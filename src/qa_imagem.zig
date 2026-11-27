//! QA da imagem privada: um print colado com Ctrl+V entra na bandeja (na pasta temporária
//! só nossa) com o Editar; o editor corta e esconde pedaços com arrastos de verdade, as
//! alças mexem no corte, Ctrl+Z desfaz, Enter grava, e o PNG que entra no lugar é
//! conferido pixel a pixel contra o original (o pedaço escondido mudou, o resto não). Um
//! PNG com o Exif girado abre de pé; Recomeçar e Esc não mudam nada. Depois, o que sobe
//! para o Discord (net/envio_limpo.zig, pelo gateway de mentira): sem o GPS e com a mesma
//! imagem com a opção ligada, o arquivo como está com ela desligada, e o arquivo da pessoa
//! nunca muda.
//!
//! `QA_SUITE=imagem` roda tudo; `QA_SUITE=imagem-tema` roda o editor em outro tema, em
//! outro idioma e com a interface em 125% (tools/qa.sh: papel claro, japonês).
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const sys = @import("platform/sys.zig");
const editor = @import("ui/editor_imagem.zig");
const ie = @import("core/imagem_edicao.zig");
const png_escrita = @import("core/png_escrita.zig");

const alloc = std.heap.c_allocator;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 4000 } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}
fn ctrl(k: c_int) Op {
    return .{ .key = .{ .key = k, .ctrl = true } };
}
/// Arrasta dentro da imagem do editor, de um ponto a outro (frações da imagem na tela).
fn arrasta(x0: f32, y0: f32, x1: f32, y1: f32) Op {
    return .{ .drag = .{ .from = .{ .at = .{ .key = "editor-imagem", .fx = x0, .fy = y0 } }, .to = .{ .at = .{ .key = "editor-imagem", .fx = x1, .fy = y1 } } } };
}

// --- O print colado ------------------------------------------------------------------

const print_w = 320;
const print_h = 200;

/// Um "print" opaco em que cada pixel tem uma cor própria (nada de áreas lisas: um
/// pixel do pedaço escondido que não mudasse seria acaso).
fn printPixels() ![]u8 {
    const px = try alloc.alloc(u8, print_w * print_h * 4);
    for (0..print_h) |y| for (0..print_w) |x| {
        px[(y * print_w + x) * 4 ..][0..4].* = .{ @intCast(x * 255 / print_w), @intCast(y * 255 / print_h), @intCast((x * 7 + y * 13) % 256), 255 };
    };
    return px;
}

var clip_png: []u8 = &.{};
fn clipData(_: ?*anyopaque, _: [*c]const u8, size: [*c]usize) callconv(.c) ?*const anyopaque {
    size.* = clip_png.len;
    return clip_png.ptr;
}
/// Como um print do navegador ou do sistema chega: a área de transferência com o PNG.
fn copiarPrint(_: *App) void {
    const px = printPixels() catch return;
    defer alloc.free(px);
    if (clip_png.len > 0) alloc.free(clip_png);
    clip_png = png_escrita.codificar(alloc, px, print_w, print_h, print_w * 4) catch return;
    var mimes = [_][*c]const u8{"image/png"};
    _ = c.SDL_SetClipboardData(clipData, null, null, &mimes, 1);
}

fn coladoNaBandeja(app: *App) bool {
    const ups = app.st.uploads.items;
    return ups.len == 1 and ups[0].width == print_w and ups[0].height == print_h and ups[0].editavel and
        types.isPrivateFile(ups[0].path) and std.mem.endsWith(u8, ups[0].path, ".png") and qa.find("upload-edit:0") != null;
}

fn editorAberto(app: *App) bool {
    const v = editor.visto() orelse return false;
    return app.st.popup == .editar_imagem and qa.find("editor-imagem") != null and qa.find("editor:Pronto") != null and
        v.w == print_w and v.h == print_h and v.corte.eql(.{ .w = print_w, .h = print_h }) and v.areas.len == 0;
}

fn perto(a: u32, b: u32, folga: u32) bool {
    return @max(a, b) - @min(a, b) <= folga;
}

/// O arrasto de (0,10; 0,15) a (0,85; 0,90): o corte de (32, 30) a (272, 180).
fn cortou(_: *App) bool {
    const v = editor.visto() orelse return false;
    const r = v.corte;
    return perto(r.x, 32, 2) and perto(r.y, 30, 2) and perto(r.right(), 272, 2) and perto(r.bottom(), 180, 2) and qa.find("editor-alca:4") != null;
}

/// A alça de baixo à direita levada a (0,80; 0,85): o canto vai para (256, 170), o outro fica.
fn alcaMexeu(_: *App) bool {
    const v = editor.visto() orelse return false;
    const r = v.corte;
    return perto(r.x, 32, 2) and perto(r.y, 30, 2) and perto(r.right(), 256, 2) and perto(r.bottom(), 170, 2);
}

fn umaArea(_: *App) bool {
    const v = editor.visto() orelse return false;
    if (v.areas.len != 1 or v.ferramenta == .cortar) return false;
    const a = v.areas[0];
    // De (0,30; 0,35) a (0,55; 0,60): de (96, 70) a (176, 120).
    return a.modo == .blocos and perto(a.r.x, 96, 2) and perto(a.r.y, 70, 2) and perto(a.r.right(), 176, 2) and perto(a.r.bottom(), 120, 2) and a.bloco >= 10;
}

fn duasAreas(_: *App) bool {
    const v = editor.visto() orelse return false;
    return v.areas.len == 2 and v.areas[1].modo == .tarja and v.areas[0].modo == .blocos;
}

/// O que estava no editor antes do Enter, para conferir o arquivo que sai.
var antes_corte: ie.Ret = .{};
var antes_area: ie.Ret = .{};
var antes_path: [1100]u8 = undefined;
var antes_path_len: usize = 0;
var original: []u8 = &.{};

fn guardar(app: *App) void {
    const v = editor.visto() orelse return;
    antes_corte = v.corte;
    antes_area = if (v.areas.len > 0) v.areas[0].r else .{};
    const p = app.st.uploads.items[0].path;
    antes_path_len = @min(p.len, antes_path.len);
    @memcpy(antes_path[0..antes_path_len], p[0..antes_path_len]);
    if (original.len > 0) alloc.free(original);
    original = printPixels() catch &.{};
}

fn trocou(app: *App) bool {
    const ups = app.st.uploads.items;
    if (app.st.popup != .none or ups.len != 1) return false;
    const u = ups[0];
    return !std.mem.eql(u8, u.path, antes_path[0..antes_path_len]) and types.isPrivateFile(u.path) and
        std.mem.endsWith(u8, u.path, ".png") and u.width == antes_corte.w and u.height == antes_corte.h and u.editavel;
}

/// Abre o PNG da bandeja pelo stb (RGBA).
const Aberta = struct {
    px: [*]u8,
    w: u32,
    h: u32,
    fn deinit(a: Aberta) void {
        c.stbi_image_free(a.px);
    }
};
fn abrirArquivo(path: [:0]const u8) ?Aberta {
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return null;
    defer c.SDL_free(data);
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const px = c.stbi_load_from_memory(@ptrCast(data), @intCast(size), &w, &h, &comp, 4) orelse return null;
    return .{ .px = px, .w = @intCast(w), .h = @intCast(h) };
}

/// O PNG que entrou: do tamanho do corte; dentro do pedaço escondido quase tudo mudou, e
/// fora dele cada pixel é o do original na mesma posição.
fn conferePixels(app: *App) bool {
    if (app.st.uploads.items.len != 1 or original.len == 0) return false;
    const img = abrirArquivo(app.st.uploads.items[0].path) orelse return false;
    defer img.deinit();
    if (img.w != antes_corte.w or img.h != antes_corte.h) return false;
    var dentro: usize = 0;
    var mudou_dentro: usize = 0;
    var mudou_fora: usize = 0;
    for (0..img.h) |y| for (0..img.w) |x| {
        const ix = antes_corte.x + x;
        const iy = antes_corte.y + y;
        const novo = img.px[(y * img.w + x) * 4 ..][0..4];
        const velho = original[(iy * print_w + ix) * 4 ..][0..4];
        const igual = std.mem.eql(u8, novo, velho);
        if (ix >= antes_area.x and ix < antes_area.right() and iy >= antes_area.y and iy < antes_area.bottom()) {
            dentro += 1;
            if (!igual) mudou_dentro += 1;
        } else if (!igual) mudou_fora += 1;
    };
    if (mudou_fora != 0 or dentro == 0 or mudou_dentro * 10 < dentro * 9) {
        std.log.warn("imagem editada: {d}/{d} mudaram no pedaço, {d} fora dele", .{ mudou_dentro, dentro, mudou_fora });
        return false;
    }
    return true;
}

fn antigoApagado(_: *App) bool {
    var b: [1100]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&b, "{s}", .{antes_path[0..antes_path_len]}, 0) catch return false;
    return !sys.exists(z.ptr);
}

fn segundaVez(app: *App) bool {
    const v = editor.visto() orelse return false;
    return app.st.popup == .editar_imagem and v.w == antes_corte.w and v.h == antes_corte.h and v.areas.len == 0;
}
fn tarjaMarcada(_: *App) bool {
    const v = editor.visto() orelse return false;
    return v.areas.len == 1 and v.areas[0].modo == .tarja;
}
fn recomecou(_: *App) bool {
    const v = editor.visto() orelse return false;
    return v.areas.len == 0 and v.corte.eql(.{ .w = v.w, .h = v.h }) and qa.find("editor-imagem") != null;
}
fn guardarCaminho(app: *App) void {
    const p = app.st.uploads.items[0].path;
    antes_path_len = @min(p.len, antes_path.len);
    @memcpy(antes_path[0..antes_path_len], p[0..antes_path_len]);
}
fn fechouSemMudar(app: *App) bool {
    const ups = app.st.uploads.items;
    return app.st.popup == .none and editor.visto() == null and ups.len == 1 and std.mem.eql(u8, ups[0].path, antes_path[0..antes_path_len]);
}

// --- O que sobe para o Discord ------------------------------------------------------

var sends_antes: u64 = 0;
fn contarEnvios(_: *App) void {
    sends_antes = gw.sent.sends.load(.acquire);
}
fn enviado(app: *App) bool {
    return gw.sent.sends.load(.acquire) > sends_antes and app.st.uploads.items.len == 0;
}
fn dados() []const u8 {
    return gw.sent.view(&gw.sent.send_data, &gw.sent.send_data_len);
}

var editado: []u8 = &.{};
fn guardarEditado(app: *App) void {
    if (editado.len > 0) alloc.free(editado);
    editado = &.{};
    var size: usize = 0;
    const data = c.SDL_LoadFile(app.st.uploads.items[0].path.ptr, &size) orelse return;
    defer c.SDL_free(data);
    editado = alloc.dupe(u8, @as([*]const u8, @ptrCast(data))[0..size]) catch &.{};
}
/// O PNG do editor não tem nada escondido: sobe byte a byte (o gateway guarda o começo).
fn editadoComoEsta(app: *App) bool {
    const d = dados();
    return enviado(app) and editado.len > 0 and gw.sent.send_data_size.load(.acquire) == editado.len and d.len > 0 and std.mem.eql(u8, d, editado[0..d.len]);
}

/// Uma foto com GPS: um PNG com um eXIf (o IFD do GPS, com a latitude em texto) e um
/// tEXt, em qa-out/foto-gps.png.
var foto: []u8 = &.{};
var foto_px: []u8 = &.{};
fn fotoComGps() ![]u8 {
    if (foto_px.len == 0) {
        foto_px = try alloc.alloc(u8, 48 * 32 * 4);
        for (0..32) |y| for (0..48) |x| {
            foto_px[(y * 48 + x) * 4 ..][0..4].* = .{ @intCast(x * 5), @intCast(y * 7), 90, 255 };
        };
    }
    const base = try png_escrita.codificar(alloc, foto_px, 48, 32, 48 * 4);
    defer alloc.free(base);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, base[0 .. 8 + 25]);
    // TIFF big endian: IFD0 com o ponteiro do GPS; o IFD do GPS com uma tag de texto.
    const tiff = "MM\x00\x2a\x00\x00\x00\x08" ++ "\x00\x01" ++ "\x88\x25\x00\x04\x00\x00\x00\x01\x00\x00\x00\x1a" ++ "\x00\x00\x00\x00" ++
        "\x00\x01" ++ "\x00\x1b\x00\x07\x00\x00\x00\x10\x00\x00\x00\x2c" ++ "\x00\x00\x00\x00" ++ "GPS-23.5505,-46\x00";
    try png_escrita.bloco(alloc, &out, "eXIf", tiff);
    try png_escrita.bloco(alloc, &out, "tEXt", "Comment\x00GPS -23.5505 -46.6333, em casa");
    try out.appendSlice(alloc, base[8 + 25 ..]);
    return out.toOwnedSlice(alloc);
}

fn anexarFoto(app: *App) void {
    if (foto.len > 0) alloc.free(foto);
    foto = fotoComGps() catch return;
    _ = c.SDL_CreateDirectory("qa-out");
    _ = c.SDL_SaveFile("qa-out/foto-gps.png", foto.ptr, foto.len);
    var buf: [1024]u8 = undefined;
    const cwd = c.SDL_GetCurrentDirectory() orelse return;
    defer c.SDL_free(cwd);
    app.attachFile(std.fmt.bufPrint(&buf, "{s}qa-out/foto-gps.png", .{std.mem.span(cwd)}) catch return);
}
fn fotoNaBandeja(app: *App) bool {
    const ups = app.st.uploads.items;
    return ups.len == 1 and ups[0].width == 48 and std.mem.endsWith(u8, ups[0].path, "foto-gps.png");
}

/// O arquivo da pessoa continua como foi gravado.
fn fotoIntacta() bool {
    var size: usize = 0;
    const data = c.SDL_LoadFile("qa-out/foto-gps.png", &size) orelse return false;
    defer c.SDL_free(data);
    return std.mem.eql(u8, @as([*]const u8, @ptrCast(data))[0..size], foto);
}

fn foiLimpo(app: *App) bool {
    if (!enviado(app)) return false;
    const d = dados();
    const size = gw.sent.send_data_size.load(.acquire);
    if (size == 0 or size >= foto.len or d.len != size) return false;
    if (std.mem.indexOf(u8, d, "GPS") != null or std.mem.indexOf(u8, d, "tEXt") != null or std.mem.indexOf(u8, d, "eXIf") != null) return false;
    // A mesma imagem, pixel a pixel.
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const px = c.stbi_load_from_memory(d.ptr, @intCast(d.len), &w, &h, &comp, 4) orelse return false;
    defer c.stbi_image_free(px);
    return w == 48 and h == 32 and std.mem.eql(u8, px[0 .. 48 * 32 * 4], foto_px) and fotoIntacta();
}

fn foiOriginal(app: *App) bool {
    return enviado(app) and gw.sent.send_data_size.load(.acquire) == foto.len and std.mem.eql(u8, dados(), foto) and fotoIntacta();
}

/// O nome do interruptor passa do tamanho de uma marca do QA (56 bytes): o clique vai na
/// linha dele, logo abaixo da do indicador de digitação (que fica em cima na página).
const interruptor: Op = .{ .click = .{ .at = .{ .key = "toggle:Enviar indicador de digitação", .fx = 0.5, .fy = 1.3 } } };

fn desligada(app: *App) bool {
    return !app.st.settings.strip_metadata and app.st.settings.open;
}
fn ligada(app: *App) bool {
    return app.st.settings.strip_metadata and app.st.settings.open;
}
fn fechada(app: *App) bool {
    return !app.st.settings.open;
}

// --- Um PNG girado pelo Exif -----------------------------------------------------------

fn anexarGirada(app: *App) void {
    const px = alloc.alloc(u8, 40 * 20 * 4) catch return;
    defer alloc.free(px);
    @memset(px, 200);
    const base = png_escrita.codificar(alloc, px, 40, 20, 40 * 4) catch return;
    defer alloc.free(base);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.appendSlice(alloc, base[0 .. 8 + 25]) catch return;
    // Orientação 6: girar 90° para a direita para ficar de pé.
    png_escrita.bloco(alloc, &out, "eXIf", "MM\x00\x2a\x00\x00\x00\x08\x00\x01\x01\x12\x00\x03\x00\x00\x00\x01\x00\x06\x00\x00\x00\x00\x00\x00") catch return;
    out.appendSlice(alloc, base[8 + 25 ..]) catch return;
    _ = c.SDL_SaveFile("qa-out/girada.png", out.items.ptr, out.items.len);
    var buf: [1024]u8 = undefined;
    const cwd = c.SDL_GetCurrentDirectory() orelse return;
    defer c.SDL_free(cwd);
    app.attachFile(std.fmt.bufPrint(&buf, "{s}qa-out/girada.png", .{std.mem.span(cwd)}) catch return);
}
fn giradaNaBandeja(app: *App) bool {
    const ups = app.st.uploads.items;
    return ups.len == 1 and ups[0].width == 40 and ups[0].editavel and qa.find("upload-edit:0") != null;
}
fn abriuDePe(app: *App) bool {
    const v = editor.visto() orelse return false;
    return app.st.popup == .editar_imagem and v.w == 20 and v.h == 40;
}
fn bandejaVazia(app: *App) bool {
    return app.st.uploads.items.len == 0 and app.st.popup == .none;
}
fn tirarDaBandeja(app: *App) void {
    if (app.st.uploads.items.len > 0) app.handle(.{ .remove_upload = 0 });
}

// --- Escala ----------------------------------------------------------------------------

fn escala125(app: *App) void {
    app.st.settings.ui_scale = 1.25;
}
fn escala100(app: *App) void {
    app.st.settings.ui_scale = 1;
}
fn emEscala(app: *App) bool {
    return app.ui_size == 1.25;
}

/// Colar, cortar, pixelar, Enter e conferir o arquivo: o caminho principal, que as duas
/// baterias fazem.
const caminho = [_]Op{
    click("composer"),
    run(copiarPrint),
    ctrl(c.ImGuiKey_V),
    expect("Ctrl+V com um PNG entra na bandeja, na pasta só nossa, com o Editar", coladoNaBandeja),
    .{ .wait = 200 },
    .{ .shot = "imagem-bandeja" },
    click("upload-edit:0"),
    expect("Editar abre o editor com a imagem inteira", editorAberto),
    .{ .shot = "imagem-editor" },
    arrasta(0.10, 0.15, 0.85, 0.90),
    expect("arrastar na imagem faz o corte, com as alças", cortou),
    .{ .drag = .{ .from = .{ .mark = "editor-alca:4" }, .to = .{ .at = .{ .key = "editor-imagem", .fx = 0.80, .fy = 0.85 } } } },
    expect("a alça de baixo mexe só naquele canto", alcaMexeu),
    click("editor:Pixelar"),
    arrasta(0.30, 0.35, 0.55, 0.60),
    expect("com Pixelar, arrastar esconde o pedaço em blocos", umaArea),
};

const fim_caminho = [_]Op{
    run(guardar),
    key(c.ImGuiKey_Enter),
    expect("Enter grava o PNG editado, que toma o lugar na bandeja", trocou),
    expect("do tamanho do corte, com os blocos só no pedaço e o resto igual ao original", conferePixels),
    expect("o print colado de antes foi apagado", antigoApagado),
    .{ .wait = 300 },
    .{ .shot = "imagem-bandeja-editada" },
};

pub const ops = caminho ++ [_]Op{
    s("editor: tarja e desfazer"),
    click("editor:Tarja preta"),
    arrasta(0.60, 0.30, 0.75, 0.45),
    expect("a tarja entra como outro pedaço", duasAreas),
    .{ .wait = 200 },
    .{ .shot = "imagem-editor-escondido" },
    ctrl(c.ImGuiKey_Z),
    expect("Ctrl+Z tira a tarja e deixa os blocos", umaArea),
    s("editor: pronto"),
} ++ fim_caminho ++ [_]Op{
    s("editor: recomeçar e cancelar"),
    run(guardarCaminho),
    click("upload-edit:0"),
    expect("editar de novo abre o PNG editado", segundaVez),
    click("editor:Tarja preta"),
    arrasta(0.20, 0.20, 0.50, 0.50),
    expect("uma tarja", tarjaMarcada),
    click("editor:Recomeçar"),
    expect("Recomeçar volta à imagem inteira, sem nada escondido", recomecou),
    arrasta(0.20, 0.20, 0.50, 0.50),
    key(c.ImGuiKey_Escape),
    expect("Esc fecha sem mudar o arquivo da bandeja", fechouSemMudar),

    s("envio: o PNG editado sobe como está"),
    run(guardarEditado),
    run(contarEnvios),
    click("composer"),
    key(c.ImGuiKey_Enter),
    expect("o PNG do editor não tem o que tirar: sobe byte a byte", editadoComoEsta),

    s("privacidade: localização ligada"),
    run(anexarFoto),
    expect("a foto com GPS entra na bandeja", fotoNaBandeja),
    run(contarEnvios),
    click("composer"),
    key(c.ImGuiKey_Enter),
    expect("ligado (o padrão): sobe uma cópia sem o GPS e sem os textos, com a mesma imagem; o arquivo não muda", foiLimpo),

    s("privacidade: desligada"),
    click("user-btn:2"),
    click("settings:Privacidade"),
    .{ .wait = 200 },
    interruptor,
    expect("o interruptor em Privacidade desliga", desligada),
    .{ .shot = "imagem-privacidade" },
    key(c.ImGuiKey_Escape),
    expect("fecha as configurações", fechada),
    run(anexarFoto),
    expect("a foto entra de novo", fotoNaBandeja),
    run(contarEnvios),
    click("composer"),
    key(c.ImGuiKey_Enter),
    expect("desligado: sobe o arquivo como está, byte a byte", foiOriginal),
    click("user-btn:2"),
    click("settings:Privacidade"),
    .{ .wait = 200 },
    interruptor,
    expect("e liga de novo", ligada),
    key(c.ImGuiKey_Escape),
    expect("fecha as configurações", fechada),

    s("editor: foto girada pelo Exif"),
    run(anexarGirada),
    expect("o PNG com orientação entra com o Editar", giradaNaBandeja),
    click("upload-edit:0"),
    expect("o editor mostra a foto de pé (20 × 40, não 40 × 20)", abriuDePe),
    .{ .shot = "imagem-editor-girada" },
    key(c.ImGuiKey_Escape),
    run(tirarDaBandeja),
    expect("tirar da bandeja", bandejaVazia),
};

/// Outro tema, outro idioma, a interface em 125%: o mesmo caminho, com os prints.
pub const ops_tema = [_]Op{
    s("imagem: tema, idioma e escala"),
    run(escala125),
    expect("a interface em 125%", emEscala),
    .{ .wait = 300 },
} ++ caminho ++ [_]Op{
    .{ .wait = 300 },
    .{ .shot = "imagem-editor-escondido" },
} ++ fim_caminho ++ [_]Op{
    run(tirarDaBandeja),
    expect("tirar da bandeja", bandejaVazia),
    run(escala100),
};
