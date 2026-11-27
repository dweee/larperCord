//! Um desenho que não mudou não precisa ser refeito: o carimbo guarda os vértices dele
//! (o mascote do canto parado, com o corpo cheio de curvas e o preenchimento côncavo do
//! ImGui, caro) e, no quadro seguinte com o mesmo resumo, só copia os vértices de novo
//! para a lista da tela. Os vértices e a ordem dos triângulos são os mesmos de desenhar
//! na hora: o quadro sai igual pixel a pixel, em qualquer renderizador, e não há nada
//! da GPU para refazer quando o renderizador vai embora (a janela na bandeja).
//!
//! Quem desenha calcula o resumo de tudo o que o desenho lê (`feed`, mais o estado da
//! lista em `listKey`) e chama `again`; se não deu, desenha na lista de `begin` e fecha
//! com `end`, que põe o desenho na lista da tela e o guarda com o resumo.
const std = @import("std");
const c = @import("c");

pub const Carimbo = struct {
    /// A lista em que o desenho é feito (a memória fica de um quadro para o outro).
    list: c.ImDrawList = std.mem.zeroes(c.ImDrawList),
    /// O resumo do desenho guardado; `valid` falso: nada guardado.
    key: u64 = 0,
    valid: bool = false,
    listed: bool = false,
    /// Quantas vezes o desenho guardado foi repetido (o QA confere que ele é usado).
    hits: u64 = 0,

    /// O desenho guardado com `key` vai de novo para `dl`. Falso: não há um com esse
    /// resumo, desenhe (`begin`).
    pub fn again(cb: *Carimbo, dl: *c.ImDrawList, key: u64) bool {
        if (!cb.valid or cb.key != key) return false;
        copy(&cb.list, dl);
        cb.hits +%= 1;
        return true;
    }

    /// A lista em que desenhar, com o estado de `dl` (as mesmas opções, a mesma
    /// densidade de pixel, o mesmo corte e a mesma textura). Null: desenhe direto.
    pub fn begin(cb: *Carimbo, dl: *c.ImDrawList) ?*c.ImDrawList {
        if (dl.*._Data == null) return null;
        if (!cb.listed) {
            if (n_live == live.len) return null;
            live[n_live] = cb;
            n_live += 1;
            cb.listed = true;
        }
        cb.valid = false;
        cb.list._Data = dl.*._Data;
        c.ImDrawList__ResetForNewFrame(&cb.list);
        cb.list.Flags = dl.*.Flags;
        cb.list._FringeScale = dl.*._FringeScale;
        cb.list._InvFringeScale = dl.*._InvFringeScale;
        cb.list._FringeScaleIsInteger = dl.*._FringeScaleIsInteger;
        c.ImDrawList_PushClipRect(&cb.list, c.ImDrawList_GetClipRectMin(dl), c.ImDrawList_GetClipRectMax(dl), false);
        c.ImDrawList_PushTexture(&cb.list, dl.*._CmdHeader.TexRef);
        return &cb.list;
    }

    /// Fecha: o desenho vai para `dl` e fica guardado com `key`.
    pub fn end(cb: *Carimbo, dl: *c.ImDrawList, key: u64) void {
        copy(&cb.list, dl);
        cb.key = key;
        cb.valid = true;
    }

    /// Esquece o desenho guardado (o próximo `again` não acha nada).
    pub fn forget(cb: *Carimbo) void {
        cb.valid = false;
    }
};

/// Os carimbos que já desenharam (a memória sai em `shutdown`).
var live: [4]*Carimbo = undefined;
var n_live: usize = 0;

/// Os vértices e índices de `src` no fim de `dl`, como se desenhados ali agora: cada
/// comando com o corte e a textura dele (o desenho do mascote só tem um, o de `dl`).
fn copy(src: *c.ImDrawList, dl: *c.ImDrawList) void {
    const cmds = src.CmdBuffer.Data[0..@intCast(src.CmdBuffer.Size)];
    const vtx = src.VtxBuffer.Data;
    const idx = src.IdxBuffer.Data;
    for (cmds) |*q| {
        if (q.UserCallback != null or q.ElemCount == 0) continue;
        const own = idx[q.IdxOffset .. q.IdxOffset + q.ElemCount];
        var lo: u32 = std.math.maxInt(u32);
        var hi: u32 = 0;
        for (own) |i| {
            lo = @min(lo, i);
            hi = @max(hi, i);
        }
        const n: u32 = hi - lo + 1;
        // Outro corte ou outra textura que a de agora em `dl`: só para este comando.
        const here = &dl.*._CmdHeader;
        const clip_other = !std.mem.eql(u8, std.mem.asBytes(&q.ClipRect), std.mem.asBytes(&here.ClipRect));
        const tex_other = q.TexRef._TexData != here.TexRef._TexData or q.TexRef._TexID != here.TexRef._TexID;
        if (clip_other) c.ImDrawList_PushClipRect(dl, .{ .x = q.ClipRect.x, .y = q.ClipRect.y }, .{ .x = q.ClipRect.z, .y = q.ClipRect.w }, false);
        if (tex_other) c.ImDrawList_PushTexture(dl, q.TexRef);
        c.ImDrawList_PrimReserve(dl, @intCast(own.len), @intCast(n));
        const base = dl.*._VtxCurrentIdx;
        @memcpy(dl.*._VtxWritePtr[0..n], vtx[q.VtxOffset + lo .. q.VtxOffset + lo + n]);
        for (own, dl.*._IdxWritePtr[0..own.len]) |i, *o| o.* = @intCast(base + i - lo);
        dl.*._VtxWritePtr += n;
        dl.*._IdxWritePtr += own.len;
        dl.*._VtxCurrentIdx += n;
        if (tex_other) c.ImDrawList_PopTexture(dl);
        if (clip_other) c.ImDrawList_PopClipRect(dl);
    }
}

/// Solta a memória dos carimbos (antes do ImGui ir embora).
pub fn shutdown() void {
    for (live[0..n_live]) |cb| {
        c.ImDrawList__ClearFreeMemory(&cb.list);
        cb.list = std.mem.zeroes(c.ImDrawList);
        cb.listed = false;
        cb.valid = false;
    }
    n_live = 0;
}

// --- O resumo -----------------------------------------------------------------------

/// Põe `v` no resumo campo a campo (os bytes de enchimento das structs ficam de fora:
/// eles mudam de um quadro para o outro e o resumo nunca bateria). Ponteiros não
/// entram: quem tem um diz o que conta do que ele aponta.
pub fn feed(h: *std.hash.Wyhash, v: anytype) void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .void => {},
        .bool => h.update(&[_]u8{@intFromBool(v)}),
        .int => |i| {
            if (i.bits > 64) @compileError("carimbo.feed: " ++ @typeName(T));
            const w: u64 = if (i.signedness == .signed) @bitCast(@as(i64, v)) else @as(u64, v);
            h.update(std.mem.asBytes(&w));
        },
        .comptime_int => feed(h, @as(i64, v)),
        .float => |f| {
            const w: @Int(.unsigned, f.bits) = @bitCast(v);
            feed(h, w);
        },
        .@"enum" => feed(h, @intFromEnum(v)),
        .array => |a| if (a.child == u8) h.update(&v) else for (v) |x| feed(h, x),
        .@"struct" => |st| inline for (st.field_names) |name| feed(h, @field(v, name)),
        .optional => if (v) |x| {
            h.update(&[_]u8{1});
            feed(h, x);
        } else h.update(&[_]u8{0}),
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("carimbo.feed: " ++ @typeName(T));
            feed(h, std.meta.activeTag(v));
            switch (v) {
                inline else => |x| feed(h, x),
            }
        },
        else => @compileError("carimbo.feed: " ++ @typeName(T)),
    }
}

/// O que da lista `dl` muda os vértices desenhados nela: as opções (suavizar), a
/// densidade de pixel, o corte, a escala da tela (a da camada, em pixels), a textura e
/// onde o pixel branco e as linhas prontas estão no atlas das fontes (o atlas que cresce
/// ou se reorganiza é outra textura, com outro número).
pub fn listKey(h: *std.hash.Wyhash, dl: *const c.ImDrawList) void {
    feed(h, dl.Flags);
    feed(h, .{ dl._FringeScale, dl._InvFringeScale, dl._FringeScaleIsInteger });
    feed(h, dl._CmdHeader.ClipRect);
    feed(h, c.ImGui_GetIO().*.DisplayFramebufferScale);
    feed(h, .{ @intFromPtr(dl._CmdHeader.TexRef._TexData), dl._CmdHeader.TexRef._TexID });
    const atlas = c.ImGui_GetIO().*.Fonts;
    feed(h, .{ atlas.*.TexUvScale, atlas.*.TexUvWhitePixel, @intFromPtr(atlas.*.TexData) });
    if (atlas.*.TexData != null) feed(h, atlas.*.TexData.*.UniqueID);
}

test "carimbo: o resumo ignora o enchimento e vê cada campo" {
    const S = struct { a: u8, b: f32, c: ?u16, d: enum { x, y } };
    var one: S = undefined;
    var two: S = undefined;
    @memset(std.mem.asBytes(&one), 0xAA);
    @memset(std.mem.asBytes(&two), 0x55);
    one = .{ .a = 1, .b = 2.5, .c = null, .d = .y };
    two = .{ .a = 1, .b = 2.5, .c = null, .d = .y };
    var h1 = std.hash.Wyhash.init(0);
    var h2 = std.hash.Wyhash.init(0);
    feed(&h1, one);
    feed(&h2, two);
    try std.testing.expectEqual(h1.final(), h2.final());
    two.c = 0;
    var h3 = std.hash.Wyhash.init(0);
    feed(&h3, two);
    try std.testing.expect(h1.final() != h3.final());
    two.c = null;
    two.b = 2.5001;
    var h4 = std.hash.Wyhash.init(0);
    feed(&h4, two);
    try std.testing.expect(h1.final() != h4.final());
}
