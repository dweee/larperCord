//! Pastas da barra de servidores mudadas aqui (arrastar, menus): cada mudança é uma
//! operação, aplicada na lista do jeito que o Discord guarda (`GuildFolders` das
//! configurações, net/settings_proto.zig). A mesma operação roda duas vezes: na tela,
//! na hora, e na rede, sobre as configurações lidas de novo (outro aparelho pode ter
//! mudado algo no meio: a operação vale sobre o que estiver lá, não sobre uma cópia
//! velha da lista inteira).
//!
//! Na lista, uma entrada sem id é um servidor solto (um só); uma com id é uma pasta.
//! Pasta que fica vazia some, como no cliente oficial. Servidores que a lista não
//! cita (entrou há pouco) aparecem no topo; mexendo em qualquer coisa, eles entram
//! na lista ali, como soltos.
const std = @import("std");
const types = @import("types.zig");
const Id = types.Id;

/// Nome de pasta mais longo que o app grava (em bytes, cortado sem partir um caractere).
pub const max_name = 100;

pub const Name = struct {
    buf: [max_name]u8 = undefined,
    len: u8 = 0,

    /// Sem espaços nas pontas e cortado em `max_name`.
    pub fn init(raw: []const u8) Name {
        const tr = std.mem.trim(u8, raw, " \t\r\n");
        var end = @min(tr.len, max_name);
        if (end < tr.len) while (end > 0 and (tr[end] & 0xC0) == 0x80) {
            end -= 1;
        };
        const s = std.mem.trimEnd(u8, tr[0..end], " ");
        var n: Name = .{ .len = @intCast(s.len) };
        @memcpy(n.buf[0..s.len], s);
        return n;
    }

    pub fn slice(n: *const Name) []const u8 {
        return n.buf[0..n.len];
    }
};

/// Uma coisa da barra: um servidor (solto, ou dentro da pasta de que se fala) ou uma pasta.
pub const Item = union(enum) { guild: Id, folder: u64 };

/// Onde entra: no começo, no fim, antes ou depois de algo do mesmo nível. Algo que
/// não está mais lá (outro aparelho tirou) vira o fim.
pub const Where = union(enum) { start, end, before: Item, after: Item };

pub const Op = union(enum) {
    /// Leva o servidor para a pasta `folder` (0 = solto na barra), no lugar `where`.
    move_guild: struct { guild: Id, folder: u64 = 0, where: Where = .end },
    /// Leva a pasta inteira para outro lugar da barra.
    move_folder: struct { folder: u64, where: Where },
    /// Servidor solto em cima de outro: pasta nova `folder` no lugar de `onto`, com os
    /// dois (`onto` primeiro). `onto` já numa pasta: o servidor entra nela, depois dele.
    merge: struct { guild: Id, onto: Id, folder: u64 },
    /// "Nova pasta": uma pasta `folder` só com o servidor, no lugar dele.
    new_folder: struct { guild: Id, folder: u64 },
    /// Tira o servidor da pasta: fica solto logo depois dela.
    ungroup: Id,
    /// Desfaz a pasta: os servidores ficam soltos, no lugar dela e na mesma ordem.
    remove_folder: u64,
    /// "Configurações da pasta": o nome e a cor (0xRRGGBB; 0 = sem cor). null = não
    /// muda (outro aparelho pode ter mudado o outro no meio).
    edit: struct { folder: u64, name: ?Name = null, color: ?u32 = null },
};

/// Id de pasta nova. A documentação não fixa uma convenção; um número positivo de até
/// 31 bits cabe em qualquer leitor (número do JavaScript, int32, int64) e não repete
/// o de nenhuma pasta que já existe.
pub fn newId(random: std.Random, folders: anytype) u64 {
    while (true) {
        const id = random.intRangeAtMost(u64, 1, std.math.maxInt(i32));
        for (folders) |f| {
            if (f.id == id) break;
        } else return id;
    }
}

const Entry = struct {
    /// 0 = servidor solto.
    id: u64,
    name: []u8,
    color: u32,
    guilds: std.ArrayList(Id),
    /// Já veio vazia (fora do normal): fica como veio. As que uma operação esvazia somem.
    keep_empty: bool = false,
};

/// A lista como dá para editar. Toda a memória vem de `gpa`.
pub const Model = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    /// `folders`: qualquer fatia de coisas com `id`, `name`, `color` e `guilds`.
    /// `known`: os servidores do app, na ordem dele; os que a lista não cita entram no
    /// começo, soltos (é onde a barra os mostra). Uma entrada sem id com vários
    /// servidores vira um solto para cada um.
    pub fn init(gpa: std.mem.Allocator, folders: anytype, known: []const Id) !Model {
        var m: Model = .{ .gpa = gpa };
        errdefer m.deinit();
        for (known) |g| {
            const listed = for (folders) |f| {
                if (std.mem.indexOfScalar(Id, f.guilds, g) != null) break true;
            } else false;
            if (!listed and m.find(g) == null) try m.insertLoose(m.entries.items.len, g);
        }
        for (folders) |f| {
            if (f.id == 0) {
                for (f.guilds) |g| try m.insertLoose(m.entries.items.len, g);
                continue;
            }
            try m.entries.ensureUnusedCapacity(gpa, 1);
            const name = try gpa.dupe(u8, f.name);
            errdefer gpa.free(name);
            var guilds: std.ArrayList(Id) = .empty;
            try guilds.appendSlice(gpa, f.guilds);
            m.entries.appendAssumeCapacity(.{ .id = f.id, .name = name, .color = f.color, .guilds = guilds, .keep_empty = f.guilds.len == 0 });
        }
        return m;
    }

    pub fn deinit(m: *Model) void {
        for (m.entries.items) |*e| freeEntry(m.gpa, e);
        m.entries.deinit(m.gpa);
    }

    fn freeEntry(gpa: std.mem.Allocator, e: *Entry) void {
        gpa.free(e.name);
        e.guilds.deinit(gpa);
    }

    fn insertLoose(m: *Model, at: usize, g: Id) !void {
        var guilds: std.ArrayList(Id) = .empty;
        errdefer guilds.deinit(m.gpa);
        try guilds.append(m.gpa, g);
        const name = try m.gpa.alloc(u8, 0);
        errdefer m.gpa.free(name);
        try m.entries.insert(m.gpa, at, .{ .id = 0, .name = name, .color = 0, .guilds = guilds });
    }

    const Pos = struct { entry: usize, index: usize };

    fn find(m: *const Model, g: Id) ?Pos {
        for (m.entries.items, 0..) |e, i| {
            if (std.mem.indexOfScalar(Id, e.guilds.items, g)) |k| return .{ .entry = i, .index = k };
        }
        return null;
    }

    fn folderIndex(m: *const Model, id: u64) ?usize {
        if (id == 0) return null;
        for (m.entries.items, 0..) |e, i| if (e.id == id) return i;
        return null;
    }

    /// A entrada do nível de cima que é `it` (um solto ou uma pasta).
    fn topIndex(m: *const Model, it: Item) ?usize {
        return switch (it) {
            .folder => |id| m.folderIndex(id),
            .guild => |g| for (m.entries.items, 0..) |e, i| {
                if (e.id == 0 and std.mem.indexOfScalar(Id, e.guilds.items, g) != null) break i;
            } else null,
        };
    }

    fn topSlot(m: *const Model, where: Where) usize {
        const n = m.entries.items.len;
        return switch (where) {
            .start => 0,
            .end => n,
            .before => |it| m.topIndex(it) orelse n,
            .after => |it| if (m.topIndex(it)) |i| i + 1 else n,
        };
    }

    fn innerSlot(e: *const Entry, where: Where) usize {
        const n = e.guilds.items.len;
        return switch (where) {
            .start => 0,
            .end => n,
            .before => |it| switch (it) {
                .guild => |g| std.mem.indexOfScalar(Id, e.guilds.items, g) orelse n,
                .folder => n,
            },
            .after => |it| switch (it) {
                .guild => |g| if (std.mem.indexOfScalar(Id, e.guilds.items, g)) |k| k + 1 else n,
                .folder => n,
            },
        };
    }

    /// Tira o servidor de onde estiver (de todo lugar, se aparecer repetido). A
    /// entrada que ficar vazia continua lá até `sweep`: a operação ainda pode querer
    /// o lugar dela.
    fn pull(m: *Model, g: Id) void {
        for (m.entries.items) |*e| {
            var k: usize = 0;
            while (k < e.guilds.items.len) {
                if (e.guilds.items[k] == g) _ = e.guilds.orderedRemove(k) else k += 1;
            }
        }
    }

    /// Some com as entradas que a operação esvaziou (soltos tirados, pastas que esvaziaram).
    fn sweep(m: *Model) void {
        var i: usize = 0;
        while (i < m.entries.items.len) {
            const e = &m.entries.items[i];
            if (e.guilds.items.len == 0 and !e.keep_empty) {
                freeEntry(m.gpa, e);
                _ = m.entries.orderedRemove(i);
            } else i += 1;
        }
    }

    fn moveGuild(m: *Model, g: Id, folder: u64, where: Where) !void {
        if (folder != 0 and m.folderIndex(folder) == null) return;
        // Antes ou depois de si mesmo: nada muda.
        switch (where) {
            .before, .after => |it| if (it == .guild and it.guild == g) return,
            else => {},
        }
        m.pull(g);
        if (folder == 0) {
            try m.insertLoose(m.topSlot(where), g);
        } else {
            const e = &m.entries.items[m.folderIndex(folder).?];
            try e.guilds.insert(m.gpa, innerSlot(e, where), g);
        }
    }

    pub fn apply(m: *Model, op: Op) !void {
        defer m.sweep();
        switch (op) {
            .move_guild => |mg| try m.moveGuild(mg.guild, mg.folder, mg.where),
            .move_folder => |mf| {
                const i = m.folderIndex(mf.folder) orelse return;
                switch (mf.where) {
                    .before, .after => |it| if (it == .folder and it.folder == mf.folder) return,
                    else => {},
                }
                try m.entries.ensureUnusedCapacity(m.gpa, 1);
                const e = m.entries.orderedRemove(i);
                m.entries.insertAssumeCapacity(m.topSlot(mf.where), e);
            },
            .merge => |mg| {
                if (mg.guild == mg.onto) return;
                const at = m.find(mg.onto) orelse return;
                const host = m.entries.items[at.entry].id;
                if (host != 0) return m.moveGuild(mg.guild, host, .{ .after = .{ .guild = mg.onto } });
                // A pasta já existe (a mesma operação aplicada de novo): entra nela.
                if (m.folderIndex(mg.folder) != null) return m.moveGuild(mg.guild, mg.folder, .{ .after = .{ .guild = mg.onto } });
                try m.entries.items[at.entry].guilds.ensureUnusedCapacity(m.gpa, 1);
                m.pull(mg.guild);
                const i = m.topIndex(.{ .guild = mg.onto }) orelse return;
                const e = &m.entries.items[i];
                // O solto vira a pasta: mesmo lugar, com o outro servidor depois.
                e.guilds.appendAssumeCapacity(mg.guild);
                e.id = mg.folder;
            },
            .new_folder => |nf| {
                if (m.folderIndex(nf.folder) != null) return m.moveGuild(nf.guild, nf.folder, .end);
                const at = m.find(nf.guild) orelse return;
                if (m.entries.items[at.entry].id == 0) {
                    m.entries.items[at.entry].id = nf.folder;
                    return;
                }
                m.pull(nf.guild);
                try m.insertLoose(at.entry + 1, nf.guild);
                m.entries.items[at.entry + 1].id = nf.folder;
            },
            .ungroup => |g| {
                const at = m.find(g) orelse return;
                const host = m.entries.items[at.entry].id;
                if (host == 0) return;
                try m.moveGuild(g, 0, .{ .after = .{ .folder = host } });
            },
            .remove_folder => |id| {
                const i = m.folderIndex(id) orelse return;
                const e = &m.entries.items[i];
                // A pasta vira o primeiro solto; os outros entram logo depois dela.
                const rest = e.guilds.items.len -| 1;
                try m.entries.ensureUnusedCapacity(m.gpa, rest);
                var k: usize = 0;
                while (k < rest) : (k += 1) {
                    const g = m.entries.items[i].guilds.items[1 + k];
                    try m.insertLoose(i + 1 + k, g);
                }
                const f = &m.entries.items[i];
                f.guilds.shrinkRetainingCapacity(@min(f.guilds.items.len, 1));
                f.id = 0;
                f.color = 0;
                f.keep_empty = false;
            },
            .edit => |ed| {
                const i = m.folderIndex(ed.folder) orelse return;
                const e = &m.entries.items[i];
                if (ed.name) |nm| {
                    const name = try m.gpa.dupe(u8, nm.slice());
                    m.gpa.free(e.name);
                    e.name = name;
                }
                if (ed.color) |col| e.color = col & 0xFFFFFF;
            },
        }
    }

    /// A lista pronta: cada solto como entrada própria, sem id. Nomes e servidores
    /// alocados um a um com `gpa` (o Store solta assim).
    pub fn toFolders(m: *const Model, gpa: std.mem.Allocator) ![]types.GuildFolder {
        const out = try gpa.alloc(types.GuildFolder, m.entries.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |f| {
                gpa.free(f.name);
                gpa.free(f.guilds);
            }
            gpa.free(out);
        }
        for (m.entries.items) |e| {
            const name = try gpa.dupe(u8, if (e.id == 0) "" else e.name);
            errdefer gpa.free(name);
            const guilds = try gpa.dupe(Id, e.guilds.items);
            out[n] = .{ .id = e.id, .name = name, .color = if (e.id == 0) 0 else e.color, .guilds = guilds };
            n += 1;
        }
        return out;
    }
};

/// `folders` com as operações aplicadas (ver `Model.init` para `known`).
pub fn applyAll(gpa: std.mem.Allocator, folders: anytype, known: []const Id, ops: []const Op) ![]types.GuildFolder {
    var m = try Model.init(gpa, folders, known);
    defer m.deinit();
    for (ops) |op| try m.apply(op);
    return m.toFolders(gpa);
}

pub fn freeFolders(gpa: std.mem.Allocator, list: []const types.GuildFolder) void {
    for (list) |f| {
        gpa.free(f.name);
        gpa.free(f.guilds);
    }
    gpa.free(list);
}

/// O código de uma cor (6 dígitos hexadecimais, com ou sem #). 000000 = sem cor.
pub fn parseHex(text: []const u8) ?u32 {
    const h = std.mem.trimStart(u8, std.mem.trim(u8, text, " "), "#");
    if (h.len != 6) return null;
    return std.fmt.parseInt(u32, h, 16) catch null;
}

/// As duas listas mostram a mesma barra (mesmas pastas, nomes, cores e ordem).
pub fn same(a: anytype, b: anytype) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.id != y.id or x.color != y.color or !std.mem.eql(u8, x.name, y.name) or !std.mem.eql(Id, x.guilds, y.guilds)) return false;
    }
    return true;
}

/// A pasta onde o servidor está (0 = solto ou fora da lista).
pub fn folderOf(folders: anytype, g: Id) u64 {
    for (folders) |f| if (f.id != 0 and std.mem.indexOfScalar(Id, f.guilds, g) != null) return f.id;
    return 0;
}

// ---------------------------------------------------------------------------

const t = std.testing;

fn sample() [5]types.GuildFolder {
    return .{
        .{ .id = 0, .name = "", .color = 0, .guilds = &.{1} },
        .{ .id = 10, .name = "Jogos", .color = 0xFF0000, .guilds = &.{ 2, 3 } },
        .{ .id = 0, .name = "", .color = 0, .guilds = &.{4} },
        .{ .id = 20, .name = "", .color = 0, .guilds = &.{5} },
        .{ .id = 0, .name = "", .color = 0, .guilds = &.{6} },
    };
}

/// A barra em texto: `1 [10:2,3] 4 [20:5] 6`.
fn shape(buf: []u8, list: []const types.GuildFolder) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    for (list, 0..) |f, i| {
        if (i > 0) w.writeAll(" ") catch {};
        if (f.id == 0) {
            for (f.guilds, 0..) |g, k| w.print("{s}{d}", .{ if (k > 0) "," else "", g }) catch {};
        } else {
            w.print("[{d}:", .{f.id}) catch {};
            for (f.guilds, 0..) |g, k| w.print("{s}{d}", .{ if (k > 0) "," else "", g }) catch {};
            w.writeAll("]") catch {};
        }
    }
    return w.buffered();
}

fn expectShape(want: []const u8, ops: []const Op) !void {
    const s = sample();
    const out = try applyAll(t.allocator, &s, &.{ 1, 2, 3, 4, 5, 6 }, ops);
    defer freeFolders(t.allocator, out);
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings(want, shape(&buf, out));
}

test "arrastar servidores e pastas" {
    // Servidor em cima de outro: pasta nova no lugar do de baixo, ele primeiro.
    try expectShape("[10:2,3] [99:4,1] [20:5] 6", &.{.{ .merge = .{ .guild = 1, .onto = 4, .folder = 99 } }});
    // Em cima de um que já está numa pasta: entra nela, depois dele.
    try expectShape("1 [10:2,6,3] 4 [20:5]", &.{.{ .merge = .{ .guild = 6, .onto = 2, .folder = 99 } }});
    // Para dentro, para fora, reordenar.
    try expectShape("1 [10:2,3,4] [20:5] 6", &.{.{ .move_guild = .{ .guild = 4, .folder = 10 } }});
    try expectShape("1 [10:3] 4 [20:5] 6 2", &.{.{ .move_guild = .{ .guild = 2 } }});
    try expectShape("1 [10:3,2] 4 [20:5] 6", &.{.{ .move_guild = .{ .guild = 2, .folder = 10, .where = .end } }});
    try expectShape("6 1 [10:2,3] 4 [20:5]", &.{.{ .move_guild = .{ .guild = 6, .where = .{ .before = .{ .guild = 1 } } } }});
    try expectShape("1 [10:2,3] 6 4 [20:5]", &.{.{ .move_guild = .{ .guild = 6, .where = .{ .after = .{ .folder = 10 } } } }});
    try expectShape("[20:5] 1 [10:2,3] 4 6", &.{.{ .move_folder = .{ .folder = 20, .where = .start } }});
    try expectShape("1 4 [10:2,3] [20:5] 6", &.{.{ .move_folder = .{ .folder = 10, .where = .{ .after = .{ .guild = 4 } } } }});
    // O último servidor saiu: a pasta some.
    try expectShape("1 [10:2,3] 4 6 5", &.{.{ .move_guild = .{ .guild = 5, .where = .end } }});
    // Tirar da pasta: solto logo depois dela.
    try expectShape("1 [10:3] 2 4 [20:5] 6", &.{.{ .ungroup = 2 }});
    try expectShape("1 [10:2,3] 4 5 6", &.{.{ .ungroup = 5 }});
    // Desfazer a pasta: os servidores no lugar dela, na ordem.
    try expectShape("1 2 3 4 [20:5] 6", &.{.{ .remove_folder = 10 }});
    // Nova pasta só com ele: no lugar dele; dentro de outra pasta, logo depois dela.
    try expectShape("1 [10:2,3] [7:4] [20:5] 6", &.{.{ .new_folder = .{ .guild = 4, .folder = 7 } }});
    try expectShape("1 [10:2] [7:3] 4 [20:5] 6", &.{.{ .new_folder = .{ .guild = 3, .folder = 7 } }});
    // Coisas que não mudam nada (ou não existem mais): a lista fica como estava.
    try expectShape("1 [10:2,3] 4 [20:5] 6", &.{
        .{ .merge = .{ .guild = 4, .onto = 4, .folder = 99 } },
        .{ .move_guild = .{ .guild = 4, .where = .{ .before = .{ .guild = 4 } } } },
        .{ .move_guild = .{ .guild = 4, .folder = 555 } },
        .{ .move_folder = .{ .folder = 10, .where = .{ .after = .{ .folder = 10 } } } },
        .{ .remove_folder = 555 },
        .{ .ungroup = 1 },
        .{ .merge = .{ .guild = 1, .onto = 777, .folder = 99 } },
    });
    // A mesma fusão aplicada duas vezes (a tela e depois a rede): o mesmo resultado.
    try expectShape("[10:2,3] [99:4,1] [20:5] 6", &.{
        .{ .merge = .{ .guild = 1, .onto = 4, .folder = 99 } },
        .{ .merge = .{ .guild = 1, .onto = 4, .folder = 99 } },
    });
    // Um lugar que sumiu (outro aparelho) vira o fim.
    try expectShape("1 [10:2,3] [20:5] 6 4", &.{.{ .move_guild = .{ .guild = 4, .where = .{ .before = .{ .guild = 999 } } } }});
}

test "nome e cor da pasta" {
    const s = sample();
    const out = try applyAll(t.allocator, &s, &.{}, &.{
        .{ .edit = .{ .folder = 10, .name = Name.init("  Trabalho  ") } },
        .{ .edit = .{ .folder = 10, .color = 0x123456 } },
        .{ .edit = .{ .folder = 20, .name = Name.init("x"), .color = 0xABCDEF } },
        .{ .edit = .{ .folder = 20, .name = Name.init(""), .color = 0 } },
    });
    defer freeFolders(t.allocator, out);
    try t.expectEqualStrings("Trabalho", out[1].name);
    try t.expectEqual(@as(u32, 0x123456), out[1].color);
    try t.expectEqualStrings("", out[3].name);
    try t.expectEqual(@as(u32, 0), out[3].color);
    // Nome comprido: cortado sem partir o "é".
    const a99: [99]u8 = @splat('a');
    const n = Name.init(&a99 ++ "é");
    try t.expectEqual(@as(usize, 99), n.slice().len);
}

test "servidores fora da lista entram no começo, soltos" {
    const s = sample();
    const out = try applyAll(t.allocator, &s, &.{ 8, 1, 2, 9 }, &.{.{ .ungroup = 5 }});
    defer freeFolders(t.allocator, out);
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("8 9 1 [10:2,3] 4 5 6", shape(&buf, out));
    // Solto com vários servidores (fora do normal): um para cada.
    const odd = [_]types.GuildFolder{.{ .id = 0, .name = "", .color = 0, .guilds = &.{ 1, 2 } }};
    const o2 = try applyAll(t.allocator, &odd, &.{}, &.{.{ .move_guild = .{ .guild = 1 } }});
    defer freeFolders(t.allocator, o2);
    try t.expectEqualStrings("2 1", shape(&buf, o2));
}

test "id de pasta nova: positivo, 31 bits, sem repetir" {
    var prng = std.Random.DefaultPrng.init(7);
    const s = sample();
    for (0..200) |_| {
        const id = newId(prng.random(), &s);
        try t.expect(id >= 1 and id <= std.math.maxInt(i32));
        try t.expect(id != 10 and id != 20);
    }
    try t.expectEqual(@as(u64, 10), folderOf(&s, 3));
    try t.expectEqual(@as(u64, 0), folderOf(&s, 4));
}

test "código da cor" {
    try t.expectEqual(@as(?u32, 0x5865F2), parseHex("#5865f2"));
    try t.expectEqual(@as(?u32, 0xABCDEF), parseHex("ABCDEF"));
    try t.expectEqual(@as(?u32, 0), parseHex("000000"));
    try t.expectEqual(@as(?u32, null), parseHex("12345"));
    try t.expectEqual(@as(?u32, null), parseHex("zzzzzz"));
}

fn applyAndFree(a: std.mem.Allocator) !void {
    const s = sample();
    const out = try applyAll(a, &s, &.{ 8, 1 }, &.{
        .{ .merge = .{ .guild = 1, .onto = 4, .folder = 99 } },
        .{ .remove_folder = 10 },
        .{ .new_folder = .{ .guild = 6, .folder = 7 } },
        .{ .edit = .{ .folder = 7, .name = Name.init("n") } },
        .{ .move_folder = .{ .folder = 20, .where = .start } },
    });
    freeFolders(a, out);
}

test "sem vazamento quando falta memória" {
    try t.checkAllAllocationFailures(t.allocator, applyAndFree, .{});
}
