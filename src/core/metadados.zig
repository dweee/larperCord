//! Tirar a localização e os dados da câmera de fotos e vídeos antes de enviar
//! (Configurações → Privacidade). Só mexe numa cópia na memória: quem chama
//! (net/envio_limpo.zig) grava o resultado num arquivo temporário nosso e manda esse no
//! lugar do original, que nunca muda.
//!
//! - JPEG: ficam só os segmentos que mudam o desenho (o APP0 do JFIF, o perfil de cor no
//!   APP2 e o APP14 da Adobe). Vão embora o Exif e o XMP (APP1), o IPTC do Photoshop
//!   (APP13), os comentários e o que cada fabricante põe nos outros APPn, e também o que
//!   vem depois do fim da imagem (o vídeo de uma "foto com movimento", as imagens extras
//!   do MPF). A foto continua de pé: se o Exif mandava girar, entra no lugar um Exif
//!   mínimo só com a orientação, sem recomprimir nada.
//! - PNG: ficam os blocos críticos e os de cor e transparência; saem o eXIf (o mesmo
//!   Exif mínimo fica, se girava), os textos (tEXt, zTXt, iTXt), o tIME e os de programas.
//! - WebP: saem os blocos EXIF e XMP, e o VP8X e o tamanho do RIFF são acertados.
//! - MP4 e MOV (o GPS do celular fica no moov, em udta e meta): as caixas de lugar
//!   (©xyz, loci, a location.* da Apple) e de câmera (©mak, ©mod e o make/model da Apple)
//!   viram `free` do mesmo tamanho, com o conteúdo zerado: nenhum deslocamento muda.
//! - O resto (GIF, áudio, documentos) passa como está. Um arquivo quebrado também: vai o
//!   original, que pelo menos abre do outro lado.
const std = @import("std");
const png_escrita = @import("png_escrita.zig");

pub const Formato = enum { jpeg, png, webp, mp4, outro };

/// O formato pelos primeiros bytes (o nome do arquivo não conta).
pub fn formato(d: []const u8) Formato {
    if (d.len >= 3 and d[0] == 0xFF and d[1] == 0xD8 and d[2] == 0xFF) return .jpeg;
    if (std.mem.startsWith(u8, d, png_escrita.assinatura)) return .png;
    if (d.len >= 12 and std.mem.eql(u8, d[0..4], "RIFF") and std.mem.eql(u8, d[8..12], "WEBP")) return .webp;
    // MP4 começa no ftyp; um MOV antigo pode começar direto no moov, no mdat ou num espaço vazio.
    if (d.len >= 8) for ([_][]const u8{ "ftyp", "moov", "mdat", "free", "skip", "wide", "pnot" }) |tipo| {
        if (std.mem.eql(u8, d[4..8], tipo)) return .mp4;
    };
    return .outro;
}

pub const Erro = error{ Malformado, OutOfMemory };

/// A cópia limpa de `dados` (alocada com `gpa`), ou null quando não há o que tirar (um
/// formato que não mexemos, ou nada escondido nele). `error.Malformado`: o arquivo não é
/// o que os primeiros bytes dizem; quem chama manda o original.
pub fn limpar(gpa: std.mem.Allocator, dados: []const u8) Erro!?[]u8 {
    return switch (formato(dados)) {
        .jpeg => jpeg(gpa, dados),
        .png => png(gpa, dados),
        .webp => webp(gpa, dados),
        .mp4 => mp4(gpa, dados),
        .outro => null,
    };
}

/// A orientação do Exif de um JPEG ou PNG (1..8; 1 = como está, também sem Exif). O
/// editor da bandeja endireita a foto por ela antes de mostrar.
pub fn orientacao(d: []const u8) u8 {
    return switch (formato(d)) {
        .jpeg => jpegOrientacao(d),
        .png => pngOrientacao(d),
        else => 1,
    };
}

fn be16(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .big);
}
fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}
fn le32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}
fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// --- Exif (TIFF) -------------------------------------------------------------------

/// A orientação (tag 0x0112 do IFD0) num TIFF do Exif, ou null se não tem ou não lê.
fn tiffOrientacao(tiff: []const u8) ?u8 {
    if (tiff.len < 8) return null;
    const ordem: std.builtin.Endian = if (eql(tiff[0..2], "II")) .little else if (eql(tiff[0..2], "MM")) .big else return null;
    if (std.mem.readInt(u16, tiff[2..4], ordem) != 42) return null;
    const ifd = std.mem.readInt(u32, tiff[4..8], ordem);
    if (ifd > tiff.len or tiff.len - ifd < 2) return null;
    const n = std.mem.readInt(u16, tiff[ifd..][0..2], ordem);
    var e: usize = ifd + 2;
    var k: u16 = 0;
    while (k < n and e + 12 <= tiff.len) : ({
        k += 1;
        e += 12;
    }) {
        if (std.mem.readInt(u16, tiff[e..][0..2], ordem) != 0x0112) continue;
        // Um SHORT: o valor fica no começo do campo de 4 bytes.
        if (std.mem.readInt(u16, tiff[e + 2 ..][0..2], ordem) != 3) return null;
        const v = std.mem.readInt(u16, tiff[e + 8 ..][0..2], ordem);
        return if (v >= 1 and v <= 8) @intCast(v) else null;
    }
    return null;
}

/// Um TIFF só com a orientação: big endian, uma entrada no IFD0, sem próximo IFD.
fn tiffMinimo(o: u8) [26]u8 {
    return .{ 'M', 'M', 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, o, 0, 0, 0, 0, 0, 0 };
}

/// É o Exif mínimo que sai daqui (limpar de novo não muda nada).
fn soOrientacao(tiff: []const u8) bool {
    const o = tiffOrientacao(tiff) orelse return false;
    return eql(tiff, &tiffMinimo(o));
}

/// O TIFF de um bloco Exif do PNG ou do WebP, que deviam vir sem o "Exif\0\0" na frente
/// (mas tem programa que põe).
fn semPrefixo(p: []const u8) []const u8 {
    return if (p.len >= 6 and eql(p[0..5], "Exif\x00")) p[6..] else p;
}

// --- JPEG --------------------------------------------------------------------------

fn ehExif(corpo: []const u8) bool {
    return corpo.len >= 6 and eql(corpo[0..5], "Exif\x00");
}

/// O segmento `m` fica? Só o que muda o desenho; o resto é texto, data, lugar e câmera.
fn fica(m: u8, corpo: []const u8) bool {
    return switch (m) {
        // JFIF (densidade, nada pessoal) e o da Adobe (diz como ler CMYK).
        0xE0, 0xEE => true,
        // O APP2 também leva o MPF e o FlashPix; só o perfil de cor fica.
        0xE2 => std.mem.startsWith(u8, corpo, "ICC_PROFILE\x00"),
        0xE1, 0xE3...0xED, 0xEF, 0xFE => false,
        // Tabelas, quadro, varredura: a imagem em si.
        else => true,
    };
}

fn jpeg(gpa: std.mem.Allocator, d: []const u8) Erro!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, d.len);
    out.appendSliceAssumeCapacity(d[0..2]);
    var i: usize = 2;
    var mudou = false;
    var exif_visto = false;
    // Já passou do primeiro SOS: o que vem são dados comprimidos (e, num progressivo,
    // mais tabelas e varreduras).
    var na_imagem = false;
    while (true) {
        if (na_imagem) {
            // Os dados vão inteiros até o próximo marcador: FF seguido de algo que não é
            // 00 (o FF escapado) nem um RSTn.
            const ini = i;
            while (i < d.len) : (i += 1) {
                if (d[i] != 0xFF or i + 1 >= d.len) continue;
                const n = d[i + 1];
                if (n == 0x00 or (n >= 0xD0 and n <= 0xD7)) {
                    i += 1;
                    continue;
                }
                break;
            }
            try out.appendSlice(gpa, d[ini..@min(i, d.len)]);
        }
        // Acabou sem o fim da imagem: antes dos dados é um arquivo quebrado; depois, um
        // JPEG cortado, que sai cortado igual.
        if (i >= d.len) {
            if (!na_imagem) return error.Malformado;
            break;
        }
        if (d[i] != 0xFF) return error.Malformado;
        // Bytes de enchimento antes do marcador.
        while (i < d.len and d[i] == 0xFF) i += 1;
        if (i >= d.len) {
            if (!na_imagem) return error.Malformado;
            break;
        }
        const m = d[i];
        i += 1;
        switch (m) {
            0xD9 => {
                if (!na_imagem) return error.Malformado;
                try out.appendSlice(gpa, &.{ 0xFF, 0xD9 });
                // O que vem depois do fim (outro arquivo grudado) fica para trás.
                if (i < d.len) mudou = true;
                break;
            },
            0x00, 0xD8 => return error.Malformado,
            0x01, 0xD0...0xD7 => {
                try out.appendSlice(gpa, &.{ 0xFF, m });
                continue;
            },
            else => {},
        }
        if (d.len - i < 2) {
            if (!na_imagem) return error.Malformado;
            break;
        }
        const len = be16(d[i..]);
        if (len < 2 or len > d.len - i) {
            if (!na_imagem) return error.Malformado;
            break;
        }
        const corpo = d[i + 2 .. i + len];
        const minimo = m == 0xE1 and ehExif(corpo) and soOrientacao(corpo[6..]);
        if (minimo) exif_visto = true;
        if (fica(m, corpo) or minimo) {
            try out.appendSlice(gpa, &.{ 0xFF, m });
            try out.appendSlice(gpa, d[i .. i + len]);
        } else {
            mudou = true;
            if (m == 0xE1 and !exif_visto and ehExif(corpo)) {
                exif_visto = true;
                // A foto de pé: no lugar do Exif, um com a orientação e nada mais.
                if (tiffOrientacao(corpo[6..])) |o| if (o != 1) {
                    try out.appendSlice(gpa, &.{ 0xFF, 0xE1, 0, 2 + 6 + 26 });
                    try out.appendSlice(gpa, "Exif\x00\x00");
                    try out.appendSlice(gpa, &tiffMinimo(o));
                };
            }
        }
        i += len;
        if (m == 0xDA) na_imagem = true;
    }
    if (!mudou) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}

fn jpegOrientacao(d: []const u8) u8 {
    var i: usize = 2;
    while (i + 4 <= d.len) {
        if (d[i] != 0xFF) return 1;
        const m = d[i + 1];
        if (m == 0xFF) {
            i += 1;
            continue;
        }
        if (m == 0xDA or m == 0xD9) return 1;
        if (m == 0x01 or (m >= 0xD0 and m <= 0xD7)) {
            i += 2;
            continue;
        }
        const len = be16(d[i + 2 ..]);
        if (len < 2 or len > d.len - i - 2) return 1;
        const corpo = d[i + 4 .. i + 2 + len];
        if (m == 0xE1 and ehExif(corpo)) return tiffOrientacao(corpo[6..]) orelse 1;
        i += 2 + len;
    }
    return 1;
}

// --- PNG ---------------------------------------------------------------------------

/// O bloco fica? Os críticos (primeira letra maiúscula), sem os quais não abre, e os
/// que mudam a cor, a transparência ou a animação. (O mDCv e o cLLi são os nomes de
/// antes do PNG 3.)
fn pngFica(tipo: []const u8) bool {
    if (tipo[0] & 0x20 == 0) return true;
    const desenho = [_][]const u8{ "tRNS", "gAMA", "cHRM", "sRGB", "iCCP", "sBIT", "cICP", "mDCV", "mDCv", "cLLI", "cLLi", "pHYs", "bKGD", "hIST", "sPLT", "acTL", "fcTL", "fdAT" };
    for (desenho) |d| if (eql(tipo, d)) return true;
    return false;
}

fn png(gpa: std.mem.Allocator, d: []const u8) Erro!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, d.len);
    out.appendSliceAssumeCapacity(png_escrita.assinatura);
    var i: usize = png_escrita.assinatura.len;
    var mudou = false;
    var exif_visto = false;
    while (true) {
        // Sem o IEND não é um PNG inteiro.
        if (d.len - i < 12) return error.Malformado;
        const n = be32(d[i..]);
        const tipo = d[i + 4 .. i + 8];
        if (n > d.len - i - 12) return error.Malformado;
        for (tipo) |ch| if (!std.ascii.isAlphabetic(ch)) return error.Malformado;
        if (i == png_escrita.assinatura.len and !eql(tipo, "IHDR")) return error.Malformado;
        const minimo = eql(tipo, "eXIf") and soOrientacao(d[i + 8 .. i + 8 + n]);
        if (minimo) exif_visto = true;
        if (pngFica(tipo) or minimo) {
            try out.appendSlice(gpa, d[i .. i + 12 + n]);
        } else {
            mudou = true;
            if (eql(tipo, "eXIf") and !exif_visto) {
                exif_visto = true;
                if (tiffOrientacao(semPrefixo(d[i + 8 .. i + 8 + n]))) |o| if (o != 1) {
                    png_escrita.bloco(gpa, &out, "eXIf", &tiffMinimo(o)) catch return error.OutOfMemory;
                };
            }
        }
        i += 12 + n;
        if (eql(tipo, "IEND")) break;
    }
    if (i < d.len) mudou = true;
    if (!mudou) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}

fn pngOrientacao(d: []const u8) u8 {
    var i: usize = png_escrita.assinatura.len;
    while (d.len - i >= 12) {
        const n = be32(d[i..]);
        if (n > d.len - i - 12) return 1;
        const tipo = d[i + 4 .. i + 8];
        if (eql(tipo, "eXIf")) return tiffOrientacao(semPrefixo(d[i + 8 .. i + 8 + n])) orelse 1;
        if (eql(tipo, "IDAT") or eql(tipo, "IEND")) return 1;
        i += 12 + n;
    }
    return 1;
}

// --- WebP --------------------------------------------------------------------------

/// Os bits do VP8X que dizem que há Exif e XMP.
const vp8x_exif: u8 = 0x08;
const vp8x_xmp: u8 = 0x04;

fn webpBloco(gpa: std.mem.Allocator, out: *std.ArrayList(u8), tipo: *const [4]u8, corpo: []const u8) !void {
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, @intCast(corpo.len), .little);
    try out.appendSlice(gpa, tipo);
    try out.appendSlice(gpa, &n);
    try out.appendSlice(gpa, corpo);
    if (corpo.len % 2 == 1) try out.append(gpa, 0);
}

fn webp(gpa: std.mem.Allocator, d: []const u8) Erro!?[]u8 {
    const riff = le32(d[4..8]);
    if (riff < 4 or riff > d.len - 8) return error.Malformado;
    const fim = 8 + @as(usize, riff);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, d.len);
    out.appendSliceAssumeCapacity(d[0..12]);
    var i: usize = 12;
    // Algo grudado depois do RIFF também fica para trás.
    var mudou = fim < d.len;
    var vp8x: ?usize = null;
    var exif_visto = false;
    var exif_novo = false;
    while (i < fim) {
        if (fim - i < 8) return error.Malformado;
        const tipo = d[i..][0..4];
        const n = le32(d[i + 4 ..]);
        if (n > fim - i - 8) return error.Malformado;
        const corpo = d[i + 8 .. i + 8 + n];
        if (eql(tipo, "EXIF") and soOrientacao(corpo)) {
            try webpBloco(gpa, &out, tipo, corpo);
            exif_visto = true;
            exif_novo = true;
        } else if (eql(tipo, "EXIF")) {
            mudou = true;
            if (!exif_visto) {
                exif_visto = true;
                // O EXIF só vale num WebP com VP8X (que vem antes de tudo).
                if (tiffOrientacao(semPrefixo(corpo))) |o| if (o != 1 and vp8x != null) {
                    try webpBloco(gpa, &out, "EXIF", &tiffMinimo(o));
                    exif_novo = true;
                };
            }
        } else if (eql(tipo, "XMP ")) {
            mudou = true;
        } else {
            if (eql(tipo, "VP8X")) {
                if (n < 10) return error.Malformado;
                vp8x = out.items.len + 8;
            }
            // Com o byte de preenchimento, mesmo se o original terminou sem ele.
            try webpBloco(gpa, &out, tipo, corpo);
        }
        i += 8 + n + n % 2;
    }
    if (!mudou) {
        out.deinit(gpa);
        return null;
    }
    if (vp8x) |p| out.items[p] = (out.items[p] & ~(vp8x_exif | vp8x_xmp)) | (if (exif_novo) vp8x_exif else 0);
    std.mem.writeInt(u32, out.items[4..8], @intCast(out.items.len - 8), .little);
    return try out.toOwnedSlice(gpa);
}

// --- MP4 e MOV ---------------------------------------------------------------------

const Caixa = struct { ini: usize, tipo: []const u8, corpo: usize, fim: usize };

/// A caixa em `i`, que precisa terminar até `limite` (tamanho 0 = até o fim; 1 = o
/// tamanho de 64 bits vem depois do tipo).
fn caixa(d: []const u8, i: usize, limite: usize) Erro!Caixa {
    if (limite - i < 8) return error.Malformado;
    const t32 = be32(d[i..]);
    var corpo = i + 8;
    const tam: u64 = switch (t32) {
        0 => limite - i,
        1 => blk: {
            if (limite - i < 16) return error.Malformado;
            corpo = i + 16;
            break :blk std.mem.readInt(u64, d[i + 8 ..][0..8], .big);
        },
        else => t32,
    };
    if (tam < corpo - i or tam > limite - i) return error.Malformado;
    return .{ .ini = i, .tipo = d[i + 4 .. i + 8], .corpo = corpo, .fim = i + @as(usize, @intCast(tam)) };
}

/// Lugar e câmera: ©xyz (ISO 6709, o do Android), loci (3GPP), ©mak e ©mod.
fn caixaApagar(tipo: []const u8) bool {
    return eql(tipo, "\xA9xyz") or eql(tipo, "loci") or eql(tipo, "\xA9mak") or eql(tipo, "\xA9mod");
}

/// As chaves do meta da Apple (o iPhone guarda o lugar como uma chave do `keys`, e o
/// valor fica no item do `ilst` com o número dela).
fn chaveApagar(nome: []const u8) bool {
    return std.mem.startsWith(u8, nome, "com.apple.quicktime.location.") or
        eql(nome, "com.apple.quicktime.make") or eql(nome, "com.apple.quicktime.model");
}

const Alvos = std.ArrayList(Caixa);

fn mp4(gpa: std.mem.Allocator, d: []const u8) Erro!?[]u8 {
    var alvos: Alvos = .empty;
    defer alvos.deinit(gpa);
    var i: usize = 0;
    while (i < d.len) {
        const cx = try caixa(d, i, d.len);
        if (eql(cx.tipo, "moov")) try dentro(gpa, d, cx.corpo, cx.fim, &alvos, 0);
        i = cx.fim;
    }
    if (alvos.items.len == 0) return null;
    const out = try gpa.dupe(u8, d);
    for (alvos.items) |a| {
        @memcpy(out[a.ini + 4 .. a.ini + 8], "free");
        @memset(out[a.corpo..a.fim], 0);
    }
    return out;
}

/// As caixas entre `ini` e `fim` (dentro do moov, de uma trak ou de um udta).
fn dentro(gpa: std.mem.Allocator, d: []const u8, ini: usize, fim: usize, alvos: *Alvos, nivel: u8) Erro!void {
    // Ninguém aninha tanto; um arquivo feito para isso não estoura a pilha.
    if (nivel > 8) return;
    var i = ini;
    // Uma lista do QuickTime pode terminar com 4 bytes zerados: sobra menos que uma caixa.
    while (fim - i >= 8) {
        const cx = try caixa(d, i, fim);
        if (caixaApagar(cx.tipo)) {
            try alvos.append(gpa, cx);
        } else if (eql(cx.tipo, "udta") or eql(cx.tipo, "trak")) {
            try dentro(gpa, d, cx.corpo, cx.fim, alvos, nivel + 1);
        } else if (eql(cx.tipo, "meta")) {
            try meta(gpa, d, cx, alvos);
        }
        i = cx.fim;
    }
}

fn meta(gpa: std.mem.Allocator, d: []const u8, cx: Caixa, alvos: *Alvos) Erro!void {
    // No MP4 o meta tem versão e flags antes das caixas; no QuickTime, não (o hdlr vem logo).
    var ini = cx.corpo;
    if (cx.fim - ini >= 8 and !eql(d[ini + 4 .. ini + 8], "hdlr")) ini += 4;
    if (ini > cx.fim) return error.Malformado;
    // Os números das chaves de lugar e de câmera no `keys`.
    var marcadas: [32]u32 = undefined;
    var n_marcadas: usize = 0;
    var i = ini;
    while (cx.fim - i >= 8) {
        const k = try caixa(d, i, cx.fim);
        if (eql(k.tipo, "keys")) n_marcadas = try chaves(d, k, &marcadas);
        i = k.fim;
    }
    i = ini;
    while (cx.fim - i >= 8) {
        const k = try caixa(d, i, cx.fim);
        if (eql(k.tipo, "ilst")) {
            var j = k.corpo;
            while (k.fim - j >= 8) {
                const item = try caixa(d, j, k.fim);
                // O tipo de um item é o número da chave (no estilo do iTunes, um ©xyz).
                const numero = be32(d[item.ini + 4 ..]);
                if (caixaApagar(item.tipo) or std.mem.indexOfScalar(u32, marcadas[0..n_marcadas], numero) != null) try alvos.append(gpa, item);
                j = item.fim;
            }
        } else if (caixaApagar(k.tipo)) try alvos.append(gpa, k);
        i = k.fim;
    }
}

/// O `keys`: versão e flags, quantas, e cada uma com tamanho, espaço de nomes e o nome.
fn chaves(d: []const u8, k: Caixa, marcadas: *[32]u32) Erro!usize {
    if (k.fim - k.corpo < 8) return error.Malformado;
    const total = be32(d[k.corpo + 4 ..]);
    var i = k.corpo + 8;
    var n: usize = 0;
    var numero: u32 = 1;
    while (numero <= total and k.fim - i >= 8) : (numero += 1) {
        const tam = be32(d[i..]);
        if (tam < 8 or tam > k.fim - i) return error.Malformado;
        if (chaveApagar(d[i + 8 .. i + tam]) and n < marcadas.len) {
            marcadas[n] = numero;
            n += 1;
        }
        i += tam;
    }
    return n;
}

// --- Testes ------------------------------------------------------------------------

const t = std.testing;
const stb = png_escrita.stb;

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    @setEvalBranchQuota(10_000);
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

/// Um JPEG de verdade de 16×8 (baseline, sem nenhum metadado), feito pelo Pillow.
const jpeg_16x8 = hex(
    "ffd8ffe000104a46494600010100000100010000ffdb0043000d090a0b0a080d0b0a0b0e0e0d0f13201513121213271c" ++
        "1e17202e2931302e292d2c333a4a3e333646372c2d405741464c4e525352323e5a615a50604a51524fffdb0043010e0e" ++
        "0e131113261515264f352d354f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f" ++
        "4f4f4f4f4f4f4f4f4f4f4f4f4f4fffc00011080008001003012200021101031101ffc400150001010000000000000000" ++
        "0000000000000005ffc4001910000105000000000000000000000000000004062231a1ffc40015010101000000000000" ++
        "00000000000000000304ffc400191100020301000000000000000000000000000304052151ffda000c03010002110311" ++
        "003f009895bb50c2c256ed430009f2dbd25aa9cecd3fffd9",
);

/// Um WebP sem perdas de 4×4 (VP8L simples, sem VP8X).
const webp_4x4 = hex("524946461e000000574542505650384c110000002f03c0000007508f2297a7ff8188e87f0000");

/// O TIFF de um Exif com a orientação `o`, a marca do aparelho e um IFD de GPS (com a
/// latitude em texto, para o teste procurar), em `ordem`.
fn exifTiff(buf: *std.ArrayList(u8), ordem: std.builtin.Endian, o: u16) !void {
    const gpa = t.allocator;
    const W = struct {
        fn u16_(b: *std.ArrayList(u8), e: std.builtin.Endian, v: u16) !void {
            var x: [2]u8 = undefined;
            std.mem.writeInt(u16, &x, v, e);
            try b.appendSlice(t.allocator, &x);
        }
        fn u32_(b: *std.ArrayList(u8), e: std.builtin.Endian, v: u32) !void {
            var x: [4]u8 = undefined;
            std.mem.writeInt(u32, &x, v, e);
            try b.appendSlice(t.allocator, &x);
        }
    };
    try buf.appendSlice(gpa, if (ordem == .little) "II" else "MM");
    try W.u16_(buf, ordem, 42);
    try W.u32_(buf, ordem, 8);
    // IFD0 em 8: Make (ASCII, fora), Orientation, ponteiro do GPS.
    try W.u16_(buf, ordem, 3);
    try W.u16_(buf, ordem, 0x010F);
    try W.u16_(buf, ordem, 2);
    try W.u32_(buf, ordem, 12);
    try W.u32_(buf, ordem, 8 + 2 + 36 + 4); // logo depois do IFD0
    try W.u16_(buf, ordem, 0x0112);
    try W.u16_(buf, ordem, 3);
    try W.u32_(buf, ordem, 1);
    try W.u16_(buf, ordem, o);
    try W.u16_(buf, ordem, 0);
    try W.u16_(buf, ordem, 0x8825);
    try W.u16_(buf, ordem, 4);
    try W.u32_(buf, ordem, 1);
    try W.u32_(buf, ordem, 8 + 2 + 36 + 4 + 12);
    try W.u32_(buf, ordem, 0);
    try buf.appendSlice(gpa, "CameraXYZ12\x00");
    // IFD do GPS: GPSLatitudeRef "S" e uma tag de texto com a latitude.
    try W.u16_(buf, ordem, 2);
    try W.u16_(buf, ordem, 0x0001);
    try W.u16_(buf, ordem, 2);
    try W.u32_(buf, ordem, 2);
    try buf.appendSlice(gpa, "S\x00\x00\x00");
    try W.u16_(buf, ordem, 0x001B);
    try W.u16_(buf, ordem, 7);
    try W.u32_(buf, ordem, 16);
    try W.u32_(buf, ordem, @intCast(buf.items.len + 4 + 4));
    try W.u32_(buf, ordem, 0);
    try buf.appendSlice(gpa, "GPS-23.5505,-46\x00");
}

/// O JPEG de amostra com Exif (orientação `o`), XMP, IPTC, comentário, um MPF, o perfil de
/// cor (que fica) e um arquivo grudado depois do fim.
fn jpegComTudo(gpa: std.mem.Allocator, ordem: std.builtin.Endian, o: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, jpeg_16x8[0..20]); // SOI + APP0 do JFIF
    var tiff: std.ArrayList(u8) = .empty;
    defer tiff.deinit(gpa);
    try exifTiff(&tiff, ordem, o);
    const segs = [_]struct { m: u8, corpo: []const u8 }{
        .{ .m = 0xE1, .corpo = "" }, // o Exif, montado abaixo
        .{ .m = 0xE1, .corpo = "http://ns.adobe.com/xap/1.0/\x00<x:xmpmeta><exif:GPSLatitude>23,33S</exif:GPSLatitude></x:xmpmeta>" },
        .{ .m = 0xED, .corpo = "Photoshop 3.0\x008BIM\x04\x04\x00\x00\x00\x00\x00\x0cIPTC-cidade" },
        .{ .m = 0xE2, .corpo = "MPF\x00MM\x00\x2a\x00\x00\x00\x08" },
        .{ .m = 0xE2, .corpo = "ICC_PROFILE\x00\x01\x01perfil-de-cor" },
        .{ .m = 0xEB, .corpo = "JPXT-credenciais" },
        .{ .m = 0xFE, .corpo = "comentario: tirada em casa" },
    };
    for (segs, 0..) |s, k| {
        var corpo: []const u8 = s.corpo;
        var exif: std.ArrayList(u8) = .empty;
        defer exif.deinit(gpa);
        if (k == 0) {
            try exif.appendSlice(gpa, "Exif\x00\x00");
            try exif.appendSlice(gpa, tiff.items);
            corpo = exif.items;
        }
        try out.appendSlice(gpa, &.{ 0xFF, s.m, @intCast((corpo.len + 2) >> 8), @intCast((corpo.len + 2) & 0xFF) });
        try out.appendSlice(gpa, corpo);
    }
    try out.appendSlice(gpa, jpeg_16x8[20..]);
    try out.appendSlice(gpa, "ftypmp42-video-grudado-GPS");
    return out.toOwnedSlice(gpa);
}

fn temNada(d: []const u8, partes: []const []const u8) !void {
    for (partes) |p| if (std.mem.indexOf(u8, d, p) != null) {
        std.debug.print("ainda tem \"{s}\"\n", .{p});
        return error.SobrouMetadado;
    };
}

test "JPEG: some o Exif com GPS, o XMP, o IPTC, o comentário e o que vem depois; a foto fica de pé e abre" {
    const gpa = t.allocator;
    for ([_]std.builtin.Endian{ .big, .little }) |ordem| {
        const sujo = try jpegComTudo(gpa, ordem, 6);
        defer gpa.free(sujo);
        try t.expectEqual(@as(u8, 6), orientacao(sujo));
        const limpo = (try limpar(gpa, sujo)) orelse return error.NadaMudou;
        defer gpa.free(limpo);
        try temNada(limpo, &.{ "GPS", "CameraXYZ", "xmpmeta", "IPTC", "Photoshop", "comentario", "MPF", "JPXT", "ftyp" });
        // O perfil de cor e o JFIF ficam; o Exif mínimo entra no lugar do outro.
        try t.expect(std.mem.indexOf(u8, limpo, "ICC_PROFILE") != null);
        try t.expect(std.mem.indexOf(u8, limpo, "JFIF") != null);
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, limpo, "Exif\x00\x00"));
        try t.expectEqual(@as(u8, 6), orientacao(limpo));
        try t.expect(std.mem.endsWith(u8, limpo, &.{ 0xFF, 0xD9 }));
        // A imagem é a mesma, byte a byte depois de decodificada.
        const a = stb.abrir(&jpeg_16x8) orelse return error.NaoAbriu;
        defer a.deinit();
        const b = stb.abrir(limpo) orelse return error.NaoAbriu;
        defer b.deinit();
        try t.expectEqual(@as(u32, 16), b.w);
        try t.expectEqual(@as(u32, 8), b.h);
        try t.expectEqualSlices(u8, a.px, b.px);
        // Limpar de novo não acha mais nada.
        try t.expect((try limpar(gpa, limpo)) == null);
    }
}

test "JPEG: orientação normal sai sem Exif nenhum; sem metadado, nada muda" {
    const gpa = t.allocator;
    const sujo = try jpegComTudo(gpa, .big, 1);
    defer gpa.free(sujo);
    const limpo = (try limpar(gpa, sujo)) orelse return error.NadaMudou;
    defer gpa.free(limpo);
    try temNada(limpo, &.{ "Exif", "GPS" });
    try t.expectEqual(@as(u8, 1), orientacao(limpo));
    try t.expect((try limpar(gpa, &jpeg_16x8)) == null);
}

test "JPEG cortado: no cabeçalho é quebrado; nos dados sai limpo e cortado igual" {
    const gpa = t.allocator;
    const sujo = try jpegComTudo(gpa, .big, 3);
    defer gpa.free(sujo);
    try t.expectError(error.Malformado, limpar(gpa, sujo[0..30]));
    try t.expectError(error.Malformado, limpar(gpa, &.{ 0xFF, 0xD8, 0xFF }));
    // Até o meio dos dados comprimidos (sem o FFD9 e o que vinha grudado).
    const corte = std.mem.lastIndexOf(u8, sujo, &.{ 0xFF, 0xD9 }).? - 6;
    const limpo = (try limpar(gpa, sujo[0..corte])) orelse return error.NadaMudou;
    defer gpa.free(limpo);
    try temNada(limpo, &.{ "GPS", "xmpmeta" });
    try t.expectEqualSlices(u8, sujo[corte - 10 .. corte], limpo[limpo.len - 10 ..]);
    // Um segmento que diz ser maior que o arquivo.
    var ruim = jpeg_16x8;
    ruim[4] = 0xFF;
    try t.expectError(error.Malformado, limpar(gpa, &ruim));
}

/// Um PNG 8×5 do nosso codificador com blocos de metadado no meio (e os de cor, que ficam).
fn pngComTudo(gpa: std.mem.Allocator, o: u16) !struct { png: []u8, px: []u8 } {
    const px = try gpa.alloc(u8, 8 * 5 * 4);
    errdefer gpa.free(px);
    for (px, 0..) |*b, k| b.* = @truncate(k * 13);
    const base = try png_escrita.codificar(gpa, px, 8, 5, 8 * 4);
    defer gpa.free(base);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, base[0 .. 8 + 25]); // assinatura + IHDR
    var tiff: std.ArrayList(u8) = .empty;
    defer tiff.deinit(gpa);
    try exifTiff(&tiff, .big, o);
    try png_escrita.bloco(gpa, &out, "gAMA", &.{ 0, 0, 0xB1, 0x8F });
    try png_escrita.bloco(gpa, &out, "sRGB", &.{0});
    try png_escrita.bloco(gpa, &out, "eXIf", tiff.items);
    try png_escrita.bloco(gpa, &out, "tEXt", "Comment\x00GPS-23.55 tirada em casa");
    try png_escrita.bloco(gpa, &out, "zTXt", "Author\x00\x00x\x9c\x03\x00\x00\x00\x00\x01");
    try png_escrita.bloco(gpa, &out, "iTXt", "XML:com.adobe.xmp\x00\x00\x00\x00\x00<x:xmpmeta/>");
    try png_escrita.bloco(gpa, &out, "tIME", &.{ 0x07, 0xEA, 11, 19, 12, 0, 0 });
    try png_escrita.bloco(gpa, &out, "pHYs", &.{ 0, 0, 0x0B, 0x13, 0, 0, 0x0B, 0x13, 1 });
    try png_escrita.bloco(gpa, &out, "vpAg", "programa");
    try out.appendSlice(gpa, base[8 + 25 ..]);
    try out.appendSlice(gpa, "lixo depois do IEND");
    return .{ .png = try out.toOwnedSlice(gpa), .px = px };
}

/// Os blocos de um PNG, conferindo o CRC de cada um.
fn pngTipos(d: []const u8, buf: [][]const u8) ![][]const u8 {
    var i: usize = 8;
    var n: usize = 0;
    while (i < d.len) {
        const len = be32(d[i..]);
        var crc = std.hash.Crc32.init();
        crc.update(d[i + 4 .. i + 8 + len]);
        try t.expectEqual(crc.final(), be32(d[i + 8 + len ..]));
        buf[n] = d[i + 4 .. i + 8];
        n += 1;
        i += 12 + len;
    }
    try t.expectEqual(d.len, i);
    return buf[0..n];
}

test "PNG: saem eXIf, textos, tIME e o bloco de programa; ficam cor e densidade; a orientação fica" {
    const gpa = t.allocator;
    const s = try pngComTudo(gpa, 3);
    defer gpa.free(s.png);
    defer gpa.free(s.px);
    try t.expectEqual(@as(u8, 3), orientacao(s.png));
    const limpo = (try limpar(gpa, s.png)) orelse return error.NadaMudou;
    defer gpa.free(limpo);
    try temNada(limpo, &.{ "GPS", "CameraXYZ", "tEXt", "zTXt", "iTXt", "tIME", "vpAg", "xmpmeta", "lixo" });
    var buf: [16][]const u8 = undefined;
    const tipos = try pngTipos(limpo, &buf);
    const esperado = [_][]const u8{ "IHDR", "gAMA", "sRGB", "eXIf", "pHYs", "IDAT", "IEND" };
    try t.expectEqual(esperado.len, tipos.len);
    for (esperado, tipos) |a, b| try t.expectEqualStrings(a, b);
    try t.expectEqual(@as(u8, 3), orientacao(limpo));
    const img = stb.abrir(limpo) orelse return error.NaoAbriu;
    defer img.deinit();
    try t.expectEqualSlices(u8, s.px, img.px);
}

test "PNG: sem metadado nada muda; cortado ou com tamanho errado é quebrado" {
    const gpa = t.allocator;
    const s = try pngComTudo(gpa, 1);
    defer gpa.free(s.png);
    defer gpa.free(s.px);
    const limpo = (try limpar(gpa, s.png)) orelse return error.NadaMudou;
    defer gpa.free(limpo);
    try temNada(limpo, &.{"eXIf"});
    try t.expect((try limpar(gpa, limpo)) == null);
    // Sem o IEND.
    try t.expectError(error.Malformado, limpar(gpa, limpo[0 .. limpo.len - 12]));
    // Um bloco maior que o arquivo.
    const ruim = try gpa.dupe(u8, limpo);
    defer gpa.free(ruim);
    ruim[8] = 0x7F;
    try t.expectError(error.Malformado, limpar(gpa, ruim));
    // O primeiro bloco precisa ser o IHDR.
    @memcpy(ruim, limpo);
    @memcpy(ruim[12..16], "gAMA");
    try t.expectError(error.Malformado, limpar(gpa, ruim));
}

/// Um WebP estendido: VP8X (com alfa, Exif e XMP ligados), a imagem de 4×4 da amostra,
/// um EXIF ímpar e um XMP.
fn webpComTudo(gpa: std.mem.Allocator, o: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "RIFF\x00\x00\x00\x00WEBP");
    try webpBloco(gpa, &out, "VP8X", &.{ 0x10 | vp8x_exif | vp8x_xmp, 0, 0, 0, 3, 0, 0, 3, 0, 0 });
    try out.appendSlice(gpa, webp_4x4[12..]);
    var tiff: std.ArrayList(u8) = .empty;
    defer tiff.deinit(gpa);
    try tiff.appendSlice(gpa, "Exif\x00\x00");
    try exifTiff(&tiff, .little, o);
    try tiff.append(gpa, 0x55); // ímpar: o bloco ganha o byte de preenchimento
    try webpBloco(gpa, &out, "EXIF", tiff.items);
    try webpBloco(gpa, &out, "XMP ", "<x:xmpmeta>GPS</x:xmpmeta>");
    std.mem.writeInt(u32, out.items[4..8], @intCast(out.items.len - 8), .little);
    return out.toOwnedSlice(gpa);
}

/// Confere o RIFF e devolve os blocos.
fn webpTipos(d: []const u8, buf: [][]const u8) ![][]const u8 {
    try t.expectEqual(d.len - 8, le32(d[4..8]));
    var i: usize = 12;
    var n: usize = 0;
    while (i < d.len) {
        const len = le32(d[i + 4 ..]);
        buf[n] = d[i .. i + 4];
        n += 1;
        i += 8 + len + len % 2;
    }
    try t.expectEqual(d.len, i);
    return buf[0..n];
}

test "WebP: saem EXIF e XMP, o VP8X e o RIFF são acertados; girada fica com o Exif mínimo" {
    const gpa = t.allocator;
    for ([_]u16{ 1, 8 }) |o| {
        const sujo = try webpComTudo(gpa, o);
        defer gpa.free(sujo);
        const limpo = (try limpar(gpa, sujo)) orelse return error.NadaMudou;
        defer gpa.free(limpo);
        try temNada(limpo, &.{ "GPS", "CameraXYZ", "xmpmeta", "XMP " });
        var buf: [8][]const u8 = undefined;
        const tipos = try webpTipos(limpo, &buf);
        try t.expectEqualStrings("VP8X", tipos[0]);
        try t.expectEqualStrings("VP8L", tipos[1]);
        // O alfa continua; Exif só se girava; XMP nunca.
        const flags = limpo[20];
        try t.expect(flags & 0x10 != 0 and flags & vp8x_xmp == 0);
        if (o == 1) {
            try t.expectEqual(@as(usize, 2), tipos.len);
            try t.expect(flags & vp8x_exif == 0);
        } else {
            try t.expectEqual(@as(usize, 3), tipos.len);
            try t.expectEqualStrings("EXIF", tipos[2]);
            try t.expect(flags & vp8x_exif != 0);
            try t.expectEqual(@as(?u8, 8), tiffOrientacao(limpo[limpo.len - 26 ..]));
        }
        // A imagem em si, byte a byte.
        try t.expect(std.mem.indexOf(u8, limpo, webp_4x4[12..]) != null);
    }
    // O WebP simples não tem onde guardar metadado.
    try t.expect((try limpar(gpa, &webp_4x4)) == null);
}

test "WebP quebrado: RIFF maior que o arquivo e bloco maior que o RIFF" {
    const gpa = t.allocator;
    const sujo = try webpComTudo(gpa, 1);
    defer gpa.free(sujo);
    try t.expectError(error.Malformado, limpar(gpa, sujo[0 .. sujo.len - 3]));
    const ruim = try gpa.dupe(u8, sujo);
    defer gpa.free(ruim);
    std.mem.writeInt(u32, ruim[16..20], 999, .little);
    try t.expectError(error.Malformado, limpar(gpa, ruim));
}

fn mp4Caixa(gpa: std.mem.Allocator, out: *std.ArrayList(u8), tipo: []const u8, corpo: []const u8) !void {
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, @intCast(corpo.len + 8), .big);
    try out.appendSlice(gpa, &n);
    try out.appendSlice(gpa, tipo);
    try out.appendSlice(gpa, corpo);
}

/// Um MP4 de celular: ftyp, moov (mvhd, udta com ©xyz/©mak/©nam e o meta da Apple com
/// as chaves de lugar, e uma trak com loci) e o mdat.
fn mp4ComTudo(gpa: std.mem.Allocator) ![]u8 {
    var udta: std.ArrayList(u8) = .empty;
    defer udta.deinit(gpa);
    try mp4Caixa(gpa, &udta, "\xA9xyz", "\x00\x12\x15\xc7+12.3456-045.6789/");
    try mp4Caixa(gpa, &udta, "\xA9mak", "\x00\x05\x15\xc7Apple");
    try mp4Caixa(gpa, &udta, "\xA9nam", "\x00\x06\x15\xc7ferias");
    try udta.appendSlice(gpa, &.{ 0, 0, 0, 0 }); // o fim de lista do QuickTime
    var keys: std.ArrayList(u8) = .empty;
    defer keys.deinit(gpa);
    try keys.appendSlice(gpa, &.{ 0, 0, 0, 0, 0, 0, 0, 3 });
    for ([_][]const u8{ "com.apple.quicktime.location.ISO6709", "com.apple.quicktime.creationdate", "com.apple.quicktime.model" }) |k| {
        try mp4Caixa(gpa, &keys, "mdta", k);
    }
    var ilst: std.ArrayList(u8) = .empty;
    defer ilst.deinit(gpa);
    for ([_][]const u8{ "+12.3456-045.6789+010.000/", "2026-11-19T10:00:00-0300", "iPhone 15" }, 1..) |v, k| {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);
        try mp4Caixa(gpa, &data, "data", v);
        var tipo: [4]u8 = undefined;
        std.mem.writeInt(u32, &tipo, @intCast(k), .big);
        try mp4Caixa(gpa, &ilst, &tipo, data.items);
    }
    var meta_c: std.ArrayList(u8) = .empty;
    defer meta_c.deinit(gpa);
    try mp4Caixa(gpa, &meta_c, "hdlr", "\x00\x00\x00\x00\x00\x00\x00\x00mdta\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00");
    try mp4Caixa(gpa, &meta_c, "keys", keys.items);
    try mp4Caixa(gpa, &meta_c, "ilst", ilst.items);
    var trak_udta: std.ArrayList(u8) = .empty;
    defer trak_udta.deinit(gpa);
    try mp4Caixa(gpa, &trak_udta, "loci", "\x00\x00\x00\x00\x15\xc7casa\x00\x00");
    var trak: std.ArrayList(u8) = .empty;
    defer trak.deinit(gpa);
    try mp4Caixa(gpa, &trak, "tkhd", &@as([20]u8, @splat(0)));
    try mp4Caixa(gpa, &trak, "udta", trak_udta.items);
    var moov: std.ArrayList(u8) = .empty;
    defer moov.deinit(gpa);
    try mp4Caixa(gpa, &moov, "mvhd", &@as([24]u8, @splat(0)));
    try mp4Caixa(gpa, &moov, "udta", udta.items);
    try mp4Caixa(gpa, &moov, "meta", meta_c.items);
    try mp4Caixa(gpa, &moov, "trak", trak.items);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try mp4Caixa(gpa, &out, "ftyp", "isom\x00\x00\x02\x00isomiso2mp41");
    try mp4Caixa(gpa, &out, "moov", moov.items);
    try mp4Caixa(gpa, &out, "mdat", "quadros do video +12.3456");
    return out.toOwnedSlice(gpa);
}

test "MP4: ©xyz, loci, câmera e a location da Apple viram free zerado, do mesmo tamanho" {
    const gpa = t.allocator;
    const sujo = try mp4ComTudo(gpa);
    defer gpa.free(sujo);
    const limpo = (try limpar(gpa, sujo)) orelse return error.NadaMudou;
    defer gpa.free(limpo);
    try t.expectEqual(sujo.len, limpo.len);
    try temNada(limpo, &.{ "\xA9xyz", "\xA9mak", "loci", "-045.6789", "Apple", "iPhone", "casa" });
    // Fica o que não é lugar nem câmera: o título, a data e o próprio vídeo (com o texto
    // que parece coordenada, que é só dado do mdat).
    try t.expect(std.mem.indexOf(u8, limpo, "\xA9nam") != null);
    try t.expect(std.mem.indexOf(u8, limpo, "ferias") != null);
    try t.expect(std.mem.indexOf(u8, limpo, "2026-11-19T10:00:00") != null);
    try t.expect(std.mem.endsWith(u8, limpo, "quadros do video +12.3456"));
    try t.expectEqual(@as(usize, 5), std.mem.count(u8, limpo, "free"));
    // Fora dos pedaços zerados, nenhum byte mudou.
    var diferentes: usize = 0;
    for (sujo, limpo) |a, b| diferentes += @intFromBool(a != b);
    try t.expect(diferentes > 0 and diferentes < 120);
    try t.expect((try limpar(gpa, limpo)) == null);
}

test "MP4 quebrado: caixa maior que o arquivo; sem lugar nem câmera, nada muda" {
    const gpa = t.allocator;
    const sujo = try mp4ComTudo(gpa);
    defer gpa.free(sujo);
    try t.expectError(error.Malformado, limpar(gpa, sujo[0 .. sujo.len - 4]));
    var so_video: std.ArrayList(u8) = .empty;
    defer so_video.deinit(gpa);
    try mp4Caixa(gpa, &so_video, "ftyp", "isom\x00\x00\x02\x00");
    try mp4Caixa(gpa, &so_video, "moov", "\x00\x00\x00\x10mvhd\x00\x00\x00\x00\x00\x00\x00\x00");
    try mp4Caixa(gpa, &so_video, "mdat", "x");
    try t.expect((try limpar(gpa, so_video.items)) == null);
    // Tamanho de 64 bits e "até o fim" também são caixas.
    var grande: std.ArrayList(u8) = .empty;
    defer grande.deinit(gpa);
    try mp4Caixa(gpa, &grande, "ftyp", "isom");
    try grande.appendSlice(gpa, "\x00\x00\x00\x01moov\x00\x00\x00\x00\x00\x00\x00\x2a");
    try mp4Caixa(gpa, &grande, "\xA9xyz", "+01.0000+002.0000/");
    try grande.appendSlice(gpa, "\x00\x00\x00\x00mdat restante");
    const limpo = (try limpar(gpa, grande.items)) orelse return error.NadaMudou;
    defer gpa.free(limpo);
    try temNada(limpo, &.{"+01.0000"});
}

test "qualquer pedaço de cada formato: nunca quebra, ou limpa ou diz que está quebrado" {
    const gpa = t.allocator;
    const jp = try jpegComTudo(gpa, .little, 6);
    defer gpa.free(jp);
    const pn = try pngComTudo(gpa, 6);
    defer gpa.free(pn.png);
    defer gpa.free(pn.px);
    const wp = try webpComTudo(gpa, 6);
    defer gpa.free(wp);
    const mp = try mp4ComTudo(gpa);
    defer gpa.free(mp);
    for ([_][]const u8{ jp, pn.png, wp, mp }) |amostra| {
        for (0..amostra.len + 1) |n| {
            const r = limpar(gpa, amostra[0..n]) catch |e| {
                try t.expectEqual(error.Malformado, e);
                continue;
            };
            if (r) |x| gpa.free(x);
            _ = orientacao(amostra[0..n]);
        }
        // E com um byte trocado em cada posição.
        const copia = try gpa.dupe(u8, amostra);
        defer gpa.free(copia);
        for (0..copia.len) |k| {
            copia[k] ^= 0xA5;
            if (limpar(gpa, copia)) |r| {
                if (r) |x| gpa.free(x);
            } else |e| try t.expectEqual(error.Malformado, e);
            copia[k] ^= 0xA5;
        }
    }
    // O que não é nenhum deles passa como está.
    try t.expect((try limpar(gpa, "GIF89a\x01\x00\x01\x00")) == null);
    try t.expect((try limpar(gpa, "")) == null);
    try t.expect((try limpar(gpa, "OggS\x00\x02")) == null);
}
