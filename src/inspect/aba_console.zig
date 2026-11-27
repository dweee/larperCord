//! Aba Console: as linhas de log do app (as mesmas do registro de depuração, sem precisar
//! ligá-lo), com filtro por nível e texto, avisos e erros em destaque, e embaixo a linha
//! de comandos do Inspetor (os mesmos do `larpercord ctl inspect`; `help` lista).
const std = @import("std");
const c = @import("c");
const d = @import("../ui/draw.zig");
const i18n = @import("../ui/i18n.zig");
const kit = @import("kit.zig");
const qa = @import("../ui/qa.zig");
const reg = @import("registros.zig");
const cmds = @import("comandos.zig");
const App = @import("../app.zig").App;

const gpa = std.heap.c_allocator;

const Kind = enum(u8) { debug, info, warn, err, input, output };

const Row = struct {
    kind: Kind,
    time_ms: i64,
    scope: [16]u8 = @splat(0),
    text: []u8,
};

/// O que o Console mostra: as linhas do log (copiadas do registro, na thread da
/// interface) e o que se digitou na linha de comandos com a resposta, na ordem.
var rows: std.ArrayList(Row) = .empty;
var next_log: u32 = 1;
var cleared_seen: u32 = 0;
var shown: std.ArrayList(u32) = .empty;
var filter: [96]u8 = @splat(0);
var levels = [4]bool{ false, true, true, true };
var follow = true;
var input: [512]u8 = @splat(0);
var focus_input = false;
var history: std.ArrayList([]u8) = .empty;
var hist_at: ?usize = null;
/// Um comando que precisa de um quadro gravado espera aqui e roda de novo no próximo.
var waiting: ?[]u8 = null;
var waiting_tries: u8 = 0;
const max_rows = 12_000;

fn add(kind: Kind, text: []const u8, scope: []const u8, time_ms: i64) void {
    if (rows.items.len >= max_rows) {
        // Sai o terço mais velho de uma vez (não a cada linha).
        const drop = max_rows / 3;
        for (rows.items[0..drop]) |r| gpa.free(r.text);
        std.mem.copyForwards(Row, rows.items[0..], rows.items[drop..]);
        rows.shrinkRetainingCapacity(rows.items.len - drop);
    }
    var r: Row = .{ .kind = kind, .time_ms = time_ms, .text = gpa.dupe(u8, text) catch return };
    const n = @min(scope.len, r.scope.len);
    @memcpy(r.scope[0..n], scope[0..n]);
    rows.append(gpa, r) catch gpa.free(r.text);
}

/// Traz as linhas novas do registro.
fn pull() void {
    const first = reg.lines.first();
    if (first > next_log) next_log = first;
    reg.lines.eachFrom(next_log, {}, struct {
        fn f(_: void, l: *const reg.Line) void {
            add(@enumFromInt(@intFromEnum(l.level)), l.text, l.scopeStr(), l.time_ms);
            next_log = l.id +% 1;
        }
    }.f);
}

fn counts() [4]u32 {
    var n: [4]u32 = @splat(0);
    for (rows.items) |r| if (@intFromEnum(r.kind) < 4) {
        n[@intFromEnum(r.kind)] += 1;
    };
    return n;
}

pub fn draw(u: *kit.Ui, app: *App, r: kit.Rect) void {
    pull();
    rerun(app);
    // Barra: limpar, filtro, níveis, seguir o fim, deixar o ctl mexer.
    const bar_h: f32 = 30;
    kit.rect(u, .{ .x = r.x, .y = r.y, .w = r.w, .h = bar_h }, kit.pal.panel, 0);
    kit.hline(u, r.x, r.right(), r.y + bar_h - 1, kit.pal.line);
    var x = r.x + 4;
    if (kit.toolButton(u, .{ .x = x, .y = r.y + 2, .w = 26, .h = 26 }, .clear, false, i18n.tr("Limpar o console", "Clear the console"))) {
        for (rows.items) |row| gpa.free(row.text);
        rows.clearRetainingCapacity();
        reg.lines.clear();
    }
    x += 30;
    const fw = @min(220, r.w * 0.3);
    _ = kit.search(u, "##con-filter", .{ .x = x, .y = r.y + 4, .w = fw, .h = bar_h - 8 }, &filter, i18n.trZ("Filtrar", "Filter"));
    x += fw + 8;
    const n = counts();
    const names = [_]struct { pt: []const u8, en: []const u8 }{
        .{ .pt = "Detalhes", .en = "Verbose" },
        .{ .pt = "Info", .en = "Info" },
        .{ .pt = "Avisos", .en = "Warnings" },
        .{ .pt = "Erros", .en = "Errors" },
    };
    for (names, 0..) |nm, k| {
        if (k == 0 and n[0] == 0) continue;
        const ch = kit.chip(u, x, r.y + 6, bar_h - 12, i18n.tr(nm.pt, nm.en), levels[k], n[k]);
        if (ch.clicked) levels[k] = !levels[k];
        x += ch.w + 4;
    }
    // Pelo ctl, clicar e digitar só com isto ligado (fora da demonstração). Sem espaço para o
    // nome inteiro, fica só "ctl" (a dica explica).
    const long = i18n.tr("Deixar o ctl clicar e digitar", "Let ctl click and type");
    const label = if (x + u.textW(long) + 28 < r.right()) long else "ctl";
    const cw = u.textW(label) + 16;
    const ctl = kit.chip(u, r.right() - 8 - cw, r.y + 6, bar_h - 12, label, cmds.ctl_mexe, null);
    if (ctl.clicked) cmds.ctl_mexe = !cmds.ctl_mexe;
    if (u.over(.{ .x = r.right() - 8 - ctl.w, .y = r.y, .w = ctl.w, .h = bar_h })) kit.tooltip(u, i18n.tr("O larpercord ctl pode clicar e digitar na sua conta até você fechar o app", "larpercord ctl may click and type on your account until you close the app"));

    // A lista.
    const in_h: f32 = 30;
    const list_r: kit.Rect = .{ .x = r.x, .y = r.y + bar_h, .w = r.w, .h = r.h - bar_h - in_h };
    const q = kit.bufStr(&filter);
    shown.clearRetainingCapacity();
    for (rows.items, 0..) |row, k| {
        const lvl = @intFromEnum(row.kind);
        if (lvl < 4 and !levels[lvl]) continue;
        if (q.len > 0 and !kit.has(row.text, q) and !kit.has(std.mem.sliceTo(&row.scope, 0), q)) continue;
        shown.append(gpa, @intCast(k)) catch break;
    }
    const parent = u.dl;
    const rh: f32 = 20;
    const l = kit.beginList(u, "##con-list", list_r, shown.items.len, rh, follow, null);
    for (shown.items[l.first..l.last], l.first..) |k, i| {
        const row = rows.items[k];
        const y = l.y0 + @as(f32, @floatFromInt(i - l.first)) * rh;
        const rr: kit.Rect = .{ .x = list_r.x, .y = y, .w = list_r.w, .h = rh };
        const bg: ?kit.Rgba = switch (row.kind) {
            .warn => kit.pal.warn_bg,
            .err => kit.pal.err_bg,
            .input => kit.pal.hover,
            else => null,
        };
        if (bg) |b| kit.rect(u, rr, b, 0);
        const over = u.over(rr);
        if (over and bg == null) kit.rect(u, rr, kit.pal.hover, 0);
        kit.hline(u, rr.x, rr.right(), y + rh - 1, kit.pal.line.alpha(0.5));
        const col = switch (row.kind) {
            .warn => kit.pal.warn,
            .err => kit.pal.err,
            .debug => kit.pal.faint,
            .input => kit.pal.accent,
            .output => kit.pal.text,
            .info => kit.pal.text,
        };
        var tb: [16]u8 = undefined;
        // A resposta de um comando continua a linha dele: sem horário próprio.
        if (row.kind != .output) _ = u.code(rr.x + 8, u.midCode(y, rh), kit.pal.faint, kit.clock(&tb, row.time_ms));
        var run: kit.Run = .{ .u = u, .x = rr.x + 8 + u.codeW("00:00:00.000") + 10, .y = u.midCode(y, rh), .max_x = rr.right() - 6 };
        switch (row.kind) {
            .input => run.put(kit.pal.accent, "› "),
            .warn => run.put(col, "▲ "),
            .err => run.put(col, "✖ "),
            else => {},
        }
        const sc = std.mem.sliceTo(&row.scope, 0);
        if (sc.len > 0) {
            run.put(kit.pal.attr, sc);
            run.put(kit.pal.faint, "  ");
        }
        run.put(col, row.text);
        if (over and c.ImGui_IsMouseClicked(0)) kit.copyText(row.text);
    }
    if (shown.items.len == 0) {
        const msg = i18n.tr("Nada aqui ainda. Digite help embaixo para ver os comandos.", "Nothing here yet. Type help below to see the commands.");
        _ = u.text(list_r.x + (list_r.w - u.textW(msg)) / 2, list_r.y + 30, kit.pal.faint, msg);
    }
    // Rolar para cima solta o "seguir o fim"; voltar ao fim liga de novo.
    follow = c.ImGui_GetScrollY() >= c.ImGui_GetScrollMaxY() - rh * 1.5;
    kit.endList(u, l, shown.items.len, rh, parent);

    commandLine(u, app, .{ .x = r.x, .y = r.bottom() - in_h, .w = r.w, .h = in_h });
}

fn commandLine(u: *kit.Ui, app: *App, r: kit.Rect) void {
    qa.mark(r, "insp-console-input", .{});
    kit.rect(u, r, kit.pal.input, 0);
    kit.hline(u, r.x, r.right(), r.y, kit.pal.line);
    _ = u.code(r.x + 10, u.midCode(r.y, r.h), kit.pal.accent, "›");
    c.ImGui_SetCursorScreenPos(d.v(r.x + 24, r.y + (r.h - u.ms * 1.2 - 4) / 2));
    c.ImGui_PushFontFloat(u.mono, u.ms);
    defer c.ImGui_PopFont();
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_FrameBg, .{ .x = 0, .y = 0, .z = 0, .w = 0 });
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Text, kit.vec4(kit.pal.text));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_TextDisabled, kit.vec4(kit.pal.faint));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, d.v(2, 2));
    defer {
        c.ImGui_PopStyleVarEx(1);
        c.ImGui_PopStyleColorEx(3);
    }
    if (focus_input) {
        c.ImGui_SetKeyboardFocusHere();
        focus_input = false;
    }
    c.ImGui_SetNextItemWidth(r.w - 34);
    const enter = c.ImGui_InputTextWithHintEx("##con-input", i18n.trZ("comando (help lista todos)", "command (help lists them all)").ptr, &input, input.len, c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_CallbackHistory, historyCb, null);
    if (enter) {
        const line = std.mem.trim(u8, kit.bufStr(&input), " ");
        if (line.len > 0) {
            if (gpa.dupe(u8, line)) |h| history.append(gpa, h) catch gpa.free(h) else |_| {}
            hist_at = null;
            add(.input, line, "", reg.agoraMs());
            exec(app, line);
            follow = true;
        }
        @memset(&input, 0);
        focus_input = true;
    }
}

/// ↑ e ↓ na linha de comandos: o histórico (pelo jeito do ImGui de trocar o texto do campo ativo).
fn historyCb(data: [*c]c.ImGuiInputTextCallbackData) callconv(.c) c_int {
    if (history.items.len == 0) return 0;
    const up = data.*.EventKey == c.ImGuiKey_UpArrow;
    if (up) {
        hist_at = if (hist_at) |h| h -| 1 else history.items.len - 1;
    } else if (hist_at) |h| {
        hist_at = if (h + 1 < history.items.len) h + 1 else null;
    } else return 0;
    c.ImGuiInputTextCallbackData_DeleteChars(data, 0, data.*.BufTextLen);
    if (hist_at) |h| {
        const s = history.items[h];
        c.ImGuiInputTextCallbackData_InsertChars(data, 0, s.ptr, s.ptr + s.len);
    }
    return 0;
}

fn exec(app: *App, line: []const u8) void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    switch (cmds.run(app, line, &out.writer, .console)) {
        .pronto => emit(out.written()),
        .depois => {
            if (waiting) |w| gpa.free(w);
            waiting = gpa.dupe(u8, line) catch null;
            waiting_tries = 0;
        },
    }
}

/// O comando que esperava um quadro gravado: roda de novo (até umas 30 vezes).
fn rerun(app: *App) void {
    const line = waiting orelse return;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    waiting_tries += 1;
    switch (cmds.run(app, line, &out.writer, .console)) {
        .pronto => {
            emit(out.written());
            gpa.free(line);
            waiting = null;
        },
        .depois => if (waiting_tries > 30) {
            emit(i18n.tr("sem quadro gravado para responder", "no captured frame to answer with"));
            gpa.free(line);
            waiting = null;
        } else {
            @import("../ui/anim.zig").active = true;
        },
    }
}

fn emit(text: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    const now = reg.agoraMs();
    while (it.next()) |l| add(.output, l, "", now);
}
