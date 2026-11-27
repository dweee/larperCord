//! Aba Eventos: as mensagens entre as partes do app, na ordem em que aconteceram — o que
//! a interface pediu ao app (ações), o que o app pediu à rede (comandos) e o que a rede
//! entregou (eventos). É onde se vê que um clique virou um pedido, ou que um evento
//! chegou e nada mudou na tela.
const std = @import("std");
const c = @import("c");
const d = @import("../ui/draw.zig");
const i18n = @import("../ui/i18n.zig");
const kit = @import("kit.zig");
const reg = @import("registros.zig");
const App = @import("../app.zig").App;

const gpa = std.heap.c_allocator;

const Row = struct { id: u32, time_ms: i64, kind: reg.EvKind, tag: []const u8, text: []u8 };

var rows: std.ArrayList(Row) = .empty;
var next_id: u32 = 1;
var shown: std.ArrayList(usize) = .empty;
var filter: [96]u8 = @splat(0);
var kinds = [_]bool{ true, true, true };
var selected: ?u32 = null;
var follow = true;
const max_rows = 6000;

fn pull() void {
    const first = reg.evs.first();
    if (first > next_id) next_id = first;
    reg.evs.eachFrom(next_id, {}, struct {
        fn f(_: void, e: *const reg.Ev) void {
            if (rows.items.len >= max_rows) {
                const drop = max_rows / 4;
                for (rows.items[0..drop]) |r| gpa.free(r.text);
                std.mem.copyForwards(Row, rows.items, rows.items[drop..]);
                rows.shrinkRetainingCapacity(rows.items.len - drop);
            }
            const text = gpa.dupe(u8, e.text) catch return;
            rows.append(gpa, .{ .id = e.id, .time_ms = e.time_ms, .kind = e.kind, .tag = e.tag, .text = text }) catch gpa.free(text);
            next_id = e.id +% 1;
        }
    }.f);
}

fn kindColor(k: reg.EvKind) kit.Rgba {
    return switch (k) {
        .action => kit.pal.info,
        .command => kit.pal.warn,
        .event => kit.pal.ok,
    };
}

fn kindName(k: reg.EvKind) []const u8 {
    return switch (k) {
        .action => i18n.tr("ação", "action"),
        .command => i18n.tr("comando", "command"),
        .event => i18n.tr("evento", "event"),
    };
}

pub fn draw(u: *kit.Ui, app: *App, r: kit.Rect) void {
    _ = app;
    pull();
    const bar_h: f32 = 30;
    kit.rect(u, .{ .x = r.x, .y = r.y, .w = r.w, .h = bar_h }, kit.pal.panel, 0);
    kit.hline(u, r.x, r.right(), r.y + bar_h - 1, kit.pal.line);
    var x = r.x + 4;
    if (kit.toolButton(u, .{ .x = x, .y = r.y + 2, .w = 26, .h = 26 }, .clear, false, i18n.tr("Limpar a lista", "Clear the list"))) {
        for (rows.items) |row| gpa.free(row.text);
        rows.clearRetainingCapacity();
        reg.evs.clear();
        selected = null;
    }
    x += 30;
    const fw = @min(220, r.w * 0.3);
    _ = kit.search(u, "##ev-filter", .{ .x = x, .y = r.y + 4, .w = fw, .h = bar_h - 8 }, &filter, i18n.trZ("Filtrar", "Filter"));
    x += fw + 8;
    const names = [_]struct { pt: []const u8, en: []const u8, tip_pt: []const u8, tip_en: []const u8 }{
        .{ .pt = "Ações", .en = "Actions", .tip_pt = "O que a interface pediu ao app", .tip_en = "What the interface asked the app" },
        .{ .pt = "Comandos", .en = "Commands", .tip_pt = "O que o app pediu à rede", .tip_en = "What the app asked the network" },
        .{ .pt = "Eventos", .en = "Events", .tip_pt = "O que chegou da rede", .tip_en = "What came from the network" },
    };
    for (names, 0..) |nm, k| {
        var count: u32 = 0;
        for (rows.items) |row| {
            if (@intFromEnum(row.kind) == k) count += 1;
        }
        const b = kit.chip(u, x, r.y + 6, bar_h - 12, i18n.tr(nm.pt, nm.en), kinds[k], count);
        if (b.clicked) kinds[k] = !kinds[k];
        if (u.over(.{ .x = x, .y = r.y, .w = b.w, .h = bar_h })) kit.tooltip(u, i18n.tr(nm.tip_pt, nm.tip_en));
        x += b.w + 4;
    }
    const q = kit.bufStr(&filter);
    shown.clearRetainingCapacity();
    for (rows.items, 0..) |row, i| {
        if (!kinds[@intFromEnum(row.kind)]) continue;
        if (q.len > 0 and !kit.has(row.tag, q) and !kit.has(row.text, q)) continue;
        shown.append(gpa, i) catch break;
    }
    const det_h: f32 = if (selected != null) @min(160, r.h * 0.35) else 0;
    const lr: kit.Rect = .{ .x = r.x, .y = r.y + bar_h, .w = r.w, .h = r.h - bar_h - det_h };
    const parent = u.dl;
    const rh: f32 = 20;
    const l = kit.beginList(u, "##ev-list", lr, shown.items.len, rh, follow, null);
    for (shown.items[l.first..l.last], l.first..) |ri, k| {
        const row = rows.items[ri];
        const y = l.y0 + @as(f32, @floatFromInt(k - l.first)) * rh;
        const rr: kit.Rect = .{ .x = lr.x, .y = y, .w = lr.w, .h = rh };
        const sel = selected == row.id;
        const over = u.over(rr);
        if (sel) kit.rect(u, rr, kit.pal.sel, 0) else if (over) kit.rect(u, rr, kit.pal.hover, 0);
        const ty = u.midCode(y, rh);
        var tb: [16]u8 = undefined;
        _ = u.code(lr.x + 8, ty, kit.pal.faint, kit.clock(&tb, row.time_ms));
        const bx = lr.x + 8 + u.codeW("00:00:00.000") + 10;
        const kn = kindName(row.kind);
        const bw = d.width(u.font, u.fs - 1.5, kn) + 10;
        kit.rect(u, .{ .x = bx, .y = y + 3, .w = bw, .h = rh - 6 }, kindColor(row.kind).alpha(0.18), 3);
        d.text(u.dl, u.font, u.fs - 1.5, bx + 5, y + 3 + (rh - 6 - (u.fs - 1.5) * 1.2) / 2, kindColor(row.kind), kn);
        var run: kit.Run = .{ .u = u, .x = bx + 76, .y = ty, .max_x = lr.right() - 6 };
        run.put(kit.pal.key, row.tag);
        run.put(kit.pal.faint, "  ");
        run.put(kit.pal.dim, row.text);
        if (over and c.ImGui_IsMouseClicked(0)) selected = if (sel) null else row.id;
    }
    if (shown.items.len == 0) {
        const msg = i18n.tr("Nada ainda: mexa no app (abra um canal, mande uma mensagem) e os eventos aparecem aqui.", "Nothing yet: use the app (open a channel, send a message) and the events show up here.");
        _ = u.clip(lr.x + 12, lr.y + 30, kit.pal.faint, msg, lr.w - 24);
    }
    follow = c.ImGui_GetScrollY() >= c.ImGui_GetScrollMaxY() - rh * 1.5;
    kit.endList(u, l, shown.items.len, rh, parent);
    // O escolhido inteiro, quebrado em linhas.
    if (selected) |id| {
        const dr: kit.Rect = .{ .x = r.x, .y = r.bottom() - det_h, .w = r.w, .h = det_h };
        kit.rect(u, dr, kit.pal.panel, 0);
        kit.hline(u, dr.x, dr.right(), dr.y, kit.pal.line);
        for (rows.items) |row| if (row.id == id) {
            var y = dr.y + 8;
            _ = u.textB(dr.x + 12, y, kindColor(row.kind), row.tag);
            const cp = kit.button(u, dr.right() - 90, dr.y + 5, 22, i18n.tr("Copiar", "Copy"), .copy);
            if (cp.clicked) kit.copyText(row.text);
            y += 24;
            var rest: []const u8 = row.text;
            while (rest.len > 0 and y < dr.bottom() - 14) {
                const k = @max(1, d.fitBytes(u.mono, u.ms, rest, dr.w - 24));
                _ = u.code(dr.x + 12, y, kit.pal.text, rest[0..k]);
                rest = rest[k..];
                y += u.ms * 1.4;
            }
            break;
        };
    }
}
