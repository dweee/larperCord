//! As notificações do sistema que respondem, sem nada do app nem do sistema
//! (testado em `zig build test`): o que cada botão leva (`mark-read:<canal>:<msg>`),
//! os botões e as dicas da notificação do D-Bus conforme o servidor
//! (org.freedesktop.Notifications: o KDE Plasma tem caixa de texto, o GNOME só
//! botões), o XML do aviso do Windows, as notificações vivas de cada lado e o que
//! um clique, um botão ou uma resposta pedem ao app. Quem fala com o sistema é
//! platform/notif_dbus.zig e platform/notif_win.zig; quem age é app_notificacao.zig.
const std = @import("std");

pub const Id = u64;

/// A mensagem da notificação: clicar abre a conversa nela. Zero: um aviso que só
/// traz a janela (lembrete, versão nova, plugin).
pub const Alvo = struct { canal: Id = 0, msg: Id = 0 };

pub const Tipo = enum {
    /// Lembrete, chamada, versão nova, plugin: clicar só traz a janela.
    simples,
    /// DM ou menção: os botões "Marcar como lida" e "Responder".
    mensagem,
    /// A resposta pela notificação não saiu: clicar abre a conversa com a
    /// resposta pronta para tentar de novo.
    falha,
};

pub const Acao = enum {
    /// Traz a janela e abre a conversa na mensagem.
    abrir,
    /// Marca a conversa como lida, sem mostrar a janela.
    lida,
    /// Manda `texto` como resposta à mensagem, sem mostrar a janela.
    responder,
    /// Traz a janela na conversa, com a resposta à mensagem pronta na caixa.
    escrever,
};

/// O que um clique, um botão ou uma resposta pedem. `texto` e `ficha` (a ficha
/// do xdg-activation, para a janela vir com o foco no Wayland) são emprestados,
/// menos numa cópia (`copiar`), que guarda os dois em `buf`.
pub const Pedido = struct {
    acao: Acao,
    alvo: Alvo,
    texto: []const u8 = "",
    ficha: []const u8 = "",
    buf: []u8 = &.{},

    pub fn copiar(p: Pedido, gpa: std.mem.Allocator) !Pedido {
        const buf = try gpa.alloc(u8, p.texto.len + p.ficha.len);
        @memcpy(buf[0..p.texto.len], p.texto);
        @memcpy(buf[p.texto.len..], p.ficha);
        return .{ .acao = p.acao, .alvo = p.alvo, .texto = buf[0..p.texto.len], .ficha = buf[p.texto.len..], .buf = buf };
    }
};

/// Os textos dos botões, no idioma do app.
pub const Rotulos = struct {
    abrir: []const u8 = "Open",
    lida: []const u8 = "Mark as read",
    responder: []const u8 = "Reply",
};

/// Uma notificação para mostrar. Emprestada, menos numa cópia (`copiar`), que
/// guarda os textos em `buf`.
pub const Aviso = struct {
    titulo: []const u8,
    corpo: []const u8,
    alvo: Alvo = .{},
    tipo: Tipo = .simples,
    /// Os botões de uma mensagem (Configurações → Notificações).
    botoes: bool = false,
    rotulos: Rotulos = .{},
    /// O que a caixa de texto da resposta mostra vazia ("Responder a Ana…").
    dica: []const u8 = "",
    buf: []u8 = &.{},

    pub fn copiar(a: Aviso, gpa: std.mem.Allocator) !Aviso {
        const partes = [_][]const u8{ a.titulo, a.corpo, a.rotulos.abrir, a.rotulos.lida, a.rotulos.responder, a.dica };
        var total: usize = 0;
        for (partes) |p| total += p.len;
        const buf = try gpa.alloc(u8, total);
        var fatias: [partes.len][]const u8 = undefined;
        var at: usize = 0;
        for (partes, 0..) |p, i| {
            @memcpy(buf[at..][0..p.len], p);
            fatias[i] = buf[at..][0..p.len];
            at += p.len;
        }
        var out = a;
        out.titulo = fatias[0];
        out.corpo = fatias[1];
        out.rotulos = .{ .abrir = fatias[2], .lida = fatias[3], .responder = fatias[4] };
        out.dica = fatias[5];
        out.buf = buf;
        return out;
    }
};

/// O que volta do lado do sistema para o app (as cópias são do app soltar).
pub const Volta = union(enum) {
    pedido: Pedido,
    /// Não deu para mostrar por ali (sem servidor, recusada): quem chamou mostra
    /// do jeito de antes (notify-send, o aviso da bandeja), e ela não se perde.
    devolvida: Aviso,

    pub fn liberar(v: Volta, gpa: std.mem.Allocator) void {
        switch (v) {
            .pedido => |p| gpa.free(p.buf),
            .devolvida => |a| gpa.free(a.buf),
        }
    }
};

// --- O que cada botão leva -------------------------------------------------------

/// A chave de um botão: a ação e a mensagem, `mark-read:<canal>:<msg>`. É o que o
/// D-Bus devolve no ActionInvoked e o `arguments` do aviso do Windows.
pub fn chave(buf: []u8, acao: Acao, alvo: Alvo) []const u8 {
    const nome = switch (acao) {
        .abrir => "open",
        .lida => "mark-read",
        .responder => "reply",
        .escrever => "write",
    };
    return std.fmt.bufPrint(buf, "{s}:{d}:{d}", .{ nome, alvo.canal, alvo.msg }) catch "";
}

pub const Lida = struct { acao: Acao, alvo: Alvo };

pub fn lerChave(s: []const u8) ?Lida {
    var it = std.mem.splitScalar(u8, s, ':');
    const nome = it.next() orelse return null;
    const canal = std.fmt.parseInt(Id, it.next() orelse return null, 10) catch return null;
    const msg = std.fmt.parseInt(Id, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    const acao: Acao = if (eql(nome, "open"))
        .abrir
    else if (eql(nome, "mark-read"))
        .lida
    else if (eql(nome, "reply"))
        .responder
    else if (eql(nome, "write"))
        .escrever
    else
        return null;
    // Uma ação sobre uma mensagem precisa dela; abrir sem nada só traz a janela.
    if (acao != .abrir and (canal == 0 or msg == 0)) return null;
    return .{ .acao = acao, .alvo = .{ .canal = canal, .msg = msg } };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// --- O servidor do D-Bus ---------------------------------------------------------

/// O que o servidor de notificações diz que sabe fazer (GetCapabilities).
pub const Caps = struct {
    /// Botões (o "default" é o clique na notificação).
    acoes: bool = false,
    /// A caixa de texto da resposta (o KDE Plasma: `inline-reply`).
    resposta: bool = false,
    /// O corpo é lido como marcação (`<b>`, `&amp;`): o texto da mensagem é escapado.
    markup: bool = false,

    pub fn de(lista: []const []const u8) Caps {
        var c: Caps = .{};
        for (lista) |s| {
            if (eql(s, "actions")) c.acoes = true;
            if (eql(s, "inline-reply")) c.resposta = true;
            if (eql(s, "body-markup")) c.markup = true;
        }
        // Caixa de texto sem botões não tem como aparecer.
        if (!c.acoes) c.resposta = false;
        return c;
    }
};

pub const Botao = struct { chave: []const u8, rotulo: []const u8 };

/// As chaves dos botões de uma notificação (os textos que `botoesDbus` aponta).
pub const Chaves = struct {
    lida: [64]u8 = undefined,
    responder: [64]u8 = undefined,
};

/// Os botões do Notify, na ordem. Sem botões no servidor, nenhum (nem o clique):
/// uma notificação que não faz nada ao clicar é melhor que uma que promete. Com
/// caixa de texto, "Responder" é o `inline-reply` do KDE (a resposta volta no
/// NotificationReplied); sem ela, "Responder" abre a conversa com a resposta pronta.
pub fn botoesDbus(out: *[3]Botao, chaves: *Chaves, caps: Caps, a: Aviso) []const Botao {
    if (!caps.acoes) return out[0..0];
    out[0] = .{ .chave = "default", .rotulo = a.rotulos.abrir };
    if (a.tipo != .mensagem or !a.botoes or a.alvo.msg == 0) return out[0..1];
    out[1] = .{ .chave = chave(&chaves.lida, .lida, a.alvo), .rotulo = a.rotulos.lida };
    out[2] = .{ .chave = if (caps.resposta) "inline-reply" else chave(&chaves.responder, .responder, a.alvo), .rotulo = a.rotulos.responder };
    return out[0..3];
}

/// Mostra a caixa de texto da resposta nesta notificação?
pub fn temCaixa(caps: Caps, a: Aviso) bool {
    return caps.resposta and a.tipo == .mensagem and a.botoes and a.alvo.msg != 0;
}

pub const Modo = enum {
    /// Texto puro (o título; o corpo sem `body-markup`).
    texto,
    /// O corpo com `body-markup`: & < > viram entidades.
    markup,
    /// Texto e atributos do XML do Windows: & < > " ' viram entidades.
    xml,
};

/// UTF-8 válido (a libdbus derruba o processo com UTF-8 quebrado; o XmlDocument do
/// Windows recusa o XML), sem caracteres de controle (menos quebra de linha e
/// tabulação) e com o escape do `modo`.
pub fn limpar(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8, modo: Modo) !void {
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        if (n == 0 or i + n > s.len or !std.unicode.utf8ValidateSlice(s[i..][0..n])) {
            try out.appendSlice(gpa, "\u{FFFD}");
            i += 1;
            continue;
        }
        const seq = s[i..][0..n];
        i += n;
        if (n == 1) {
            const ch = seq[0];
            if (ch < 0x20 and ch != '\n' and ch != '\t') continue;
            if (ch == 0x7f) continue;
            const ent: ?[]const u8 = switch (ch) {
                '&' => if (modo != .texto) "&amp;" else null,
                '<' => if (modo != .texto) "&lt;" else null,
                '>' => if (modo != .texto) "&gt;" else null,
                '"' => if (modo == .xml) "&quot;" else null,
                '\'' => if (modo == .xml) "&apos;" else null,
                else => null,
            };
            if (ent) |e| try out.appendSlice(gpa, e) else try out.append(gpa, ch);
            continue;
        }
        // U+FFFE e U+FFFF não existem no XML.
        if (modo == .xml and n == 3 and seq[0] == 0xEF and seq[1] == 0xBF and seq[2] >= 0xBE) continue;
        try out.appendSlice(gpa, seq);
    }
}

// --- As notificações vivas (D-Bus) -------------------------------------------------

pub const max_vivas = 16;
pub const ficha_max = 255;

pub const Entrada = struct {
    id: u32 = 0,
    alvo: Alvo = .{},
    tipo: Tipo = .simples,
    ficha_len: u8 = 0,
    ficha: [ficha_max]u8 = undefined,

    pub fn fichaSlice(e: *const Entrada) []const u8 {
        return e.ficha[0..e.ficha_len];
    }
};

/// As notificações nossas ainda na tela ou na central, da mais velha para a mais
/// nova. O ActionInvoked vai para todo mundo que escuta o servidor: um id que não
/// está aqui é de outro programa e fica sem resposta.
pub const Tabela = struct {
    itens: [max_vivas]Entrada = undefined,
    n: usize = 0,

    /// Guarda a notificação que o servidor acabou de numerar. Cheia, a mais velha
    /// sai e o id dela volta: quem chama a fecha, que os botões dela não teriam
    /// mais o que fazer.
    pub fn por(t: *Tabela, id: u32, alvo: Alvo, tipo: Tipo) ?u32 {
        if (t.achar(id)) |e| {
            e.* = .{ .id = id, .alvo = alvo, .tipo = tipo };
            return null;
        }
        var saiu: ?u32 = null;
        if (t.n == max_vivas) {
            saiu = t.itens[0].id;
            std.mem.copyForwards(Entrada, t.itens[0 .. t.n - 1], t.itens[1..t.n]);
            t.n -= 1;
        }
        t.itens[t.n] = .{ .id = id, .alvo = alvo, .tipo = tipo };
        t.n += 1;
        return saiu;
    }

    pub fn achar(t: *Tabela, id: u32) ?*Entrada {
        for (t.itens[0..t.n]) |*e| if (e.id == id) return e;
        return null;
    }

    pub fn tirar(t: *Tabela, id: u32) void {
        for (t.itens[0..t.n], 0..) |e, i| if (e.id == id) {
            std.mem.copyForwards(Entrada, t.itens[i .. t.n - 1], t.itens[i + 1 .. t.n]);
            t.n -= 1;
            return;
        };
    }

    /// A ficha do xdg-activation chega (ActivationToken) logo antes da ação.
    pub fn guardarFicha(t: *Tabela, id: u32, ficha: []const u8) void {
        const e = t.achar(id) orelse return;
        if (ficha.len > ficha_max) return;
        @memcpy(e.ficha[0..ficha.len], ficha);
        e.ficha_len = @intCast(ficha.len);
    }

    /// Tira as da conversa `canal` (0: todas) e devolve os ids, para fechar.
    pub fn tirarDoCanal(t: *Tabela, canal: Id, out: *[max_vivas]u32) []const u32 {
        var n: usize = 0;
        var i: usize = 0;
        while (i < t.n) {
            if (canal == 0 or t.itens[i].alvo.canal == canal) {
                out[n] = t.itens[i].id;
                n += 1;
                std.mem.copyForwards(Entrada, t.itens[i .. t.n - 1], t.itens[i + 1 .. t.n]);
                t.n -= 1;
            } else i += 1;
        }
        return out[0..n];
    }
};

/// O ActionInvoked (id, chave): o que ele pede, ou nulo (de outro programa, ou uma
/// chave que não é desta notificação).
pub fn deAcao(t: *Tabela, id: u32, k: []const u8) ?Pedido {
    const e = t.achar(id) orelse return null;
    const ficha = e.fichaSlice();
    if (eql(k, "default")) return .{ .acao = if (e.tipo == .falha) .escrever else .abrir, .alvo = e.alvo, .ficha = ficha };
    // O botão da caixa de texto, num servidor que o manda como ação: abre a caixa daqui.
    if (eql(k, "inline-reply")) return if (e.tipo == .mensagem) .{ .acao = .escrever, .alvo = e.alvo, .ficha = ficha } else null;
    const l = lerChave(k) orelse return null;
    if (l.alvo.canal != e.alvo.canal or l.alvo.msg != e.alvo.msg) return null;
    // Sem a caixa de texto no servidor, "Responder" abre a caixa do app.
    return .{ .acao = if (l.acao == .responder) .escrever else l.acao, .alvo = l.alvo, .ficha = ficha };
}

/// O NotificationReplied (id, texto) do KDE: a resposta digitada na notificação.
/// Vazia, abre a caixa do app com a resposta pronta.
pub fn deResposta(t: *Tabela, id: u32, texto: []const u8) ?Pedido {
    const e = t.achar(id) orelse return null;
    if (e.tipo != .mensagem) return null;
    const limpo = std.mem.trim(u8, texto, " \t\r\n");
    return .{ .acao = if (limpo.len == 0) .escrever else .responder, .alvo = e.alvo, .texto = limpo, .ficha = e.fichaSlice() };
}

// --- O aviso do Windows -------------------------------------------------------------

/// O id da caixa de texto no XML (o que volta em UserInput).
pub const caixa_id = "reply";

/// O XML do ToastNotification: o clique leva `open:<canal>:<msg>` (ou `write:`, numa
/// falha), e uma mensagem com botões ganha a caixa de texto, "Responder" (que leva o
/// que foi digitado) e "Marcar como lida".
pub fn toastXml(gpa: std.mem.Allocator, out: *std.ArrayList(u8), a: Aviso) !void {
    var kb: [64]u8 = undefined;
    try out.appendSlice(gpa, "<toast launch=\"");
    try limpar(gpa, out, chave(&kb, if (a.tipo == .falha) .escrever else .abrir, a.alvo), .xml);
    try out.appendSlice(gpa, "\"><visual><binding template=\"ToastGeneric\"><text>");
    try limpar(gpa, out, a.titulo, .xml);
    try out.appendSlice(gpa, "</text><text>");
    try limpar(gpa, out, a.corpo, .xml);
    try out.appendSlice(gpa, "</text></binding></visual>");
    if (a.tipo == .mensagem and a.botoes and a.alvo.msg != 0) {
        try out.appendSlice(gpa, "<actions><input id=\"" ++ caixa_id ++ "\" type=\"text\" placeHolderContent=\"");
        try limpar(gpa, out, a.dica, .xml);
        try out.appendSlice(gpa, "\"/><action content=\"");
        try limpar(gpa, out, a.rotulos.responder, .xml);
        try out.appendSlice(gpa, "\" arguments=\"");
        try limpar(gpa, out, chave(&kb, .responder, a.alvo), .xml);
        try out.appendSlice(gpa, "\" hint-inputId=\"" ++ caixa_id ++ "\"/><action content=\"");
        try limpar(gpa, out, a.rotulos.lida, .xml);
        try out.appendSlice(gpa, "\" arguments=\"");
        try limpar(gpa, out, chave(&kb, .lida, a.alvo), .xml);
        try out.appendSlice(gpa, "\"/></actions>");
    }
    try out.appendSlice(gpa, "</toast>");
}

/// O Activated do aviso: os `arguments` do que foi clicado e o que estava na caixa.
/// "Responder" com a caixa vazia abre a caixa do app.
pub fn deToast(args: []const u8, texto: []const u8) ?Pedido {
    const l = lerChave(args) orelse return null;
    const limpo = std.mem.trim(u8, texto, " \t\r\n");
    if (l.acao == .responder) return .{ .acao = if (limpo.len == 0) .escrever else .responder, .alvo = l.alvo, .texto = limpo };
    return .{ .acao = l.acao, .alvo = l.alvo };
}

// --- Testes ---------------------------------------------------------------------------

const tt = std.testing;

test "chave: ida e volta, e o que não é nosso" {
    var b: [64]u8 = undefined;
    const alvo: Alvo = .{ .canal = 1234567890123456789, .msg = 18446744073709551615 };
    for ([_]Acao{ .abrir, .lida, .responder, .escrever }) |a| {
        const k = chave(&b, a, alvo);
        const l = lerChave(k).?;
        try tt.expectEqual(a, l.acao);
        try tt.expectEqual(alvo, l.alvo);
    }
    try tt.expectEqualStrings("mark-read:5:7", chave(&b, .lida, .{ .canal = 5, .msg = 7 }));
    try tt.expectEqualStrings("open:0:0", chave(&b, .abrir, .{}));
    try tt.expectEqual(Acao.abrir, lerChave("open:0:0").?.acao);
    // Ação sobre mensagem sem a mensagem, nome estranho, partes a mais ou a menos.
    try tt.expect(lerChave("mark-read:0:0") == null);
    try tt.expect(lerChave("reply:5:0") == null);
    try tt.expect(lerChave("default") == null);
    try tt.expect(lerChave("delete:5:7") == null);
    try tt.expect(lerChave("open:5:7:8") == null);
    try tt.expect(lerChave("open:5") == null);
    try tt.expect(lerChave("open:-5:7") == null);
    try tt.expect(lerChave("open:5:99999999999999999999") == null);
    try tt.expect(lerChave("") == null);
}

test "caps: o que o servidor sabe" {
    const kde = Caps.de(&.{ "body", "body-hyperlinks", "body-markup", "actions", "inline-reply", "x-kde-urls" });
    try tt.expect(kde.acoes and kde.resposta and kde.markup);
    const gnome = Caps.de(&.{ "actions", "body", "body-markup", "persistence", "sound" });
    try tt.expect(gnome.acoes and !gnome.resposta and gnome.markup);
    // Caixa de texto sem botões: nenhum dos dois.
    const estranho = Caps.de(&.{ "body", "inline-reply" });
    try tt.expect(!estranho.acoes and !estranho.resposta and !estranho.markup);
    try tt.expectEqual(Caps{}, Caps.de(&.{}));
}

test "botões do D-Bus: KDE, GNOME, sem botões e desligados" {
    var out: [3]Botao = undefined;
    var ch: Chaves = .{};
    const msg: Aviso = .{ .titulo = "Ana", .corpo = "oi", .alvo = .{ .canal = 10, .msg = 20 }, .tipo = .mensagem, .botoes = true, .rotulos = .{ .abrir = "Abrir", .lida = "Marcar como lida", .responder = "Responder" } };
    const kde: Caps = .{ .acoes = true, .resposta = true };
    const b1 = botoesDbus(&out, &ch, kde, msg);
    try tt.expectEqual(@as(usize, 3), b1.len);
    try tt.expectEqualStrings("default", b1[0].chave);
    try tt.expectEqualStrings("Abrir", b1[0].rotulo);
    try tt.expectEqualStrings("mark-read:10:20", b1[1].chave);
    try tt.expectEqualStrings("Marcar como lida", b1[1].rotulo);
    try tt.expectEqualStrings("inline-reply", b1[2].chave);
    try tt.expect(temCaixa(kde, msg));

    const gnome: Caps = .{ .acoes = true };
    const b2 = botoesDbus(&out, &ch, gnome, msg);
    try tt.expectEqual(@as(usize, 3), b2.len);
    try tt.expectEqualStrings("reply:10:20", b2[2].chave);
    try tt.expectEqualStrings("Responder", b2[2].rotulo);
    try tt.expect(!temCaixa(gnome, msg));

    // Desligado nas configurações, ou um aviso simples: só o clique.
    var sem = msg;
    sem.botoes = false;
    try tt.expectEqual(@as(usize, 1), botoesDbus(&out, &ch, kde, sem).len);
    try tt.expect(!temCaixa(kde, sem));
    const lembrete: Aviso = .{ .titulo = "Lembrete", .corpo = "x" };
    try tt.expectEqual(@as(usize, 1), botoesDbus(&out, &ch, kde, lembrete).len);
    var falha = msg;
    falha.tipo = .falha;
    try tt.expectEqual(@as(usize, 1), botoesDbus(&out, &ch, kde, falha).len);
    // Servidor sem botões: nada, nem o clique.
    try tt.expectEqual(@as(usize, 0), botoesDbus(&out, &ch, .{}, msg).len);
}

test "limpar: escape, UTF-8 quebrado e controle" {
    const gpa = tt.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try limpar(gpa, &out, "a<b>&\"c\" 'd'", .texto);
    try tt.expectEqualStrings("a<b>&\"c\" 'd'", out.items);
    out.clearRetainingCapacity();
    try limpar(gpa, &out, "<b>oi</b> & tchau \"x\"", .markup);
    try tt.expectEqualStrings("&lt;b&gt;oi&lt;/b&gt; &amp; tchau \"x\"", out.items);
    out.clearRetainingCapacity();
    try limpar(gpa, &out, "</text><action arguments='x'/>&amp;\"", .xml);
    try tt.expectEqualStrings("&lt;/text&gt;&lt;action arguments=&apos;x&apos;/&gt;&amp;amp;&quot;", out.items);
    out.clearRetainingCapacity();
    // UTF-8 quebrado vira U+FFFD; o certo (acento, emoji, japonês) passa igual.
    try limpar(gpa, &out, "ok\xff\xc3 é 🙂 日本", .texto);
    try tt.expectEqualStrings("ok\u{FFFD}\u{FFFD} é 🙂 日本", out.items);
    out.clearRetainingCapacity();
    // Sequência cortada no fim.
    try limpar(gpa, &out, "x\xe6\x97", .markup);
    try tt.expectEqualStrings("x\u{FFFD}\u{FFFD}", out.items);
    out.clearRetainingCapacity();
    // Controle sai; quebra de linha e tabulação ficam.
    try limpar(gpa, &out, "a\x00b\x07c\nd\te\x1b[0m\x7f", .xml);
    try tt.expectEqualStrings("abc\nd\te[0m", out.items);
    out.clearRetainingCapacity();
    // U+FFFE/U+FFFF não entram no XML.
    try limpar(gpa, &out, "a\u{FFFE}b\u{FFFF}c\u{FFFD}", .xml);
    try tt.expectEqualStrings("abc\u{FFFD}", out.items);
}

test "tabela: guardar, achar, a mais velha sai e as da conversa" {
    var t: Tabela = .{};
    var i: u32 = 1;
    while (i <= max_vivas) : (i += 1) try tt.expect(t.por(i, .{ .canal = if (i % 2 == 0) 100 else 200, .msg = i }, .mensagem) == null);
    try tt.expectEqual(@as(usize, max_vivas), t.n);
    // Cheia: a 1 sai para a 17 entrar.
    try tt.expectEqual(@as(?u32, 1), t.por(17, .{ .canal = 300, .msg = 17 }, .simples));
    try tt.expect(t.achar(1) == null);
    try tt.expectEqual(@as(Id, 17), t.achar(17).?.alvo.msg);
    // O mesmo id de novo (replaces_id): troca, não ocupa outro lugar.
    try tt.expect(t.por(17, .{ .canal = 300, .msg = 18 }, .simples) == null);
    try tt.expectEqual(@as(usize, max_vivas), t.n);
    try tt.expectEqual(@as(Id, 18), t.achar(17).?.alvo.msg);
    t.tirar(17);
    try tt.expect(t.achar(17) == null);
    var ids: [max_vivas]u32 = undefined;
    const pares = t.tirarDoCanal(100, &ids);
    try tt.expectEqual(@as(usize, 8), pares.len);
    for (pares) |id| try tt.expect(id % 2 == 0);
    try tt.expectEqual(@as(usize, 7), t.n);
    for (t.itens[0..t.n]) |e| try tt.expectEqual(@as(Id, 200), e.alvo.canal);
    try tt.expectEqual(@as(usize, 7), t.tirarDoCanal(0, &ids).len);
    try tt.expectEqual(@as(usize, 0), t.n);
}

test "sinais: ação, resposta, ficha e o que é de outro programa" {
    var t: Tabela = .{};
    _ = t.por(7, .{ .canal = 10, .msg = 20 }, .mensagem);
    _ = t.por(8, .{}, .simples);
    _ = t.por(9, .{ .canal = 10, .msg = 21 }, .falha);
    // De outro programa: nada.
    try tt.expect(deAcao(&t, 99, "default") == null);
    try tt.expect(deResposta(&t, 99, "oi") == null);
    // O clique, com a ficha que veio antes.
    t.guardarFicha(7, "ficha-xyz");
    const p = deAcao(&t, 7, "default").?;
    try tt.expectEqual(Acao.abrir, p.acao);
    try tt.expectEqual(Alvo{ .canal = 10, .msg = 20 }, p.alvo);
    try tt.expectEqualStrings("ficha-xyz", p.ficha);
    try tt.expectEqual(Acao.lida, deAcao(&t, 7, "mark-read:10:20").?.acao);
    // Uma chave de outra mensagem (outro programa com o mesmo nome) não vale.
    try tt.expect(deAcao(&t, 7, "mark-read:10:99") == null);
    try tt.expect(deAcao(&t, 7, "qualquer") == null);
    // GNOME: "Responder" sem caixa abre a do app.
    try tt.expectEqual(Acao.escrever, deAcao(&t, 7, "reply:10:20").?.acao);
    try tt.expectEqual(Acao.escrever, deAcao(&t, 7, "inline-reply").?.acao);
    // A resposta do KDE, aparada; vazia abre a caixa.
    const r = deResposta(&t, 7, "  vou sim!\n").?;
    try tt.expectEqual(Acao.responder, r.acao);
    try tt.expectEqualStrings("vou sim!", r.texto);
    try tt.expectEqual(Acao.escrever, deResposta(&t, 7, " \n").?.acao);
    // Aviso simples: o clique só traz a janela; resposta não existe.
    const s = deAcao(&t, 8, "default").?;
    try tt.expectEqual(Acao.abrir, s.acao);
    try tt.expectEqual(Alvo{}, s.alvo);
    try tt.expect(deResposta(&t, 8, "x") == null);
    try tt.expect(deAcao(&t, 8, "inline-reply") == null);
    // A falha: o clique abre a caixa para tentar de novo.
    try tt.expectEqual(Acao.escrever, deAcao(&t, 9, "default").?.acao);
    // Ficha grande demais não entra (o clique segue sem ela).
    t.guardarFicha(8, &@as([ficha_max + 1]u8, @splat('x')));
    try tt.expectEqualStrings("", deAcao(&t, 8, "default").?.ficha);
}

test "cópias: pedido e aviso guardam os textos" {
    const gpa = tt.allocator;
    var txt = "resposta".*;
    const p = try (Pedido{ .acao = .responder, .alvo = .{ .canal = 1, .msg = 2 }, .texto = &txt, .ficha = "f" }).copiar(gpa);
    txt[0] = 'X';
    try tt.expectEqualStrings("resposta", p.texto);
    try tt.expectEqualStrings("f", p.ficha);
    (Volta{ .pedido = p }).liberar(gpa);
    const a = try (Aviso{ .titulo = "Ana", .corpo = "oi", .dica = "Responder a Ana…", .rotulos = .{ .lida = "Lida" } }).copiar(gpa);
    try tt.expectEqualStrings("Ana", a.titulo);
    try tt.expectEqualStrings("oi", a.corpo);
    try tt.expectEqualStrings("Lida", a.rotulos.lida);
    try tt.expectEqualStrings("Reply", a.rotulos.responder);
    try tt.expectEqualStrings("Responder a Ana…", a.dica);
    (Volta{ .devolvida = a }).liberar(gpa);
}

test "XML do Windows: botões, caixa e o texto escapado" {
    const gpa = tt.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const msg: Aviso = .{
        .titulo = "Ana & Cia",
        .corpo = "</text></binding><action arguments=\"mark-read:1:2\"/>",
        .alvo = .{ .canal = 10, .msg = 20 },
        .tipo = .mensagem,
        .botoes = true,
        .rotulos = .{ .abrir = "Abrir", .lida = "Marcar como lida", .responder = "Responder" },
        .dica = "Responder a \"Ana\"…",
    };
    try toastXml(gpa, &out, msg);
    try tt.expectEqualStrings(
        "<toast launch=\"open:10:20\"><visual><binding template=\"ToastGeneric\">" ++
            "<text>Ana &amp; Cia</text>" ++
            "<text>&lt;/text&gt;&lt;/binding&gt;&lt;action arguments=&quot;mark-read:1:2&quot;/&gt;</text>" ++
            "</binding></visual><actions>" ++
            "<input id=\"reply\" type=\"text\" placeHolderContent=\"Responder a &quot;Ana&quot;…\"/>" ++
            "<action content=\"Responder\" arguments=\"reply:10:20\" hint-inputId=\"reply\"/>" ++
            "<action content=\"Marcar como lida\" arguments=\"mark-read:10:20\"/>" ++
            "</actions></toast>",
        out.items,
    );
    // O texto do usuário vai escapado: as duas ações do XML são as nossas.
    try tt.expectEqual(@as(usize, 2), std.mem.count(u8, out.items, "<action "));
    out.clearRetainingCapacity();
    try toastXml(gpa, &out, .{ .titulo = "Lembrete", .corpo = "x" });
    try tt.expectEqualStrings("<toast launch=\"open:0:0\"><visual><binding template=\"ToastGeneric\"><text>Lembrete</text><text>x</text></binding></visual></toast>", out.items);
    out.clearRetainingCapacity();
    var falha = msg;
    falha.tipo = .falha;
    try toastXml(gpa, &out, falha);
    try tt.expect(std.mem.startsWith(u8, out.items, "<toast launch=\"write:10:20\">"));
    try tt.expect(std.mem.indexOf(u8, out.items, "<actions>") == null);
}

test "Activated do Windows: o clique, os botões e a caixa" {
    try tt.expectEqual(Acao.abrir, deToast("open:10:20", "").?.acao);
    try tt.expectEqual(Alvo{}, deToast("open:0:0", "").?.alvo);
    try tt.expectEqual(Acao.lida, deToast("mark-read:10:20", "ignorado").?.acao);
    const r = deToast("reply:10:20", "  já vou\r\n").?;
    try tt.expectEqual(Acao.responder, r.acao);
    try tt.expectEqualStrings("já vou", r.texto);
    try tt.expectEqual(Alvo{ .canal = 10, .msg = 20 }, r.alvo);
    try tt.expectEqual(Acao.escrever, deToast("reply:10:20", "   ").?.acao);
    try tt.expectEqual(Acao.escrever, deToast("write:10:20", "").?.acao);
    try tt.expect(deToast("", "x") == null);
    try tt.expect(deToast("--qa", "") == null);
}
