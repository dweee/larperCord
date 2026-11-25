//! QA dos clipes dos GIFs favoritos (ui/gif_clips.zig), em dois processos, como abrir o app
//! de novo. O primeiro (QA_SUITE=gif-clipes-a) abre o seletor: a lista dos favoritos vem
//! sozinha e os clipes que faltam são feitos em segundo plano, um por vez; a estrela num GIF
//! faz o clipe dele, um WebP pequeno que abre de volta no tamanho e com os quadros certos; a
//! aba Favoritos desenha cada GIF do clipe, todos animando; tirar dos favoritos apaga o
//! clipe; o teto tira o menos usado; Configurações → Privacidade mostra e "Apagar cache"
//! leva tudo; e a aba refaz o que falta. O segundo (QA_SUITE=gif-clipes-b, sem apagar
//! qa-out/gif-favorites entre os dois: tools/qa.sh) abre pelo que ficou no disco: a lista
//! guardada volta, e a aba desenha tudo dos clipes sem baixar mídia nenhuma, mesmo com as
//! mídias apontando para o Tenor e os GIFs de fora ligados.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gif_clips = @import("ui/gif_clips.zig");
const clipe = @import("core/gif_clipe.zig");
const images = @import("ui/images.zig");

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn expectIn(name: []const u8, f: *const fn (*App) bool, ms: u32) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = ms } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}

// Os GIFs da demonstração (net/fake_gateway.zig): os três primeiros já são favoritos.
const cat = "https://tenor.com/view/dancing-cat-gif-1000";
const thumbs = "https://tenor.com/view/thumbs-up-gif-1001";
const morning = "https://tenor.com/view/good-morning-gif-1002";
const laughing = "https://tenor.com/view/laughing-gif-1003";
const seeded = [_][]const u8{ cat, thumbs, morning };

/// O GIF da demonstração tem 24 quadros de 50 ms em 480×270: no clipe, um sim e um não
/// (no máximo 15 por segundo), 12 quadros de 100 ms, 1,2 s.
const demo_frames = 12;
const demo_end_ms = 1200;

fn ready(app: *App) bool {
    return app.store.ready and app.st.activeChannel() != null;
}

var fetches0: u32 = 0;

/// Começa do zero (rodando sozinho, sem o tools/qa.sh): nada na pasta, contadores zerados.
fn wipe(app: *App) void {
    gif_clips.clearAll(&app.images);
    gif_clips.made = 0;
    gif_clips.evictions = 0;
    gif_clips.max_running.store(0, .release);
    gif_clips.cap_bytes = clipe.default_cap;
    fetches0 = images.fetches.load(.monotonic);
}

fn trending(app: *App) bool {
    const l = app.store.gif_results;
    return app.st.popup == .gif and l.state == .ready and l.items.len == 8 and qa.find("gif:7") != null;
}

fn favsReady(app: *App) bool {
    const l = app.store.gif_favorites;
    return l.state == .ready and l.items.len == 3;
}

fn hasClip(url: []const u8) bool {
    var b: [600]u8 = undefined;
    const p = gif_clips.clipPath(&b, url) orelse return false;
    return @import("platform/sys.zig").exists(p.ptr);
}

fn seededClipped(app: *App) bool {
    if (!favsReady(app) or gif_clips.busy()) return false;
    for (seeded) |u| if (!hasClip(u)) return false;
    return gif_clips.made == 3 and gif_clips.max_running.load(.acquire) == 1;
}

/// O que um clipe tem quando aberto de volta pela libwebpdemux.
const Info = struct { w: u32, h: u32, frames: u32, end_ms: c_int, size: usize };

fn clipInfo(url: []const u8) ?Info {
    var b: [600]u8 = undefined;
    const p = gif_clips.clipPath(&b, url) orelse return null;
    var size: usize = 0;
    const data = c.SDL_LoadFile(p.ptr, &size) orelse return null;
    defer c.SDL_free(data);
    var opts: c.WebPAnimDecoderOptions = undefined;
    if (c.WebPAnimDecoderOptionsInit(&opts) == 0) return null;
    opts.color_mode = c.MODE_RGBA;
    opts.use_threads = 0;
    const wd: c.WebPData = .{ .bytes = @ptrCast(data), .size = size };
    const dec = c.WebPAnimDecoderNew(&wd, &opts) orelse return null;
    defer c.WebPAnimDecoderDelete(dec);
    var info: c.WebPAnimInfo = undefined;
    if (c.WebPAnimDecoderGetInfo(dec, &info) == 0) return null;
    var n: u32 = 0;
    var last: c_int = 0;
    while (c.WebPAnimDecoderHasMoreFrames(dec) != 0) {
        var buf: [*c]u8 = null;
        var ts: c_int = 0;
        if (c.WebPAnimDecoderGetNext(dec, &buf, &ts) == 0 or buf == null) return null;
        n += 1;
        last = ts;
    }
    if (n != info.frame_count) return null;
    return .{ .w = info.canvas_width, .h = info.canvas_height, .frames = n, .end_ms = last, .size = size };
}

fn starClipped(app: *App) bool {
    return app.store.gif_favorites.has(laughing) and hasClip(laughing) and !gif_clips.busy();
}

fn clipSmall(_: *App) bool {
    const i = clipInfo(laughing) orelse return false;
    return i.size <= clipe.size_target;
}

var laughing_path: [600]u8 = undefined;
var laughing_len: usize = 0;

fn clipDecodes(_: *App) bool {
    const i = clipInfo(laughing) orelse return false;
    const want = clipe.clipSize(480, 270, clipe.sideFor(gif_clips.scale));
    if (i.w != want[0] or i.h != want[1] or i.frames != demo_frames or i.end_ms != demo_end_ms) {
        std.debug.print("    clipe: {d}×{d}, {d} quadros, fim em {d} ms, {d} bytes (esperado {d}×{d}, {d}, {d})\n", .{ i.w, i.h, i.frames, i.end_ms, i.size, want[0], want[1], demo_frames, demo_end_ms });
        return false;
    }
    var b: [600]u8 = undefined;
    const p = gif_clips.clipPath(&b, laughing) orelse return false;
    @memcpy(laughing_path[0..p.len], p);
    laughing_len = p.len;
    return true;
}

/// Cada GIF da aba que está na tela foi desenhado do clipe dele, e cada clipe na memória das
/// imagens está pronto e tocando (decodificando aos poucos: só o anel na memória).
fn tilesFromClips(app: *App) bool {
    if (app.st.popup != .gif) return false;
    var shown: usize = 0;
    var b: [24]u8 = undefined;
    var cb: [24]u8 = undefined;
    for (0..8) |i| {
        const g = std.fmt.bufPrint(&b, "gif:{d}", .{i}) catch continue;
        if (qa.visiblePart(g) == null) continue;
        if (qa.find(std.fmt.bufPrint(&cb, "gif-clip:{d}", .{i}) catch continue) == null) return false;
        shown += 1;
    }
    var playing: usize = 0;
    var it = app.images.map.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        if (std.mem.indexOf(u8, k, "s file://") == null or std.mem.indexOf(u8, k, "gif-favorites") == null) continue;
        if (e.value_ptr.state == .ready and e.value_ptr.stream != null) playing += 1;
    }
    return shown >= 3 and playing >= shown;
}

fn noDownloads(_: *App) bool {
    const f = images.fetches.load(.monotonic);
    if (f != fetches0) std.debug.print("    downloads de mídia: antes {d}, depois {d}\n", .{ fetches0, f });
    return f == fetches0;
}

fn favTab(app: *App) bool {
    return tilesFromClips(app) and noDownloads(app);
}

fn unstarredGone(app: *App) bool {
    if (app.store.gif_favorites.has(laughing) or gif_clips.entry(laughing) != null) return false;
    if (laughing_len == 0) return false;
    var p: [601]u8 = undefined;
    @memcpy(p[0..laughing_len], laughing_path[0..laughing_len]);
    p[laughing_len] = 0;
    return !@import("platform/sys.zig").exists(@ptrCast(&p));
}

// --- Teto ---------------------------------------------------------------------------------

var cat_path: [600]u8 = undefined;
var cat_len: usize = 0;
var cap_set: u64 = 0;

/// Ordem de uso conhecida (o gato é o mostrado há mais tempo) e um teto que cabe só os
/// outros dois: tem que sair o gato, e só ele.
fn tinyCap(app: *App) void {
    gif_clips.touchAt(cat, 1000);
    gif_clips.touchAt(thumbs, 2000);
    gif_clips.touchAt(morning, 3000);
    const a = gif_clips.entry(thumbs) orelse return;
    const b = gif_clips.entry(morning) orelse return;
    var pb: [600]u8 = undefined;
    const p = gif_clips.clipPath(&pb, cat) orelse return;
    @memcpy(cat_path[0..p.len], p);
    cat_len = p.len;
    cap_set = a.size + b.size;
    gif_clips.evictions = 0;
    gif_clips.cap_bytes = cap_set;
    gif_clips.enforceNow(&app.images);
}

fn lruEvicted(_: *App) bool {
    const e = gif_clips.entry(cat) orelse return false;
    if (e.hasClip() or !e.evicted or cat_len == 0) return false;
    var p: [601]u8 = undefined;
    @memcpy(p[0..cat_len], cat_path[0..cat_len]);
    p[cat_len] = 0;
    if (@import("platform/sys.zig").exists(@ptrCast(&p))) return false;
    return hasClip(thumbs) and hasClip(morning) and gif_clips.evictions == 1 and gif_clips.stats().bytes <= cap_set;
}

fn capBack(_: *App) void {
    gif_clips.cap_bytes = clipe.default_cap;
}

// --- Configurações e "Apagar cache" ---------------------------------------------------------

fn privacyShows(app: *App) bool {
    return app.st.settings.open and app.st.settings.page == .privacidade and qa.find("gif-clips-stats") != null and
        gif_clips.totalBytes() > 0 and gif_clips.stats().clips == 2;
}

fn tClearCache(_: *App, b: []u8) []const u8 {
    var keys: [4][56]u8 = undefined;
    var lens: [4]u8 = undefined;
    if (qa.keysWith(&.{"button:Apagar cache"}, &keys, &lens) == 0) return "";
    const n = lens[0];
    @memcpy(b[0..n], keys[0][0..n]);
    return b[0..n];
}

fn folderEmpty(_: *App) bool {
    if (gif_clips.stats().clips != 0 or gif_clips.totalBytes() != 0) return false;
    var db: [600]u8 = undefined;
    const d = gif_clips.accountDir(&db) orelse return false;
    const dir = c.opendir(d.ptr) orelse return true;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |e| {
        const name = std.mem.sliceTo(&e.*.d_name, 0);
        if (name.len > 0 and name[0] != '.') return false;
    }
    return true;
}

fn remadeAll(app: *App) bool {
    if (!favsReady(app) or gif_clips.busy()) return false;
    for (seeded) |u| if (!hasClip(u)) return false;
    return tilesFromClips(app);
}

pub const ops_a = [_]Op{
    s("clipes dos GIFs favoritos"),
    expectIn("carrega", ready, 5000),
    run(wipe),
    click("composer-gif"),
    expectIn("abre o seletor nos em alta", trending, 3000),
    expectIn("a lista dos favoritos vem ao abrir, sem clicar na aba", favsReady, 3000),
    expectIn("os clipes que faltam são feitos em segundo plano, um por vez", seededClipped, 20000),
    .{ .hover = .{ .mark = "gif:3" } },
    .{ .wait = 150 },
    click("gif-star:3"),
    expectIn("a estrela num GIF faz o clipe dele", starClipped, 10000),
    expect("o clipe tem no máximo 40 KB", clipSmall),
    expect("e abre de volta pela libwebpdemux no tamanho da célula, com 12 quadros e 1,2 s", clipDecodes),
    click("gif-tab:1"),
    expectIn("a aba Favoritos desenha cada GIF do clipe, todos tocando, sem baixar mídia", favTab, 3000),
    .{ .shot = "gif-clipes-favoritos" },
    .{ .hover = .{ .mark = "gif:0" } },
    .{ .wait = 150 },
    click("gif-star:0"),
    expectIn("tirar dos favoritos apaga o clipe quando a lista da conta volta", unstarredGone, 4000),
    key(c.ImGuiKey_Escape),
    s("teto da pasta dos clipes"),
    run(tinyCap),
    expect("passou do teto: sai o clipe mostrado há mais tempo, e só ele", lruEvicted),
    run(capBack),
    s("Configurações → Privacidade e Apagar cache"),
    .{ .key = .{ .key = c.ImGuiKey_Comma, .ctrl = true } },
    click("settings:Privacidade"),
    expectIn("a página mostra os clipes, e o tamanho deles entra no do cache", privacyShows, 3000),
    .{ .click = .{ .dyn = tClearCache } },
    expectIn("Apagar cache leva a pasta dos clipes", folderEmpty, 3000),
    key(c.ImGuiKey_Escape),
    click("composer-gif"),
    click("gif-tab:1"),
    expectIn("a aba refaz os clipes que faltam", remadeAll, 20000),
};

// --- Segundo processo ------------------------------------------------------------------------

fn savedBack(app: *App) bool {
    return ready(app) and gif_clips.cachedList().len == 3 and gif_clips.stats().clips == 3;
}

fn markStart(app: *App) void {
    fetches0 = images.fetches.load(.monotonic);
    gif_clips.made = 0;
    // Com os GIFs de fora ligados, uma célula que fosse à rede baixaria de verdade (e o
    // contador de downloads subiria).
    app.st.settings.gif_hosts = true;
}

/// As mídias dos favoritos passam a apontar para o Tenor: se a aba pedisse a cópia da
/// rede, o pedido apareceria no cache das imagens e no contador de downloads.
fn tenorSrcs(app: *App) void {
    const ca = std.heap.c_allocator;
    for (app.store.gif_favorites.items, 0..) |*g, i| {
        const src = std.fmt.allocPrint(ca, "https://media.tenor.com/QaClipe{d}AAAAx/clipe.webp", .{i}) catch continue;
        ca.free(g.src);
        g.src = src;
    }
}

fn noNetwork(app: *App) bool {
    var it = app.images.map.keyIterator();
    while (it.next()) |k| if (std.mem.indexOf(u8, k.*, "media.tenor.com") != null) {
        std.debug.print("    pedido à rede: {s}\n", .{k.*});
        return false;
    };
    return tilesFromClips(app) and noDownloads(app) and gif_clips.made == 0 and !gif_clips.busy();
}

fn hostsBack(app: *App) void {
    app.st.settings.gif_hosts = false;
}

pub const ops_b = [_]Op{
    s("clipes dos GIFs favoritos depois de reabrir"),
    expectIn("a lista guardada volta do disco com os 3 clipes", savedBack, 5000),
    run(markStart),
    click("composer-gif"),
    expectIn("abre o seletor", trending, 3000),
    click("gif-tab:1"),
    expectIn("a aba abre já com cada GIF tocando do clipe", tilesFromClips, 1500),
    expectIn("a lista da conta chega por cima, a mesma", favsReady, 3000),
    run(tenorSrcs),
    .{ .wait = 800 },
    expect("nada foi à rede: nenhum download de mídia, nenhum pedido ao Tenor, nenhum clipe refeito", noNetwork),
    .{ .shot = "gif-clipes-reaberto" },
    run(hostsBack),
    key(c.ImGuiKey_Escape),
};
