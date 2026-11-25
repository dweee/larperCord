//! Árvore de JSON que abre e fecha, como a do navegador: chaves, textos, números e
//! booleanos cada um na sua cor, um resumo do que está fechado (`{op: 0, t: "READY", …}`,
//! `Array(12)`), busca que abre o caminho até o que achou, e clique para copiar o valor
//! (ou o pedaço inteiro). Usada nos quadros do gateway, nas respostas da API e nos eventos.
const std = @import("std");
const c = @import("c");
const kit = @import("kit.zig");
const d = @import("../ui/draw.zig");
const i18n = @import("../ui/i18n.zig");

const gpa = std.heap.c_allocator;
const Value = std.json.Value;

const Row = struct {
    depth: u8,
    key: []const u8,
    index: ?usize,
    value: *const Value,
    path: u64,
    open: bool,
};

pub const View = struct {
    arena: ?std.heap.ArenaAllocator = null,
    root: ?*Value = null,
    raw: []u8 = &.{},
    src: u64 = 0,
    failed: bool = false,
    open: std.AutoHashMapUnmanaged(u64, void) = .empty,
    rows: std.ArrayList(Row) = .empty,
    find: [96]u8 = @splat(0),
    raw_mode: bool = false,
    /// Linhas abertas por padrão ao carregar (o primeiro nível sempre).
    auto_depth: u8 = 1,

    pub fn reset(v: *View) void {
        if (v.arena) |*a| a.deinit();
        v.arena = null;
        v.root = null;
        if (v.raw.len > 0) gpa.free(v.raw);
        v.raw = &.{};
        v.open.clearRetainingCapacity();
        v.failed = false;
        v.src = 0;
    }

    /// Mostra `text` (copiado), identificado por `src`: o mesmo src não carrega de novo.
    pub fn load(v: *View, src: u64, text: []const u8) void {
        if (src == v.src and (v.root != null or v.failed)) return;
        v.reset();
        v.src = src;
        v.raw = gpa.dupe(u8, text) catch &.{};
        v.arena = std.heap.ArenaAllocator.init(gpa);
        const a = v.arena.?.allocator();
        const parsed = std.json.parseFromSliceLeaky(Value, a, v.raw, .{ .duplicate_field_behavior = .use_last }) catch {
            v.failed = true;
            return;
        };
        const p = a.create(Value) catch return;
        p.* = parsed;
        v.root = p;
        v.openDefault(p, 0, 1, 0);
    }

    fn openDefault(v: *View, val: *const Value, depth: u8, path: u64, count: usize) void {
        if (depth >= v.auto_depth or count > 200) return;
        v.open.put(gpa, path, {}) catch return;
        switch (val.*) {
            .object => |o| {
                var it = o.iterator();
                var i: usize = 0;
                while (it.next()) |e| : (i += 1) {
                    if (i > 60) break;
                    v.openDefault(e.value_ptr, depth + 1, childPath(path, e.key_ptr.*, null), count + i);
                }
            },
            else => {},
        }
    }

    pub fn deinit(v: *View) void {
        v.reset();
        v.open.deinit(gpa);
        v.rows.deinit(gpa);
    }
};

fn childPath(parent: u64, key: []const u8, index: ?usize) u64 {
    var h = std.hash.Wyhash.init(parent);
    h.update(key);
    if (index) |i| h.update(std.mem.asBytes(&i));
    return h.final() | 1;
}

fn collectRows(v: *View, val: *const Value, depth: u8, key: []const u8, index: ?usize, path: u64) void {
    if (v.rows.items.len >= 50_000) return;
    const is_open = v.open.contains(path);
    v.rows.append(gpa, .{ .depth = depth, .key = key, .index = index, .value = val, .path = path, .open = is_open }) catch return;
    if (!is_open) return;
    switch (val.*) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| collectRows(v, e.value_ptr, depth + 1, e.key_ptr.*, null, childPath(path, e.key_ptr.*, null));
        },
        .array => |arr| for (arr.items, 0..) |*item, i| {
            collectRows(v, item, depth + 1, "", i, childPath(path, "", i));
        },
        else => {},
    }
}

/// Abre o caminho até cada valor (ou chave) que tem `needle`. Devolve quantos achou.
fn openMatches(v: *View, val: *const Value, path: u64, needle: []const u8, depth: u8) usize {
    if (depth > 24) return 0;
    var found: usize = 0;
    switch (val.*) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                const cp = childPath(path, e.key_ptr.*, null);
                var here = if (kit.has(e.key_ptr.*, needle)) @as(usize, 1) else 0;
                here += openMatches(v, e.value_ptr, cp, needle, depth + 1);
                if (here > 0) v.open.put(gpa, path, {}) catch {};
                found += here;
            }
        },
        .array => |arr| for (arr.items, 0..) |*item, i| {
            const cp = childPath(path, "", i);
            const here = openMatches(v, item, cp, needle, depth + 1);
            if (here > 0) v.open.put(gpa, path, {}) catch {};
            found += here;
        },
        .string => |s| if (kit.has(s, needle)) {
            found += 1;
        },
        else => {},
    }
    return found;
}

fn preview(w: *std.Io.Writer, val: *const Value, depth: u8) void {
    switch (val.*) {
        .null => w.writeAll("null") catch {},
        .bool => |b| w.writeAll(if (b) "true" else "false") catch {},
        .integer => |n| kit.say(w, "{d}", &.{ kit.arg(n) }) catch {},
        .float => |f| kit.say(w, "{d}", &.{ kit.arg(f) }) catch {},
        .number_string => |s| w.writeAll(s) catch {},
        .string => |s| {
            w.writeByte('"') catch {};
            w.writeAll(s[0..@min(s.len, 80)]) catch {};
            if (s.len > 80) w.writeAll("…") catch {};
            w.writeByte('"') catch {};
        },
        .array => |a| if (depth > 0) {
            kit.say(w, "Array({d})", &.{ kit.arg(a.items.len) }) catch {};
        } else {
            kit.say(w, "Array({d}) [", &.{ kit.arg(a.items.len) }) catch {};
            for (a.items[0..@min(a.items.len, 4)], 0..) |*it, i| {
                if (i > 0) w.writeAll(", ") catch {};
                preview(w, it, depth + 1);
            }
            if (a.items.len > 4) w.writeAll(", …") catch {};
            w.writeAll("]") catch {};
        },
        .object => |o| if (depth > 0) {
            w.writeAll("{…}") catch {};
        } else {
            w.writeAll("{") catch {};
            var it = o.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) {
                if (i == 5) {
                    w.writeAll(", …") catch {};
                    break;
                }
                if (i > 0) w.writeAll(", ") catch {};
                kit.say(w, "{s}: ", &.{ kit.arg(e.key_ptr.*) }) catch {};
                preview(w, e.value_ptr, depth + 1);
            }
            w.writeAll("}") catch {};
        },
    }
}

fn valueColor(val: *const Value) kit.Rgba {
    return switch (val.*) {
        .string => kit.pal.str,
        .integer, .float, .number_string => kit.pal.num,
        .bool => kit.pal.num,
        .null => kit.pal.faint,
        else => kit.pal.dim,
    };
}

/// O valor como JSON compacto (para copiar).
fn stringify(val: *const Value) ?[]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    std.json.Stringify.value(val.*, .{ .whitespace = .indent_2 }, &out.writer) catch {
        out.deinit();
        return null;
    };
    return out.toOwnedSlice() catch null;
}

/// Desenha a árvore em `r`. `id` é o nome da região de rolagem.
pub fn draw(u: *kit.Ui, v: *View, id: [*:0]const u8, r: kit.Rect) void {
    const parent = u.dl;
    // Barra: busca, cru/árvore, copiar tudo.
    const bar_h: f32 = 28;
    kit.rect(u, .{ .x = r.x, .y = r.y, .w = r.w, .h = bar_h }, kit.pal.toolbar, 0);
    kit.hline(u, r.x, r.right(), r.y + bar_h - 1, kit.pal.line);
    var x = r.x + 6;
    const sw = @min(220, r.w * 0.45);
    var find_id_buf: [64]u8 = undefined;
    const find_id = kit.bufSayZ(&find_id_buf, "##jfind{s}", &.{ kit.arg(std.mem.span(id)) }) orelse "##jfind";
    if (kit.search(u, find_id.ptr, .{ .x = x, .y = r.y + 4, .w = sw, .h = bar_h - 8 }, &v.find, i18n.trZ("Buscar no JSON", "Search JSON"))) {
        if (v.root) |root| if (kit.bufStr(&v.find).len > 0) {
            _ = openMatches(v, root, 1, kit.bufStr(&v.find), 0);
        };
    }
    x += sw + 8;
    const mode = kit.chip(u, x, r.y + 5, bar_h - 10, if (v.raw_mode) i18n.tr("Texto", "Raw") else i18n.tr("Árvore", "Tree"), v.raw_mode, null);
    if (mode.clicked) v.raw_mode = !v.raw_mode;
    x += mode.w + 6;
    const cp = kit.button(u, x, r.y + 4, bar_h - 8, i18n.tr("Copiar", "Copy"), .copy);
    if (cp.clicked) {
        if (v.root) |root| {
            if (stringify(root)) |s| {
                defer gpa.free(s);
                kit.copyLong(s);
            }
        } else kit.copyLong(v.raw);
    }
    var sb: [32]u8 = undefined;
    const size_s = kit.bytesText(&sb, v.raw.len);
    _ = u.text(r.right() - u.textW(size_s) - 8, u.mid(r.y, bar_h), kit.pal.faint, size_s);

    const body: kit.Rect = .{ .x = r.x, .y = r.y + bar_h, .w = r.w, .h = r.h - bar_h };
    if (v.raw_mode or v.failed or v.root == null) {
        rawText(u, v, id, body);
        return;
    }
    v.rows.clearRetainingCapacity();
    collectRows(v, v.root.?, 0, "", null, 1);
    const rh: f32 = 18;
    const l = kit.beginList(u, id, body, v.rows.items.len, rh, false, null);
    const needle = kit.bufStr(&v.find);
    for (v.rows.items[l.first..l.last], l.first..) |row, i| {
        const y = l.y0 + @as(f32, @floatFromInt(i - l.first)) * rh;
        const rr: kit.Rect = .{ .x = body.x, .y = y, .w = body.w, .h = rh };
        const over = u.over(rr);
        if (over) kit.rect(u, rr, kit.pal.hover, 0);
        const ix = body.x + 8 + @as(f32, @floatFromInt(row.depth)) * 14;
        const container = row.value.* == .object or row.value.* == .array;
        if (container) kit.icon(u.dl, if (row.open) .chevron_d else .chevron_r, ix + 4, y + rh / 2, kit.pal.dim);
        var run: kit.Run = .{ .u = u, .x = ix + 12, .y = u.midCode(y, rh), .max_x = body.right() - 6 };
        if (row.index) |n| {
            run.say(kit.pal.faint, "{d}", &.{ kit.arg(n) });
            run.put(kit.pal.dim, ": ");
        } else if (row.depth > 0) {
            const hit_key = needle.len > 0 and kit.has(row.key, needle);
            if (hit_key) kit.rect(u, .{ .x = run.x - 1, .y = y + 2, .w = u.codeW(row.key) + 2, .h = rh - 4 }, kit.pal.warn.alpha(0.35), 2);
            run.put(kit.pal.key, row.key);
            run.put(kit.pal.dim, ": ");
        }
        var pb: [512]u8 = undefined;
        var pw = std.Io.Writer.fixed(&pb);
        preview(&pw, row.value, if (row.open) 1 else 0);
        const shown = if (container and row.open) (if (row.value.* == .array) blk: {
            var ab: [32]u8 = undefined;
            break :blk kit.bufSay(&ab, "Array({d})", &.{ kit.arg(row.value.array.items.len) }) orelse "";
        } else "{…}") else pw.buffered();
        if (needle.len > 0 and row.value.* == .string and kit.has(row.value.string, needle))
            kit.rect(u, .{ .x = run.x - 1, .y = y + 2, .w = @min(u.codeW(shown), run.max_x - run.x) + 2, .h = rh - 4 }, kit.pal.warn.alpha(0.35), 2);
        run.put(if (container) kit.pal.dim else valueColor(row.value), shown);
        if (over) {
            c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
            if (c.ImGui_IsMouseClicked(0)) {
                if (container) {
                    if (row.open) _ = v.open.remove(row.path) else v.open.put(gpa, row.path, {}) catch {};
                } else if (row.value.* == .string) kit.copyText(row.value.string) else kit.copyText(pw.buffered());
            }
            // Botão direito: copia o pedaço inteiro como JSON.
            if (c.ImGui_IsMouseClicked(1)) if (stringify(row.value)) |s| {
                defer gpa.free(s);
                kit.copyLong(s);
            };
        }
    }
    kit.endList(u, l, v.rows.items.len, rh, parent);
}

/// O texto cru, quebrado em linhas (um JSON que não abriu, ou o modo "Texto").
fn rawText(u: *kit.Ui, v: *View, id: [*:0]const u8, r: kit.Rect) void {
    const parent = u.dl;
    var y = kit.beginPane(u, id, r);
    const font = u.mono;
    const max_w = r.w - 16;
    var rest: []const u8 = v.raw;
    var lines: usize = 0;
    while (rest.len > 0 and lines < 4000) : (lines += 1) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        var line = rest[0..nl];
        rest = if (nl < rest.len) rest[nl + 1 ..] else rest[rest.len..];
        while (true) {
            const n = if (line.len == 0) 0 else @max(1, d.fitBytes(font, u.ms, line, max_w));
            if (y > r.y - 40 and y < r.bottom() + 20) d.text(u.dl, font, u.ms, r.x + 8, y, kit.pal.text, line[0..n]);
            y += u.ms * 1.35;
            line = line[n..];
            if (line.len == 0) break;
        }
    }
    kit.endPane(u, r, y, parent);
}

const t = std.testing;

test "árvore: o primeiro nível aberto, resumo do que está fechado" {
    var v: View = .{};
    defer v.deinit();
    v.load(7, "{\"op\":0,\"t\":\"READY\",\"d\":{\"v\":9,\"guilds\":[1,2,3]}}");
    try t.expect(v.root != null);
    v.rows.clearRetainingCapacity();
    collectRows(&v, v.root.?, 0, "", null, 1);
    // A raiz aberta mostra op, t e d (d fechado).
    try t.expectEqual(@as(usize, 4), v.rows.items.len);
    try t.expectEqualStrings("d", v.rows.items[3].key);
    var b: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&b);
    preview(&w, v.rows.items[3].value, 0);
    try t.expectEqualStrings("{v: 9, guilds: Array(3)}", w.buffered());
    // Carregar o mesmo de novo não refaz nada; outro src, sim.
    const root = v.root;
    v.load(7, "{}");
    try t.expectEqual(root, v.root);
}

test "busca abre o caminho até o valor" {
    var v: View = .{};
    defer v.deinit();
    v.load(1, "{\"a\":{\"b\":{\"c\":\"agulha aqui\"}},\"x\":1}");
    try t.expectEqual(@as(usize, 1), openMatches(&v, v.root.?, 1, "AGULHA", 0));
    v.rows.clearRetainingCapacity();
    collectRows(&v, v.root.?, 0, "", null, 1);
    var achou = false;
    for (v.rows.items) |r| if (std.mem.eql(u8, r.key, "c")) {
        achou = true;
    };
    try t.expect(achou);
}

test "JSON quebrado: fica o texto" {
    var v: View = .{};
    defer v.deinit();
    v.load(2, "{\"op\":0,");
    try t.expect(v.failed);
    try t.expectEqualStrings("{\"op\":0,", v.raw);
}
