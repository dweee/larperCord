//! As contas do editor de imagens da bandeja (ui/editor_imagem.zig), em RGBA de 8 bits:
//! endireitar a foto pela orientação do Exif, esconder um pedaço com blocos grandes ou
//! uma tarja preta, e recortar. Nada aqui desenha nem lê arquivo.
//!
//! Esconder vale de verdade: os pixels de baixo somem do arquivo que sai. Por isso não
//! há desfoque leve (um texto desfocado de leve dá para ler de volta) e os blocos são
//! grandes, com o tamanho pelo pedaço e pela imagem, e com um ruído sorteado por bloco:
//! os programas que tentam desfazer uma pixelização comparam a média exata de cada bloco
//! com a de cada letra possível, e o ruído tira essa pista.
const std = @import("std");
const metadados = @import("metadados.zig");

/// O editor abre: JPEG, BMP e PNG parado (ele lida com um quadro só; um GIF ou um PNG
/// animado perderia a animação).
pub fn podeEditar(d: []const u8) bool {
    return switch (metadados.formato(d)) {
        .jpeg => true,
        .png => !pngAnimado(d),
        else => d.len > 2 and d[0] == 'B' and d[1] == 'M',
    };
}

/// Um acTL antes da imagem: é um APNG.
fn pngAnimado(d: []const u8) bool {
    var i: usize = 8;
    while (d.len - i >= 12) {
        const n = std.mem.readInt(u32, d[i..][0..4], .big);
        const tipo = d[i + 4 .. i + 8];
        if (std.mem.eql(u8, tipo, "acTL")) return true;
        if (std.mem.eql(u8, tipo, "IDAT") or n > d.len - i - 12) return false;
        i += 12 + n;
    }
    return false;
}

/// Um retângulo em pixels da imagem inteira (já endireitada).
pub const Ret = struct {
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,

    pub fn right(r: Ret) u32 {
        return r.x + r.w;
    }
    pub fn bottom(r: Ret) u32 {
        return r.y + r.h;
    }
    pub fn eql(a: Ret, b: Ret) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }
    /// A parte de `r` dentro de `o` (largura 0 quando não se tocam).
    pub fn dentro(r: Ret, o: Ret) Ret {
        const x0 = @max(r.x, o.x);
        const y0 = @max(r.y, o.y);
        const x1 = @min(r.right(), o.right());
        const y1 = @min(r.bottom(), o.bottom());
        if (x1 <= x0 or y1 <= y0) return .{ .x = x0, .y = y0 };
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
};

pub const Modo = enum { blocos, tarja };

/// Um pedaço escondido. `bloco` e `semente` são decididos ao criar: a prévia e o
/// arquivo que sai mostram os mesmos blocos com o mesmo ruído.
pub const Area = struct {
    r: Ret,
    modo: Modo,
    bloco: u32 = 0,
    semente: u64 = 0,
};

/// O lado do bloco de um pedaço `aw`×`ah` numa imagem `iw`×`ih`: um sexto do lado maior
/// do pedaço, nunca menos que 1/80 da imagem nem que 10 pixels. Uma linha de texto vira
/// uma fileira de poucos blocos, cada um mais largo que várias letras; um rosto, uns
/// 6×6 borrões.
pub fn ladoBloco(aw: u32, ah: u32, iw: u32, ih: u32) u32 {
    return @max(@max(aw, ah) / 6, @max(iw, ih) / 80, 10);
}

/// O tamanho depois de endireitar pela orientação `o` (5 a 8 trocam os lados).
pub fn tamanhoOrientado(w: u32, h: u32, o: u8) [2]u32 {
    return if (o >= 5 and o <= 8) .{ h, w } else .{ w, h };
}

/// Copia `src` (`w`×`h`) para `dst` já endireitada pela orientação `o` do Exif (1..8):
/// `dst` tem o tamanho de `tamanhoOrientado`.
pub fn orientar(src: []const u8, w: u32, h: u32, o: u8, dst: []u8) void {
    const ow, const oh = tamanhoOrientado(w, h, o);
    std.debug.assert(dst.len >= @as(usize, ow) * oh * 4 and src.len >= @as(usize, w) * h * 4);
    if (o < 2 or o > 8) {
        const n = @as(usize, w) * h * 4;
        return @memcpy(dst[0..n], src[0..n]);
    }
    for (0..oh) |y| for (0..ow) |x| {
        // De onde vem o pixel (x, y) da imagem de pé.
        const s: [2]usize = switch (o) {
            2 => .{ w - 1 - x, y },
            3 => .{ w - 1 - x, h - 1 - y },
            4 => .{ x, h - 1 - y },
            5 => .{ y, x },
            6 => .{ y, h - 1 - x },
            7 => .{ w - 1 - y, h - 1 - x },
            else => .{ w - 1 - y, x },
        };
        dst[(y * ow + x) * 4 ..][0..4].* = src[(s[1] * w + s[0]) * 4 ..][0..4].*;
    };
}

/// Esconde `a` em `px` (`bw`×`bh`), que mostra a imagem a partir do ponto (`ox`, `oy`)
/// numa escala `kx`, `ky` (1 no arquivo que sai, que é o recorte; menos na prévia, que é
/// a imagem inteira reduzida).
pub fn esconder(px: []u8, bw: u32, bh: u32, a: Area, ox: u32, oy: u32, kx: f32, ky: f32) void {
    if (a.r.w == 0 or a.r.h == 0) return;
    const Pos = struct {
        /// A coluna (ou linha) do buffer onde fica a coordenada `v` da imagem.
        fn de(v: u32, o: u32, k: f32, lim: u32) u32 {
            const f = (@as(f32, @floatFromInt(v)) - @as(f32, @floatFromInt(o))) * k;
            return @intFromFloat(std.math.clamp(@round(f), 0, @as(f32, @floatFromInt(lim))));
        }
    };
    switch (a.modo) {
        .tarja => {
            const x0 = Pos.de(a.r.x, ox, kx, bw);
            const x1 = Pos.de(a.r.right(), ox, kx, bw);
            const y0 = Pos.de(a.r.y, oy, ky, bh);
            const y1 = Pos.de(a.r.bottom(), oy, ky, bh);
            for (y0..y1) |y| for (x0..x1) |x| {
                px[(y * bw + x) * 4 ..][0..4].* = .{ 0, 0, 0, 255 };
            };
        },
        .blocos => {
            const lado = @max(a.bloco, 1);
            var by: u32 = 0;
            while (by * lado < a.r.h) : (by += 1) {
                var bx: u32 = 0;
                while (bx * lado < a.r.w) : (bx += 1) {
                    // O bloco na imagem inteira, e onde ele cai neste buffer.
                    const ix0 = a.r.x + bx * lado;
                    const iy0 = a.r.y + by * lado;
                    const ix1 = @min(ix0 + lado, a.r.right());
                    const iy1 = @min(iy0 + lado, a.r.bottom());
                    const x0 = Pos.de(ix0, ox, kx, bw);
                    const x1 = Pos.de(ix1, ox, kx, bw);
                    const y0 = Pos.de(iy0, oy, ky, bh);
                    const y1 = Pos.de(iy1, oy, ky, bh);
                    if (x1 <= x0 or y1 <= y0) continue;
                    var soma: [4]u64 = .{ 0, 0, 0, 0 };
                    for (y0..y1) |y| for (x0..x1) |x| {
                        const p = px[(y * bw + x) * 4 ..][0..4];
                        for (0..4) |k| soma[k] += p[k];
                    };
                    const n: u64 = @as(u64, x1 - x0) * (y1 - y0);
                    var cor: [4]u8 = undefined;
                    var chave: [12]u8 = undefined;
                    std.mem.writeInt(u32, chave[0..4], bx, .little);
                    std.mem.writeInt(u32, chave[4..8], by, .little);
                    std.mem.writeInt(u32, chave[8..12], lado, .little);
                    const ruido = std.hash.Wyhash.hash(a.semente, &chave);
                    for (0..3) |k| {
                        // Até 16 para cada lado em cada canal.
                        const r: i32 = @as(i32, @intCast((ruido >> @intCast(k * 8)) & 31)) - 16;
                        cor[k] = @intCast(std.math.clamp(@as(i32, @intCast(soma[k] / n)) + r, 0, 255));
                    }
                    cor[3] = @intCast(soma[3] / n);
                    for (y0..y1) |y| for (x0..x1) |x| {
                        px[(y * bw + x) * 4 ..][0..4].* = cor;
                    };
                }
            }
        },
    }
}

/// O pedaço `r` de `px` (`w` de largura) numa cópia nova, com as áreas escondidas por cima.
pub fn recortar(gpa: std.mem.Allocator, px: []const u8, w: u32, r: Ret, areas: []const Area) ![]u8 {
    const out = try gpa.alloc(u8, @as(usize, r.w) * r.h * 4);
    for (0..r.h) |y| {
        const de = ((r.y + y) * w + r.x) * 4;
        @memcpy(out[y * r.w * 4 ..][0 .. r.w * 4], px[de..][0 .. r.w * 4]);
    }
    for (areas) |a| esconder(out, r.w, r.h, a, r.x, r.y, 1, 1);
    return out;
}

// --- Testes ------------------------------------------------------------------------

const testing = std.testing;

/// Cada pixel com a própria posição: dá para saber de onde ele veio.
fn numerada(gpa: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    const px = try gpa.alloc(u8, w * h * 4);
    for (0..h) |y| for (0..w) |x| {
        px[(y * w + x) * 4 ..][0..4].* = .{ @intCast(x), @intCast(y), @intCast((x * 7 + y * 3) % 256), 255 };
    };
    return px;
}

fn pixel(px: []const u8, w: u32, x: usize, y: usize) [4]u8 {
    return px[(y * w + x) * 4 ..][0..4].*;
}

test "orientar: as oito orientações do Exif, conferidas pelos cantos" {
    const gpa = testing.allocator;
    const src = try numerada(gpa, 3, 2);
    defer gpa.free(src);
    const dst = try gpa.alloc(u8, 3 * 2 * 4);
    defer gpa.free(dst);
    // O canto de cima à esquerda da foto de pé vem de qual pixel (x, y) do arquivo.
    const cantos = [_][2]u8{ .{ 0, 0 }, .{ 0, 0 }, .{ 2, 0 }, .{ 2, 1 }, .{ 0, 1 }, .{ 0, 0 }, .{ 0, 1 }, .{ 2, 1 }, .{ 2, 0 } };
    for (1..9) |o8| {
        const o: u8 = @intCast(o8);
        orientar(src, 3, 2, o, dst);
        const ow, const oh = tamanhoOrientado(3, 2, o);
        try testing.expectEqual(@as(u32, if (o >= 5) 2 else 3), ow);
        try testing.expectEqual(@as(u32, if (o >= 5) 3 else 2), oh);
        const p = pixel(dst, ow, 0, 0);
        try testing.expectEqual(cantos[o][0], p[0]);
        try testing.expectEqual(cantos[o][1], p[1]);
    }
    // Girar 90° para a direita (6): a coluna da esquerda, de baixo para cima, vira a primeira linha.
    orientar(src, 3, 2, 6, dst);
    try testing.expectEqual([4]u8{ 0, 1, 3, 255 }, pixel(dst, 2, 0, 0));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pixel(dst, 2, 1, 0));
    try testing.expectEqual([4]u8{ 2, 1, 17, 255 }, pixel(dst, 2, 0, 2));
}

test "esconder: blocos cobrem só o pedaço, cada bloco de uma cor; a tarja é preta" {
    const gpa = testing.allocator;
    const w: u32 = 60;
    const h: u32 = 40;
    const px = try numerada(gpa, w, h);
    defer gpa.free(px);
    const orig = try gpa.dupe(u8, px);
    defer gpa.free(orig);
    const a: Area = .{ .r = .{ .x = 10, .y = 5, .w = 25, .h = 17 }, .modo = .blocos, .bloco = 8, .semente = 99 };
    esconder(px, w, h, a, 0, 0, 1, 1);
    for (0..h) |y| for (0..w) |x| {
        const dentro_ = x >= 10 and x < 35 and y >= 5 and y < 22;
        if (!dentro_) try testing.expectEqual(pixel(orig, w, x, y), pixel(px, w, x, y));
    };
    // Um bloco inteiro (10..18 × 5..13) é uma cor só, e não é mais o original.
    const c0 = pixel(px, w, 10, 5);
    for (5..13) |y| for (10..18) |x| try testing.expectEqual(c0, pixel(px, w, x, y));
    var mudaram: usize = 0;
    for (5..22) |y| for (10..35) |x| {
        if (!std.mem.eql(u8, &pixel(orig, w, x, y), &pixel(px, w, x, y))) mudaram += 1;
    };
    try testing.expect(mudaram > 25 * 17 * 9 / 10);
    // A mesma área de novo dá os mesmos blocos (a semente decide o ruído).
    const outra = try gpa.dupe(u8, orig);
    defer gpa.free(outra);
    esconder(outra, w, h, a, 0, 0, 1, 1);
    try testing.expectEqualSlices(u8, px, outra);
    esconder(outra, w, h, .{ .r = .{ .x = 50, .y = 30, .w = 20, .h = 20 }, .modo = .tarja }, 0, 0, 1, 1);
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pixel(outra, w, 59, 39));
    try testing.expectEqual(pixel(orig, w, 49, 39), pixel(outra, w, 49, 39));
}

test "recortar: o pedaço certo, com as áreas no lugar delas dentro do recorte" {
    const gpa = testing.allocator;
    const w: u32 = 50;
    const px = try numerada(gpa, w, 30);
    defer gpa.free(px);
    const corte: Ret = .{ .x = 12, .y = 4, .w = 20, .h = 15 };
    const areas = [_]Area{.{ .r = .{ .x = 20, .y = 10, .w = 30, .h = 30 }, .modo = .tarja }};
    const out = try recortar(gpa, px, w, corte, &areas);
    defer gpa.free(out);
    try testing.expectEqual(pixel(px, w, 12, 4), pixel(out, 20, 0, 0));
    try testing.expectEqual(pixel(px, w, 19, 18), pixel(out, 20, 7, 14));
    // A tarja começa em (20, 10) da imagem: (8, 6) do recorte, até o fim dele.
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pixel(out, 20, 8, 6));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pixel(out, 20, 19, 14));
    try testing.expectEqual(pixel(px, w, 19, 10), pixel(out, 20, 7, 6));
    // Na prévia (metade do tamanho) a tarja cai no mesmo lugar, em escala.
    const prev = try gpa.alloc(u8, 25 * 15 * 4);
    defer gpa.free(prev);
    @memset(prev, 200);
    esconder(prev, 25, 15, areas[0], 0, 0, 0.5, 0.5);
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pixel(prev, 25, 10, 5));
    try testing.expectEqual([4]u8{ 200, 200, 200, 200 }, pixel(prev, 25, 9, 5));
}

test "podeEditar: JPEG, BMP e PNG parado; APNG, GIF e o resto não" {
    const png_escrita = @import("png_escrita.zig");
    const gpa = testing.allocator;
    const px = try numerada(gpa, 4, 3);
    defer gpa.free(px);
    const png = try png_escrita.codificar(gpa, px, 4, 3, 16);
    defer gpa.free(png);
    try testing.expect(podeEditar(png));
    var apng: std.ArrayList(u8) = .empty;
    defer apng.deinit(gpa);
    try apng.appendSlice(gpa, png[0 .. 8 + 25]);
    try png_escrita.bloco(gpa, &apng, "acTL", &.{ 0, 0, 0, 2, 0, 0, 0, 0 });
    try apng.appendSlice(gpa, png[8 + 25 ..]);
    try testing.expect(!podeEditar(apng.items));
    try testing.expect(podeEditar(&.{ 0xFF, 0xD8, 0xFF, 0xE0 }));
    try testing.expect(podeEditar("BM\x00\x00"));
    try testing.expect(!podeEditar("GIF89a"));
    try testing.expect(!podeEditar("RIFF\x00\x00\x00\x00WEBPVP8 "));
}

test "ladoBloco e Ret.dentro" {
    try testing.expectEqual(@as(u32, 66), ladoBloco(400, 20, 1920, 1080));
    try testing.expectEqual(@as(u32, 24), ladoBloco(30, 12, 1920, 1080));
    try testing.expectEqual(@as(u32, 10), ladoBloco(30, 12, 300, 200));
    const r: Ret = .{ .x = 5, .y = 5, .w = 10, .h = 10 };
    try testing.expect(r.dentro(.{ .x = 0, .y = 0, .w = 8, .h = 100 }).eql(.{ .x = 5, .y = 5, .w = 3, .h = 10 }));
    try testing.expectEqual(@as(u32, 0), r.dentro(.{ .x = 20, .y = 0, .w = 5, .h = 5 }).w);
}
