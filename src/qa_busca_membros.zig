//! QA da busca do `@` no servidor inteiro (op 8 com `query`, net/member_search.zig), com a
//! mesma fila do gateway de verdade (net/gw_budget.zig): a busca divide com o op 8 dos
//! autores de uma página a janela de 30 s por servidor do Discord e passa na frente dele.
//! Na demonstração, o servidor grande (Arch Linux BR) não traz quem está offline na lista
//! de membros: o gustavo e a nanda ("Nanda do Arch") só aparecem no `@` pela resposta.
//! Confere: numa DM nunca pede; um nome digitado depressa é um pedido só, com o aviso de
//! "buscando" enquanto isso e a pessoa offline na lista depois da resposta; continuar um
//! nome que voltou curto não pede nada; dentro da janela do servidor só a última busca
//! sai, na frente do op 8 dos autores, e a escolha não pula para outra pessoa quando a
//! resposta chega; `@nan` acha a nanda e escolher vira `<@id>` ao enviar; e nenhum op 8
//! que o Discord recusaria. Leva uns 40 s (a segunda busca espera a janela de verdade).
//! Sozinho: QA_SUITE=busca-membros.
const std = @import("std");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const c = @import("c");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const autocomplete = @import("ui/autocomplete.zig");
const Id = types.Id;

fn s(name: []const u8) Op {
    return .{ .section = name };
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

const big: Id = gw.guildId(gw.large_guild);
/// #zig e #geral do servidor grande: no #zig a nanda escreveu, no #geral não; o gustavo
/// não escreveu no #zig.
const big_zig: Id = gw.channelId(gw.large_guild, 9);
const big_geral: Id = gw.channelId(gw.large_guild, 4);
const nanda: Id = gw.large_old_author;
const gustavo: Id = 1008;
const dm0: Id = 900_000;

fn load(a: anytype) u64 {
    return a.load(.acquire);
}
fn searches() u64 {
    return load(&gw.sent.member_searches);
}
fn lastQuery() []const u8 {
    return gw.sent.view(&gw.sent.member_query, &gw.sent.member_query_len);
}
fn input(app: *App) []const u8 {
    return std.mem.sliceTo(&app.st.input, 0);
}
fn clearInput(app: *App) void {
    @memset(&app.st.input, 0);
    app.st.input_sync = true;
    app.st.focus_input = true;
    autocomplete.clearTokens();
}
fn loaded(app: *App, id: Id) bool {
    const cs = app.store.channel(id) orelse return false;
    return app.st.activeChannel() == id and cs.history == .loaded;
}
fn inList(user: Id, name: []const u8) bool {
    var b: [96]u8 = undefined;
    return qa.find(std.fmt.bufPrint(&b, "nome:auto:{d}:{s}", .{ user, name }) catch return false) != null;
}

/// O que já tinha acontecido antes (a bateria geral pode ter pedido antes).
var s0: u64 = 0;
var refused0: u64 = 0;
var wrong0: u64 = 0;
/// Op 8 dos autores do servidor grande até aqui.
var large0: u64 = 0;

/// As abas que o demo abre no começo (no primeiro servidor) já carregaram e o op 8 delas
/// já saiu.
fn settled(app: *App) bool {
    for (app.st.tabs.items) |id| {
        const cs = app.store.channel(id) orelse return false;
        if (cs.history != .loaded) return false;
    }
    return load(&gw.sent.member_pages) >= app.st.tabs.items.len and load(&gw.sent.member_queued) == 0;
}

// --- DM ---------------------------------------------------------------------------

fn start(app: *App) void {
    s0 = searches();
    refused0 = load(&gw.sent.member_refused);
    wrong0 = load(&gw.sent.member_wrong);
    app.handle(.{ .select_channel = dm0 });
}
fn dmLoaded(app: *App) bool {
    return loaded(app, dm0);
}
fn dmNoAsk(_: *App) bool {
    return searches() == s0 and !autocomplete.searching() and qa.find("ac-searching") == null;
}

// --- Um nome digitado depressa ------------------------------------------------------

fn openZig(app: *App) void {
    large0 = load(&gw.sent.member_large);
    app.handle(.{ .select_guild = big });
    app.handle(.{ .select_channel = big_zig });
}
fn zigLoaded(app: *App) bool {
    return loaded(app, big_zig);
}
/// O gustavo ainda não é membro conhecido de lá (nem a lista nem uma página o trouxe).
fn gustavoUnknown(app: *App) bool {
    return app.store.memberInfo(big, gustavo) == null;
}
fn hintShown(_: *App) bool {
    return autocomplete.searching() and qa.find("ac-searching") != null;
}
fn gustavoFound(_: *App) bool {
    return inList(gustavo, "gustavo") and !autocomplete.searching() and qa.find("ac-searching") == null;
}
/// "g", "gu", ... "gustav" com uma tecla a cada ~40 ms: um op 8, com o nome inteiro, e
/// antes do op 8 dos autores da página (que esperava o lote de 2 s).
fn oneSearch(_: *App) bool {
    return searches() == s0 + 1 and std.mem.eql(u8, lastQuery(), "gustav") and load(&gw.sent.member_large) == large0;
}
fn refinedNoAsk(_: *App) bool {
    return searches() == s0 + 1 and !autocomplete.searching() and inList(gustavo, "gustavo");
}

// --- Dentro da janela do servidor --------------------------------------------------

/// Uma busca nova no #zig: ela espera a janela do servidor, com o aviso na tela.
fn peWaits(_: *App) bool {
    return autocomplete.searching() and qa.find("ac-searching") != null and searches() == s0 + 1;
}
fn openGeral(app: *App) void {
    app.handle(.{ .select_channel = big_geral });
}
fn geralLoaded(app: *App) bool {
    return loaded(app, big_geral);
}
/// Quem estava escolhido antes da resposta (alguém que já se conhecia daqui).
var pre_sel: Id = 0;
fn naListed(app: *App) bool {
    pre_sel = autocomplete.selectedId();
    return autocomplete.open() and autocomplete.searching() and pre_sel != 0 and pre_sel != nanda and app.store.memberInfo(big, nanda) == null;
}
/// Passada a janela, uma busca só (a última: "na", não "pe") e a nanda na lista.
fn naAnswered(_: *App) bool {
    return searches() == s0 + 2 and std.mem.eql(u8, lastQuery(), "na") and inList(nanda, "Nanda do Arch");
}
/// A escolha continua em quem estava escolhido, agora abaixo da nanda.
fn selectionKept(_: *App) bool {
    return autocomplete.selectedId() == pre_sel and autocomplete.selected() >= 1;
}
/// O op 8 dos autores das páginas (#zig e #geral) esperou atrás da busca.
fn authorsWaited(_: *App) bool {
    return load(&gw.sent.member_large) == large0 and load(&gw.sent.member_refused) == refused0;
}
fn nanFound(_: *App) bool {
    return searches() == s0 + 2 and inList(nanda, "Nanda do Arch") and autocomplete.selectedId() == nanda and !autocomplete.searching();
}
fn nickInserted(app: *App) bool {
    return std.mem.eql(u8, input(app), "@Nanda do Arch ") and !autocomplete.open();
}
fn mentionSent(app: *App) bool {
    const cs = app.store.channel(big_geral) orelse return false;
    if (cs.messages.items.len == 0) return false;
    const m = &cs.messages.items[cs.messages.items.len - 1];
    return !m.pending and std.mem.eql(u8, m.msg.content, "<@1009> oi");
}

fn allClean(_: *App) bool {
    return load(&gw.sent.member_refused) == refused0 and load(&gw.sent.member_wrong) == wrong0 and searches() == s0 + 2;
}

/// Digita uma letra de cada vez, com ~40 ms entre elas (bem menos que a pausa de 300 ms).
fn typed(comptime text: []const u8) [text.len * 2]Op {
    var out: [text.len * 2]Op = undefined;
    for (0..text.len) |i| {
        out[i * 2] = .{ .text = text[i .. i + 1] };
        out[i * 2 + 1] = .{ .wait = 40 };
    }
    return out;
}

pub const ops = [_]Op{
    s("busca do @: DM"),
    .{ .expect = .{ .name = "as abas do começo carregaram e o op 8 delas já saiu", .check = settled, .timeout_ms = 8000 } },
    run(start),
    expect("a DM abre", dmLoaded),
    .{ .click = .{ .mark = "composer" } },
} ++ typed("@nan") ++ [_]Op{
    .{ .wait = 700 },
    expect("numa DM, @nan não pede nada ao Discord (a lista são os participantes)", dmNoAsk),
    run(clearInput),
    .{ .wait = 60 },

    s("busca do @: um nome digitado depressa"),
    run(openZig),
    expect("o #zig do servidor grande abre", zigLoaded),
    expect("o gustavo (offline, fora da lista) ainda não é conhecido de lá", gustavoUnknown),
    .{ .click = .{ .mark = "composer" } },
} ++ typed("@gustav") ++ [_]Op{
    .{ .expect = .{ .name = "enquanto a resposta não chega, \"buscando no servidor…\"", .check = hintShown, .timeout_ms = 1000 } },
    .{ .shot = "busca-membros-buscando" },
    .{ .expect = .{ .name = "o gustavo aparece na lista depois da resposta", .check = gustavoFound, .timeout_ms = 3000 } },
    .{ .wait = 400 },
    .{ .expect = .{ .name = "seis letras depressa: um op 8 só, com o nome inteiro, antes do op 8 dos autores", .check = oneSearch, .timeout_ms = 1 } },
    .{ .text = "o" },
    .{ .wait = 500 },
    expect("continuar um nome que voltou com menos de 10 não pede nada", refinedNoAsk),
    run(clearInput),
    .{ .wait = 60 },

    s("busca do @: dentro da janela de 30 s do servidor"),
    .{ .text = "@pe" },
    expect("outra busca no mesmo servidor espera a janela, com o aviso na tela", peWaits),
    run(clearInput),
    .{ .wait = 60 },
    run(openGeral),
    expect("o #geral do mesmo servidor abre", geralLoaded),
    .{ .click = .{ .mark = "composer" } },
    .{ .text = "@na" },
    .{ .expect = .{ .name = "a lista mostra quem já se conhece daqui, com alguém escolhido, e avisa que busca", .check = naListed, .timeout_ms = 1500 } },
    // A janela do gustavo vence uns 32 s depois dele.
    .{ .expect = .{ .name = "passada a janela, sai uma busca só (a última) e a nanda entra na lista", .check = naAnswered, .timeout_ms = 40_000 } },
    expect("a escolha continua em quem estava escolhido (a lista não pulou)", selectionKept),
    expect("o op 8 dos autores das páginas esperou atrás da busca, e nada foi cedo demais", authorsWaited),
    .{ .shot = "busca-membros-nanda" },
    .{ .text = "n" },
    .{ .wait = 500 },
    expect("@nan acha a nanda (offline) sem pedir de novo", nanFound),
    key(c.ImGuiKey_Enter),
    expect("escolher põe o apelido de lá na caixa", nickInserted),
    .{ .text = "oi" },
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "e vira <@1009> ao enviar", .check = mentionSent, .timeout_ms = 3000 } },
    expect("no total: duas buscas, nenhuma que o Discord recusaria, nenhuma com servidor errado", allClean),
};
