//! As notificações do sistema que respondem (core/notificacao.zig). A de uma DM ou
//! menção leva "Marcar como lida" e "Responder", e o clique abre a conversa na
//! mensagem; as outras (lembrete, chamada, versão nova, plugin) só trazem a janela.
//! No Linux vão pelo D-Bus (platform/notif_dbus.zig), no Windows pelos avisos do
//! WinRT (platform/notif_win.zig); onde não dá, saem como antes (notify-send, o balão
//! da bandeja), sem botões.
//!
//! O que a pessoa fez volta pelo laço (Wake.notificacao) e é feito aqui, com a janela
//! escondida na bandeja ou não: ler e responder não mostram a janela, abrir e
//! "Responder" sem caixa de texto na notificação mostram. A resposta passa pelas
//! mesmas regras da caixa de texto (modo lento, permissão, castigo, conectando); não
//! saindo, o texto vira o rascunho da conversa e outra notificação diz por quê.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const types = @import("core/types.zig");
const n = @import("core/notificacao.zig");
const envio = @import("core/envio.zig");
const sys = @import("platform/sys.zig");
const tray = @import("platform/tray.zig");
const notif_dbus = @import("platform/notif_dbus.zig");
const notif_win = @import("platform/notif_win.zig");
const i18n = @import("ui/i18n.zig");
const send_limits = @import("ui/composer_limits.zig");
const ChannelState = @import("core/store.zig").ChannelState;
const now = @import("net/fake_gateway.zig").nowMs;
const Id = types.Id;

/// O programa do caminho de antes (o QA troca por um de mentira, que só anota).
pub var notify_send: [:0]const u8 = "notify-send";
/// O QA liga para a demonstração notificar (App.notify volta antes no QA e no demo).
pub var qa_ligado = false;

/// O QA confere por aqui.
pub const medidas = struct {
    pub var pelo_notify_send: u32 = 0;
    pub var pelo_balao: u32 = 0;
    pub var nao_enviadas: u32 = 0;
    /// A ficha do xdg-activation do último clique que trouxe a janela.
    pub var ficha: [n.ficha_max]u8 = undefined;
    pub var ficha_len: usize = 0;
};

/// As conversas com notificação nossa viva: o fechar só vai ao sistema quando tem o
/// que fechar (ler uma conversa acontece o tempo todo).
var vivas: [n.max_vivas]Id = @splat(0);

/// As respostas pela notificação a caminho: a recusa do Discord (send_failed) avisa.
const Enviada = struct { canal: Id = 0, nonce: u64 = 0, msg: Id = 0 };
var enviadas: [8]Enviada = @splat(.{});
var proxima: usize = 0;

fn rotulos() n.Rotulos {
    return .{
        .abrir = i18n.tr("Abrir", "Open"),
        .lida = i18n.tr("Marcar como lida", "Mark as read"),
        .responder = i18n.tr("Responder", "Reply"),
    };
}

/// DM ou menção chegando sem ninguém olhando (App.notify já conferiu foco, "Não
/// perturbe" e silenciados), com os botões se as Configurações deixam.
pub fn mensagem(app: *App, m: types.Message, cs: *const ChannelState, titulo: []const u8, corpo: []const u8) void {
    const quem = app.store.nameIn(cs.info.guild, m.author) orelse "?";
    var db: [128]u8 = undefined;
    const a: n.Aviso = .{
        .titulo = titulo,
        .corpo = corpo,
        .alvo = .{ .canal = m.channel, .msg = m.id },
        .tipo = .mensagem,
        .botoes = app.st.settings.notif_reply,
        .rotulos = rotulos(),
        .dica = i18n.fmt(&db, "Responder a {s}…", "Reply to {s}…", .{clip(quem, 64)}),
    };
    if (mostrar(app, a)) lembrar(m.channel);
}

/// Lembrete, chamada, versão nova, plugin: sem botões, e o clique traz a janela.
pub fn simples(app: *App, titulo: []const u8, corpo: []const u8) void {
    _ = mostrar(app, .{ .titulo = titulo, .corpo = corpo, .rotulos = rotulos() });
}

/// Pelo caminho novo; não dando, pelo de antes. false: nenhum (uma rajada passou do
/// limite de notificações a caminho, como os notify-send de antes).
fn mostrar(app: *App, a: n.Aviso) bool {
    if (sys.windows) {
        if (notif_win.mostrar(app.win.wake_type, a)) return true;
        balao(app, a);
        return true;
    } else {
        if (notif_dbus.cheio()) return false;
        if (notif_dbus.mostrar(app.win.wake_type, a, now())) return true;
        return notifySend(app, a.titulo, a.corpo);
    }
}

fn balao(app: *App, a: n.Aviso) void {
    medidas.pelo_balao += 1;
    // Na bandeja a janela foi embora (App.releaseGpu): o balão vai pela janela escondida
    // do ícone da bandeja.
    const hwnd = if (app.win.window) |w| c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(w), c.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null) else tray.nativeWindow();
    sys.toast(hwnd, now(), a.titulo, a.corpo);
}

/// O caminho de antes no Linux: um notify-send por notificação, sem botões (os que
/// terminaram são recolhidos em App.reapNotifiers).
fn notifySend(app: *App, titulo: []const u8, corpo: []const u8) bool {
    if (app.notifiers.items.len >= 8) return false;
    const t = app.gpa.dupeSentinel(u8, titulo, 0) catch return false;
    defer app.gpa.free(t);
    const b = app.gpa.dupeSentinel(u8, corpo, 0) catch return false;
    defer app.gpa.free(b);
    // O ícone pelo nome: o do mascote escolhido (ver applyMascot e icone_sistema).
    var args = [_:null]?[*:0]const u8{ notify_send.ptr, "--app-name=larperCord", "--icon=larpercord", "--", t.ptr, b.ptr };
    const proc = c.SDL_CreateProcess(@ptrCast(&args), false) orelse return false;
    app.notifiers.append(app.gpa, proc) catch c.SDL_DestroyProcess(proc);
    medidas.pelo_notify_send += 1;
    return true;
}

fn clip(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

// --- O que volta ------------------------------------------------------------------

/// O que voltou das notificações (Wake.notificacao). true: algo para a tela mudou.
pub fn pedidos(app: *App) bool {
    var lista: std.ArrayList(n.Volta) = .empty;
    defer lista.deinit(std.heap.c_allocator);
    if (sys.windows) notif_win.pegar(&lista) else notif_dbus.pegar(&lista);
    var quadro = false;
    for (lista.items) |v| {
        defer v.liberar(std.heap.c_allocator);
        switch (v) {
            // Não deu pelo caminho novo (sem servidor, recusada): sai pelo de antes.
            .devolvida => |a| if (sys.windows) balao(app, a) else {
                _ = notifySend(app, a.titulo, a.corpo);
            },
            .pedido => |p| quadro = fazer(app, p) or quadro,
        }
    }
    return quadro;
}

fn fazer(app: *App, p: n.Pedido) bool {
    switch (p.acao) {
        .abrir => {
            trazer(app, p.ficha);
            if (p.alvo.canal != 0) app.handle(.{ .open_message = .{ .channel = p.alvo.canal, .id = p.alvo.msg } });
            return true;
        },
        // Como "Marcar como lido" no app (as notificações da conversa saem junto).
        .lida => {
            app.handle(.{ .mark_read = p.alvo.canal });
            return false;
        },
        .responder => {
            responder(app, p.alvo, p.texto);
            return false;
        },
        .escrever => {
            trazer(app, p.ficha);
            escrever(app, p.alvo);
            return true;
        },
    }
}

/// A janela vem (da bandeja, de trás de outra), com a ficha do servidor de
/// notificações: com ela, o compositor Wayland deixa vir com o foco.
fn trazer(app: *App, ficha: []const u8) void {
    var buf: [n.ficha_max + 1]u8 = undefined;
    const tok: ?[:0]const u8 = if (ficha.len > 0 and ficha.len <= n.ficha_max) blk: {
        @memcpy(buf[0..ficha.len], ficha);
        buf[ficha.len] = 0;
        break :blk buf[0..ficha.len :0];
    } else null;
    medidas.ficha_len = if (tok) |t| t.len else 0;
    if (tok) |t| @memcpy(medidas.ficha[0..t.len], t);
    app.showWindowWith(tok);
}

/// A conversa aberta na mensagem, com a resposta a ela pronta na caixa.
fn escrever(app: *App, alvo: n.Alvo) void {
    app.handle(.{ .open_message = .{ .channel = alvo.canal, .id = alvo.msg } });
    // Sem acesso (ou de outra conta): quem abriu já avisou.
    if (app.st.activeChannel() != alvo.canal) return;
    // A caixa passa já para esta conversa (o rascunho dela volta); trocar no próximo
    // quadro tiraria a resposta.
    app.syncDraft();
    app.handle(.{ .reply = alvo.msg });
}

/// A resposta digitada na notificação, mandada como a caixa de texto mandaria.
fn responder(app: *App, alvo: n.Alvo, texto: []const u8) void {
    const now_ms = now();
    const cs = app.store.channel(alvo.canal) orelse
        return naoEnviada(app, alvo, texto, i18n.tr("Essa conversa não está disponível nesta conta.", "That conversation isn't available on this account."));
    if (!app.store.canAccess(&cs.info))
        return naoEnviada(app, alvo, texto, i18n.tr("Você não tem acesso a essa conversa.", "You don't have access to that conversation."));
    // As regras da caixa de texto: castigo, permissão, quarentena, modo lento, conectando.
    var rb: [240]u8 = undefined;
    const b = send_limits.blockForId(&app.store, alvo.canal, now_ms);
    if (b.reason != .none) return naoEnviada(app, alvo, texto, send_limits.reasonText(&rb, b, now_ms));
    // Como a caixa da janela flutuante: as regras fixas dos plugins e o "@silent " no começo.
    const limpo = app.plugins.rewriteOutgoing(texto);
    defer if (limpo) |t| app.gpa.free(t);
    var body: []const u8 = limpo orelse texto;
    // Mencionar ou não o autor é a escolha de agora na caixa (o "@ LIGADO" da barra).
    var opts: envio.SendOpts = .{ .ping_reply = app.st.reply_ping };
    if (envio.stripSilent(body)) |rest| {
        opts.silent = true;
        body = rest;
    }
    if (body.len == 0) return;
    const antes = app.st.nonce;
    app.sendWithOpts(alvo.canal, body, alvo.msg, false, opts);
    if (app.st.nonce == antes) return naoEnviada(app, alvo, texto, i18n.tr("Não deu para mandar agora.", "Couldn't send it right now."));
    enviadas[proxima] = .{ .canal = alvo.canal, .nonce = app.st.nonce, .msg = alvo.msg };
    proxima = (proxima + 1) % enviadas.len;
}

/// A resposta não saiu: o texto fica como rascunho da conversa (não se perde) e uma
/// notificação diz por quê; o clique nela abre a conversa com a resposta pronta.
fn naoEnviada(app: *App, alvo: n.Alvo, texto: []const u8, motivo: []const u8) void {
    medidas.nao_enviadas += 1;
    const existe = app.store.channel(alvo.canal) != null;
    if (existe) guardarRascunho(app, alvo.canal, texto);
    _ = mostrar(app, .{
        .titulo = i18n.tr("Resposta não enviada", "Reply not sent"),
        .corpo = motivo,
        .alvo = if (existe) alvo else .{},
        .tipo = if (existe) .falha else .simples,
        .rotulos = rotulos(),
    });
    // Com a janela à vista, o aviso de dentro também.
    app.st.showToast(now(), true, "{s}", "{s}", .{motivo});
}

/// O texto entra na caixa da conversa (a da tela, se ela é a desta conversa e está
/// livre) ou no rascunho dela, depois do que já estava lá.
fn guardarRascunho(app: *App, canal: Id, texto: []const u8) void {
    const st = &app.st;
    if (texto.len == 0) return;
    const na_caixa = st.drafts.current == canal;
    if (na_caixa and st.editing != 0) return;
    const velho = if (na_caixa) std.mem.sliceTo(&st.input, 0) else st.drafts.get(canal) orelse "";
    var buf: [@typeInfo(@TypeOf(st.input)).array.len]u8 = undefined;
    const max = buf.len - 1;
    var len: usize = 0;
    for ([_][]const u8{ velho, if (velho.len > 0) "\n" else "", texto }) |parte| {
        const k = clip(parte, max - len).len;
        @memcpy(buf[len..][0..k], parte[0..k]);
        len += k;
    }
    if (na_caixa) {
        @memcpy(st.input[0..len], buf[0..len]);
        @memset(st.input[len..], 0);
        st.input_sync = true;
    } else {
        st.drafts.put(app.gpa, canal, buf[0..len]);
        app.saveDrafts();
    }
}

/// O Discord recusou uma mensagem: se era uma resposta pela notificação, avisa por
/// outra (a mensagem fica na conversa com "tentar de novo").
pub fn falhou(app: *App, canal: Id, nonce: u64) void {
    if (nonce == 0) return;
    for (&enviadas) |*e| if (e.nonce == nonce and e.canal == canal) {
        const alvo: n.Alvo = .{ .canal = canal, .msg = e.msg };
        e.* = .{};
        medidas.nao_enviadas += 1;
        _ = mostrar(app, .{
            .titulo = i18n.tr("Resposta não enviada", "Reply not sent"),
            .corpo = i18n.tr("O Discord recusou a mensagem. Ela ficou na conversa para tentar de novo.", "Discord refused the message. It's in the conversation to try again."),
            .alvo = alvo,
            .rotulos = rotulos(),
        });
        return;
    };
}

// --- Fechar ----------------------------------------------------------------------

fn lembrar(canal: Id) void {
    for (vivas) |v| if (v == canal) return;
    for (&vivas) |*v| if (v.* == 0) {
        v.* = canal;
        return;
    };
    std.mem.copyForwards(Id, vivas[0 .. vivas.len - 1], vivas[1..]);
    vivas[vivas.len - 1] = canal;
}

/// A conversa foi lida (aqui, em outro aparelho, ou respondida): as notificações
/// dela saem da tela e da central.
pub fn lida(canal: Id) void {
    var tinha = false;
    for (&vivas) |*v| if (v.* == canal and canal != 0) {
        v.* = 0;
        tinha = true;
    };
    if (!tinha) return;
    if (sys.windows) notif_win.fechar(canal) else notif_dbus.fechar(canal);
}

/// A conta saiu (os canais das notificações eram dela).
pub fn fecharTodas() void {
    vivas = @splat(0);
    if (sys.windows) notif_win.fechar(0) else notif_dbus.fechar(0);
}

/// O app está saindo: as nossas saem da tela e da central (os botões delas não
/// teriam mais quem atender).
pub fn parar() void {
    if (sys.windows) notif_win.parar() else notif_dbus.parar();
}

/// O mascote do ícone dos avisos do Windows.
pub fn mascote(classic: bool) void {
    if (sys.windows) notif_win.mascote(classic);
}
