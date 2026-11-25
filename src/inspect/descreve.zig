//! O texto curto de uma mensagem do barramento (event.zig) para a aba Eventos: a etiqueta
//! e os campos, com textos entre aspas, listas resumidas e dois níveis de profundidade.
//!
//! As mensagens são centenas de tipos (cada ação, comando e evento com a sua struct). Uma
//! função gerada por tipo, como o `std.fmt` faz, deixava o executável centenas de KB maior.
//! Aqui o tempo de compilação só monta uma descrição de cada tipo (dados: os nomes dos
//! campos, onde cada um fica, o que é) e uma função só percorre qualquer valor por ela.
//! Código por tipo, só o mínimo que a linguagem não deixa ler pela memória: qual variante
//! de uma união está ativa e se um opcional tem valor.
const std = @import("std");

const Forma = enum(u8) {
    /// Sem nada a escrever (void).
    nada,
    bool,
    int,
    float,
    /// Enum com nomes; o aberto (não exaustivo) vai como número.
    enum_nome,
    enum_numero,
    opcional,
    /// []u8: o texto entre aspas (até 160 bytes).
    texto,
    /// Outra lista: só quantos.
    lista,
    /// Ponteiro para um valor: o valor.
    ponteiro,
    /// Ponteiro sem o que mostrar (opaco, função, muitos, C).
    ptr,
    /// Ponteiro que passou da profundidade.
    estrela,
    /// [N]u8: o texto até o primeiro zero.
    vetor_texto,
    vetor,
    estrutura,
    /// Estrutura que passou da profundidade.
    fechada,
    uniao,
    /// União que passou da profundidade: só a etiqueta.
    uniao_nome,
    uniao_sem_tag,
    /// O "?" de antes (erro, vetor SIMD…): também não tinha texto.
    outro,
    /// O que o de antes mostrava e este não sabe ler (inteiro de mais de 64 bits, campo
    /// comptime…): sai "?". Os testes conferem que o barramento não tem nenhum.
    sem_forma,
};

const Campo = struct {
    nome: [*:0]const u8,
    /// Bytes desde o começo da estrutura; numa `packed struct`, bits.
    pos: u32 = 0,
    desc: *const Desc,
};

const Abre = *const fn (*const anyopaque, *u32) ?*const anyopaque;

const Desc = struct {
    forma: Forma,
    /// Inteiro, enum, bool e float: o tamanho na memória e os bits que valem.
    bytes: u8 = 0,
    bits: u8 = 0,
    sinal: bool = false,
    /// `packed struct`: os campos estão em `pos` bits do inteiro de `bytes` bytes.
    packed_: bool = false,
    /// Vetor: quantos.
    n: u32 = 0,
    /// Estrutura: os campos. União: as variantes (o desc é o do conteúdo).
    campos: []const Campo = &.{},
    /// Enum: os nomes, na ordem de `valores` (vazio quando os valores são 0, 1, 2…).
    nomes: []const [*:0]const u8 = &.{},
    valores: []const u64 = &.{},
    /// Opcional, ponteiro: o tipo de dentro.
    filho: ?*const Desc = null,
    /// Opcional: o conteúdo (ou null). União: a variante ativa e o conteúdo dela.
    abre: ?Abre = null,
};

const d_nada: Desc = .{ .forma = .nada };
const d_ptr: Desc = .{ .forma = .ptr };
const d_estrela: Desc = .{ .forma = .estrela };
const d_fechada: Desc = .{ .forma = .fechada };
const d_sem_tag: Desc = .{ .forma = .uniao_sem_tag };
const d_outro: Desc = .{ .forma = .outro };
const d_sem_forma: Desc = .{ .forma = .sem_forma };

const d_texto: Desc = .{ .forma = .texto };
const d_lista: Desc = .{ .forma = .lista };

/// A descrição de `T` vista na profundidade `depth` (0 = os campos da mensagem).
fn descOf(comptime T: type, comptime depth: u8) *const Desc {
    switch (@typeInfo(T)) {
        .void => return &d_nada,
        .bool => return &Folha(T).d,
        .int => |i| return if (i.bits > 64) &d_sem_forma else &Folha(T).d,
        .float => |f| return if (f.bits == 32 or f.bits == 64) &Folha(T).d else &d_sem_forma,
        .@"enum" => |e| return if (@typeInfo(e.tag_type).int.bits > 64) &d_sem_forma else &Enum(T).d,
        .optional => return &Opcional(T, depth).d,
        .pointer => |p| switch (p.size) {
            .slice => return if (p.child == u8) &d_texto else &d_lista,
            .one => switch (@typeInfo(p.child)) {
                .@"opaque", .@"fn" => return &d_ptr,
                else => return if (depth >= 2) &d_estrela else &Ponteiro(p.child, depth).d,
            },
            else => return &d_ptr,
        },
        .array => |a| return &Vetor(a.child == u8, a.len).d,
        .@"struct" => |s| {
            if (depth >= 2) return &d_fechada;
            if (s.layout == .@"packed" and @sizeOf(T) > 8) return &d_sem_forma;
            return &Estrutura(T, depth).d;
        },
        .@"union" => |u| {
            if (u.tag_type == null) return &d_sem_tag;
            return &Uniao(T, if (depth >= 2) null else depth + 1).d;
        },
        else => return &d_outro,
    }
}

fn Folha(comptime T: type) type {
    return struct {
        const d: Desc = switch (@typeInfo(T)) {
            .bool => .{ .forma = .bool, .bytes = 1, .bits = 1 },
            .int => |i| .{ .forma = .int, .bytes = @sizeOf(T), .bits = i.bits, .sinal = i.signedness == .signed },
            .float => |f| .{ .forma = .float, .bytes = @sizeOf(T), .bits = f.bits },
            else => unreachable,
        };
    };
}

fn Vetor(comptime texto: bool, comptime len: comptime_int) type {
    return struct {
        const d: Desc = .{ .forma = if (texto) .vetor_texto else .vetor, .n = len };
    };
}

fn Enum(comptime T: type) type {
    const info = @typeInfo(T).@"enum";
    const it = @typeInfo(info.tag_type).int;
    const mask: u64 = if (it.bits == 64) std.math.maxInt(u64) else (1 << it.bits) - 1;
    @setEvalBranchQuota(100_000);
    const contiguo = blk: {
        for (info.field_values, 0..) |v, k| if (v != k) break :blk false;
        break :blk true;
    };
    return struct {
        const nomes = blk: {
            @setEvalBranchQuota(100_000);
            var ns: [info.field_names.len][*:0]const u8 = undefined;
            for (info.field_names, &ns) |name, *n| n.* = name.ptr;
            break :blk ns;
        };
        const valores = blk: {
            @setEvalBranchQuota(100_000);
            var vs: [if (contiguo) 0 else info.field_values.len]u64 = undefined;
            // O padrão de bits de cada valor, como `lerU` lê da memória.
            if (!contiguo) for (info.field_values, &vs) |v, *o| {
                const raw: u64 = if (v < 0) @bitCast(@as(i64, v)) else v;
                o.* = raw & mask;
            };
            break :blk vs;
        };
        const aberto = info.mode == .nonexhaustive;
        const d: Desc = .{
            .forma = if (aberto) .enum_numero else .enum_nome,
            .bytes = @sizeOf(T),
            .bits = it.bits,
            .sinal = it.signedness == .signed,
            .nomes = if (aberto) &.{} else &nomes,
            .valores = if (aberto) &.{} else &valores,
        };
    };
}

/// Uma por tipo (não por profundidade): se tem valor e onde ele está.
fn AbreOpcional(comptime T: type) type {
    const C = @typeInfo(T).optional.child;
    return struct {
        fn abre(p: *const anyopaque, _: *u32) ?*const anyopaque {
            const o: *const T = @ptrCast(@alignCast(p));
            if (o.*) |*x| return if (@sizeOf(C) == 0) p else @as(*const anyopaque, @ptrCast(x));
            return null;
        }
    };
}

fn Opcional(comptime T: type, comptime depth: u8) type {
    return struct {
        const d: Desc = .{ .forma = .opcional, .filho = descOf(@typeInfo(T).optional.child, depth), .abre = AbreOpcional(T).abre };
    };
}

fn Ponteiro(comptime C: type, comptime depth: u8) type {
    return struct {
        const d: Desc = if (@sizeOf(*const C) == 0) d_nada else .{ .forma = .ponteiro, .filho = descOf(C, depth + 1) };
    };
}

fn Estrutura(comptime T: type, comptime depth: u8) type {
    const info = @typeInfo(T).@"struct";
    const packed_ = info.layout == .@"packed";
    return struct {
        const campos = blk: {
            @setEvalBranchQuota(100_000);
            var cs: [info.field_names.len]Campo = undefined;
            for (info.field_names, info.field_types, info.field_attrs, &cs) |name, ty, attrs, *cp| {
                // Um campo comptime não está na memória do valor.
                cp.* = .{
                    .nome = name.ptr,
                    .pos = if (attrs.@"comptime") 0 else if (packed_) @bitOffsetOf(T, name) else @offsetOf(T, name),
                    .desc = if (attrs.@"comptime") &d_sem_forma else descOf(ty, depth + 1),
                };
            }
            break :blk cs;
        };
        const d: Desc = .{
            .forma = .estrutura,
            .campos = &campos,
            .packed_ = packed_,
            .bytes = if (packed_) @sizeOf(T) else 0,
            .bits = if (packed_) @bitSizeOf(T) else 0,
        };
    };
}

/// Uma por tipo (não por profundidade): a variante ativa e onde está o conteúdo dela.
fn AbreUniao(comptime T: type) type {
    return struct {
        fn abre(p: *const anyopaque, i: *u32) ?*const anyopaque {
            // As uniões do barramento têm mais de cem variantes.
            @setEvalBranchQuota(100_000);
            const u: *const T = @ptrCast(@alignCast(p));
            switch (u.*) {
                inline else => |*x, tag| {
                    i.* = comptime std.meta.fieldIndex(T, @tagName(tag)).?;
                    return if (@sizeOf(@TypeOf(x.*)) == 0) p else @as(*const anyopaque, @ptrCast(x));
                },
            }
        }
    };
}

/// `conteudo`: a profundidade do conteúdo das variantes, ou null para só a etiqueta.
fn Uniao(comptime T: type, comptime conteudo: ?u8) type {
    const info = @typeInfo(T).@"union";
    return struct {
        const campos = blk: {
            @setEvalBranchQuota(100_000);
            var cs: [info.field_names.len]Campo = undefined;
            for (info.field_names, info.field_types, &cs) |name, ty, *cp| cp.* = .{
                .nome = name.ptr,
                .desc = if (conteudo) |dp| (if (ty == void) &d_nada else descOf(ty, dp)) else &d_nada,
            };
            break :blk cs;
        };
        const d: Desc = .{ .forma = if (conteudo == null) .uniao_nome else .uniao, .campos = &campos, .abre = AbreUniao(T).abre };
    };
}

// --- O percurso -------------------------------------------------------------------

fn lerU(p: *const anyopaque, bytes: u8) u64 {
    const b: [*]const u8 = @ptrCast(p);
    return switch (bytes) {
        1 => b[0],
        2 => std.mem.readInt(u16, b[0..2], .native),
        4 => std.mem.readInt(u32, b[0..4], .native),
        8 => std.mem.readInt(u64, b[0..8], .native),
        else => 0,
    };
}

fn mascara(v: u64, bits: u8) u64 {
    return if (bits >= 64) v else v & ((@as(u64, 1) << @intCast(bits)) - 1);
}

fn escreveInt(w: *std.Io.Writer, v: u64, bits: u8, sinal: bool) void {
    if (sinal and bits > 0) {
        const sh: u6 = @intCast(64 - @as(u32, bits));
        const s: i64 = @as(i64, @bitCast(v << sh)) >> sh;
        w.print("{d}", .{s}) catch {};
    } else w.print("{d}", .{v}) catch {};
}

fn str(z: [*:0]const u8) []const u8 {
    return std.mem.span(z);
}

/// Um campo de `packed struct`: os bits dele, gravados num valor do tamanho do tipo dele
/// (a leitura de cada forma é pela memória, como nos outros).
fn campoPacked(w: *std.Io.Writer, inteiro: u64, cp: *const Campo) void {
    const f = cp.desc;
    switch (f.forma) {
        .bool, .int, .float, .enum_nome, .enum_numero, .estrutura => {},
        // Os que não leem a memória ("{…}", "{union}").
        .nada, .fechada, .uniao_sem_tag, .outro, .sem_forma => return escreve(w, f, &inteiro),
        // Um ponteiro dentro de uma packed struct: não vale ler.
        else => {
            w.writeAll("?") catch {};
            return;
        },
    }
    var buf: [8]u8 align(8) = @splat(0);
    const v = mascara(inteiro >> @intCast(cp.pos), f.bits);
    switch (f.bytes) {
        1 => buf[0] = @truncate(v),
        2 => std.mem.writeInt(u16, buf[0..2], @truncate(v), .native),
        4 => std.mem.writeInt(u32, buf[0..4], @truncate(v), .native),
        8 => std.mem.writeInt(u64, buf[0..8], v, .native),
        else => {},
    }
    escreve(w, f, &buf);
}

fn escreve(w: *std.Io.Writer, d: *const Desc, p: *const anyopaque) void {
    switch (d.forma) {
        .nada => {},
        .bool => w.writeAll(if (lerU(p, 1) & 1 != 0) "true" else "false") catch {},
        .int => escreveInt(w, mascara(lerU(p, d.bytes), d.bits), d.bits, d.sinal),
        .float => if (d.bits == 32) {
            const f: *const f32 = @ptrCast(@alignCast(p));
            w.print("{d:.3}", .{f.*}) catch {};
        } else {
            const f: *const f64 = @ptrCast(@alignCast(p));
            w.print("{d:.3}", .{f.*}) catch {};
        },
        .enum_numero => escreveInt(w, mascara(lerU(p, d.bytes), d.bits), d.bits, d.sinal),
        .enum_nome => {
            const v = mascara(lerU(p, d.bytes), d.bits);
            if (d.valores.len == 0) {
                if (v < d.nomes.len) w.writeAll(str(d.nomes[@intCast(v)])) catch {};
            } else for (d.valores, d.nomes) |x, n| if (x == v) {
                w.writeAll(str(n)) catch {};
                break;
            };
        },
        .opcional => {
            var i: u32 = 0;
            if (d.abre.?(p, &i)) |x| escreve(w, d.filho.?, x) else w.writeAll("null") catch {};
        },
        .texto => {
            const s: *const []const u8 = @ptrCast(@alignCast(p));
            w.writeByte('"') catch {};
            w.writeAll(s.*[0..@min(s.len, 160)]) catch {};
            if (s.len > 160) w.writeAll("…") catch {};
            w.writeByte('"') catch {};
        },
        .lista => {
            // Só o tamanho: o mesmo lugar em qualquer fatia.
            const s: *const []const u8 = @ptrCast(@alignCast(p));
            w.print("[{d}]", .{s.len}) catch {};
        },
        .ponteiro => {
            const q: *const *const anyopaque = @ptrCast(@alignCast(p));
            escreve(w, d.filho.?, q.*);
        },
        .ptr => w.writeAll("ptr") catch {},
        .estrela => w.writeAll("*") catch {},
        .vetor_texto => {
            const b: [*]const u8 = @ptrCast(p);
            const s = std.mem.sliceTo(b[0..d.n], 0);
            w.print("\"{s}\"", .{s[0..@min(s.len, 160)]}) catch {};
        },
        .vetor => w.print("[{d}]", .{d.n}) catch {},
        .estrutura => {
            w.writeAll("{") catch {};
            const inteiro = if (d.packed_) lerU(p, d.bytes) else 0;
            for (d.campos, 0..) |*cp, i| {
                if (i > 0) w.writeAll(", ") catch {};
                w.writeAll(str(cp.nome)) catch {};
                w.writeAll("=") catch {};
                if (d.packed_) {
                    campoPacked(w, inteiro, cp);
                } else {
                    const b: [*]const u8 = @ptrCast(p);
                    escreve(w, cp.desc, b + cp.pos);
                }
            }
            w.writeAll("}") catch {};
        },
        .fechada => w.writeAll("{…}") catch {},
        .uniao, .uniao_nome => {
            var i: u32 = 0;
            const x = d.abre.?(p, &i).?;
            const cp = &d.campos[i];
            w.writeAll(str(cp.nome)) catch {};
            if (d.forma == .uniao and cp.desc.forma != .nada) {
                w.writeAll("(") catch {};
                escreve(w, cp.desc, x);
                w.writeAll(")") catch {};
            }
        },
        .uniao_sem_tag => w.writeAll("{union}") catch {},
        .outro, .sem_forma => w.writeAll("?") catch {},
    }
}

/// A etiqueta (o nome da variante ativa) de `value`, uma união do barramento, e o texto
/// curto do conteúdo dela em `w`.
pub fn uniao(w: *std.Io.Writer, value: anytype) []const u8 {
    const d = comptime &Uniao(@TypeOf(value), 0).d;
    var i: u32 = 0;
    const x = d.abre.?(&value, &i).?;
    const cp = &d.campos[i];
    escreve(w, cp.desc, x);
    return str(cp.nome);
}

/// O texto curto de um valor qualquer (o que não é uma união do barramento).
pub fn valor(w: *std.Io.Writer, value: anytype) void {
    escreve(w, comptime descOf(@TypeOf(value), 0), &value);
}

// --- Testes -------------------------------------------------------------------------

const t = std.testing;

/// O formatador de antes (uma função por tipo, com o `std.fmt`), só para os testes: o
/// novo tem de escrever exatamente o mesmo texto.
fn referencia(w: *std.Io.Writer, v: anytype, comptime depth: u8) void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .void => {},
        .bool => w.writeAll(if (v) "true" else "false") catch {},
        .int, .comptime_int => w.print("{d}", .{v}) catch {},
        .float, .comptime_float => w.print("{d:.3}", .{v}) catch {},
        .@"enum" => |en| if (en.mode == .exhaustive) w.writeAll(@tagName(v)) catch {} else w.print("{d}", .{@intFromEnum(v)}) catch {},
        .optional => if (v) |x| referencia(w, x, depth) else w.writeAll("null") catch {},
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) {
                const s: []const u8 = v;
                w.writeByte('"') catch {};
                w.writeAll(s[0..@min(s.len, 160)]) catch {};
                if (s.len > 160) w.writeAll("…") catch {};
                w.writeByte('"') catch {};
            } else {
                w.print("[{d}]", .{v.len}) catch {};
            },
            .one => switch (@typeInfo(p.child)) {
                .@"opaque", .@"fn" => w.writeAll("ptr") catch {},
                else => if (depth < 2) referencia(w, v.*, depth + 1) else w.writeAll("*") catch {},
            },
            else => w.writeAll("ptr") catch {},
        },
        .array => |a| if (a.child == u8) {
            const s = std.mem.sliceTo(&v, 0);
            w.print("\"{s}\"", .{s[0..@min(s.len, 160)]}) catch {};
        } else w.print("[{d}]", .{a.len}) catch {},
        .@"struct" => |s| {
            if (depth >= 2) {
                w.writeAll("{…}") catch {};
                return;
            }
            w.writeAll("{") catch {};
            inline for (s.field_names, 0..) |name, i| {
                if (i > 0) w.writeAll(", ") catch {};
                w.writeAll(name ++ "=") catch {};
                referencia(w, @field(v, name), depth + 1);
            }
            w.writeAll("}") catch {};
        },
        .@"union" => |u| {
            if (u.tag_type == null) {
                w.writeAll("{union}") catch {};
                return;
            }
            const tag = std.meta.activeTag(v);
            w.writeAll(@tagName(tag)) catch {};
            if (depth >= 2) return;
            inline for (u.field_names, u.field_types) |name, ty| {
                if (ty != void and tag == @field(std.meta.Tag(T), name)) {
                    w.writeAll("(") catch {};
                    referencia(w, @field(v, name), depth + 1);
                    w.writeAll(")") catch {};
                }
            }
        },
        else => w.writeAll("?") catch {},
    }
}

/// O texto da mensagem `value` (uma união) pelo de antes e pelo novo, comparados.
fn confere(value: anytype) !void {
    @setEvalBranchQuota(100_000);
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    var wa = std.Io.Writer.fixed(&a);
    var wb = std.Io.Writer.fixed(&b);
    const T = @TypeOf(value);
    const tag = uniao(&wa, value);
    inline for (@typeInfo(T).@"union".field_names) |name| {
        if (std.meta.activeTag(value) == @field(std.meta.Tag(T), name)) {
            try t.expectEqualStrings(name, tag);
            referencia(&wb, @field(value, name), 0);
        }
    }
    try t.expectEqualStrings(wb.buffered(), wa.buffered());
}

fn confereValor(value: anytype) !void {
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    var wa = std.Io.Writer.fixed(&a);
    var wb = std.Io.Writer.fixed(&b);
    valor(&wa, value);
    referencia(&wb, value, 0);
    try t.expectEqualStrings(wb.buffered(), wa.buffered());
}

const E1 = enum(u2) { a, b, c };
const E2 = enum(i8) { neg = -3, um = 1, mil = 100 };
const E3 = enum(u16) { x = 5, _ };
const Pk = packed struct(u16) { a: bool, b: u3, c: E1, d: i4, e: bool, f: packed struct(u3) { x: bool, y: u2 }, _p: u2 = 0 };
const In = struct { n: u32, s: []const u8, fundo: struct { x: u8, mais: struct { y: u8 } }, e: E2 };
const Un = union(enum) { vazio, num: i32, est: In, dentro: union(enum) { a: u8, b: void, c: In } };
const Tudo = struct {
    b: bool,
    i8_: i8,
    u7_: u7,
    i33_: i33,
    u64_: u64,
    i64_: i64,
    us: usize,
    f: f32,
    dd: f64,
    e1: E1,
    e2: E2,
    e3: E3,
    o1: ?u32,
    o2: ?[]const u8,
    o3: ?*const In,
    o4: ?E2,
    s: []const u8,
    longo: []const u8,
    z: [:0]const u8,
    l: []const u32,
    arr: [8]u8,
    arr2: [3]u16,
    p: *const In,
    pp: *const *const In,
    op: *const anyopaque,
    fp: *const fn () void,
    many: [*]const u8,
    in_: In,
    un: Un,
    un2: Un,
    un3: Un,
    pk: Pk,
    v: void,
    vazia: struct {},
    ut: extern union { a: u32, b: f32 },
    u0_: u0,
};

fn nada() void {}

test "o texto curto é o mesmo do formatador de antes em cada forma" {
    const in1: In = .{ .n = 7, .s = "oi \"x\"", .fundo = .{ .x = 3, .mais = .{ .y = 4 } }, .e = .mil };
    const pin: *const In = &in1;
    var longo: [200]u8 = undefined;
    @memset(&longo, 'a');
    const tudo: Tudo = .{
        .b = true,
        .i8_ = -128,
        .u7_ = 127,
        .i33_ = -4294967296,
        .u64_ = std.math.maxInt(u64),
        .i64_ = std.math.minInt(i64),
        .us = 12345,
        .f = 1.25,
        .dd = -3.14159,
        .e1 = .c,
        .e2 = .neg,
        .e3 = @enumFromInt(9),
        .o1 = null,
        .o2 = "talvez",
        .o3 = &in1,
        .o4 = .mil,
        .s = "texto",
        .longo = &longo,
        .z = "fim",
        .l = &.{ 1, 2, 3 },
        .arr = "abc\x00defg".*,
        .arr2 = .{ 1, 2, 3 },
        .p = &in1,
        .pp = &pin,
        .op = @ptrCast(&in1),
        .fp = &nada,
        .many = "x",
        .in_ = in1,
        .un = .{ .est = in1 },
        .un2 = .{ .dentro = .{ .c = in1 } },
        .un3 = .vazio,
        .pk = .{ .a = true, .b = 5, .c = .b, .d = -3, .e = false, .f = .{ .x = true, .y = 2 } },
        .v = {},
        .vazia = .{},
        .ut = .{ .a = 1 },
        .u0_ = 0,
    };
    try confereValor(tudo);
    try confereValor(in1);
    try confereValor(Un{ .dentro = .{ .b = {} } });
    try confereValor(Un{ .num = -5 });
    try confereValor(@as(?u8, null));
    // Como mensagem: o conteúdo da variante na profundidade 0.
    const M = union(enum) { tudo: Tudo, in_: In, un: Un, pk: Pk, nada, num: u16 };
    try confere(M{ .tudo = tudo });
    try confere(M{ .in_ = in1 });
    try confere(M{ .un = .{ .dentro = .{ .c = in1 } } });
    try confere(M{ .pk = tudo.pk });
    try confere(@as(M, .nada));
    try confere(M{ .num = 9 });
    // Um caso escrito à mão, para não depender só do de antes.
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try t.expectEqualStrings("est", uniao(&w, Un{ .est = in1 }));
    try t.expectEqualStrings("{n=7, s=\"oi \"x\"\", fundo={x=3, mais={…}}, e=mil}", w.buffered());
}

const ev = @import("../core/event.zig");
const types = @import("../core/types.zig");

test "mensagens de verdade do barramento saem como antes" {
    const msg: types.Message = .{ .id = 11, .channel = 22, .author = 33, .timestamp = 1_700_000_000, .content = "olá", .mention_roles = &.{ 1, 2 } };
    try confere(ev.Event{ .message_create = msg });
    var msgs = [_]types.Message{ msg, msg };
    try confere(ev.Event{ .history = .{ .channel = 22, .messages = &msgs, .older = true } });
    try confere(ev.Event{ .message_update = .{ .channel = 1, .id = 2, .content = null, .pinned = true, .mentions = .{ .me = true, .roles = &.{3} } } });
    try confere(ev.Event{ .typing_start = .{ .channel = 5, .user = 6 } });
    try confere(ev.Action{ .send_message = "uma mensagem" });
    try confere(ev.Action{ .set_voice_volume = .{ .user = 9, .volume = 0.5 } });
    try confere(@as(ev.Action, .leave_voice));
    try confere(ev.Action{ .select_channel = 42 });
    try confere(ev.Command{ .send_message = .{ .channel = 1, .content = "oi", .nonce = 77 } });
}

/// Percorre as descrições (com cada uma visitada uma vez) e conta as `sem_forma`.
fn contaOutros(d: *const Desc, vistos: *std.AutoHashMapUnmanaged(usize, void)) !usize {
    if ((try vistos.getOrPut(t.allocator, @intFromPtr(d))).found_existing) return 0;
    var n: usize = if (d.forma == .sem_forma) 1 else 0;
    if (d.filho) |f| n += try contaOutros(f, vistos);
    for (d.campos) |*cp| n += try contaOutros(cp.desc, vistos);
    return n;
}

test "nenhum tipo do barramento fica sem forma (o de antes escreveria outra coisa)" {
    var vistos: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer vistos.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), try contaOutros(comptime &Uniao(ev.Event, 0).d, &vistos));
    try t.expectEqual(@as(usize, 0), try contaOutros(comptime &Uniao(ev.Action, 0).d, &vistos));
    try t.expectEqual(@as(usize, 0), try contaOutros(comptime &Uniao(ev.Command, 0).d, &vistos));
    try t.expect(vistos.count() > 100);
}
