//! Pastas e ordem dos servidores a partir do READY (sem dependências, testado
//! no `zig build test`). Contas de usuário recebem `user_settings_proto`: o
//! protobuf `PreloadedUserSettings` em base64 (discord-protos). Só lemos o
//! campo 14, `guild_folders`:
//!
//!   GuildFolders { repeated GuildFolder folders = 1; repeated fixed64 guild_positions = 2; }
//!   GuildFolder  { repeated fixed64 guild_ids = 1; Int64Value id = 2;
//!                  StringValue name = 3; UInt64Value color = 4; }
//!
//! (os "wrappers" do google.protobuf são mensagens com o valor no campo 1).
//! Algumas contas ainda recebem a forma antiga em JSON,
//! `user_settings.guild_folders`; `fromJson` lê essa.
//!
//! Escrever (pastas mudadas aqui, core/pastas.zig): `edit` aplica as operações nas
//! configurações inteiras e troca só o campo 14; todo o resto sai byte a byte como
//! entrou. Dentro do 14, a pasta que não mudou também sai como veio, e a que mudou
//! leva junto os campos que o app não conhece. Qualquer parte que não dê para ler
//! inteira dá erro antes de montar a saída: melhor não gravar do que estragar.
//! O PATCH leva só o campo 14 (`patchBody`): o Discord troca o campo de cima inteiro
//! que vier e deixa os outros como estão.
const std = @import("std");
const jsonx = @import("jsonx.zig");
const pastas = @import("../core/pastas.zig");

pub const Error = error{
    /// A mensagem acaba no meio de um campo.
    Truncated,
    /// Tipo de fio inválido, varint longo demais, campo 0 etc.
    Malformed,
    InvalidBase64,
    OutOfMemory,
};

/// Uma entrada da barra de servidores. `id == 0` (sem id) é como o Discord
/// guarda um servidor solto, fora de pasta: normalmente com um servidor só.
pub const Folder = struct {
    id: u64,
    /// Vazio = sem nome (o cliente oficial mostra os nomes dos servidores).
    name: []const u8,
    /// 0xRRGGBB; 0 = sem cor.
    color: u32,
    guilds: []const u64,

    /// Servidores soltos: desenhar cada um como ícone normal, sem pasta.
    pub fn isLoose(f: Folder) bool {
        return f.id == 0;
    }
};

/// Toda a memória vem do alocador passado; liberar com `deinit`.
pub const Layout = struct {
    /// Na ordem de exibição. Servidores que não aparecem aqui (entrou há pouco)
    /// o cliente oficial põe no topo.
    folders: []Folder,
    /// Ordem antiga (`guild_positions`); costuma vir vazia hoje em dia.
    positions: []u64,

    pub fn deinit(self: Layout, gpa: std.mem.Allocator) void {
        freeFolders(gpa, self.folders);
        gpa.free(self.folders);
        gpa.free(self.positions);
    }
};

fn freeFolders(gpa: std.mem.Allocator, folders: []const Folder) void {
    for (folders) |f| {
        gpa.free(f.name);
        gpa.free(f.guilds);
    }
}

/// `user_settings_proto` do READY (base64, com ou sem `=` no fim).
pub fn fromProtoBase64(gpa: std.mem.Allocator, b64: []const u8) Error!Layout {
    const src = std.mem.trim(u8, b64, " \t\r\n");
    const dec = if (std.mem.endsWith(u8, src, "=")) std.base64.standard.Decoder else std.base64.standard_no_pad.Decoder;
    const n = dec.calcSizeForSlice(src) catch return error.InvalidBase64;
    const buf = try gpa.alloc(u8, n);
    defer gpa.free(buf);
    dec.decode(buf, src) catch return error.InvalidBase64;
    return fromProto(gpa, buf);
}

/// Bytes de `PreloadedUserSettings` já decodificados.
pub fn fromProto(gpa: std.mem.Allocator, bytes: []const u8) Error!Layout {
    var b: Builder = .{};
    errdefer b.deinit(gpa);
    var r: Reader = .{ .buf = bytes };
    while (!r.done()) {
        const k = try r.key();
        if (k.field == 14 and k.wire == 2) {
            try readGuildFolders(gpa, &b, try r.bytes());
        } else try r.skip(k.wire);
    }
    return b.finish(gpa);
}

/// Forma antiga: o array `user_settings.guild_folders` já parseado, com
/// `{ "guild_ids": ["123", …], "id": 456|null, "name": "x"|null, "color": 123|null }`.
/// O JSON não traz `guild_positions`, então `positions` sai vazio.
pub fn fromJson(gpa: std.mem.Allocator, folders: std.json.Value) Error!Layout {
    var b: Builder = .{};
    errdefer b.deinit(gpa);
    for (jsonx.array(folders)) |f| {
        var guilds: std.ArrayList(u64) = .empty;
        defer guilds.deinit(gpa);
        for (jsonx.array(jsonx.get(f, "guild_ids"))) |g| {
            const gid = jsonx.id(g) orelse if (jsonx.int(g)) |i| std.math.cast(u64, i) else null;
            try guilds.append(gpa, gid orelse continue);
        }
        const fid = jsonx.int(jsonx.get(f, "id")) orelse 0;
        const color = jsonx.int(jsonx.get(f, "color")) orelse 0;
        try b.addFolder(gpa, .{
            .id = @bitCast(fid),
            .name = jsonx.str(jsonx.get(f, "name")) orelse "",
            .color = if (color > 0) @truncate(@as(u64, @intCast(color))) else 0,
            .guilds = guilds.items,
        });
    }
    return b.finish(gpa);
}

// ---------------------------------------------------------------------------

const Builder = struct {
    folders: std.ArrayList(Folder) = .empty,
    positions: std.ArrayList(u64) = .empty,

    /// Copia nome e servidores (podem apontar para o buffer de entrada).
    fn addFolder(b: *Builder, gpa: std.mem.Allocator, f: Folder) !void {
        try b.folders.ensureUnusedCapacity(gpa, 1);
        const name = try gpa.dupe(u8, f.name);
        errdefer gpa.free(name);
        const guilds = try gpa.dupe(u64, f.guilds);
        b.folders.appendAssumeCapacity(.{ .id = f.id, .name = name, .color = f.color, .guilds = guilds });
    }

    fn finish(b: *Builder, gpa: std.mem.Allocator) !Layout {
        const folders = try b.folders.toOwnedSlice(gpa);
        errdefer {
            freeFolders(gpa, folders);
            gpa.free(folders);
        }
        return .{ .folders = folders, .positions = try b.positions.toOwnedSlice(gpa) };
    }

    fn deinit(b: *Builder, gpa: std.mem.Allocator) void {
        freeFolders(gpa, b.folders.items);
        b.folders.deinit(gpa);
        b.positions.deinit(gpa);
    }
};

fn readGuildFolders(gpa: std.mem.Allocator, b: *Builder, msg: []const u8) Error!void {
    var r: Reader = .{ .buf = msg };
    while (!r.done()) {
        const k = try r.key();
        switch (k.field) {
            1 => if (k.wire == 2) try readFolder(gpa, b, try r.bytes()) else try r.skip(k.wire),
            2 => if (!try r.repeatedFixed64(gpa, k.wire, &b.positions)) try r.skip(k.wire),
            else => try r.skip(k.wire),
        }
    }
}

fn readFolder(gpa: std.mem.Allocator, b: *Builder, msg: []const u8) Error!void {
    var guilds: std.ArrayList(u64) = .empty;
    defer guilds.deinit(gpa);
    var f: Folder = .{ .id = 0, .name = "", .color = 0, .guilds = &.{} };
    var r: Reader = .{ .buf = msg };
    while (!r.done()) {
        const k = try r.key();
        switch (k.field) {
            1 => if (!try r.repeatedFixed64(gpa, k.wire, &guilds)) try r.skip(k.wire),
            2, 3, 4 => if (k.wire == 2) {
                const w = try readWrapper(try r.bytes());
                switch (k.field) {
                    2 => f.id = w.int,
                    3 => f.name = w.bytes,
                    else => f.color = @truncate(w.int),
                }
            } else try r.skip(k.wire),
            else => try r.skip(k.wire),
        }
    }
    f.guilds = guilds.items;
    try b.addFolder(gpa, f);
}

/// Int64Value/UInt64Value (campo 1 varint) ou StringValue (campo 1 bytes).
const Wrapper = struct { int: u64 = 0, bytes: []const u8 = "" };

fn readWrapper(msg: []const u8) Error!Wrapper {
    var out: Wrapper = .{};
    var r: Reader = .{ .buf = msg };
    while (!r.done()) {
        const k = try r.key();
        if (k.field == 1 and k.wire == 0) {
            out.int = try r.varint();
        } else if (k.field == 1 and k.wire == 2) {
            out.bytes = try r.bytes();
        } else try r.skip(k.wire);
    }
    return out;
}

/// Leitor de protobuf: nunca passa do fim do buffer.
const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn done(r: *const Reader) bool {
        return r.pos >= r.buf.len;
    }

    fn varint(r: *Reader) Error!u64 {
        var v: u64 = 0;
        var i: u7 = 0;
        while (i < 10) : (i += 1) {
            if (r.pos >= r.buf.len) return error.Truncated;
            const ch = r.buf[r.pos];
            r.pos += 1;
            v |= @as(u64, ch & 0x7f) << @intCast(7 * i);
            if (ch & 0x80 == 0) return v;
        }
        return error.Malformed;
    }

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.buf.len - r.pos) return error.Truncated;
        const s = r.buf[r.pos..][0..n];
        r.pos += n;
        return s;
    }

    fn fixed64(r: *Reader) Error!u64 {
        return std.mem.readInt(u64, (try r.take(8))[0..8], .little);
    }

    fn bytes(r: *Reader) Error![]const u8 {
        const n = try r.varint();
        if (n > r.buf.len - r.pos) return error.Truncated;
        return r.take(@intCast(n));
    }

    fn key(r: *Reader) Error!struct { field: u64, wire: u3 } {
        const k = try r.varint();
        const field = k >> 3;
        if (field == 0) return error.Malformed;
        return .{ .field = field, .wire = @truncate(k) };
    }

    /// Pula um campo desconhecido. Grupos (3/4) são obsoletos: erro.
    fn skip(r: *Reader, wire: u3) Error!void {
        switch (wire) {
            0 => _ = try r.varint(),
            1 => _ = try r.take(8),
            2 => _ = try r.bytes(),
            5 => _ = try r.take(4),
            else => return error.Malformed,
        }
    }

    /// `repeated fixed64`, empacotado (tipo 2) ou não (tipo 1). Devolve false
    /// se o tipo de fio não é nenhum dos dois (aí quem chama pula o campo).
    fn repeatedFixed64(r: *Reader, gpa: std.mem.Allocator, wire: u3, out: *std.ArrayList(u64)) Error!bool {
        switch (wire) {
            1 => try out.append(gpa, try r.fixed64()),
            2 => {
                const data = try r.bytes();
                if (data.len % 8 != 0) return error.Malformed;
                try out.ensureUnusedCapacity(gpa, data.len / 8);
                var i: usize = 0;
                while (i < data.len) : (i += 8)
                    out.appendAssumeCapacity(std.mem.readInt(u64, data[i..][0..8], .little));
            },
            else => return false,
        }
        return true;
    }
};

// --- Escrita ----------------------------------------------------------------

const guild_folders_field = 14;

/// Um campo inteiro: onde começa (na chave), onde acaba e o conteúdo (tipo 2).
const Span = struct { field: u64, wire: u3, start: usize, end: usize, data: []const u8 };

fn nextSpan(r: *Reader) Error!Span {
    const start = r.pos;
    const k = try r.key();
    var data: []const u8 = "";
    switch (k.wire) {
        2 => data = try r.bytes(),
        else => try r.skip(k.wire),
    }
    return .{ .field = k.field, .wire = k.wire, .start = start, .end = r.pos, .data = data };
}

/// Uma pasta como veio, lida inteira e conferida.
const OldFolder = struct {
    /// O `GuildFolder` inteiro (sem chave nem tamanho).
    raw: []const u8,
    id: u64 = 0,
    name: []const u8 = "",
    color: u32 = 0,
    guilds: []u64 = &.{},
    /// Os campos que o app não conhece, inteiros e na ordem em que vieram.
    unknown: []const u8 = "",
};

/// O `GuildFolders` lido para editar: tipo de fio errado num campo conhecido é erro.
const Parsed = struct {
    folders: []OldFolder,
    had_positions: bool,
    /// Campos de `GuildFolders` que o app não conhece.
    unknown: []const u8,
};

fn wantWire(sp: Span, wire: u3) Error!void {
    if (sp.wire != wire) return error.Malformed;
}

/// Int64Value/UInt64Value: só o campo 1 como varint conta; o resto, conferido e pulado.
fn strictInt(msg: []const u8) Error!u64 {
    var out: u64 = 0;
    var r: Reader = .{ .buf = msg };
    while (!r.done()) {
        const sp = try nextSpan(&r);
        if (sp.field != 1) continue;
        try wantWire(sp, 0);
        var vr: Reader = .{ .buf = msg[sp.start..sp.end] };
        _ = try vr.key();
        out = try vr.varint();
    }
    return out;
}

fn strictString(msg: []const u8) Error![]const u8 {
    var out: []const u8 = "";
    var r: Reader = .{ .buf = msg };
    while (!r.done()) {
        const sp = try nextSpan(&r);
        if (sp.field != 1) continue;
        try wantWire(sp, 2);
        out = sp.data;
    }
    return out;
}

/// Tudo com o alocador de arena de quem chama (`edit`).
fn parseStrict(ar: std.mem.Allocator, content: []const u8) Error!Parsed {
    var folders: std.ArrayList(OldFolder) = .empty;
    var unknown: std.ArrayList(u8) = .empty;
    var had_positions = false;
    var r: Reader = .{ .buf = content };
    while (!r.done()) {
        const sp = try nextSpan(&r);
        switch (sp.field) {
            1 => {
                try wantWire(sp, 2);
                try folders.append(ar, try parseFolder(ar, sp.data));
            },
            2 => {
                var list: std.ArrayList(u64) = .empty;
                var vr: Reader = .{ .buf = content[sp.start..sp.end] };
                const k = try vr.key();
                if (!try vr.repeatedFixed64(ar, k.wire, &list)) return error.Malformed;
                if (list.items.len > 0) had_positions = true;
            },
            else => try unknown.appendSlice(ar, content[sp.start..sp.end]),
        }
    }
    return .{ .folders = try folders.toOwnedSlice(ar), .had_positions = had_positions, .unknown = try unknown.toOwnedSlice(ar) };
}

fn parseFolder(ar: std.mem.Allocator, msg: []const u8) Error!OldFolder {
    var f: OldFolder = .{ .raw = msg };
    var guilds: std.ArrayList(u64) = .empty;
    var unknown: std.ArrayList(u8) = .empty;
    var r: Reader = .{ .buf = msg };
    while (!r.done()) {
        const sp = try nextSpan(&r);
        switch (sp.field) {
            1 => {
                var vr: Reader = .{ .buf = msg[sp.start..sp.end] };
                const k = try vr.key();
                if (!try vr.repeatedFixed64(ar, k.wire, &guilds)) return error.Malformed;
            },
            2, 4 => {
                try wantWire(sp, 2);
                const v = try strictInt(sp.data);
                if (sp.field == 2) f.id = v else f.color = @truncate(v);
            },
            3 => {
                try wantWire(sp, 2);
                f.name = try strictString(sp.data);
            },
            else => try unknown.appendSlice(ar, msg[sp.start..sp.end]),
        }
    }
    f.guilds = try guilds.toOwnedSlice(ar);
    f.unknown = try unknown.toOwnedSlice(ar);
    return f;
}

const Writer = struct {
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    fn varint(w: Writer, v: u64) Error!void {
        var x = v;
        while (x >= 0x80) : (x >>= 7) try w.out.append(w.gpa, @as(u8, @truncate(x)) | 0x80);
        try w.out.append(w.gpa, @truncate(x));
    }
    fn key(w: Writer, field: u64, wire: u3) Error!void {
        try w.varint(field << 3 | wire);
    }
    fn bytes(w: Writer, field: u64, data: []const u8) Error!void {
        try w.key(field, 2);
        try w.varint(data.len);
        try w.out.appendSlice(w.gpa, data);
    }
    fn packed64(w: Writer, field: u64, vals: []const u64) Error!void {
        if (vals.len == 0) return;
        try w.key(field, 2);
        try w.varint(vals.len * 8);
        for (vals) |v| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, v, .little);
            try w.out.appendSlice(w.gpa, &b);
        }
    }
    /// Int64Value/UInt64Value { 1: v }.
    fn wrapInt(w: Writer, field: u64, v: u64) Error!void {
        var buf: [11]u8 = undefined;
        buf[0] = 0x08;
        var x = v;
        var n: usize = 1;
        while (x >= 0x80) : (x >>= 7) {
            buf[n] = @as(u8, @truncate(x)) | 0x80;
            n += 1;
        }
        buf[n] = @truncate(x);
        try w.bytes(field, buf[0 .. n + 1]);
    }
    /// StringValue { 1: s }.
    fn wrapString(w: Writer, field: u64, s: []const u8) Error!void {
        var inner: std.ArrayList(u8) = .empty;
        defer inner.deinit(w.gpa);
        try (Writer{ .out = &inner, .gpa = w.gpa }).bytes(1, s);
        try w.bytes(field, inner.items);
    }
};

/// Um `GuildFolder` (proto3: servidores empacotados; sem id, sem nome e sem cor, os
/// wrappers não vão). `unknown`: campos de antes que o app não conhece.
fn writeFolder(w: Writer, f: anytype, unknown: []const u8) Error!void {
    try w.packed64(1, f.guilds);
    if (f.id != 0) try w.wrapInt(2, f.id);
    if (f.name.len > 0) try w.wrapString(3, f.name);
    if (f.color != 0) try w.wrapInt(4, f.color);
    try w.out.appendSlice(w.gpa, unknown);
}

/// `GuildFolders` só com as pastas de `folders` (sem nada de antes): para a
/// demonstração e os testes.
pub fn encodeGuildFolders(gpa: std.mem.Allocator, folders: anytype) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const w: Writer = .{ .out = &out, .gpa = gpa };
    var one: std.ArrayList(u8) = .empty;
    defer one.deinit(gpa);
    for (folders) |f| {
        one.clearRetainingCapacity();
        try writeFolder(.{ .out = &one, .gpa = gpa }, f, "");
        try w.bytes(1, one.items);
    }
    return out.toOwnedSlice(gpa);
}

/// Um `GuildFolder` sozinho (sem chave nem tamanho), com `unknown` no fim.
pub fn encodeFolder(gpa: std.mem.Allocator, f: anytype, unknown: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try writeFolder(.{ .out = &out, .gpa = gpa }, f, unknown);
    return out.toOwnedSlice(gpa);
}

fn sameIds(a: []const u64, b: []const u64) bool {
    return std.mem.eql(u64, a, b);
}

/// A pasta de antes que corresponde a `f`: a do mesmo id, ou o solto do mesmo servidor.
fn oldFor(old: []const OldFolder, f: anytype) ?*const OldFolder {
    for (old) |*o| {
        if (f.id != 0 and o.id == f.id) return o;
        if (f.id == 0 and o.id == 0 and sameIds(o.guilds, f.guilds)) return o;
    }
    return null;
}

/// O `GuildFolders` novo: a pasta igual à de antes sai como veio; a que mudou, de
/// novo (com os campos desconhecidos dela). A ordem antiga (`guild_positions`) só vai
/// se já vinha, refeita com a ordem nova. Os campos desconhecidos do `GuildFolders`
/// vão no fim.
fn encodeEdited(ar: std.mem.Allocator, p: Parsed, folders: []const @import("../core/types.zig").GuildFolder) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const w: Writer = .{ .out = &out, .gpa = ar };
    var one: std.ArrayList(u8) = .empty;
    for (folders) |f| {
        const o = oldFor(p.folders, f);
        if (o) |x| if (std.mem.eql(u8, x.name, f.name) and x.color == f.color and sameIds(x.guilds, f.guilds)) {
            try w.bytes(1, x.raw);
            continue;
        };
        one.clearRetainingCapacity();
        try writeFolder(.{ .out = &one, .gpa = ar }, f, if (o) |x| x.unknown else "");
        try w.bytes(1, one.items);
    }
    if (p.had_positions) {
        var order: std.ArrayList(u64) = .empty;
        for (folders) |f| try order.appendSlice(ar, f.guilds);
        try w.packed64(2, order.items);
    }
    try out.appendSlice(ar, p.unknown);
    return out.toOwnedSlice(ar);
}

/// As configurações lidas e conferidas: o conteúdo de todo campo 14 junto (repetido,
/// o protobuf junta) e onde estão.
const Top = struct { content: []const u8 };

fn scanTop(ar: std.mem.Allocator, bytes: []const u8) Error!Top {
    var joined: std.ArrayList(u8) = .empty;
    var r: Reader = .{ .buf = bytes };
    while (!r.done()) {
        const sp = try nextSpan(&r);
        if (sp.field != guild_folders_field) continue;
        try wantWire(sp, 2);
        try joined.appendSlice(ar, sp.data);
    }
    return .{ .content = try joined.toOwnedSlice(ar) };
}

/// As configurações inteiras (`bytes`) com as operações aplicadas nas pastas. Fora do
/// campo 14, tudo sai exatamente como entrou, no mesmo lugar; sem campo 14, ele entra
/// no fim. null = nada muda (nada a gravar). `known`: os servidores do app, na ordem
/// dele (core/pastas.zig `Model.init`). Devolve memória de `gpa`.
pub fn edit(gpa: std.mem.Allocator, bytes: []const u8, ops: []const pastas.Op, known: []const u64) Error!?[]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const top = try scanTop(ar, bytes);
    const p = try parseStrict(ar, top.content);
    const before = try pastas.applyAll(ar, p.folders, known, &.{});
    const after = try pastas.applyAll(ar, p.folders, known, ops);
    if (pastas.same(before, after)) return null;
    const content = try encodeEdited(ar, p, after);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, bytes.len + content.len + 8);
    const w: Writer = .{ .out = &out, .gpa = gpa };
    var r: Reader = .{ .buf = bytes };
    var done = false;
    while (!r.done()) {
        const sp = try nextSpan(&r);
        if (sp.field != guild_folders_field) {
            try out.appendSlice(gpa, bytes[sp.start..sp.end]);
            continue;
        }
        // O primeiro campo 14 dá lugar ao novo; os outros já estão dentro dele.
        if (done) continue;
        done = true;
        try w.bytes(guild_folders_field, content);
    }
    if (!done) try w.bytes(guild_folders_field, content);
    return try out.toOwnedSlice(gpa);
}

/// Só o campo 14 de `bytes`, como mensagem própria (repetido, junto num só). Sem
/// campo 14, vai vazio: o PATCH sempre diz como as pastas ficaram.
pub fn foldersOnly(gpa: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const top = try scanTop(arena.allocator(), bytes);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try (Writer{ .out = &out, .gpa = gpa }).bytes(guild_folders_field, top.content);
    return out.toOwnedSlice(gpa);
}

/// `{"settings":"<só o campo 14>","required_data_version":N}`. Com a versão lida,
/// o Discord recusa (`out_of_date`) se outro aparelho gravou no meio, em vez de voltar
/// a mudança dele.
pub fn patchBody(gpa: std.mem.Allocator, edited: []const u8, version: ?u32) Error![]u8 {
    const only = try foldersOnly(gpa, edited);
    defer gpa.free(only);
    const enc = std.base64.standard.Encoder;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"settings\":\"");
    const at = out.items.len;
    try out.resize(gpa, at + enc.calcSize(only.len));
    _ = enc.encode(out.items[at..], only);
    try out.append(gpa, '"');
    if (version) |v| try out.print(gpa, ",\"required_data_version\":{d}", .{v});
    try out.append(gpa, '}');
    return out.toOwnedSlice(gpa);
}

/// As configurações guardadas (`cached`) com uma atualização parcial por cima
/// (USER_SETTINGS_PROTO_UPDATE com `partial`): cada campo de cima que veio na
/// atualização troca o mesmo campo das guardadas, inteiro, como o PATCH faz no
/// servidor; os outros ficam como estavam, na mesma ordem. Os que vieram vão no fim.
/// Qualquer parte que não dê para ler inteira dá erro (quem chama esquece a cópia).
pub fn mergeTop(gpa: std.mem.Allocator, cached: []const u8, update: []const u8) Error![]u8 {
    var present: std.ArrayList(u64) = .empty;
    defer present.deinit(gpa);
    var r: Reader = .{ .buf = update };
    while (!r.done()) {
        const sp = try nextSpan(&r);
        if (std.mem.indexOfScalar(u64, present.items, sp.field) == null) try present.append(gpa, sp.field);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, cached.len + update.len);
    var c: Reader = .{ .buf = cached };
    while (!c.done()) {
        const sp = try nextSpan(&c);
        if (std.mem.indexOfScalar(u64, present.items, sp.field) == null) try out.appendSlice(gpa, cached[sp.start..sp.end]);
    }
    try out.appendSlice(gpa, update);
    return out.toOwnedSlice(gpa);
}

/// O que o PATCH levou (o campo 14 de `settings` em base64), lido de volta: para o
/// QA e os testes conferirem os bytes que iriam para o Discord.
pub fn decodePatch(gpa: std.mem.Allocator, body: []const u8) !Layout {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
    const b64 = jsonx.str(jsonx.get(v, "settings")) orelse return error.Malformed;
    return fromProtoBase64(gpa, b64);
}

// ---------------------------------------------------------------------------

/// Codificador mínimo, só para montar mensagens nos testes.
const TestEnc = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    fn deinit(e: *TestEnc) void {
        e.out.deinit(e.gpa);
    }
    fn varint(e: *TestEnc, v: u64) !void {
        var x = v;
        while (x >= 0x80) : (x >>= 7) try e.out.append(e.gpa, @as(u8, @truncate(x)) | 0x80);
        try e.out.append(e.gpa, @truncate(x));
    }
    fn key(e: *TestEnc, field: u64, wire: u3) !void {
        try e.varint(field << 3 | wire);
    }
    fn fieldVarint(e: *TestEnc, field: u64, v: u64) !void {
        try e.key(field, 0);
        try e.varint(v);
    }
    fn fieldFixed64(e: *TestEnc, field: u64, v: u64) !void {
        try e.key(field, 1);
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try e.out.appendSlice(e.gpa, &b);
    }
    fn fieldFixed32(e: *TestEnc, field: u64, v: u32) !void {
        try e.key(field, 5);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try e.out.appendSlice(e.gpa, &b);
    }
    fn fieldBytes(e: *TestEnc, field: u64, data: []const u8) !void {
        try e.key(field, 2);
        try e.varint(data.len);
        try e.out.appendSlice(e.gpa, data);
    }
    fn fieldPacked64(e: *TestEnc, field: u64, vals: []const u64) !void {
        try e.key(field, 2);
        try e.varint(vals.len * 8);
        for (vals) |v| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, v, .little);
            try e.out.appendSlice(e.gpa, &b);
        }
    }
    /// Wrapper do google.protobuf com um varint no campo 1.
    fn fieldWrapInt(e: *TestEnc, field: u64, v: u64) !void {
        var w: TestEnc = .{ .gpa = e.gpa };
        defer w.deinit();
        try w.fieldVarint(1, v);
        try e.fieldBytes(field, w.out.items);
    }
    fn fieldWrapStr(e: *TestEnc, field: u64, s: []const u8) !void {
        var w: TestEnc = .{ .gpa = e.gpa };
        defer w.deinit();
        try w.fieldBytes(1, s);
        try e.fieldBytes(field, w.out.items);
    }
};

/// `PreloadedUserSettings` de exemplo; `range` recebe onde fica o campo 14.
fn testSettings(a: std.mem.Allocator, range: *[2]usize) ![]u8 {
    // Pasta de verdade: id, nome, cor e 3 servidores empacotados.
    var f1: TestEnc = .{ .gpa = a };
    defer f1.deinit();
    try f1.fieldPacked64(1, &.{ 111, 222, 333 });
    try f1.fieldWrapInt(2, 4567);
    try f1.fieldWrapStr(3, "Jogos");
    try f1.fieldWrapInt(4, 0xFF00AA);
    try f1.fieldFixed64(9, 0xdead); // desconhecido

    // Servidor solto: sem id, guild_ids sem empacotar.
    var f2: TestEnc = .{ .gpa = a };
    defer f2.deinit();
    try f2.fieldFixed64(1, 999);

    // Pasta sem nome nem cor, guild_ids misturando as duas formas.
    var f3: TestEnc = .{ .gpa = a };
    defer f3.deinit();
    try f3.fieldFixed64(1, 10);
    try f3.fieldPacked64(1, &.{ 20, 30 });
    try f3.fieldWrapInt(2, 8);

    var gf: TestEnc = .{ .gpa = a };
    defer gf.deinit();
    try gf.fieldBytes(1, f1.out.items);
    try gf.fieldFixed32(7, 1234); // desconhecido no meio
    try gf.fieldBytes(1, f2.out.items);
    try gf.fieldBytes(1, f3.out.items);
    try gf.fieldPacked64(2, &.{ 999, 111 });
    try gf.fieldFixed64(2, 222);

    // Antes do 14: mensagem aninhada (versions), varint, fixed32 e campo de número alto.
    var nested: TestEnc = .{ .gpa = a };
    defer nested.deinit();
    try nested.fieldVarint(1, 300);
    try nested.fieldBytes(3, "\x08\x01");
    var top: TestEnc = .{ .gpa = a };
    errdefer top.deinit();
    try top.fieldBytes(1, nested.out.items);
    try top.fieldVarint(8, std.math.maxInt(u64));
    try top.fieldFixed32(5, 0xcafebabe);
    try top.fieldVarint(5000, 1);
    range[0] = top.out.items.len;
    try top.fieldBytes(14, gf.out.items);
    range[1] = top.out.items.len;
    // Depois do 14: outra mensagem aninhada, fixed64 e fixed32.
    try top.fieldBytes(15, nested.out.items);
    try top.fieldFixed64(3, 42);
    try top.fieldFixed32(27, 7);
    return top.out.toOwnedSlice(a);
}

fn expectSample(l: Layout) !void {
    const t = std.testing;
    try t.expectEqual(@as(usize, 3), l.folders.len);
    const f = l.folders[0];
    try t.expectEqual(@as(u64, 4567), f.id);
    try t.expectEqualStrings("Jogos", f.name);
    try t.expectEqual(@as(u32, 0xFF00AA), f.color);
    try t.expectEqualSlices(u64, &.{ 111, 222, 333 }, f.guilds);
    try t.expect(!f.isLoose());

    const s = l.folders[1];
    try t.expect(s.isLoose());
    try t.expectEqualStrings("", s.name);
    try t.expectEqual(@as(u32, 0), s.color);
    try t.expectEqualSlices(u64, &.{999}, s.guilds);

    try t.expectEqual(@as(u64, 8), l.folders[2].id);
    try t.expectEqualSlices(u64, &.{ 10, 20, 30 }, l.folders[2].guilds);
    try t.expectEqualSlices(u64, &.{ 999, 111, 222 }, l.positions);
}

test "pastas e servidores soltos do protobuf, pulando campos desconhecidos" {
    const a = std.testing.allocator;
    var range: [2]usize = undefined;
    const bytes = try testSettings(a, &range);
    defer a.free(bytes);
    const l = try fromProto(a, bytes);
    defer l.deinit(a);
    try expectSample(l);

    // Sem o campo 14: tudo vazio.
    const empty = try fromProto(a, "");
    defer empty.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), empty.folders.len);
    try std.testing.expectEqual(@as(usize, 0), empty.positions.len);
}

test "entrada truncada ou malformada dá erro" {
    const a = std.testing.allocator;
    var range: [2]usize = undefined;
    const bytes = try testSettings(a, &range);
    defer a.free(bytes);
    // Cortar em qualquer ponto: nunca lê fora nem vaza; dentro do campo 14 é erro.
    for (0..bytes.len) |n| {
        if (fromProto(a, bytes[0..n])) |l| {
            l.deinit(a);
            try std.testing.expect(n <= range[0] or n >= range[1]);
        } else |err| try std.testing.expectEqual(error.Truncated, err);
    }
    // Varint com mais de 10 bytes.
    try std.testing.expectError(error.Malformed, fromProto(a, "\x08\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01"));
    // Tipo de fio 3 (grupo) e campo 0.
    try std.testing.expectError(error.Malformed, fromProto(a, "\x0b"));
    try std.testing.expectError(error.Malformed, fromProto(a, "\x00\x00"));
    // guild_ids empacotado com tamanho que não é múltiplo de 8.
    try std.testing.expectError(error.Malformed, fromProto(a, "\x72\x0b\x0a\x09\x0a\x07\x01\x02\x03\x04\x05\x06\x07"));
    // Comprimento maior que o resto da mensagem.
    try std.testing.expectError(error.Truncated, fromProto(a, "\x72\xff\xff\xff\xff\x0f\x00"));
}

fn parseAndFree(a: std.mem.Allocator, bytes: []const u8) !void {
    const l = try fromProto(a, bytes);
    l.deinit(a);
}

test "sem vazamento quando falta memória" {
    const a = std.testing.allocator;
    var range: [2]usize = undefined;
    const bytes = try testSettings(a, &range);
    defer a.free(bytes);
    try std.testing.checkAllAllocationFailures(a, parseAndFree, .{bytes});
}

test "base64 do user_settings_proto" {
    const a = std.testing.allocator;
    var range: [2]usize = undefined;
    const bytes = try testSettings(a, &range);
    defer a.free(bytes);
    const enc = std.base64.standard.Encoder;
    const b64 = try a.alloc(u8, enc.calcSize(bytes.len));
    defer a.free(b64);
    _ = enc.encode(b64, bytes);

    const l = try fromProtoBase64(a, b64);
    defer l.deinit(a);
    try expectSample(l);

    // Sem o `=` do fim também serve.
    const unpadded = std.mem.trimEnd(u8, b64, "=");
    const l2 = try fromProtoBase64(a, unpadded);
    defer l2.deinit(a);
    try expectSample(l2);

    try std.testing.expectError(error.InvalidBase64, fromProtoBase64(a, "não é base64!"));
}

test "forma antiga em JSON (user_settings.guild_folders)" {
    const a = std.testing.allocator;
    const text =
        \\[
        \\  {"guild_ids": ["111", "222", "333"], "id": 4567, "name": "Jogos", "color": 16711850},
        \\  {"guild_ids": ["999"], "id": null, "name": null, "color": null},
        \\  {"guild_ids": ["10", "lixo", 20], "id": "8"}
        \\]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    const l = try fromJson(a, parsed.value);
    defer l.deinit(a);

    try std.testing.expectEqual(@as(usize, 3), l.folders.len);
    try std.testing.expectEqual(@as(u64, 4567), l.folders[0].id);
    try std.testing.expectEqualStrings("Jogos", l.folders[0].name);
    try std.testing.expectEqual(@as(u32, 0xFF00AA), l.folders[0].color);
    try std.testing.expectEqualSlices(u64, &.{ 111, 222, 333 }, l.folders[0].guilds);
    try std.testing.expect(l.folders[1].isLoose());
    try std.testing.expectEqualStrings("", l.folders[1].name);
    try std.testing.expectEqualSlices(u64, &.{999}, l.folders[1].guilds);
    try std.testing.expectEqual(@as(u64, 8), l.folders[2].id);
    try std.testing.expectEqualSlices(u64, &.{ 10, 20 }, l.folders[2].guilds);
    try std.testing.expectEqual(@as(usize, 0), l.positions.len);

    // Algo que não é array: lista vazia, sem erro.
    const none = try fromJson(a, .null);
    defer none.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), none.folders.len);
}

// --- Escrita: testes ---------------------------------------------------------

const types = @import("../core/types.zig");

test "codificar e ler de volta: as mesmas pastas" {
    const a = std.testing.allocator;
    var range: [2]usize = undefined;
    const bytes = try testSettings(a, &range);
    defer a.free(bytes);
    const l = try fromProto(a, bytes);
    defer l.deinit(a);
    const content = try encodeGuildFolders(a, l.folders);
    defer a.free(content);
    var top: TestEnc = .{ .gpa = a };
    defer top.deinit();
    try top.fieldBytes(14, content);
    const back = try fromProto(a, top.out.items);
    defer back.deinit(a);
    try std.testing.expect(pastas.same(l.folders, back.folders));
    // E de novo: a segunda volta é idêntica byte a byte.
    const again = try encodeGuildFolders(a, back.folders);
    defer a.free(again);
    try std.testing.expectEqualSlices(u8, content, again);
}

test "wrappers: id, nome e cor; nome vazio, sem cor e solto não levam o campo" {
    const a = std.testing.allocator;
    const folders = [_]types.GuildFolder{
        .{ .id = 4567, .name = "Jogos", .color = 0xFF00AA, .guilds = &.{0x0102030405060708} },
        .{ .id = 300, .name = "", .color = 0, .guilds = &.{ 1, 2 } },
        .{ .id = 0, .name = "", .color = 0, .guilds = &.{9} },
    };
    const got = try encodeGuildFolders(a, &folders);
    defer a.free(got);
    const want =
        // pasta 1: guild_ids empacotado, id {1: 4567}, nome {1: "Jogos"}, cor {1: 0xFF00AA}
        "\x0a\x1f" ++ "\x0a\x08\x08\x07\x06\x05\x04\x03\x02\x01" ++ "\x12\x03\x08\xd7\x23" ++
        "\x1a\x07\x0a\x05Jogos" ++ "\x22\x05\x08\xaa\x81\xfc\x07" ++
        // pasta 2: só servidores e id (300 = \xac\x02)
        "\x0a\x17" ++ "\x0a\x10\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00" ++ "\x12\x03\x08\xac\x02" ++
        // solto: só o servidor
        "\x0a\x0a" ++ "\x0a\x08\x09\x00\x00\x00\x00\x00\x00\x00";
    try std.testing.expectEqualSlices(u8, want, got);
}

test "editar: fora do campo 14 nada muda; dentro, a pasta intacta sai como veio" {
    const a = std.testing.allocator;
    var range: [2]usize = undefined;
    const bytes = try testSettings(a, &range);
    defer a.free(bytes);
    const ops = [_]pastas.Op{
        .{ .edit = .{ .folder = 8, .name = pastas.Name.init("Trabalho") } },
        .{ .move_guild = .{ .guild = 999, .folder = 8, .where = .start } },
    };
    const out = (try edit(a, bytes, &ops, &.{})).?;
    defer a.free(out);
    // Antes e depois do 14, idêntico.
    try std.testing.expectEqualSlices(u8, bytes[0..range[0]], out[0..range[0]]);
    const tail = bytes[range[1]..];
    try std.testing.expect(std.mem.endsWith(u8, out, tail));
    // O "Jogos" (com o campo 9 desconhecido) não mudou: os bytes dele estão lá.
    var f1: TestEnc = .{ .gpa = a };
    defer f1.deinit();
    try f1.fieldPacked64(1, &.{ 111, 222, 333 });
    try f1.fieldWrapInt(2, 4567);
    try f1.fieldWrapStr(3, "Jogos");
    try f1.fieldWrapInt(4, 0xFF00AA);
    try f1.fieldFixed64(9, 0xdead);
    try std.testing.expect(std.mem.indexOf(u8, out, f1.out.items) != null);
    // O campo 7 do GuildFolders (fixed32 1234) continua.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x3d\xd2\x04\x00\x00") != null);
    const l = try fromProto(a, out);
    defer l.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), l.folders.len);
    try std.testing.expectEqualStrings("Trabalho", l.folders[1].name);
    try std.testing.expectEqual(@as(u64, 8), l.folders[1].id);
    try std.testing.expectEqualSlices(u64, &.{ 999, 10, 20, 30 }, l.folders[1].guilds);
    // A ordem antiga vinha: refeita com a ordem nova.
    try std.testing.expectEqualSlices(u64, &.{ 111, 222, 333, 999, 10, 20, 30 }, l.positions);
}

test "editar a pasta com campo desconhecido: ele vai junto" {
    const a = std.testing.allocator;
    var range: [2]usize = undefined;
    const bytes = try testSettings(a, &range);
    defer a.free(bytes);
    const out = (try edit(a, bytes, &.{.{ .edit = .{ .folder = 4567, .color = 0x00FF00 } }}, &.{})).?;
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x49\xad\xde\x00\x00\x00\x00\x00\x00") != null);
    const l = try fromProto(a, out);
    defer l.deinit(a);
    try std.testing.expectEqual(@as(u32, 0x00FF00), l.folders[0].color);
    try std.testing.expectEqualStrings("Jogos", l.folders[0].name);
}

test "nada muda: nada a gravar; sem campo 14, ele entra no fim" {
    const a = std.testing.allocator;
    var range: [2]usize = undefined;
    const bytes = try testSettings(a, &range);
    defer a.free(bytes);
    try std.testing.expectEqual(null, try edit(a, bytes, &.{.{ .edit = .{ .folder = 4567, .name = pastas.Name.init("Jogos") } }}, &.{}));
    try std.testing.expectEqual(null, try edit(a, bytes, &.{.{ .move_guild = .{ .guild = 999, .folder = 12345 } }}, &.{}));
    // Conta sem pastas: os servidores do app viram a lista, com a pasta nova.
    const head = "\x0a\x02\x18\x05" ++ "\x58\x01";
    const out = (try edit(a, head, &.{.{ .merge = .{ .guild = 2, .onto = 1, .folder = 50 } }}, &.{ 1, 2, 3 })).?;
    defer a.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, head));
    const l = try fromProto(a, out);
    defer l.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), l.folders.len);
    try std.testing.expectEqual(@as(u64, 50), l.folders[0].id);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, l.folders[0].guilds);
    try std.testing.expect(l.folders[1].isLoose());
    try std.testing.expectEqual(@as(usize, 0), l.positions.len);
}

test "configurações cortadas ou com tipo errado nunca são escritas" {
    const a = std.testing.allocator;
    var range: [2]usize = undefined;
    const bytes = try testSettings(a, &range);
    defer a.free(bytes);
    const op = [_]pastas.Op{.{ .ungroup = 222 }};
    for (0..bytes.len) |n| {
        if (edit(a, bytes[0..n], &op, &.{})) |res| {
            if (res) |o| a.free(o);
            // Só passa cortado entre campos do topo (e antes do 14, sem pasta nenhuma).
            try std.testing.expect(n <= range[0] or n >= range[1]);
        } else |err| try std.testing.expect(err == error.Truncated or err == error.Malformed);
    }
    const bad = [_][]const u8{
        // Campo 14 como varint.
        "\x70\x01",
        // Pasta como fixed64.
        "\x72\x09\x09\x01\x02\x03\x04\x05\x06\x07\x08",
        // id da pasta como varint (não é wrapper).
        "\x72\x04\x0a\x02\x10\x05",
        // nome com o campo 1 como varint.
        "\x72\x06\x0a\x04\x1a\x02\x08\x01",
        // guild_ids como varint.
        "\x72\x04\x0a\x02\x08\x01",
        // guild_positions como fixed32.
        "\x72\x05\x15\x01\x02\x03\x04",
        // Grupo no topo.
        "\x0b",
    };
    for (bad) |b| try std.testing.expectError(error.Malformed, edit(a, b, &op, &.{}));
}

test "corpo do PATCH: só o campo 14 e a versão" {
    const a = std.testing.allocator;
    var range: [2]usize = undefined;
    const bytes = try testSettings(a, &range);
    defer a.free(bytes);
    const out = (try edit(a, bytes, &.{.{ .remove_folder = 8 }}, &.{})).?;
    defer a.free(out);
    const body = try patchBody(a, out, 41);
    defer a.free(body);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
    try std.testing.expectEqual(@as(?i64, 41), jsonx.int(jsonx.get(v, "required_data_version")));
    const b64 = jsonx.str(jsonx.get(v, "settings")).?;
    const dec = std.base64.standard.Decoder;
    const sent = try arena.allocator().alloc(u8, try dec.calcSizeForSlice(b64));
    try dec.decode(sent, b64);
    // Um campo só, o 14 (0x72), e nada de fora dele.
    var r: Reader = .{ .buf = sent };
    const k = try r.key();
    try std.testing.expectEqual(@as(u64, 14), k.field);
    _ = try r.bytes();
    try std.testing.expect(r.done());
    const l = try decodePatch(a, body);
    defer l.deinit(a);
    try std.testing.expectEqual(@as(usize, 5), l.folders.len);
    try std.testing.expect(l.folders[2].isLoose() and l.folders[3].isLoose() and l.folders[4].isLoose());
    // Sem a versão: o corpo vai sem ela.
    const plain = try patchBody(a, out, null);
    defer a.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "required_data_version") == null);
}

fn editAndFree(a: std.mem.Allocator, bytes: []const u8) !void {
    const out = (try edit(a, bytes, &.{ .{ .merge = .{ .guild = 999, .onto = 111, .folder = 5 } }, .{ .edit = .{ .folder = 8, .name = pastas.Name.init("x") } } }, &.{ 1, 2 })).?;
    defer a.free(out);
    const body = try patchBody(a, out, 3);
    a.free(body);
}

test "editar sem vazamento quando falta memória" {
    const a = std.testing.allocator;
    var range: [2]usize = undefined;
    const bytes = try testSettings(a, &range);
    defer a.free(bytes);
    try std.testing.checkAllAllocationFailures(a, editAndFree, .{bytes});
}

test "atualização parcial por cima das configurações guardadas" {
    const a = std.testing.allocator;
    var range: [2]usize = undefined;
    const bytes = try testSettings(a, &range);
    defer a.free(bytes);
    // Outro aparelho: versions novo e as pastas (só um servidor solto).
    var up: TestEnc = .{ .gpa = a };
    defer up.deinit();
    try up.fieldBytes(1, "\x18\x09");
    var gf: TestEnc = .{ .gpa = a };
    defer gf.deinit();
    try gf.fieldBytes(1, "\x0a\x08\x05\x00\x00\x00\x00\x00\x00\x00");
    try up.fieldBytes(14, gf.out.items);
    const merged = try mergeTop(a, bytes, up.out.items);
    defer a.free(merged);
    const l = try fromProto(a, merged);
    defer l.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), l.folders.len);
    try std.testing.expectEqualSlices(u64, &.{5}, l.folders[0].guilds);
    // O resto que não veio continua, byte a byte (o campo 8 com o maior varint, o 5000…).
    try std.testing.expect(std.mem.indexOf(u8, merged, bytes[range[1]..]) != null);
    try std.testing.expect(std.mem.endsWith(u8, merged, up.out.items));
    // Nada a mais: o tamanho é o de antes sem o versions e o 14, mais a atualização.
    var nested: TestEnc = .{ .gpa = a };
    defer nested.deinit();
    try nested.fieldVarint(1, 300);
    try nested.fieldBytes(3, "\x08\x01");
    const old_versions = 2 + nested.out.items.len;
    try std.testing.expectEqual(bytes.len - old_versions - (range[1] - range[0]) + up.out.items.len, merged.len);
    try std.testing.expectError(error.Truncated, mergeTop(a, bytes, "\x72\x05\x01"));
    try std.testing.expectError(error.Truncated, mergeTop(a, bytes[0 .. bytes.len - 1], up.out.items));
}
