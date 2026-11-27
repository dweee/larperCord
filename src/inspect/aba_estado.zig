//! Aba Estado: o básico do que o app tem agora — a sessão (conexão, conta, quantos
//! servidores, canais e pessoas), a conversa aberta (o que está carregado dela), o tema
//! (cada cor com o nome e o hex, as opções) e a janela (tamanho, escala, renderizador).
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const i18n = @import("../ui/i18n.zig");
const kit = @import("kit.zig");
const theme_mod = @import("../theme/theme.zig");
const App = @import("../app.zig").App;

var sec_session = true;
var sec_channel = true;
var sec_theme = true;
var sec_window = true;

pub fn draw(u: *kit.Ui, app: *App, r: kit.Rect) void {
    const parent = u.dl;
    kit.rect(u, r, kit.pal.panel, 0);
    var y = kit.beginPane(u, "##state", r);
    const x = r.x;
    const w = r.w - 10;
    var b: [160]u8 = undefined;
    const st = &app.store;
    if (kit.section(u, x, &y, w + 10, i18n.tr("Sessão", "Session"), &sec_session)) {
        kit.kv(u, x, &y, w, i18n.tr("Conexão", "Connection"), @tagName(st.connection), if (st.connection == .ready) kit.pal.ok else kit.pal.warn);
        kit.kv(u, x, &y, w, i18n.tr("Modo", "Mode"), if (st.demo) i18n.tr("demonstração", "demo") else if (st.from_cache) i18n.tr("aberto pelo cache, esperando o READY", "opened from cache, waiting for READY") else i18n.tr("conta conectada", "account connected"), kit.pal.text);
        kit.kv(u, x, &y, w, i18n.tr("Sua conta", "Your account"), kit.bufSay(&b, "{s} ({d})", &.{ kit.arg(st.me_username orelse "?"), kit.arg(st.me) }) orelse "", kit.pal.text);
        kit.kv(u, x, &y, w, i18n.tr("Servidores / canais / pessoas", "Servers / channels / people"), kit.bufSay(&b, "{d} / {d} / {d}", &.{ kit.arg(st.guilds.items.len), kit.arg(st.channels.count()), kit.arg(st.users.count()) }) orelse "", kit.pal.num);
        kit.kv(u, x, &y, w, i18n.tr("Latência", "Latency"), kit.bufSay(&b, "{d} ms", &.{ kit.arg(st.latency_ms) }) orelse "", kit.pal.num);
        kit.kv(u, x, &y, w, i18n.tr("Mensagens por canal (teto)", "Messages per channel (cap)"), kit.bufSay(&b, "{d}", &.{ kit.arg(st.max_messages) }) orelse "", kit.pal.num);
        y += 6;
    }
    if (kit.section(u, x, &y, w + 10, i18n.tr("Conversa aberta", "Open conversation"), &sec_channel)) {
        if (app.st.activeChannel()) |id| if (st.channel(id)) |cs| {
            kit.kv(u, x, &y, w, i18n.tr("Canal", "Channel"), kit.bufSay(&b, "{s} ({d})", &.{ kit.arg(cs.info.name), kit.arg(id) }) orelse "", kit.pal.text);
            kit.kv(u, x, &y, w, i18n.tr("Servidor", "Server"), kit.bufSay(&b, "{d}", &.{ kit.arg(cs.info.guild) }) orelse "", kit.pal.num);
            kit.kv(u, x, &y, w, i18n.tr("Tipo", "Type"), @tagName(cs.info.kind), kit.pal.text);
            kit.kv(u, x, &y, w, i18n.tr("Mensagens carregadas", "Messages loaded"), kit.bufSay(&b, "{d}", &.{ kit.arg(cs.messages.items.len) }) orelse "", kit.pal.num);
            kit.kv(u, x, &y, w, i18n.tr("Histórico", "History"), kit.bufSay(&b, "{s} · mais antigas: {s}", &.{ kit.arg(@tagName(cs.history)), kit.arg(@tagName(cs.older)) }) orelse "", kit.pal.text);
            kit.kv(u, x, &y, w, i18n.tr("Lida até", "Read up to"), kit.bufSay(&b, "{d}", &.{ kit.arg(cs.read_id) }) orelse "", kit.pal.num);
            kit.kv(u, x, &y, w, i18n.tr("Veio do cache", "Came from cache"), if (cs.cached) i18n.tr("sim", "yes") else i18n.tr("não", "no"), kit.pal.text);
            if (cs.messages.items.len > 0) {
                const last = cs.messages.items[cs.messages.items.len - 1];
                kit.kv(u, x, &y, w, i18n.tr("Última mensagem", "Last message"), kit.bufSay(&b, "{d}", &.{ kit.arg(last.msg.id) }) orelse "", kit.pal.num);
            }
        } else {
            _ = u.text(x + 12, y + 2, kit.pal.faint, i18n.tr("Nenhuma conversa aberta.", "No conversation open."));
            y += 22;
        } else {
            _ = u.text(x + 12, y + 2, kit.pal.faint, i18n.tr("Nenhuma conversa aberta.", "No conversation open."));
            y += 22;
        }
        y += 6;
    }
    if (kit.section(u, x, &y, w + 10, i18n.tr("Tema", "Theme"), &sec_theme)) {
        const th = app.themes.theme_();
        kit.kv(u, x, &y, w, i18n.tr("Nome", "Name"), app.themes.name(), kit.pal.text);
        kit.kv(u, x, &y, w, i18n.tr("Arquivo", "File"), @import("aba_elementos.zig").themeFile(), kit.pal.hl_scope);
        kit.kv(u, x, &y, w, i18n.tr("Modo", "Mode"), @tagName(app.themes.mode), kit.pal.text);
        y += 4;
        // As cores, em duas colunas quando cabe.
        const cols: usize = if (w > 520) 2 else 1;
        const colw = (w - 10) / @as(f32, @floatFromInt(cols));
        // Um laço de verdade (não `inline for`): o corpo desenhado uma vez só no executável,
        // não uma cópia por cor.
        const tokens = comptime std.enums.values(theme_mod.Token);
        for (tokens, 0..) |tok, k| {
            const name = @tagName(tok);
            const col = th.c(tok);
            const cx = x + 12 + @as(f32, @floatFromInt(k % cols)) * colw;
            const cy = y + @as(f32, @floatFromInt(k / cols)) * 20;
            kit.swatch(u, .{ .x = cx, .y = cy + 4, .w = 12, .h = 12 }, col);
            _ = u.code(cx + 20, u.midCode(cy, 20), kit.pal.key, name);
            var hx: [12]u8 = undefined;
            const hex = kit.hexOf(&hx, col.u());
            const rr: kit.Rect = .{ .x = cx, .y = cy, .w = colw - 8, .h = 20 };
            if (u.over(rr)) {
                kit.rect(u, rr, kit.pal.hover, 3);
                if (c.ImGui_IsMouseClicked(0)) kit.copyText(hex);
            }
            _ = u.code(cx + colw - 90, u.midCode(cy, 20), kit.pal.value, hex);
        }
        y += @as(f32, @floatFromInt((tokens.len + cols - 1) / cols)) * 20 + 8;
    }
    if (kit.section(u, x, &y, w + 10, i18n.tr("Janela", "Window"), &sec_window)) {
        const io = app.io;
        kit.kv(u, x, &y, w, i18n.tr("Tamanho (pontos)", "Size (points)"), kit.bufSay(&b, "{d:.0} × {d:.0}", &.{ kit.arg(io.*.DisplaySize.x), kit.arg(io.*.DisplaySize.y) }) orelse "", kit.pal.num);
        kit.kv(u, x, &y, w, i18n.tr("Escala da interface", "Interface scale"), kit.bufSay(&b, "{d:.2} (pixels por ponto {d:.2})", &.{ kit.arg(app.uiScale()), kit.arg(io.*.DisplayFramebufferScale.x) }) orelse "", kit.pal.num);
        kit.kv(u, x, &y, w, i18n.tr("Renderizador", "Renderer"), if (c.SDL_GetRendererName(app.win.renderer)) |n| std.mem.span(n) else "?", kit.pal.text);
        kit.kv(u, x, &y, w, i18n.tr("Vídeo", "Video"), if (c.SDL_GetCurrentVideoDriver()) |n| std.mem.span(n) else "?", kit.pal.text);
        kit.kv(u, x, &y, w, i18n.tr("Sistema", "System"), kit.bufSay(&b, "{s} {s}", &.{ kit.arg(@tagName(builtin.os.tag)), kit.arg(@tagName(builtin.cpu.arch)) }) orelse "", kit.pal.text);
        kit.kv(u, x, &y, w, i18n.tr("Versão", "Version"), @import("../core/version.zig").number, kit.pal.text);
        y += 6;
    }
    kit.endPane(u, r, y, parent);
}

/// O mesmo em texto, para o comando `state`.
pub fn texto(app: *App, w: *std.Io.Writer) @import("comandos.zig").Fim {
    const st = &app.store;
    kit.say(w, "conexão: {s}{s}\n", &.{ kit.arg(@tagName(st.connection)), kit.arg(if (st.demo) " (demonstração)" else "") }) catch {};
    kit.say(w, "conta: {s} ({d})\n", &.{ kit.arg(st.me_username orelse "?"), kit.arg(st.me) }) catch {};
    kit.say(w, "servidores {d}, canais {d}, pessoas {d}, latência {d} ms\n", &.{ kit.arg(st.guilds.items.len), kit.arg(st.channels.count()), kit.arg(st.users.count()), kit.arg(st.latency_ms) }) catch {};
    if (app.st.activeChannel()) |id| if (st.channel(id)) |cs| {
        kit.say(w, "conversa aberta: {s} ({d}), servidor {d}, {d} mensagens, histórico {s}\n", &.{ kit.arg(cs.info.name), kit.arg(id), kit.arg(cs.info.guild), kit.arg(cs.messages.items.len), kit.arg(@tagName(cs.history)) }) catch {};
    };
    kit.say(w, "tema: {s} ({s}), arquivo {s}\n", &.{ kit.arg(app.themes.name()), kit.arg(@tagName(app.themes.mode)), kit.arg(@import("aba_elementos.zig").themeFile()) }) catch {};
    kit.say(w, "janela: {d:.0}×{d:.0} pontos, escala {d:.2}\n", &.{ kit.arg(app.io.*.DisplaySize.x), kit.arg(app.io.*.DisplaySize.y), kit.arg(app.uiScale()) }) catch {};
    return .pronto;
}
