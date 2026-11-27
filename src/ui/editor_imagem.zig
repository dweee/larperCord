//! Editor de imagem da bandeja: antes de enviar, cortar e esconder pedaços (um nome num
//! print, um endereço, um rosto). Abre pelo botão Editar no cartão de uma imagem parada
//! (ui/upload_opts.zig) e cobre a janela com o estilo do tema. Esconder vale de verdade:
//! blocos grandes ou uma tarja preta entram nos pixels do arquivo que sai (as contas em
//! core/imagem_edicao.zig). Pronto grava um PNG novo na pasta temporária nossa
//! (core/png_escrita.zig, platform/temporarios.zig), e ele toma o lugar do arquivo na
//! bandeja com o spoiler e o texto alternativo de antes; o arquivo da pessoa não muda.
//!
//! A imagem fica inteira na memória enquanto o editor está aberto, já de pé (a
//! orientação do Exif aplicada), e a tela mostra uma cópia reduzida de até 2048 pixels
//! de lado. Acima de `max_pixels` o editor não abre. Enter = Pronto, Esc = Cancelar,
//! Ctrl+Z = Desfazer.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const popup = @import("popup.zig");
const inbox = @import("inbox.zig");
const forum = @import("forum.zig");
const images = @import("images.zig");
const state = @import("state.zig");
const ie = @import("../core/imagem_edicao.zig");
const metadados = @import("../core/metadados.zig");
const png_escrita = @import("../core/png_escrita.zig");
const envio = @import("../core/envio.zig");
const temporarios = @import("../platform/temporarios.zig");

const alloc = std.heap.c_allocator;

/// 20 MP em RGBA são 80 MB na memória enquanto o editor está aberto (uma foto de celular
/// de 12 MP, um print de 5K e três telas lado a lado cabem).
pub const max_pixels: u64 = 20_000_000;
/// O lado maior da prévia (a textura na tela).
const lado_previa: f32 = 2048;

pub const Ferramenta = enum { cortar, blocos, tarja };

/// O que Desfazer volta: o corte de antes, ou o último pedaço escondido.
const Passo = union(enum) { corte: ie.Ret, area };

/// O que o mouse está arrastando. `alca`: 0..7 os cantos e os lados (do canto de cima à
/// esquerda, no sentido do relógio), 8 o meio (mover o corte).
const Arrasto = struct {
    tipo: enum { corte_novo, alca, area },
    alca: u8 = 0,
    /// Onde começou, em pixels da imagem.
    x0: i64,
    y0: i64,
    /// O corte quando começou (para mexer a partir dele, ou voltar).
    antes: ie.Ret,
    /// O pedaço que está sendo marcado.
    atual: ie.Ret = .{},
};

const Editor = struct {
    /// O arquivo da bandeja que abriu (Pronto confere que ainda é ele).
    caminho: [:0]u8,
    /// A imagem inteira, de pé.
    px: []u8,
    w: u32,
    h: u32,
    /// A prévia sem nada escondido, a que está na tela, e a textura dela.
    base: []u8,
    prev: []u8,
    pw: u32,
    ph: u32,
    /// Null depois de a janela ir para a bandeja (`dropTexture`): refeita de `prev`.
    tex: ?*c.SDL_Texture,
    corte: ie.Ret,
    areas: std.ArrayList(ie.Area) = .empty,
    passos: std.ArrayList(Passo) = .empty,
    ferramenta: Ferramenta = .cortar,
    arrasto: ?Arrasto = null,
    /// A textura está sem suavizar (ampliada, cada pixel aparece como é).
    nitida: bool = false,

    fn inteira(e: *const Editor) ie.Ret {
        return .{ .w = e.w, .h = e.h };
    }
    fn mudou(e: *const Editor) bool {
        return !e.corte.eql(e.inteira()) or e.areas.items.len > 0;
    }
};

var ed: ?Editor = null;

/// Solta tudo (a textura também). Só fora do desenho do editor: a textura pode estar na
/// lista de desenho do quadro.
pub fn fechar() void {
    const e: *Editor = if (ed) |*x| x else return;
    if (e.tex) |t| c.SDL_DestroyTexture(t);
    alloc.free(e.px);
    alloc.free(e.base);
    alloc.free(e.prev);
    alloc.free(e.caminho);
    e.areas.deinit(alloc);
    e.passos.deinit(alloc);
    ed = null;
}

/// O renderizador vai embora (a janela na bandeja, App.releaseGpu). O editor aberto
/// continua com o que foi feito: a textura é refeita da prévia no próximo quadro dele.
pub fn dropTexture() void {
    const e: *Editor = if (ed) |*x| x else return;
    if (e.tex) |t| c.SDL_DestroyTexture(t);
    e.tex = null;
}

/// A textura da prévia (refeita depois da bandeja). Null se o SDL não deu.
fn textura(ctx: *d.Ctx, e: *Editor) ?*c.SDL_Texture {
    if (e.tex) |t| return t;
    const t = c.SDL_CreateTexture(ctx.images.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, @intCast(e.pw), @intCast(e.ph)) orelse return null;
    _ = c.SDL_SetTextureScaleMode(t, if (e.nitida) c.SDL_SCALEMODE_NEAREST else c.SDL_SCALEMODE_LINEAR);
    _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_UpdateTexture(t, null, e.prev.ptr, @intCast(e.pw * 4));
    e.tex = t;
    return t;
}

/// O popup do editor fechou (Pronto, Cancelar, Esc, outro popup por cima): a memória
/// volta no quadro seguinte, antes de qualquer desenho.
pub fn varrer(st: *const state.State) void {
    if (ed != null and st.popup != .editar_imagem) fechar();
}

/// Para o QA: o corte, os pedaços escondidos, o tamanho da imagem e a ferramenta.
pub const Visto = struct { corte: ie.Ret, areas: []const ie.Area, w: u32, h: u32, ferramenta: Ferramenta };
pub fn visto() ?Visto {
    const e: *const Editor = if (ed) |*x| x else return null;
    return .{ .corte = e.corte, .areas = e.areas.items, .w = e.w, .h = e.h, .ferramenta = e.ferramenta };
}

// --- Abrir -------------------------------------------------------------------------

fn falha(ctx: *d.Ctx) void {
    ctx.st.showToast(ctx.now_ms, true, "não consegui abrir a imagem", "couldn't open the image", .{});
}
fn semMemoria(ctx: *d.Ctx) void {
    ctx.st.showToast(ctx.now_ms, true, "sem memória para editar essa imagem", "not enough memory to edit this image", .{});
}

/// Abre o arquivo `index` da bandeja no editor.
pub fn abrir(ctx: *d.Ctx, index: usize) void {
    fechar();
    const st = ctx.st;
    if (index >= st.uploads.items.len or index > std.math.maxInt(u8)) return;
    const u = &st.uploads.items[index];
    var size: usize = 0;
    const data = c.SDL_LoadFile(u.path.ptr, &size) orelse return falha(ctx);
    defer c.SDL_free(data);
    if (size > std.math.maxInt(c_int)) return falha(ctx);
    const bytes = @as([*]const u8, @ptrCast(data))[0..size];
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    if (c.stbi_info_from_memory(bytes.ptr, @intCast(size), &w, &h, &comp) == 0 or w <= 0 or h <= 0) return falha(ctx);
    if (@as(u64, @intCast(w)) * @as(u64, @intCast(h)) > max_pixels)
        return st.showToast(ctx.now_ms, true, "imagem grande demais para editar aqui (até {d} megapixels)", "image too large to edit here (up to {d} megapixels)", .{max_pixels / 1_000_000});
    const src = c.stbi_load_from_memory(bytes.ptr, @intCast(size), &w, &h, &comp, 4) orelse return falha(ctx);
    defer c.stbi_image_free(src);
    const sw: u32 = @intCast(w);
    const sh: u32 = @intCast(h);
    // De pé, como o Discord vai mostrar (o stb lê os pixels como estão no arquivo).
    const o = metadados.orientacao(bytes);
    const iw, const ih = ie.tamanhoOrientado(sw, sh, o);
    const px = alloc.alloc(u8, @as(usize, iw) * ih * 4) catch return semMemoria(ctx);
    ie.orientar(src[0 .. @as(usize, sw) * sh * 4], sw, sh, o, px);
    // A prévia no tamanho em que a imagem aparece, em pixels da tela.
    const tela = medidas(ctx).tela;
    const fb = ctx.io.*.DisplayFramebufferScale.x;
    const fw: f32 = @floatFromInt(iw);
    const fh: f32 = @floatFromInt(ih);
    const k = @min(1, @min(@min(lado_previa, @max(64, tela.w * fb)) / fw, @min(lado_previa, @max(64, tela.h * fb)) / fh));
    const pw: u32 = @max(1, @as(u32, @intFromFloat(@round(fw * k))));
    const ph: u32 = @max(1, @as(u32, @intFromFloat(@round(fh * k))));
    const base = alloc.alloc(u8, @as(usize, pw) * ph * 4) catch {
        alloc.free(px);
        return semMemoria(ctx);
    };
    if (pw == iw and ph == ih) @memcpy(base, px) else images.resize(px, iw, ih, base, pw, ph);
    const prev = alloc.dupe(u8, base) catch {
        alloc.free(px);
        alloc.free(base);
        return semMemoria(ctx);
    };
    const caminho = alloc.dupeSentinel(u8, u.path, 0) catch {
        alloc.free(px);
        alloc.free(base);
        alloc.free(prev);
        return semMemoria(ctx);
    };
    const tex = c.SDL_CreateTexture(ctx.images.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, @intCast(pw), @intCast(ph)) orelse {
        alloc.free(px);
        alloc.free(base);
        alloc.free(prev);
        alloc.free(caminho);
        return falha(ctx);
    };
    _ = c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_LINEAR);
    _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_UpdateTexture(tex, null, prev.ptr, @intCast(pw * 4));
    ed = .{ .caminho = caminho, .px = px, .w = iw, .h = ih, .base = base, .prev = prev, .pw = pw, .ph = ph, .tex = tex, .corte = .{ .w = iw, .h = ih } };
    ctx.popup(.{ .editar_imagem = .{ .index = @intCast(index) } });
}

// --- Editar ------------------------------------------------------------------------

/// A prévia com os pedaços escondidos de agora, na textura.
fn refazerPrevia(ctx: *d.Ctx, e: *Editor) void {
    @memcpy(e.prev, e.base);
    const kx = @as(f32, @floatFromInt(e.pw)) / @as(f32, @floatFromInt(e.w));
    const ky = @as(f32, @floatFromInt(e.ph)) / @as(f32, @floatFromInt(e.h));
    for (e.areas.items) |a| ie.esconder(e.prev, e.pw, e.ph, a, 0, 0, kx, ky);
    if (e.tex) |t| _ = c.SDL_UpdateTexture(t, null, e.prev.ptr, @intCast(e.pw * 4));
    // A mesma textura com outra imagem: o quadro não pode ser pulado por "igual".
    ctx.images.texture_changed = true;
}

fn desfazer(ctx: *d.Ctx, e: *Editor) void {
    const p = e.passos.pop() orelse return;
    switch (p) {
        .corte => |r| e.corte = r,
        .area => {
            _ = e.areas.pop();
            refazerPrevia(ctx, e);
        },
    }
}

fn recomecar(ctx: *d.Ctx, e: *Editor) void {
    const tinha = e.areas.items.len > 0;
    e.corte = e.inteira();
    e.areas.clearRetainingCapacity();
    e.passos.clearRetainingCapacity();
    if (tinha) refazerPrevia(ctx, e);
}

/// "foto.jpg" → "foto.png" (o nome que vai para o Discord).
fn nomePng(buf: []u8, nome: []const u8) []const u8 {
    if (nome.len == 0) return "imagem.png";
    const ponto = std.mem.lastIndexOfScalar(u8, nome, '.') orelse nome.len;
    // Sem nada antes do ponto (".png"), o nome inteiro fica.
    const raiz = d.utf8Prefix(nome[0..if (ponto == 0) nome.len else ponto], buf.len - 8);
    return std.fmt.bufPrint(buf, "{s}.png", .{raiz}) catch "imagem.png";
}

/// Pronto: o recorte com os pedaços escondidos vira um PNG novo, que entra na bandeja.
fn concluir(ctx: *d.Ctx, e: *Editor, index: u8) void {
    if (!e.mudou()) return popup.close(ctx);
    const out = ie.recortar(alloc, e.px, e.w, e.corte, e.areas.items) catch return semMemoria(ctx);
    defer alloc.free(out);
    const png = png_escrita.codificar(alloc, out, e.corte.w, e.corte.h, @as(usize, e.corte.w) * 4) catch return semMemoria(ctx);
    defer alloc.free(png);
    // Uma foto grande em PNG pode passar do limite: a pessoa corta menos e tenta de novo.
    if (png.len > envio.max_upload) return ctx.st.showToast(ctx.now_ms, true, "a imagem editada passou de 10 MB; corte um pedaço menor", "the edited image is over 10 MB; crop a smaller part", .{});
    var nb: [256]u8 = undefined;
    const nome = nomePng(&nb, std.fs.path.basename(e.caminho));
    var pb: [1100]u8 = undefined;
    const salvo = blk: {
        const path = temporarios.novo(&pb, nome) orelse break :blk null;
        if (!c.SDL_SaveFile(path.ptr, png.ptr, png.len)) {
            temporarios.apagar(path);
            break :blk null;
        }
        break :blk alloc.dupeSentinel(u8, path, 0) catch {
            temporarios.apagar(path);
            break :blk null;
        };
    } orelse return ctx.st.showToast(ctx.now_ms, true, "não consegui salvar a imagem editada", "couldn't save the edited image", .{});
    ctx.act(.{ .replace_upload = .{ .index = index, .path = salvo, .size = png.len, .width = @intCast(@min(e.corte.w, 65535)), .height = @intCast(@min(e.corte.h, 65535)) } });
    popup.close(ctx);
}

// --- Tela --------------------------------------------------------------------------

const Medidas = struct { painel: d.Rect, topo: d.Rect, tela: d.Rect, base: d.Rect };

fn medidas(ctx: *const d.Ctx) Medidas {
    const m: f32 = 16;
    const painel: d.Rect = .{ .x = ctx.win.x + m, .y = ctx.win.y + m, .w = @max(ctx.win.w - 2 * m, 200), .h = @max(ctx.win.h - 2 * m, 200) };
    const topo: d.Rect = .{ .x = painel.x, .y = painel.y, .w = painel.w, .h = 56 };
    const base: d.Rect = .{ .x = painel.x, .y = painel.bottom() - 60, .w = painel.w, .h = 60 };
    return .{ .painel = painel, .topo = topo, .base = base, .tela = .{ .x = painel.x + 16, .y = topo.bottom(), .w = painel.w - 32, .h = @max(base.y - topo.bottom(), 40) } };
}

/// Onde a imagem inteira aparece dentro da `tela` (cabe inteira; uma pequena cresce até
/// 3 vezes, para dar onde segurar).
fn vista(e: *const Editor, tela: d.Rect) struct { r: d.Rect, s: f32 } {
    const fw: f32 = @floatFromInt(e.w);
    const fh: f32 = @floatFromInt(e.h);
    const s = @min(3, @min((tela.w - 16) / fw, (tela.h - 16) / fh));
    const vw = fw * s;
    const vh = fh * s;
    return .{ .r = .{ .x = tela.x + (tela.w - vw) / 2, .y = tela.y + (tela.h - vh) / 2, .w = vw, .h = vh }, .s = s };
}

fn naTela(r: ie.Ret, v: d.Rect, s: f32) d.Rect {
    return .{ .x = v.x + @as(f32, @floatFromInt(r.x)) * s, .y = v.y + @as(f32, @floatFromInt(r.y)) * s, .w = @as(f32, @floatFromInt(r.w)) * s, .h = @as(f32, @floatFromInt(r.h)) * s };
}

/// O ponto do mouse em pixels da imagem (preso dentro dela).
fn pontoImagem(e: *const Editor, ctx: *const d.Ctx, v: d.Rect, s: f32) [2]i64 {
    const x: i64 = @intFromFloat(@round((ctx.mouse.x - v.x) / s));
    const y: i64 = @intFromFloat(@round((ctx.mouse.y - v.y) / s));
    return .{ std.math.clamp(x, 0, e.w), std.math.clamp(y, 0, e.h) };
}

fn retDe(x0: i64, y0: i64, x1: i64, y1: i64) ie.Ret {
    return .{ .x = @intCast(@min(x0, x1)), .y = @intCast(@min(y0, y1)), .w = @intCast(@abs(x1 - x0)), .h = @intCast(@abs(y1 - y0)) };
}

/// Os oito pontos de segurar do corte, na tela.
fn alcas(r: d.Rect) [8][2]f32 {
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    return .{ .{ r.x, r.y }, .{ cx, r.y }, .{ r.right(), r.y }, .{ r.right(), cy }, .{ r.right(), r.bottom() }, .{ cx, r.bottom() }, .{ r.x, r.bottom() }, .{ r.x, cy } };
}

fn alcaSob(ctx: *const d.Ctx, r: d.Rect) ?u8 {
    for (alcas(r), 0..) |p, i| {
        if (@abs(ctx.mouse.x - p[0]) <= 9 and @abs(ctx.mouse.y - p[1]) <= 9) return @intCast(i);
    }
    return if (r.contains(ctx.mouse.x, ctx.mouse.y)) 8 else null;
}

fn cursorDe(alca: u8) c_int {
    return switch (alca) {
        0, 4 => c.ImGuiMouseCursor_ResizeNWSE,
        2, 6 => c.ImGuiMouseCursor_ResizeNESW,
        1, 5 => c.ImGuiMouseCursor_ResizeNS,
        3, 7 => c.ImGuiMouseCursor_ResizeEW,
        else => c.ImGuiMouseCursor_ResizeAll,
    };
}

/// O corte enquanto uma alça é arrastada até (`mx`, `my`).
fn moverAlca(e: *const Editor, a: Arrasto, mx: i64, my: i64) ie.Ret {
    const r = a.antes;
    if (a.alca == 8) {
        const nx = std.math.clamp(@as(i64, r.x) + mx - a.x0, 0, @as(i64, e.w) - r.w);
        const ny = std.math.clamp(@as(i64, r.y) + my - a.y0, 0, @as(i64, e.h) - r.h);
        return .{ .x = @intCast(nx), .y = @intCast(ny), .w = r.w, .h = r.h };
    }
    var l: i64 = r.x;
    var t: i64 = r.y;
    var rr: i64 = r.right();
    var b: i64 = r.bottom();
    switch (a.alca) {
        0 => {
            l = mx;
            t = my;
        },
        1 => t = my,
        2 => {
            rr = mx;
            t = my;
        },
        3 => rr = mx,
        4 => {
            rr = mx;
            b = my;
        },
        5 => b = my,
        6 => {
            l = mx;
            b = my;
        },
        else => l = mx,
    }
    return retDe(l, t, rr, b);
}

fn segmento(ctx: *d.Ctx, dl: *c.ImDrawList, id: usize, r: d.Rect, label: []const u8, on: bool) bool {
    const hb = d.hit(ctx, id, r);
    const radius = @max(ctx.th.radius, 2);
    if (on) {
        d.rect(dl, r, ctx.col(.accent), radius);
    } else if (hb.hovered) d.rect(dl, r, ctx.col(.hover), radius);
    const f = ctx.ui.get(.semibold);
    d.text(dl, f, 13.5, r.x + (r.w - d.width(f, 13.5, label)) / 2, d.centerY(r, 13.5), if (on) ctx.col(.accent_text) else ctx.col(.text), label);
    return hb.clicked;
}

/// Botão em pílula como o de inbox.button, que pode estar apagado (sem nada a desfazer).
fn botao(ctx: *d.Ctx, dl: *c.ImDrawList, id: usize, r: d.Rect, label: []const u8, on: bool) bool {
    const hb = d.hit(ctx, id, r);
    const quente = on and hb.hovered;
    d.rect(dl, r, if (quente) ctx.col(.accent) else ctx.col(.hover), r.h / 2);
    const tc = if (quente) ctx.col(.accent_text) else ctx.col(.text).alpha(if (on) 1 else 0.4);
    d.text(dl, ctx.ui.get(.semibold), 13, r.x + 12, d.centerY(r, 13), tc, label);
    return on and hb.clicked;
}

fn largura(ctx: *const d.Ctx, label: []const u8) f32 {
    return inbox.buttonWidth(ctx, label);
}

const ferramentas = [_]struct { f: Ferramenta, pt: []const u8, en: []const u8 }{
    .{ .f = .cortar, .pt = "Cortar", .en = "Crop" },
    .{ .f = .blocos, .pt = "Pixelar", .en = "Pixelate" },
    .{ .f = .tarja, .pt = "Tarja preta", .en = "Black bar" },
};

/// Um retângulo com o tamanho em pixels ("640 × 360") em cima de `r`.
fn etiqueta(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, w: u32, h: u32, limite: d.Rect) void {
    var b: [40]u8 = undefined;
    const t = std.fmt.bufPrint(&b, "{d} × {d}", .{ w, h }) catch return;
    const f = ctx.ui.get(.semibold);
    const tw = d.width(f, 12, t) + 14;
    var x = r.x;
    var y = r.y - 24;
    // Sem espaço em cima: dentro, no canto.
    if (y < limite.y + 2) y = r.y + 4;
    x = std.math.clamp(x, limite.x + 2, @max(limite.x + 2, limite.right() - tw - 2));
    const er: d.Rect = .{ .x = x, .y = y, .w = tw, .h = 20 };
    d.rect(dl, er, d.Rgba.black.alpha(0.72), 10);
    d.text(dl, f, 12, er.x + 7, d.centerY(er, 12), d.Rgba.white, t);
}

pub fn draw(ctx: *d.Ctx, index: u8) void {
    const e: *Editor = if (ed) |*x| x else return popup.close(ctx);
    // O arquivo saiu da bandeja (ou outro tomou o lugar): nada a editar.
    const ups = ctx.st.uploads.items;
    if (index >= ups.len or !std.mem.eql(u8, ups[index].path, e.caminho)) return popup.close(ctx);
    const m = medidas(ctx);
    const dl = popup.beginWindow("##editor-imagem", ctx.win);
    defer c.ImGui_End();
    ctx.dl = dl;
    d.rect(dl, ctx.win, d.Rgba.black.alpha(0.55), 0);
    inbox.panelFrame(ctx, dl, m.painel);
    qa.mark(m.painel, "editor-painel", .{});
    const fam = ctx.ui;

    // Topo: o título e as ferramentas.
    const titulo = i18n.tr("Editar imagem", "Edit image");
    d.text(dl, fam.get(.bold), 17, m.topo.x + 20, m.topo.y + 17, ctx.col(.text), titulo);
    {
        var tw: f32 = 0;
        for (ferramentas) |t| tw += d.width(fam.get(.semibold), 13.5, i18n.tr(t.pt, t.en)) + 28;
        const fim_titulo = m.topo.x + 20 + d.width(fam.get(.bold), 17, titulo) + 24;
        var x = @max(fim_titulo, m.topo.x + (m.topo.w - tw) / 2);
        const fundo: d.Rect = .{ .x = x - 3, .y = m.topo.y + 11, .w = tw + 6, .h = 36 };
        d.rect(dl, fundo, ctx.col(.rail).mix(ctx.col(.surface), 0.35), @max(ctx.th.radius, 2) + 2);
        for (ferramentas, 0..) |t, i| {
            const label = i18n.tr(t.pt, t.en);
            const r: d.Rect = .{ .x = x, .y = m.topo.y + 14, .w = d.width(fam.get(.semibold), 13.5, label) + 28, .h = 30 };
            x = r.right();
            qa.mark(r, "editor:{s}", .{t.pt});
            if (segmento(ctx, dl, 0x7600 + i, r, label, e.ferramenta == t.f)) e.ferramenta = t.f;
        }
    }

    // A imagem e o que está por cima dela.
    d.rect(dl, m.tela, ctx.col(.rail), @max(ctx.th.radius, 2));
    const vv = vista(e, m.tela);
    const v = vv.r;
    const s = vv.s;
    qa.mark(v, "editor-imagem", .{});
    // Ampliada, sem suavizar: os blocos aparecem com a borda que vão ter no arquivo.
    const nitida = v.w * ctx.io.*.DisplayFramebufferScale.x > @as(f32, @floatFromInt(e.pw)) + 0.5;
    if (nitida != e.nitida) {
        e.nitida = nitida;
        if (e.tex) |t| _ = c.SDL_SetTextureScaleMode(t, if (nitida) c.SDL_SCALEMODE_NEAREST else c.SDL_SCALEMODE_LINEAR);
        ctx.images.texture_changed = true;
    }
    if (textura(ctx, e)) |t| {
        const ref: c.ImTextureRef = .{ ._TexData = null, ._TexID = @intFromPtr(t) };
        c.ImDrawList_AddImage(dl, ref, d.v(v.x, v.y), d.v(v.right(), v.bottom()));
    }
    interagir(ctx, e, m.tela, v, s);
    const cr = naTela(e.corte, v, s);
    if (!e.corte.eql(e.inteira()) or e.ferramenta == .cortar) {
        // Fora do corte fica escuro.
        const veu = d.Rgba.black.alpha(0.6);
        d.rect(dl, .{ .x = v.x, .y = v.y, .w = v.w, .h = cr.y - v.y }, veu, 0);
        d.rect(dl, .{ .x = v.x, .y = cr.bottom(), .w = v.w, .h = v.bottom() - cr.bottom() }, veu, 0);
        d.rect(dl, .{ .x = v.x, .y = cr.y, .w = cr.x - v.x, .h = cr.h }, veu, 0);
        d.rect(dl, .{ .x = cr.right(), .y = cr.y, .w = v.right() - cr.right(), .h = cr.h }, veu, 0);
        d.border(dl, cr.inset(-1, -1), d.Rgba.black.alpha(0.5), 0, 3);
        d.border(dl, cr, d.Rgba.white, 0, 1.5);
        if (e.ferramenta == .cortar) for (alcas(cr), 0..) |p, i| {
            const q: d.Rect = .{ .x = p[0] - 4.5, .y = p[1] - 4.5, .w = 9, .h = 9 };
            d.rect(dl, q.inset(-1, -1), d.Rgba.black.alpha(0.6), 2);
            d.rect(dl, q, d.Rgba.white, 2);
            qa.mark(q, "editor-alca:{d}", .{i});
        };
        etiqueta(ctx, dl, cr, e.corte.w, e.corte.h, m.tela);
    }
    if (e.arrasto) |a| if (a.tipo == .area and a.atual.w > 0 and a.atual.h > 0) {
        const ar = naTela(a.atual, v, s);
        if (e.ferramenta == .tarja) {
            d.rect(dl, ar, d.Rgba.black.alpha(0.85), 0);
        } else d.rect(dl, ar, ctx.col(.accent).alpha(0.25), 0);
        d.border(dl, ar, ctx.col(.accent), 0, 1.5);
        etiqueta(ctx, dl, ar, a.atual.w, a.atual.h, m.tela);
    };

    // Embaixo: o tamanho que vai sair, a dica e os botões.
    const by = m.base.y + 13;
    const pronto = i18n.tr("Pronto", "Done");
    const cancelar = i18n.tr("Cancelar", "Cancel");
    const refazer = i18n.tr("Recomeçar", "Reset");
    const voltar = i18n.tr("Desfazer", "Undo");
    const pw_ = d.width(fam.get(.semibold), 13.5, pronto) + 36;
    const pr: d.Rect = .{ .x = m.base.right() - 20 - pw_, .y = by, .w = pw_, .h = 34 };
    qa.mark(pr, "editor:Pronto", .{});
    const cr2: d.Rect = .{ .x = pr.x - 10 - largura(ctx, cancelar), .y = by + 3, .w = largura(ctx, cancelar), .h = 28 };
    qa.mark(cr2, "editor:Cancelar", .{});
    const rr: d.Rect = .{ .x = cr2.x - 22 - largura(ctx, refazer), .y = by + 3, .w = largura(ctx, refazer), .h = 28 };
    qa.mark(rr, "editor:Recomeçar", .{});
    const ur: d.Rect = .{ .x = rr.x - 8 - largura(ctx, voltar), .y = by + 3, .w = largura(ctx, voltar), .h = 28 };
    qa.mark(ur, "editor:Desfazer", .{});
    {
        var sb: [96]u8 = undefined;
        const tam = i18n.fmt(&sb, "Imagem final: {d} × {d}", "Result: {d} × {d}", .{ e.corte.w, e.corte.h });
        const livre = ur.x - m.base.x - 40;
        _ = d.textClipped(dl, fam.get(.semibold), 13.5, m.base.x + 20, by - 1, ctx.col(.text), tam, livre);
        const dica = switch (e.ferramenta) {
            .cortar => i18n.tr("Arraste para cortar; os cantos e as bordas ajustam.", "Drag to crop; the corners and edges adjust it."),
            .blocos => i18n.tr("Arraste sobre o que quer esconder: vira blocos grandes, sem volta.", "Drag over what you want to hide: it turns into big blocks, for good."),
            .tarja => i18n.tr("Arraste sobre o que quer esconder: vira uma tarja preta.", "Drag over what you want to hide: it turns into a black bar."),
        };
        _ = d.textClipped(dl, fam.get(.regular), 12.5, m.base.x + 20, by + 19, ctx.col(.muted), dica, livre);
    }
    const hu = botao(ctx, dl, 0x7610, ur, voltar, e.passos.items.len > 0);
    d.tip(ctx, ur, "Ctrl+Z", ctx.hovering(ur));
    const hr = botao(ctx, dl, 0x7611, rr, refazer, e.mudou());
    const hc = botao(ctx, dl, 0x7612, cr2, cancelar, true);
    d.tip(ctx, cr2, "Esc", ctx.hovering(cr2));
    const hp = forum.primary(ctx, dl, fam, 0x7613, pr, pronto, true);
    d.tip(ctx, pr, "Enter", ctx.hovering(pr));

    if (hu or (ctx.io.*.KeyCtrl and c.ImGui_IsKeyPressed(c.ImGuiKey_Z))) desfazer(ctx, e);
    if (hr) recomecar(ctx, e);
    if (hc) return popup.close(ctx);
    if (hp or (e.arrasto == null and (c.ImGui_IsKeyPressed(c.ImGuiKey_Enter) or c.ImGui_IsKeyPressed(c.ImGuiKey_KeypadEnter)))) concluir(ctx, e, index);
}

/// O ruído dos blocos de um pedaço: ninguém de fora sabe de antemão (o relógio fino e o
/// sorteio do SDL, misturados).
fn semente() u64 {
    const bits: [2]u64 = .{ c.SDL_GetPerformanceCounter(), c.SDL_rand_bits() };
    return std.hash.Wyhash.hash(@intFromPtr(&bits), std.mem.asBytes(&bits));
}

/// O mouse na imagem: começar, seguir e terminar um arrasto.
fn interagir(ctx: *d.Ctx, e: *Editor, tela: d.Rect, v: d.Rect, s: f32) void {
    const sobre = tela.contains(ctx.mouse.x, ctx.mouse.y) and c.ImGui_IsWindowHovered(0);
    const ponto = pontoImagem(e, ctx, v, s);
    const cr = naTela(e.corte, v, s);
    if (e.arrasto == null and sobre) {
        // O cursor diz o que o arrasto vai fazer.
        if (e.ferramenta == .cortar) if (alcaSob(ctx, cr)) |a| {
            if (a < 8 or !e.corte.eql(e.inteira())) c.ImGui_SetMouseCursor(cursorDe(a));
        };
        if (c.ImGui_IsMouseClicked(0)) {
            // As alças valem sempre; o meio só move um corte que não é a imagem inteira.
            const alca = alcaSob(ctx, cr);
            if (e.ferramenta != .cortar) {
                e.arrasto = .{ .tipo = .area, .x0 = ponto[0], .y0 = ponto[1], .antes = e.corte };
            } else if (alca != null and (alca.? < 8 or !e.corte.eql(e.inteira()))) {
                e.arrasto = .{ .tipo = .alca, .alca = alca.?, .x0 = ponto[0], .y0 = ponto[1], .antes = e.corte };
            } else {
                e.arrasto = .{ .tipo = .corte_novo, .x0 = ponto[0], .y0 = ponto[1], .antes = e.corte };
            }
        }
    }
    const a: *Arrasto = if (e.arrasto) |*x| x else return;
    switch (a.tipo) {
        .corte_novo => e.corte = retDe(a.x0, a.y0, ponto[0], ponto[1]),
        .alca => {
            e.corte = moverAlca(e, a.*, ponto[0], ponto[1]);
            c.ImGui_SetMouseCursor(cursorDe(a.alca));
        },
        .area => a.atual = retDe(a.x0, a.y0, ponto[0], ponto[1]),
    }
    if (c.ImGui_IsMouseDown(0)) return;
    // Soltou.
    const fim = a.*;
    e.arrasto = null;
    switch (fim.tipo) {
        .corte_novo, .alca => {
            // Um clique (ou um corte de nada) não muda o corte.
            if (e.corte.w < 4 or e.corte.h < 4) {
                e.corte = fim.antes;
            } else if (!e.corte.eql(fim.antes)) {
                e.passos.append(alloc, .{ .corte = fim.antes }) catch {};
            }
        },
        .area => {
            if (fim.atual.w < 2 or fim.atual.h < 2) return;
            const modo: ie.Modo = if (e.ferramenta == .tarja) .tarja else .blocos;
            const area: ie.Area = .{ .r = fim.atual, .modo = modo, .bloco = ie.ladoBloco(fim.atual.w, fim.atual.h, e.w, e.h), .semente = semente() };
            e.areas.append(alloc, area) catch return semMemoria(ctx);
            e.passos.append(alloc, .area) catch {
                _ = e.areas.pop();
                return semMemoria(ctx);
            };
            refazerPrevia(ctx, e);
        },
    }
}
