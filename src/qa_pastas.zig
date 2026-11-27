//! QA das pastas da barra de servidores (QA_SUITE=pastas): arrastar um servidor em
//! cima de outro faz uma pasta, renomear e mudar a cor (pelas bolinhas e pelo código),
//! levar para dentro e para fora (arrastando e pelos menus), reordenar servidores e
//! pastas, várias mudanças seguidas viram poucas gravações, desfazer a pasta, a
//! gravação que falha volta a barra, marcar a pasta como lida e a mudança feita em
//! "outro aparelho" reordenando a barra. Depois de cada passo confere a barra e os
//! bytes que iriam para o Discord (o corpo do PATCH decodificado de volta), e que o
//! resto das configurações da conta de mentira não mudou.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const fp = @import("net/fake_pastas.zig");
const settings_proto = @import("net/settings_proto.zig");
const pastas = @import("core/pastas.zig");
const app_pastas = @import("app_pastas.zig");
const types = @import("core/types.zig");
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
fn rclickDyn(f: *const fn (*App, []u8) []const u8) Op {
    return .{ .rclick = .{ .dyn = f } };
}
fn clickDyn(f: *const fn (*App, []u8) []const u8) Op {
    return .{ .click = .{ .dyn = f } };
}
/// Arrasta `from` até um ponto de `to` (frações da altura: 0.5 = no meio, em cima dele).
fn drag(from: *const fn (*App, []u8) []const u8, to: *const fn (*App, []u8) []const u8, fy: f32) Op {
    return .{ .drag = .{ .from = .{ .dyn = from }, .to = .{ .dyn_at = .{ .f = to, .fx = 0.5, .fy = fy } } } };
}

fn G(i: usize) Id {
    return gw.guildId(i);
}
fn index(id: Id) usize {
    return @intCast((id - gw.guildId(0)) / 1000);
}

/// A pasta criada arrastando (o id é sorteado).
var new_id: u64 = 0;
var patches0: u64 = 0;
var requests0: u64 = 0;
var gets0: u64 = 0;
var calls0: u64 = 0;
var bulks0: u64 = 0;

/// Conta os pedidos de agora em diante (cada conferência é desde aqui).
fn resetCounts() void {
    patches0 = load(&fp.sent.patches);
    requests0 = load(&fp.sent.requests);
    gets0 = load(&fp.sent.gets);
    calls0 = load(&fp.sent.patch_calls);
}

fn markFmt(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch "";
}
fn tG(comptime i: usize) fn (*App, []u8) []const u8 {
    return struct {
        fn f(_: *App, b: []u8) []const u8 {
            return markFmt(b, "guild:{d}", .{G(i)});
        }
    }.f;
}
fn tF(comptime id: u64) fn (*App, []u8) []const u8 {
    return struct {
        fn f(_: *App, b: []u8) []const u8 {
            return markFmt(b, "folder:{d}", .{id});
        }
    }.f;
}
fn tNew(_: *App, b: []u8) []const u8 {
    return markFmt(b, "folder:{d}", .{new_id});
}
/// "Jogos" no menu de "Adicionar à pasta…" (o nome da demonstração na língua do QA).
fn tPickJogos(app: *App, b: []u8) []const u8 {
    const f = app.store.folderById(78) orelse return "";
    return markFmt(b, "menu:{s}", .{f.name});
}

/// A barra em texto: `0 1 [77:2,8,4] 5 [78:6,3] [N:9,7]` (N = a pasta nova).
fn shape(buf: []u8, list: []const types.GuildFolder) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    for (list, 0..) |f, i| {
        if (i > 0) w.writeAll(" ") catch {};
        if (f.id != 0) {
            if (f.id == new_id) w.writeAll("[N:") catch {} else w.print("[{d}:", .{f.id}) catch {};
        }
        for (f.guilds, 0..) |g, k| w.print("{s}{d}", .{ if (k > 0) "," else "", index(g) }) catch {};
        if (f.id != 0) w.writeAll("]") catch {};
    }
    return w.buffered();
}

fn barIs(app: *App, want: []const u8) bool {
    var b: [256]u8 = undefined;
    const got = shape(&b, app.store.folders);
    if (!std.mem.eql(u8, got, want)) {
        if (c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[pastas] barra: {s} (esperava {s})\n", .{ got, want });
        return false;
    }
    return true;
}

fn load(a: anytype) u64 {
    return a.load(.acquire);
}

/// Cada gravação foi um pedido só (o PATCH, sem GET); o último PATCH, decodificado de
/// volta, é igual ao que a conta guardou e ao que a barra mostra; levou a versão que a
/// conta tinha; e o resto da conta não mudou.
fn patchMatches(app: *App, n: u64) bool {
    if (load(&fp.sent.patches) != patches0 + n) return false;
    if (load(&fp.sent.requests) != requests0 + n or load(&fp.sent.gets) != gets0) return false;
    if (app.store.folder_ops.items.len > 0 or app_pastas.waiting() > 0) return false;
    return lastBodyMatches(app);
}

fn lastBodyMatches(app: *App) bool {
    const len = load(&fp.sent.body_len);
    const body = fp.sent.body[0..len];
    var vb: [48]u8 = undefined;
    // A conta sobe a versão a cada gravação: o PATCH levou a de antes dele.
    const want = std.fmt.bufPrint(&vb, "\"required_data_version\":{d}", .{load(&fp.sent.version) - 1}) catch return false;
    if (std.mem.indexOf(u8, body, want) == null) return false;
    const l = settings_proto.decodePatch(std.heap.c_allocator, body) catch return false;
    defer l.deinit(std.heap.c_allocator);
    // Sem `guild_positions` na conta: o PATCH também não leva.
    if (l.positions.len != 0) return false;
    if (!pastas.same(l.folders, app.store.folders_server) or !pastas.same(l.folders, app.store.folders)) return false;
    return load(&fp.sent.intact) == 1 and load(&fp.sent.unknown_kept) == 1;
}

fn snapshot(_: *App) void {
    resetCounts();
    bulks0 = load(&gw.sent.bulks);
}

fn demoBar(app: *App) bool {
    // Na barra sem pastas (abas de texto, dock), os servidores aparecem um a um.
    const drawn = qa.find("folder:77") != null or qa.find(markFmt(&mb, "guild:{d}", .{G(2)})) != null;
    return app.store.ready and drawn and barIs(app, "0 1 [77:2,8,4] 5 [78:6,3] 7 9");
}

fn merged(app: *App) bool {
    if (new_id == 0) for (app.store.folders) |f| {
        if (f.id != 0 and f.id != 77 and f.id != 78) new_id = f.id;
    };
    // Positivo, de até 31 bits.
    if (new_id == 0 or new_id > std.math.maxInt(i32)) return false;
    return barIs(app, "0 1 [77:2,8,4] 5 [78:6,3] [N:9,7]") and qa.find("folder-drop:center") == null;
}
fn merged1(app: *App) bool {
    return patchMatches(app, 1) and qa.find(markFmt(&mb, "folder:{d}", .{new_id})) != null;
}
var mb: [64]u8 = undefined;

fn settingsOpen(_: *App) bool {
    return qa.find("folder-settings") != null;
}
fn settingsClosed(_: *App) bool {
    return qa.find("folder-settings") == null;
}
fn newFolder(app: *App) ?*const types.GuildFolder {
    return app.store.folderById(new_id);
}
fn renamed(app: *App) bool {
    const f = newFolder(app) orelse return false;
    return std.mem.eql(u8, f.name, "Projetos") and f.color == 0 and patchMatches(app, 2);
}
fn swatched(app: *App) bool {
    const f = newFolder(app) orelse return false;
    return std.mem.eql(u8, f.name, "Projetos") and f.color == App.accents[2] and patchMatches(app, 3);
}
fn hexed(app: *App) bool {
    const f = newFolder(app) orelse return false;
    return f.color == 0x1A2B3C and patchMatches(app, 4);
}
fn intoClosed(app: *App) bool {
    return barIs(app, "1 [77:2,8,4,0] 5 [78:6,3] [N:9,7]") and patchMatches(app, 5) and !app.st.open_folders.contains(77);
}
fn opened77(app: *App) bool {
    return app.st.open_folders.contains(77) and qa.find(markFmt(&mb, "guild:{d}", .{G(0)})) != null;
}
fn ungrouped(app: *App) bool {
    return barIs(app, "1 [77:2,8,4] 0 5 [78:6,3] [N:9,7]") and patchMatches(app, 6);
}
fn pickShown(_: *App) bool {
    return qa.find("menu:Nova pasta") != null and qa.find("menu:Adicionar à pasta…") == null;
}
fn added(app: *App) bool {
    return barIs(app, "1 [77:2,8,4] 0 [78:6,3,5] [N:9,7]") and patchMatches(app, 7);
}
fn reordered(app: *App) bool {
    return barIs(app, "[77:2,8,4] 0 1 [78:6,3,5] [N:9,7]") and patchMatches(app, 8);
}
fn folderMoved(app: *App) bool {
    return barIs(app, "[N:9,7] [77:2,8,4] 0 1 [78:6,3,5]") and patchMatches(app, 9) and app.st.open_folders.contains(77);
}

/// Três mudanças seguidas, no mesmo instante: a primeira sai na hora, as outras duas
/// esperam e saem juntas.
fn burst(app: *App) void {
    resetCounts();
    app_pastas.handle(app, .{ .move_guild = .{ .guild = G(0), .where = .end } });
    app_pastas.handle(app, .{ .move_guild = .{ .guild = G(1), .where = .end } });
    app_pastas.handle(app, .{ .move_guild = .{ .guild = G(0), .where = .end } });
}
fn burstShownNow(app: *App) bool {
    return barIs(app, "[N:9,7] [77:2,8,4] [78:6,3,5] 1 0") and load(&fp.sent.patches) <= patches0 + 1;
}
fn burstFirst(_: *App) bool {
    return load(&fp.sent.patches) == patches0 + 1 and app_pastas.waiting() == 2;
}
fn burstDone(app: *App) bool {
    return barIs(app, "[N:9,7] [77:2,8,4] [78:6,3,5] 1 0") and patchMatches(app, 2);
}

fn removed(app: *App) bool {
    return barIs(app, "9 7 [77:2,8,4] [78:6,3,5] 1 0") and patchMatches(app, 1) and app.store.folderById(new_id) == null;
}

/// Outro aparelho grava algo logo antes do PATCH: o Discord recusa com as configurações
/// como estão, e as mudanças vão de novo sobre elas, sem GET. Dois pedidos.
fn staleNext(_: *App) void {
    resetCounts();
    fp.sent.stale_next.store(1, .release);
}
fn staleRetried(app: *App) bool {
    return barIs(app, "[N:9,7] [77:2,8,4] [78:6,3,5] 0 1") and load(&fp.sent.patches) == patches0 + 1 and
        load(&fp.sent.patch_calls) == calls0 + 2 and load(&fp.sent.requests) == requests0 + 2 and load(&fp.sent.gets) == gets0 and
        app.store.folder_ops.items.len == 0 and lastBodyMatches(app);
}
/// Sem a cópia das configurações (um READY na forma antiga): um GET antes do PATCH.
fn forgetNext(_: *App) void {
    resetCounts();
    fp.sent.forget_next.store(1, .release);
}
fn fetchedFirst(app: *App) bool {
    return barIs(app, "[N:9,7] [77:2,8,4] [78:6,3,5] 1 0") and load(&fp.sent.patches) == patches0 + 1 and
        load(&fp.sent.gets) == gets0 + 1 and load(&fp.sent.requests) == requests0 + 2 and
        app.store.folder_ops.items.len == 0 and lastBodyMatches(app);
}

fn failNext(app: *App) void {
    resetCounts();
    app.st.toast.len = 0;
    fp.sent.fail_next.store(1, .release);
}
fn failedBack(app: *App) bool {
    // A barra volta ao que a conta tem, com o aviso do erro, e nada foi gravado.
    return barIs(app, "9 7 [77:2,8,4] [78:6,3,5] 1 0") and app.store.folder_ops.items.len == 0 and
        load(&fp.sent.patches) == patches0 and load(&fp.sent.fail_next) == 0 and load(&fp.sent.requests) == requests0 + 1 and
        app.st.toast.until_ms > gw.nowMs() and std.mem.indexOf(u8, app.st.toast.text(), "não deu para salvar as pastas") != null;
}

/// Um canal do "Zig Brasil" (na pasta 77) e o "Arch Linux BR" com algo não lido.
fn makeUnread(app: *App) void {
    bulks0 = load(&gw.sent.bulks);
    for ([_]usize{ 2, 8 }) |gi| {
        for (app.store.channelsOf(G(gi))) |ch| if (app.store.channel(ch)) |cs| if (cs.info.kind == .text) {
            cs.info.unread = true;
            if (cs.info.last_message == 0) cs.info.last_message = types.makeSnowflake(gw.nowMs(), 1);
            break;
        };
        if (app.store.guild(G(gi))) |g| {
            g.unread = true;
            g.mentions = 2;
        }
    }
}
fn folderRead(app: *App) bool {
    for ([_]usize{ 2, 8 }) |gi| {
        const g = app.store.guild(G(gi)) orelse return false;
        if (g.unread or g.mentions != 0) return false;
    }
    // Os dois servidores num pedido só.
    return load(&gw.sent.bulks) == bulks0 + 1 and load(&gw.sent.bulk_len) >= 2;
}

fn appendField(out: *std.ArrayList(u8), field: u64, data: []const u8) !void {
    const ca = std.heap.c_allocator;
    var x: u64 = field << 3 | 2;
    while (x >= 0x80) : (x >>= 7) try out.append(ca, @as(u8, @truncate(x)) | 0x80);
    try out.append(ca, @truncate(x));
    x = data.len;
    while (x >= 0x80) : (x >>= 7) try out.append(ca, @as(u8, @truncate(x)) | 0x80);
    try out.append(ca, @truncate(x));
    try out.appendSlice(ca, data);
}

/// "Outro aparelho" pôs o "Jogos" no começo da barra: o USER_SETTINGS_PROTO_UPDATE
/// parcial, só com o campo 14.
fn remoteReorder(app: *App) void {
    const ca = std.heap.c_allocator;
    resetCounts();
    const moved = pastas.applyAll(ca, app.store.folders_server, &.{}, &.{.{ .move_folder = .{ .folder = 78, .where = .start } }}) catch return;
    defer pastas.freeFolders(ca, moved);
    // Um cliente que guarda o que não conhece: os campos desconhecidos da conta vão junto.
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(ca);
    for (moved) |f| {
        const one = settings_proto.encodeFolder(ca, f, if (f.id == 78) fp.folder_unknown else "") catch return;
        defer ca.free(one);
        appendField(&content, 1, one) catch return;
    }
    content.appendSlice(ca, fp.list_unknown) catch return;
    var proto: std.ArrayList(u8) = .empty;
    defer proto.deinit(ca);
    appendField(&proto, 14, content.items) catch return;
    const e = fp.remote(proto.items) orelse return;
    app.events.push(e);
    @import("platform/window.zig").Window.wake(app.win.wake_type, .gateway);
}
fn remoteApplied(app: *App) bool {
    var items: [64]@import("core/store.zig").Store.RailItem = undefined;
    const order = app.store.railOrder(&items);
    if (order.len == 0 or order[0] != .folder or order[0].folder.id != 78) return false;
    // Só chegou: nada é gravado de volta, e a pasta aberta continua aberta.
    return barIs(app, "[78:6,3,5] 9 7 [77:2,8,4] 1 0") and load(&fp.sent.patches) == patches0 and app.st.open_folders.contains(77) and
        qa.find("folder:78") != null;
}
/// A mudança seguinte vale sobre o que o outro aparelho deixou.
fn afterRemote(app: *App) bool {
    return barIs(app, "[78:6,3,5] 7 9 [77:2,8,4] 1 0") and patchMatches(app, 1);
}

pub const ops = [_]Op{
    expect("barra com as pastas da demonstração", demoBar),
    run(snapshot),

    s("pastas: servidor em cima de outro faz uma pasta"),
    drag(tG(7), tG(9), 0.5),
    expect("pasta nova com os dois, no lugar do de baixo, id positivo de 31 bits", merged),
    expect("um PATCH só com as pastas, igual à barra; o resto da conta igual", merged1),
    .{ .shot = "pastas-nova" },

    s("pastas: nome e cor"),
    rclickDyn(tNew),
    click("menu:Configurações da pasta…"),
    expect("janela da pasta aberta", settingsOpen),
    click("folder-name"),
    .{ .text = "Projetos" },
    .{ .shot = "pastas-config" },
    click("folder-save"),
    expect("renomeada, gravada", renamed),
    expect("janela fechada", settingsClosed),
    rclickDyn(tNew),
    click("menu:Configurações da pasta…"),
    expect("janela da pasta aberta de novo", settingsOpen),
    click("folder-color:3"),
    click("folder-save"),
    expect("cor da paleta, gravada", swatched),
    rclickDyn(tNew),
    click("menu:Configurações da pasta…"),
    expect("janela da pasta aberta (código)", settingsOpen),
    click("folder-hex"),
    .{ .key = .{ .key = c.ImGuiKey_A, .ctrl = true } },
    .{ .text = "1A2B3C" },
    click("folder-save"),
    expect("cor pelo código, gravada", hexed),

    s("pastas: para dentro e para fora"),
    drag(tG(0), tF(77), 0.5),
    expect("para dentro da pasta fechada (no fim), gravado", intoClosed),
    clickDyn(tF(77)),
    expect("pasta aberta mostra o servidor", opened77),
    rclickDyn(tG(0)),
    click("menu:Remover da pasta"),
    expect("solto logo depois da pasta, gravado", ungrouped),
    rclickDyn(tG(5)),
    click("menu:Adicionar à pasta…"),
    expect("lista das pastas e Nova pasta", pickShown),
    clickDyn(tPickJogos),
    expect("no fim do Jogos, gravado", added),

    s("pastas: reordenar"),
    drag(tG(1), tF(78), 0.08),
    expect("servidor antes da pasta, gravado", reordered),
    drag(tNew, tF(77), 0.08),
    expect("pasta inteira antes da outra, a aberta continua aberta", folderMoved),

    s("pastas: mudanças seguidas"),
    // Um tempo parado desde a última: a primeira da rajada sai na hora.
    .{ .wait = 1100 },
    run(burst),
    expect("a barra muda na hora", burstShownNow),
    expect("a primeira sai na hora, as outras esperam", burstFirst),
    .{ .expect = .{ .name = "as outras duas numa gravação só, um segundo depois", .check = burstDone, .timeout_ms = 3000 } },

    s("pastas: um pedido por gravação"),
    run(staleNext),
    drag(tG(0), tG(1), 0.08),
    expect("outro aparelho gravou no meio: recusado e refeito sobre a resposta, dois pedidos", staleRetried),
    run(forgetNext),
    drag(tG(1), tG(0), 0.08),
    expect("sem a cópia das configurações: GET e PATCH", fetchedFirst),

    s("pastas: desfazer a pasta"),
    run(snapshot),
    rclickDyn(tNew),
    click("menu:Remover pasta"),
    expect("os servidores ficam soltos no lugar dela, gravado", removed),

    s("pastas: gravação que falha"),
    run(failNext),
    drag(tG(9), tG(7), 0.5),
    expect("a barra volta ao que a conta tem e o erro aparece", failedBack),
    .{ .shot = "pastas-falha" },

    s("pastas: marcar a pasta como lida"),
    run(makeUnread),
    rclickDyn(tF(77)),
    click("menu:Marcar pasta como lida"),
    expect("os servidores dela lidos, num pedido só", folderRead),

    s("pastas: outro aparelho"),
    run(remoteReorder),
    expect("a barra reordena sozinha, sem gravar nada", remoteApplied),
    drag(tG(9), tG(7), 0.92),
    expect("a mudança seguinte vale sobre a do outro aparelho", afterRemote),
    .{ .shot = "pastas-fim" },
};

// --- Em cada tipo de barra (QA_SUITE=pastas-tema, no tema que estiver) ---------------

fn dragAt(from: *const fn (*App, []u8) []const u8, to: *const fn (*App, []u8) []const u8, f: f32) Op {
    // A mesma fração nos dois eixos: vale para a barra em pé e para a deitada.
    return .{ .drag = .{ .from = .{ .dyn = from }, .to = .{ .dyn_at = .{ .f = to, .fx = f, .fy = f } } } };
}

fn temaMerged(app: *App) bool {
    if (new_id == 0) for (app.store.folders) |f| {
        if (f.id != 0 and f.id != 77 and f.id != 78) new_id = f.id;
    };
    return new_id != 0 and barIs(app, "[N:0,1] [77:2,8,4] 5 [78:6,3] 7 9") and patchMatches(app, 1) and
        qa.find(markFmt(&mb, "folder:{d}", .{new_id})) != null;
}
fn temaOpened(app: *App) bool {
    return app.st.open_folders.contains(new_id) and qa.find(markFmt(&mb, "guild:{d}", .{G(1)})) != null;
}
fn temaOut(app: *App) bool {
    return barIs(app, "1 [N:0] [77:2,8,4] 5 [78:6,3] 7 9") and patchMatches(app, 2);
}
/// A pasta nova não tem nome: no menu, o nome do servidor dela.
fn tPickNew(app: *App, b: []u8) []const u8 {
    const g = app.store.guild(G(0)) orelse return "";
    return markFmt(b, "menu:{s}", .{g.name});
}
fn temaAdded(app: *App) bool {
    return barIs(app, "1 [N:0,5] [77:2,8,4] [78:6,3] 7 9") and patchMatches(app, 3);
}
fn temaRemoved(app: *App) bool {
    return barIs(app, "1 0 5 [77:2,8,4] [78:6,3] 7 9") and patchMatches(app, 4) and qa.find(markFmt(&mb, "folder:{d}", .{new_id})) == null;
}

pub const ops_tema = [_]Op{
    expect("barra com as pastas da demonstração", demoBar),
    run(snapshot),
    s("pastas no tema: servidor em cima de outro"),
    dragAt(tG(1), tG(0), 0.5),
    expect("pasta nova, desenhada na barra", temaMerged),
    clickDyn(tNew),
    expect("aberta, mostra os servidores dela", temaOpened),
    .{ .shot = "pastas-tema-aberta" },
    s("pastas no tema: para fora e pelo menu"),
    dragAt(tG(1), tNew, 0.08),
    expect("antes da pasta, fora dela", temaOut),
    rclickDyn(tG(5)),
    click("menu:Adicionar à pasta…"),
    clickDyn(tPickNew),
    expect("na pasta pelo menu", temaAdded),
    rclickDyn(tNew),
    click("menu:Remover pasta"),
    expect("pasta desfeita, sumiu da barra", temaRemoved),
};

// --- Barra sem pastas: abas de texto e dock (QA_SUITE=pastas-plana) -------------------

fn planaFirst(app: *App) bool {
    return barIs(app, "1 0 [77:2,8,4] 5 [78:6,3] 7 9") and patchMatches(app, 1);
}
fn planaInside(app: *App) bool {
    return barIs(app, "1 0 [77:2,8,4] 5 [78:6,7,3] 9") and patchMatches(app, 2);
}
fn planaEdge(app: *App) bool {
    return barIs(app, "1 0 [77:2,8,4] 5 [78:6,3] 7 9") and patchMatches(app, 3);
}
fn planaMenu(app: *App) bool {
    return barIs(app, "1 0 [77:2,8,4] [78:6,3,5] 7 9") and patchMatches(app, 4);
}

pub const ops_plana = [_]Op{
    expect("barra com os servidores da demonstração", demoBar),
    run(snapshot),
    s("barra sem pastas: arrastar só reordena"),
    dragAt(tG(1), tG(0), 0.08),
    expect("antes do outro", planaFirst),
    // No meio do grupo de uma pasta: entra nela; na ponta: fica fora.
    dragAt(tG(7), tG(6), 0.92),
    expect("no meio do grupo, dentro da pasta", planaInside),
    dragAt(tG(7), tG(3), 0.92),
    expect("na ponta do grupo, fora da pasta", planaEdge),
    rclickDyn(tG(5)),
    click("menu:Adicionar à pasta…"),
    clickDyn(tPickJogos),
    expect("os menus valem aqui também", planaMenu),
};
