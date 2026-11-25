//! QA das notificações que respondem (app_notificacao.zig), pelo caminho de verdade do
//! Linux: sem sessão D-Bus a notificação sai pelo notify-send (um de mentira, que só
//! anota); depois sobe um dbus-daemon particular (nunca o da sessão de quem roda, nem
//! um servidor de notificações instalado: a configuração não ativa nada) e o servidor
//! de mentira (`--qa-notif-server`, qa_notif_server.zig), primeiro como o do KDE (com a
//! caixa de texto) e depois como o do GNOME (só botões). Confere o Notify de uma DM e de
//! uma menção, "Marcar como lida" e a resposta com a janela na bandeja, a resposta
//! barrada pelo modo lento, o clique que abre a conversa com a ficha do Wayland,
//! "Responder" sem caixa, e o servidor que some (volta o notify-send). No Windows, só
//! que a notificação sai (pelo aviso do WinRT ou pelo balão) e nada cai.
//!
//! `QA_SUITE=notificacao` roda isto.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const platform = @import("platform/window.zig");
const sys = @import("platform/sys.zig");
const tray = @import("platform/tray.zig");
const i18n = @import("ui/i18n.zig");
const an = @import("app_notificacao.zig");
const notif_dbus = @import("platform/notif_dbus.zig");
const notif_win = @import("platform/notif_win.zig");
const Id = types.Id;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 6000 } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}

const dm = gw.dmId(1);
const barrada = gw.dmId(3);
const memes = gw.channelId(0, 5);

var seq: u64 = 0;

/// Mensagem de outra pessoa chegando, como se viesse do Discord.
fn chegar(app: *App, ch: Id, texto: []const u8) Id {
    seq += 1;
    const id = types.makeSnowflake(gw.nowMs(), 0x5e000 + seq);
    const content = std.heap.c_allocator.dupe(u8, texto) catch return 0;
    const autor = gw.dmRecipient(ch) orelse 1001;
    app.events.push(.{ .message_create = .{ .id = id, .channel = ch, .author = autor, .timestamp = @divTrunc(gw.nowMs(), 1000), .content = content, .mentions_me = ch == memes } });
    platform.Window.wake(app.win.wake_type, .gateway);
    return id;
}

// --- Arquivos de qa-out ----------------------------------------------------------

var dir_buf: [512]u8 = undefined;
var dir: []const u8 = "";

fn caminho(buf: []u8, nome: []const u8) [:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ dir, nome }, 0) catch "";
}

var ler_buf: [128 * 1024]u8 = undefined;
fn ler(nome: []const u8) []const u8 {
    var pb: [600]u8 = undefined;
    var size: usize = 0;
    const data = c.SDL_LoadFile(caminho(&pb, nome).ptr, &size) orelse return "";
    defer c.SDL_free(data);
    const n = @min(size, ler_buf.len);
    @memcpy(ler_buf[0..n], @as([*]const u8, @ptrCast(data))[0..n]);
    return ler_buf[0..n];
}

fn gravar(nome: []const u8, bytes: []const u8) void {
    var pb: [600]u8 = undefined;
    _ = c.SDL_SaveFile(caminho(&pb, nome).ptr, bytes.ptr, bytes.len);
}

/// Uma linha `notify` do servidor de mentira.
const Linha = struct { id: u32, titulo: []const u8, corpo: []const u8, acoes: []const u8, dicas: []const u8 };

/// A última notificação cujo corpo tem `texto`.
fn notificada(texto: []const u8) ?Linha {
    var achou: ?Linha = null;
    var it = std.mem.splitScalar(u8, ler("notif-servidor.log"), '\n');
    while (it.next()) |l| {
        var f = std.mem.splitScalar(u8, l, '\t');
        if (!std.mem.eql(u8, f.next() orelse continue, "notify")) continue;
        const id = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        const t = f.next() orelse continue;
        const corpo = f.next() orelse continue;
        const acoes = f.next() orelse continue;
        const dicas = f.next() orelse "";
        if (std.mem.indexOf(u8, corpo, texto) != null) achou = .{ .id = id, .titulo = t, .corpo = corpo, .acoes = acoes, .dicas = dicas };
    }
    return achou;
}

fn tem(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn temFmt(hay: []const u8, comptime fmt: []const u8, args: anytype) bool {
    var b: [160]u8 = undefined;
    return tem(hay, std.fmt.bufPrint(&b, fmt, args) catch return false);
}

// --- O notify-send de mentira e o começo -----------------------------------------

const notify_send_falso =
    \\#!/bin/sh
    \\# O notify-send do QA: só anota o que receberia (nunca mostra nada na tela).
    \\printf '%s\n' "$*" >> "$(dirname "$0")/notify-send.log"
    \\
;

var notify_send_buf: [600]u8 = undefined;

fn preparar(app: *App) void {
    const here = c.SDL_GetCurrentDirectory() orelse return;
    defer c.SDL_free(here);
    const base = std.mem.trimEnd(u8, std.mem.span(here), "/");
    dir = std.fmt.bufPrint(&dir_buf, "{s}/qa-out", .{base}) catch return;
    gravar("notify-send", notify_send_falso);
    gravar("notify-send.log", "");
    const ns = caminho(&notify_send_buf, "notify-send");
    _ = c.chmod(ns.ptr, 0o755);
    an.notify_send = ns;
    an.qa_ligado = true;
    // Fora de foco: as notificações saem (como a janela atrás de outra).
    app.qa_blur = true;
    // Sem sessão D-Bus nenhuma: um endereço que não existe (nunca a do usuário, nem a
    // do XDG_RUNTIME_DIR, mesmo rodando fora do qaenv).
    var ab: [600]u8 = undefined;
    const sem = std.fmt.bufPrintSentinel(&ab, "unix:path={s}/sem-barramento", .{dir}, 0) catch return;
    _ = c.setenv("DBUS_SESSION_BUS_ADDRESS", sem.ptr, 1);
    notif_dbus.tentarDeNovo();
}

var dm_a: Id = 0;
fn chegaSemBarramento(app: *App) void {
    dm_a = chegar(app, dm, "chegou sem barramento");
}
fn peloNotifySend(_: *App) bool {
    const log = ler("notify-send.log");
    return notif_dbus.estado() == .sem and an.medidas.pelo_notify_send >= 1 and
        tem(log, "--app-name=larperCord --icon=larpercord -- ") and tem(log, "chegou sem barramento");
}

// --- A sessão D-Bus particular e o servidor de mentira ------------------------------

var daemon: ?*c.SDL_Process = null;
var servidor: ?*c.SDL_Process = null;
var endereco_buf: [600]u8 = undefined;
var endereco: [:0]const u8 = "";

fn subirBarramento(_: *App) void {
    // Sem ativação de serviço: nenhum servidor de notificações instalado começa aqui.
    var socket_dir: []const u8 = dir;
    if (dir.len + 24 > 100) socket_dir = "/tmp";
    var cb: [1400]u8 = undefined;
    const conf = std.fmt.bufPrint(&cb,
        \\<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
        \\ "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
        \\<busconfig>
        \\  <type>session</type>
        \\  <listen>unix:dir={s}</listen>
        \\  <auth>EXTERNAL</auth>
        \\  <policy context="default">
        \\    <allow send_destination="*" eavesdrop="true"/>
        \\    <allow eavesdrop="true"/>
        \\    <allow own="*"/>
        \\  </policy>
        \\</busconfig>
        \\
    , .{socket_dir}) catch return;
    gravar("notif-barramento.conf", conf);
    var pb: [600]u8 = undefined;
    var ab: [640]u8 = undefined;
    const arg = std.fmt.bufPrintSentinel(&ab, "--config-file={s}", .{caminho(&pb, "notif-barramento.conf")}, 0) catch return;
    var args = [_:null]?[*:0]const u8{ "dbus-daemon", arg.ptr, "--nofork", "--print-address" };
    const props = c.SDL_CreateProperties();
    defer c.SDL_DestroyProperties(props);
    _ = c.SDL_SetPointerProperty(props, c.SDL_PROP_PROCESS_CREATE_ARGS_POINTER, @ptrCast(&args));
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDIN_NUMBER, c.SDL_PROCESS_STDIO_NULL);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDOUT_NUMBER, c.SDL_PROCESS_STDIO_APP);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDERR_NUMBER, c.SDL_PROCESS_STDIO_INHERITED);
    const proc = c.SDL_CreateProcessWithProperties(props) orelse {
        std.debug.print("[notificação] o dbus-daemon não abriu (instalado?): {s}\n", .{c.SDL_GetError()});
        return;
    };
    daemon = proc;
    // O endereço sai na primeira linha, assim que ele está pronto.
    const out = c.SDL_GetProcessOutput(proc);
    var len: usize = 0;
    var tries: u32 = 0;
    while (tries < 250) : (tries += 1) {
        const got = c.SDL_ReadIO(out, endereco_buf[len..].ptr, endereco_buf.len - 1 - len);
        len += got;
        if (std.mem.indexOfScalar(u8, endereco_buf[0..len], '\n')) |nl| {
            endereco_buf[nl] = 0;
            endereco = endereco_buf[0..nl :0];
            break;
        }
        if (got == 0 and c.SDL_GetIOStatus(out) != c.SDL_IO_STATUS_NOT_READY) break;
        c.SDL_Delay(20);
    }
    if (endereco.len == 0) return;
    // O app (a libdbus dele) e o servidor de mentira passam a usar esta.
    _ = c.setenv("DBUS_SESSION_BUS_ADDRESS", endereco.ptr, 1);
}
fn barramentoDePe(_: *App) bool {
    return std.mem.startsWith(u8, endereco, "unix:");
}

/// O servidor de mentira com as capacidades `caps` (o registro começa vazio).
fn subirServidor(caps: [*:0]const u8) void {
    gravar("notif-servidor.log", "");
    var eb: [1024]u8 = undefined;
    const exe = sys.selfExe(&eb) orelse return;
    var zb: [1024]u8 = undefined;
    const exe_z = std.fmt.bufPrintSentinel(&zb, "{s}", .{exe}, 0) catch return;
    var pb: [600]u8 = undefined;
    const log = caminho(&pb, "notif-servidor.log");
    var args = [_:null]?[*:0]const u8{ exe_z.ptr, "--qa-notif-server", caps, log.ptr };
    const env = c.SDL_CreateEnvironment(true) orelse return;
    defer c.SDL_DestroyEnvironment(env);
    _ = c.SDL_SetEnvironmentVariable(env, "DBUS_SESSION_BUS_ADDRESS", endereco.ptr, true);
    const props = c.SDL_CreateProperties();
    defer c.SDL_DestroyProperties(props);
    _ = c.SDL_SetPointerProperty(props, c.SDL_PROP_PROCESS_CREATE_ARGS_POINTER, @ptrCast(&args));
    _ = c.SDL_SetPointerProperty(props, c.SDL_PROP_PROCESS_CREATE_ENVIRONMENT_POINTER, env);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDIN_NUMBER, c.SDL_PROCESS_STDIO_APP);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDOUT_NUMBER, c.SDL_PROCESS_STDIO_NULL);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDERR_NUMBER, c.SDL_PROCESS_STDIO_INHERITED);
    servidor = c.SDL_CreateProcessWithProperties(props);
}

fn mandar(comptime fmt: []const u8, args: anytype) void {
    const p = servidor orelse return;
    var b: [512]u8 = undefined;
    const l = std.fmt.bufPrint(&b, fmt ++ "\n", args) catch return;
    const in = c.SDL_GetProcessInput(p) orelse return;
    _ = c.SDL_WriteIO(in, l.ptr, l.len);
    _ = c.SDL_FlushIO(in);
}

fn derrubarServidor() void {
    const p = servidor orelse return;
    servidor = null;
    mandar("quit", .{});
    if (c.SDL_GetProcessInput(p)) |in| _ = c.SDL_CloseIO(in);
    var tries: u32 = 0;
    while (!c.SDL_WaitProcess(p, false, null)) : (tries += 1) {
        if (tries == 100) _ = c.SDL_KillProcess(p, true);
        c.SDL_Delay(10);
    }
    c.SDL_DestroyProcess(p);
}

fn servidorKde(_: *App) void {
    subirServidor("actions,body,body-hyperlinks,body-markup,inline-reply,x-kde-urls");
}
fn servidorPronto(_: *App) bool {
    return servidor != null and tem(ler("notif-servidor.log"), "pronto\t");
}
fn tentarDeNovo(_: *App) void {
    notif_dbus.tentarDeNovo();
}

// --- KDE: os botões e a caixa ------------------------------------------------------

var dm_b: Id = 0;
var id_b: u32 = 0;
fn chegaKde(app: *App) void {
    dm_b = chegar(app, dm, "oi pela notificação <b>&</b>");
}
fn notifyKde(_: *App) bool {
    const l = notificada("oi pela notifica") orelse return false;
    id_b = l.id;
    return notif_dbus.estado() == .pronto and notif_dbus.caps().resposta and
        // O corpo com marcação: o texto da mensagem vai escapado.
        tem(l.corpo, "oi pela notificação &lt;b&gt;&amp;&lt;/b&gt;") and
        std.mem.startsWith(u8, l.acoes, "default=") and
        temFmt(l.acoes, "|mark-read:{d}:{d}=", .{ dm, dm_b }) and tem(l.acoes, "|inline-reply=") and
        tem(l.dicas, "desktop-entry=dev.larpercord") and tem(l.dicas, "category=im.received") and
        tem(l.dicas, "x-kde-reply-placeholder-text=");
}

fn paraBandeja(app: *App) void {
    tray.fake = true;
    app.st.settings.close_to_tray = true;
    var e = std.mem.zeroes(c.SDL_Event);
    e.type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
    e.window.windowID = c.SDL_GetWindowID(app.win.window);
    _ = c.SDL_PushEvent(&e);
}
fn naBandeja(app: *App) bool {
    return app.win.flags() & c.SDL_WINDOW_HIDDEN != 0 and app.in_tray;
}

var dm_c: Id = 0;
var id_c: u32 = 0;
fn chegaSegunda(app: *App) void {
    dm_c = chegar(app, dm, "segunda da conversa");
}
fn notifySegunda(_: *App) bool {
    const l = notificada("segunda da conversa") orelse return false;
    id_c = l.id;
    return id_c != id_b;
}

var acks0: u64 = 0;
fn marcarLida(_: *App) void {
    acks0 = gw.sent.acks.load(.monotonic);
    mandar("action {d} mark-read:{d}:{d}", .{ id_c, dm, dm_c });
}
fn lidaNaBandeja(app: *App) bool {
    const cs = app.store.channel(dm) orelse return false;
    return !cs.info.unread and app.st.filtros.count(dm) == 0 and gw.sent.acks.load(.monotonic) > acks0 and
        gw.sent.ack_channel.load(.monotonic) == dm and naBandeja(app);
}
fn fechouAOutra(_: *App) bool {
    var b: [32]u8 = undefined;
    return tem(ler("notif-servidor.log"), std.fmt.bufPrint(&b, "close\t{d}\n", .{id_b}) catch return false);
}

// --- Responder pela caixa ------------------------------------------------------------

var dm_d: Id = 0;
var id_d: u32 = 0;
var sends0: u64 = 0;
const resposta = "respondi pela notificação";
fn chegaParaResponder(app: *App) void {
    dm_d = chegar(app, dm, "responde aqui");
}
fn notifyParaResponder(_: *App) bool {
    const l = notificada("responde aqui") orelse return false;
    id_d = l.id;
    return true;
}
fn responderKde(_: *App) void {
    sends0 = gw.sent.sends.load(.monotonic);
    mandar("reply {d} {s}", .{ id_d, resposta });
}
fn corpoEnviado() []const u8 {
    return gw.sent.view(&gw.sent.send_body, &gw.sent.send_body_len);
}
fn respondeu(app: *App) bool {
    const body = corpoEnviado();
    return gw.sent.sends.load(.monotonic) == sends0 + 1 and tem(body, resposta) and
        temFmt(body, "\"message_reference\":{{\"message_id\":\"{d}\"}}", .{dm_d}) and
        tem(body, "\"replied_user\":true") and naBandeja(app);
}
fn confirmada(app: *App) bool {
    const cs = app.store.channel(dm) orelse return false;
    for (cs.messages.items) |*m| {
        if (m.msg.author == app.store.me and !m.pending and m.msg.reply_to == dm_d and std.mem.eql(u8, m.msg.content, resposta)) return true;
    }
    return false;
}

var dm_e: Id = 0;
var id_e: u32 = 0;
fn semPing(app: *App) void {
    app.st.reply_ping = false;
    dm_e = chegar(app, dm, "responde sem mencionar");
}
fn notifySemPing(_: *App) bool {
    const l = notificada("responde sem mencionar") orelse return false;
    id_e = l.id;
    return true;
}
fn responderSemPing(_: *App) void {
    sends0 = gw.sent.sends.load(.monotonic);
    mandar("reply {d} sem mencionar ninguém", .{id_e});
}
fn respondeuSemPing(app: *App) bool {
    const body = corpoEnviado();
    const ok = gw.sent.sends.load(.monotonic) == sends0 + 1 and tem(body, "sem mencionar ninguém") and tem(body, "\"replied_user\":false");
    if (ok) app.st.reply_ping = true;
    return ok;
}

// --- A resposta que não pode sair ---------------------------------------------------

var dm_f: Id = 0;
var id_f: u32 = 0;
var nao0: u32 = 0;
fn barrar(app: *App) void {
    // O Discord disse para esperar (429): a caixa de texto também não mandaria.
    app.events.push(.{ .send_cooldown = .{ .channel = barrada, .ms = 600_000 } });
    dm_f = chegar(app, barrada, "essa não vai dar");
}
fn notifyBarrada(_: *App) bool {
    const l = notificada("essa não vai dar") orelse return false;
    id_f = l.id;
    return true;
}
fn responderBarrada(_: *App) void {
    sends0 = gw.sent.sends.load(.monotonic);
    nao0 = an.medidas.nao_enviadas;
    mandar("reply {d} não vai sair", .{id_f});
}
var id_falha: u32 = 0;
fn naoSaiu(app: *App) bool {
    if (gw.sent.sends.load(.monotonic) != sends0 or an.medidas.nao_enviadas != nao0 + 1) return false;
    // A notificação da falha, sem botões; o clique abre a conversa para tentar de novo.
    var it = std.mem.splitScalar(u8, ler("notif-servidor.log"), '\n');
    while (it.next()) |l| {
        var f = std.mem.splitScalar(u8, l, '\t');
        if (!std.mem.eql(u8, f.next() orelse continue, "notify")) continue;
        const id = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        const titulo = f.next() orelse continue;
        _ = f.next();
        const acoes = f.next() orelse continue;
        if (std.mem.eql(u8, titulo, i18n.tr("Resposta não enviada", "Reply not sent")) and std.mem.startsWith(u8, acoes, "default=") and !tem(acoes, "|")) id_falha = id;
    }
    return id_falha != 0 and naBandeja(app);
}
fn virouRascunho(app: *App) bool {
    const r = app.st.drafts.get(barrada) orelse return false;
    return tem(r, "não vai sair");
}
fn clicarFalha(_: *App) void {
    mandar("action {d} default", .{id_falha});
}
fn falhaAbreACaixa(app: *App) bool {
    return !naBandeja(app) and app.st.activeChannel() == barrada and app.st.reply_to == dm_f and
        tem(std.mem.sliceTo(&app.st.input, 0), "não vai sair");
}

// --- O clique, com a ficha do Wayland -------------------------------------------------

var men_g: Id = 0;
var id_g: u32 = 0;
fn chegaMencao(app: *App) void {
    men_g = chegar(app, memes, "<@1000> olha esse meme");
}
fn notifyMencao(_: *App) bool {
    const l = notificada("olha esse meme") orelse return false;
    id_g = l.id;
    return tem(l.titulo, "#") and temFmt(l.acoes, "|mark-read:{d}:{d}=", .{ memes, men_g });
}
fn clicar(_: *App) void {
    mandar("token {d} qa-ficha-1", .{id_g});
    mandar("action {d} default", .{id_g});
}
fn abriuNaMensagem(app: *App) bool {
    const ficha = an.medidas.ficha[0..an.medidas.ficha_len];
    return !naBandeja(app) and app.st.activeChannel() == memes and std.mem.eql(u8, ficha, "qa-ficha-1") and
        (app.st.jump == men_g or app.st.jump == 0);
}

// --- Avisos sem botões ----------------------------------------------------------------

fn lembrete(app: *App) void {
    app.desktopNotify("Lembrete do QA", "um lembrete sem botões");
}
fn soOClique(_: *App) bool {
    const l = notificada("um lembrete sem botões") orelse return false;
    return std.mem.eql(u8, l.titulo, "Lembrete do QA") and std.mem.startsWith(u8, l.acoes, "default=") and !tem(l.acoes, "|") and
        !tem(l.dicas, "category=") and !tem(l.dicas, "x-kde-reply");
}
fn desligar(app: *App) void {
    app.st.settings.notif_reply = false;
    _ = chegar(app, dm, "botões desligados");
}
fn semBotoesDesligado(app: *App) bool {
    const l = notificada("botões desligados") orelse return false;
    const ok = std.mem.startsWith(u8, l.acoes, "default=") and !tem(l.acoes, "|") and !tem(l.dicas, "x-kde-reply");
    if (ok) app.st.settings.notif_reply = true;
    return ok;
}

// --- GNOME: botões sem caixa -----------------------------------------------------------

fn servidorGnome(_: *App) void {
    derrubarServidor();
    subirServidor("actions,body,body-markup,persistence,sound");
}
fn perguntouDeNovo(_: *App) bool {
    const cp = notif_dbus.caps();
    return notif_dbus.estado() == .pronto and cp.acoes and !cp.resposta;
}

var dm_h: Id = 0;
var id_h: u32 = 0;
fn chegaGnome(app: *App) void {
    dm_h = chegar(app, dm, "agora no gnome");
}
fn notifyGnome(_: *App) bool {
    const l = notificada("agora no gnome") orelse return false;
    id_h = l.id;
    return temFmt(l.acoes, "|mark-read:{d}:{d}=", .{ dm, dm_h }) and temFmt(l.acoes, "|reply:{d}:{d}=", .{ dm, dm_h }) and
        !tem(l.acoes, "inline-reply") and !tem(l.dicas, "x-kde-reply");
}
fn responderGnome(_: *App) void {
    mandar("action {d} reply:{d}:{d}", .{ id_h, dm, dm_h });
}
fn caixaPronta(app: *App) bool {
    return !naBandeja(app) and app.st.activeChannel() == dm and app.st.reply_to == dm_h;
}

// --- Sem servidor ----------------------------------------------------------------------

fn semServidor(_: *App) void {
    derrubarServidor();
}
fn ficouSemServidor(_: *App) bool {
    return notif_dbus.estado() == .sem_servidor;
}
var ns0: u32 = 0;
fn chegaSemServidor(app: *App) void {
    ns0 = an.medidas.pelo_notify_send;
    _ = chegar(app, dm, "de volta ao notify-send");
}
fn voltouAoNotifySend(_: *App) bool {
    return an.medidas.pelo_notify_send == ns0 + 1 and tem(ler("notify-send.log"), "de volta ao notify-send");
}

fn limpar(app: *App) void {
    derrubarServidor();
    if (daemon) |p| {
        _ = c.SDL_KillProcess(p, false);
        _ = c.SDL_WaitProcess(p, true, null);
        c.SDL_DestroyProcess(p);
        daemon = null;
    }
    _ = c.unsetenv("DBUS_SESSION_BUS_ADDRESS");
    an.qa_ligado = false;
    app.qa_blur = false;
}

pub const ops_linux = [_]Op{
    run(preparar),
    s("notificações: sem sessão D-Bus, o notify-send de antes"),
    run(chegaSemBarramento),
    expect("a DM sai pelo notify-send, com o título e o texto", peloNotifySend),

    s("notificações: o servidor do KDE (com caixa de texto)"),
    run(subirBarramento),
    expect("o dbus-daemon particular sobe (precisa do dbus-daemon instalado)", barramentoDePe),
    run(servidorKde),
    expect("o servidor de mentira fica com org.freedesktop.Notifications", servidorPronto),
    run(tentarDeNovo),
    run(chegaKde),
    expect("a DM vira um Notify com o clique, Marcar como lida e a caixa do KDE, e o texto escapado", notifyKde),

    s("notificações: Marcar como lida com a janela na bandeja"),
    run(paraBandeja),
    expect("a janela vai para a bandeja", naBandeja),
    run(chegaSegunda),
    expect("a segunda mensagem da conversa é outra notificação", notifySegunda),
    run(marcarLida),
    expect("Marcar como lida lê a conversa (o ack sai) sem mostrar a janela", lidaNaBandeja),
    expect("a outra notificação da conversa fecha junto (CloseNotification)", fechouAOutra),

    s("notificações: responder pela caixa"),
    run(chegaParaResponder),
    expect("a notificação da mensagem chega", notifyParaResponder),
    run(responderKde),
    expect("a resposta sai como resposta à mensagem, mencionando o autor (a escolha da caixa), sem mostrar a janela", respondeu),
    expect("e aparece confirmada na conversa", confirmada),
    run(semPing),
    expect("a notificação chega", notifySemPing),
    run(responderSemPing),
    expect("com o \"@ DESLIGADO\" na caixa, a resposta pela notificação também não menciona", respondeuSemPing),

    s("notificações: a resposta que não pode sair"),
    run(barrar),
    expect("a notificação da conversa barrada chega", notifyBarrada),
    run(responderBarrada),
    expect("com o modo lento valendo, nada sai e outra notificação diz que a resposta não foi enviada", naoSaiu),
    expect("o texto vira o rascunho da conversa", virouRascunho),
    run(clicarFalha),
    expect("o clique nela abre a conversa com a resposta pronta e o texto na caixa", falhaAbreACaixa),
    run(paraBandeja),
    expect("de volta à bandeja", naBandeja),

    s("notificações: o clique abre a conversa, com a ficha do Wayland"),
    run(chegaMencao),
    expect("a menção num canal vira um Notify com o nome do canal e os botões", notifyMencao),
    run(clicar),
    expect("o clique traz a janela da bandeja na conversa, pulando para a mensagem, com a ficha que veio antes", abriuNaMensagem),

    s("notificações: avisos sem botões"),
    run(lembrete),
    expect("lembrete, chamada, versão nova: só o clique, sem botões nem caixa", soOClique),
    run(desligar),
    expect("com \"Responder pela notificação\" desligado, a DM vem só com o clique", semBotoesDesligado),

    s("notificações: o servidor do GNOME (botões sem caixa)"),
    run(servidorGnome),
    expect("o novo servidor fica com o nome", servidorPronto),
    expect("o app pergunta de novo ao servidor que entrou: botões, sem caixa", perguntouDeNovo),
    run(paraBandeja),
    expect("a janela vai para a bandeja", naBandeja),
    run(chegaGnome),
    expect("a DM vem com Marcar como lida e Responder, sem a caixa", notifyGnome),
    run(responderGnome),
    expect("Responder traz a janela na conversa com a resposta pronta na caixa", caixaPronta),

    s("notificações: o servidor some"),
    run(semServidor),
    expect("sem ninguém com o nome, o app fica sem servidor", ficouSemServidor),
    run(chegaSemServidor),
    expect("e a próxima sai pelo notify-send", voltouAoNotifySend),
    run(limpar),
};

// --- Windows ---------------------------------------------------------------------------

var saidas0: u32 = 0;
fn prepararWin(app: *App) void {
    an.qa_ligado = true;
    app.qa_blur = true;
    saidas0 = notif_win.medidas.mostrados + an.medidas.pelo_balao;
    _ = chegar(app, dm, "uma DM no Windows");
}
fn saiuNoWindows(_: *App) bool {
    return notif_win.medidas.mostrados + an.medidas.pelo_balao >= saidas0 + 1;
}
fn lembreteWin(app: *App) void {
    saidas0 = notif_win.medidas.mostrados + an.medidas.pelo_balao;
    app.desktopNotify("Lembrete do QA", "um lembrete no Windows");
}
fn fimWin(app: *App) void {
    std.debug.print("[notificação] avisos do WinRT: {d}, recusados: {d}, pelo balão: {d}\n", .{ notif_win.medidas.mostrados, notif_win.medidas.recusados, an.medidas.pelo_balao });
    an.qa_ligado = false;
    app.qa_blur = false;
}

pub const ops_windows = [_]Op{
    s("notificações (Windows)"),
    run(prepararWin),
    expect("a DM sai pelo aviso do WinRT ou, sem ele, pelo balão de antes, e nada cai", saiuNoWindows),
    run(lembreteWin),
    expect("o aviso sem botões também sai", saiuNoWindows),
    run(fimWin),
};

pub const ops = if (sys.windows) ops_windows else ops_linux;
