//! `larpercord ctl`: o app aberto controlado de fora, por scripts e atalhos do sistema.
//! No Linux o SDL não tem atalho global, então o aperte para falar fora da janela é um
//! atalho do compositor chamando `ptt-down` e `ptt-up`. Aqui ficam os comandos e o que
//! cada um faz; o transporte (porta, segredo, threads) é o platform/ctl.zig, e o que não
//! depende do app (enquadramento, JSON, regras), o core/ctl.zig.
//!
//! Protocolo (versão 1). Texto UTF-8, uma linha por vez (\n; um \r antes dele é ignorado).
//!
//!   1. O app escreve "<porta> <segredo>\n" em <configurações>/larpercord/ctl.port, só
//!      para o dono (a demonstração e o QA com LARPER_CTL=1 usam ctl-demo.port), e
//!      escuta em 127.0.0.1:<porta>. O segredo são 32 caracteres hexadecimais, novos a
//!      cada abertura. Quem consegue ler o arquivo é só o mesmo usuário do computador.
//!   2. Quem conecta manda o segredo numa linha, em até 2 s. Errado: "ERR auth …" e a
//!      conexão fecha. Certo: a resposta "OK" com o corpo "larpercord-ctl 1".
//!   3. Depois, um comando por linha: `nome arg arg…`, separados por espaço (até 4 KB e
//!      16 partes). Cada comando tem uma resposta, na ordem, e a conexão fica aberta
//!      para o próximo; sem nada por 60 s, ela fecha.
//!   4. Toda resposta é a linha "OK" ou "ERR <código> <mensagem>", as linhas do corpo e
//!      uma linha só com ".". Uma linha do corpo que começa com "." vai com mais um "."
//!      na frente (quem lê tira). O corpo pode ter qualquer tamanho: a interface monta,
//!      e a thread da conexão manda aos pedaços. Os códigos estão em core/ctl.zig
//!      (`Code`) e não mudam entre versões; a mensagem é em inglês, para gente ler.
//!   5. `watch [json|waybar|text]` responde "OK", a linha de agora e uma linha a cada
//!      mudança, sem o "." do fim, até o app fechar ou a opção ser desligada (aí vem o
//!      "." e a conexão fecha). A conexão do watch não aceita outros comandos.
//!   6. A interface tem `ctl.reply_ms` (5 s) para responder; passou disso, vem
//!      "ERR timeout …" e a conexão continua. Até `ctl.max_clients` (8) conexões ao
//!      mesmo tempo; a próxima recebe "ERR busy …".
//!
//! Comando novo: uma linha em `commands` e uma função `fn (app, args, out) Error!void`.
//! Ela roda na thread da interface, no meio dos eventos do laço (App.run, `.ctl`), nunca
//! dentro de um quadro: vale com a janela escondida na bandeja. Escreve o corpo em `out`
//! ou volta `out.fail(código, texto)`. Uma resposta que precise de um quadro desenhado
//! (um print da tela, por exemplo) teria que guardar o pedido e chamar `ctl.finish`
//! depois, dentro de `ctl.reply_ms`.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const ctl = @import("platform/ctl.zig");
const proto = @import("core/ctl.zig");
const links = @import("core/links.zig");
const types = @import("core/types.zig");
const i18n = @import("ui/i18n.zig");
const voz_audio = @import("net/voz_audio.zig");

const alloc = std.heap.c_allocator;
const Id = types.Id;

pub const Error = error{ Failed, OutOfMemory };

/// Onde o comando escreve a resposta.
pub const Out = struct {
    req: *ctl.Request,
    /// A resposta ainda não está pronta (um comando do Inspetor que precisa de um quadro):
    /// o pedido fica guardado e é respondido depois, dentro de `ctl.reply_ms`.
    hold: bool = false,

    pub fn list(o: *Out) *std.ArrayList(u8) {
        return &o.req.body;
    }

    pub fn write(o: *Out, s: []const u8) Error!void {
        try o.req.body.appendSlice(alloc, s);
    }

    pub fn print(o: *Out, comptime fmt: []const u8, args: anytype) Error!void {
        try o.req.body.print(alloc, fmt, args);
    }

    /// Erro com o código e, se não vazia, uma mensagem no lugar da de sempre (em inglês).
    pub fn fail(o: *Out, code: proto.Code, text: []const u8) error{Failed} {
        o.req.err = .{ .code = code, .text = text };
        return error.Failed;
    }
};

pub const Command = struct {
    name: []const u8,
    run: *const fn (app: *App, args: *const proto.Args, out: *Out) Error!void,
    /// Os argumentos, para a ajuda.
    usage: []const u8 = "",
    pt: []const u8,
    en: []const u8,
    /// Mexe no que está na tela: o laço desenha um quadro depois.
    redraw: bool = false,
};

pub const commands = [_]Command{
    .{ .name = "status", .run = status, .pt = "conexão, conta, call e não lidas, em JSON", .en = "connection, account, call and unread, as JSON" },
    .{ .name = "unread", .run = unread, .pt = "as contas de não lidas, em JSON", .en = "unread counts, as JSON" },
    .{ .name = "mute", .run = mute, .redraw = true, .pt = "muta o microfone", .en = "mutes the microphone" },
    .{ .name = "unmute", .run = unmute, .redraw = true, .pt = "desmuta o microfone", .en = "unmutes the microphone" },
    .{ .name = "toggle-mute", .run = toggleMute, .redraw = true, .pt = "muta ou desmuta (como Ctrl+Shift+M)", .en = "mutes or unmutes (like Ctrl+Shift+M)" },
    .{ .name = "deafen", .run = deafen, .redraw = true, .pt = "ensurdece (sem ouvir nem falar)", .en = "deafens (no sound in or out)" },
    .{ .name = "undeafen", .run = undeafen, .redraw = true, .pt = "volta a ouvir", .en = "undeafens" },
    .{ .name = "toggle-deafen", .run = toggleDeafen, .redraw = true, .pt = "ensurdece ou volta (como Ctrl+Shift+D)", .en = "deafens or undeafens (like Ctrl+Shift+D)" },
    .{ .name = "ptt-down", .run = pttDown, .redraw = true, .pt = "aperta o aperte para falar (até o ptt-up)", .en = "presses push to talk (until ptt-up)" },
    .{ .name = "ptt-up", .run = pttUp, .redraw = true, .pt = "solta o aperte para falar", .en = "releases push to talk" },
    .{ .name = "ptt-toggle", .run = pttToggle, .redraw = true, .pt = "aperta ou solta (atalhos sem o soltar da tecla)", .en = "presses or releases (for shortcuts without a key release)" },
    .{ .name = "show", .run = show, .redraw = true, .pt = "mostra a janela (também da bandeja)", .en = "shows the window (also from the tray)" },
    .{ .name = "hide", .run = hide, .redraw = true, .pt = "esconde na bandeja (sem bandeja, minimiza)", .en = "hides to the tray (without a tray, minimizes)" },
    .{ .name = "toggle", .run = toggle, .redraw = true, .pt = "mostra ou esconde, como o clique no ícone da bandeja", .en = "shows or hides, like clicking the tray icon" },
    .{ .name = "open", .run = open, .redraw = true, .usage = "<link | id>", .pt = "abre um link do Discord ou o ID de um canal", .en = "opens a Discord link or a channel ID" },
    .{ .name = "mentions", .run = mentions, .usage = "[n]", .pt = "as DMs não lidas e as menções, com o começo de cada mensagem, em JSON", .en = "unread DMs and mentions, with the start of each message, as JSON" },
    .{ .name = "channels", .run = channels, .pt = "servidores, canais e DMs com as não lidas, em JSON (para um lançador)", .en = "servers, channels and DMs with unread counts, as JSON (for a launcher)" },
    .{ .name = "presence", .run = presence, .redraw = true, .usage = "<online|idle|dnd|invisible>", .pt = "troca o seu status", .en = "changes your status" },
    .{ .name = "volume", .run = volume, .redraw = true, .usage = "<id> <0-200>", .pt = "o volume de alguém na call, em porcentagem (como o mixer)", .en = "someone's volume in the call, in percent (like the mixer)" },
    .{ .name = "inspect", .run = inspect, .redraw = true, .usage = "<comando>", .pt = "o Inspetor: achar e clicar elementos, a árvore, a rede, o log… (inspect help)", .en = "the Inspector: find and click elements, the tree, the network, the log… (inspect help)" },
    .{ .name = "watch", .run = watch, .usage = "[--waybar | --format json|waybar|text]", .pt = "uma linha a cada mudança (status, não lidas, call)", .en = "one line per change (status, unread, call)" },
    .{ .name = "help", .run = help, .pt = "esta lista", .en = "this list" },
};

fn find(name: []const u8) ?*const Command {
    for (&commands) |*cmd| if (std.mem.eql(u8, cmd.name, name)) return cmd;
    return null;
}

/// A lista de comandos para a ajuda (a linha de comando e o `help`), no idioma de agora.
pub fn writeHelp(out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    for (commands) |cmd| {
        var head: [64]u8 = undefined;
        const left = std.fmt.bufPrint(&head, "{s} {s}", .{ cmd.name, cmd.usage }) catch cmd.name;
        // Os comentários alinhados numa coluna; um comando comprido vai para a linha de baixo.
        if (left.len < 22) {
            try out.print(gpa, "  {s: <22}", .{left});
        } else try out.print(gpa, "  {s}\n{s: <24}", .{ left, "" });
        try out.print(gpa, "{s}\n", .{i18n.tr(cmd.pt, cmd.en)});
    }
}

// --- O laço do app ----------------------------------------------------------------------

/// A opção como estava na última volta do laço (nulo: ainda não olhou).
var wanted: ?bool = null;

/// A porta abre e fecha com Configurações → Avançado → Controle externo. Roda a cada
/// volta do laço; só faz algo quando a opção muda.
pub fn sync(app: *App) void {
    const want = app.opts.ctl != .off and app.st.settings.external_control;
    if (wanted == want) return;
    wanted = want;
    if (!want) return stop();
    var buf: [512]u8 = undefined;
    const path = ctl.portPath(&buf, app.opts.ctl == .demo) orelse return;
    if (!ctl.start(app.win.wake_type, path)) std.log.warn("controle externo: não deu para abrir a porta em 127.0.0.1", .{});
}

/// Fecha a porta (a opção desligou, ou o app está fechando).
pub fn stop() void {
    ctl.stop();
    for (&last_line) |*l| l.clearAndFree(alloc);
    last_key = 0;
}

/// Os pedidos que chegaram (`Wake.ctl`). Verdadeiro: algum mexeu no que está na tela.
pub fn pump(app: *App) bool {
    var list: std.ArrayList(*ctl.Request) = .empty;
    defer list.deinit(alloc);
    ctl.take(&list);
    var redraw = false;
    for (list.items) |req| {
        var out: Out = .{ .req = req };
        // O Inspetor recebe a linha inteira (um `type` pode ter mais palavras que as 16 partes).
        if (inspectLine(req.line) != null) {
            inspect(app, undefined, &out) catch |e| switch (e) {
                error.Failed => {},
                error.OutOfMemory => req.err = .{ .code = .failed, .text = "out of memory" },
            };
            redraw = true;
            if (!out.hold) ctl.finish(req);
            continue;
        }
        const args = proto.Args.parse(req.line) orelse blk: {
            req.err = .{ .code = .usage, .text = "too many arguments" };
            break :blk null;
        };
        if (args) |a| if (find(a.name())) |cmd| {
            cmd.run(app, &a, &out) catch |e| switch (e) {
                error.Failed => {},
                error.OutOfMemory => req.err = .{ .code = .failed, .text = "out of memory" },
            };
            redraw = redraw or cmd.redraw;
        } else {
            req.err = .{ .code = .unknown };
        };
        ctl.finish(req);
    }
    return redraw;
}

// --- watch -------------------------------------------------------------------------------

/// O que o `watch` acompanha, num número: só quando ele muda o status é montado de novo.
var last_key: u64 = 0;
/// A última linha mandada em cada formato (o waybar não muda com a janela minimizada,
/// por exemplo: a linha repetida não vai).
var last_line: [3]std.ArrayList(u8) = .{ .empty, .empty, .empty };

/// Antes de o laço dormir: se alguém está no `watch` e algo que ele mostra mudou, a
/// linha nova vai. Sem ninguém olhando, só uma leitura atômica.
pub fn notify(app: *App) void {
    if (!ctl.watching()) return;
    const k = key(app);
    if (k == last_key) return;
    last_key = k;
    const snap = snapshot(app);
    const want = ctl.formatsWatched();
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    for (std.enums.values(proto.Format)) |fmt| {
        if (!want.contains(fmt)) continue;
        line.clearRetainingCapacity();
        render(&snap, fmt, &line) catch continue;
        const last = &last_line[@backingInt(fmt)];
        if (std.mem.eql(u8, last.items, line.items)) continue;
        last.clearRetainingCapacity();
        last.appendSlice(alloc, line.items) catch {};
        ctl.broadcast(fmt, line.items);
    }
}

/// Tudo de que o status depende e que muda sem passar pelo Store (`rev`).
fn key(app: *App) u64 {
    const st = &app.st;
    const store = &app.store;
    var mention_sum: u32 = 0;
    var it = st.filtros.mentions.valueIterator();
    while (it.next()) |v| mention_sum +%= v.*;
    const parts = [_]u64{
        store.rev,
        @backingInt(store.connection),
        @intFromBool(store.ready),
        @intFromBool(app.net == .none),
        store.me,
        st.voice orelse 0,
        st.voice_guild,
        @backingInt(st.voice_status),
        @intFromBool(st.muted),
        @intFromBool(st.deafened),
        @intFromBool(st.settings.voice_ptt),
        @intFromBool(voz_audio.pttKey()),
        mention_sum,
        st.muted_channels.count(),
        @intFromBool(app.in_tray),
        app.win.flags() & (c.SDL_WINDOW_HIDDEN | c.SDL_WINDOW_MINIMIZED),
        st.settings.my_status,
        // O ping muda a cada heartbeat; de 10 em 10 ms basta para a barra.
        store.latency_ms / 10,
        speakingKey(app),
    };
    return std.hash.Wyhash.hash(1, std.mem.asBytes(&parts)) | 1;
}

/// Quem está na call e quem fala agora, num número (o `watch` manda uma linha quando muda).
fn speakingKey(app: *App) u64 {
    const ch = app.st.voice orelse return 0;
    const cs = app.store.channel(ch) orelse return 0;
    const now: i64 = @intCast(c.SDL_GetTicks());
    var h = std.hash.Wyhash.init(ch);
    for (cs.voice_members.items) |uid| {
        h.update(std.mem.asBytes(&uid));
        const on = app.store.isSpeaking(uid, now);
        h.update(std.mem.asBytes(&on));
        const f = app.store.voiceFlags(uid);
        h.update(std.mem.asBytes(&f));
        // O volume de cada um também: a barra que mexeu no volume vê o valor novo.
        const v = app.st.volumes.volume(uid);
        h.update(std.mem.asBytes(&v));
    }
    return h.final();
}

fn render(s: *const proto.Snapshot, fmt: proto.Format, out: *std.ArrayList(u8)) !void {
    switch (fmt) {
        .json => try proto.statusJson(out, alloc, s),
        .waybar, .text => {
            var hb: [160]u8 = undefined;
            var cb: [400]u8 = undefined;
            var nb: [200]u8 = undefined;
            const l = labels(s, &hb, &cb, &nb);
            if (fmt == .waybar) try proto.waybar(out, alloc, s, &l) else try proto.textLine(out, alloc, s, &l);
        },
    }
}

/// Os textos do waybar e da linha de texto, no idioma do app.
fn labels(s: *const proto.Snapshot, hb: []u8, cb: []u8, nb: []u8) proto.Labels {
    var l: proto.Labels = .{
        .head = if (s.connected and s.account.len > 0)
            std.fmt.bufPrint(hb, "larperCord — {s}", .{s.account}) catch "larperCord"
        else
            i18n.tr("larperCord — sem conexão", "larperCord — not connected"),
        .muted = i18n.tr("mudo", "muted"),
        .deafened = i18n.tr("surdo", "deafened"),
        .talking = i18n.tr("falando", "talking"),
        .offline = i18n.tr("sem conexão", "not connected"),
        .counts = i18n.fmt(nb, "Menções: {d} · DMs não lidas: {d} · canais não lidos: {d}", "Mentions: {d} · unread DMs: {d} · unread channels: {d}", .{ s.mentions, s.dms, s.channels }),
    };
    if (s.call) |call| {
        var wb: [200]u8 = undefined;
        const where = if (call.guild.len > 0) std.fmt.bufPrint(&wb, "{s} ({s})", .{ call.channel, call.guild }) catch call.channel else call.channel;
        l.call = if (std.mem.eql(u8, call.state, "connected"))
            i18n.fmt(cb, "Na call: {s}", "In call: {s}", .{where})
        else
            i18n.fmt(cb, "Entrando na call: {s}", "Joining the call: {s}", .{where});
    }
    return l;
}

// --- O estado do app ----------------------------------------------------------------------

/// O nome do canal como a lista mostra: numa DM sem nome, a outra pessoa.
fn channelName(app: *App, ch: Id) []const u8 {
    const cs = app.store.channel(ch) orelse return "";
    if (cs.info.name.len > 0 or cs.info.recipient == 0) return cs.info.name;
    return if (app.store.user(cs.info.recipient)) |u| u.name else "";
}

fn windowState(app: *App) []const u8 {
    const f = app.win.flags();
    if (app.in_tray or f & c.SDL_WINDOW_HIDDEN != 0) return "hidden";
    if (f & c.SDL_WINDOW_MINIMIZED != 0) return "minimized";
    return "shown";
}

/// As contas da barra: menções (com as DMs, como o número vermelho do Discord),
/// conversas e canais de texto não lidos fora dos silenciados.
pub const Unread = struct { mentions: u32 = 0, dms: u32 = 0, channels: u32 = 0 };

pub fn countUnread(app: *App) Unread {
    const st = &app.st;
    const store = &app.store;
    var u: Unread = .{};
    var it = st.filtros.mentions.valueIterator();
    while (it.next()) |v| u.mentions += v.*;
    for (store.channelsOf(0)) |id| if (store.channel(id)) |cs| {
        if (cs.info.unread and cs.info.request == .none and !st.muted_channels.contains(id)) u.dms += 1;
    };
    for (store.guilds.items) |g| for (store.channelsOf(g.id)) |id| if (store.channel(id)) |cs| {
        if (cs.info.kind == .text and cs.info.unread and !st.muted_channels.contains(id)) u.channels += 1;
    };
    return u;
}

pub fn snapshot(app: *App) proto.Snapshot {
    const st = &app.st;
    const store = &app.store;
    var s: proto.Snapshot = .{
        .connection = if (app.net == .none) "logged_out" else @tagName(store.connection),
        .connected = app.net != .none and store.ready and store.connection == .ready,
        .demo = store.demo,
        .window = windowState(app),
        .muted = st.muted,
        .deafened = st.deafened,
        .ptt_mode = st.settings.voice_ptt,
        .ptt_held = voz_audio.pttKey(),
    };
    if (store.me != 0) if (store.user(store.me)) |u| {
        s.account_id = u.id;
        s.account = u.name;
    };
    if (st.voice) |ch| s.call = .{
        .state = @tagName(st.voice_status),
        .channel_id = ch,
        .channel = channelName(app, ch),
        .guild_id = st.voice_guild,
        .guild = if (store.guild(st.voice_guild)) |g| g.name else "",
        .members = callMembers(app, ch, st.voice_guild),
    };
    s.presence = switch (@as(types.Status, @enumFromInt(std.math.clamp(st.settings.my_status, 0, 3)))) {
        .online => "online",
        .idle => "idle",
        .dnd => "dnd",
        .offline => "invisible",
    };
    s.latency_ms = store.latency_ms;
    const u = countUnread(app);
    s.mentions = u.mentions;
    s.dms = u.dms;
    s.channels = u.channels;
    return s;
}

/// Quem está na call (até 32), com as fotos: os textos ficam aqui até a próxima foto.
var members_buf: [32]proto.Member = undefined;
var avatar_bufs: [32][160]u8 = undefined;

fn callMembers(app: *App, ch: Id, guild: Id) []const proto.Member {
    const cs = app.store.channel(ch) orelse return &.{};
    const now: i64 = @intCast(c.SDL_GetTicks());
    var n: usize = 0;
    for (cs.voice_members.items) |uid| {
        if (n == members_buf.len) break;
        const f = app.store.voiceFlags(uid);
        members_buf[n] = .{
            .id = uid,
            .name = app.store.nameIn(guild, uid) orelse if (app.store.user(uid)) |u| u.name else "?",
            .avatar = avatarUrl(app, &avatar_bufs[n], guild, uid),
            .speaking = app.store.isSpeaking(uid, now),
            .muted = f.muted(),
            .deafened = f.deafened(),
            .self = uid == app.store.me,
            .volume = app.st.volumes.volume(uid),
        };
        n += 1;
    }
    return members_buf[0..n];
}

/// A foto no CDN (a do perfil do servidor, se houver), como a interface pede.
fn avatarUrl(app: *App, buf: []u8, guild: Id, uid: Id) []const u8 {
    const server = if (app.store.face(guild, uid)) |f| f.avatar else null;
    const hash = server orelse (if (app.store.user(uid)) |u| u.avatar else null) orelse return "";
    const url = @import("ui/widgets.zig").cdnUrl(buf, .avatar, uid, hash);
    // A demonstração usa fotos internas ("demo:…"): de fora, só um endereço de verdade.
    return if (std.mem.startsWith(u8, url, "https://")) url else "";
}

// --- Comandos ----------------------------------------------------------------------------

fn status(app: *App, _: *const proto.Args, out: *Out) Error!void {
    const s = snapshot(app);
    try proto.statusJson(out.list(), alloc, &s);
}

fn unread(app: *App, _: *const proto.Args, out: *Out) Error!void {
    const s = snapshot(app);
    try proto.unreadJson(out.list(), alloc, &s);
}

/// O mesmo dos botões e de Ctrl+Shift+M/D: o som, o aviso ao Discord e o que fica gravado.
fn voiceReply(app: *App, out: *Out) Error!void {
    try out.print("{{\"muted\":{s},\"deafened\":{s}}}", .{ jsonBool(app.st.muted), jsonBool(app.st.deafened) });
}

fn jsonBool(b: bool) []const u8 {
    return if (b) "true" else "false";
}

fn mute(app: *App, _: *const proto.Args, out: *Out) Error!void {
    if (!app.st.muted) app.handle(.toggle_mute);
    try voiceReply(app, out);
}

fn unmute(app: *App, _: *const proto.Args, out: *Out) Error!void {
    if (app.st.muted) app.handle(.toggle_mute);
    try voiceReply(app, out);
}

fn toggleMute(app: *App, _: *const proto.Args, out: *Out) Error!void {
    app.handle(.toggle_mute);
    try voiceReply(app, out);
}

fn deafen(app: *App, _: *const proto.Args, out: *Out) Error!void {
    if (!app.st.deafened) app.handle(.toggle_deafen);
    try voiceReply(app, out);
}

fn undeafen(app: *App, _: *const proto.Args, out: *Out) Error!void {
    if (app.st.deafened) app.handle(.toggle_deafen);
    try voiceReply(app, out);
}

fn toggleDeafen(app: *App, _: *const proto.Args, out: *Out) Error!void {
    app.handle(.toggle_deafen);
    try voiceReply(app, out);
}

/// A tecla de fora vai para o mesmo lugar que a do teclado (net/voz_audio.zig): a thread
/// de voz transmite igual, e sai sozinha ao deixar a call (App.resetCallState).
fn ptt(app: *App, cmd: proto.Ptt, out: *Out) Error!void {
    const held = voz_audio.sh.ptt_ext.load(.monotonic);
    switch (proto.ptt(cmd, held, app.st.settings.voice_ptt, app.st.voice != null)) {
        .err => |code| return out.fail(code, ""),
        .held => |h| voz_audio.holdExternal(h),
    }
    try out.print("{{\"ptt_held\":{s}}}", .{jsonBool(voz_audio.pttKey())});
}

fn pttDown(app: *App, _: *const proto.Args, out: *Out) Error!void {
    return ptt(app, .down, out);
}

fn pttUp(app: *App, _: *const proto.Args, out: *Out) Error!void {
    return ptt(app, .up, out);
}

fn pttToggle(app: *App, _: *const proto.Args, out: *Out) Error!void {
    return ptt(app, .toggle, out);
}

fn windowReply(out: *Out, state: []const u8) Error!void {
    try out.print("{{\"window\":\"{s}\"}}", .{state});
}

/// O mesmo do "Abrir o larperCord" da bandeja.
fn show(app: *App, _: *const proto.Args, out: *Out) Error!void {
    app.showWindow();
    app.gate.redraw();
    try windowReply(out, "shown");
}

/// Como fechar a janela com "Fechar para a bandeja": sem bandeja (ou antes do login),
/// minimiza, para nunca sobrar um app invisível sem caminho de volta.
fn hide(app: *App, _: *const proto.Args, out: *Out) Error!void {
    if (app.hideToTray()) return windowReply(out, "hidden");
    _ = c.SDL_MinimizeWindow(app.win.window);
    try windowReply(out, "minimized");
}

/// O clique no ícone da bandeja (janela.trayClick).
fn toggle(app: *App, _: *const proto.Args, out: *Out) Error!void {
    app.toggleWindow();
    app.gate.redraw();
    try windowReply(out, switch (app.tray_click orelse .mostrar) {
        .mostrar => "shown",
        .para_bandeja => "hidden",
        .minimizar => "minimized",
    });
}

/// Um link de mensagem ou de canal do Discord (o mesmo do clique num link da conversa)
/// ou o ID do canal, e a janela vem para a frente.
fn open(app: *App, args: *const proto.Args, out: *Out) Error!void {
    const what = args.arg(0) orelse return out.fail(.usage, "open needs a Discord link or a channel ID");
    var ch: Id = 0;
    var msg: Id = 0;
    if (links.parseMessage(what)) |l| {
        ch = l.channel;
        msg = l.message;
    } else ch = std.fmt.parseInt(Id, what, 10) catch return out.fail(.usage, "not a Discord message or channel link, nor a channel ID");
    if (!app.store.ready) return out.fail(.not_ready, "");
    const cs = app.store.channel(ch) orelse return out.fail(.not_found, "");
    if (cs.info.kind != .text) return out.fail(.not_text, "");
    app.handle(.{ .open_message = .{ .channel = ch, .id = msg } });
    app.showWindow();
    app.gate.redraw();
    try out.print("{{\"channel_id\":\"{d}\",\"channel\":", .{ch});
    try @import("net/jsonx.zig").writeString(out.list(), alloc, channelName(app, ch));
    try out.write("}");
}

fn watch(app: *App, args: *const proto.Args, out: *Out) Error!void {
    const fmt: proto.Format = if (args.arg(0)) |a| proto.parseFormat(a) orelse return out.fail(.usage, "watch takes json, waybar or text") else .json;
    // Quem já estava olhando recebe o que mudou antes; o novo começa da linha de agora.
    notify(app);
    last_key = key(app);
    const snap = snapshot(app);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    try render(&snap, fmt, &line);
    const last = &last_line[@backingInt(fmt)];
    last.clearRetainingCapacity();
    try last.appendSlice(alloc, line.items);
    try out.write(line.items);
    ctl.watch(out.req, fmt);
}

fn help(_: *App, _: *const proto.Args, out: *Out) Error!void {
    try writeHelp(out.list(), alloc);
}

const inbox = @import("core/inbox.zig");
const StoredMessage = @import("core/store.zig").StoredMessage;
const jsonx = @import("net/jsonx.zig");

/// As DMs não lidas e as menções (o que a Caixa de entrada mostra), da mais nova para a
/// mais velha: quem, onde, o começo da mensagem e o link para abrir com o `open`.
fn mentions(app: *App, args: *const proto.Args, out: *Out) Error!void {
    const want: usize = if (args.len > 1) std.fmt.parseInt(usize, args.list[1], 10) catch return out.fail(.usage, "mentions [n]") else 20;
    var model: inbox.Model = .{};
    inbox.build(&app.store, &app.st.muted_channels, &app.st.filtros, &model);
    // Uma linha por mensagem carregada; a conversa não lida que ainda não foi aberta (sem
    // mensagens na memória) vira uma linha só, sem texto, com quantas são.
    const Item = struct { channel: Id, guild: Id, id: Id, count: u32, loaded: bool };
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(alloc);
    for (model.slice()) |g| {
        if (g.channel == 0) continue;
        if (g.n == 0) {
            if (g.latest != 0) try items.append(alloc, .{ .channel = g.channel, .guild = g.guild, .id = g.latest, .count = @max(g.total, 1), .loaded = false });
            continue;
        }
        for (g.ids()) |id| try items.append(alloc, .{ .channel = g.channel, .guild = g.guild, .id = id, .count = 1, .loaded = true });
    }
    std.mem.sortUnstable(Item, items.items, {}, struct {
        fn gt(_: void, a: Item, b: Item) bool {
            return a.id > b.id;
        }
    }.gt);
    const l = out.list();
    try l.append(alloc, '[');
    for (items.items[0..@min(items.items.len, want)], 0..) |it, n| {
        const m: ?*const StoredMessage = if (it.loaded) (if (inbox.lookup(&app.store, it.channel, it.id)) |f| f.m else null) else null;
        // Sem a mensagem, quem escreveu é a outra pessoa da DM (num servidor, ninguém).
        const author: Id = if (m) |x| x.msg.author else if (app.store.channel(it.channel)) |cs| cs.info.recipient else 0;
        if (n > 0) try l.append(alloc, ',');
        var pb: [400]u8 = undefined;
        var ab: [160]u8 = undefined;
        try l.print(alloc, "{{\"kind\":\"{s}\",\"id\":\"{d}\",\"channel_id\":\"{d}\",\"channel\":", .{ if (it.guild == 0) "dm" else "mention", it.id, it.channel });
        try jsonx.writeString(l, alloc, channelName(app, it.channel));
        try l.appendSlice(alloc, ",\"guild\":");
        if (app.store.guild(it.guild)) |g| try jsonx.writeString(l, alloc, g.name) else try l.appendSlice(alloc, "null");
        try l.print(alloc, ",\"author_id\":\"{d}\",\"author\":", .{author});
        try jsonx.writeString(l, alloc, if (author == 0) "" else app.store.nameIn(it.guild, author) orelse if (app.store.user(author)) |u| u.name else "?");
        try l.appendSlice(alloc, ",\"avatar\":");
        try jsonx.writeString(l, alloc, if (author == 0) "" else avatarUrl(app, &ab, it.guild, author));
        try l.appendSlice(alloc, ",\"text\":");
        try jsonx.writeString(l, alloc, if (m) |x| inbox.preview(&pb, &app.store, x) else "");
        try l.print(alloc, ",\"count\":{d},\"time_ms\":{d},\"link\":\"https://discord.com/channels/", .{ it.count, types.snowflakeTime(it.id) });
        if (it.guild == 0) try l.appendSlice(alloc, "@me") else try l.print(alloc, "{d}", .{it.guild});
        try l.print(alloc, "/{d}/{d}\"}}", .{ it.channel, it.id });
    }
    try l.append(alloc, ']');
}

/// Servidores, canais de texto e de voz e DMs, com as não lidas: o que um lançador
/// precisa para pular para qualquer conversa (o `open` com o id abre).
fn channels(app: *App, _: *const proto.Args, out: *Out) Error!void {
    const l = out.list();
    try l.append(alloc, '[');
    var first = true;
    // As DMs primeiro, na ordem da lista do app; depois cada servidor.
    var gi: usize = 0;
    while (gi <= app.store.guilds.items.len) : (gi += 1) {
        const gid: Id = if (gi == 0) 0 else app.store.guilds.items[gi - 1].id;
        const gname: []const u8 = if (gi == 0) "" else app.store.guilds.items[gi - 1].name;
        for (app.store.channelsOf(gid)) |id| {
            const cs = app.store.channel(id) orelse continue;
            const kind: []const u8 = switch (cs.info.kind) {
                .text => if (gid == 0) (if (cs.info.group) "group" else "dm") else "text",
                .voice => "voice",
                .forum => "forum",
                .category => continue,
            };
            if (!first) try l.append(alloc, ',');
            first = false;
            try l.print(alloc, "{{\"id\":\"{d}\",\"kind\":\"{s}\",\"name\":", .{ id, kind });
            try jsonx.writeString(l, alloc, channelName(app, id));
            try l.appendSlice(alloc, ",\"guild\":");
            if (gid == 0) try l.appendSlice(alloc, "null") else try jsonx.writeString(l, alloc, gname);
            try l.print(alloc, ",\"guild_id\":\"{d}\",\"unread\":{s},\"mentions\":{d},\"muted\":{s}}}", .{
                gid,
                if (cs.info.unread) "true" else "false",
                app.st.filtros.count(id),
                if (app.st.muted_channels.contains(id)) "true" else "false",
            });
        }
    }
    try l.append(alloc, ']');
}

fn presence(app: *App, args: *const proto.Args, out: *Out) Error!void {
    if (args.len < 2) return out.fail(.usage, "presence <online|idle|dnd|invisible>");
    const p = proto.parsePresence(args.list[1]) orelse return out.fail(.usage, "presence <online|idle|dnd|invisible>");
    app.handle(.{ .set_status = switch (p) {
        .online => .online,
        .idle => .idle,
        .dnd => .dnd,
        .offline => .offline,
    } });
    try out.print("{{\"presence\":\"{s}\"}}", .{args.list[1]});
}

fn volume(app: *App, args: *const proto.Args, out: *Out) Error!void {
    if (args.len < 3) return out.fail(.usage, "volume <id> <0-200>");
    const uid = std.fmt.parseInt(Id, args.list[1], 10) catch return out.fail(.usage, "volume <id> <0-200>");
    const v = proto.parseVolume(args.list[2]) orelse return out.fail(.usage, "volume <id> <0-200>");
    app.handle(.{ .set_voice_volume = .{ .user = uid, .volume = v } });
    try out.print("{{\"id\":\"{d}\",\"volume\":{d:.2}}}", .{ uid, v });
}

// --- inspect: os comandos do Inspetor (src/inspect/comandos.zig) ---------------------------

const insp_cmd = @import("inspect/comandos.zig");

/// Um pedido do Inspetor esperando um quadro (achar, clicar, a árvore) ou o print.
const Held = struct { req: *ctl.Request, since_ms: u64, shot: bool };
var guardados: std.ArrayList(Held) = .empty;

/// O que vem depois de "inspect " na linha, ou nulo se não é um `inspect`.
fn inspectLine(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, t, "inspect")) return null;
    if (t.len == "inspect".len) return "";
    if (t["inspect".len] != ' ' and t["inspect".len] != '\t') return null;
    return std.mem.trim(u8, t["inspect".len..], " \t");
}

fn inspect(app: *App, _: *const proto.Args, out: *Out) Error!void {
    const line = inspectLine(out.req.line) orelse "";
    if (line.len == 0) return out.fail(.usage, "inspect <command> (inspect help lists them)");
    switch (try runInspect(app, line, out.req)) {
        .pronto => {
            // O print sai no fim do próximo quadro: a resposta espera o arquivo.
            if (std.mem.startsWith(u8, line, "shot ") and insp_cmd.busy()) {
                out.hold = true;
                try guardados.append(alloc, .{ .req = out.req, .since_ms = c.SDL_GetTicks(), .shot = true });
            }
        },
        .depois => {
            out.hold = true;
            try guardados.append(alloc, .{ .req = out.req, .since_ms = c.SDL_GetTicks(), .shot = false });
        },
    }
}

/// Roda a linha no Inspetor; a resposta vai para o corpo do pedido.
fn runInspect(app: *App, line: []const u8, req: *ctl.Request) Error!insp_cmd.Fim {
    var w: std.Io.Writer.Allocating = .init(alloc);
    defer w.deinit();
    const fim = insp_cmd.run(app, line, &w.writer, .ctl);
    if (fim == .pronto) try req.body.appendSlice(alloc, w.written());
    return fim;
}

/// Os pedidos guardados do Inspetor: depois de um quadro (`after_frame`), roda de novo os que
/// esperavam um; e responde com erro os que passaram do prazo (janela escondida: sem quadro).
pub fn inspectPump(app: *App, after_frame: bool) void {
    if (guardados.items.len == 0) return;
    const now = c.SDL_GetTicks();
    var i: usize = 0;
    while (i < guardados.items.len) {
        const h = guardados.items[i];
        var done = false;
        if (now - h.since_ms > ctl.reply_ms - 300) {
            h.req.err = .{ .code = .timeout, .text = "no frame was drawn in time (is the window hidden?)" };
            done = true;
        } else if (after_frame) {
            if (h.shot) {
                if (!insp_cmd.busy()) {
                    if (insp_cmd.shot_result != .ok) h.req.err = .{ .code = .failed, .text = "couldn't save the screenshot" } else h.req.body.appendSlice(alloc, "saved\n") catch {};
                    done = true;
                }
            } else if (inspectLine(h.req.line)) |line| {
                const fim = runInspect(app, line, h.req) catch blk: {
                    h.req.err = .{ .code = .failed, .text = "out of memory" };
                    break :blk .pronto;
                };
                done = fim == .pronto;
            } else done = true;
        }
        if (done) {
            ctl.finish(h.req);
            _ = guardados.swapRemove(i);
        } else i += 1;
    }
}

/// Tem pedido do Inspetor esperando: o laço desenha quadros até ele sair.
pub fn inspectWaiting() bool {
    return guardados.items.len > 0;
}
