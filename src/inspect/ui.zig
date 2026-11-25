//! O Inspetor: as ferramentas de desenvolvedor do larperCord (F12). Uma janela encaixada
//! à direita, embaixo ou solta, com as abas:
//!   Elementos   — clicar em qualquer coisa da tela e ver o que é: o pedaço do tema que
//!                 desenha (arquivo:linha), as cores com o nome no tema, o contraste do
//!                 texto, o id do ImGui, quanto o componente custou.
//!   Console     — os logs do app e uma linha de comandos (os mesmos do `larpercord ctl`).
//!   Rede        — cada pedido HTTP (API do Discord, imagens, plugins), com cabeçalhos,
//!                 corpo, resposta, tempos e o rate limit.
//!   Gateway     — cada quadro do gateway e do gateway de voz, aberto como árvore.
//!   Eventos     — o que a interface pediu ao app, o que o app pediu à rede e o que chegou.
//!   Desempenho  — o tempo de cada quadro, o custo de cada componente, memória e CPU.
//!   Estado      — a sessão, a conversa aberta, as cores do tema e os caches.
//! Fechado e nunca aberto, não custa nada: nem memória (as listas nascem na primeira
//! gravação), nem tempo (cada ponto de gravação lê um booleano).
const std = @import("std");
const c = @import("c");
const d = @import("../ui/draw.zig");
const i18n = @import("../ui/i18n.zig");
const kit = @import("kit.zig");
const qa = @import("../ui/qa.zig");
const doca = @import("doca.zig");
const cap = @import("captura.zig");
const reg = @import("registros.zig");
const App = @import("../app.zig").App;

pub const Aba = enum { elementos, console, rede, gateway, eventos, desempenho, estado };

pub var aba: Aba = .elementos;
/// Escolhendo um elemento na tela (o clique vai para o Inspetor, não para o app).
pub var picking = false;
/// Grava a rede, os logs e os eventos mesmo com o Inspetor fechado.
pub var gravar_fechado = false;
/// Quadros que alguém de fora (o ctl) pediu gravados, com o Inspetor fechado ou não.
pub var quadros_pedidos: u32 = 0;
pub var app_ptr: ?*App = null;

/// O elemento escolhido. Os quadros mudam: ele é reencontrado em cada um pelo que não
/// muda (o id do ImGui, ou o tipo, o texto e o pedaço do layout, com a posição perto).
pub const Sel = struct {
    on: bool = false,
    kind: cap.Kind = .item,
    id: u32 = 0,
    hash: u64 = 0,
    scope_name: [48]u8 = @splat(0),
    scope_len: u8 = 0,
    rect: cap.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Um pedaço do layout inteiro (a linha da árvore), no lugar de um elemento.
    scope_only: bool = false,
    scope_line: u32 = 0,
    /// Onde está no último quadro (null = sumiu da tela).
    index: ?usize = null,
    scope_index: ?usize = null,
    /// Pedido de rolar a árvore até ele.
    reveal: bool = false,
};

pub var sel: Sel = .{};
/// O que está sob o mouse (na tela, escolhendo, ou numa linha da árvore).
pub var hover_el: ?usize = null;
pub var hover_scope: ?usize = null;

pub fn aberto() bool {
    return doca.aberto;
}

pub fn open() void {
    if (!doca.aberto) {
        doca.aberto = true;
        reg.gravar(true);
    }
}

pub fn close() void {
    doca.aberto = false;
    picking = false;
    if (!gravar_fechado) reg.gravar(false);
}

pub fn toggle() void {
    if (doca.aberto) close() else open();
}

pub fn startPick() void {
    open();
    aba = .elementos;
    picking = !picking;
}

/// Grava os elementos neste quadro? Só com a aba Elementos à vista, escolhendo, ou a
/// pedido do ctl (gravar custa: cada texto é medido e guardado).
pub fn wantsCapture() bool {
    if (quadros_pedidos > 0) return true;
    return doca.aberto and (aba == .elementos or picking or aba == .desempenho);
}

var seen_revs: [4]u32 = @splat(0);

/// Algo novo na lista da aba à vista (um pedido, um quadro, uma linha de log): o laço
/// redesenha no ritmo das coisas da rede, sem acordar à toa com o Inspetor fechado.
pub fn listsChanged() bool {
    if (!doca.aberto) return false;
    const now = [4]u32{ reg.net.rev.load(.monotonic), reg.gw.rev.load(.monotonic), reg.lines.rev.load(.monotonic), reg.evs.rev.load(.monotonic) };
    const which: ?usize = switch (aba) {
        .rede => 0,
        .gateway => 1,
        .console => 2,
        .eventos => 3,
        else => null,
    };
    // O número de erros e avisos na aba do Console e da Rede também muda com elas fechadas.
    const changed = (if (which) |k| now[k] != seen_revs[k] else false) or now[0] != seen_revs[0] or now[2] != seen_revs[2];
    seen_revs = now;
    return changed;
}

/// Antes de o ImGui ver o evento: escolhendo, o clique escolhe (e não chega ao app).
pub fn takeEvent(e: *const c.SDL_Event) bool {
    if (!picking) return false;
    switch (e.type) {
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            // Clique dentro do próprio Inspetor: segue para ele (trocar de aba, parar).
            if (overInspector(e.button.x, e.button.y)) return false;
            if (e.button.button == c.SDL_BUTTON_LEFT) pickNow();
            if (e.button.button == c.SDL_BUTTON_RIGHT) picking = false;
            return true;
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => return !overInspector(e.button.x, e.button.y),
        c.SDL_EVENT_KEY_DOWN => if (e.key.key == c.SDLK_ESCAPE) {
            picking = false;
            return true;
        },
        else => {},
    }
    return false;
}

/// O mesmo para o clique de um robô (o do QA, o dos comandos), que vai direto ao ImGui
/// sem passar pelos eventos do SDL. Devolve se o Inspetor ficou com ele.
var robot_swallow = false;
pub fn robotPress(button: c_int) bool {
    if (!picking) return false;
    const app = app_ptr orelse return false;
    const m = app.io.*.MousePos;
    if (doca.aberto and doca.area.contains(m.x, m.y)) return false;
    if (button == 0) pickNow() else picking = false;
    robot_swallow = true;
    return true;
}

pub fn robotRelease() bool {
    defer robot_swallow = false;
    return robot_swallow;
}

fn overInspector(x_px: f32, y_px: f32) bool {
    const app = app_ptr orelse return false;
    const s = app.uiScale();
    return doca.aberto and doca.area.contains(x_px / s, y_px / s);
}

/// O elemento sob o mouse vira o escolhido.
fn pickNow() void {
    const f = cap.last() orelse return;
    const i = hover_el orelse return;
    select(f, i);
    picking = false;
}

pub fn select(f: *const cap.Frame, i: usize) void {
    const e = &f.els.items[i];
    sel = .{ .on = true, .kind = e.kind, .id = e.id, .hash = std.hash.Wyhash.hash(0, f.str(e.str)), .rect = e.rect, .index = i, .reveal = true };
    if (f.scopeOf(e)) |s| setScopeName(s.name);
}

pub fn selectScope(f: *const cap.Frame, si: usize) void {
    const s = &f.scopes.items[si];
    sel = .{ .on = true, .scope_only = true, .rect = s.rect, .scope_line = s.line, .scope_index = si, .reveal = true };
    setScopeName(s.name);
}

fn setScopeName(name: []const u8) void {
    const n = @min(name.len, sel.scope_name.len);
    @memcpy(sel.scope_name[0..n], name[0..n]);
    sel.scope_len = @intCast(n);
}

pub fn selScopeName() []const u8 {
    return sel.scope_name[0..sel.scope_len];
}

/// Reencontra o escolhido no quadro novo.
fn resolve(f: *const cap.Frame) void {
    if (!sel.on) return;
    if (sel.scope_only) {
        sel.scope_index = null;
        for (f.scopes.items, 0..) |*s, i| if (s.line == sel.scope_line and std.mem.eql(u8, s.name, selScopeName())) {
            sel.scope_index = i;
            sel.rect = s.rect;
            break;
        };
        return;
    }
    var best: ?usize = null;
    var best_d: f32 = std.math.floatMax(f32);
    for (f.els.items, 0..) |*e, i| {
        if (e.kind != sel.kind) continue;
        if (sel.id != 0) {
            if (e.id != sel.id) continue;
        } else {
            if (std.hash.Wyhash.hash(0, f.str(e.str)) != sel.hash) continue;
            const sn = if (f.scopeOf(e)) |s| s.name else "";
            if (!std.mem.eql(u8, sn, selScopeName())) continue;
        }
        const dd = @abs(e.rect.x - sel.rect.x) + @abs(e.rect.y - sel.rect.y);
        if (dd < best_d) {
            best_d = dd;
            best = i;
        }
    }
    sel.index = best;
    if (best) |i| sel.rect = f.els.items[i].rect;
}

// --- Por quadro ------------------------------------------------------------------

/// Depois do layout e das sobreposições do app, no mesmo quadro: a janela do Inspetor
/// e o destaque na tela.
pub fn frame(ctx: *d.Ctx, app: *App) void {
    app_ptr = app;
    if (quadros_pedidos > 0) quadros_pedidos -= 1;
    const f = cap.last();
    if (f) |fr| resolve(fr);
    hover_el = null;
    hover_scope = null;
    if (picking) if (f) |fr| {
        if (!doca.area.contains(ctx.mouse.x, ctx.mouse.y) or !doca.aberto) hover_el = cap.pick(fr, ctx.mouse.x, ctx.mouse.y);
    };
    if (!doca.aberto) return;
    cap.pause();
    defer cap.unpause();
    kit.setTheme(ctx.th.mode == .light, ctx.th.c(.accent));
    window(ctx, app);
    if (f) |fr| highlight(ctx, fr);
}

fn window(ctx: *d.Ctx, app: *App) void {
    const r = doca.area;
    c.ImGui_SetNextWindowPos(d.v(r.x, r.y), 0);
    c.ImGui_SetNextWindowSize(d.v(r.w, r.h), 0);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, d.v(0, 0));
    c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowBorderSize, 0);
    c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowRounding, if (doca.lado == .solta) 8 else 0);
    const flags = c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoSavedSettings |
        c.ImGuiWindowFlags_NoScrollWithMouse | c.ImGuiWindowFlags_NoBackground;
    _ = c.ImGui_Begin("##inspetor", null, flags);
    c.ImGui_PopStyleVarEx(3);
    // Por cima do app (as Configurações e os popups também são janelas).
    d.windowToFront();
    var u: kit.Ui = .{
        .ctx = ctx,
        .dl = c.ImGui_GetWindowDrawList(),
        .font = ctx.ui.get(.regular),
        .bold = ctx.ui.get(.semibold),
        .mono = ctx.mono.get(.regular),
        .mono_bold = ctx.mono.get(.bold),
    };
    if (doca.lado == .solta) d.shadow(c.ImGui_GetBackgroundDrawList(), r, 8, 18, kit.Rgba.black.alpha(0.35));
    kit.rect(&u, r, kit.pal.bg, if (doca.lado == .solta) 8 else 0);
    // A borda que separa do app (e arrasta para mudar o tamanho).
    edge(&u, r);
    const head_h: f32 = 34;
    header(&u, .{ .x = r.x, .y = r.y, .w = r.w, .h = head_h });
    const body: kit.Rect = .{ .x = r.x, .y = r.y + head_h, .w = r.w, .h = r.h - head_h - 22 };
    switch (aba) {
        .elementos => @import("aba_elementos.zig").draw(&u, app, body),
        .console => @import("aba_console.zig").draw(&u, app, body),
        .rede => @import("aba_rede.zig").draw(&u, app, body),
        .gateway => @import("aba_gateway.zig").draw(&u, app, body),
        .eventos => @import("aba_eventos.zig").draw(&u, app, body),
        .desempenho => @import("aba_desempenho.zig").draw(&u, app, body),
        .estado => @import("aba_estado.zig").draw(&u, app, body),
    }
    statusBar(&u, .{ .x = r.x, .y = r.bottom() - 22, .w = r.w, .h = 22 });
    if (doca.lado == .solta) d.border(u.dl, r, kit.pal.line, 8, 1);
    // Copiado: um aviso curto no canto.
    const since = @as(i64, @intCast(c.SDL_GetTicks())) - kit.copied_at_ms;
    if (kit.copied_at_ms != 0 and since < 1200) {
        const msg = i18n.tr("Copiado", "Copied");
        const w = u.textW(msg) + 20;
        const cr: kit.Rect = .{ .x = r.right() - w - 10, .y = r.bottom() - 52, .w = w, .h = 24 };
        kit.rect(&u, cr, kit.pal.accent, 12);
        _ = u.text(cr.x + 10, u.mid(cr.y, cr.h), kit.pal.bg, msg);
        @import("../ui/anim.zig").at(kit.copied_at_ms + 1250);
    }
    c.ImGui_End();
}

/// A beirada do Inspetor encaixado: arrastar muda a largura (ou a altura). Solto, a barra
/// de cima move a janela e o canto de baixo muda o tamanho.
fn edge(u: *kit.Ui, r: kit.Rect) void {
    const m = u.ctx.mouse;
    switch (doca.lado) {
        .direita, .baixo => {
            const vertical = doca.lado == .direita;
            const hr: kit.Rect = if (vertical) .{ .x = r.x - 3, .y = r.y, .w = 7, .h = r.h } else .{ .x = r.x, .y = r.y - 3, .w = r.w, .h = 7 };
            c.ImGui_SetCursorScreenPos(d.v(hr.x, hr.y));
            _ = c.ImGui_InvisibleButton("##insp-edge", d.v(hr.w, hr.h), 0);
            const active = c.ImGui_IsItemActive();
            if (active or c.ImGui_IsItemHovered(0)) c.ImGui_SetMouseCursor(if (vertical) c.ImGuiMouseCursor_ResizeEW else c.ImGuiMouseCursor_ResizeNS);
            if (active) {
                if (vertical) doca.largura = r.right() - m.x else doca.altura = r.bottom() - m.y;
            }
            if (vertical) kit.vline(u, r.x, r.y, r.bottom(), if (active) kit.pal.accent else kit.pal.line) else kit.hline(u, r.x, r.right(), r.y, if (active) kit.pal.accent else kit.pal.line);
        },
        .solta => {
            const grip: kit.Rect = .{ .x = r.right() - 14, .y = r.bottom() - 14, .w = 14, .h = 14 };
            c.ImGui_SetCursorScreenPos(d.v(grip.x, grip.y));
            _ = c.ImGui_InvisibleButton("##insp-grip", d.v(grip.w, grip.h), 0);
            if (c.ImGui_IsItemActive()) {
                const dlt = u.ctx.io.*.MouseDelta;
                doca.solta.w += dlt.x;
                doca.solta.h += dlt.y;
            }
            if (c.ImGui_IsItemHovered(0) or c.ImGui_IsItemActive()) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_ResizeNWSE);
            d.line(u.dl, grip.x + 4, grip.bottom() - 2, grip.right() - 2, grip.y + 4, kit.pal.faint, 1.2);
            d.line(u.dl, grip.x + 8, grip.bottom() - 2, grip.right() - 2, grip.y + 8, kit.pal.faint, 1.2);
        },
    }
}

fn header(u: *kit.Ui, r: kit.Rect) void {
    kit.rect(u, r, kit.pal.toolbar, 0);
    kit.hline(u, r.x, r.right(), r.bottom() - 1, kit.pal.line);
    // Solto: arrastar a barra move a janela (fora dos botões).
    if (doca.lado == .solta) {
        c.ImGui_SetCursorScreenPos(d.v(r.x, r.y));
        c.ImGui_SetNextItemAllowOverlap();
        _ = c.ImGui_InvisibleButton("##insp-move", d.v(r.w, r.h), 0);
        if (c.ImGui_IsItemActive()) {
            const dlt = u.ctx.io.*.MouseDelta;
            doca.solta.x += dlt.x;
            doca.solta.y += dlt.y;
        }
    }
    var x = r.x + 4;
    const bh = r.h - 4;
    var tb: [96]u8 = undefined;
    const pick_tip = i18n.fmt(&tb, "Selecionar um elemento na tela ({s})", "Select an element on screen ({s})", .{"Ctrl+Shift+E"});
    qa.mark(.{ .x = x, .y = r.y + 2, .w = bh, .h = bh }, "insp-pick", .{});
    if (kit.toolButton(u, .{ .x = x, .y = r.y + 2, .w = bh, .h = bh }, .pick, picking, pick_tip)) {
        picking = !picking;
        aba = .elementos;
    }
    x += bh + 4;
    kit.vline(u, x, r.y + 8, r.bottom() - 8, kit.pal.line);
    x += 6;
    // As abas (as que não cabem viram uma lista no botão "»").
    const right_w: f32 = bh * 4 + 16;
    const tabs = [_]struct { a: Aba, pt: []const u8, en: []const u8 }{
        .{ .a = .elementos, .pt = "Elementos", .en = "Elements" },
        .{ .a = .console, .pt = "Console", .en = "Console" },
        .{ .a = .rede, .pt = "Rede", .en = "Network" },
        .{ .a = .gateway, .pt = "Gateway", .en = "Gateway" },
        .{ .a = .eventos, .pt = "Eventos", .en = "Events" },
        .{ .a = .desempenho, .pt = "Desempenho", .en = "Performance" },
        .{ .a = .estado, .pt = "Estado", .en = "State" },
    };
    var hidden: [tabs.len]usize = undefined;
    var n_hidden: usize = 0;
    for (tabs, 0..) |tab, i| {
        const label = i18n.tr(tab.pt, tab.en);
        const badge = badgeOf(tab.a);
        const bw: f32 = if (badge.n > 0) d.width(u.font, u.fs - 2, badge.text()) + 12 else 0;
        const w = u.textW(label) + 16 + bw;
        if (x + w > r.right() - right_w - 24) {
            hidden[n_hidden] = i;
            n_hidden += 1;
            continue;
        }
        const tr: kit.Rect = .{ .x = x, .y = r.y, .w = w, .h = r.h - 1 };
        qa.mark(tr, "insp-tab:{s}", .{@tagName(tab.a)});
        const on = aba == tab.a;
        const over = u.over(tr);
        if (over and !on) kit.rect(u, tr, kit.pal.hover, 0);
        _ = u.text(x + 8, u.mid(r.y, r.h), if (on) kit.pal.text else if (over) kit.pal.text else kit.pal.dim, label);
        if (badge.n > 0) {
            const bx = x + 8 + u.textW(label) + 5;
            const br: kit.Rect = .{ .x = bx, .y = r.y + (r.h - 15) / 2, .w = bw - 2, .h = 15 };
            kit.rect(u, br, badge.col.alpha(0.22), 7.5);
            d.text(u.dl, u.font, u.fs - 2, bx + 5, br.y + (15 - (u.fs - 2) * 1.2) / 2, badge.col, badge.text());
        }
        if (on) kit.rect(u, .{ .x = x + 4, .y = r.bottom() - 3, .w = w - 8, .h = 2 }, kit.pal.accent, 1);
        if (over) {
            c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
            if (c.ImGui_IsMouseClicked(0)) aba = tab.a;
        }
        x += w;
    }
    if (n_hidden > 0) {
        const mr: kit.Rect = .{ .x = x, .y = r.y + 2, .w = 24, .h = bh };
        qa.mark(mr, "insp-tabs-more", .{});
        const over = u.over(mr);
        _ = u.text(mr.x + 6, u.mid(r.y, r.h), if (over) kit.pal.text else kit.pal.dim, "»");
        if (over and c.ImGui_IsMouseClicked(0)) _ = c.ImGui_OpenPopup("##insp-mais", 0);
        if (c.ImGui_BeginPopup("##insp-mais", 0)) {
            c.ImGui_PushFontFloat(u.font, u.fs);
            for (hidden[0..n_hidden]) |i| {
                var lb: [64]u8 = undefined;
                const z = kit.bufSayZ(&lb, "{s}", &.{ kit.arg(i18n.tr(tabs[i].pt, tabs[i].en)) }) orelse continue;
                if (c.ImGui_MenuItem(z.ptr)) aba = tabs[i].a;
            }
            c.ImGui_PopFont();
            c.ImGui_EndPopup();
        }
    }
    // Direita: onde encaixar e fechar.
    var rx = r.right() - 4 - bh;
    qa.mark(.{ .x = rx, .y = r.y + 2, .w = bh, .h = bh }, "insp-close", .{});
    if (kit.toolButton(u, .{ .x = rx, .y = r.y + 2, .w = bh, .h = bh }, .close, false, i18n.tr("Fechar o Inspetor (F12)", "Close the Inspector (F12)"))) close();
    rx -= bh + 6;
    kit.vline(u, rx + bh + 3, r.y + 8, r.bottom() - 8, kit.pal.line);
    const docks = [_]struct { l: doca.Lado, ic: kit.Icon, pt: []const u8, en: []const u8 }{
        .{ .l = .solta, .ic = .dock_float, .pt = "Janela solta", .en = "Floating" },
        .{ .l = .baixo, .ic = .dock_bottom, .pt = "Encaixar embaixo", .en = "Dock to bottom" },
        .{ .l = .direita, .ic = .dock_right, .pt = "Encaixar à direita", .en = "Dock to right" },
    };
    for (docks) |dk| {
        qa.mark(.{ .x = rx, .y = r.y + 2, .w = bh, .h = bh }, "insp-dock:{s}", .{@tagName(dk.l)});
        if (kit.toolButton(u, .{ .x = rx, .y = r.y + 2, .w = bh, .h = bh }, dk.ic, doca.lado == dk.l, i18n.tr(dk.pt, dk.en))) doca.lado = dk.l;
        rx -= bh;
    }
}

const Badge = struct {
    n: u32 = 0,
    col: kit.Rgba = undefined,
    buf: [12]u8 = undefined,
    len: usize = 0,
    fn text(b: *const Badge) []const u8 {
        return b.buf[0..b.len];
    }
};

/// O número ao lado da aba: erros e avisos no Console, pedidos que falharam na Rede.
fn badgeOf(a: Aba) Badge {
    var b: Badge = .{};
    switch (a) {
        .console => {
            const errs = reg.lines.counts[@intFromEnum(reg.Level.err)];
            const warns = reg.lines.counts[@intFromEnum(reg.Level.warn)];
            if (errs > 0) {
                b.n = errs;
                b.col = kit.pal.err;
            } else if (warns > 0) {
                b.n = warns;
                b.col = kit.pal.warn;
            }
        },
        .rede => {
            const n = @import("aba_rede.zig").failedCount();
            if (n > 0) {
                b.n = n;
                b.col = kit.pal.err;
            }
        },
        else => {},
    }
    if (b.n > 0) b.len = if (kit.bufSay(&b.buf, "{d}", &.{ kit.arg(b.n) })) |t| t.len else 0;
    return b;
}

fn statusBar(u: *kit.Ui, r: kit.Rect) void {
    kit.rect(u, r, kit.pal.toolbar, 0);
    kit.hline(u, r.x, r.right(), r.y, kit.pal.line);
    var x = r.x + 8;
    // Gravando: a bolinha vermelha (clique para ligar e desligar a gravação com ele fechado).
    const rec_on = reg.gravando();
    const dot: kit.Rect = .{ .x = x, .y = r.y + 3, .w = 16, .h = r.h - 6 };
    kit.icon(u.dl, .record, dot.x + 8, r.y + r.h / 2, if (rec_on) kit.pal.err else kit.pal.faint);
    if (u.over(dot)) {
        kit.tooltip(u, if (gravar_fechado) i18n.tr("Grava também com o Inspetor fechado (clique para só com ele aberto)", "Also records with the Inspector closed (click to record only while open)") else i18n.tr("Grava só com o Inspetor aberto (clique para gravar sempre)", "Records only while the Inspector is open (click to always record)"));
        if (c.ImGui_IsMouseClicked(0)) gravar_fechado = !gravar_fechado;
    }
    x += 20;
    var b: [160]u8 = undefined;
    const f = cap.last();
    const info = if (f) |fr|
        i18n.fmt(&b, "quadro {d} · {d} elementos · {d} pedaços do layout · montado em {d} µs", "frame {d} · {d} elements · {d} layout pieces · built in {d} µs", .{ fr.number, fr.els.items.len, fr.scopes.items.len -| 1, fr.build_us })
    else
        i18n.tr("abra a aba Elementos para gravar os quadros", "open the Elements tab to capture frames");
    _ = u.clip(x, u.mid(r.y, r.h), kit.pal.faint, info, r.w - 30);
}

// --- Destaque na tela -------------------------------------------------------------

fn highlight(ctx: *d.Ctx, f: *const cap.Frame) void {
    const fg = c.ImGui_GetForegroundDrawList();
    // O pedaço do layout sob o mouse na árvore (ou o escolhido inteiro).
    if (hover_scope) |si| if (si < f.scopes.items.len) {
        scopeBox(ctx, fg, f, si);
    };
    // O escolhido fica marcado na tela só na aba Elementos (nas outras, só o que passa sob o mouse).
    const show_sel = aba == .elementos;
    const target = hover_el orelse (if (show_sel and sel.on and !sel.scope_only and hover_scope == null) sel.index else null);
    if (target) |i| if (i < f.els.items.len) {
        elementBox(ctx, fg, f, i, hover_el != null);
    };
    if (show_sel and sel.on and sel.scope_only and hover_el == null and hover_scope == null) if (sel.scope_index) |si| {
        scopeBox(ctx, fg, f, si);
    };
}

fn scopeBox(ctx: *d.Ctx, fg: *c.ImDrawList, f: *const cap.Frame, si: usize) void {
    const s = &f.scopes.items[si];
    d.rect(fg, s.rect, kit.pal.hl_scope.alpha(0.16), 0);
    d.border(fg, s.rect, kit.pal.hl_scope, 0, 1.5);
    var b: [96]u8 = undefined;
    const label = kit.bufSay(&b, "{s}  {d:.0} × {d:.0}", &.{ kit.arg(s.name), kit.arg(s.rect.w), kit.arg(s.rect.h) }) orelse s.name;
    tag(ctx, fg, s.rect, label, kit.pal.hl_scope);
}

fn elementBox(ctx: *d.Ctx, fg: *c.ImDrawList, f: *const cap.Frame, i: usize, with_card: bool) void {
    const e = &f.els.items[i];
    const vis = cap.overlap(e.rect, e.clip);
    // O pedaço do layout em volta, tracejado de leve.
    if (f.scopeOf(e)) |s| if (s.rect.w > 0) d.border(fg, s.rect, kit.pal.hl_scope.alpha(0.55), 0, 1);
    d.rect(fg, vis, kit.pal.hl_fill, 0);
    d.border(fg, e.rect, kit.pal.hl_line, 0, 1);
    // Guias até a beirada da janela, como as do navegador.
    const g = kit.pal.hl_line.alpha(0.35);
    const w = f.win;
    d.line(fg, w.x, e.rect.y, w.right(), e.rect.y, g, 1);
    d.line(fg, w.x, e.rect.bottom(), w.right(), e.rect.bottom(), g, 1);
    d.line(fg, e.rect.x, w.y, e.rect.x, w.bottom(), g, 1);
    d.line(fg, e.rect.right(), w.y, e.rect.right(), w.bottom(), g, 1);
    if (with_card) card(ctx, fg, f, i);
}

/// A etiqueta curta em cima de um retângulo (o nome do pedaço do layout e o tamanho).
fn tag(ctx: *d.Ctx, fg: *c.ImDrawList, r: cap.Rect, label: []const u8, col: kit.Rgba) void {
    const font = ctx.ui.get(.semibold);
    const fs: f32 = 12;
    const w = d.width(font, fs, label) + 12;
    var y = r.y - 20;
    if (y < 2) y = r.y + 2;
    const tr: cap.Rect = .{ .x = r.x, .y = y, .w = w, .h = 18 };
    d.rect(fg, tr, col, 3);
    d.text(fg, font, fs, tr.x + 6, tr.y + (18 - fs * 1.2) / 2, kit.Rgba.white, label);
}

/// O cartão que segue o mouse escolhendo: o que é, o tamanho, a cor, a letra, o
/// contraste e de onde vem no tema.
fn card(ctx: *d.Ctx, fg: *c.ImDrawList, f: *const cap.Frame, i: usize) void {
    const e = &f.els.items[i];
    const font = ctx.ui.get(.regular);
    const bold = ctx.ui.get(.semibold);
    const fs: f32 = 12.5;
    const lh: f32 = 18;
    var lines: [6][160]u8 = undefined;
    var cols: [6]kit.Rgba = undefined;
    var lens: [6]usize = @splat(0);
    var n: usize = 0;
    const desc = @import("aba_elementos.zig").describe;
    var hb: [160]u8 = undefined;
    const head = desc(f, i, &hb);
    // Linhas: tamanho, cor/fonte, contraste, origem no tema.
    var sz: [48]u8 = undefined;
    const size_s = kit.bufSay(&sz, "{d:.0} × {d:.0}", &.{ kit.arg(e.rect.w), kit.arg(e.rect.h) }) orelse "";
    if (e.kind == .text or e.kind == .fill or e.kind == .border) {
        var hx: [12]u8 = undefined;
        const tok = @import("aba_elementos.zig").tokenName(ctx.th, e.color);
        lens[n] = if (kit.bufSay(&lines[n], "{s}  {s}{s}{s}", &.{ kit.arg(i18n.tr("Cor", "Color")), kit.arg(kit.hexOf(&hx, e.color)), kit.arg(if (tok.len > 0) "  " else ""), kit.arg(tok) })) |t| t.len else 0;
        cols[n] = kit.pal.text;
        n += 1;
    }
    if (e.kind == .text) {
        lens[n] = if (kit.bufSay(&lines[n], "{s}  {s} {d:.0}px", &.{ kit.arg(i18n.tr("Fonte", "Font")), kit.arg(@import("aba_elementos.zig").fontName(ctx, e.font)), kit.arg(e.size) })) |t| t.len else 0;
        cols[n] = kit.pal.text;
        n += 1;
        {
            const ratio = kit.fromU32(e.color).contrast(kit.fromU32(@import("aba_elementos.zig").fundo(f, i)));
            const ok = ratio >= 4.5;
            lens[n] = if (kit.bufSay(&lines[n], "{s}  {d:.2}  {s}", &.{ kit.arg(i18n.tr("Contraste", "Contrast")), kit.arg(ratio), kit.arg(if (ratio >= 7) "AAA" else if (ok) "AA" else i18n.tr("baixo", "low")) })) |t| t.len else 0;
            cols[n] = if (ok) kit.pal.ok else kit.pal.err;
            n += 1;
        }
    }
    if (f.scopeOf(e)) |s| if (s.line > 0) {
        lens[n] = if (kit.bufSay(&lines[n], "{s}  {s}:{d}", &.{ kit.arg(i18n.tr("Tema", "Theme")), kit.arg(@import("aba_elementos.zig").themeFile()), kit.arg(s.line) })) |t| t.len else 0;
        cols[n] = kit.pal.hl_scope;
        n += 1;
    };
    if (f.markFor(e.rect)) |m| {
        lens[n] = if (kit.bufSay(&lines[n], "QA  {s}", &.{ kit.arg(m) })) |t| t.len else 0;
        cols[n] = kit.pal.dim;
        n += 1;
    }
    var w: f32 = d.width(bold, fs, head) + d.width(font, fs, size_s) + 40;
    for (0..n) |k| w = @max(w, d.width(font, fs, lines[k][0..lens[k]]) + 20);
    w = @min(w, 420);
    const h = lh * @as(f32, @floatFromInt(n + 1)) + 10;
    const m = ctx.mouse;
    const vp = c.ImGui_GetMainViewport();
    const vr: cap.Rect = .{ .x = vp.*.Pos.x, .y = vp.*.Pos.y, .w = vp.*.Size.x, .h = vp.*.Size.y };
    var x = e.rect.x;
    var y = e.rect.bottom() + 8;
    if (y + h > vr.bottom()) y = e.rect.y - h - 8;
    if (y < vr.y) y = m.y + 20;
    x = std.math.clamp(x, vr.x + 4, vr.right() - w - 4);
    const r: cap.Rect = .{ .x = x, .y = y, .w = w, .h = h };
    d.shadow(fg, r, 6, 10, kit.Rgba.black.alpha(0.35));
    d.rect(fg, r, kit.pal.toolbar, 6);
    d.border(fg, r, kit.pal.line, 6, 1);
    d.text(fg, bold, fs, x + 10, y + 5 + (lh - fs * 1.2) / 2, kit.pal.tag, d.utf8Prefix(head, 120));
    d.text(fg, font, fs, r.right() - d.width(font, fs, size_s) - 10, y + 5 + (lh - fs * 1.2) / 2, kit.pal.dim, size_s);
    for (0..n) |k| {
        const ly = y + 5 + lh * @as(f32, @floatFromInt(k + 1));
        if (k == 0 and (e.kind == .text or e.kind == .fill or e.kind == .border)) {
            d.rect(fg, .{ .x = x + 10, .y = ly + 4, .w = 10, .h = 10 }, kit.fromU32(e.color), 2);
            d.border(fg, .{ .x = x + 10, .y = ly + 4, .w = 10, .h = 10 }, kit.pal.line, 2, 1);
            _ = d.textClipped(fg, font, fs, x + 26, ly + (lh - fs * 1.2) / 2, cols[k], lines[k][0..lens[k]], w - 34);
        } else _ = d.textClipped(fg, font, fs, x + 10, ly + (lh - fs * 1.2) / 2, cols[k], lines[k][0..lens[k]], w - 20);
    }
}
