//! O op 8 com `query` (REQUEST_GUILD_MEMBERS por prefixo): o `@ab` da caixa de texto acha
//! gente do servidor inteiro, não só quem o app já viu. Num servidor grande a lista de
//! membros só traz quem está online e quem aparece na tela, e mencionar alguém offline que
//! não escreveu há pouco não dava. Sem rede, para dar para testar.
//!
//! Os limites (docs.discord.food: Gateway → Rate Limiting, e Request Guild Members). O
//! Discord aceita um op 8 por servidor por sessão a cada 30 s e a doc não separa o pedido
//! por `query` do pedido por `user_ids` (net/member_ask.zig): os dois dividem a mesma janela
//! por servidor da fila (net/gw_budget.zig, 32 s, com folga), e quem paga se passar é a
//! conta do usuário. Por isso a busca:
//!  - sai 300 ms depois da última tecla (um nome inteiro digitado depressa é um pedido só),
//!    com 2 letras ou mais;
//!  - só num servidor (nunca em DM ou grupo, onde a lista são os participantes), e só quando
//!    a lista de membros dele não tem todo mundo e o que já se conhece não enche a lista do
//!    autocompletar (quem decide isso é ui/autocomplete.zig);
//!  - pede `limit` 10, o que o cliente oficial pede no autocompletar. A doc aceita até 100,
//!    mas varrer prefixos de 100 em 100 é como se raspa a lista de um servidor, e a lista
//!    mostra 8;
//!  - nunca repete uma busca respondida, nem a continuação de uma que voltou com menos de
//!    `limit` (veio todo mundo daquele prefixo: o resto se acha aqui mesmo);
//!  - só a última espera: uma tecla nova troca a que ainda não saiu, nada se acumula, e a
//!    caixa fechada (Esc, escolher, enviar, trocar de conversa) cancela a que espera;
//!  - passa na frente do pedido dos autores de uma página do mesmo servidor (que é só o
//!    apelido e a cor nas mensagens antigas e continua juntando páginas para a janela
//!    seguinte), mas nunca antes da janela do servidor;
//!  - no máximo 4 por minuto somando todos os servidores;
//!  - um RATE_LIMITED segura o servidor como o do outro op 8 (o `retry_after`, nunca menos
//!    que a janela, dobrando; na terceira recusa seguida o op 8 de lá acaba na sessão), e a
//!    busca recusada só volta para a fila se ainda for a que a caixa quer.
//! A resposta (GUILD_MEMBERS_CHUNK com o nosso `nonce`) passa pelo mesmo caminho dos outros
//! `member` (apelido, foto, cor do cargo) e cada pedido da caixa recebe um `Reply`.
const std = @import("std");
const types = @import("../core/types.zig");
const gw_budget = @import("gw_budget.zig");
const Id = types.Id;

/// Quantos membros cada busca pede (o que o cliente oficial pede no autocompletar).
pub const limit: u8 = 10;
/// Menos letras que isso não busca (uma letra só num servidor grande é qualquer um).
pub const min_chars = 2;
/// O tamanho máximo da busca, em bytes (mais que isso não é o começo de um nome).
pub const max_len = 32;
/// Quanto esperar depois da última tecla.
pub const debounce_ms: i64 = 300;
/// No máximo tantas por minuto (gw_budget.window_ms), somando todos os servidores.
pub const per_minute: usize = 4;

/// Uma busca: o servidor e o texto (já como vai para o Discord). `len` 0 = nenhuma
/// (para a caixa cancelar a que espera).
pub const Query = struct {
    guild: Id = 0,
    buf: [max_len]u8 = @splat(0),
    len: u8 = 0,

    pub fn text(q: *const Query) []const u8 {
        return q.buf[0..q.len];
    }

    pub fn eql(a: Query, b: Query) bool {
        return a.guild == b.guild and std.mem.eql(u8, a.text(), b.text());
    }
};

/// A busca como vai para o Discord (null = não vale buscar): sem espaço nas pontas, as
/// letras ASCII em minúsculas (o Discord compara sem diferenciar), 2 letras ou mais, até
/// 32 bytes, UTF-8 válido e sem caractere de controle. Sem servidor (DM, grupo), nada.
pub fn make(guild: Id, typed: []const u8) ?Query {
    if (guild == 0) return null;
    const trimmed = std.mem.trim(u8, typed, " ");
    if (trimmed.len == 0 or trimmed.len > max_len) return null;
    const n = std.unicode.utf8CountCodepoints(trimmed) catch return null;
    if (n < min_chars) return null;
    var q: Query = .{ .guild = guild, .len = @intCast(trimmed.len) };
    for (trimmed, 0..) |ch, i| {
        if (ch < 0x20 or ch == 0x7f) return null;
        q.buf[i] = std.ascii.toLower(ch);
    }
    return q;
}

/// As buscas já respondidas nesta sessão, para não pedir de novo o que já veio.
pub const Memo = struct {
    const Entry = struct { q: Query, complete: bool };
    list: [64]Entry = undefined,
    n: usize = 0,
    /// Cheio: a próxima vaga a ser trocada (a mais antiga).
    next: usize = 0,

    /// Já veio: a mesma busca, ou o começo dela respondido com menos de `limit` (todo
    /// mundo daquele prefixo veio, então quem casa com o resto também veio).
    pub fn covers(m: *const Memo, q: Query) bool {
        for (m.list[0..m.n]) |*e| {
            if (e.q.guild != q.guild) continue;
            if (std.mem.eql(u8, e.q.text(), q.text())) return true;
            if (e.complete and std.mem.startsWith(u8, q.text(), e.q.text())) return true;
        }
        return false;
    }

    /// A busca `q` voltou com `found` membros.
    pub fn note(m: *Memo, q: Query, found: usize) void {
        const e: Entry = .{ .q = q, .complete = found < limit };
        for (m.list[0..m.n]) |*x| if (x.q.eql(q)) {
            x.* = e;
            return;
        };
        if (m.n < m.list.len) {
            m.list[m.n] = e;
            m.n += 1;
            return;
        }
        m.list[m.next] = e;
        m.next = (m.next + 1) % m.list.len;
    }

    /// Saímos do servidor: o que se sabia de lá não vale mais.
    pub fn forgetGuild(m: *Memo, guild: Id) void {
        var k: usize = 0;
        for (m.list[0..m.n]) |e| if (e.q.guild != guild) {
            m.list[k] = e;
            k += 1;
        };
        m.n = k;
        m.next = 0;
    }
};

/// Como um pedido da caixa terminou. `answered`: o Discord respondeu (`found` membros, já
/// no Store); `covered`: não precisou pedir (uma resposta anterior já trouxe todo mundo);
/// `dropped`: não vai ter resposta (outra busca entrou no lugar, a caixa cancelou, o
/// Discord recusou, a conexão caiu, saímos do servidor).
pub const Result = enum { answered, covered, dropped };
pub const Reply = struct { q: Query, result: Result, found: u8 = 0 };

/// As respostas de uma vez (no máximo as que saíram, a que espera e a nova).
pub const Replies = struct {
    list: [per_minute + 3]Reply = undefined,
    n: usize = 0,

    fn add(r: *Replies, q: Query, result: Result, found: usize) void {
        if (r.n == r.list.len) return;
        r.list[r.n] = .{ .q = q, .result = result, .found = @intCast(@min(found, 255)) };
        r.n += 1;
    }

    pub fn slice(r: *const Replies) []const Reply {
        return r.list[0..r.n];
    }
};

/// Uma busca que saiu e espera o GUILD_MEMBERS_CHUNK (`q.guild` 0 = vaga).
pub const Sent = struct { seq: u32 = 0, q: Query = .{} };

/// O lado da rede: o que a caixa quer, o que já veio e o que saiu. A fila e a janela de
/// cada servidor são do gw_budget.Outbox (a mesma do outro op 8); aqui só se decide o que
/// entra nela e o que responder à caixa.
pub const Searcher = struct {
    memo: Memo = .{},
    /// A busca que a caixa quer agora (null = nenhuma).
    want: ?Query = null,
    /// As que saíram, pelo número do `nonce` (uma por vaga; no máximo `per_minute` saem
    /// por minuto, e a resposta chega bem antes).
    sent: [per_minute]Sent = @splat(.{}),

    /// A caixa quer `q` (`q.len` 0: não quer mais nada; cancela a que espera).
    pub fn ask(s: *Searcher, o: *gw_budget.Outbox, q: Query, now_ms: i64) Replies {
        var out: Replies = .{};
        if (q.len == 0) {
            s.want = null;
            if (o.takeSearch()) |old| out.add(old, .dropped, 0);
            return out;
        }
        s.want = q;
        // Já respondida, ou já saiu e a resposta está a caminho: a que esperava não vale
        // mais, e nada novo sai.
        const in_flight = s.flying(q);
        if (in_flight or s.memo.covers(q)) {
            if (o.search) |w| if (!w.q.eql(q)) {
                o.search = null;
                out.add(w.q, .dropped, 0);
            };
            if (!in_flight) out.add(q, .covered, 0);
            return out;
        }
        // O op 8 daquele servidor acabou na sessão (recusas demais).
        if (o.isOff(q.guild)) {
            if (o.takeSearch()) |old| out.add(old, .dropped, 0);
            out.add(q, .dropped, 0);
            return out;
        }
        if (o.pushSearch(q, now_ms)) |old| out.add(old, .dropped, 0);
        return out;
    }

    fn flying(s: *const Searcher, q: Query) bool {
        for (s.sent) |x| if (x.q.guild != 0 and x.q.eql(q)) return true;
        return false;
    }

    fn find(s: *Searcher, seq: u32) ?*Sent {
        for (&s.sent) |*x| if (x.q.guild != 0 and x.seq == seq) return x;
        return null;
    }

    /// A busca de um `nonce` nosso que ainda espera resposta.
    pub fn query(s: *Searcher, seq: u32) ?Query {
        return if (s.find(seq)) |x| x.q else null;
    }

    /// `q` saiu com o número `seq`. A vaga ainda ocupada (a resposta nunca veio) fica
    /// sem resposta.
    pub fn wrote(s: *Searcher, q: Query, seq: u32) ?Reply {
        const slot = &s.sent[seq % s.sent.len];
        const gone: ?Reply = if (slot.q.guild != 0) .{ .q = slot.q, .result = .dropped } else null;
        slot.* = .{ .seq = seq, .q = q };
        return gone;
    }

    /// Chegou o GUILD_MEMBERS_CHUNK da busca `seq` com `found` membros (com `limit` 10 é
    /// sempre um pedaço só; `last` = é o último). A que espera e ficou coberta por esta
    /// resposta não sai mais.
    pub fn answered(s: *Searcher, o: *gw_budget.Outbox, seq: u32, found: usize, last: bool) Replies {
        var out: Replies = .{};
        if (!last) return out;
        const x = s.find(seq) orelse return out;
        const q = x.q;
        x.q.guild = 0;
        s.memo.note(q, found);
        out.add(q, .answered, found);
        if (o.search) |w| if (s.memo.covers(w.q)) {
            o.search = null;
            out.add(w.q, .covered, 0);
        };
        return out;
    }

    /// O Discord recusou a busca `seq` (RATE_LIMITED com o nosso nonce; `guild` 0 = o
    /// `meta` não disse). O servidor espera como no outro op 8 (gw_budget `holdMembers`), e
    /// ela volta para a fila só se a caixa ainda quer exatamente ela e nenhuma outra espera.
    pub fn limited(s: *Searcher, o: *gw_budget.Outbox, now_ms: i64, seq: u32, guild: Id, wait_ms: i64) Replies {
        var out: Replies = .{};
        var refused: ?Query = null;
        if (s.find(seq)) |x| {
            refused = x.q;
            x.q.guild = 0;
        }
        const g = if (guild != 0) guild else if (refused) |q| q.guild else 0;
        _ = o.holdMembers(now_ms, g, wait_ms, null);
        if (refused) |q| {
            const still = if (s.want) |w| w.eql(q) else false;
            if (still and o.search == null and !o.isOff(q.guild)) {
                o.search = .{ .q = q, .ready_ms = 0 };
            } else out.add(q, .dropped, 0);
        }
        s.dropOff(o, &out);
        return out;
    }

    /// Um RATE_LIMITED sem o nosso nonce (`guild` 0 = sem servidor): pode ter sido uma
    /// busca daquele servidor; elas ficam sem resposta (sem voltar para a fila), e a que
    /// espera um servidor cujo op 8 acabou também. (Quem segura o servidor é o caminho do
    /// outro op 8, que já cuidou da recusa.)
    pub fn limitedUnknown(s: *Searcher, o: *gw_budget.Outbox, guild: Id) Replies {
        var out: Replies = .{};
        for (&s.sent) |*x| if (x.q.guild != 0 and (guild == 0 or x.q.guild == guild)) {
            out.add(x.q, .dropped, 0);
            x.q.guild = 0;
        };
        s.dropOff(o, &out);
        return out;
    }

    /// A busca que espera um servidor cujo op 8 acabou não sai mais.
    fn dropOff(s: *Searcher, o: *gw_budget.Outbox, out: *Replies) void {
        _ = s;
        if (o.search) |w| if (o.isOff(w.q.guild)) {
            o.search = null;
            out.add(w.q, .dropped, 0);
        };
    }

    /// Depois de uma recusa do op 8 dos autores (com o nonce dele): se ela acabou com o
    /// op 8 do servidor, a busca que esperava lá não sai mais.
    pub fn afterRefusal(s: *Searcher, o: *gw_budget.Outbox) Replies {
        var out: Replies = .{};
        s.dropOff(o, &out);
        return out;
    }

    /// As que saíram não vão ter resposta (RESUMED logo depois de uma queda).
    pub fn lost(s: *Searcher) Replies {
        var out: Replies = .{};
        for (&s.sent) |*x| if (x.q.guild != 0) {
            out.add(x.q, .dropped, 0);
            x.q.guild = 0;
        };
        return out;
    }

    /// Sessão nova (READY): a que esperava também era da anterior.
    pub fn newSession(s: *Searcher, o: *gw_budget.Outbox) Replies {
        var out = s.lost();
        if (o.takeSearch()) |w| out.add(w, .dropped, 0);
        return out;
    }

    /// Saímos do servidor: nada dele sai mais, e o que se sabia de lá some.
    pub fn leftGuild(s: *Searcher, o: *gw_budget.Outbox, guild: Id) Replies {
        var out: Replies = .{};
        if (o.search) |w| if (w.q.guild == guild) {
            o.search = null;
            out.add(w.q, .dropped, 0);
        };
        for (&s.sent) |*x| if (x.q.guild == guild) {
            out.add(x.q, .dropped, 0);
            x.q.guild = 0;
        };
        s.memo.forgetGuild(guild);
        if (s.want) |w| if (w.guild == guild) {
            s.want = null;
        };
        return out;
    }
};

/// Escreve `s` como string JSON (sem as aspas).
fn jsonText(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
}

/// O op 8 em JSON. O `nonce` ("s" e o número do pedido) volta no GUILD_MEMBERS_CHUNK e no
/// RATE_LIMITED (o "m" é o do op 8 dos autores).
pub fn payload(buf: []u8, q: *const Query, seq: u32) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("{{\"op\":8,\"d\":{{\"guild_id\":\"{d}\",\"query\":\"", .{q.guild}) catch return null;
    jsonText(&w, q.text()) catch return null;
    w.print("\",\"limit\":{d},\"presences\":false,\"nonce\":\"s{d}\"}}}}", .{ limit, seq }) catch return null;
    return w.buffered();
}

/// O número do pedido num `nonce` de busca nosso (null = não é de uma busca daqui).
pub fn nonceSeq(nonce: []const u8) ?u32 {
    if (nonce.len < 2 or nonce[0] != 's') return null;
    return std.fmt.parseInt(u32, nonce[1..], 10) catch null;
}

// --- Testes (sem rede) ----------------------------------------------------------

const t = std.testing;

fn mk(guild: Id, s: []const u8) Query {
    return make(guild, s).?;
}

test "busca: 2 letras ou mais, minúsculas, sem DM, sem controle, até 32 bytes" {
    try t.expectEqualStrings("nan", mk(5, "Nan").text());
    try t.expectEqualStrings("nanda d", mk(5, " Nanda D ").text());
    // Uma letra (mesmo de dois bytes) não busca; duas sim.
    try t.expect(make(5, "n") == null);
    try t.expect(make(5, "ã") == null);
    try t.expectEqualStrings("jã", mk(5, "Jã").text());
    // DM e grupo (sem servidor): nunca.
    try t.expect(make(0, "nanda") == null);
    try t.expect(make(5, "  ") == null);
    try t.expect(make(5, "a\tb") == null);
    try t.expect(make(5, "\xff\xfe") == null);
    try t.expect(make(5, &@as([33]u8, @splat('a'))) == null);
    try t.expectEqual(@as(u8, 32), mk(5, &@as([32]u8, @splat('a'))).len);
    try t.expect(mk(5, "Nan").eql(mk(5, "nan")));
    try t.expect(!mk(5, "nan").eql(mk(6, "nan")));
}

test "memória: a mesma busca e a continuação de uma que voltou curta não pedem de novo" {
    var m: Memo = .{};
    // "na" voltou com 3 (menos que o limite): todo mundo de "na" veio.
    m.note(mk(5, "na"), 3);
    try t.expect(m.covers(mk(5, "na")));
    try t.expect(m.covers(mk(5, "nan")));
    try t.expect(m.covers(mk(5, "nanda d")));
    // O começo de uma busca não é coberto por ela, nem outro servidor.
    try t.expect(!m.covers(mk(5, "n" ++ "x")));
    try t.expect(!m.covers(mk(6, "nan")));
    // "gu" voltou cheio (10): "gu" não repete, mas "gus" pode trazer outros.
    m.note(mk(5, "gu"), limit);
    try t.expect(m.covers(mk(5, "gu")));
    try t.expect(!m.covers(mk(5, "gus")));
    // Respondida de novo, curta: agora cobre o resto.
    m.note(mk(5, "gu"), 2);
    try t.expect(m.covers(mk(5, "gus")));
    // Saímos do servidor 5: nada de lá vale mais.
    m.note(mk(6, "ab"), 0);
    m.forgetGuild(5);
    try t.expect(!m.covers(mk(5, "na")));
    try t.expect(m.covers(mk(6, "abc")));
    // Cheia: a mais antiga dá lugar, sem perder a conta.
    var full: Memo = .{};
    var nb: [8]u8 = undefined;
    for (0..70) |i| full.note(mk(7, std.fmt.bufPrint(&nb, "q{d}", .{i}) catch unreachable), limit);
    try t.expectEqual(@as(usize, 64), full.n);
    try t.expect(!full.covers(mk(7, "q0")));
    try t.expect(full.covers(mk(7, "q69")));
}

test "JSON: a busca escapada, o limite, sem presenças e o nonce" {
    var buf: [512]u8 = undefined;
    try t.expectEqualStrings("{\"op\":8,\"d\":{\"guild_id\":\"5\",\"query\":\"nan\",\"limit\":10,\"presences\":false,\"nonce\":\"s7\"}}", payload(&buf, &mk(5, "Nan"), 7).?);
    var q: Query = .{ .guild = 5 };
    const raw = "a\"b\\c";
    @memcpy(q.buf[0..raw.len], raw);
    q.len = raw.len;
    try t.expectEqualStrings("{\"op\":8,\"d\":{\"guild_id\":\"5\",\"query\":\"a\\\"b\\\\c\",\"limit\":10,\"presences\":false,\"nonce\":\"s0\"}}", payload(&buf, &q, 0).?);
    // O pior caso (32 aspas, servidor e número enormes) cabe no buffer de quem manda.
    var worst: Query = .{ .guild = std.math.maxInt(u63), .len = max_len };
    @memset(&worst.buf, '"');
    var small: [256]u8 = undefined;
    try t.expect(payload(&small, &worst, std.math.maxInt(u32)) != null);
    try t.expectEqual(@as(?u32, 7), nonceSeq("s7"));
    try t.expect(nonceSeq("m7") == null and nonceSeq("s") == null and nonceSeq("s-1") == null);
}

fn has(out: Replies, q: Query, r: Result) bool {
    for (out.slice()) |x| if (x.q.eql(q) and x.result == r) return true;
    return false;
}

test "fila: digitar depressa vira uma busca só, depois da pausa" {
    var o: gw_budget.Outbox = .{};
    var s: Searcher = .{};
    // "na", "nan", "nand" com 80 ms entre as teclas: cada uma troca a anterior.
    var now: i64 = 1000;
    for ([_][]const u8{ "na", "nan", "nand", "nanda" }, 0..) |txt, i| {
        const out = s.ask(&o, mk(5, txt), now);
        if (i > 0) try t.expectEqual(@as(usize, 1), out.n);
        try t.expect(o.pop(now) == null);
        now += 80;
    }
    // Ainda dentro dos 300 ms da última tecla: nada.
    try t.expect(o.pop(now + debounce_ms - 81) == null);
    // Passou a pausa: sai a última, e só ela.
    const it = o.pop(now - 80 + debounce_ms).?;
    try t.expectEqualStrings("nanda", it.search.text());
    try t.expect(o.pop(now + 10_000) == null);
}

test "fila: a busca divide a janela de 30 s do servidor com o op 8 dos autores, e passa na frente" {
    var o: gw_budget.Outbox = .{};
    var s: Searcher = .{};
    // O op 8 dos autores de uma página espera o lote de 2 s.
    var r: @import("member_ask.zig").Request = .{ .guild = 5, .n = 1 };
    r.ids[0] = 77;
    try t.expect(o.pushMembers(&r, 0));
    // A busca chega antes do lote fechar: sai primeiro.
    _ = s.ask(&o, mk(5, "nan"), 100);
    try t.expect(o.pop(100 + debounce_ms) .? == .search);
    // O lote fechou, mas a janela do servidor é da busca: nada antes dos 32 s.
    try t.expect(o.pop(5_000) == null);
    try t.expectEqual(100 + debounce_ms + gw_budget.members_window_ms, o.due(5_000));
    // Outra busca no mesmo servidor também espera a janela.
    _ = s.ask(&o, mk(5, "gus"), 6_000);
    try t.expect(o.pop(10_000) == null);
    // Com uma busca esperando, o op 8 dos autores do mesmo servidor fica atrás dela.
    const open = 100 + debounce_ms + gw_budget.members_window_ms;
    try t.expectEqualStrings("gus", o.pop(open).?.search.text());
    try t.expect(o.pop(open + 1) == null);
    try t.expect(o.pop(open + gw_budget.members_window_ms).? == .members);
}

test "fila: com a busca na pausa da digitação, o op 8 dos autores do servidor não toma a janela" {
    var o: gw_budget.Outbox = .{};
    var s: Searcher = .{};
    var r: @import("member_ask.zig").Request = .{ .guild = 5, .n = 1 };
    r.ids[0] = 77;
    try t.expect(o.pushMembers(&r, 0));
    // O lote fecha em 2 s; a pessoa ainda está digitando (a busca sai em 2,2 s).
    _ = s.ask(&o, mk(5, "nan"), 1_900);
    try t.expect(o.pop(gw_budget.members_batch_ms) == null);
    try t.expectEqual(1_900 + debounce_ms, o.due(gw_budget.members_batch_ms));
    try t.expect(o.pop(1_900 + debounce_ms).? == .search);
    // Outro servidor não espera a busca deste.
    var other: @import("member_ask.zig").Request = .{ .guild = 6, .n = 1 };
    other.ids[0] = 78;
    try t.expect(o.pushMembers(&other, 0));
    try t.expect(o.pop(1_900 + debounce_ms).? == .members);
    // A caixa cancelou antes da pausa acabar: o lote sai sozinho, sem esperar nada.
    var o2: gw_budget.Outbox = .{};
    var r2 = r;
    try t.expect(o2.pushMembers(&r2, 0));
    _ = s.ask(&o2, mk(5, "gus"), 1_900);
    _ = s.ask(&o2, .{ .guild = 5 }, 1_950);
    try t.expect(o2.pop(gw_budget.members_batch_ms).? == .members);
}

test "fila: no máximo 4 por minuto somando os servidores" {
    var o: gw_budget.Outbox = .{};
    var s: Searcher = .{};
    var now: i64 = 0;
    var nb: [8]u8 = undefined;
    // Cada busca num servidor diferente (a janela por servidor não segura): quatro saem.
    for (0..4) |i| {
        _ = s.ask(&o, mk(10 + i, std.fmt.bufPrint(&nb, "q{d}", .{i}) catch unreachable), now);
        now += debounce_ms;
        try t.expect(o.pop(now).? == .search);
    }
    // A quinta espera a mais antiga sair do minuto.
    _ = s.ask(&o, mk(20, "q4"), now);
    try t.expect(o.pop(now + debounce_ms) == null);
    try t.expectEqual(debounce_ms + gw_budget.window_ms, o.due(now + debounce_ms));
    try t.expect(o.pop(debounce_ms + gw_budget.window_ms).? == .search);
}

test "respostas: respondida, coberta, trocada, cancelada, voando" {
    var o: gw_budget.Outbox = .{};
    var s: Searcher = .{};
    // "nan" sai e volta com 1: "nanda" já está coberta.
    try t.expectEqual(@as(usize, 0), s.ask(&o, mk(5, "nan"), 0).n);
    const it = o.pop(debounce_ms).?;
    try t.expect(s.wrote(it.search, 3) == null);
    // Enquanto voa, pedir de novo a mesma não põe nada na fila nem responde.
    try t.expectEqual(@as(usize, 0), s.ask(&o, mk(5, "nan"), 400).n);
    try t.expect(o.search == null);
    // Uma continuação que chega antes da resposta espera a janela...
    _ = s.ask(&o, mk(5, "nand"), 500);
    try t.expect(o.search != null);
    // ...e a resposta curta a cobre: ela não sai.
    const ans = s.answered(&o, 3, 1, true);
    try t.expect(has(ans, mk(5, "nan"), .answered));
    try t.expect(has(ans, mk(5, "nand"), .covered));
    try t.expect(o.search == null);
    try t.expect(has(s.ask(&o, mk(5, "nanda"), 600), mk(5, "nanda"), .covered));
    // Resposta de um nonce que não é nosso (ou repetida): nada.
    try t.expectEqual(@as(usize, 0), s.answered(&o, 3, 1, true).n);
    // Trocar a que espera responde a antiga; cancelar responde a que esperava.
    _ = s.ask(&o, mk(5, "pe"), 700);
    try t.expect(has(s.ask(&o, mk(5, "gu"), 710), mk(5, "pe"), .dropped));
    try t.expect(has(s.ask(&o, .{ .guild = 5 }, 720), mk(5, "gu"), .dropped));
    try t.expect(o.search == null and s.want == null);
    // Uma pedida duas vezes seguidas fica uma só, sem responder a primeira.
    _ = s.ask(&o, mk(5, "lu"), 800);
    try t.expectEqual(@as(usize, 0), s.ask(&o, mk(5, "lu"), 810).n);
}

test "RATE_LIMITED: volta só se a caixa ainda quer, e três recusas acabam com o servidor" {
    var o: gw_budget.Outbox = .{};
    var s: Searcher = .{};
    _ = s.ask(&o, mk(5, "nan"), 0);
    var now: i64 = debounce_ms;
    _ = s.wrote(o.pop(now).?.search, 1);
    // Recusada e ainda é a que a caixa quer: volta, e espera o retry_after (nunca menos
    // que a janela).
    const r1 = s.limited(&o, now, 1, 5, 1_000);
    try t.expectEqual(@as(usize, 0), r1.n);
    try t.expect(o.search != null);
    try t.expect(o.pop(now + 1_000) == null);
    now += gw_budget.members_window_ms;
    _ = s.wrote(o.pop(now).?.search, 2);
    // Recusada de novo, mas a caixa já quer outra: a recusada fica sem resposta.
    _ = s.ask(&o, mk(5, "gus"), now + 10);
    const r2 = s.limited(&o, now + 20, 2, 5, 0);
    try t.expect(has(r2, mk(5, "nan"), .dropped));
    try t.expectEqualStrings("gus", o.search.?.q.text());
    // A terceira recusa seguida acaba com o op 8 do servidor: a que espera não sai, e
    // pedir de novo responde na hora.
    now += 3 * gw_budget.members_window_ms;
    _ = s.wrote(o.pop(now).?.search, 3);
    const r3 = s.limited(&o, now, 3, 5, 0);
    try t.expect(has(r3, mk(5, "gus"), .dropped));
    try t.expect(o.isOff(5) and o.search == null);
    try t.expect(has(s.ask(&o, mk(5, "lu"), now + 1), mk(5, "lu"), .dropped));
    try t.expect(o.pop(now + 600_000) == null);
    // Outro servidor continua.
    _ = s.ask(&o, mk(6, "lu"), now + 1);
    try t.expect(o.pop(now + 1 + debounce_ms).? == .search);
}

test "sem resposta: queda, sessão nova, vaga reusada e sair do servidor" {
    var o: gw_budget.Outbox = .{};
    var s: Searcher = .{};
    _ = s.ask(&o, mk(5, "nan"), 0);
    _ = s.wrote(o.pop(debounce_ms).?.search, 0);
    try t.expect(has(s.lost(), mk(5, "nan"), .dropped));
    try t.expectEqual(@as(usize, 0), s.lost().n);
    // A vaga reusada (a resposta nunca veio) responde a antiga.
    _ = s.wrote(mk(6, "ab"), 1);
    try t.expectEqualStrings("ab", s.wrote(mk(6, "cd"), 1 + per_minute).?.q.text());
    // Sessão nova: as que saíram e a que espera.
    _ = s.ask(&o, mk(7, "xy"), 0);
    const ns = s.newSession(&o);
    try t.expect(has(ns, mk(6, "cd"), .dropped) and has(ns, mk(7, "xy"), .dropped));
    try t.expect(o.search == null);
    // Saímos do servidor: a que espera, as que saíram e a memória de lá.
    s.memo.note(mk(8, "zz"), 0);
    _ = s.ask(&o, mk(8, "aa"), 0);
    _ = s.wrote(mk(8, "bb"), 2);
    const lg = s.leftGuild(&o, 8);
    try t.expect(has(lg, mk(8, "aa"), .dropped) and has(lg, mk(8, "bb"), .dropped));
    try t.expect(!s.memo.covers(mk(8, "zz")) and s.want == null);
    // RATE_LIMITED sem nonce: as daquele servidor que saíram ficam sem resposta.
    _ = s.wrote(mk(9, "ab"), 3);
    try t.expect(has(s.limitedUnknown(&o, 9), mk(9, "ab"), .dropped));
    // Recusas do op 8 dos autores que acabam com o servidor: a busca que esperava lá não
    // sai mais.
    _ = s.ask(&o, mk(11, "ab"), 0);
    for (0..3) |_| _ = o.holdMembers(0, 11, 0, null);
    try t.expect(o.isOff(11));
    try t.expect(has(s.afterRefusal(&o), mk(11, "ab"), .dropped));
    try t.expect(o.search == null and o.due(0) == std.math.maxInt(i64));
}
