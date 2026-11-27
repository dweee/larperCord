//! Uma camada para desenhar algo inteiro meio transparente (o mascote do canto no
//! status invisível, o clone do Ctrl+C sumindo). Com o alpha em cada peça, o que fica
//! por baixo de outra peça aparece através dela: as orelhas atrás do corpo, o chapéu,
//! as pontas redondas dos traços, e as emendas viram manchas mais escuras. Aqui o
//! desenho vai opaco para uma textura, e a textura entra no quadro com o alpha pedido,
//! de uma vez: some por igual.
//!
//! Quem desenha pede a lista com `begin`, desenha nela como num ImDrawList qualquer e
//! fecha com `end`, que põe em `dl` um callback e a imagem da textura. Na hora de ir
//! para a tela, o callback desenha a lista na textura (cada textura do SDL_Renderer tem
//! o próprio corte e a própria escala, e o alvo de antes volta no fim) e a imagem logo
//! depois cobre o lugar, com alpha pré-multiplicado. O canto da textura cai num pixel
//! inteiro: o desenho opaco sai no mesmo lugar do desenhado direto na tela.
//!
//! O desenho que não mudou não é refeito: `end` recebe o resumo dele (ui/carimbo.zig), e
//! enquanto o resumo for o mesmo, `reuse` põe só a imagem da textura que já está pronta.
//! A textura só vale depois de desenhada (o callback rodou), e sai junto com o
//! renderizador (a janela na bandeja) ou quando o SDL avisa que os alvos se perderam.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const fx = @import("fx.zig");

const ca = std.heap.c_allocator;

/// Maior lado da textura, em pixels (o mascote do canto tem uns 100).
const max_side: f32 = 2048;

pub const Layer = struct {
    /// A lista em que o desenho é feito (refeita a cada quadro; a memória fica).
    list: c.ImDrawList = std.mem.zeroes(c.ImDrawList),
    renderer: ?*c.SDL_Renderer = null,
    tex: ?*c.SDL_Texture = null,
    tex_w: f32 = 0,
    tex_h: f32 = 0,
    /// As cores dos vértices como o SDL quer (float).
    colors: std.ArrayList(c.SDL_FColor) = .empty,
    listed: bool = false,
    /// O desenho deste quadro está pronto para o callback.
    armed: bool = false,
    /// O que está na textura: o resumo do desenho e onde a imagem dele vai (vale depois
    /// que o callback desenhou). `pend_*`: o deste quadro, esperando o callback.
    key: u64 = 0,
    img: Img = .{},
    valid: bool = false,
    pend_key: u64 = 0,
    pend_img: Img = .{},
    /// Quantas vezes a textura pronta foi reaproveitada (o QA confere).
    hits: u64 = 0,

    /// A textura pronta tem o desenho com o resumo `key`: só a imagem dela vai para `dl`,
    /// com `alpha`. Falso: desenhe (`begin` e `end`).
    pub fn reuse(l: *Layer, dl: *c.ImDrawList, renderer: ?*c.SDL_Renderer, key: u64, alpha: f32) bool {
        if (!l.valid or l.key != key or renderer == null or l.renderer != renderer or l.tex == null) return false;
        l.armed = false;
        l.hits +%= 1;
        if (alpha > 0.002) image(l, dl, l.img, alpha);
        return true;
    }

    /// Começa: a lista em que desenhar, com o corte e a textura de `dl`. Null sem
    /// SDL_Renderer: quem chama desenha direto, com o alpha em cada peça.
    pub fn begin(l: *Layer, dl: *c.ImDrawList, renderer: ?*c.SDL_Renderer) ?*c.ImDrawList {
        const r = renderer orelse return null;
        const shared = c.ImGui_GetDrawListSharedData() orelse return null;
        if (l.renderer != null and l.renderer != r) dropTexture(l);
        l.renderer = r;
        if (!l.listed) {
            if (n_live == live.len) return null;
            live[n_live] = l;
            n_live += 1;
            l.listed = true;
        }
        l.armed = false;
        l.list._Data = shared;
        c.ImDrawList__ResetForNewFrame(&l.list);
        // Como `dl` desenha: as mesmas opções e a mesma densidade de pixel (a borda
        // suavizada de cada forma sai igual).
        l.list.Flags = dl.*.Flags;
        l.list._FringeScale = dl.*._FringeScale;
        l.list._InvFringeScale = dl.*._InvFringeScale;
        l.list._FringeScaleIsInteger = dl.*._FringeScaleIsInteger;
        c.ImDrawList_PushClipRect(&l.list, c.ImDrawList_GetClipRectMin(dl), c.ImDrawList_GetClipRectMax(dl), false);
        c.ImDrawList_PushTexture(&l.list, dl.*._CmdHeader.TexRef);
        return &l.list;
    }

    /// Fecha e põe o desenho em `dl` com `alpha`; `key` é o resumo dele (ver `reuse`).
    /// Sem textura (o renderer recusou), as peças vão direto para `dl` com o alpha em
    /// cada uma, como antes.
    pub fn end(l: *Layer, dl: *c.ImDrawList, alpha: f32, key: u64) void {
        const list = &l.list;
        const nv: usize = @intCast(list.VtxBuffer.Size);
        if (nv == 0 or alpha <= 0.002) return;
        const vtx = list.VtxBuffer.Data[0..nv];
        // A caixa do desenho, dentro do corte de `dl`.
        var lo = d.v(std.math.inf(f32), std.math.inf(f32));
        var hi = d.v(-std.math.inf(f32), -std.math.inf(f32));
        for (vtx) |q| {
            lo = d.v(@min(lo.x, q.pos.x), @min(lo.y, q.pos.y));
            hi = d.v(@max(hi.x, q.pos.x), @max(hi.y, q.pos.y));
        }
        const cmin = c.ImDrawList_GetClipRectMin(dl);
        const cmax = c.ImDrawList_GetClipRectMax(dl);
        lo = d.v(@max(lo.x, cmin.x), @max(lo.y, cmin.y));
        hi = d.v(@min(hi.x, cmax.x), @min(hi.y, cmax.y));
        if (hi.x <= lo.x or hi.y <= lo.y) return;
        const fb = c.ImGui_GetIO().*.DisplayFramebufferScale;
        const sx = if (fb.x > 0) fb.x else 1;
        const sy = if (fb.y > 0) fb.y else 1;
        // O canto num pixel inteiro: a imagem cai pixel sobre pixel da textura.
        const px0 = @floor(lo.x * sx);
        const py0 = @floor(lo.y * sy);
        const w = @ceil(hi.x * sx) - px0;
        const h = @ceil(hi.y * sy) - py0;
        if (w > max_side or h > max_side or !ensureTexture(l, w, h)) return replay(l, dl, alpha);
        l.colors.resize(ca, nv) catch return replay(l, dl, alpha);
        // Os vértices e os cortes passam para os pixels da textura.
        for (vtx, l.colors.items) |*q, *fc| {
            q.pos = d.v(q.pos.x * sx - px0, q.pos.y * sy - py0);
            fc.* = .{
                .r = @as(f32, @floatFromInt(q.col & 0xFF)) / 255.0,
                .g = @as(f32, @floatFromInt((q.col >> 8) & 0xFF)) / 255.0,
                .b = @as(f32, @floatFromInt((q.col >> 16) & 0xFF)) / 255.0,
                .a = @as(f32, @floatFromInt(q.col >> 24)) / 255.0,
            };
        }
        for (cmdSlice(list)) |*cmd| {
            cmd.ClipRect = .{ .x = cmd.ClipRect.x * sx - px0, .y = cmd.ClipRect.y * sy - py0, .z = cmd.ClipRect.z * sx - px0, .w = cmd.ClipRect.w * sy - py0 };
        }
        // A textura vai mudar: o quadro precisa ir para a tela (o callback só roda lá).
        changed = true;
        l.armed = true;
        l.pend_key = key;
        const ox = px0 / sx;
        const oy = py0 / sy;
        l.pend_img = .{ .p0 = d.v(ox, oy), .p1 = d.v(ox + w / sx, oy + h / sy), .uv1 = d.v(w / l.tex_w, h / l.tex_h) };
        c.ImDrawList_AddCallbackEx(dl, &render, l, 0);
        image(l, dl, l.pend_img, alpha);
    }
};

/// Onde a imagem da textura vai na tela, e até onde da textura ela pega.
const Img = struct {
    p0: c.ImVec2 = .{ .x = 0, .y = 0 },
    p1: c.ImVec2 = .{ .x = 0, .y = 0 },
    uv1: c.ImVec2 = .{ .x = 0, .y = 0 },
};

fn image(l: *Layer, dl: *c.ImDrawList, im: Img, alpha: f32) void {
    const a8: u32 = @intFromFloat(std.math.clamp(alpha, 0, 1) * 255 + 0.5);
    c.ImDrawList_AddImageEx(dl, fx.refOf(l.tex.?), im.p0, im.p1, d.v(0, 0), im.uv1, a8 | a8 << 8 | a8 << 16 | a8 << 24);
}

fn cmdSlice(list: *c.ImDrawList) []c.ImDrawCmd {
    return list.CmdBuffer.Data[0..@intCast(list.CmdBuffer.Size)];
}

/// As camadas que já pediram textura (soltas em `shutdown`).
var live: [8]*Layer = undefined;
var n_live: usize = 0;

/// Uma camada mudou de desenho neste quadro: o app não pode pular o quadro (o resumo
/// do ImGui não vê o que vai para a textura).
var changed = false;

pub fn takeChanged() bool {
    defer changed = false;
    return changed;
}

/// A textura cabe `w` × `h` pixels (cresce em passos de 64, e nunca diminui).
fn ensureTexture(l: *Layer, w: f32, h: f32) bool {
    if (l.tex != null and l.tex_w >= w and l.tex_h >= h) return true;
    const r = l.renderer orelse return false;
    const nw = @max(l.tex_w, @ceil(w / 64) * 64);
    const nh = @max(l.tex_h, @ceil(h / 64) * 64);
    dropTexture(l);
    // ARGB8888 é o formato de alvo que todo renderer do SDL aceita; RGBA32 de reserva.
    const tex = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ARGB8888, c.SDL_TEXTUREACCESS_TARGET, @intFromFloat(nw), @intFromFloat(nh)) orelse
        c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_TARGET, @intFromFloat(nw), @intFromFloat(nh)) orelse return false;
    // O que vai para a textura já sai pré-multiplicado (desenhado com alpha sobre o
    // transparente); sem esse modo, as bordas escureceriam.
    if (!c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND_PREMULTIPLIED)) {
        c.SDL_DestroyTexture(tex);
        return false;
    }
    l.tex = tex;
    l.tex_w = nw;
    l.tex_h = nh;
    return true;
}

fn dropTexture(l: *Layer) void {
    if (l.tex) |t| c.SDL_DestroyTexture(t);
    l.tex = null;
    l.tex_w = 0;
    l.tex_h = 0;
    l.valid = false;
}

/// Na hora de desenhar (dentro de ImGui_ImplSDLRenderer3_RenderDrawData): a lista da
/// camada vai para a textura dela; o comando seguinte de `dl` é a imagem da textura.
fn render(parent: [*c]const c.ImDrawList, cmd: [*c]const c.ImDrawCmd) callconv(.c) void {
    _ = parent;
    const l: *Layer = @ptrCast(@alignCast(cmd.*.UserCallbackData orelse return));
    if (!l.armed) return;
    const r = l.renderer orelse return;
    const tex = l.tex orelse return;
    const prev = c.SDL_GetRenderTarget(r);
    if (!c.SDL_SetRenderTarget(r, tex)) return;
    defer _ = c.SDL_SetRenderTarget(r, prev);
    // A partir daqui a textura tem o desenho deste quadro (até o próximo `end`).
    l.armed = false;
    l.key = l.pend_key;
    l.img = l.pend_img;
    l.valid = true;
    var dc: [4]f32 = .{ 0, 0, 0, 0 };
    _ = c.SDL_GetRenderDrawColorFloat(r, &dc[0], &dc[1], &dc[2], &dc[3]);
    _ = c.SDL_SetRenderDrawColorFloat(r, 0, 0, 0, 0);
    _ = c.SDL_RenderClear(r);
    _ = c.SDL_SetRenderDrawColorFloat(r, dc[0], dc[1], dc[2], dc[3]);
    // As coordenadas já estão em pixels da textura.
    _ = c.SDL_SetRenderScale(r, 1, 1);
    _ = c.SDL_SetRenderViewport(r, null);
    const list = &l.list;
    const nv: usize = @intCast(list.VtxBuffer.Size);
    const stride: c_int = @sizeOf(c.ImDrawVert);
    for (cmdSlice(list)) |*q| {
        if (q.UserCallback != null or q.ElemCount == 0 or q.VtxOffset >= nv) continue;
        const x0 = @max(@floor(q.ClipRect.x), 0);
        const y0 = @max(@floor(q.ClipRect.y), 0);
        const x1 = @min(@ceil(q.ClipRect.z), l.tex_w);
        const y1 = @min(@ceil(q.ClipRect.w), l.tex_h);
        if (x1 <= x0 or y1 <= y0) continue;
        const clip: c.SDL_Rect = .{ .x = @intFromFloat(x0), .y = @intFromFloat(y0), .w = @intFromFloat(x1 - x0), .h = @intFromFloat(y1 - y0) };
        _ = c.SDL_SetRenderClipRect(r, &clip);
        const atlas: ?*c.SDL_Texture = @ptrFromInt(@as(usize, @intCast(c.ImDrawCmd_GetTexID(q))));
        const first = &list.VtxBuffer.Data[q.VtxOffset];
        _ = c.SDL_RenderGeometryRaw(
            r,
            atlas,
            @ptrCast(&first.pos),
            stride,
            l.colors.items.ptr + q.VtxOffset,
            @sizeOf(c.SDL_FColor),
            @ptrCast(&first.uv),
            stride,
            @intCast(nv - q.VtxOffset),
            list.IdxBuffer.Data + q.IdxOffset,
            @intCast(q.ElemCount),
            @sizeOf(c.ImDrawIdx),
        );
    }
    _ = c.SDL_SetRenderClipRect(r, null);
}

/// Sem textura: as peças vão para `dl` com o alpha em cada uma (o jeito de antes).
fn replay(l: *Layer, dl: *c.ImDrawList, alpha: f32) void {
    const list = &l.list;
    for (cmdSlice(list)) |*q| {
        if (q.UserCallback != null or q.ElemCount == 0) continue;
        const idx = list.IdxBuffer.Data[q.IdxOffset .. q.IdxOffset + q.ElemCount];
        var lo: u32 = std.math.maxInt(u32);
        var hi: u32 = 0;
        for (idx) |i| {
            lo = @min(lo, i);
            hi = @max(hi, i);
        }
        const n = hi - lo + 1;
        if (n >= 1 << 16) continue;
        c.ImDrawList_PrimReserve(dl, @intCast(idx.len), @intCast(n));
        const at = dl.*._VtxCurrentIdx;
        for (list.VtxBuffer.Data[q.VtxOffset + lo .. q.VtxOffset + hi + 1]) |vt| {
            const a: u32 = @intFromFloat(@as(f32, @floatFromInt(vt.col >> 24)) * std.math.clamp(alpha, 0, 1) + 0.5);
            c.ImDrawList_PrimWriteVtx(dl, vt.pos, vt.uv, (vt.col & 0x00FF_FFFF) | a << 24);
        }
        for (idx) |i| c.ImDrawList_PrimWriteIdx(dl, @intCast(at + i - lo));
    }
}

/// O SDL avisou que o conteúdo dos alvos se perdeu (SDL_EVENT_RENDER_TARGETS_RESET,
/// SDL_EVENT_RENDER_DEVICE_RESET): as texturas ficam, mas o desenho é refeito.
pub fn invalidate() void {
    for (live[0..n_live]) |l| l.valid = false;
}

/// O renderizador vai embora (a janela na bandeja, App.releaseGpu): as texturas das
/// camadas saem e são refeitas no renderizador novo no próximo `begin`.
pub fn dropTextures() void {
    for (live[0..n_live]) |l| {
        dropTexture(l);
        l.renderer = null;
        l.armed = false;
    }
}

/// Solta as texturas e a memória das camadas (antes do renderer e do ImGui irem embora).
pub fn shutdown() void {
    for (live[0..n_live]) |l| {
        dropTexture(l);
        l.colors.deinit(ca);
        l.colors = .empty;
        c.ImDrawList__ClearFreeMemory(&l.list);
        l.list = std.mem.zeroes(c.ImDrawList);
        l.listed = false;
        l.armed = false;
        l.renderer = null;
    }
    n_live = 0;
}
