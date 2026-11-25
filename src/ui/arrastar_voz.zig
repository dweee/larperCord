//! Arrastar alguém da call para outro canal de voz, como no Discord: segurar a pessoa na
//! lista de canais e soltar em cima de outro canal de voz move ela, com o mesmo pedido do
//! "Mover para…" do menu (só aparece para quem tem "Mover membros", popup.movable). Um
//! clique sem arrastar continua abrindo o perfil; Esc ou soltar fora de um canal cancela.
//!
//! A lista de canais (ui/comp_channels.zig) chama `beginList` antes das linhas, `press` na
//! linha de quem está na call, `channelTarget` em cada canal de voz e `endList` no fim.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const i18n = @import("i18n.zig");
const w = @import("widgets.zig");
const qa = @import("qa.zig");
const types = @import("../core/types.zig");
const Id = types.Id;

/// Quanto o mouse anda, segurando, até virar arraste (menos que isso é um clique).
const limiar: f32 = 6;

pub const Arraste = struct {
    user: Id,
    guild: Id,
    /// O canal de voz de onde a pessoa sai.
    from: Id,
    start: c.ImVec2,
    active: bool = false,
};

pub var arraste: ?Arraste = null;
/// O canal de voz válido sob o mouse neste quadro (as linhas da lista dizem).
var alvo: Id = 0;
var alvo_nome: [64]u8 = undefined;
var alvo_len: usize = 0;

/// Segurou alguém da call: o arraste começa se o mouse andar antes de soltar.
pub fn press(ctx: *d.Ctx, uid: Id, guild: Id, from: Id) void {
    arraste = .{ .user = uid, .guild = guild, .from = from, .start = ctx.mouse };
}

pub fn ativo() bool {
    return if (arraste) |a| a.active else false;
}

/// O clique que abriria o perfil não vale: a pessoa estava sendo arrastada.
pub fn engoleClique() bool {
    return ativo();
}

/// Antes das linhas: solto sem ter andado era um clique; andou o bastante, vira arraste.
pub fn beginList(ctx: *d.Ctx) void {
    alvo = 0;
    const a = if (arraste) |*x| x else return;
    if (!a.active and !c.ImGui_IsMouseDown(0)) {
        arraste = null;
        return;
    }
    if (!a.active) {
        const dx = ctx.mouse.x - a.start.x;
        const dy = ctx.mouse.y - a.start.y;
        if (dx * dx + dy * dy >= limiar * limiar) a.active = true;
    }
    if (a.active and c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) arraste = null;
}

/// Um canal de voz da lista: se dá para soltar a pessoa nele e o mouse está em cima (do
/// canal ou de quem já está nele), ele acende e vira o alvo. `block` é a linha do canal
/// com as de quem está nele.
pub fn channelTarget(ctx: *d.Ctx, dl: *c.ImDrawList, ch: *const types.Channel, block: d.Rect) void {
    const a = arraste orelse return;
    if (!a.active) return;
    if (ch.kind != .voice or ch.id == a.from or ch.guild != a.guild) return;
    // Um canal em que a gente nem entra também não recebe ninguém pela gente.
    if (!ctx.store.canAccess(ch)) return;
    qa.mark(block, "voice-drop:{d}", .{ch.id});
    const over = block.contains(ctx.mouse.x, ctx.mouse.y);
    // Os que podem receber ficam marcados de leve; o de baixo do mouse, forte.
    const accent = ctx.col(.accent);
    if (over) {
        d.rect(dl, block, accent.alpha(0.16), ctx.th.radius);
        d.border(dl, block, accent, ctx.th.radius, 2);
        alvo = ch.id;
        alvo_len = @min(ch.name.len, alvo_nome.len);
        @memcpy(alvo_nome[0..alvo_len], ch.name[0..alvo_len]);
    } else d.border(dl, block, accent.alpha(0.35), ctx.th.radius, 1);
}

/// Depois das linhas: soltou em cima de um canal, a pessoa vai para lá. Enquanto arrasta,
/// ela segue o mouse, com o nome do canal de destino.
pub fn endList(ctx: *d.Ctx) void {
    const a = arraste orelse return;
    if (!a.active) return;
    if (!c.ImGui_IsMouseDown(0)) {
        if (alvo != 0) ctx.act(.{ .move_member = .{ .guild = a.guild, .user = a.user, .channel = alvo } });
        arraste = null;
        return;
    }
    c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
    fantasma(ctx, a);
}

/// A pessoa sendo arrastada: a foto e o nome, e embaixo para onde ela vai.
fn fantasma(ctx: *d.Ctx, a: Arraste) void {
    const fg = ctx.fg;
    const font = ctx.ui.get(.semibold);
    const small = ctx.ui.get(.regular);
    const name = ctx.store.nameIn(a.guild, a.user) orelse if (ctx.store.user(a.user)) |u| u.name else "?";
    var hb: [128]u8 = undefined;
    const hint = if (alvo != 0)
        i18n.fmt(&hb, "Mover para {s}", "Move to {s}", .{alvo_nome[0..alvo_len]})
    else
        i18n.tr("Solte num canal de voz", "Drop on a voice channel");
    const tw = @max(d.width(font, 14, name), d.width(small, 12, hint));
    const r: d.Rect = .{ .x = ctx.mouse.x + 14, .y = ctx.mouse.y + 8, .w = tw + 58, .h = 44 };
    d.shadow(fg, r, 10, 10, ctx.col(.shadow).alpha(0.8));
    d.rect(fg, r, ctx.col(.elevated), 10);
    d.border(fg, r, if (alvo != 0) ctx.col(.accent) else ctx.col(.border), 10, 1);
    w.avatarIn(ctx, fg, a.guild, r.x + 22, r.y + r.h / 2, 28, a.user, .circle, null, 1);
    d.text(fg, font, 14, r.x + 44, r.y + 5, ctx.col(.text), name);
    d.text(fg, small, 12, r.x + 44, r.y + 24, if (alvo != 0) ctx.col(.accent) else ctx.col(.muted), hint);
    qa.markTop(r, "voice-drag", .{});
}
