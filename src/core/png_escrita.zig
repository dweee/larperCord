//! Escrita de PNG para o editor de imagens da bandeja (ui/editor_imagem.zig): 8 bits por
//! canal, RGB quando nenhum pixel é transparente (um print sai menor) e RGBA quando algum
//! é, um filtro por linha (o de menor soma, como a libpng escolhe) e o deflate da
//! biblioteca padrão. Só os blocos obrigatórios: nada de data, programa ou lugar no
//! arquivo que sai daqui. Tudo puro: os testes conferem o resultado no stb_image, que
//! descomprime com o código dele.
const std = @import("std");

pub const assinatura = "\x89PNG\r\n\x1a\n";

/// IDAT em pedaços deste tamanho (um só gigante também vale, mas tem leitor que se perde).
const idat_max = 256 * 1024;

/// Um bloco inteiro em `out`: tamanho, tipo, dados e o CRC do tipo com os dados.
pub fn bloco(gpa: std.mem.Allocator, out: *std.ArrayList(u8), tipo: *const [4]u8, dados: []const u8) !void {
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, @intCast(dados.len), .big);
    try out.appendSlice(gpa, &n);
    try out.appendSlice(gpa, tipo);
    try out.appendSlice(gpa, dados);
    var crc = std.hash.Crc32.init();
    crc.update(tipo);
    crc.update(dados);
    std.mem.writeInt(u32, &n, crc.final(), .big);
    try out.appendSlice(gpa, &n);
}

/// `px` em RGBA, `largura` × `altura`, cada linha começando `passo` bytes depois da
/// anterior (o recorte de uma imagem maior usa o passo dela). O PNG volta alocado com `gpa`.
pub fn codificar(gpa: std.mem.Allocator, px: []const u8, largura: u32, altura: u32, passo: usize) ![]u8 {
    std.debug.assert(largura > 0 and altura > 0 and passo >= @as(usize, largura) * 4);
    std.debug.assert(px.len >= passo * (altura - 1) + @as(usize, largura) * 4);
    const w: usize = largura;
    const opaco = blk: {
        for (0..altura) |y| {
            const lin = px[y * passo ..][0 .. w * 4];
            var x: usize = 3;
            while (x < lin.len) : (x += 4) if (lin[x] != 255) break :blk false;
        }
        break :blk true;
    };
    const bpp: usize = if (opaco) 3 else 4;
    const linha = w * bpp;
    // A linha de cima e a de agora sem filtro, e as cinco tentativas (cada uma com o byte
    // do filtro na frente).
    const buf = try gpa.alloc(u8, linha * 2 + (linha + 1) * 5);
    defer gpa.free(buf);
    var cima = buf[0..linha];
    var agora = buf[linha .. linha * 2];
    @memset(cima, 0);
    const tentativas = buf[linha * 2 ..];

    var z: std.Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    defer z.deinit();
    const janela = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(janela);
    // Uns 224 KB de tabelas: fora da pilha.
    const comp = try gpa.create(std.compress.flate.Compress);
    defer gpa.destroy(comp);
    comp.* = std.compress.flate.Compress.init(&z.writer, janela, .zlib, .default) catch return error.OutOfMemory;
    for (0..altura) |y| {
        const src = px[y * passo ..][0 .. w * 4];
        if (opaco) {
            for (0..w) |x| agora[x * 3 ..][0..3].* = src[x * 4 ..][0..3].*;
        } else @memcpy(agora, src);
        // (O Allocating só falha sem memória.)
        comp.writer.writeAll(filtrar(agora, cima, bpp, tentativas)) catch return error.OutOfMemory;
        std.mem.swap([]u8, &cima, &agora);
    }
    comp.finish() catch return error.OutOfMemory;
    const zs = z.written();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, zs.len + 64 + (zs.len / idat_max + 1) * 12);
    out.appendSliceAssumeCapacity(assinatura);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], largura, .big);
    std.mem.writeInt(u32, ihdr[4..8], altura, .big);
    // 8 bits; RGB (2) ou RGBA (6); deflate, filtros por linha, sem entrelaçar.
    ihdr[8] = 8;
    ihdr[9] = if (opaco) 2 else 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try bloco(gpa, &out, "IHDR", &ihdr);
    var i: usize = 0;
    while (i < zs.len) {
        const n = @min(idat_max, zs.len - i);
        try bloco(gpa, &out, "IDAT", zs[i .. i + n]);
        i += n;
    }
    try bloco(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

/// Os cinco filtros do PNG na linha `agora` (com a de cima em `cima`): volta o de menor
/// soma dos bytes lidos com sinal, com o tipo do filtro na frente.
fn filtrar(agora: []const u8, cima: []const u8, bpp: usize, tentativas: []u8) []const u8 {
    const n = agora.len;
    var melhor: []const u8 = tentativas[0 .. n + 1];
    var menor: u64 = std.math.maxInt(u64);
    for (0..5) |f| {
        const o = tentativas[f * (n + 1) ..][0 .. n + 1];
        o[0] = @intCast(f);
        var soma: u64 = 0;
        for (0..n) |i| {
            const a: u8 = if (i >= bpp) agora[i - bpp] else 0;
            const b = cima[i];
            const cc: u8 = if (i >= bpp) cima[i - bpp] else 0;
            const x = agora[i];
            const v: u8 = switch (f) {
                0 => x,
                1 => x -% a,
                2 => x -% b,
                3 => x -% @as(u8, @intCast((@as(u16, a) + b) / 2)),
                else => x -% paeth(a, b, cc),
            };
            o[i + 1] = v;
            soma += if (v < 128) v else 256 - @as(u64, v);
        }
        if (soma < menor) {
            menor = soma;
            melhor = o;
        }
    }
    return melhor;
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

// --- Testes ------------------------------------------------------------------------

/// O stb_image dos testes (build.zig compila o third_party/stb/stb_image.c junto): quem
/// lê de volta é outro código, então um confere o outro. Os testes de core/metadados.zig
/// e core/imagem_edicao.zig usam também.
pub const stb = struct {
    extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, comp: *c_int, req_comp: c_int) ?[*]u8;
    extern fn stbi_image_free(p: ?*anyopaque) void;

    pub const Imagem = struct {
        px: []u8,
        w: u32,
        h: u32,
        pub fn deinit(i: Imagem) void {
            stbi_image_free(i.px.ptr);
        }
    };

    /// RGBA de 8 bits, ou null se o stb não abriu.
    pub fn abrir(dados: []const u8) ?Imagem {
        var w: c_int = 0;
        var h: c_int = 0;
        var comp: c_int = 0;
        const p = stbi_load_from_memory(dados.ptr, @intCast(dados.len), &w, &h, &comp, 4) orelse return null;
        const n: usize = @intCast(w * h * 4);
        return .{ .px = p[0..n], .w = @intCast(w), .h = @intCast(h) };
    }
};

/// Um degradê com transparência opcional (cada pixel diferente do vizinho).
fn degrade(gpa: std.mem.Allocator, w: u32, h: u32, alfa: bool) ![]u8 {
    const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
    for (0..h) |y| for (0..w) |x| {
        const o = px[(y * w + x) * 4 ..][0..4];
        o.* = .{ @truncate(x * 7 + y), @truncate(y * 5), @truncate(x ^ y), if (alfa) @truncate(255 - (x + y) % 200) else 255 };
    };
    return px;
}

test "PNG: RGB opaco e RGBA voltam iguais pelo stb_image" {
    const gpa = std.testing.allocator;
    for ([_]bool{ false, true }) |alfa| {
        const px = try degrade(gpa, 37, 23, alfa);
        defer gpa.free(px);
        const png = try codificar(gpa, px, 37, 23, 37 * 4);
        defer gpa.free(png);
        try std.testing.expect(std.mem.startsWith(u8, png, assinatura));
        // Tipo de cor no IHDR: 2 sem transparência, 6 com.
        try std.testing.expectEqual(@as(u8, if (alfa) 6 else 2), png[8 + 8 + 9]);
        const img = stb.abrir(png) orelse return error.NaoAbriu;
        defer img.deinit();
        try std.testing.expectEqual(@as(u32, 37), img.w);
        try std.testing.expectEqual(@as(u32, 23), img.h);
        try std.testing.expectEqualSlices(u8, px, img.px);
    }
}

test "PNG: recorte com o passo da imagem maior, e só os blocos obrigatórios" {
    const gpa = std.testing.allocator;
    const px = try degrade(gpa, 64, 40, false);
    defer gpa.free(px);
    // O pedaço 20×10 a partir de (11, 7).
    const ini = (7 * 64 + 11) * 4;
    const png = try codificar(gpa, px[ini..], 20, 10, 64 * 4);
    defer gpa.free(png);
    const img = stb.abrir(png) orelse return error.NaoAbriu;
    defer img.deinit();
    try std.testing.expectEqual(@as(u32, 20), img.w);
    for (0..10) |y| try std.testing.expectEqualSlices(u8, px[ini + y * 64 * 4 ..][0 .. 20 * 4], img.px[y * 20 * 4 ..][0 .. 20 * 4]);
    // Cada bloco com o CRC certo, e nenhum além de IHDR, IDAT e IEND.
    var i: usize = 8;
    while (i < png.len) {
        const n = std.mem.readInt(u32, png[i..][0..4], .big);
        const tipo = png[i + 4 .. i + 8];
        try std.testing.expect(std.mem.eql(u8, tipo, "IHDR") or std.mem.eql(u8, tipo, "IDAT") or std.mem.eql(u8, tipo, "IEND"));
        var crc = std.hash.Crc32.init();
        crc.update(png[i + 4 .. i + 8 + n]);
        try std.testing.expectEqual(crc.final(), std.mem.readInt(u32, png[i + 8 + n ..][0..4], .big));
        i += 12 + n;
    }
    try std.testing.expectEqual(png.len, i);
}

test "PNG: imagem grande vai em vários IDAT e um print liso comprime" {
    const gpa = std.testing.allocator;
    const w: u32 = 700;
    const h: u32 = 500;
    const px = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(px);
    // Ruído (não comprime: passa de um IDAT) …
    var rng = std.Random.DefaultPrng.init(7);
    rng.random().bytes(px);
    for (0..w * h) |i| px[i * 4 + 3] = 255;
    const ruido = try codificar(gpa, px, w, h, w * 4);
    defer gpa.free(ruido);
    try std.testing.expect(std.mem.count(u8, ruido, "IDAT") > 1);
    const img = stb.abrir(ruido) orelse return error.NaoAbriu;
    defer img.deinit();
    try std.testing.expectEqualSlices(u8, px, img.px);
    // … e uma tela quase toda de uma cor fica pequena.
    @memset(px, 40);
    for (0..w * h) |i| px[i * 4 + 3] = 255;
    const liso = try codificar(gpa, px, w, h, w * 4);
    defer gpa.free(liso);
    try std.testing.expect(liso.len < 8 * 1024);
}
