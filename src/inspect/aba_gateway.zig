//! Aba Gateway: cada quadro do WebSocket do Discord e do gateway de voz, com a direção,
//! o nome do op (e do evento, no Dispatch), o seq e o tamanho; escolhido um, o conteúdo
//! em árvore (o token do IDENTIFY e do RESUME aparece como asteriscos). Sem nada
//! escolhido, um resumo: quantos de cada evento chegaram, os bytes e a latência.
const std = @import("std");
const c = @import("c");
const i18n = @import("../ui/i18n.zig");
const kit = @import("kit.zig");
const qa = @import("../ui/qa.zig");
const reg = @import("registros.zig");
const json_view = @import("json_view.zig");
const sort = @import("../core/sort.zig");
const App = @import("../app.zig").App;

const gpa = std.heap.c_allocator;

const Row = struct {
    id: u32,
    conn: reg.Conn,
    dir: reg.Dir,
    time_ms: i64,
    us: u64,
    op: i16,
    seq: i64,
    t: [40]u8,
    size: u32,
    preview: [120]u8,
    preview_len: u8,
};

var rows: std.ArrayList(Row) = .empty;
var next_id: u32 = 1;
var shown: std.ArrayList(usize) = .empty;
var filter: [96]u8 = @splat(0);
var show_main = true;
var show_voice = true;
var show_in = true;
var show_out = true;
var show_hb = false;
var selected: ?u32 = null;
var view: json_view.View = .{};
var split: f32 = 0.5;
const max_rows = 8000;

/// O nome do op como o Discord chama (no Dispatch, o nome do evento). Serve à linha da
/// lista e ao quadro do registro: o trabalho fica numa função só, não numa por tipo.
pub inline fn opName(g: anytype, buf: []u8) []const u8 {
    return nomeOp(g.conn == .main, g.op, std.mem.sliceTo(&g.t, 0), buf);
}

fn nomeOp(main: bool, op: i16, t_name: []const u8, buf: []u8) []const u8 {
    if (main) {
        return switch (op) {
            0 => if (t_name.len > 0) blk: {
                const n = @min(t_name.len, buf.len);
                @memcpy(buf[0..n], t_name[0..n]);
                break :blk buf[0..n];
            } else "Dispatch",
            1 => "Heartbeat",
            2 => "Identify",
            3 => "Presence Update",
            4 => "Voice State Update",
            6 => "Resume",
            7 => "Reconnect",
            8 => "Request Guild Members",
            9 => "Invalid Session",
            10 => "Hello",
            11 => "Heartbeat ACK",
            13 => "Call Connect",
            14 => "Guild Subscriptions",
            37 => "Guild Subscriptions Bulk",
            43 => "Request Channel Info",
            else => kit.bufSay(buf, "op {d}", &.{ kit.arg(op) }) orelse "op",
        };
    }
    return switch (op) {
        0 => "Identify",
        1 => "Select Protocol",
        2 => "Ready",
        3 => "Heartbeat",
        4 => "Session Description",
        5 => "Speaking",
        6 => "Heartbeat ACK",
        7 => "Resume",
        8 => "Hello",
        9 => "Resumed",
        11 => "Clients Connect",
        13 => "Client Disconnect",
        21 => "DAVE Prepare Transition",
        22 => "DAVE Execute Transition",
        23 => "DAVE Transition Ready",
        24 => "DAVE Prepare Epoch",
        25 => "MLS External Sender",
        26 => "MLS Key Package",
        27 => "MLS Proposals",
        28 => "MLS Commit Welcome",
        29 => "MLS Announce Commit",
        30 => "MLS Welcome",
        31 => "MLS Invalid Commit",
        else => kit.bufSay(buf, "op {d}", &.{ kit.arg(op) }) orelse "op",
    };
}

fn isHeartbeat(r: *const Row) bool {
    return if (r.conn == .main) r.op == 1 or r.op == 11 else r.op == 3 or r.op == 6;
}

fn pull() void {
    const first = reg.gw.first();
    // Limpou ou o registro deu a volta: começa de novo.
    if (first > next_id or (rows.items.len > 0 and rows.items[0].id < first)) {
        var keep: usize = 0;
        for (rows.items) |r| {
            if (r.id >= first) break;
            keep += 1;
        }
        std.mem.copyForwards(Row, rows.items, rows.items[keep..]);
        rows.shrinkRetainingCapacity(rows.items.len - keep);
        next_id = @max(next_id, first);
    }
    reg.gw.eachFrom(next_id, {}, struct {
        fn f(_: void, g: *const reg.Gw) void {
            if (rows.items.len >= max_rows) {
                const drop = max_rows / 4;
                std.mem.copyForwards(Row, rows.items, rows.items[drop..]);
                rows.shrinkRetainingCapacity(rows.items.len - drop);
            }
            var r: Row = .{ .id = g.id, .conn = g.conn, .dir = g.dir, .time_ms = g.time_ms, .us = g.us, .op = g.op, .seq = g.seq, .t = g.t, .size = g.size, .preview = undefined, .preview_len = 0 };
            const n = @min(g.payload.len, r.preview.len);
            @memcpy(r.preview[0..n], g.payload[0..n]);
            for (r.preview[0..n]) |*ch| if (ch.* < 0x20) {
                ch.* = ' ';
            };
            r.preview_len = @intCast(n);
            rows.append(gpa, r) catch {};
            next_id = g.id +% 1;
        }
    }.f);
}

pub fn draw(u: *kit.Ui, app: *App, r: kit.Rect) void {
    pull();
    const bar_h: f32 = 30;
    kit.rect(u, .{ .x = r.x, .y = r.y, .w = r.w, .h = bar_h }, kit.pal.panel, 0);
    kit.hline(u, r.x, r.right(), r.y + bar_h - 1, kit.pal.line);
    var x = r.x + 4;
    if (kit.toolButton(u, .{ .x = x, .y = r.y + 2, .w = 26, .h = 26 }, .clear, false, i18n.tr("Limpar a lista", "Clear the list"))) {
        reg.gw.clear();
        rows.clearRetainingCapacity();
        selected = null;
    }
    x += 30;
    const fw = @min(200, r.w * 0.26);
    _ = kit.search(u, "##gw-filter", .{ .x = x, .y = r.y + 4, .w = fw, .h = bar_h - 8 }, &filter, i18n.trZ("Evento, op ou texto", "Event, op or text"));
    x += fw + 8;
    const toggles = [_]struct { v: *bool, pt: []const u8, en: []const u8 }{
        .{ .v = &show_main, .pt = "Gateway", .en = "Gateway" },
        .{ .v = &show_voice, .pt = "Voz", .en = "Voice" },
        .{ .v = &show_out, .pt = "↑ Enviados", .en = "↑ Sent" },
        .{ .v = &show_in, .pt = "↓ Recebidos", .en = "↓ Received" },
        .{ .v = &show_hb, .pt = "Heartbeats", .en = "Heartbeats" },
    };
    for (toggles) |tg| {
        const b = kit.chip(u, x, r.y + 6, bar_h - 12, i18n.tr(tg.pt, tg.en), tg.v.*, null);
        if (b.clicked) tg.v.* = !tg.v.*;
        x += b.w + 4;
    }
    const body: kit.Rect = .{ .x = r.x, .y = r.y + bar_h, .w = r.w, .h = r.h - bar_h };
    const side = body.w >= 760;
    const list_r: kit.Rect = if (side) .{ .x = body.x, .y = body.y, .w = body.w * split, .h = body.h } else .{ .x = body.x, .y = body.y, .w = body.w, .h = body.h * split };
    const det_r: kit.Rect = if (side) .{ .x = body.x + body.w * split + 1, .y = body.y, .w = body.w * (1 - split) - 1, .h = body.h } else .{ .x = body.x, .y = body.y + body.h * split + 1, .w = body.w, .h = body.h * (1 - split) - 1 };
    list(u, list_r, app);
    if (selected) |id| details(u, det_r, id) else overview(u, det_r, app);
    kit.splitter(u, body, side, &split, 220, 200, 0xe3);
}

fn list(u: *kit.Ui, r: kit.Rect, app: *App) void {
    const q = kit.bufStr(&filter);
    shown.clearRetainingCapacity();
    for (rows.items, 0..) |*row, i| {
        if (row.conn == .main and !show_main) continue;
        if (row.conn == .voice and !show_voice) continue;
        if (row.dir == .in and !show_in) continue;
        if (row.dir == .out and !show_out) continue;
        if (!show_hb and isHeartbeat(row)) continue;
        if (q.len > 0) {
            var nb: [48]u8 = undefined;
            if (!kit.has(opName(row, &nb), q) and !kit.has(row.preview[0..row.preview_len], q)) continue;
        }
        shown.append(gpa, i) catch break;
    }
    const parent = u.dl;
    const rh: f32 = 21;
    const l = kit.beginList(u, "##gw-list", r, shown.items.len, rh, true, null);
    for (shown.items[l.first..l.last], l.first..) |ri, k| {
        const row = &rows.items[ri];
        const y = l.y0 + @as(f32, @floatFromInt(k - l.first)) * rh;
        const rr: kit.Rect = .{ .x = r.x, .y = y, .w = r.w, .h = rh };
        qa.mark(rr, "insp-gw-row:{d}", .{k});
        const sel = selected == row.id;
        const over = u.over(rr);
        if (sel) kit.rect(u, rr, kit.pal.sel, 0) else if (row.dir == .out) kit.rect(u, rr, kit.pal.sent_bg.alpha(0.7), 0);
        if (over and !sel) kit.rect(u, rr, kit.pal.hover, 0);
        kit.icon(u.dl, if (row.dir == .out) .up else .down, r.x + 12, y + rh / 2, if (row.dir == .out) kit.pal.ok else kit.pal.err);
        const ty = u.midCode(y, rh);
        var tb: [16]u8 = undefined;
        _ = u.code(r.x + 24, ty, kit.pal.faint, kit.clock(&tb, row.time_ms));
        var run: kit.Run = .{ .u = u, .x = r.x + 24 + u.codeW("00:00:00.000") + 10, .y = ty, .max_x = r.right() - 70 };
        if (row.conn == .voice) run.put(kit.pal.num, "voz ");
        var nb: [48]u8 = undefined;
        run.put(if (row.op == 0 and row.conn == .main) kit.pal.key else kit.pal.text, opName(row, &nb));
        if (row.seq >= 0) run.say(kit.pal.faint, "  #{d}", &.{ kit.arg(row.seq) });
        run.put(kit.pal.faint, "  ");
        run.put(kit.pal.faint, row.preview[0..row.preview_len]);
        var sb: [24]u8 = undefined;
        const size_s = kit.bytesText(&sb, row.size);
        _ = u.code(r.right() - u.codeW(size_s) - 10, ty, kit.pal.dim, size_s);
        if (over and c.ImGui_IsMouseClicked(0)) selected = if (sel) null else row.id;
    }
    if (shown.items.len == 0) {
        const msg = if (app.store.demo) i18n.tr("Na demonstração não há gateway de verdade: os quadros aparecem com uma conta conectada.", "The demo has no real gateway: frames show up with an account connected.") else if (!reg.gravando()) i18n.tr("A gravação está desligada.", "Recording is off.") else i18n.tr("Nenhum quadro ainda.", "No frames yet.");
        _ = u.clip(r.x + 12, r.y + 30, kit.pal.faint, msg, r.w - 24);
    }
    kit.endList(u, l, shown.items.len, rh, parent);
}

fn details(u: *kit.Ui, r: kit.Rect, id: u32) void {
    kit.rect(u, r, kit.pal.panel, 0);
    if (view.src != id) {
        const p = reg.gw.payloadCopy(id) orelse {
            selected = null;
            return;
        };
        defer gpa.free(p);
        view.load(id, p);
    }
    json_view.draw(u, &view, "##gw-json", r);
}

/// Sem quadro escolhido: os eventos que mais chegaram, os bytes e a latência.
fn overview(u: *kit.Ui, r: kit.Rect, app: *App) void {
    kit.rect(u, r, kit.pal.panel, 0);
    const parent = u.dl;
    var y = kit.beginPane(u, "##gw-over", r);
    const x = r.x;
    const w = r.w - 10;
    var open = true;
    if (kit.section(u, x, &y, w + 10, i18n.tr("Conexão", "Connection"), &open)) {
        kit.kv(u, x, &y, w, i18n.tr("Estado", "State"), @tagName(app.store.connection), kit.pal.text);
        var lb: [24]u8 = undefined;
        kit.kv(u, x, &y, w, i18n.tr("Latência do heartbeat", "Heartbeat latency"), kit.bufSay(&lb, "{d} ms", &.{ kit.arg(app.store.latency_ms) }) orelse "", kit.pal.num);
        var b1: [24]u8 = undefined;
        var b2: [24]u8 = undefined;
        kit.kv(u, x, &y, w, i18n.tr("Recebido / enviado", "Received / sent"), kit.bufSay(&lb, "{s} / {s}", &.{ kit.arg(kit.bytesText(&b1, reg.gw.bytes_in[0])), kit.arg(kit.bytesText(&b2, reg.gw.bytes_out[0])) }) orelse "", kit.pal.num);
        if (reg.gw.bytes_in[1] + reg.gw.bytes_out[1] > 0) {
            var vb: [48]u8 = undefined;
            kit.kv(u, x, &y, w, i18n.tr("Voz: recebido / enviado", "Voice: received / sent"), kit.bufSay(&vb, "{s} / {s}", &.{ kit.arg(kit.bytesText(&b1, reg.gw.bytes_in[1])), kit.arg(kit.bytesText(&b2, reg.gw.bytes_out[1])) }) orelse "", kit.pal.num);
        }
        y += 6;
    }
    // Contagem por evento (Dispatch) e por op enviado.
    var names: [64][40]u8 = undefined;
    var counts: [64]u32 = @splat(0);
    var n: usize = 0;
    for (rows.items) |*row| {
        if (row.conn != .main) continue;
        var nb: [48]u8 = undefined;
        const name = opName(row, &nb);
        var found = false;
        for (names[0..n], 0..) |*nm, k| if (std.mem.eql(u8, std.mem.sliceTo(nm, 0), name)) {
            counts[k] += 1;
            found = true;
            break;
        };
        if (!found and n < names.len) {
            @memset(&names[n], 0);
            @memcpy(names[n][0..@min(name.len, 39)], name[0..@min(name.len, 39)]);
            counts[n] = 1;
            n += 1;
        }
    }
    var open2 = true;
    if (n > 0) if (kit.section(u, x, &y, w + 10, i18n.tr("Quadros por tipo", "Frames by type"), &open2)) {
        var order: [64]usize = undefined;
        for (0..n) |k| order[k] = k;
        const S = struct {
            fn gt(cs: *const [64]u32, a: usize, b: usize) bool {
                return cs[a] > cs[b];
            }
        };
        sort.stable(usize, order[0..n], &counts, S.gt);
        const top = counts[order[0]];
        for (order[0..@min(n, 24)]) |k| {
            const name = std.mem.sliceTo(&names[k], 0);
            _ = u.clipCode(x + 12, u.midCode(y, 19), kit.pal.key, name, 190);
            const bw = (w - 260) * @as(f32, @floatFromInt(counts[k])) / @as(f32, @floatFromInt(top));
            kit.rect(u, .{ .x = x + 210, .y = y + 6, .w = @max(2, bw), .h = 8 }, kit.pal.accent.alpha(0.6), 2);
            var cb: [16]u8 = undefined;
            _ = u.code(x + w - 40, u.midCode(y, 19), kit.pal.dim, kit.bufSay(&cb, "{d}", &.{ kit.arg(counts[k]) }) orelse "");
            y += 19;
        }
    };
    _ = u.clip(x + 12, y + 8, kit.pal.faint, i18n.tr("Clique num quadro para ver o conteúdo.", "Click a frame to see its content."), w - 12);
    y += 30;
    kit.endPane(u, r, y, parent);
}

const t = std.testing;

test "nome do op do gateway e da voz" {
    var b: [48]u8 = undefined;
    var g: reg.Gw = .{ .op = 0 };
    @memcpy(g.t[0..14], "MESSAGE_CREATE");
    try t.expectEqualStrings("MESSAGE_CREATE", opName(&g, &b));
    g.op = 14;
    try t.expectEqualStrings("Guild Subscriptions", opName(&g, &b));
    g.conn = .voice;
    g.op = 5;
    try t.expectEqualStrings("Speaking", opName(&g, &b));
    g.op = 99;
    try t.expectEqualStrings("op 99", opName(&g, &b));
}
