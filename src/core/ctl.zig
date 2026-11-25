//! O controle de fora (`larpercord ctl`) sem socket nem SDL (testado em `zig build
//! test`): o arquivo da porta, o enquadramento das respostas, o que a linha de comando
//! pede, as regras do aperte para falar de fora e o JSON do status, do waybar e a linha
//! de texto. O protocolo está descrito em app_ctl.zig; o transporte, em platform/ctl.zig.
const std = @import("std");
const jsonx = @import("../net/jsonx.zig");

/// O segredo do arquivo da porta: 16 bytes do sorteio do sistema, em hexadecimal.
pub const nonce_len = 32;
/// Uma linha de comando, no máximo (o segredo também chega numa).
pub const max_line = 4096;
pub const max_args = 16;
/// Primeira linha depois do segredo certo: o protocolo e a versão dele.
pub const greeting = "larpercord-ctl 1";

/// O que o app deixa no arquivo da porta: "<porta> <segredo>\n".
pub const PortFile = struct {
    port: u16,
    nonce: []const u8,

    pub fn parse(text: []const u8) ?PortFile {
        var it = std.mem.tokenizeAny(u8, text, " \r\n");
        const port = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
        const nonce = it.next() orelse return null;
        if (port == 0 or nonce.len != nonce_len or it.next() != null) return null;
        for (nonce) |ch| if (!std.ascii.isHex(ch)) return null;
        return .{ .port = port, .nonce = nonce };
    }
};

/// Compara o segredo sem parar no primeiro byte diferente.
pub fn sameNonce(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Por que um pedido não deu certo. O nome vai na resposta ("ERR not_ptt …") e não
/// muda entre versões: é o que um script compara.
pub const Code = enum {
    auth,
    busy,
    timeout,
    unknown,
    usage,
    not_ptt,
    no_call,
    not_ready,
    not_found,
    not_text,
    closing,
    failed,

    pub fn parse(s: []const u8) ?Code {
        return std.meta.stringToEnum(Code, s);
    }

    /// A mensagem de sempre, em inglês, como vai na resposta (a linha de comando
    /// mostra a dela, no idioma do sistema: ctl_cli.zig).
    pub fn message(code: Code) []const u8 {
        return switch (code) {
            .auth => "wrong or missing key",
            .busy => "too many connections at once",
            .timeout => "larperCord didn't answer in time",
            .unknown => "unknown command (see larpercord ctl help)",
            .usage => "wrong arguments (see larpercord ctl help)",
            .not_ptt => "the voice mode isn't push to talk (Settings → Voice)",
            .no_call => "not in a call",
            .not_ready => "not connected to Discord yet",
            .not_found => "that channel isn't on this account",
            .not_text => "not a text channel",
            .closing => "larperCord is closing",
            .failed => "it didn't work",
        };
    }
};

/// Um erro de resposta. `text` vazio: a mensagem de sempre do código.
pub const Err = struct {
    code: Code,
    text: []const u8 = "",
};

/// A primeira linha de cada resposta.
pub const Reply = union(enum) {
    ok,
    /// `code` nulo: um código que esta versão não conhece (vale a mensagem).
    err: struct { code: ?Code, text: []const u8 },
};

pub fn parseReply(line: []const u8) ?Reply {
    if (std.mem.eql(u8, line, "OK")) return .ok;
    if (!std.mem.startsWith(u8, line, "ERR ")) return null;
    const rest = line[4..];
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const text = if (sp < rest.len) rest[sp + 1 ..] else "";
    return .{ .err = .{ .code = Code.parse(rest[0..sp]), .text = text } };
}

/// Uma linha do corpo, com o "." a mais quando ela começa com ".".
pub fn stuffLine(out: *std.ArrayList(u8), gpa: std.mem.Allocator, line: []const u8) !void {
    if (line.len > 0 and line[0] == '.') try out.append(gpa, '.');
    try out.appendSlice(gpa, line);
    try out.append(gpa, '\n');
}

/// A resposta inteira como vai pelo socket: a linha de status, o corpo linha a linha
/// e, fora no `watch` (`close` falso), o "." que fecha.
pub fn frame(out: *std.ArrayList(u8), gpa: std.mem.Allocator, err: ?Err, body: []const u8, close: bool) !void {
    if (err) |e| {
        const text = if (e.text.len > 0) e.text else e.code.message();
        try out.print(gpa, "ERR {t} ", .{e.code});
        // A mensagem é uma linha só.
        for (text) |ch| try out.append(gpa, if (ch == '\n' or ch == '\r') ' ' else ch);
        try out.append(gpa, '\n');
    } else try out.appendSlice(gpa, "OK\n");
    var rest = body;
    // Sem o \n do fim, a última linha não vira uma linha vazia a mais.
    if (rest.len > 0 and rest[rest.len - 1] == '\n') rest = rest[0 .. rest.len - 1];
    if (body.len > 0) {
        var it = std.mem.splitScalar(u8, rest, '\n');
        while (it.next()) |line| try stuffLine(out, gpa, line);
    }
    if (close) try out.appendSlice(gpa, ".\n");
}

/// Uma linha do corpo como chegou. Nulo: o "." sozinho, que fecha a resposta.
pub fn unstuff(line: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, line, ".")) return null;
    return if (line.len > 0 and line[0] == '.') line[1..] else line;
}

/// Um comando já separado: o nome e os argumentos (por espaço ou tab).
pub const Args = struct {
    list: [max_args][]const u8 = undefined,
    len: usize = 0,

    /// Nulo: argumentos demais.
    pub fn parse(line: []const u8) ?Args {
        var a: Args = .{};
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        while (it.next()) |t| {
            if (a.len == max_args) return null;
            a.list[a.len] = t;
            a.len += 1;
        }
        return a;
    }

    pub fn name(a: *const Args) []const u8 {
        return if (a.len > 0) a.list[0] else "";
    }

    /// O argumento `i` depois do nome.
    pub fn arg(a: *const Args, i: usize) ?[]const u8 {
        return if (i + 1 < a.len) a.list[i + 1] else null;
    }

    pub fn count(a: *const Args) usize {
        return a.len -| 1;
    }
};

/// O que cada linha do `watch` traz: o status em JSON, o JSON do waybar ou a linha de
/// texto (polybar e parecidos).
pub const Format = enum { json, waybar, text };

pub fn parseFormat(s: []const u8) ?Format {
    return std.meta.stringToEnum(Format, s);
}

/// O que a linha de comando pede.
pub const Cli = union(enum) {
    help,
    /// A linha que vai para o app e, no `watch`, o formato (a resposta não acaba).
    send: struct { line: []const u8, watch: ?Format },
    bad: Bad,

    pub const Bad = enum { format, newline, too_long };
};

/// `buf` guarda a linha montada. "watch --waybar" vira "watch waybar"; o resto vai
/// como veio, e quem decide se o comando existe é o app.
pub fn parseCli(args: []const []const u8, buf: []u8) Cli {
    if (args.len == 0) return .help;
    const first = args[0];
    if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) return .help;
    if (std.mem.eql(u8, first, "watch")) {
        var fmt: Format = .json;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--waybar")) {
                fmt = .waybar;
            } else if (std.mem.eql(u8, a, "--json")) {
                fmt = .json;
            } else if (std.mem.eql(u8, a, "--format")) {
                i += 1;
                if (i >= args.len) return .{ .bad = .format };
                fmt = parseFormat(args[i]) orelse return .{ .bad = .format };
            } else if (std.mem.startsWith(u8, a, "--format=")) {
                fmt = parseFormat(a["--format=".len..]) orelse return .{ .bad = .format };
            } else return .{ .bad = .format };
        }
        const line = std.fmt.bufPrint(buf, "watch {t}", .{fmt}) catch return .{ .bad = .too_long };
        return .{ .send = .{ .line = line, .watch = fmt } };
    }
    var n: usize = 0;
    for (args, 0..) |a, i| {
        // Uma quebra de linha viraria outro comando.
        if (std.mem.indexOfAny(u8, a, "\r\n") != null) return .{ .bad = .newline };
        const sep: usize = if (i > 0) 1 else 0;
        if (n + sep + a.len > @min(buf.len, max_line)) return .{ .bad = .too_long };
        if (sep == 1) buf[n] = ' ';
        n += sep;
        @memcpy(buf[n..][0..a.len], a);
        n += a.len;
    }
    return .{ .send = .{ .line = buf[0..n], .watch = null } };
}

// --- Aperte para falar de fora ----------------------------------------------------

pub const Ptt = enum { down, up, toggle };
pub const PttResult = union(enum) { held: bool, err: Code };

/// A tecla de fora depois do comando. Só no modo aperte para falar; apertar só numa
/// call (fora dela não sobra uma tecla presa para a próxima). Soltar sempre pode.
pub fn ptt(cmd: Ptt, held: bool, ptt_mode: bool, in_call: bool) PttResult {
    if (!ptt_mode) return .{ .err = .not_ptt };
    const want = switch (cmd) {
        .down => true,
        .up => false,
        .toggle => !held,
    };
    if (want and !in_call) return .{ .err = .no_call };
    return .{ .held = want };
}

// --- Status -----------------------------------------------------------------------

pub const Call = struct {
    /// "connecting" ou "connected".
    state: []const u8,
    channel_id: u64,
    channel: []const u8,
    /// 0 numa DM.
    guild_id: u64 = 0,
    guild: []const u8 = "",
    /// Quem está na call, com quem fala agora (a barra anima as fotos).
    members: []const Member = &.{},
};

/// Alguém na call.
pub const Member = struct {
    id: u64,
    name: []const u8,
    /// O endereço da foto no CDN do Discord (vazio: sem foto, fica a inicial).
    avatar: []const u8 = "",
    speaking: bool = false,
    muted: bool = false,
    deafened: bool = false,
    /// A nossa própria linha.
    self: bool = false,
    /// O volume dela no mixer (1 = 100%).
    volume: f32 = 1,
};

/// O app numa foto: o que o `status` responde e o que o `watch` acompanha.
pub const Snapshot = struct {
    /// Nome do estado da conexão ("ready", "reconnecting"…; "logged_out" na tela de login).
    connection: []const u8 = "logged_out",
    connected: bool = false,
    demo: bool = false,
    account_id: u64 = 0,
    account: []const u8 = "",
    /// "shown", "hidden" (na bandeja) ou "minimized".
    window: []const u8 = "shown",
    muted: bool = false,
    deafened: bool = false,
    ptt_mode: bool = false,
    ptt_held: bool = false,
    call: ?Call = null,
    mentions: u32 = 0,
    dms: u32 = 0,
    channels: u32 = 0,
    /// "online", "idle", "dnd" ou "invisible".
    presence: []const u8 = "online",
    /// A latência do heartbeat do gateway (0: ainda não mediu).
    latency_ms: u32 = 0,

    /// Na call, com a tecla do aperte para falar apertada e o microfone aberto.
    pub fn talking(s: *const Snapshot) bool {
        return s.call != null and s.ptt_mode and s.ptt_held and !s.muted and !s.deafened;
    }
};

fn idStr(out: *std.ArrayList(u8), gpa: std.mem.Allocator, id: u64) !void {
    // Snowflakes como texto, como o Discord manda: o double do JavaScript perde dígitos.
    if (id == 0) return out.appendSlice(gpa, "null");
    try out.print(gpa, "\"{d}\"", .{id});
}

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

pub fn unreadJson(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: *const Snapshot) !void {
    try out.print(gpa, "{{\"mentions\":{d},\"dms\":{d},\"channels\":{d}}}", .{ s.mentions, s.dms, s.channels });
}

pub fn statusJson(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: *const Snapshot) !void {
    try out.print(gpa, "{{\"connected\":{s},\"connection\":", .{boolStr(s.connected)});
    try jsonx.writeString(out, gpa, s.connection);
    try out.print(gpa, ",\"demo\":{s},\"account\":", .{boolStr(s.demo)});
    if (s.account_id == 0) {
        try out.appendSlice(gpa, "null");
    } else {
        try out.appendSlice(gpa, "{\"id\":");
        try idStr(out, gpa, s.account_id);
        try out.appendSlice(gpa, ",\"name\":");
        try jsonx.writeString(out, gpa, s.account);
        try out.append(gpa, '}');
    }
    try out.appendSlice(gpa, ",\"window\":");
    try jsonx.writeString(out, gpa, s.window);
    try out.appendSlice(gpa, ",\"presence\":");
    try jsonx.writeString(out, gpa, s.presence);
    try out.print(gpa, ",\"latency_ms\":{d}", .{s.latency_ms});
    try out.print(gpa, ",\"voice\":{{\"muted\":{s},\"deafened\":{s},\"mode\":\"{s}\",\"ptt_held\":{s},\"call\":", .{
        boolStr(s.muted), boolStr(s.deafened), if (s.ptt_mode) "push_to_talk" else "voice_activity", boolStr(s.ptt_held),
    });
    if (s.call) |call| {
        try out.appendSlice(gpa, "{\"state\":");
        try jsonx.writeString(out, gpa, call.state);
        try out.appendSlice(gpa, ",\"channel_id\":");
        try idStr(out, gpa, call.channel_id);
        try out.appendSlice(gpa, ",\"channel\":");
        try jsonx.writeString(out, gpa, call.channel);
        try out.appendSlice(gpa, ",\"guild_id\":");
        try idStr(out, gpa, call.guild_id);
        try out.appendSlice(gpa, ",\"guild\":");
        if (call.guild_id == 0) try out.appendSlice(gpa, "null") else try jsonx.writeString(out, gpa, call.guild);
        try out.appendSlice(gpa, ",\"members\":[");
        for (call.members, 0..) |m, i| {
            if (i > 0) try out.append(gpa, ',');
            try memberJson(out, gpa, &m);
        }
        try out.appendSlice(gpa, "]}");
    } else try out.appendSlice(gpa, "null");
    try out.appendSlice(gpa, "},\"unread\":");
    try unreadJson(out, gpa, s);
    try out.append(gpa, '}');
}

pub fn memberJson(out: *std.ArrayList(u8), gpa: std.mem.Allocator, m: *const Member) !void {
    try out.appendSlice(gpa, "{\"id\":");
    try idStr(out, gpa, m.id);
    try out.appendSlice(gpa, ",\"name\":");
    try jsonx.writeString(out, gpa, m.name);
    try out.appendSlice(gpa, ",\"avatar\":");
    try jsonx.writeString(out, gpa, m.avatar);
    try out.print(gpa, ",\"speaking\":{s},\"muted\":{s},\"deafened\":{s},\"self\":{s},\"volume\":{d:.2}}}", .{
        boolStr(m.speaking), boolStr(m.muted), boolStr(m.deafened), boolStr(m.self), m.volume,
    });
}

/// `presence` aceita o nome que a pessoa conhece ("invisible") e o do Discord ("offline").
pub fn parsePresence(s: []const u8) ?enum { online, idle, dnd, offline } {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(s, "online")) return .online;
    if (eq(s, "idle") or eq(s, "away")) return .idle;
    if (eq(s, "dnd")) return .dnd;
    if (eq(s, "invisible") or eq(s, "offline")) return .offline;
    return null;
}

/// O volume de `volume <id> <n>`: em porcentagem (0 a 200, como o mixer).
pub fn parseVolume(s: []const u8) ?f32 {
    const t = std.mem.trimEnd(u8, s, "%");
    const n = std.fmt.parseFloat(f32, t) catch return null;
    if (!(n >= 0 and n <= 200)) return null;
    return n / 100;
}

// --- waybar e a linha de texto ------------------------------------------------------

/// Os textos para gente ler, já no idioma do app (quem chama monta; aqui só entra no
/// lugar). `call` vazio: fora de call.
pub const Labels = struct {
    head: []const u8,
    call: []const u8 = "",
    counts: []const u8 = "",
    muted: []const u8 = "muted",
    deafened: []const u8 = "deafened",
    talking: []const u8 = "talking",
    /// A linha de texto sem conexão.
    offline: []const u8 = "offline",
};

/// O estado principal, para os ícones do waybar (`format-icons`, pelo `alt`): sem
/// conexão; na call surdo, mudo, falando ou só na call; fora dela, menção, não lida ou
/// nada.
pub fn state(s: *const Snapshot) []const u8 {
    if (!s.connected) return "offline";
    if (s.call != null) {
        if (s.deafened) return "deafened";
        if (s.muted) return "muted";
        if (s.talking()) return "talking";
        return "call";
    }
    if (s.mentions > 0) return "mention";
    if (s.dms + s.channels > 0) return "unread";
    return "idle";
}

fn voiceWord(s: *const Snapshot, l: *const Labels) ?[]const u8 {
    if (s.deafened) return l.deafened;
    if (s.muted) return l.muted;
    if (s.talking()) return l.talking;
    return null;
}

/// O módulo custom do waybar (`return-type: json`): o número de menções no texto (vazio
/// sem nenhuma), o estado no `alt` e no `class`, e o resumo no `tooltip`.
pub fn waybar(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: *const Snapshot, l: *const Labels) !void {
    var num: [16]u8 = undefined;
    const text = if (s.connected and s.mentions > 0) std.fmt.bufPrint(&num, "{d}", .{s.mentions}) catch "" else "";
    try out.appendSlice(gpa, "{\"text\":");
    try jsonx.writeString(out, gpa, text);
    // O resumo: quem, a call (com mudo/surdo) e as contas.
    var tip: std.ArrayList(u8) = .empty;
    defer tip.deinit(gpa);
    try tip.appendSlice(gpa, l.head);
    if (s.connected and l.call.len > 0) {
        try tip.append(gpa, '\n');
        try tip.appendSlice(gpa, l.call);
        if (voiceWord(s, l)) |w| try tip.print(gpa, " · {s}", .{w});
    }
    if (s.connected and l.counts.len > 0) {
        try tip.append(gpa, '\n');
        try tip.appendSlice(gpa, l.counts);
    }
    try out.appendSlice(gpa, ",\"tooltip\":");
    try jsonx.writeString(out, gpa, tip.items);
    // Todas as classes que valem (o CSS escolhe), e o alt com a principal.
    try out.appendSlice(gpa, ",\"class\":[");
    var n: usize = 0;
    if (!s.connected) {
        try out.appendSlice(gpa, "\"offline\"");
        n = 1;
    } else {
        const flags = [_]struct { []const u8, bool }{
            .{ "call", s.call != null },
            .{ "deafened", s.deafened },
            .{ "muted", s.muted and !s.deafened },
            .{ "talking", s.talking() },
            .{ "mention", s.mentions > 0 },
            .{ "unread", s.dms + s.channels > 0 },
        };
        for (flags) |f| if (f[1]) {
            if (n > 0) try out.append(gpa, ',');
            try out.print(gpa, "\"{s}\"", .{f[0]});
            n += 1;
        };
        if (n == 0) try out.appendSlice(gpa, "\"idle\"");
    }
    try out.print(gpa, "],\"alt\":\"{s}\"}}", .{state(s)});
}

/// Uma linha para barras que leem texto (polybar): a call e o estado dela, "@" com as
/// menções, "DM" e "#" com as conversas e os canais não lidos. Vazia sem nada disso.
pub fn textLine(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: *const Snapshot, l: *const Labels) !void {
    if (!s.connected) return out.appendSlice(gpa, l.offline);
    const start = out.items.len;
    const T = struct {
        fn sep(o: *std.ArrayList(u8), g: std.mem.Allocator, first: usize) !void {
            if (o.items.len > first) try o.appendSlice(g, " · ");
        }
    };
    if (s.call) |call| {
        try out.appendSlice(gpa, call.channel);
        if (voiceWord(s, l)) |w| {
            try T.sep(out, gpa, start);
            try out.appendSlice(gpa, w);
        }
    }
    if (s.mentions > 0) {
        try T.sep(out, gpa, start);
        try out.print(gpa, "@{d}", .{s.mentions});
    }
    if (s.dms > 0) {
        try T.sep(out, gpa, start);
        try out.print(gpa, "DM {d}", .{s.dms});
    }
    if (s.channels > 0) {
        try T.sep(out, gpa, start);
        try out.print(gpa, "#{d}", .{s.channels});
    }
}

// --- Testes -----------------------------------------------------------------------

const testing = std.testing;

test "arquivo da porta" {
    const p = PortFile.parse("41234 0123456789abcdef0123456789ABCDEF\n").?;
    try testing.expectEqual(@as(u16, 41234), p.port);
    try testing.expectEqualStrings("0123456789abcdef0123456789ABCDEF", p.nonce);
    try testing.expect(PortFile.parse("") == null);
    try testing.expect(PortFile.parse("41234") == null);
    try testing.expect(PortFile.parse("0 0123456789abcdef0123456789abcdef") == null);
    try testing.expect(PortFile.parse("70000 0123456789abcdef0123456789abcdef") == null);
    // O segredo da instância (16) não serve aqui, nem um que não é hexadecimal.
    try testing.expect(PortFile.parse("41234 0123456789abcdef") == null);
    try testing.expect(PortFile.parse("41234 0123456789abcdef0123456789abcdeg") == null);
    try testing.expect(PortFile.parse("41234 0123456789abcdef0123456789abcdef extra") == null);
}

test "segredo: igual, diferente, outro tamanho" {
    try testing.expect(sameNonce("abcd", "abcd"));
    try testing.expect(!sameNonce("abcd", "abce"));
    try testing.expect(!sameNonce("abcd", "abc"));
    try testing.expect(!sameNonce("", "a"));
}

test "linha de status da resposta" {
    try testing.expectEqual(Reply.ok, parseReply("OK").?);
    const e = parseReply("ERR not_ptt the voice mode isn't push to talk").?.err;
    try testing.expectEqual(@as(?Code, .not_ptt), e.code);
    try testing.expectEqualStrings("the voice mode isn't push to talk", e.text);
    // Código de uma versão mais nova: sem código, com a mensagem.
    const n = parseReply("ERR new_thing something").?.err;
    try testing.expect(n.code == null);
    try testing.expectEqualStrings("something", n.text);
    try testing.expectEqual(@as(?Code, .busy), parseReply("ERR busy").?.err.code);
    try testing.expect(parseReply("ok") == null);
    try testing.expect(parseReply("{\"connected\":true}") == null);
}

test "enquadramento: o ponto do começo, o fim e a mensagem numa linha" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try frame(&out, gpa, null, "a\n.b\n.\n", true);
    try testing.expectEqualStrings("OK\na\n..b\n..\n.\n", out.items);
    // Lido de volta, linha a linha, até o ".".
    var it = std.mem.splitScalar(u8, out.items, '\n');
    try testing.expectEqual(Reply.ok, parseReply(it.next().?).?);
    try testing.expectEqualStrings("a", unstuff(it.next().?).?);
    try testing.expectEqualStrings(".b", unstuff(it.next().?).?);
    try testing.expectEqualStrings(".", unstuff(it.next().?).?);
    try testing.expect(unstuff(it.next().?) == null);

    out.clearRetainingCapacity();
    try frame(&out, gpa, .{ .code = .usage, .text = "open needs\na link" }, "", true);
    try testing.expectEqualStrings("ERR usage open needs a link\n.\n", out.items);
    out.clearRetainingCapacity();
    try frame(&out, gpa, .{ .code = .no_call }, "", true);
    try testing.expectEqualStrings("ERR no_call not in a call\n.\n", out.items);
    // Corpo vazio e o watch, que não fecha.
    out.clearRetainingCapacity();
    try frame(&out, gpa, null, "", true);
    try testing.expectEqualStrings("OK\n.\n", out.items);
    out.clearRetainingCapacity();
    try frame(&out, gpa, null, "{}", false);
    try testing.expectEqualStrings("OK\n{}\n", out.items);
    // Uma linha vazia no meio do corpo continua lá.
    out.clearRetainingCapacity();
    try frame(&out, gpa, null, "a\n\nb", true);
    try testing.expectEqualStrings("OK\na\n\nb\n.\n", out.items);
}

test "argumentos do comando" {
    const a = Args.parse("open  https://discord.com/channels/1/2\t").?;
    try testing.expectEqualStrings("open", a.name());
    try testing.expectEqual(@as(usize, 1), a.count());
    try testing.expectEqualStrings("https://discord.com/channels/1/2", a.arg(0).?);
    try testing.expect(a.arg(1) == null);
    const empty = Args.parse("").?;
    try testing.expectEqualStrings("", empty.name());
    try testing.expectEqual(@as(usize, 0), empty.count());
    try testing.expect(Args.parse("a b c d e f g h i j k l m n o p q") == null);
    try testing.expect(Args.parse("a b c d e f g h i j k l m n o p") != null);
}

test "linha de comando" {
    var buf: [max_line]u8 = undefined;
    try testing.expectEqual(Cli.help, parseCli(&.{}, &buf));
    try testing.expectEqual(Cli.help, parseCli(&.{"help"}, &buf));
    try testing.expectEqual(Cli.help, parseCli(&.{"--help"}, &buf));
    const s = parseCli(&.{ "open", "123" }, &buf).send;
    try testing.expectEqualStrings("open 123", s.line);
    try testing.expect(s.watch == null);
    const w = parseCli(&.{ "watch", "--waybar" }, &buf).send;
    try testing.expectEqualStrings("watch waybar", w.line);
    try testing.expectEqual(@as(?Format, .waybar), w.watch);
    try testing.expectEqualStrings("watch text", parseCli(&.{ "watch", "--format", "text" }, &buf).send.line);
    try testing.expectEqualStrings("watch json", parseCli(&.{"watch"}, &buf).send.line);
    try testing.expectEqualStrings("watch text", parseCli(&.{ "watch", "--format=text" }, &buf).send.line);
    try testing.expectEqual(Cli.Bad.format, parseCli(&.{ "watch", "--format" }, &buf).bad);
    try testing.expectEqual(Cli.Bad.format, parseCli(&.{ "watch", "--format", "xml" }, &buf).bad);
    try testing.expectEqual(Cli.Bad.format, parseCli(&.{ "watch", "-x" }, &buf).bad);
    // Uma quebra de linha não pode virar um segundo comando.
    try testing.expectEqual(Cli.Bad.newline, parseCli(&.{ "status", "x\nmute" }, &buf).bad);
    var small: [8]u8 = undefined;
    try testing.expectEqual(Cli.Bad.too_long, parseCli(&.{ "open", "123456789" }, &small).bad);
    try testing.expectEqualStrings("status", parseCli(&.{"status"}, &small).send.line);
}

test "aperte para falar de fora" {
    // Fora do modo: erro claro, apertando ou soltando.
    try testing.expectEqual(PttResult{ .err = .not_ptt }, ptt(.down, false, false, true));
    try testing.expectEqual(PttResult{ .err = .not_ptt }, ptt(.up, true, false, true));
    try testing.expectEqual(PttResult{ .err = .not_ptt }, ptt(.toggle, false, false, true));
    // Na call.
    try testing.expectEqual(PttResult{ .held = true }, ptt(.down, false, true, true));
    try testing.expectEqual(PttResult{ .held = true }, ptt(.down, true, true, true));
    try testing.expectEqual(PttResult{ .held = false }, ptt(.up, true, true, true));
    try testing.expectEqual(PttResult{ .held = true }, ptt(.toggle, false, true, true));
    try testing.expectEqual(PttResult{ .held = false }, ptt(.toggle, true, true, true));
    // Fora da call: apertar não, soltar sempre (a call caiu com a tecla apertada).
    try testing.expectEqual(PttResult{ .err = .no_call }, ptt(.down, false, true, false));
    try testing.expectEqual(PttResult{ .err = .no_call }, ptt(.toggle, false, true, false));
    try testing.expectEqual(PttResult{ .held = false }, ptt(.up, true, true, false));
    try testing.expectEqual(PttResult{ .held = false }, ptt(.toggle, true, true, false));
}

test "JSON do status e das não lidas" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const s: Snapshot = .{
        .connection = "ready",
        .connected = true,
        .account_id = 1000,
        .account = "Vo\"cê",
        .muted = true,
        .ptt_mode = true,
        .call = .{ .state = "connected", .channel_id = 500014, .channel = "Geral", .guild_id = 7, .guild = "larperCord" },
        .mentions = 3,
        .dms = 1,
        .channels = 5,
    };
    try statusJson(&out, gpa, &s);
    try testing.expectEqualStrings(
        \\{"connected":true,"connection":"ready","demo":false,"account":{"id":"1000","name":"Vo\"cê"},"window":"shown","presence":"online","latency_ms":0,"voice":{"muted":true,"deafened":false,"mode":"push_to_talk","ptt_held":false,"call":{"state":"connected","channel_id":"500014","channel":"Geral","guild_id":"7","guild":"larperCord","members":[]}},"unread":{"mentions":3,"dms":1,"channels":5}}
    , out.items);
    // O JSON é válido (o std lê de volta).
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.items, .{});
    parsed.deinit();
    out.clearRetainingCapacity();
    // Na tela de login: sem conta e sem call; numa DM, sem servidor.
    try statusJson(&out, gpa, &.{});
    try testing.expectEqualStrings(
        \\{"connected":false,"connection":"logged_out","demo":false,"account":null,"window":"shown","presence":"online","latency_ms":0,"voice":{"muted":false,"deafened":false,"mode":"voice_activity","ptt_held":false,"call":null},"unread":{"mentions":0,"dms":0,"channels":0}}
    , out.items);
    out.clearRetainingCapacity();
    try statusJson(&out, gpa, &.{ .connected = true, .call = .{ .state = "connecting", .channel_id = 9, .channel = "ana" } });
    try testing.expect(std.mem.indexOf(u8, out.items, "\"guild_id\":null,\"guild\":null") != null);
    out.clearRetainingCapacity();
    try unreadJson(&out, gpa, &s);
    try testing.expectEqualStrings("{\"mentions\":3,\"dms\":1,\"channels\":5}", out.items);
}

test "quem está na call, o status e o volume" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const gpa = testing.allocator;
    const members = [_]Member{
        .{ .id = 1001, .name = "Ana", .avatar = "https://cdn.discordapp.com/avatars/1001/a.png", .speaking = true },
        .{ .id = 1000, .name = "Eu", .muted = true, .self = true, .volume = 1.5 },
    };
    try statusJson(&out, gpa, &.{ .connected = true, .presence = "dnd", .latency_ms = 42, .call = .{ .state = "connected", .channel_id = 9, .channel = "Call", .guild_id = 7, .guild = "g", .members = &members } });
    try testing.expect(std.mem.indexOf(u8, out.items, "\"presence\":\"dnd\",\"latency_ms\":42") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"members\":[{\"id\":\"1001\",\"name\":\"Ana\",\"avatar\":\"https://cdn.discordapp.com/avatars/1001/a.png\",\"speaking\":true,\"muted\":false,\"deafened\":false,\"self\":false,\"volume\":1.00}") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"self\":true,\"volume\":1.50}]") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.items, .{});
    parsed.deinit();
    try testing.expectEqual(@as(?@TypeOf(parsePresence("x").?), .offline), parsePresence("invisible"));
    try testing.expectEqual(@as(?@TypeOf(parsePresence("x").?), .idle), parsePresence("IDLE"));
    try testing.expectEqual(@as(?@TypeOf(parsePresence("x").?), null), parsePresence("busy"));
    try testing.expectEqual(@as(?f32, 0.5), parseVolume("50"));
    try testing.expectEqual(@as(?f32, 2), parseVolume("200%"));
    try testing.expectEqual(@as(?f32, null), parseVolume("201"));
    try testing.expectEqual(@as(?f32, null), parseVolume("-1"));
}

test "estado principal para os ícones" {
    try testing.expectEqualStrings("offline", state(&.{ .mentions = 4 }));
    try testing.expectEqualStrings("idle", state(&.{ .connected = true }));
    try testing.expectEqualStrings("unread", state(&.{ .connected = true, .channels = 2 }));
    try testing.expectEqualStrings("mention", state(&.{ .connected = true, .channels = 2, .mentions = 1 }));
    const call: Call = .{ .state = "connected", .channel_id = 1, .channel = "Geral" };
    // Na call, o estado dela ganha das menções.
    try testing.expectEqualStrings("call", state(&.{ .connected = true, .mentions = 1, .call = call }));
    try testing.expectEqualStrings("muted", state(&.{ .connected = true, .muted = true, .call = call }));
    try testing.expectEqualStrings("deafened", state(&.{ .connected = true, .muted = true, .deafened = true, .call = call }));
    try testing.expectEqualStrings("talking", state(&.{ .connected = true, .ptt_mode = true, .ptt_held = true, .call = call }));
    // Mudo com a tecla apertada não está falando.
    try testing.expectEqualStrings("muted", state(&.{ .connected = true, .ptt_mode = true, .ptt_held = true, .muted = true, .call = call }));
    // Fora da call, mudo não é o estado principal.
    try testing.expectEqualStrings("idle", state(&.{ .connected = true, .muted = true }));
}

test "waybar: texto, tooltip, classes e alt" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const l: Labels = .{ .head = "larperCord — Você", .call = "In call: Geral (larperCord)", .counts = "Mentions: 2" };
    const call: Call = .{ .state = "connected", .channel_id = 1, .channel = "Geral" };
    try waybar(&out, gpa, &.{ .connected = true, .muted = true, .mentions = 2, .channels = 1, .call = call }, &l);
    try testing.expectEqualStrings(
        \\{"text":"2","tooltip":"larperCord — Você\nIn call: Geral (larperCord) · muted\nMentions: 2","class":["call","muted","mention","unread"],"alt":"muted"}
    , out.items);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.items, .{});
    parsed.deinit();
    // Nada acontecendo: texto vazio (o formato do módulo põe o ícone).
    out.clearRetainingCapacity();
    try waybar(&out, gpa, &.{ .connected = true }, &.{ .head = "larperCord — Você" });
    try testing.expectEqualStrings("{\"text\":\"\",\"tooltip\":\"larperCord — Você\",\"class\":[\"idle\"],\"alt\":\"idle\"}", out.items);
    // Sem conexão: as contas e a call não aparecem, mesmo que existam.
    out.clearRetainingCapacity();
    try waybar(&out, gpa, &.{ .mentions = 3, .call = call }, &.{ .head = "larperCord isn't running", .call = "x", .counts = "y" });
    try testing.expectEqualStrings("{\"text\":\"\",\"tooltip\":\"larperCord isn't running\",\"class\":[\"offline\"],\"alt\":\"offline\"}", out.items);
}

test "linha de texto para o polybar" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const l: Labels = .{ .head = "", .muted = "mudo", .offline = "sem conexão" };
    try textLine(&out, gpa, &.{ .connected = true, .muted = true, .mentions = 3, .dms = 1, .channels = 5, .call = .{ .state = "connected", .channel_id = 1, .channel = "Geral" } }, &l);
    try testing.expectEqualStrings("Geral · mudo · @3 · DM 1 · #5", out.items);
    out.clearRetainingCapacity();
    try textLine(&out, gpa, &.{ .connected = true, .channels = 2 }, &l);
    try testing.expectEqualStrings("#2", out.items);
    out.clearRetainingCapacity();
    try textLine(&out, gpa, &.{ .connected = true }, &l);
    try testing.expectEqualStrings("", out.items);
    out.clearRetainingCapacity();
    try textLine(&out, gpa, &.{}, &l);
    try testing.expectEqualStrings("sem conexão", out.items);
}

test "cada código tem mensagem e volta pelo nome" {
    for (std.enums.values(Code)) |code| {
        try testing.expect(code.message().len > 0);
        try testing.expectEqual(code, Code.parse(@tagName(code)).?);
    }
}
