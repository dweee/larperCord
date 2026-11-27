//! QA do Inspetor (src/inspect/): F12 abre encaixado à direita e o app passa a caber no
//! resto; a aba Elementos grava o quadro (os pedaços do layout com a linha do tema, os
//! textos, os itens do ImGui); escolher um elemento na tela não clica no app e mostra o
//! que ele é; os comandos acham, clicam e digitam pelo robô; a Rede e o Gateway mostram
//! o que foi gravado sem o token; os Eventos registram as ações; Desempenho e Estado
//! desenham; encaixar embaixo e solto mudam o espaço do app; e fechado não grava nada.
//! A demonstração não tem rede: os pedidos e os quadros do gateway entram pelo próprio
//! registro, como a rede gravaria.
//!
//! `QA_SUITE=inspetor` roda isto.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const ui = @import("inspect/ui.zig");
const doca = @import("inspect/doca.zig");
const cap = @import("inspect/captura.zig");
const reg = @import("inspect/registros.zig");
const cmds = @import("inspect/comandos.zig");
const curl_insp = @import("inspect/curl_insp.zig");
const Id = types.Id;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}

const g0: Id = gw.guildId(0);

fn openGuild0(app: *App) void {
    app.handle(.{ .select_guild = g0 });
}
fn onText(app: *App) bool {
    const ch = app.st.activeChannel() orelse return false;
    const cs = app.store.channel(ch) orelse return false;
    return app.st.guild == g0 and cs.history == .loaded and qa.find("composer") != null;
}

// --- Abrir ---------------------------------------------------------------------

var chat_right_before: f32 = 0;
/// Largo o bastante para as sete abas caberem na barra (mais estreito, as que sobram vão para o "»").
fn wide(_: *App) void {
    doca.largura = 820;
}
fn rememberChat(_: *App) void {
    const r = qa.find("composer") orelse return;
    chat_right_before = r.right();
}
fn openDocked(_: *App) bool {
    const comp = qa.find("composer") orelse return false;
    return doca.aberto and doca.lado == .direita and reg.gravando() and doca.area.w >= 300 and
        comp.right() <= doca.area.x + 1 and comp.right() < chat_right_before - 100 and qa.find("insp-tab:elementos") != null;
}

// --- Elementos -------------------------------------------------------------------

fn frameCaptured(_: *App) bool {
    const f = cap.last() orelse return false;
    var messages = false;
    var channels = false;
    var line_ok = false;
    for (f.scopes.items) |sc| {
        if (std.mem.eql(u8, sc.name, "messages")) messages = true;
        if (std.mem.eql(u8, sc.name, "channel-list")) channels = true;
        if (sc.component and sc.line > 0) line_ok = true;
    }
    var texts: usize = 0;
    var items: usize = 0;
    for (f.els.items) |e| switch (e.kind) {
        .text => texts += 1,
        .item => items += 1,
        else => {},
    };
    return messages and channels and line_ok and texts > 50 and items > 20 and f.marks.items.len > 20;
}

fn hasText(f: *const cap.Frame, want: []const u8) bool {
    for (f.els.items) |e| if (e.kind == .text and std.mem.indexOf(u8, f.str(e.str), want) != null) return true;
    return false;
}
fn demoTextsCaptured(app: *App) bool {
    const f = cap.last() orelse return false;
    const ch = app.st.activeChannel() orelse return false;
    const cs = app.store.channel(ch) orelse return false;
    return hasText(f, cs.info.name);
}

fn shotElements(app: *App) void {
    _ = app.win.screenshot("qa-out/inspetor-elementos.png");
}

// --- Escolher na tela ------------------------------------------------------------

/// Um canal de texto do servidor que não é o aberto (clicar nele trocaria a conversa).
var other: Id = 0;
fn tOther(_: *App, b: []u8) []const u8 {
    return std.fmt.bufPrint(b, "channel:{d}", .{other}) catch "";
}
var active_before: Id = 0;
fn pickOther(app: *App) void {
    active_before = app.st.activeChannel() orelse 0;
    for (app.store.channelsOf(g0)) |id| {
        const cs = app.store.channel(id) orelse continue;
        if (id != active_before and cs.info.kind == .text) {
            other = id;
            break;
        }
    }
}
fn picking(_: *App) bool {
    return ui.picking and other != 0;
}
fn pickedNotClicked(app: *App) bool {
    const f = cap.last() orelse return false;
    const i = ui.sel.index orelse return false;
    const e = &f.els.items[i];
    const sc = f.scopeOf(e) orelse return false;
    // Escolheu algo da lista de canais, e o canal aberto continua o mesmo.
    return !ui.picking and ui.sel.on and std.mem.eql(u8, sc.name, "channel-list") and app.st.activeChannel() == active_before;
}
fn pickedHasThemeLine(_: *App) bool {
    const f = cap.last() orelse return false;
    const i = ui.sel.index orelse return false;
    const sc = f.scopeOf(&f.els.items[i]) orelse return false;
    return sc.line > 0 and std.mem.eql(u8, @import("inspect/aba_elementos.zig").themeFile(), "classico.kdl");
}
fn shotPicked(app: *App) void {
    _ = app.win.screenshot("qa-out/inspetor-escolhido.png");
}

/// Um texto escolhido: a cor tem o nome no tema e o contraste com o fundo é calculado.
/// A cor do corpo de uma mensagem: a `text` do tema ou um tom perto dela (o horário é
/// `muted`, um cinza que de propósito fica abaixo do AA).
fn bodyColor(tok: []const u8) bool {
    return std.mem.eql(u8, tok, "text") or std.mem.eql(u8, tok, "≈ text");
}

fn selectText(app: *App) void {
    const f = cap.last() orelse return;
    // A linha mais longa do corpo de uma mensagem (o selo "NOVAS MENSAGENS" também é claro,
    // mas é branco no vermelho).
    var best: ?usize = null;
    for (f.els.items, 0..) |e, i| {
        const sc = f.scopeOf(&e) orelse continue;
        if (e.kind != .text or !std.mem.eql(u8, sc.name, "messages") or !cap.visible(&e)) continue;
        if (std.mem.indexOfScalar(u8, f.str(e.str), ' ') == null) continue;
        if (!bodyColor(@import("inspect/aba_elementos.zig").tokenName(app.themes.theme_(), e.color))) continue;
        if (best == null or f.str(e.str).len > f.str(f.els.items[best.?].str).len) best = i;
    }
    if (best) |i| ui.select(f, i);
}

fn textHasTokenAndContrast(app: *App) bool {
    const f = cap.last() orelse return false;
    const i = ui.sel.index orelse return false;
    const e = &f.els.items[i];
    if (e.kind != .text) return false;
    const tok = @import("inspect/aba_elementos.zig").tokenName(app.themes.theme_(), e.color);
    const bg = @import("inspect/aba_elementos.zig").fundo(f, i);
    const ratio = @import("inspect/kit.zig").fromU32(e.color).contrast(@import("inspect/kit.zig").fromU32(bg));
    // O classico escuro: texto claro no fundo escuro passa folgado do AA, e os pedaços da
    // linha viraram um texto só (com espaço).
    return bodyColor(tok) and ratio > 4.5 and std.mem.indexOfScalar(u8, f.str(e.str), ' ') != null;
}

// --- Comandos ------------------------------------------------------------------------

var out_buf: [16 * 1024]u8 = undefined;
var out_len: usize = 0;
fn runCmd(app: *App, line: []const u8) cmds.Fim {
    var w = std.Io.Writer.fixed(&out_buf);
    const r = cmds.run(app, line, &w, .ctl);
    out_len = w.buffered().len;
    return r;
}
fn out() []const u8 {
    return out_buf[0..out_len];
}

var find_done = false;
fn cmdFind(app: *App) void {
    const ch = app.st.activeChannel() orelse return;
    const cs = app.store.channel(ch) orelse return;
    find_done = runCmd(app, std.fmt.bufPrint(out_buf[8000..], "find {s}", .{cs.info.name}) catch return) == .pronto;
}
fn findListed(app: *App) bool {
    if (!find_done) {
        cmdFind(app);
        return false;
    }
    return std.mem.indexOf(u8, out(), "text.") != null and std.mem.indexOf(u8, out(), "#") != null;
}

var el_done = false;
fn elJson(app: *App) bool {
    if (!el_done) {
        el_done = runCmd(app, "el qa:composer") == .pronto;
        return false;
    }
    return std.mem.startsWith(u8, out(), "{\"index\":") and std.mem.indexOf(u8, out(), "\"scope\":\"composer\"") != null;
}

var click_sent = false;
fn cmdClickOther(app: *App) bool {
    if (!click_sent) {
        var b: [64]u8 = undefined;
        click_sent = runCmd(app, std.fmt.bufPrint(&b, "click qa:channel:{d}", .{other}) catch return false) == .pronto;
        return false;
    }
    // Pela fila do robô, em alguns quadros: o canal abre de verdade (a demonstração deixa).
    return app.st.activeChannel() == other;
}

fn ctlTypeRefusedOutsideDemo(app: *App) bool {
    app.store.demo = false;
    defer app.store.demo = true;
    cmds.ctl_mexe = false;
    _ = runCmd(app, "type oi");
    return std.mem.indexOf(u8, out(), "pelo ctl, clicar e digitar só") != null and !cmds.busy();
}

var typed = false;
fn cmdType(app: *App) bool {
    if (!typed) {
        // O foco na caixa de texto e o texto pelo robô.
        app.st.focus_input = true;
        typed = runCmd(app, "type olá inspetor") == .pronto;
        return false;
    }
    return std.mem.indexOf(u8, std.mem.sliceTo(&app.st.input, 0), "olá inspetor") != null;
}
fn clearInput(app: *App) void {
    @memset(&app.st.input, 0);
    app.st.input_sync = true;
}

// --- Rede e gateway (gravados pelo registro, como a rede gravaria) ---------------------

const fake_token = "QAfaketoken0000000000000.abcdef.ghijklmnopqrstuvwxyz0123";

fn injectNet(_: *App) void {
    var h: std.ArrayList(u8) = .empty;
    defer h.deinit(std.heap.c_allocator);
    var line_buf: [128]u8 = undefined;
    curl_insp.requestLine(&h, std.fmt.bufPrint(&line_buf, "Authorization: {s}", .{fake_token}) catch "");
    curl_insp.requestLine(&h, "Accept: */*");
    const a = reg.net.begin(.api, "GET", "https://discord.com/api/v9/users/@me", h.items, null, "gateway");
    reg.net.end(a, .{ .status = 200, .resp_headers = "HTTP/2 200\nx-ratelimit-remaining: 4\nx-ratelimit-reset-after: 1.0\n", .resp_body = "{\"id\":\"1000\",\"username\":\"qa\",\"flags\":0}", .content_type = "application/json", .http = 20, .t_dns = 1200, .t_connect = 9000, .t_tls = 31000, .t_first = 52000, .t_total = 54000 });
    const b = reg.net.begin(.api, "POST", "https://discord.com/api/v9/channels/1/messages", "Content-Type: application/json\n", "{\"content\":\"oi\"}", "gateway");
    reg.net.end(b, .{ .status = 429, .resp_body = "{\"message\":\"You are being rate limited.\",\"retry_after\":1.2,\"global\":false}", .waited_ms = 1300, .content_type = "application/json" });
    const m = reg.net.begin(.media, "GET", "https://cdn.discordapp.com/avatars/1001/abc.png", "User-Agent: x\n", null, "imagens");
    reg.net.end(m, .{ .status = 200, .resp_len = 4096, .content_type = "image/png" });
}
fn netStoredWithoutToken(_: *App) bool {
    const Ctx = struct { n: usize = 0, leak: bool = false };
    var ctx: Ctx = .{};
    reg.net.each(&ctx, struct {
        fn f(cc: *Ctx, n: *const reg.Net) void {
            cc.n += 1;
            if (std.mem.indexOf(u8, n.req_headers, "QAfaketoken") != null) cc.leak = true;
        }
    }.f);
    return ctx.n >= 3 and !ctx.leak and @import("inspect/aba_rede.zig").failedCount() >= 1;
}
fn shotNet(app: *App) void {
    _ = app.win.screenshot("qa-out/inspetor-rede.png");
}
fn netDetailOpen(_: *App) bool {
    return qa.find("insp-net-sub:response") != null;
}
fn shotNetDetail(app: *App) void {
    _ = app.win.screenshot("qa-out/inspetor-rede-detalhe.png");
}

fn injectGw(_: *App) void {
    var b: [256]u8 = undefined;
    reg.gwOut(.main, std.fmt.bufPrint(&b, "{{\"op\":2,\"d\":{{\"token\":\"{s}\",\"properties\":{{\"os\":\"Windows\"}}}}}}", .{fake_token}) catch "");
    reg.gw.add(.main, .in, "{\"op\":10,\"d\":{\"heartbeat_interval\":41250}}", 10, null, null);
    reg.gw.add(.main, .in, "{\"t\":\"READY\",\"s\":1,\"op\":0,\"d\":{\"v\":9,\"user\":{\"id\":\"1000\"},\"guilds\":[]}}", 0, 1, "READY");
    reg.gw.add(.main, .in, "{\"t\":\"MESSAGE_CREATE\",\"s\":2,\"op\":0,\"d\":{\"content\":\"oi\",\"channel_id\":\"1\"}}", 0, 2, "MESSAGE_CREATE");
    reg.gwOut(.main, "{\"op\":1,\"d\":2}");
    reg.gw.add(.main, .in, "{\"op\":11}", 11, null, null);
    reg.gwOut(.voice, "{\"op\":5,\"d\":{\"speaking\":1,\"delay\":0,\"ssrc\":7}}");
}
fn gwStoredWithoutToken(_: *App) bool {
    const Ctx = struct { n: usize = 0, leak: bool = false, identify_hidden: bool = false };
    var ctx: Ctx = .{};
    reg.gw.each(&ctx, struct {
        fn f(cc: *Ctx, g: *const reg.Gw) void {
            cc.n += 1;
            if (std.mem.indexOf(u8, g.payload, "QAfaketoken") != null) cc.leak = true;
            if (g.op == 2 and std.mem.indexOf(u8, g.payload, "\"token\":\"***") != null) cc.identify_hidden = true;
        }
    }.f);
    return ctx.n >= 7 and !ctx.leak and ctx.identify_hidden;
}
fn gwListHidesHeartbeats(_: *App) bool {
    // 7 quadros, dois são heartbeat (op 1 e 11): a lista mostra 5.
    return qa.find("insp-gw-row:4") != null and qa.find("insp-gw-row:5") == null;
}
fn shotGw(app: *App) void {
    _ = app.win.screenshot("qa-out/inspetor-gateway.png");
}

// --- Eventos, Desempenho, Estado, Console -----------------------------------------------

fn eventsRecorded(_: *App) bool {
    const Ctx = struct { sel: bool = false, ev: bool = false };
    var ctx: Ctx = .{};
    reg.evs.each(&ctx, struct {
        fn f(cc: *Ctx, e: *const reg.Ev) void {
            if (e.kind == .action and std.mem.eql(u8, e.tag, "select_channel")) cc.sel = true;
            if (e.kind == .action and std.mem.eql(u8, e.tag, "open_channel")) cc.sel = true;
            if (e.kind == .event) cc.ev = true;
        }
    }.f);
    return ctx.sel or ctx.ev;
}
fn shotEvents(app: *App) void {
    _ = app.win.screenshot("qa-out/inspetor-eventos.png");
}
fn perfHasSamples(app: *App) bool {
    var b: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&b);
    _ = @import("inspect/aba_desempenho.zig").texto(app, &w);
    return std.mem.indexOf(u8, w.buffered(), "amostras") != null and std.mem.indexOf(u8, w.buffered(), "(abra o Inspetor") == null;
}
fn shotPerf(app: *App) void {
    _ = app.win.screenshot("qa-out/inspetor-desempenho.png");
}
fn stateText(app: *App) bool {
    _ = runCmd(app, "state");
    return std.mem.indexOf(u8, out(), "conexão: ") != null and std.mem.indexOf(u8, out(), "tema: classico") != null;
}
fn shotState(app: *App) void {
    _ = app.win.screenshot("qa-out/inspetor-estado.png");
}
fn consoleTyped(_: *App) bool {
    return qa.find("insp-console-input") != null;
}
fn shotConsole(app: *App) void {
    _ = app.win.screenshot("qa-out/inspetor-console.png");
}
fn logLineCaptured(_: *App) bool {
    std.log.warn("qa do inspetor: linha de aviso", .{});
    const Ctx = struct { ok: bool = false };
    var ctx: Ctx = .{};
    reg.lines.each(&ctx, struct {
        fn f(cc: *Ctx, l: *const reg.Line) void {
            if (l.level == .warn and std.mem.indexOf(u8, l.text, "qa do inspetor") != null) cc.ok = true;
        }
    }.f);
    return ctx.ok;
}

// --- Encaixe e fechar ---------------------------------------------------------------------

fn dockedBottom(_: *App) bool {
    const comp = qa.find("composer") orelse return false;
    return doca.lado == .baixo and comp.bottom() <= doca.area.y + 1;
}
fn shotBottom(app: *App) void {
    _ = app.win.screenshot("qa-out/inspetor-embaixo.png");
}
fn floating(_: *App) bool {
    const comp = qa.find("composer") orelse return false;
    // Solto, o app tem a janela inteira: a caixa de texto volta para onde estava antes de abrir.
    return doca.lado == .solta and @abs(comp.right() - chat_right_before) < 2;
}
fn shotFloating(app: *App) void {
    _ = app.win.screenshot("qa-out/inspetor-solto.png");
}
fn backRight(_: *App) void {
    doca.lado = .direita;
}

var frame_closed: u64 = 0;
fn closedNoCapture(_: *App) bool {
    if (doca.aberto or reg.gravando() or ui.wantsCapture() or cap.on) return false;
    // Fechado, os quadros não são mais gravados.
    const f = cap.last() orelse return true;
    if (frame_closed == 0) frame_closed = f.number;
    return f.number == frame_closed;
}
fn closedStaysClosed(_: *App) bool {
    const f = cap.last() orelse return true;
    return f.number == frame_closed and !cap.on;
}

pub const ops = [_]Op{
    s("inspetor: abrir encaixado"),
    run(openGuild0),
    expect("a conversa do servidor está aberta", onText),
    run(rememberChat),
    run(wide),
    key(c.ImGuiKey_F12),
    expect("F12 abre o Inspetor à direita, gravando, e o app cabe no resto", openDocked),

    s("inspetor: elementos"),
    expect("o quadro gravado tem os pedaços do layout (com a linha do tema), textos, itens e marcas", frameCaptured),
    expect("os textos da conversa aberta estão no quadro", demoTextsCaptured),
    .{ .wait = 200 },
    run(shotElements),

    s("inspetor: escolher na tela"),
    run(pickOther),
    .{ .key = .{ .key = c.ImGuiKey_E, .ctrl = true, .shift = true } },
    expect("Ctrl+Shift+E começa a escolher", picking),
    .{ .hover = .{ .dyn = tOther } },
    .{ .wait = 100 },
    run(shotPicked),
    .{ .click = .{ .dyn = tOther } },
    expect("o clique escolhe um elemento da lista de canais e não abre o canal", pickedNotClicked),
    expect("o escolhido diz o arquivo e a linha do tema", pickedHasThemeLine),
    run(selectText),
    expect("um texto escolhido tem a cor com nome no tema e o contraste com o fundo", textHasTokenAndContrast),

    s("inspetor: comandos"),
    expect("find lista os elementos com o texto", findListed),
    expect("el qa:composer devolve o JSON do elemento", elJson),
    expect("pelo ctl fora da demonstração, digitar é recusado sem a opção", ctlTypeRefusedOutsideDemo),
    expect("click qa:channel:N clica pelo robô e o canal abre", cmdClickOther),
    expect("type digita na caixa de texto pelo robô", cmdType),
    run(clearInput),

    s("inspetor: rede"),
    run(injectNet),
    click("insp-tab:rede"),
    expect("os pedidos ficam gravados sem o Authorization, e o 429 conta como erro", netStoredWithoutToken),
    .{ .wait = 150 },
    run(shotNet),
    click("insp-net-row:0"),
    expect("clicar num pedido abre o detalhe com as abas", netDetailOpen),
    click("insp-net-sub:timing"),
    .{ .wait = 100 },
    run(shotNetDetail),

    s("inspetor: gateway"),
    run(injectGw),
    click("insp-tab:gateway"),
    expect("os quadros ficam gravados com o token do IDENTIFY em asteriscos", gwStoredWithoutToken),
    expect("a lista esconde os heartbeats", gwListHidesHeartbeats),
    click("insp-gw-row:2"),
    .{ .wait = 150 },
    run(shotGw),

    s("inspetor: eventos, console, desempenho e estado"),
    click("insp-tab:eventos"),
    expect("as ações e os eventos do app ficam registrados", eventsRecorded),
    .{ .wait = 100 },
    run(shotEvents),
    click("insp-tab:console"),
    expect("o Console tem a linha de comandos", consoleTyped),
    expect("uma linha de log entra no Console", logLineCaptured),
    click("insp-console-input"),
    .{ .text = "help" },
    key(c.ImGuiKey_Enter),
    .{ .wait = 150 },
    run(shotConsole),
    click("insp-tab:desempenho"),
    .{ .wait = 300 },
    expect("o Desempenho tem as amostras dos quadros", perfHasSamples),
    run(shotPerf),
    click("insp-tab:estado"),
    expect("o Estado diz a conexão e o tema", stateText),
    .{ .wait = 100 },
    run(shotState),

    s("inspetor: encaixar e soltar"),
    click("insp-dock:baixo"),
    expect("embaixo: o app fica com a parte de cima", dockedBottom),
    .{ .wait = 100 },
    run(shotBottom),
    click("insp-dock:solta"),
    expect("solto: o app volta a ter a janela inteira", floating),
    .{ .wait = 100 },
    run(shotFloating),
    run(backRight),

    s("inspetor: fechar"),
    click("insp-close"),
    expect("fechado: não grava a rede nem os quadros", closedNoCapture),
    .{ .wait = 300 },
    expect("e continua sem gravar quadro nenhum", closedStaysClosed),
};
