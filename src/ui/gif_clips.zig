//! Clipes dos GIFs favoritos: um WebP animado pequeno de cada favorito numa pasta da
//! conta, para a aba Favoritos do seletor abrir já com tudo animando, sem esperar a rede.
//! A lista da conta (core/gif_favorites.zig, nas configurações dela no Discord) continua
//! mandando; isto é só um cache dela (as contas ficam em core/gif_clipe.zig).
//!
//! Fica em $XDG_CACHE_HOME/larpercord/gif-favorites/<conta>/ (~/.cache, ou
//! %LOCALAPPDATA% no Windows): um arquivo por favorito, com o hash do link no nome, e
//! `index`, a lista como a pasta conhece (a ordem, o arquivo de cada um e quando foi
//! mostrado). Pastas 700 e arquivos 600 no Linux, como o cache de mensagens. Teto de 50 MB
//! por conta: sai o clipe mostrado há mais tempo. O que deixou de ser favorito sai na
//! próxima vez que a lista da conta é lida. "Apagar cache", a conta removida e "Apagar
//! todos os dados" levam tudo.
//!
//! Cada clipe tem até 160 px no lado maior com a interface em 100% (acompanha a escala),
//! até 15 quadros por segundo e os primeiros 6 s, com a qualidade que deixa perto de 40 KB;
//! um original de até 64 KB (GIF ou WebP) fica como veio. Feito numa thread só, um por vez,
//! nunca na da interface: na estrela, com o arquivo que as imagens acabaram de baixar; os
//! que faltam (outro aparelho, a primeira vez), baixados pelo mesmo caminho das imagens
//! (domínios permitidos, proxy), respeitando o modo economia e "Animar GIFs do Tenor e do
//! Giphy". A célula com clipe não baixa nada da rede, e enviar continua mandando o link do
//! GIF, como sempre.
const std = @import("std");
const c = @import("c");
const sys = @import("../platform/sys.zig");
const fsutil = @import("../platform/fsutil.zig");
const platform = @import("../platform/window.zig");
const images = @import("images.zig");
const media_url = @import("../net/media_url.zig");
const clipe = @import("../core/gif_clipe.zig");
const types = @import("../core/types.zig");
const Store = @import("../core/store.zig").Store;

const alloc = std.heap.c_allocator;
const index_name = "index";

/// Desligado de vez (prints da documentação: sempre os mesmos dados).
pub var off = false;
/// Teto da pasta da conta (o QA diminui para ver o que sai).
pub var cap_bytes: u64 = clipe.default_cap;
/// Pixels por ponto da última vez que o seletor desenhou: o tamanho dos clipes novos.
pub var scale: f32 = 1;

// Para o QA: clipes feitos e tirados pelo teto nesta sessão, e quantos já foram feitos ao
// mesmo tempo (nunca mais de um).
pub var made: u32 = 0;
pub var evictions: u32 = 0;
pub var max_running: std.atomic.Value(u32) = .init(0);
var running: std.atomic.Value(u32) = .init(0);

var wake_type: u32 = 0;
var root_buf: [448]u8 = undefined;
var root_len: usize = 0;
/// Pasta da conta conectada: o ID dela, ou "demo".
var acct_buf: [24]u8 = undefined;
var acct_len: usize = 0;
var index: clipe.Index = .{};
/// A lista guardada como o seletor desenha (aponta para os textos de `index`).
var listed: std.ArrayList(types.Gif) = .empty;
/// A lista mudou desde a última gravação.
var dirty = false;
var dirs_ok = false;
/// Muda com a conta e com "Apagar cache": o clipe que estava sendo feito não vale mais.
var gen: u32 = 0;
/// Bytes da pasta inteira (todas as contas), para Configurações → Privacidade.
var total_all: u64 = 0;
var total_known = false;

const Pending = struct { url: []u8, src: []u8, star: bool };
/// O que falta fazer, na ordem (só a thread da interface mexe).
var queue: std.ArrayList(Pending) = .empty;
/// Não deram certo nesta sessão: não tentam de novo até o app abrir outra vez (ou uma
/// estrela nova).
var failed: std.StringHashMapUnmanaged(void) = .empty;
/// Saíram pelo teto e já voltaram nesta sessão: não voltam de novo (o teto não comporta o
/// que a aba mostra, e eles ficariam se revezando).
var remade: std.StringHashMapUnmanaged(void) = .empty;
/// Nada na fila pode andar com o modo economia e a opção dos GIFs de fora como estão: ela
/// só olha de novo quando eles mudam ou chega um pedido novo.
var queue_blocked = false;
var settings_seen: u64 = 0;

const Job = struct {
    url: []u8,
    src: []u8,
    /// A pasta da conta.
    dir: [:0]u8,
    side: u16,
    gen: u32,
};
const Result = struct { ok: bool = false, file: clipe.File = .{}, size: u64 = 0 };

// O trabalho em andamento: a thread lê `job` e escreve `result` antes de `done`; a da
// interface só mexe neles depois de `done`.
var thread: ?*c.SDL_Thread = null;
var job: ?Job = null;
var result: Result = .{};
var done: std.atomic.Value(bool) = .init(false);
var stopping: std.atomic.Value(bool) = .init(false);

/// `qa`: tudo em qa-out/gif-favorites (o QA nunca mexe no cache de verdade).
pub fn init(wake: u32, qa: bool) void {
    wake_type = wake;
    if (sys.web) return;
    const r: []const u8 = if (qa)
        std.fmt.bufPrint(&root_buf, "qa-out/gif-favorites", .{}) catch ""
    else blk: {
        var hb: [400]u8 = undefined;
        const base = sys.cacheHome(&hb) orelse break :blk "";
        break :blk std.fmt.bufPrint(&root_buf, "{s}/larpercord/gif-favorites", .{base}) catch "";
    };
    root_len = r.len;
}

fn root() []const u8 {
    return root_buf[0..root_len];
}

fn account() []const u8 {
    return acct_buf[0..acct_len];
}

fn usable() bool {
    return !sys.web and !off and root_len > 0 and acct_len > 0;
}

fn nowMs() i64 {
    var t: c.SDL_Time = 0;
    _ = c.SDL_GetCurrentTime(&t);
    return @divTrunc(t, 1_000_000);
}

fn filePath(buf: []u8, name: []const u8) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}/{s}", .{ root(), account(), name }, 0) catch null;
}

/// O endereço que o cache das imagens abre ("file://…").
fn fileUrl(buf: []u8, name: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "file://{s}/{s}/{s}", .{ root(), account(), name }) catch null;
}

fn ensureDirs() bool {
    if (dirs_ok) return true;
    var buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root(), account() }) catch return false;
    dirs_ok = fsutil.ensureDir(dir);
    return dirs_ok;
}

fn addTotal(delta: i64) void {
    if (!total_known) return;
    total_all = if (delta < 0) total_all -| @as(u64, @intCast(-delta)) else total_all + @as(u64, @intCast(delta));
}

// --- Conta ----------------------------------------------------------------------------

/// Conta da sessão (0 = demonstração): lê a lista guardada dela.
pub fn setAccount(id: types.Id) void {
    if (sys.web or root_len == 0) return;
    var nb: [24]u8 = undefined;
    const name = if (id == 0) "demo" else std.fmt.bufPrint(&nb, "{d}", .{id}) catch return;
    // A mesma (o READY de verdade depois de abrir pelo retrato): nada muda.
    if (acct_len > 0 and std.mem.eql(u8, name, account())) return;
    leave();
    @memcpy(acct_buf[0..name.len], name);
    acct_len = name.len;
    load();
}

/// Sem conta (a aberta está sendo removida): grava o que tinha e para de mexer na pasta.
pub fn detach() void {
    if (acct_len > 0) leave();
}

/// Conta removida: os clipes dela vão junto.
pub fn removeAccount(id: types.Id) void {
    if (sys.web or root_len == 0 or id == 0) return;
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&buf, "{s}/{d}", .{ root(), id }, 0) catch return;
    addTotal(-@as(i64, @intCast(removeDir(p))));
}

/// Sai da conta atual: grava a lista e esquece a fila e o clipe que estava sendo feito.
fn leave() void {
    save();
    gen +%= 1;
    clearQueue();
    clearSet(&failed);
    clearSet(&remade);
    index.deinit(alloc);
    listed.clearRetainingCapacity();
    dirty = false;
    dirs_ok = false;
    acct_len = 0;
}

fn clearSet(set: *std.StringHashMapUnmanaged(void)) void {
    var it = set.keyIterator();
    while (it.next()) |k| alloc.free(k.*);
    set.clearRetainingCapacity();
}

fn clearQueue() void {
    for (queue.items) |p| {
        alloc.free(p.url);
        alloc.free(p.src);
    }
    queue.clearRetainingCapacity();
}

fn load() void {
    if (!usable()) return;
    var pb: [600]u8 = undefined;
    const p = filePath(&pb, index_name) orelse return;
    var size: usize = 0;
    if (c.SDL_LoadFile(p.ptr, &size)) |data| {
        defer c.SDL_free(data);
        index = clipe.Index.read(alloc, @as([*]const u8, @ptrCast(data))[0..size]) catch .{};
    }
    sweep();
    rebuildListed();
}

/// Confere a pasta com a lista: arquivo listado que sumiu por fora fica sem clipe, e clipe
/// que a lista não conhece (o app fechou no meio, uma conta de antes de uma limpeza) e
/// temporário que sobrou saem.
fn sweep() void {
    var db: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrintSentinel(&db, "{s}/{s}", .{ root(), account() }, 0) catch return;
    var present: std.StringHashMapUnmanaged(void) = .empty;
    defer clearAndFree(&present);
    if (c.opendir(dir_path.ptr)) |dir| {
        defer _ = c.closedir(dir);
        while (c.readdir(dir)) |ent| {
            const name = std.mem.sliceTo(&ent.*.d_name, 0);
            var fb: [600]u8 = undefined;
            const fp = filePath(&fb, name) orelse continue;
            if (std.mem.endsWith(u8, name, ".tmp")) {
                _ = c.unlink(fp.ptr);
                continue;
            }
            if (clipe.File.parse(name) == null) continue;
            const owned = alloc.dupe(u8, name) catch continue;
            present.put(alloc, owned, {}) catch alloc.free(owned);
        }
    }
    for (index.items.items, 0..) |*e, i| {
        if (e.hasClip() and !present.contains(e.file.slice())) _ = index.dropClip(i, false);
    }
    var it = present.keyIterator();
    while (it.next()) |k| {
        var known = false;
        for (index.items.items) |*e| {
            if (e.hasClip() and std.mem.eql(u8, e.file.slice(), k.*)) known = true;
        }
        if (known) continue;
        var fb: [600]u8 = undefined;
        const fp = filePath(&fb, k.*) orelse continue;
        const sz = sys.fileSize(fp.ptr) orelse 0;
        if (c.unlink(fp.ptr) == 0) addTotal(-@as(i64, @intCast(sz)));
    }
}

fn clearAndFree(set: *std.StringHashMapUnmanaged(void)) void {
    clearSet(set);
    set.deinit(alloc);
}

fn rebuildListed() void {
    listed.clearRetainingCapacity();
    listed.ensureTotalCapacity(alloc, index.items.items.len) catch return;
    for (index.items.items) |e| listed.appendAssumeCapacity(.{ .url = e.url, .src = e.src });
}

/// Grava a lista se mudou. Num .tmp e depois troca de nome, como o resto do cache.
fn save() void {
    if (!dirty or !usable()) return;
    dirty = false;
    var pb: [600]u8 = undefined;
    const p = filePath(&pb, index_name) orelse return;
    const before = sys.fileSize(p.ptr);
    if (index.items.items.len == 0) {
        if (before) |b| if (c.unlink(p.ptr) == 0) addTotal(-@as(i64, @intCast(b)));
        return;
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    index.write(alloc, &out) catch return;
    if (!ensureDirs()) return;
    if (!fsutil.replacePrivate(p, out.items)) {
        // A pasta pode ter sumido por fora: cria de novo na próxima.
        dirs_ok = false;
        return;
    }
    addTotal(@as(i64, @intCast(out.items.len)) - @as(i64, @intCast(before orelse 0)));
}

/// Apaga o arquivo de um clipe (e a textura dele, se o seletor estava mostrando).
fn deleteFile(f: clipe.File, cache: ?*images.Cache) void {
    if (f.len == 0) return;
    var ub: [700]u8 = undefined;
    if (cache) |ch| if (fileUrl(&ub, f.slice())) |u| ch.forget(u);
    var fb: [600]u8 = undefined;
    const fp = filePath(&fb, f.slice()) orelse return;
    const sz = sys.fileSize(fp.ptr) orelse return;
    if (c.unlink(fp.ptr) == 0) addTotal(-@as(i64, @intCast(sz)));
}

// --- O seletor --------------------------------------------------------------------------

/// A lista guardada, do mais novo para o mais velho: o seletor mostra antes de a lista da
/// conta chegar (e sem rede). Vale até a próxima mudança da lista.
pub fn cachedList() []types.Gif {
    return if (usable()) listed.items else &.{};
}

/// O favorito `url` tem clipe?
pub fn has(url: []const u8) bool {
    if (!usable()) return false;
    const i = index.find(url) orelse return false;
    return index.items.items[i].hasClip();
}

pub const Tile = union(enum) {
    /// O clipe para desenhar ("file://…", em `buf`).
    clip: []const u8,
    /// Sendo feito, ou na fila: a célula espera, sem baixar o GIF da rede.
    making,
    /// Sem clipe (desligado, deu errado, o modo economia ou a opção dos GIFs de fora não
    /// deixam baixar): o caminho de sempre.
    none,
};

/// O que a célula do favorito `url` desenha. Sem clipe e podendo fazer, pede (as células
/// na tela passam na frente da fila).
pub fn tile(buf: []u8, cache: *const images.Cache, url: []const u8, src: []const u8, now: i64) Tile {
    if (!usable()) return .none;
    var evicted = false;
    if (index.find(url)) |i| {
        const e = &index.items.items[i];
        if (e.hasClip()) {
            // O uso vai para o arquivo na próxima gravação (nada é gravado a cada quadro).
            if (now - e.used > 1000) {
                index.touch(i, now);
                dirty = true;
            }
            return .{ .clip = fileUrl(buf, e.file.slice()) orelse return .none };
        }
        evicted = e.evicted;
        if (evicted and remade.contains(url)) return .none;
    }
    if (failed.contains(url) or !allowed(cache, src)) return .none;
    if (!pending(url)) {
        if (evicted) mark(&remade, url);
        enqueue(url, src, true, true);
    }
    return .making;
}

/// O clipe de `url` não abriu (arquivo estragado): sai, e a célula volta ao caminho de
/// sempre nesta sessão.
pub fn bad(url: []const u8, cache: *images.Cache) void {
    if (!usable()) return;
    const i = index.find(url) orelse return;
    deleteFile(index.dropClip(i, false), cache);
    mark(&failed, url);
    dirty = true;
    save();
}

/// Pode baixar a mídia de `src` agora? As mesmas regras das imagens: o modo economia só
/// deixa o que a pessoa liberou com um clique, e de fora do Discord só o Tenor e o Giphy,
/// com "Animar GIFs do Tenor e do Giphy" ligado.
fn allowed(cache: *const images.Cache, src: []const u8) bool {
    if (cache.blocked(src)) return false;
    if (std.mem.startsWith(u8, src, "demo:")) return true;
    if (std.mem.startsWith(u8, src, media_url.tenor_page)) return media_url.allow_gif_hosts.load(.acquire);
    return media_url.allowedHost(src);
}

fn mark(set: *std.StringHashMapUnmanaged(void), url: []const u8) void {
    if (set.contains(url)) return;
    const owned = alloc.dupe(u8, url) catch return;
    set.put(alloc, owned, {}) catch alloc.free(owned);
}

fn inFlight(url: []const u8) bool {
    const j = job orelse return false;
    return std.mem.eql(u8, j.url, url);
}

/// Na fila ou sendo feito.
fn pending(url: []const u8) bool {
    if (inFlight(url)) return true;
    for (queue.items) |p| if (std.mem.eql(u8, p.url, url)) return true;
    return false;
}

fn enqueue(url: []const u8, src: []const u8, star: bool, front: bool) void {
    const u = alloc.dupe(u8, url) catch return;
    const s = alloc.dupe(u8, src) catch return alloc.free(u);
    const p: Pending = .{ .url = u, .src = s, .star = star };
    (if (front) queue.insert(alloc, 0, p) else queue.append(alloc, p)) catch {
        alloc.free(u);
        alloc.free(s);
        return;
    };
    queue_blocked = false;
}

// --- A lista da conta e a estrela -------------------------------------------------------

/// A estrela de um GIF (no seletor ou na conversa). `shown` é o que a tela desenhou: o
/// arquivo dele acabou de baixar, e o clipe sai dele sem ir à rede de novo. Tirar não
/// apaga nada aqui: a lista da conta que volta da gravação é que diz.
pub fn starred(url: []const u8, shown: []const u8, add: bool) void {
    if (!usable() or !add or shown.len == 0 or has(url)) return;
    if (failed.fetchRemove(url)) |kv| alloc.free(kv.key);
    if (pending(url)) return;
    enqueue(url, shown, true, true);
}

/// A lista da conta chegou (o Discord respondeu): quem deixou de ser favorito leva o clipe
/// junto, e quem ainda não tem clipe entra na fila (no fim: as estrelas e as células na
/// tela vêm antes).
pub fn sync(items: []const types.Gif, cache: *images.Cache) void {
    if (!usable()) return;
    var gone: std.ArrayList(clipe.File) = .empty;
    defer gone.deinit(alloc);
    index.sync(alloc, items, &gone) catch return;
    for (gone.items) |f| deleteFile(f, cache);
    // Na fila sem ser mais favorito: sai.
    var i: usize = 0;
    while (i < queue.items.len) {
        if (index.find(queue.items[i].url) == null) {
            const p = queue.orderedRemove(i);
            alloc.free(p.url);
            alloc.free(p.src);
        } else i += 1;
    }
    for (index.items.items) |*e| {
        if (e.hasClip() or e.evicted or failed.contains(e.url) or pending(e.url)) continue;
        enqueue(e.url, e.src, false, false);
    }
    rebuildListed();
    dirty = true;
    save();
}

// --- O laço do app ------------------------------------------------------------------------

/// Thread da interface, a cada volta do laço: recolhe o clipe que ficou pronto e começa o
/// próximo da fila. true = um clipe novo para desenhar.
pub fn pump(cache: *images.Cache, store: *const Store) bool {
    if (sys.web) return false;
    var changed = false;
    if (thread != null and done.load(.acquire)) {
        c.SDL_WaitThread(thread, null);
        thread = null;
        changed = finish(cache, store);
    }
    if (thread == null and queue.items.len > 0 and usable()) {
        // O modo economia, os GIFs de fora e o que a pessoa liberou com um clique.
        const sig = @as(u64, @intFromBool(cache.data_saver)) | @as(u64, @intFromBool(media_url.allow_gif_hosts.load(.acquire))) << 1 | @as(u64, cache.allowed.count()) << 2;
        if (!queue_blocked or sig != settings_seen) {
            settings_seen = sig;
            start(cache);
        }
    }
    return changed;
}

/// Começa o primeiro da fila que pode baixar agora.
fn start(cache: *const images.Cache) void {
    var i: usize = 0;
    while (i < queue.items.len) {
        const p = queue.items[i];
        if (!allowed(cache, p.src)) {
            i += 1;
            continue;
        }
        _ = queue.orderedRemove(i);
        // Ficou pronto enquanto esperava (a mesma estrela duas vezes): nada a fazer.
        if (has(p.url)) {
            alloc.free(p.url);
            alloc.free(p.src);
            continue;
        }
        var db: [512]u8 = undefined;
        const dir = std.fmt.bufPrint(&db, "{s}/{s}", .{ root(), account() }) catch "";
        const owned_dir = if (dir.len > 0 and ensureDirs()) alloc.dupeSentinel(u8, dir, 0) catch null else null;
        const d = owned_dir orelse {
            alloc.free(p.url);
            alloc.free(p.src);
            return;
        };
        job = .{ .url = p.url, .src = p.src, .dir = d, .side = clipe.sideFor(scale), .gen = gen };
        result = .{};
        done.store(false, .release);
        stopping.store(false, .release);
        thread = if (sys.web) null else c.SDL_CreateThread(work, "gif-clip", null);
        if (thread == null) {
            freeJob();
            std.log.warn("não consegui criar a thread dos clipes de GIF", .{});
        }
        return;
    }
    queue_blocked = true;
}

fn freeJob() void {
    const j = job orelse return;
    alloc.free(j.url);
    alloc.free(j.src);
    alloc.free(j.dir);
    job = null;
}

/// O clipe ficou pronto (ou não deu): entra na lista, e o que passar do teto sai.
fn finish(cache: *images.Cache, store: *const Store) bool {
    const j = job orelse return false;
    defer freeJob();
    const r = result;
    var pb: [600]u8 = undefined;
    const written = if (r.ok) std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ j.dir, r.file.slice() }, 0) catch null else null;
    // Outra conta, ou "Apagar cache" no meio: não vale mais.
    if (j.gen != gen or !usable()) {
        if (written) |w| _ = c.unlink(w.ptr);
        return false;
    }
    if (!r.ok) {
        mark(&failed, j.url);
        return false;
    }
    // Deixou de ser favorito enquanto era feito.
    const favs = &store.gif_favorites;
    if (favs.state == .ready and !favs.has(j.url)) {
        if (written) |w| _ = c.unlink(w.ptr);
        return false;
    }
    addTotal(@intCast(r.size));
    const old = index.setClip(alloc, j.url, j.src, r.file, r.size, nowMs()) catch {
        if (written) |w| if (c.unlink(w.ptr) == 0) addTotal(-@as(i64, @intCast(r.size)));
        return false;
    };
    if (old) |f| deleteFile(f, cache);
    // A textura de um arquivo de antes com o mesmo nome (o clipe refeito).
    var ub: [700]u8 = undefined;
    if (fileUrl(&ub, r.file.slice())) |u| cache.forget(u);
    made += 1;
    enforceCap(cache, index.find(j.url));
    rebuildListed();
    dirty = true;
    save();
    return true;
}

/// Passou do teto: saem os clipes mostrados há mais tempo, nunca `keep` (o que acabou de
/// entrar). A entrada fica: continua favorito, só sem clipe.
fn enforceCap(cache: ?*images.Cache, keep: ?usize) void {
    while (index.victim(cap_bytes, keep)) |i| {
        deleteFile(index.dropClip(i, true), cache);
        evictions += 1;
        dirty = true;
    }
}

/// O QA mudou o teto: aplica já.
pub fn enforceNow(cache: *images.Cache) void {
    if (!usable()) return;
    enforceCap(cache, null);
    save();
}

// --- Configurações → Privacidade -----------------------------------------------------------

/// Quanto a pasta ocupa no disco (todas as contas).
pub fn totalBytes() u64 {
    if (sys.web or root_len == 0) return 0;
    if (!total_known) {
        total_all = walkRoot(false);
        total_known = true;
    }
    return total_all;
}

/// Clipes da conta atual e quanto eles ocupam.
pub fn stats() struct { clips: usize, bytes: u64 } {
    if (!usable()) return .{ .clips = 0, .bytes = 0 };
    return .{ .clips = index.clips(), .bytes = index.total };
}

/// "Apagar cache": a pasta de todas as contas sai do disco. Na memória a lista continua (a
/// ordem dos favoritos desta sessão), sem nenhum clipe; nada é gravado de novo até o
/// seletor precisar de um clipe (se puder baixar).
pub fn clearAll(cache: *images.Cache) void {
    if (sys.web or root_len == 0) return;
    for (index.items.items, 0..) |*e, i| if (e.hasClip()) {
        var ub: [700]u8 = undefined;
        if (fileUrl(&ub, e.file.slice())) |u| cache.forget(u);
        _ = index.dropClip(i, false);
    } else {
        e.evicted = false;
    };
    gen +%= 1;
    clearQueue();
    clearSet(&failed);
    clearSet(&remade);
    _ = walkRoot(true);
    dirty = false;
    dirs_ok = false;
    total_all = 0;
    total_known = true;
}

/// Passa pelas pastas das contas: soma o tamanho dos arquivos ou (`remove`) apaga tudo.
fn walkRoot(remove: bool) u64 {
    var rbuf: [512]u8 = undefined;
    const r = std.fmt.bufPrintSentinel(&rbuf, "{s}", .{root()}, 0) catch return 0;
    const top = c.opendir(r.ptr) orelse return 0;
    var names: std.ArrayList([:0]u8) = .empty;
    defer {
        for (names.items) |nm| alloc.free(nm);
        names.deinit(alloc);
    }
    while (c.readdir(top)) |ent| {
        const sub = std.mem.sliceTo(&ent.*.d_name, 0);
        if (sub.len == 0 or sub[0] == '.') continue;
        const p = std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ root(), sub }, 0) catch continue;
        names.append(alloc, p) catch alloc.free(p);
    }
    _ = c.closedir(top);
    var sum: u64 = 0;
    for (names.items) |p| sum += if (remove) removeDir(p) else dirBytes(p);
    if (remove) _ = c.rmdir(r.ptr);
    return sum;
}

fn dirBytes(path: [:0]const u8) u64 {
    const dir = c.opendir(path.ptr) orelse return 0;
    defer _ = c.closedir(dir);
    var sum: u64 = 0;
    while (c.readdir(dir)) |fe| {
        const name = std.mem.sliceTo(&fe.*.d_name, 0);
        if (name.len == 0 or name[0] == '.') continue;
        var fb: [600]u8 = undefined;
        const fp = std.fmt.bufPrintSentinel(&fb, "{s}/{s}", .{ path, name }, 0) catch continue;
        sum += sys.fileSize(fp.ptr) orelse 0;
    }
    return sum;
}

/// Apaga a pasta de uma conta (só os arquivos que são nossos). Os bytes que saíram.
fn removeDir(path: [:0]const u8) u64 {
    const dir = c.opendir(path.ptr) orelse return 0;
    var freed: u64 = 0;
    while (c.readdir(dir)) |fe| {
        const name = std.mem.sliceTo(&fe.*.d_name, 0);
        const ours = clipe.File.parse(name) != null or std.mem.eql(u8, name, index_name) or std.mem.endsWith(u8, name, ".tmp");
        if (!ours) continue;
        var fb: [600]u8 = undefined;
        const fp = std.fmt.bufPrintSentinel(&fb, "{s}/{s}", .{ path, name }, 0) catch continue;
        const size = sys.fileSize(fp.ptr) orelse 0;
        if (c.unlink(fp.ptr) == 0) freed += size;
    }
    _ = c.closedir(dir);
    _ = c.rmdir(path.ptr);
    return freed;
}

/// Ao fechar o app (antes das imagens, que encerram o libcurl): espera o clipe que estava
/// sendo feito parar e grava a lista.
pub fn deinit() void {
    if (thread) |t| {
        stopping.store(true, .release);
        c.SDL_WaitThread(t, null);
        thread = null;
    }
    freeJob();
    save();
    clearQueue();
    queue.deinit(alloc);
    clearAndFree(&failed);
    clearAndFree(&remade);
    index.deinit(alloc);
    listed.deinit(alloc);
}

// --- Para o QA --------------------------------------------------------------------------

/// O caminho do clipe de `url` (null = sem clipe).
pub fn clipPath(buf: []u8, url: []const u8) ?[:0]const u8 {
    if (!usable()) return null;
    const i = index.find(url) orelse return null;
    const e = &index.items.items[i];
    if (!e.hasClip()) return null;
    return filePath(buf, e.file.slice());
}

/// A pasta da conta atual.
pub fn accountDir(buf: []u8) ?[:0]const u8 {
    if (!usable()) return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ root(), account() }, 0) catch null;
}

/// O que a lista sabe de `url`.
pub fn entry(url: []const u8) ?clipe.Entry {
    if (!usable()) return null;
    const i = index.find(url) orelse return null;
    return index.items.items[i];
}

/// Algo na fila ou sendo feito.
pub fn busy() bool {
    return thread != null or queue.items.len > 0;
}

/// Marca `url` como mostrado em `when` (o QA monta a ordem do teto).
pub fn touchAt(url: []const u8, when: i64) void {
    const i = index.find(url) orelse return;
    index.touch(i, when);
    dirty = true;
}

// --- A thread que faz o clipe ---------------------------------------------------------------

fn work(_: ?*anyopaque) callconv(.c) c_int {
    // Clipe nunca disputa a CPU com a interface.
    _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_LOW);
    const n = running.fetchAdd(1, .acq_rel) + 1;
    _ = max_running.fetchMax(n, .acq_rel);
    result = make(&job.?);
    _ = running.fetchSub(1, .acq_rel);
    done.store(true, .release);
    platform.Window.wake(wake_type, .media);
    return 0;
}

/// Um quadro que entrou no clipe: os pixels já no tamanho dele e onde começa (ms).
const Kept = struct { px: []u8, at: u32 };

/// Os quadros que entram no clipe, já reduzidos (no máximo 90: 15 por segundo, 6 s).
const Frames = struct {
    side: u16,
    sel: clipe.Selector = .{},
    list: std.ArrayList(Kept) = .empty,
    w: usize = 0,
    h: usize = 0,

    fn deinit(f: *Frames) void {
        for (f.list.items) |k| alloc.free(k.px);
        f.list.deinit(alloc);
    }

    /// Mais um quadro do original (RGBA sw×sh, de `ms`). false = parar.
    fn add(f: *Frames, rgba: []const u8, sw: usize, sh: usize, ms: u32) bool {
        const at = switch (f.sel.feed(ms)) {
            .keep => |t| t,
            .skip => return true,
            .stop => return false,
        };
        if (stopping.load(.acquire)) return false;
        // Todos do tamanho do primeiro: o WebP animado tem uma tela só.
        if (f.list.items.len == 0) {
            const dims = clipe.clipSize(sw, sh, f.side);
            if (dims[0] == 0) return false;
            f.w = dims[0];
            f.h = dims[1];
        }
        if (rgba.len < sw * sh * 4) return false;
        const out = alloc.alloc(u8, f.w * f.h * 4) catch return false;
        if (sw == f.w and sh == f.h) @memcpy(out, rgba[0..out.len]) else images.resize(rgba[0 .. sw * sh * 4], sw, sh, out, f.w, f.h);
        f.list.append(alloc, .{ .px = out, .at = at }) catch {
            alloc.free(out);
            return false;
        };
        return true;
    }

    fn tapFrame(ctx: *anyopaque, rgba: []const u8, sw: usize, sh: usize, ms: u32) bool {
        const f: *Frames = @ptrCast(@alignCast(ctx));
        return f.add(rgba, sw, sh, ms);
    }
};

/// Baixa (ou pega o que as imagens acabaram de baixar), decodifica, escolhe os quadros,
/// codifica e grava. Sem a interface: só esta thread.
fn make(j: *const Job) Result {
    if (sys.web) return .{} else return makeClip(j);
}

fn makeClip(j: *const Job) Result {
    var frames: Frames = .{ .side = j.side };
    defer frames.deinit();
    if (std.mem.startsWith(u8, j.src, "demo:")) {
        // A demonstração gera os quadros (nada vem da rede).
        const px = images.demoFrames(j.src, j.side, &stopping);
        defer px.deinit();
        for (px.frames) |f| if (!frames.add(f.data, px.w, px.h, f.delay_ms)) break;
    } else {
        var curl: ?*c.CURL = null;
        defer if (curl) |h| c.curl_easy_cleanup(h);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(alloc);
        var allow_video = clipe.tenorVideo(j.src);
        if (!images.cachedSource(j.src, &bytes)) {
            bytes.clearRetainingCapacity();
            if (!images.downloadSource(&curl, j.src, j.side, &bytes, &stopping, &allow_video)) return .{};
        }
        if (clipe.keepOriginal(bytes.items)) return write(j, bytes.items, if (clipe.isGif(bytes.items)) ".gif" else ".webp");
        const tap: images.Tap = .{ .ctx = &frames, .frame = Frames.tapFrame };
        const px = images.decodeFrames(bytes.items, j.side, &stopping, allow_video, &tap);
        defer px.deinit();
        // Imagem parada: um quadro só (já reduzida).
        if (frames.list.items.len == 0) for (px.frames) |f| {
            if (!frames.add(f.data, px.w, px.h, f.delay_ms)) break;
        };
    }
    if (frames.list.items.len == 0 or stopping.load(.acquire)) return .{};
    const data = encodeBest(&frames) orelse return .{};
    defer alloc.free(data);
    return write(j, data, ".webp");
}

fn write(j: *const Job, data: []const u8, ext: []const u8) Result {
    if (stopping.load(.acquire)) return .{};
    const file = clipe.File.of(j.url, ext);
    var pb: [600]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ j.dir, file.slice() }, 0) catch return .{};
    // Num .tmp (600) e depois troca de nome; "Apagar todos os dados" fecha a porta.
    if (!fsutil.replacePrivate(p, data)) return .{};
    return .{ .ok = true, .file = file, .size = data.len };
}

/// Algumas passadas atrás da qualidade que deixa o clipe perto do tamanho alvo.
fn encodeBest(f: *const Frames) ?[]u8 {
    var s: clipe.Search = .{};
    var best: ?[]u8 = null;
    var best_q: ?f32 = null;
    var best_fits = false;
    while (!stopping.load(.acquire)) {
        const q = s.q;
        const data = encode(f, q) orelse break;
        const len = data.len;
        const fits = len <= clipe.size_target;
        if (clipe.prefer(q, fits, best_q, best_fits)) {
            if (best) |b| alloc.free(b);
            best = data;
            best_q = q;
            best_fits = fits;
        } else alloc.free(data);
        if (!s.feed(len)) break;
    }
    if (stopping.load(.acquire)) {
        if (best) |b| alloc.free(b);
        return null;
    }
    return best;
}

/// Um WebP animado com perda (libwebpmux) dos quadros guardados, na qualidade `quality`.
fn encode(f: *const Frames, quality: f32) ?[]u8 {
    var eo: c.WebPAnimEncoderOptions = undefined;
    if (c.WebPAnimEncoderOptionsInit(&eo) == 0) return null;
    eo.anim_params.loop_count = 0;
    // Sem procurar o menor arquivo quadro a quadro (lento): o tamanho vem da qualidade.
    eo.minimize_size = 0;
    eo.allow_mixed = 0;
    const enc = c.WebPAnimEncoderNew(@intCast(f.w), @intCast(f.h), &eo) orelse return null;
    defer c.WebPAnimEncoderDelete(enc);
    var cfg: c.WebPConfig = undefined;
    if (c.WebPConfigInit(&cfg) == 0) return null;
    cfg.lossless = 0;
    cfg.quality = quality;
    cfg.method = 4;
    if (c.WebPValidateConfig(&cfg) == 0) return null;
    for (f.list.items) |k| {
        if (stopping.load(.acquire)) return null;
        var pic: c.WebPPicture = undefined;
        if (c.WebPPictureInit(&pic) == 0) return null;
        pic.use_argb = 1;
        pic.width = @intCast(f.w);
        pic.height = @intCast(f.h);
        if (c.WebPPictureImportRGBA(&pic, k.px.ptr, @intCast(f.w * 4)) == 0) {
            c.WebPPictureFree(&pic);
            return null;
        }
        const ok = c.WebPAnimEncoderAdd(enc, &pic, @intCast(k.at), &cfg);
        c.WebPPictureFree(&pic);
        if (ok == 0) return null;
    }
    // O último quadro dura até o fim do clipe.
    if (c.WebPAnimEncoderAdd(enc, null, @intCast(f.sel.end()), null) == 0) return null;
    var out: c.WebPData = undefined;
    c.WebPDataInit(&out);
    if (c.WebPAnimEncoderAssemble(enc, &out) == 0) return null;
    defer c.WebPDataClear(&out);
    if (out.bytes == null or out.size == 0) return null;
    return alloc.dupe(u8, out.bytes[0..out.size]) catch null;
}
