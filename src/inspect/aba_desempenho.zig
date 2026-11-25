//! Aba Desempenho: quanto cada quadro custa de CPU (o gráfico dos últimos), quantos
//! saíram iguais e não foram desenhados, o custo de cada componente do tema, o tamanho
//! do que vai para a GPU, a memória e a CPU do processo. O larperCord vive de ser leve:
//! é aqui que se vê o que ficou pesado.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const i18n = @import("../ui/i18n.zig");
const kit = @import("kit.zig");
const cap = @import("captura.zig");
const mem_use = @import("../core/mem_use.zig");
const sort = @import("../core/sort.zig");
const App = @import("../app.zig").App;

/// Uma amostra por quadro feito: o tempo de CPU dele e se foi para a tela.
const Sample = struct { us: u32, shown: bool, at_ms: i64 };

const n_samples = 300;
var samples: [n_samples]Sample = @splat(.{ .us = 0, .shown = false, .at_ms = 0 });
var head: usize = 0;
var count: usize = 0;
var gpu: struct { lists: u32 = 0, cmds: u32 = 0, vtx: u32 = 0, idx: u32 = 0, tex: u32 = 0 } = .{};
var cpu_pct: f32 = 0;
var cpu_last_ms: i64 = 0;
var cpu_last_us: u64 = 0;
var cpu_hist: [60]f32 = @splat(0);
var mu: mem_use.MemUse = .{};
var mu_ms: i64 = 0;
var cpu_head: usize = 0;

/// Depois de cada quadro (com o Inspetor aberto): a amostra e, se a aba está à vista, os
/// números do que foi para a GPU.
pub fn sample(app: *App, frame_us: u32, shown: bool, now_ms: i64) void {
    samples[head] = .{ .us = frame_us, .shown = shown, .at_ms = now_ms };
    head = (head + 1) % n_samples;
    count = @min(count + 1, n_samples);
    const dd = c.ImGui_GetDrawData();
    if (dd != null) {
        var g: @TypeOf(gpu) = .{};
        const lists: usize = @intCast(@max(dd.*.CmdLists.Size, 0));
        g.lists = @intCast(lists);
        for (0..lists) |li| {
            const cl = dd.*.CmdLists.Data[li];
            g.vtx += @intCast(cl.*.VtxBuffer.Size);
            g.idx += @intCast(cl.*.IdxBuffer.Size);
            var prev: u64 = 0;
            for (0..@intCast(cl.*.CmdBuffer.Size)) |ci| {
                g.cmds += 1;
                const id = cl.*.CmdBuffer.Data[ci].TexRef._TexID;
                if (id != prev) g.tex += 1;
                prev = id;
            }
        }
        gpu = g;
    }
    // A CPU do processo, de meio em meio segundo.
    if (now_ms - cpu_last_ms >= 500) {
        const us = processCpuUs();
        if (cpu_last_ms != 0 and us >= cpu_last_us) {
            cpu_pct = @as(f32, @floatFromInt(us - cpu_last_us)) / @as(f32, @floatFromInt((now_ms - cpu_last_ms) * 1000)) * 100;
            cpu_hist[cpu_head] = cpu_pct;
            cpu_head = (cpu_head + 1) % cpu_hist.len;
        }
        cpu_last_ms = now_ms;
        cpu_last_us = us;
    }
    // O número da RAM é lido pelo tique só se alguém olha.
    @atomicStore(bool, &app.stats.ram_seen, true, .monotonic);
}

/// Tempo de CPU do processo inteiro (todas as threads), em µs.
fn processCpuUs() u64 {
    if (builtin.os.tag == .windows) {
        var cr: c.FILETIME = undefined;
        var ex: c.FILETIME = undefined;
        var k: c.FILETIME = undefined;
        var us: c.FILETIME = undefined;
        if (c.GetProcessTimes(c.GetCurrentProcess(), &cr, &ex, &k, &us) == 0) return 0;
        const t100 = (@as(u64, k.dwHighDateTime) << 32 | k.dwLowDateTime) + (@as(u64, us.dwHighDateTime) << 32 | us.dwLowDateTime);
        return t100 / 10;
    }
    if (builtin.os.tag != .linux) return 0;
    // /proc/self/stat: utime e stime (campos 14 e 15), em tiques do relógio.
    const fd = c.open("/proc/self/stat", c.O_RDONLY);
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    var buf: [1024]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return 0;
    const s = buf[0..@intCast(n)];
    // Depois do nome do processo (entre parênteses, pode ter espaço).
    const close_paren = std.mem.lastIndexOfScalar(u8, s, ')') orelse return 0;
    var it = std.mem.tokenizeScalar(u8, s[close_paren + 1 ..], ' ');
    var field: usize = 3;
    var utime: u64 = 0;
    var stime: u64 = 0;
    while (it.next()) |tok| : (field += 1) {
        if (field == 14) utime = std.fmt.parseInt(u64, tok, 10) catch 0;
        if (field == 15) {
            stime = std.fmt.parseInt(u64, tok, 10) catch 0;
            break;
        }
    }
    const hz: u64 = @intCast(@max(c.sysconf(c._SC_CLK_TCK), 1));
    return (utime + stime) * 1_000_000 / hz;
}

const Stats = struct { last: u32 = 0, avg: u32 = 0, p95: u32 = 0, max: u32 = 0, fps: u32 = 0, shown_pct: u32 = 0 };

fn stats(now_ms: i64) Stats {
    if (count == 0) return .{};
    var vals: [n_samples]u32 = undefined;
    var sum: u64 = 0;
    var shown_n: u32 = 0;
    var fps: u32 = 0;
    for (0..count) |k| {
        const s = samples[(head + n_samples - 1 - k) % n_samples];
        vals[k] = s.us;
        sum += s.us;
        if (s.shown) shown_n += 1;
        if (now_ms - s.at_ms <= 1000) fps += 1;
    }
    const last = vals[0];
    sort.stable(u32, vals[0..count], {}, std.sort.asc(u32));
    return .{
        .last = last,
        .avg = @intCast(sum / count),
        .p95 = vals[@min(count - 1, count * 95 / 100)],
        .max = vals[count - 1],
        .fps = fps,
        .shown_pct = @intCast(@as(u64, shown_n) * 100 / count),
    };
}

pub fn draw(u: *kit.Ui, app: *App, r: kit.Rect) void {
    const now_ms: i64 = @intCast(c.SDL_GetTicks());
    const st = stats(now_ms);
    const parent = u.dl;
    var y = kit.beginPane(u, "##perf", r);
    const x = r.x + 10;
    const w = r.w - 20;
    // Cartões.
    var b: [8][32]u8 = undefined;
    var db: [24]u8 = undefined;
    const cards = [_]struct { pt: []const u8, en: []const u8, v: []const u8, warn: bool }{
        .{ .pt = "Quadro (último)", .en = "Frame (last)", .v = kit.durText(&b[0], st.last), .warn = st.last > 16_000 },
        .{ .pt = "Média / p95", .en = "Average / p95", .v = kit.bufSay(&b[1], "{s} / {s}", &.{ kit.arg(kit.durText(&db, st.avg)), kit.arg(kit.durText(&b[7], st.p95)) }) orelse "", .warn = st.p95 > 16_000 },
        .{ .pt = "Quadros no último segundo", .en = "Frames in the last second", .v = kit.bufSay(&b[2], "{d}", &.{ kit.arg(st.fps) }) orelse "", .warn = false },
        .{ .pt = "Foram para a tela", .en = "Went to the screen", .v = kit.bufSay(&b[3], "{d}%", &.{ kit.arg(st.shown_pct) }) orelse "", .warn = false },
        .{ .pt = "CPU do processo", .en = "Process CPU", .v = kit.bufSay(&b[4], "{d:.1}%", &.{ kit.arg(cpu_pct) }) orelse "", .warn = cpu_pct > 25 },
        .{ .pt = if (builtin.os.tag == .windows) "RAM (privada)" else "RAM (PSS)", .en = if (builtin.os.tag == .windows) "RAM (private)" else "RAM (PSS)", .v = kit.bytesText(&b[5], @as(usize, app.stats.ram_kb) * 1024), .warn = false },
    };
    const cw: f32 = @max(130, (w - 10) / 3);
    var cx = x;
    for (cards) |cd| {
        if (cx + cw > x + w + 1) {
            cx = x;
            y += 58;
        }
        const cr: kit.Rect = .{ .x = cx, .y = y, .w = cw - 8, .h = 50 };
        kit.rect(u, cr, kit.pal.panel, 6);
        @import("../ui/draw.zig").border(u.dl, cr, kit.pal.line, 6, 1);
        _ = u.clip(cr.x + 10, cr.y + 7, kit.pal.dim, i18n.tr(cd.pt, cd.en), cr.w - 20);
        @import("../ui/draw.zig").text(u.dl, u.bold, u.fs + 4, cr.x + 10, cr.y + 24, if (cd.warn) kit.pal.warn else kit.pal.text, cd.v);
        cx += cw;
    }
    y += 64;
    // O gráfico dos quadros.
    var open_g = true;
    if (kit.section(u, x - 10, &y, w + 20, i18n.tr("Tempo de cada quadro (os últimos 300)", "Time of each frame (the last 300)"), &open_g)) {
        y = graph(u, x, y, w, 120, st.max) + 10;
        _ = u.clip(x, y, kit.pal.faint, i18n.tr("Linha: 16,7 ms (60 por segundo). Barra clara: o quadro saiu igual e não foi desenhado.", "Line: 16.7 ms (60 per second). Light bar: the frame came out the same and wasn't drawn."), w);
        y += 24;
    }
    // Componentes do tema (do último quadro gravado).
    var open_c = true;
    if (cap.last()) |f| if (kit.section(u, x - 10, &y, w + 20, i18n.tr("Custo de cada componente (último quadro)", "Cost of each component (last frame)"), &open_c)) {
        var idx: [256]usize = undefined;
        var n: usize = 0;
        for (f.scopes.items, 0..) |s, i| if (s.us > 0 and n < idx.len) {
            idx[n] = i;
            n += 1;
        };
        const S = struct {
            fn gt(ff: *const cap.Frame, a: usize, bb: usize) bool {
                return ff.scopes.items[a].us > ff.scopes.items[bb].us;
            }
        };
        sort.stable(usize, idx[0..n], f, S.gt);
        const top: f32 = if (n > 0) @floatFromInt(f.scopes.items[idx[0]].us) else 1;
        for (idx[0..@min(n, 16)]) |si| {
            const s = &f.scopes.items[si];
            const rr: kit.Rect = .{ .x = x - 10, .y = y, .w = w + 20, .h = 20 };
            if (u.over(rr)) {
                kit.rect(u, rr, kit.pal.hover, 0);
                @import("ui.zig").hover_scope = si;
            }
            _ = u.clipCode(x, u.midCode(y, 20), kit.pal.tag, s.name, 150);
            const bw = (w - 240) * @as(f32, @floatFromInt(s.us)) / top;
            kit.rect(u, .{ .x = x + 160, .y = y + 6, .w = @max(2, bw), .h = 8 }, kit.pal.accent.alpha(0.65), 2);
            var ub: [24]u8 = undefined;
            _ = u.code(x + w - 70, u.midCode(y, 20), kit.pal.dim, kit.durText(&ub, s.us));
            y += 20;
        }
        if (n == 0) {
            _ = u.clip(x, y, kit.pal.faint, i18n.tr("Nenhum componente custou mais de 1 µs.", "No component cost more than 1 µs."), w);
            y += 20;
        }
        y += 8;
    };
    // GPU e memória.
    var open_m = true;
    if (kit.section(u, x - 10, &y, w + 20, i18n.tr("GPU e memória", "GPU and memory"), &open_m)) {
        var vb: [64]u8 = undefined;
        kit.kv(u, x - 10, &y, w + 10, i18n.tr("Listas de desenho", "Draw lists"), kit.bufSay(&vb, "{d}", &.{ kit.arg(gpu.lists) }) orelse "", kit.pal.num);
        kit.kv(u, x - 10, &y, w + 10, i18n.tr("Comandos / trocas de textura", "Commands / texture switches"), kit.bufSay(&vb, "{d} / {d}", &.{ kit.arg(gpu.cmds), kit.arg(gpu.tex) }) orelse "", kit.pal.num);
        kit.kv(u, x - 10, &y, w + 10, i18n.tr("Vértices / índices", "Vertices / indices"), kit.bufSay(&vb, "{d} / {d}", &.{ kit.arg(gpu.vtx), kit.arg(gpu.idx) }) orelse "", kit.pal.num);
        var b1: [24]u8 = undefined;
        kit.kv(u, x - 10, &y, w + 10, i18n.tr("Imagens no cache", "Images in cache"), kit.bufSay(&vb, "{d} · {s}", &.{ kit.arg(app.images.readyCount()), kit.arg(kit.bytesText(&b1, app.images.bytes)) }) orelse "", kit.pal.num);
        // Varrer a conta custa: no máximo a cada 2 s.
        if (now_ms - mu_ms >= 2000 or mu_ms == 0) {
            mu = mem_use.of(&app.store);
            mu_ms = now_ms;
        }
        kit.kv(u, x - 10, &y, w + 10, i18n.tr("Mensagens na memória", "Messages in memory"), kit.bufSay(&vb, "{d} · ~{s}", &.{ kit.arg(mu.n_messages), kit.arg(kit.bytesText(&b1, mu.messages)) }) orelse "", kit.pal.num);
        kit.kv(u, x - 10, &y, w + 10, i18n.tr("Pessoas", "People"), kit.bufSay(&vb, "{d} · ~{s}", &.{ kit.arg(mu.n_people), kit.arg(kit.bytesText(&b1, mu.people)) }) orelse "", kit.pal.num);
        if (app.stats.heap_used_kb > 0) kit.kv(u, x - 10, &y, w + 10, i18n.tr("Alocada / livre não devolvida", "Allocated / free not returned"), kit.bufSay(&vb, "{s} / {s}", &.{ kit.arg(kit.bytesText(&b1, @as(usize, app.stats.heap_used_kb) * 1024)), kit.arg(kit.bytesText(&b[6], @as(usize, app.stats.heap_free_kb) * 1024)) }) orelse "", kit.pal.num);
        y += 8;
    }
    kit.endPane(u, r, y, parent);
}

fn graph(u: *kit.Ui, x: f32, y: f32, w: f32, h: f32, max_us: u32) f32 {
    kit.rect(u, .{ .x = x, .y = y, .w = w, .h = h }, kit.pal.input, 4);
    // A escala vai até o maior (no mínimo 20 ms, para a linha de 16,7 ms aparecer).
    const top: f32 = @floatFromInt(@max(max_us, 20_000));
    const line_y = y + h - h * 16_700 / top;
    @import("../ui/draw.zig").line(u.dl, x, line_y, x + w, line_y, kit.pal.warn.alpha(0.6), 1);
    if (count == 0) return y + h;
    const bw = w / @as(f32, n_samples);
    var hovered: ?Sample = null;
    for (0..count) |k| {
        const s = samples[(head + n_samples - count + k) % n_samples];
        const bx = x + w - @as(f32, @floatFromInt(count - k)) * bw;
        const bh = @max(1, h * @as(f32, @floatFromInt(s.us)) / top);
        const col = if (s.us > 16_700) kit.pal.err else if (s.us > 8_000) kit.pal.warn else kit.pal.accent;
        kit.rect(u, .{ .x = bx, .y = y + h - bh, .w = @max(1, bw - 0.5), .h = bh }, if (s.shown) col else col.alpha(0.35), 0);
        if (u.over(.{ .x = bx, .y = y, .w = bw, .h = h })) hovered = s;
    }
    if (hovered) |s| {
        var tb: [64]u8 = undefined;
        var db: [24]u8 = undefined;
        kit.tooltip(u, kit.bufSay(&tb, "{s}{s}", &.{ kit.arg(kit.durText(&db, s.us)), kit.arg(if (s.shown) "" else i18n.tr("  (igual, não desenhado)", "  (same, not drawn)")) }) orelse "");
    }
    return y + h;
}

/// Os números em texto, para o comando `perf`.
pub fn texto(app: *App, w: *std.Io.Writer) @import("comandos.zig").Fim {
    const st = stats(@intCast(c.SDL_GetTicks()));
    kit.say(w, "quadro: último {d} µs, média {d} µs, p95 {d} µs, máximo {d} µs ({d} amostras)\n", &.{ kit.arg(st.last), kit.arg(st.avg), kit.arg(st.p95), kit.arg(st.max), kit.arg(count) }) catch {};
    kit.say(w, "quadros no último segundo: {d}, foram para a tela: {d}%\n", &.{ kit.arg(st.fps), kit.arg(st.shown_pct) }) catch {};
    kit.say(w, "cpu do processo: {d:.1}%\n", &.{ kit.arg(cpu_pct) }) catch {};
    kit.say(w, "ram: {d} KB, heap alocada {d} KB, livre {d} KB\n", &.{ kit.arg(app.stats.ram_kb), kit.arg(app.stats.heap_used_kb), kit.arg(app.stats.heap_free_kb) }) catch {};
    kit.say(w, "gpu: {d} listas, {d} comandos, {d} trocas de textura, {d} vértices\n", &.{ kit.arg(gpu.lists), kit.arg(gpu.cmds), kit.arg(gpu.tex), kit.arg(gpu.vtx) }) catch {};
    kit.say(w, "imagens: {d} ({d} KB)\n", &.{ kit.arg(app.images.readyCount()), kit.arg(app.images.bytes / 1024) }) catch {};
    if (cap.last()) |f| {
        for (f.scopes.items) |s| if (s.us >= 50) kit.say(w, "componente {s}: {d} µs\n", &.{ kit.arg(s.name), kit.arg(s.us) }) catch {};
    }
    if (count == 0) w.writeAll("(abra o Inspetor para as amostras de quadro)\n") catch {};
    return .pronto;
}
