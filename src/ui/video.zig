//! Vídeos tocando dentro do app (anexos e embeds), com o FFmpeg do sistema
//! (platform/ffmpeg.zig, carregado só no primeiro play). Sem FFmpeg, o play
//! abre o vídeo no navegador como antes.
//!
//! Uma thread baixa (pelo mesmo `fetch` das imagens: só domínios
//! permitidos, redirecionamentos conferidos, proxy) e outra decodifica para
//! um anel de 3 quadros RGBA enquanto o download anda; a interface só sobe
//! o quadro da vez para uma textura. Limites: 854×480, ~30 qps e 64 MB
//! baixados (fica tudo na memória para poder voltar). Som pelo SDL (f32).
//! Um vídeo de cada vez; fora da tela pausa e, 30 s depois, solta tudo.
//!
//! Tela cheia (o botão da barra, dois cliques ou F): o vídeo por cima do app
//! inteiro, com a janela em tela cheia do sistema, e o resto do app nem é
//! montado (ui/root.zig). O mesmo player continua (mesma posição, sem baixar de
//! novo); a decodificação sobe até o tamanho da tela (no máximo 1080p) e volta
//! ao da conversa na saída. A janela volta como estava: em janela, maximizada
//! ou, se já estava em tela cheia (F11), em tela cheia.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const ffmpeg = @import("../platform/ffmpeg.zig");
const images = @import("images.zig");
const platform = @import("../platform/window.zig");
const media_url = @import("../net/media_url.zig");
const S = @import("settings_state.zig");
const teclas = @import("teclas.zig");

const alloc = std.heap.c_allocator;

/// Teto do vídeo baixado (o Discord sem Nitro aceita até 10 MB).
pub const max_bytes: usize = 64 * 1024 * 1024;
const max_w: u32 = 854;
const max_h: u32 = 480;
/// Em tela cheia: até o tamanho da tela, no máximo 1080p (o anel fica com até 3
/// quadros de 8 MB, mais a textura; na saída volta ao tamanho da conversa).
pub const full_max_w: u32 = 1920;
pub const full_max_h: u32 = 1080;
/// ~30 quadros por segundo no máximo (os outros nem são convertidos).
const min_frame_ms: i64 = 33;
const ring_n = 3;
/// Pacotes de vídeo guardados enquanto o áudio precisa andar na frente.
const max_packets = 600;
const audio_ahead_ms: f64 = 1000;

/// Vídeo da demonstração (3 s, 426×240, 60 qps com som: testa o limite de
/// 30 qps e o áudio). Também vira o "GIF em MP4" da demonstração.
pub const demo_mp4 = @embedFile("demo_video.mp4");
pub const demo_link = "demo:video";

const Status = enum(u8) { opening, ready, failed };
const Fail = enum(u8) { none, download, too_big, format };

/// Um quadro do anel, com o tamanho dele: entrando e saindo da tela cheia, o
/// anel tem quadros dos dois tamanhos por alguns instantes.
const Slot = struct { px: []u8 = &.{}, pts_ms: i64 = 0, w: u32 = 0, h: u32 = 0 };

/// Estado dividido entre a interface e as duas threads (o que não diz
/// "só a thread X" fica sob o mutex). Quem soltar a última referência libera.
const Shared = struct {
    refs: std.atomic.Value(u32),
    stop: std.atomic.Value(bool) = .init(false),
    mutex: *c.SDL_Mutex,
    cond: *c.SDL_Condition,
    url: []u8,
    wake_type: u32,
    /// O tamanho máximo da saída, em pixels, já com o teto: o lugar na conversa (até
    /// 854×480) ou a tela cheia (até 1920×1080). Muda com o vídeo tocando; o
    /// decodificador segue a partir do próximo quadro.
    box_w: u32,
    box_h: u32,
    audio_on: bool,

    data: std.ArrayList(u8) = .empty,
    dl_done: bool = false,
    dl_failed: bool = false,
    too_big: bool = false,
    total: i64 = -1,
    /// Posição de leitura do FFmpeg (só a thread de decodificação).
    io_pos: usize = 0,

    status: Status = .opening,
    fail: Fail = .none,
    /// O tamanho do último quadro convertido, e o do vídeo (o QA confere a conta).
    w: u32 = 0,
    h: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
    duration_ms: i64 = 0,
    ring: [ring_n]Slot = @splat(.{}),
    head: usize = 0,
    len: usize = 0,
    /// O decodificador entregou o último quadro.
    eof: bool = false,
    seek_ms: i64 = -1,
    gen: u32 = 0,
    decoded: u32 = 0,

    audio: ?*c.SDL_AudioStream = null,
    audio_base_ms: i64 = 0,
    audio_pushed: u64 = 0,
    audio_bpms: f64 = 0,

    fn lock(sh: *Shared) void {
        c.SDL_LockMutex(sh.mutex);
    }
    fn unlock(sh: *Shared) void {
        c.SDL_UnlockMutex(sh.mutex);
    }
};

fn release(sh: *Shared) void {
    if (sh.refs.fetchSub(1, .acq_rel) != 1) return;
    if (sh.audio) |s| c.SDL_DestroyAudioStream(s);
    for (sh.ring) |s| if (s.px.len > 0) alloc.free(s.px);
    sh.data.deinit(alloc);
    alloc.free(sh.url);
    c.SDL_DestroyCondition(sh.cond);
    c.SDL_DestroyMutex(sh.mutex);
    alloc.destroy(sh);
}

/// Threads ainda rodando (o encerramento do app espera por elas).
var live: std.atomic.Value(u32) = .init(0);

// --- Interface -----------------------------------------------------------------

const Player = struct {
    sh: *Shared,
    key: u64,
    link: [1024]u8 = undefined,
    link_len: usize = 0,
    tex: ?*c.SDL_Texture = null,
    tex_w: u32 = 0,
    tex_h: u32 = 0,
    have_frame: bool = false,
    /// O tempo do quadro que está na tela (`dropTexture` e `refresh` voltam a ele).
    frame_pts: i64 = 0,
    /// O teto da saída no lugar da conversa (pixels, até 854×480): a tela cheia troca
    /// por um maior e, na saída, volta a este.
    box: [2]u32 = .{ max_w, max_h },
    /// Quando um clique no vídeo pausou ou continuou: o segundo clique de um duplo
    /// clique (a tela cheia) desfaz o do primeiro.
    click_ms: i64 = std.math.minInt(i64) / 2,
    pos_ms: f64 = 0,
    playing: bool = true,
    ended: bool = false,
    /// O ganho já passado para o som (-1: ainda nenhum).
    gain: f32 = -1,
    clock_ms: i64 = 0,
    drawn: bool = false,
    last_drawn_ms: i64 = 0,
    /// Quadros mostrados (o QA confere).
    shown: u32 = 0,
    audio_running: bool = false,
    status: Status = .opening,
    fail: Fail = .none,
    w: u32 = 0,
    h: u32 = 0,
    duration_ms: i64 = 0,
    has_audio: bool = false,
    next_due_ms: ?f64 = null,

    fn linkSlice(p: *const Player) []const u8 {
        return p.link[0..p.link_len];
    }
};

var cur: ?Player = null;
/// O volume antes de silenciar pelo botão.
var unmute_to: u8 = 0;
var vol_dragging = false;
/// Mudou pelas setas da tela cheia: grava quando a tecla soltar (não a cada repetição).
var vol_keys = false;
var audio_tried = false;
var audio_ok = false;
/// Vídeos abertos desde o começo (o QA confere que a tela cheia não abre outro).
var starts: u32 = 0;

/// A tela cheia do vídeo: ele por cima do app inteiro (ui/root.zig só desenha isto).
const Full = struct {
    /// Quando o mouse mexeu por último: tocando, os controles e o cursor somem
    /// `hide_ms` depois.
    moved_ms: i64,
    mouse: c.ImVec2,
    /// Acabou de abrir: a janela dela pega o foco (a caixa de texto solta o teclado).
    appearing: bool = true,
    /// Os controles estão à vista neste quadro (o QA confere).
    controls: bool = true,
    cursor_hidden: bool = false,
    pic: d.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};
var full: ?Full = null;
/// Sem mexer o mouse, tocando, os controles somem depois disto (o QA encurta).
pub var hide_ms: i64 = 2000;

/// A janela antes da tela cheia do vídeo, para voltar igual. Separado de `full`: quem
/// mexe na janela é o app, no fim do quadro (`janela`), e o sistema responde depois.
const Janela = struct {
    /// A janela está (ou está indo) para a tela cheia por causa do vídeo.
    ativa: bool = false,
    /// Já estava em tela cheia (F11): na saída, continua.
    was_fullscreen: bool = false,
    was_maximized: bool = false,
    /// O sistema já confirmou a tela cheia (sair dela depois disso, por fora, tira o vídeo).
    seen: bool = false,
    /// Saindo, até quando conferir se a maximizada voltou maximizada (0: nada a conferir).
    remax_until: i64 = 0,
};
var jan: Janela = .{};

/// O vídeo inteiro, se é o que está aberto e já terminou de baixar (salvar sem
/// baixar de novo). Só a thread da interface.
pub fn originalBytes(url: []const u8, out: *std.ArrayList(u8)) bool {
    const p = cur orelse return false;
    if (!std.mem.eql(u8, p.linkSlice(), url)) return false;
    const sh = p.sh;
    sh.lock();
    defer sh.unlock();
    if (!sh.dl_done or sh.data.items.len == 0) return false;
    out.appendSlice(alloc, sh.data.items) catch return false;
    return true;
}

/// O vídeo `key` está tocando (ou aberto) no lugar da prévia.
pub fn isActive(key: u64) bool {
    return if (cur) |p| p.key == key else false;
}

/// Dá para tocar aqui dentro? (Para a dica: antes do primeiro play não se
/// sabe se tem FFmpeg; aí a dica promete tocar e o play cai no navegador.)
pub fn canPlay(link: []const u8, size: u64) bool {
    return playable(link) and size <= max_bytes and ffmpeg.known() != false;
}

fn playable(link: []const u8) bool {
    if (std.mem.eql(u8, link, demo_link)) return true;
    if (std.mem.startsWith(u8, link, "file://")) return true;
    return media_url.allowedHost(link);
}

/// Chave de um anexo/embed (mensagem + posição).
pub fn keyOf(msg_id: u64, index: u64) u64 {
    return std.hash.Wyhash.hash(index, std.mem.asBytes(&msg_id));
}

/// O play de uma prévia: toca `link` aqui ou, sem FFmpeg (ou grande
/// demais), abre `page` no navegador.
pub fn click(ctx: *d.Ctx, key: u64, link: []const u8, page: []const u8, r: d.Rect, size: u64) void {
    if (isActive(key)) return;
    const ok = playable(link) and size <= max_bytes and ffmpeg.get() != null and start(ctx, key, link, page, r);
    if (ok) return;
    if (std.mem.startsWith(u8, page, "https://")) {
        @import("attachments.zig").openUrl(page);
        if (ffmpeg.known() == false) ctx.st.showToast(ctx.now_ms, false, "sem FFmpeg, abriu no navegador. Para tocar aqui: Configurações → Chat → Vídeos", "no FFmpeg, opened in the browser. To play here: Settings → Chat → Videos", .{});
    } else ctx.st.showToast(ctx.now_ms, false, "vídeo de demonstração (sem FFmpeg)", "demo video (no FFmpeg)", .{});
}

/// O som do SDL abriu (no QA, o driver mudo).
pub fn audioAvailable() bool {
    return audio_ok;
}

fn ensureAudio() bool {
    if (audio_tried) return audio_ok;
    audio_tried = true;
    // No QA o som vai para o driver mudo (testa o caminho sem fazer barulho).
    if (qa.on()) @import("../net/voz_audio.zig").force_dummy = true;
    // Pelo mesmo caminho da voz: duas threads não podem iniciar o áudio juntas.
    audio_ok = @import("../net/voz_audio.zig").acquire();
    return audio_ok;
}

fn start(ctx: *d.Ctx, key: u64, link: []const u8, page: []const u8, r: d.Rect) bool {
    stop();
    // Um som por vez: o áudio (ou a mensagem de voz) tocando pausa.
    @import("audio_player.zig").pausar();
    const scale = ctx.io.*.DisplayFramebufferScale.x;
    const mutex = c.SDL_CreateMutex() orelse return false;
    const cond = c.SDL_CreateCondition() orelse {
        c.SDL_DestroyMutex(mutex);
        return false;
    };
    const sh = alloc.create(Shared) catch {
        c.SDL_DestroyCondition(cond);
        c.SDL_DestroyMutex(mutex);
        return false;
    };
    // Cabe no retângulo da conversa e em 854×480.
    const box = [2]u32{ @min(max_w, pixels(@max(64, r.w * scale))), @min(max_h, pixels(@max(64, r.h * scale))) };
    sh.* = .{
        .refs = .init(1),
        .mutex = mutex,
        .cond = cond,
        .url = alloc.dupe(u8, link) catch "",
        .wake_type = ctx.images.wake_type,
        .box_w = box[0],
        .box_h = box[1],
        .audio_on = ensureAudio(),
    };
    if (sh.url.len == 0) {
        alloc.destroy(sh);
        c.SDL_DestroyCondition(cond);
        c.SDL_DestroyMutex(mutex);
        return false;
    }
    var source = link;
    // LARPER_DEMO_VIDEO=/caminho.mp4 troca o vídeo da demonstração (testes).
    if (std.mem.eql(u8, link, demo_link)) if (c.SDL_getenv("LARPER_DEMO_VIDEO")) |p| {
        var fb: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&fb, "file://{s}", .{std.mem.span(p)})) |f| {
            if (alloc.dupe(u8, f)) |owned| {
                alloc.free(sh.url);
                sh.url = owned;
                source = owned;
            } else |_| {}
        } else |_| {}
    };
    if (std.mem.eql(u8, source, demo_link)) {
        sh.data.appendSlice(alloc, demo_mp4) catch {};
        sh.dl_done = true;
    } else if (!spawn(sh, downloadMain, "video-dl")) {
        release(sh);
        return false;
    }
    if (!spawn(sh, decodeMain, "video")) {
        sh.stop.store(true, .release);
        c.SDL_BroadcastCondition(sh.cond);
        release(sh);
        return false;
    }
    // `drawn`: o clique vem no meio do desenho; não pausa no fim deste quadro.
    var p: Player = .{ .sh = sh, .key = key, .clock_ms = ctx.now_ms, .last_drawn_ms = ctx.now_ms, .drawn = true, .box = box };
    // O que o "Abrir no navegador" abre se não der para tocar.
    p.link_len = @min(page.len, p.link.len);
    @memcpy(p.link[0..p.link_len], page[0..p.link_len]);
    cur = p;
    starts +%= 1;
    return true;
}

/// Pixels inteiros de um tamanho da tela (nunca negativo, nunca absurdo).
fn pixels(x: f32) u32 {
    return @intFromFloat(std.math.clamp(@round(x), 0, 16384));
}

/// O tamanho da saída para um quadro `src` que cabe em `box_w`×`box_h`, sem
/// aumentar e sem distorcer (lados pares não são exigidos: o swscale aceita).
pub fn fitSize(src_w: u32, src_h: u32, box_w: u32, box_h: u32) [2]u32 {
    const sw: f64 = @floatFromInt(src_w);
    const sh: f64 = @floatFromInt(src_h);
    const k = @min(1.0, @min(@as(f64, @floatFromInt(@max(box_w, 2))) / sw, @as(f64, @floatFromInt(@max(box_h, 2))) / sh));
    return .{ @max(2, @as(u32, @intFromFloat(@round(sw * k)))), @max(2, @as(u32, @intFromFloat(@round(sh * k)))) };
}

/// Troca o teto da saída (entrando ou saindo da tela cheia). Tocando, o anel se
/// renova sozinho em ~3 quadros; pausado (ou no fim) ele está cheio e parado, então o
/// quadro da tela é decodificado de novo no tamanho novo, sem sair da tela até lá.
fn setBox(p: *Player, box: [2]u32) void {
    const sh = p.sh;
    sh.lock();
    const same = sh.box_w == box[0] and sh.box_h == box[1];
    sh.box_w = box[0];
    sh.box_h = box[1];
    sh.unlock();
    if (same) return;
    c.SDL_BroadcastCondition(sh.cond);
    if (p.have_frame and (!p.playing or p.ended)) refresh(p);
}

/// O quadro da tela de novo (no tamanho novo): um pulo até ele que não tira a imagem
/// da tela nem mexe no relógio. Só pausado, onde o som também está parado.
fn refresh(p: *Player) void {
    const sh = p.sh;
    sh.lock();
    sh.seek_ms = @max(0, p.frame_pts);
    sh.gen +%= 1;
    sh.len = 0;
    sh.eof = false;
    sh.unlock();
    c.SDL_BroadcastCondition(sh.cond);
}

fn spawn(sh: *Shared, f: c.SDL_ThreadFunction, name: [*:0]const u8) bool {
    _ = sh.refs.fetchAdd(1, .acq_rel);
    _ = live.fetchAdd(1, .acq_rel);
    const t = c.SDL_CreateThread(f, name, sh) orelse {
        _ = sh.refs.fetchSub(1, .acq_rel);
        _ = live.fetchSub(1, .acq_rel);
        return false;
    };
    c.SDL_DetachThread(t);
    return true;
}

/// Para e solta o vídeo atual (as threads terminam sozinhas).
pub fn stop() void {
    var p = cur orelse return;
    cur = null;
    if (p.tex) |t| c.SDL_DestroyTexture(t);
    const sh = p.sh;
    sh.lock();
    if (sh.audio) |s| _ = c.SDL_PauseAudioStreamDevice(s);
    sh.unlock();
    sh.stop.store(true, .release);
    c.SDL_BroadcastCondition(sh.cond);
    release(sh);
    p.tex = null;
}

/// Fim do app: para e espera as threads (no máximo 3 s).
pub fn shutdown() void {
    stop();
    var waited: u32 = 0;
    while (live.load(.acquire) > 0 and waited < 3000) : (waited += 5) c.SDL_Delay(5);
}

/// A textura recebeu um quadro de vídeo: o desenho é o mesmo, mas a imagem mudou.
var texture_changed = false;

pub fn takeChanged() bool {
    defer texture_changed = false;
    return texture_changed;
}

/// Uma vez por quadro, depois de desenhar: o vídeo que não apareceu neste
/// quadro (rolou para fora, trocou de canal) pausa; 30 s fora, é solto
/// (download, quadros e textura). O app pode estar dormindo: pede um quadro
/// para essa hora, senão a memória só voltaria no próximo evento.
pub fn endFrame(now_ms: i64) void {
    const p = if (cur) |*pp| pp else return;
    if (!p.drawn) {
        if (p.playing) setPlaying(p, false);
        if (now_ms - p.last_drawn_ms > 30_000) stop() else anim.at(p.last_drawn_ms + 30_001);
        return;
    }
    p.drawn = false;
}

/// Para o QA: o que mudou no player (entra na impressão digital da varredura).
pub fn qaState() u64 {
    const p = cur orelse return 0;
    return p.key ^ (@as(u64, @intFromBool(p.playing)) << 1) ^ (@as(u64, @intFromBool(p.gain == 0)) << 2) ^ (@as(u64, @intFromBool(full != null)) << 3);
}

pub const Info = struct {
    active: bool = false,
    playing: bool = false,
    ended: bool = false,
    failed: bool = false,
    ready: bool = false,
    /// O tamanho do último quadro convertido, o do vídeo, o teto pedido e o da textura.
    w: u32 = 0,
    h: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
    box_w: u32 = 0,
    box_h: u32 = 0,
    tex_w: u32 = 0,
    tex_h: u32 = 0,
    /// Bytes dos quadros do anel (a memória que a tela cheia aumenta).
    ring_bytes: usize = 0,
    pos_ms: f64 = 0,
    duration_ms: i64 = 0,
    shown: u32 = 0,
    decoded: u32 = 0,
    has_audio: bool = false,
    muted: bool = false,
    gain: f32 = -1,
    audio_queued: i32 = 0,
    drawn_ms: i64 = 0,
    /// Vídeos abertos desde o começo do app.
    starts: u32 = 0,
    /// Tela cheia: aberta, com os controles e o cursor à vista, e onde a imagem ficou.
    full: bool = false,
    controls: bool = false,
    cursor_hidden: bool = false,
    pic: d.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// A janela está em tela cheia por causa do vídeo (a ação já passou pelo app).
    window_full: bool = false,
};

pub fn info() Info {
    const p = cur orelse return .{ .starts = starts, .full = full != null, .window_full = jan.ativa };
    const sh = p.sh;
    sh.lock();
    defer sh.unlock();
    var ring_bytes: usize = 0;
    for (sh.ring) |s| ring_bytes += s.px.len;
    return .{
        .active = true,
        .playing = p.playing,
        .ended = p.ended,
        .failed = p.status == .failed,
        .ready = p.status == .ready,
        .w = sh.w,
        .h = sh.h,
        .src_w = sh.src_w,
        .src_h = sh.src_h,
        .box_w = sh.box_w,
        .box_h = sh.box_h,
        .tex_w = p.tex_w,
        .tex_h = p.tex_h,
        .ring_bytes = ring_bytes,
        .starts = starts,
        .full = full != null,
        .controls = if (full) |f| f.controls else false,
        .cursor_hidden = if (full) |f| f.cursor_hidden else false,
        .pic = if (full) |f| f.pic else .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .window_full = jan.ativa,
        .pos_ms = p.pos_ms,
        .duration_ms = p.duration_ms,
        .shown = p.shown,
        .decoded = sh.decoded,
        .has_audio = sh.audio != null,
        .muted = p.gain == 0,
        // O que o SDL está aplicando de fato, não o que pedimos.
        .gain = if (sh.audio) |s| c.SDL_GetAudioStreamGain(s) else -1,
        .audio_queued = if (sh.audio) |s| c.SDL_GetAudioStreamQueued(s) else 0,
        .drawn_ms = p.last_drawn_ms,
    };
}

fn setPlaying(p: *Player, on: bool) void {
    if (on and p.ended) {
        seek(p, 0);
        p.ended = false;
    }
    p.playing = on;
    syncAudio(p);
}

/// A janela foi para a bandeja: pausa, sem fechar o vídeo.
pub fn pause() void {
    const p = if (cur) |*pp| pp else return;
    if (p.playing) setPlaying(p, false);
}

/// O renderizador vai embora (a janela na bandeja, App.releaseGpu): a textura sai.
/// Pausado, o vídeo fica onde estava: o quadro da tela é decodificado de novo e sobe
/// para a textura nova quando ele voltar a aparecer. O que já tinha acabado também fica
/// (no último quadro, acabado, e o play recomeça do começo como antes), sem baixar de
/// novo: antes ele era fechado aqui, e o play na volta não achava mais o player.
pub fn dropTexture() void {
    const p = if (cur) |*pp| pp else return;
    if (p.tex) |t| c.SDL_DestroyTexture(t);
    p.tex = null;
    p.tex_w = 0;
    p.tex_h = 0;
    if (p.have_frame) seek(p, p.frame_pts);
}

fn seek(p: *Player, ms: i64) void {
    const sh = p.sh;
    sh.lock();
    sh.seek_ms = @max(0, ms);
    sh.gen +%= 1;
    sh.len = 0;
    sh.eof = false;
    sh.unlock();
    c.SDL_BroadcastCondition(sh.cond);
    p.pos_ms = @floatFromInt(@max(0, ms));
    p.have_frame = false;
    p.ended = false;
    syncAudio(p);
}

/// Som andando só quando a imagem anda.
fn syncAudio(p: *Player) void {
    const s = p.sh.audio orelse return;
    const want = p.playing and p.have_frame and !p.ended;
    if (want == p.audio_running) return;
    p.audio_running = want;
    _ = if (want) c.SDL_ResumeAudioStreamDevice(s) else c.SDL_PauseAudioStreamDevice(s);
}

/// O slider vale na hora, mesmo no meio do que já está na fila do som.
fn applyVolume(p: *Player, volume: u8) void {
    const s = p.sh.audio orelse return;
    const gain = S.videoGain(volume);
    if (gain != p.gain and c.SDL_SetAudioStreamGain(s, gain)) p.gain = gain;
}

fn saveVolume(ctx: *d.Ctx) void {
    ctx.act(.{ .set_setting = .{ .index = S.fieldIndex("video_volume"), .value = ctx.st.settings.video_volume } });
}

/// Avança o relógio e sobe o quadro da vez.
fn update(p: *Player, renderer: ?*c.SDL_Renderer, now_ms: i64) void {
    const sh = p.sh;
    const dt: f64 = @floatFromInt(std.math.clamp(now_ms - p.clock_ms, 0, 250));
    p.clock_ms = now_ms;
    sh.lock();
    defer sh.unlock();
    p.status = sh.status;
    p.fail = sh.fail;
    if (sh.duration_ms > 0) p.duration_ms = sh.duration_ms;
    p.has_audio = sh.audio != null;
    const stalled = sh.len == 0 and !sh.eof;
    if (p.playing and p.have_frame and !stalled and !p.ended) {
        p.pos_ms += dt;
        // O som manda no relógio (o dispositivo de áudio não anda exatamente
        // no ritmo do relógio do sistema).
        if (sh.audio) |s| if (sh.audio_bpms > 0) {
            const queued = c.SDL_GetAudioStreamQueued(s);
            if (queued > 0) {
                const played: f64 = @as(f64, @floatFromInt(sh.audio_pushed)) - @as(f64, @floatFromInt(queued));
                const apos = @as(f64, @floatFromInt(sh.audio_base_ms)) + played / sh.audio_bpms;
                if (@abs(apos - p.pos_ms) > 80) p.pos_ms = apos;
            }
        };
    }
    // Quadros vencidos: só o último sobe para a textura.
    var due: usize = 0;
    while (due < sh.len) : (due += 1) {
        const s = &sh.ring[(sh.head + due) % ring_n];
        if (!p.have_frame and due == 0) {
            p.pos_ms = @floatFromInt(s.pts_ms);
            p.have_frame = true;
            continue;
        }
        if (@as(f64, @floatFromInt(s.pts_ms)) > p.pos_ms + 2) break;
    }
    if (due > 0) {
        const s = &sh.ring[(sh.head + due - 1) % ring_n];
        // A textura acompanha o tamanho do quadro (a tela cheia entrando ou saindo):
        // a velha fica na tela até aqui, sem piscar.
        if (p.tex == null or p.tex_w != s.w or p.tex_h != s.h) {
            if (p.tex) |t| c.SDL_DestroyTexture(t);
            p.tex = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STREAMING, @intCast(s.w), @intCast(s.h));
            if (p.tex) |t| _ = c.SDL_SetTextureScaleMode(t, c.SDL_SCALEMODE_LINEAR);
            p.tex_w = if (p.tex != null) s.w else 0;
            p.tex_h = if (p.tex != null) s.h else 0;
        }
        if (p.tex) |t| _ = c.SDL_UpdateTexture(t, null, s.px.ptr, @intCast(s.w * 4));
        p.w = s.w;
        p.h = s.h;
        p.frame_pts = s.pts_ms;
        texture_changed = true;
        sh.head = (sh.head + due) % ring_n;
        sh.len -= due;
        p.shown += 1;
        c.SDL_BroadcastCondition(sh.cond);
    }
    p.next_due_ms = if (sh.len > 0) @as(f64, @floatFromInt(sh.ring[sh.head].pts_ms)) - p.pos_ms else null;
    // Um pulo para depois do último quadro (a ponta da barra, → na tela cheia): o fim
    // chega sem quadro novo, e fica na tela o que já estava na textura.
    if (sh.eof and sh.len == 0 and sh.seek_ms < 0 and !p.have_frame and p.tex != null and sh.decoded > 0) p.have_frame = true;
    if (sh.eof and sh.len == 0 and p.have_frame and !p.ended) {
        // Acabou: fica no último quadro, com o play para recomeçar.
        if (p.duration_ms <= 0) p.duration_ms = @intFromFloat(p.pos_ms);
        p.pos_ms = @floatFromInt(p.duration_ms);
        p.ended = true;
        p.playing = false;
    }
    if (p.duration_ms > 0) p.pos_ms = @min(p.pos_ms, @as(f64, @floatFromInt(p.duration_ms)));
}

fn fmtTime(buf: []u8, ms: f64) []const u8 {
    const s: u64 = @intFromFloat(@max(0, ms) / 1000);
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "";
}

/// Desenha o vídeo `key` (ativo) em `r`. `preview` é a prévia parada,
/// mostrada até chegar o primeiro quadro.
pub fn draw(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, alpha: f32, msg_id: u64, preview: ?images.Tex) void {
    const p = if (cur) |*pp| pp else return;
    const radius: f32 = 8;
    if (full != null) {
        // Em tela cheia, por cima de tudo (`drawFull`): aqui fica só o lugar dele (na
        // janela flutuante, que continua desenhando a conversa).
        d.rect(dl, r, d.Rgba.black.alpha(alpha), radius);
        return;
    }
    p.drawn = true;
    p.last_drawn_ms = ctx.now_ms;
    update(p, ctx.images.renderer, ctx.now_ms);
    // Antes de soltar o som: o primeiro instante já sai no volume certo.
    applyVolume(p, ctx.st.settings.video_volume);
    syncAudio(p);
    // O volume mudado pelas setas da tela cheia, que saiu por fora (bandeja, sistema).
    if (vol_keys) {
        vol_keys = false;
        saveVolume(ctx);
    }
    const ids: usize = @truncate(p.key);
    const hovered = ctx.hovering(r);

    d.rect(dl, r, d.Rgba.black.alpha(alpha), radius);
    _ = picture(ctx, dl, p, r, alpha, radius, preview, 1);
    const failed = p.status == .failed;
    if (failed and failure(ctx, dl, p, r, alpha, ids)) return;

    // Fechar (volta à prévia).
    const xr: d.Rect = .{ .x = r.right() - 32, .y = r.y + 6, .w = 26, .h = 26 };
    const xh = d.hit(ctx, ids +% 1, xr);
    qa.mark(xr, "video-close", .{});
    if (hovered or failed or !p.playing) {
        d.circle(dl, xr.x + 13, xr.y + 13, 12, d.Rgba.black.alpha((if (xh.hovered) @as(f32, 0.8) else 0.55) * alpha));
        d.line(dl, xr.x + 8.5, xr.y + 8.5, xr.x + 17.5, xr.y + 17.5, d.Rgba.white.alpha(alpha), 1.6);
        d.line(dl, xr.x + 17.5, xr.y + 8.5, xr.x + 8.5, xr.y + 17.5, d.Rgba.white.alpha(alpha), 1.6);
    }
    if (xh.clicked) {
        stop();
        return;
    }

    // Barra de controles: com o mouse em cima, pausado ou no fim.
    const show_bar = !failed and (hovered or !p.playing or p.ended or vol_dragging);
    const bar: d.Rect = .{ .x = r.x, .y = r.bottom() - 36, .w = r.w, .h = 36 };
    if (show_bar) {
        const top = d.Rgba.black.col(0);
        c.ImDrawList_AddRectFilledMultiColor(dl, d.v(bar.x, bar.y - 14), d.v(bar.right(), bar.y), top, top, d.Rgba.black.col(0.35 * alpha), d.Rgba.black.col(0.35 * alpha));
        d.rectFlags(dl, bar, d.Rgba.black.alpha(0.35 * alpha), radius, c.ImDrawFlags_RoundCornersBottom);
    }
    // Tela cheia: não na janela flutuante (a janela que iria para a tela cheia é a outra).
    const go_full = controls(ctx, dl, p, .{ .r = bar, .s = 1, .k = if (show_bar) alpha else 0, .ids = ids, .full_btn = !failed and !ctx.pip }, failed);

    // O resto do vídeo: clique pausa/continua; dois cliques, tela cheia; botão
    // direito, o menu.
    const area = d.hit(ctx, ids +% 5, r);
    qa.mark(r, "video", .{});
    if (area.clicked and !failed) clickToggle(ctx, p);
    const dbl = area.hovered and !failed and !ctx.pip and c.ImGui_IsMouseDoubleClicked(0);
    if (area.right and msg_id != 0) {
        // "Salvar…" no menu: o vídeo que está tocando (o link é o arquivo).
        const link = p.linkSlice();
        @import("exportar.zig").mediaMenu(ctx, msg_id, .{ .url = link, .name = @import("../core/salvar.zig").lastSegment(link) });
    }
    // F com o mouse em cima ou tocando (nenhum campo de texto com o foco).
    const key_f = !failed and !ctx.pip and (hovered or p.playing) and keysFree(ctx) and c.ImGui_IsKeyPressedEx(c.ImGuiKey_F, false);
    if (dbl) undoClick(ctx, p);
    if (go_full or key_f or dbl) enterFull(ctx);

    // Próximo redesenho: o próximo quadro (o decodificador acorda o app
    // quando o anel estava vazio).
    schedule(ctx, p);
}

/// O vídeo em tela cheia: ui/root.zig chama no lugar do app inteiro. A imagem cobre a
/// janela (faixas pretas onde sobrar), os controles ficam embaixo (tocando, somem com o
/// cursor depois de `hide_ms` sem mexer o mouse) e o teclado é dele: Esc, F, F11 ou dois
/// cliques saem, espaço toca ou pausa, ← → pulam 5 s, ↑ ↓ mudam o volume e M tira o som.
pub fn drawFull(ctx: *d.Ctx) void {
    const f = if (full) |*ff| ff else return;
    // O vídeo foi fechado por baixo (falhou e abriu no navegador, por exemplo).
    const p = if (cur) |*pp| pp else return leaveFull(ctx);
    const now = ctx.now_ms;
    const win = ctx.win;
    c.ImGui_SetNextWindowPos(d.v(win.x, win.y), 0);
    c.ImGui_SetNextWindowSize(d.v(win.w, win.h), 0);
    if (f.appearing) c.ImGui_SetNextWindowFocus();
    f.appearing = false;
    _ = c.ImGui_Begin("##video-tela-cheia", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse | c.ImGuiWindowFlags_NoNav);
    defer c.ImGui_End();
    // Na frente a cada quadro (o aviso de chamada, desenhado depois, vem por cima).
    d.windowToFront();
    const dl = c.ImGui_GetWindowDrawList();
    p.drawn = true;
    p.last_drawn_ms = now;
    // Decodifica até o tamanho da tela em pixels, no máximo 1080p (acompanha a janela
    // crescendo enquanto o sistema a põe em tela cheia).
    const scale = ctx.io.*.DisplayFramebufferScale.x;
    setBox(p, .{ @min(full_max_w, pixels(win.w * scale)), @min(full_max_h, pixels(win.h * scale)) });
    update(p, ctx.images.renderer, now);
    applyVolume(p, ctx.st.settings.video_volume);
    syncAudio(p);
    const failed = p.status == .failed;

    // O mouse mexeu, apertou ou rolou: os controles e o cursor voltam.
    const io = ctx.io;
    const moved = ctx.mouse.x != f.mouse.x or ctx.mouse.y != f.mouse.y or io.*.MouseWheel != 0 or
        c.ImGui_IsMouseDown(0) or c.ImGui_IsMouseDown(1) or c.ImGui_IsMouseDown(2);
    if (moved) {
        f.mouse = ctx.mouse;
        f.moved_ms = now;
    }

    d.rect(dl, win, d.Rgba.black, 0);
    qa.mark(win, "video-full", .{});
    f.pic = picture(ctx, dl, p, win, 1, 0, null, 1.6);
    qa.mark(f.pic, "video-picture", .{});
    const ids: usize = 0x5f00;
    if (failed and failure(ctx, dl, p, win, 1, ids)) return;

    const s: f32 = 1.35;
    const bar_h = 36 * s;
    const bar: d.Rect = .{ .x = win.x + 16, .y = win.bottom() - bar_h - 12, .w = win.w - 32, .h = bar_h };
    // Com o mouse em cima dos controles, eles ficam.
    const over_bar = ctx.mouse.y >= bar.y - 24 and win.contains(ctx.mouse.x, ctx.mouse.y);
    const idle = now - f.moved_ms >= hide_ms;
    const show = failed or !p.playing or p.ended or vol_dragging or over_bar or !idle;
    f.controls = show;
    // (Com "reduzir movimento", aparecem e somem sem esmaecer: anim.instant.)
    const k = anim.to(anim.id("video-full-bar", 0), if (show) 1 else 0, 12);
    // Tocando com o mouse parado: um quadro na hora de esconder (mesmo se o vídeo travar).
    if (show and !idle) anim.at(f.moved_ms + hide_ms + 1);
    if (k > 0.01) {
        // Um degradê de baixo para cima: os controles se leem sobre qualquer imagem.
        const gh = bar_h + 96;
        const top = d.Rgba.black.col(0);
        const bot = d.Rgba.black.col(0.65 * k);
        c.ImDrawList_AddRectFilledMultiColor(dl, d.v(win.x, win.bottom() - gh), d.v(win.right(), win.bottom()), top, top, bot, bot);
    }
    const toggle = controls(ctx, dl, p, .{ .r = bar, .s = s, .k = k, .ids = ids, .full_btn = true, .full = true }, failed);

    // O resto da tela: um clique pausa ou continua, dois saem.
    const area = d.hit(ctx, ids +% 5, win);
    if (area.clicked and !failed) clickToggle(ctx, p);
    const dbl = area.hovered and c.ImGui_IsMouseDoubleClicked(0);
    if (dbl) undoClick(ctx, p);
    var leave = toggle or dbl;

    if (!io.*.KeyCtrl and !io.*.KeyAlt and !io.*.KeySuper and !teclas.busy()) {
        if (c.ImGui_IsKeyPressedEx(c.ImGuiKey_Escape, false) or c.ImGui_IsKeyPressedEx(c.ImGuiKey_F, false)) leave = true;
        if (!failed) {
            var acted = false;
            if (c.ImGui_IsKeyPressedEx(c.ImGuiKey_Space, false)) {
                setPlaying(p, !p.playing);
                acted = true;
            }
            if (c.ImGui_IsKeyPressed(c.ImGuiKey_LeftArrow)) {
                skip(p, -5000);
                acted = true;
            }
            if (c.ImGui_IsKeyPressed(c.ImGuiKey_RightArrow)) {
                skip(p, 5000);
                acted = true;
            }
            if (c.ImGui_IsKeyPressed(c.ImGuiKey_UpArrow)) {
                volumeStep(ctx, p, 10);
                acted = true;
            }
            if (c.ImGui_IsKeyPressed(c.ImGuiKey_DownArrow)) {
                volumeStep(ctx, p, -10);
                acted = true;
            }
            if (c.ImGui_IsKeyPressedEx(c.ImGuiKey_M, false)) {
                toggleMute(ctx, p);
                acted = true;
            }
            // O que o teclado fez aparece nos controles por um instante.
            if (acted) f.moved_ms = now;
        }
    }
    // F11 / Alt+Enter (a tela cheia da janela, ou o que estiver em Atalhos de teclado).
    if (teclas.pressed(&ctx.st.teclas, ctx.io, .tela_cheia, false)) leave = true;
    // As setas soltas: o volume vai para as configurações uma vez só.
    if (vol_keys and !c.ImGui_IsKeyDown(c.ImGuiKey_UpArrow) and !c.ImGui_IsKeyDown(c.ImGuiKey_DownArrow)) {
        vol_keys = false;
        saveVolume(ctx);
    }

    // Controles escondidos: sem cursor. À vista, a seta sobre a imagem (a mãozinha é
    // dos botões).
    f.cursor_hidden = !show and k < 0.02;
    if (f.cursor_hidden) {
        c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_None);
    } else if (area.hovered) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Arrow);
    schedule(ctx, p);
    if (leave) leaveFull(ctx);
}

/// O vídeo está em tela cheia (ui/root.zig desenha só ele).
pub fn fullscreen() bool {
    return full != null;
}

fn enterFull(ctx: *d.Ctx) void {
    if (full != null or ctx.pip) return;
    full = .{ .moved_ms = ctx.now_ms, .mouse = ctx.mouse };
    vol_dragging = false;
    // A janela vai para a tela cheia do sistema no fim do quadro (o app, `janela`).
    ctx.act(.{ .video_tela_cheia = true });
}

fn leaveFull(ctx: *d.Ctx) void {
    if (full == null) return;
    endFull();
    if (vol_keys) {
        vol_keys = false;
        saveVolume(ctx);
    }
    ctx.act(.{ .video_tela_cheia = false });
}

/// O vídeo volta para a conversa, no tamanho dela (a janela é com quem chama).
fn endFull() void {
    full = null;
    vol_dragging = false;
    if (cur) |*p| setBox(p, p.box);
}

/// A janela da tela cheia do vídeo; o app chama ao tratar `.video_tela_cheia`, no fim
/// do quadro. Entrando, guarda como a janela estava e a põe em tela cheia; saindo, ela
/// volta como estava: em janela, maximizada ou, se já estava em tela cheia (F11),
/// continua nela.
pub fn janela(window: ?*c.SDL_Window, on: bool, now_ms: i64) void {
    const w = window orelse return;
    if (on) {
        // Já saiu antes de a ação chegar, ou já está: nada a fazer.
        if (full == null or jan.ativa) return;
        const f = c.SDL_GetWindowFlags(w);
        const was = f & c.SDL_WINDOW_FULLSCREEN != 0;
        jan = .{ .ativa = true, .was_fullscreen = was, .was_maximized = f & c.SDL_WINDOW_MAXIMIZED != 0, .seen = was };
        if (!was) _ = c.SDL_SetWindowFullscreen(w, true);
        return;
    }
    if (jan.ativa) restore(w, now_ms);
}

fn restore(w: *c.SDL_Window, now_ms: i64) void {
    jan.ativa = false;
    if (jan.was_fullscreen) return;
    _ = c.SDL_SetWindowFullscreen(w, false);
    // Maximizada antes: o SDL e o sistema costumam devolver assim; se não, `janelaTick`.
    if (jan.was_maximized) jan.remax_until = now_ms + 2000;
}

/// A janela entrou ou saiu da tela cheia (os eventos do SDL). Saindo por fora com o
/// vídeo nela (um atalho do sistema, o gerenciador de janelas), o vídeo sai junto.
pub fn janelaEvento(fullscreen_now: bool) void {
    if (!jan.ativa) return;
    if (fullscreen_now) {
        jan.seen = true;
        return;
    }
    if (!jan.seen) return;
    jan.ativa = false;
    endFull();
}

/// Uma vez por volta do laço do app: a tela cheia da janela confere com a do vídeo
/// (nem todo sistema avisa com o evento), e a janela que estava maximizada antes volta
/// maximizada (a garantia, para o sistema que não devolver assim).
pub fn janelaTick(window: ?*c.SDL_Window, now_ms: i64) void {
    if (!jan.ativa and jan.remax_until == 0) return;
    const w = window orelse {
        jan.remax_until = 0;
        return;
    };
    const f = c.SDL_GetWindowFlags(w);
    if (jan.ativa) janelaEvento(f & c.SDL_WINDOW_FULLSCREEN != 0);
    if (jan.remax_until == 0) return;
    // Ainda saindo da tela cheia (o sistema responde depois).
    if (f & c.SDL_WINDOW_FULLSCREEN != 0 and now_ms < jan.remax_until) return;
    jan.remax_until = 0;
    if (f & (c.SDL_WINDOW_MAXIMIZED | c.SDL_WINDOW_FULLSCREEN) == 0) _ = c.SDL_MaximizeWindow(w);
}

/// A janela vai para a bandeja (e pode ir embora, App.releaseGpu): a tela cheia do
/// vídeo sai antes, e a janela volta ao que era já agora, para ser guardada assim e
/// voltar da bandeja fora da tela cheia.
pub fn antesDaBandeja(window: ?*c.SDL_Window) void {
    if (full != null) endFull();
    if (!jan.ativa) return;
    const w = window orelse {
        jan = .{};
        return;
    };
    restore(w, 0);
    // O sistema responde depois: espera por ele (a janela é guardada logo em seguida).
    _ = c.SDL_SyncWindow(w);
    if (jan.remax_until != 0) {
        jan.remax_until = 0;
        if (c.SDL_GetWindowFlags(w) & (c.SDL_WINDOW_MAXIMIZED | c.SDL_WINDOW_FULLSCREEN) == 0) {
            _ = c.SDL_MaximizeWindow(w);
            _ = c.SDL_SyncWindow(w);
        }
    }
}

/// O teclado é do vídeo? Nenhum campo de texto com o foco, nada aberto por cima, sem
/// Ctrl, Alt ou Super (os atalhos do app) e nenhum atalho sendo trocado.
fn keysFree(ctx: *const d.Ctx) bool {
    const io = ctx.io;
    const st = ctx.st;
    return !io.*.WantTextInput and !io.*.KeyCtrl and !io.*.KeyAlt and !io.*.KeySuper and
        st.popup == .none and !st.palette.open and !st.settings.open and st.viewer == null and
        !@import("search.zig").open and !@import("interact.zig").anyOpen() and !teclas.busy();
}

fn clickToggle(ctx: *d.Ctx, p: *Player) void {
    setPlaying(p, !p.playing);
    p.click_ms = ctx.now_ms;
}

/// O segundo clique de um duplo clique: o primeiro tinha pausado (ou continuado), e o
/// duplo clique é só a tela cheia.
fn undoClick(ctx: *d.Ctx, p: *Player) void {
    const window_ms: i64 = @intFromFloat(ctx.io.*.MouseDoubleClickTime * 1000 + 50);
    if (ctx.now_ms - p.click_ms <= window_ms) setPlaying(p, !p.playing);
    p.click_ms = std.math.minInt(i64) / 2;
}

/// Pula `delta` ms a partir de onde está (as setas da tela cheia).
fn skip(p: *Player, delta: i64) void {
    if (p.duration_ms <= 0) return;
    seek(p, std.math.clamp(@as(i64, @intFromFloat(p.pos_ms)) + delta, 0, p.duration_ms));
}

fn volumeStep(ctx: *d.Ctx, p: *Player, delta: i32) void {
    const v = &ctx.st.settings.video_volume;
    v.* = @intCast(std.math.clamp(@as(i32, v.*) + delta, 0, 100));
    applyVolume(p, v.*);
    vol_keys = true;
}

fn toggleMute(ctx: *d.Ctx, p: *Player) void {
    const volume = &ctx.st.settings.video_volume;
    if (volume.* > 0) {
        unmute_to = volume.*;
        volume.* = 0;
    } else volume.* = if (unmute_to > 0) unmute_to else 100;
    applyVolume(p, volume.*);
    saveVolume(ctx);
}

fn schedule(ctx: *d.Ctx, p: *const Player) void {
    if (p.playing and !p.ended) {
        if (p.next_due_ms) |due| anim.at(ctx.now_ms + @as(i64, @intFromFloat(@max(1, @ceil(due))))) else anim.every(100);
    }
}

/// A imagem do vídeo em `r`, do tamanho que cabe sem distorcer (faixas pretas onde
/// sobrar), ou a prévia até o primeiro quadro, com a rodinha esperando (`s`: o
/// tamanho dela). Devolve onde a imagem ficou (sem quadro, um retângulo vazio no meio).
fn picture(ctx: *d.Ctx, dl: *c.ImDrawList, p: *const Player, r: d.Rect, alpha: f32, radius: f32, preview: ?images.Tex, s: f32) d.Rect {
    var out: d.Rect = .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2, .w = 0, .h = 0 };
    if (p.have_frame and p.tex != null and p.w > 0) {
        const vw: f32 = @floatFromInt(p.w);
        const vh: f32 = @floatFromInt(p.h);
        const k = @min(r.w / vw, r.h / vh);
        out = .{ .x = r.x + (r.w - vw * k) / 2, .y = r.y + (r.h - vh * k) / 2, .w = vw * k, .h = vh * k };
        const ref: c.ImTextureRef = .{ ._TexData = null, ._TexID = @intFromPtr(p.tex.?) };
        c.ImDrawList_AddImageRounded(dl, ref, d.v(out.x, out.y), d.v(out.right(), out.bottom()), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(alpha), radius, 0);
    } else if (preview) |t| {
        c.ImDrawList_AddImageRounded(dl, t.ref, d.v(r.x, r.y), d.v(r.right(), r.bottom()), d.v(0, 0), d.v(1, 1), d.Rgba.white.col(0.5 * alpha), radius, 0);
    }
    if (p.status != .failed and !p.have_frame) {
        const t = @as(f32, @floatFromInt(@mod(ctx.now_ms, 100_000))) / 1000.0;
        c.ImDrawList_PathArcTo(dl, d.v(r.x + r.w / 2, r.y + r.h / 2), 18 * s, t * 5, t * 5 + 4.2, 32);
        c.ImDrawList_PathStroke(dl, d.Rgba.white.col(0.8 * alpha), 2.5 * s, 0);
        anim.every(50);
    }
    return out;
}

/// O vídeo não tocou: diz por quê e, se veio da internet, oferece o navegador.
/// Devolve true se o clique no botão fechou o vídeo.
fn failure(ctx: *d.Ctx, dl: *c.ImDrawList, p: *const Player, r: d.Rect, alpha: f32, ids: usize) bool {
    const f = ctx.ui.get(.medium);
    const msg = switch (p.fail) {
        .too_big => i18n.tr("vídeo grande demais para tocar aqui", "video too large to play here"),
        .download => i18n.tr("não deu para baixar o vídeo", "couldn't download the video"),
        else => i18n.tr("não deu para tocar este vídeo", "couldn't play this video"),
    };
    d.text(dl, f, 13, r.x + (r.w - d.width(f, 13, msg)) / 2, r.y + r.h / 2 - 26, d.Rgba.white.alpha(0.85 * alpha), msg);
    const link = p.linkSlice();
    if (!std.mem.startsWith(u8, link, "https://")) return false;
    const label = i18n.tr("Abrir no navegador", "Open in Browser");
    const bw = d.width(f, 13, label) + 24;
    const br: d.Rect = .{ .x = r.x + (r.w - bw) / 2, .y = r.y + r.h / 2, .w = bw, .h = 30 };
    const hb = d.hit(ctx, ids +% 7, br);
    qa.mark(br, "video-browser", .{});
    d.rect(dl, br, d.Rgba.white.alpha((if (hb.hovered) @as(f32, 0.22) else 0.12) * alpha), 6);
    d.text(dl, f, 13, br.x + 12, d.centerY(br, 13), d.Rgba.white.alpha(alpha), label);
    if (!hb.clicked) return false;
    @import("attachments.zig").openUrl(link);
    stop();
    return true;
}

/// A faixa dos controles.
const Bar = struct {
    r: d.Rect,
    /// O tamanho dos controles: 1 na conversa, maior na tela cheia.
    s: f32,
    /// Opacidade (0: escondidos, mas ainda clicáveis, como sempre foram).
    k: f32,
    ids: usize,
    /// O botão de tela cheia (fora da janela flutuante e de um vídeo que falhou).
    full_btn: bool,
    /// Na tela cheia: o botão é o de sair.
    full: bool = false,
};

/// Play ou pausa, tempo, barra de progresso, volume, som e tela cheia, da esquerda
/// para a direita. Devolve true quando o botão de tela cheia foi clicado.
fn controls(ctx: *d.Ctx, dl: *c.ImDrawList, p: *Player, b: Bar, failed: bool) bool {
    const s = b.s;
    const bar = b.r;
    const alpha = b.k;
    const show = alpha > 0.01;
    const pr: d.Rect = .{ .x = bar.x + 6 * s, .y = bar.y + (bar.h - 28 * s) / 2, .w = 28 * s, .h = 28 * s };
    const ph = d.hit(ctx, b.ids +% 2, pr);
    qa.mark(pr, "video-play", .{});
    if (show) {
        const ccx = pr.x + pr.w / 2;
        const ccy = pr.y + pr.h / 2;
        const col = d.Rgba.white.alpha((if (ph.hovered) @as(f32, 1) else 0.88) * alpha);
        if (p.playing) {
            d.rect(dl, .{ .x = ccx - 6 * s, .y = ccy - 7 * s, .w = 4 * s, .h = 14 * s }, col, 1);
            d.rect(dl, .{ .x = ccx + 2 * s, .y = ccy - 7 * s, .w = 4 * s, .h = 14 * s }, col, 1);
        } else c.ImDrawList_AddTriangleFilled(dl, d.v(ccx - 5 * s, ccy - 8 * s), d.v(ccx - 5 * s, ccy + 8 * s), d.v(ccx + 8 * s, ccy), col.u());
    }
    if (ph.clicked and !failed) setPlaying(p, !p.playing);

    // Tempo.
    const f = ctx.ui.get(.medium);
    const fs = 12 * s;
    var tb1: [16]u8 = undefined;
    var tb2: [16]u8 = undefined;
    var tbuf: [40]u8 = undefined;
    const ttxt = if (p.duration_ms > 0)
        std.fmt.bufPrint(&tbuf, "{s} / {s}", .{ fmtTime(&tb1, p.pos_ms), fmtTime(&tb2, @floatFromInt(p.duration_ms)) }) catch ""
    else
        fmtTime(&tb1, p.pos_ms);
    // Num vídeo estreito, o espaço do tempo fica para as barras.
    const show_time = bar.w >= 260;
    const tw = if (show_time) d.width(f, fs, ttxt) else 0;
    if (show and show_time) d.text(dl, f, fs, pr.right() + 6 * s, d.centerY(bar, fs), d.Rgba.white.alpha(0.9 * alpha), ttxt);

    // Tela cheia (entrar; na tela cheia, sair), na ponta direita.
    var right = bar.right() - 8 * s;
    var full_clicked = false;
    if (b.full_btn) {
        const fr: d.Rect = .{ .x = right - 26 * s, .y = bar.y + (bar.h - 26 * s) / 2, .w = 26 * s, .h = 26 * s };
        right = fr.x - 6 * s;
        const fh = d.hit(ctx, b.ids +% 8, fr);
        qa.mark(fr, "video-fullscreen", .{});
        if (show) {
            fullIcon(dl, fr.x + fr.w / 2, fr.y + fr.h / 2, s, d.Rgba.white.alpha((if (fh.hovered) @as(f32, 1) else 0.85) * alpha), b.full);
            const tip = if (b.full) i18n.tr("Sair da tela cheia (Esc)", "Exit fullscreen (Esc)") else i18n.tr("Tela cheia (F)", "Fullscreen (F)");
            d.tip(ctx, fr, tip, fh.hovered);
        }
        full_clicked = fh.clicked;
    }

    // Som (só se o vídeo tem).
    if (p.has_audio) {
        const mr: d.Rect = .{ .x = right - 26 * s, .y = bar.y + (bar.h - 26 * s) / 2, .w = 26 * s, .h = 26 * s };
        right = mr.x - 6 * s;
        const mh = d.hit(ctx, b.ids +% 3, mr);
        qa.mark(mr, "video-mute", .{});
        const volume = &ctx.st.settings.video_volume;
        if (show) speakerIcon(dl, mr.x + mr.w / 2, mr.y + mr.h / 2, s, d.Rgba.white.alpha((if (mh.hovered) @as(f32, 1) else 0.85) * alpha), volume.*);
        if (mh.clicked) toggleMute(ctx, p);

        // Volume: à esquerda do alto-falante, no mesmo desenho da barra de progresso.
        const vw: f32 = (if (bar.w >= 320) @as(f32, 72) else 44) * s;
        const vt: d.Rect = .{ .x = right - vw, .y = bar.y + bar.h / 2 - 2 * s, .w = vw, .h = 4 * s };
        right = vt.x - 10 * s;
        const vr: d.Rect = .{ .x = vt.x - 6 * s, .y = bar.y + (bar.h - 24 * s) / 2, .w = vw + 12 * s, .h = 24 * s };
        const vh = d.hit(ctx, b.ids +% 6, vr);
        qa.mark(vr, "video-vol", .{});
        if (vh.held) {
            volume.* = @intFromFloat(std.math.round(std.math.clamp((ctx.mouse.x - vt.x) / vt.w, 0, 1) * 100));
            applyVolume(p, volume.*);
            vol_dragging = true;
        } else if (vol_dragging) {
            // Grava ao soltar, mesmo fora da barra (não a cada pixel do arrasto).
            vol_dragging = false;
            saveVolume(ctx);
        }
        if (show) {
            const k = @as(f32, @floatFromInt(@min(volume.*, 100))) / 100;
            d.rect(dl, vt, d.Rgba.white.alpha(0.25 * alpha), 2 * s);
            d.rect(dl, .{ .x = vt.x, .y = vt.y, .w = vt.w * k, .h = vt.h }, d.Rgba.white.alpha(0.9 * alpha), 2 * s);
            if (vh.hovered or vh.held) d.circle(dl, vt.x + vt.w * k, vt.y + vt.h / 2, 6 * s, d.Rgba.white.alpha(alpha));
        }
    }

    // Barra de progresso (clicar pula para o ponto).
    const tx0 = if (show_time) pr.right() + 6 * s + tw + 12 * s else pr.right() + 8 * s;
    const track: d.Rect = .{ .x = tx0, .y = bar.y + bar.h / 2 - 2 * s, .w = @max(10, right - tx0 - 4 * s), .h = 4 * s };
    const hr: d.Rect = .{ .x = track.x - 4 * s, .y = bar.y + (bar.h - 24 * s) / 2, .w = track.w + 8 * s, .h = 24 * s };
    const th = d.hit(ctx, b.ids +% 4, hr);
    qa.mark(hr, "video-bar", .{});
    const dur: f64 = @floatFromInt(p.duration_ms);
    if (show and track.w > 20) {
        const k: f32 = if (dur > 0) @floatCast(std.math.clamp(p.pos_ms / dur, 0, 1)) else 0;
        d.rect(dl, track, d.Rgba.white.alpha(0.25 * alpha), 2 * s);
        d.rect(dl, .{ .x = track.x, .y = track.y, .w = track.w * k, .h = track.h }, ctx.col(.accent).alpha(alpha), 2 * s);
        if (th.hovered or th.held) d.circle(dl, track.x + track.w * k, track.y + track.h / 2, 6 * s, d.Rgba.white.alpha(alpha));
        // Arrastando: mostra onde vai soltar.
        if (th.held and dur > 0) {
            const hk = std.math.clamp((ctx.mouse.x - track.x) / track.w, 0, 1);
            d.circle(dl, track.x + track.w * hk, track.y + track.h / 2, 4 * s, ctx.col(.accent).alpha(alpha));
        }
    }
    if (th.clicked and dur > 0 and !failed) {
        const hk: f64 = std.math.clamp((ctx.mouse.x - track.x) / track.w, 0, 1);
        seek(p, @intFromFloat(hk * dur));
    }
    return full_clicked;
}

fn speakerIcon(dl: *c.ImDrawList, cx: f32, cy: f32, s: f32, col: d.Rgba, volume: u8) void {
    d.rect(dl, .{ .x = cx - 8 * s, .y = cy - 3 * s, .w = 4 * s, .h = 6 * s }, col, 0);
    c.ImDrawList_AddTriangleFilled(dl, d.v(cx - 5 * s, cy - 3 * s), d.v(cx + 1 * s, cy - 8 * s), d.v(cx + 1 * s, cy + 8 * s), col.u());
    c.ImDrawList_AddTriangleFilled(dl, d.v(cx - 5 * s, cy - 3 * s), d.v(cx + 1 * s, cy + 8 * s), d.v(cx - 5 * s, cy + 3 * s), col.u());
    if (volume == 0) {
        d.line(dl, cx + 4 * s, cy - 4 * s, cx + 10 * s, cy + 4 * s, col, 1.6 * s);
        d.line(dl, cx + 10 * s, cy - 4 * s, cx + 4 * s, cy + 4 * s, col, 1.6 * s);
    } else {
        c.ImDrawList_PathArcTo(dl, d.v(cx + 1 * s, cy), 5 * s, -0.9, 0.9, 10);
        c.ImDrawList_PathStroke(dl, col.u(), 1.5 * s, 0);
        if (volume >= 50) {
            c.ImDrawList_PathArcTo(dl, d.v(cx + 1 * s, cy), 9 * s, -0.9, 0.9, 12);
            c.ImDrawList_PathStroke(dl, col.u(), 1.5 * s, 0);
        }
    }
}

/// Os quatro cantos da tela cheia: com as pontas para fora (entrar) ou recolhidos
/// para o meio (sair).
fn fullIcon(dl: *c.ImDrawList, cx: f32, cy: f32, s: f32, col: d.Rgba, exit: bool) void {
    const a = 7 * s;
    const leg = 4 * s;
    const corners = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    for (corners) |k| {
        // Entrar: o canto na ponta e as pernas voltando para o meio. Sair: o canto
        // recuado e as pernas indo para fora.
        const reach = if (exit) a - leg else a;
        const dir: f32 = if (exit) 1 else -1;
        const x = cx + k[0] * reach;
        const y = cy + k[1] * reach;
        c.ImDrawList_PathLineTo(dl, d.v(x + dir * k[0] * leg, y));
        c.ImDrawList_PathLineTo(dl, d.v(x, y));
        c.ImDrawList_PathLineTo(dl, d.v(x, y + dir * k[1] * leg));
        c.ImDrawList_PathStroke(dl, col.u(), 1.8 * s, 0);
    }
}

// --- Thread de download ----------------------------------------------------------

fn downloadMain(ud: ?*anyopaque) callconv(.c) c_int {
    const sh: *Shared = @ptrCast(@alignCast(ud.?));
    defer {
        platform.Window.wake(sh.wake_type, .media);
        release(sh);
        _ = live.fetchSub(1, .acq_rel);
    }
    _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_LOW);
    var ok = false;
    if (std.mem.startsWith(u8, sh.url, "file://")) {
        ok = loadFile(sh);
    } else {
        var curl: ?*c.CURL = null;
        defer if (curl) |h| c.curl_easy_cleanup(h);
        var zb: [2048]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&zb, "{s}", .{sh.url}, 0)) |z| {
            ok = images.fetch(&curl, z, .{ .ctx = sh, .write = dlWrite }, &sh.stop, 0);
        } else |_| {}
    }
    sh.lock();
    if (ok) sh.dl_done = true else sh.dl_failed = true;
    sh.unlock();
    c.SDL_BroadcastCondition(sh.cond);
    return 0;
}

fn loadFile(sh: *Shared) bool {
    var pbuf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pbuf, "{s}", .{sh.url[7..]}, 0) catch return false;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return false;
    defer c.SDL_free(data);
    sh.lock();
    defer sh.unlock();
    if (size > max_bytes) {
        sh.too_big = true;
        return false;
    }
    sh.data.appendSlice(alloc, @as([*]const u8, @ptrCast(data))[0..size]) catch return false;
    sh.total = @intCast(size);
    return true;
}

fn dlWrite(ud: *anyopaque, chunk: []const u8, total: i64) bool {
    const sh: *Shared = @ptrCast(@alignCast(ud));
    sh.lock();
    defer sh.unlock();
    if (sh.data.items.len + chunk.len > max_bytes or total > @as(i64, max_bytes)) {
        sh.too_big = true;
        return false;
    }
    // Tamanho conhecido: reserva tudo de uma vez (sem realocar e copiar o
    // que já veio a cada pedaço, com o decodificador esperando o mutex).
    if (total > 0 and sh.data.capacity < @as(usize, @intCast(total)))
        sh.data.ensureTotalCapacityPrecise(alloc, @intCast(total)) catch {};
    sh.data.appendSlice(alloc, chunk) catch return false;
    sh.total = total;
    c.SDL_BroadcastCondition(sh.cond);
    return true;
}

// O FFmpeg lê do que já chegou e espera o resto.
fn ioRead(ud: ?*anyopaque, buf: [*]u8, size: c_int) callconv(.c) c_int {
    const sh: *Shared = @ptrCast(@alignCast(ud.?));
    sh.lock();
    defer sh.unlock();
    while (true) {
        if (sh.stop.load(.acquire)) return ffmpeg.err_exit;
        if (sh.io_pos < sh.data.items.len) {
            const n = @min(@as(usize, @intCast(@max(size, 0))), sh.data.items.len - sh.io_pos);
            @memcpy(buf[0..n], sh.data.items[sh.io_pos..][0..n]);
            sh.io_pos += n;
            return @intCast(n);
        }
        if (sh.dl_done) return ffmpeg.err_eof;
        if (sh.dl_failed) return ffmpeg.err_io;
        _ = c.SDL_WaitConditionTimeout(sh.cond, sh.mutex, 100);
    }
}

fn ioSeek(ud: ?*anyopaque, off: i64, whence: c_int) callconv(.c) i64 {
    const sh: *Shared = @ptrCast(@alignCast(ud.?));
    sh.lock();
    defer sh.unlock();
    const len: i64 = if (sh.dl_done) @intCast(sh.data.items.len) else sh.total;
    return ffmpeg.seekTo(&sh.io_pos, len, off, whence);
}

// --- Thread de decodificação -------------------------------------------------------

fn decodeMain(ud: ?*anyopaque) callconv(.c) c_int {
    const sh: *Shared = @ptrCast(@alignCast(ud.?));
    defer {
        platform.Window.wake(sh.wake_type, .media);
        release(sh);
        _ = live.fetchSub(1, .acq_rel);
    }
    const a = ffmpeg.get() orelse return failWith(sh, .format);
    var m = ffmpeg.Media.open(a, .{ .ctx = sh, .read = ioRead, .seek = ioSeek }, sh.audio_on, 2) catch return failWith(sh, .format);
    defer m.close();
    var dec: Decoder = .{ .sh = sh, .m = &m };
    defer dec.deinit();
    sh.lock();
    sh.duration_ms = m.duration_ms;
    sh.unlock();
    if (m.hasAudio()) dec.openAudio();
    dec.run();
    return 0;
}

/// Falhou antes do primeiro quadro: diz por quê (o download manda).
fn failWith(sh: *Shared, why: Fail) c_int {
    sh.lock();
    defer sh.unlock();
    if (sh.status == .ready) return 0;
    sh.status = .failed;
    sh.fail = if (sh.too_big) .too_big else if (sh.dl_failed) .download else why;
    return 0;
}

const Decoder = struct {
    sh: *Shared,
    m: *ffmpeg.Media,
    pktq: std.ArrayList(*ffmpeg.Packet) = .empty,
    pool: std.ArrayList(*ffmpeg.Packet) = .empty,
    demux_eof: bool = false,
    video_eof: bool = false,
    flushed: bool = false,
    skip_until: i64 = 0,
    last_out: i64 = std.math.minInt(i64) / 2,
    gen: u32 = 0,
    audio_fresh: bool = true,

    fn deinit(dec: *Decoder) void {
        const a = dec.m.api;
        for (dec.pktq.items) |p| {
            var pp: ?*ffmpeg.Packet = p;
            a.av_packet_free(&pp);
        }
        for (dec.pool.items) |p| {
            var pp: ?*ffmpeg.Packet = p;
            a.av_packet_free(&pp);
        }
        dec.pktq.deinit(alloc);
        dec.pool.deinit(alloc);
    }

    fn openAudio(dec: *Decoder) void {
        const m = dec.m;
        const spec: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_F32, .channels = @intCast(m.channels), .freq = @intCast(m.rate) };
        const s = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null) orelse return;
        dec.sh.lock();
        dec.sh.audio = s;
        dec.sh.audio_bpms = @as(f64, @floatFromInt(m.rate * m.channels * 4)) / 1000.0;
        dec.sh.unlock();
    }

    fn audioQueuedMs(dec: *Decoder) f64 {
        const s = dec.sh.audio orelse return std.math.inf(f64);
        if (dec.sh.audio_bpms <= 0) return std.math.inf(f64);
        return @as(f64, @floatFromInt(c.SDL_GetAudioStreamQueued(s))) / dec.sh.audio_bpms;
    }

    /// Quadro de áudio decodificado (chamado pelo Media.decodeAudio).
    pub fn audio(dec: *Decoder, samples: []const f32, pts: ?i64) void {
        const sh = dec.sh;
        const s = sh.audio orelse return;
        if (pts) |t| if (t < dec.skip_until) return;
        const bytes = samples.len * 4;
        sh.lock();
        defer sh.unlock();
        if (dec.gen != sh.gen) return;
        if (dec.audio_fresh) {
            dec.audio_fresh = false;
            sh.audio_base_ms = pts orelse dec.skip_until;
            sh.audio_pushed = 0;
        }
        if (c.SDL_PutAudioStreamData(s, samples.ptr, @intCast(bytes))) sh.audio_pushed += bytes;
    }

    fn ringRoom(dec: *Decoder) bool {
        dec.sh.lock();
        defer dec.sh.unlock();
        return dec.sh.len < ring_n;
    }

    fn run(dec: *Decoder) void {
        const sh = dec.sh;
        const m = dec.m;
        while (!sh.stop.load(.acquire)) {
            // Pulo pedido pela interface.
            sh.lock();
            const want = sh.seek_ms;
            if (want >= 0) {
                sh.seek_ms = -1;
                dec.gen = sh.gen;
                // O fim que chegou entre o pedido e aqui era o de antes do pulo.
                sh.eof = false;
            }
            sh.unlock();
            if (want >= 0) {
                m.seek(want);
                for (dec.pktq.items) |p| {
                    m.unref(p);
                    dec.pool.append(alloc, p) catch {};
                }
                dec.pktq.clearRetainingCapacity();
                dec.demux_eof = false;
                dec.video_eof = false;
                dec.flushed = false;
                dec.skip_until = want;
                dec.last_out = std.math.minInt(i64) / 2;
                dec.audio_fresh = true;
                if (sh.audio) |s| _ = c.SDL_ClearAudioStream(s);
                continue;
            }
            var did = false;
            if (!dec.video_eof and dec.ringRoom()) {
                const r = m.receiveVideo();
                if (r == 0) {
                    dec.onFrame();
                    did = true;
                } else if (r == ffmpeg.err_again) {
                    if (dec.pktq.items.len > 0) {
                        const p = dec.pktq.orderedRemove(0);
                        _ = m.sendVideo(p);
                        m.unref(p);
                        dec.pool.append(alloc, p) catch {
                            var pp: ?*ffmpeg.Packet = p;
                            m.api.av_packet_free(&pp);
                        };
                        did = true;
                    } else if (dec.demux_eof and !dec.flushed) {
                        _ = m.sendVideo(null);
                        dec.flushed = true;
                        did = true;
                    }
                } else {
                    dec.video_eof = true;
                    sh.lock();
                    sh.eof = true;
                    const none = sh.decoded == 0 and sh.status == .opening;
                    sh.unlock();
                    if (none) _ = failWith(sh, .format);
                    platform.Window.wake(sh.wake_type, .media);
                    did = true;
                }
            }
            // Mais pacotes: poucos de vídeo na fila, ou o som ficando curto.
            const audio_low = sh.audio != null and dec.audioQueuedMs() < audio_ahead_ms;
            if (!dec.demux_eof and (dec.pktq.items.len < 8 or (audio_low and dec.pktq.items.len < max_packets))) {
                switch (m.read()) {
                    .video => dec.queue(),
                    .audio => {
                        m.decodeAudio(m.pkt.?, dec);
                        m.unref(m.pkt.?);
                    },
                    .skip => {},
                    .eof => dec.demux_eof = true,
                }
                did = true;
            }
            if (!did) {
                sh.lock();
                if (sh.seek_ms < 0 and !sh.stop.load(.acquire)) _ = c.SDL_WaitConditionTimeout(sh.cond, sh.mutex, 20);
                sh.unlock();
            }
        }
    }

    fn queue(dec: *Decoder) void {
        const m = dec.m;
        const p = dec.pool.pop() orelse m.api.av_packet_alloc() orelse {
            m.unref(m.pkt.?);
            return;
        };
        m.api.av_packet_move_ref(p, m.pkt.?);
        dec.pktq.append(alloc, p) catch {
            m.unref(p);
            var pp: ?*ffmpeg.Packet = p;
            m.api.av_packet_free(&pp);
        };
    }

    fn onFrame(dec: *Decoder) void {
        const sh = dec.sh;
        const m = dec.m;
        const t = m.framePtsMs(m.vtb) orelse dec.last_out + min_frame_ms;
        // Antes do ponto pedido, ou cedo demais para 30 qps: nem converte.
        if (t < dec.skip_until - 2) return;
        if (t < dec.last_out + min_frame_ms - 3) return;
        const src = m.frameSize();
        if (src[0] == 0 or src[1] == 0) return;
        sh.lock();
        const idx = (sh.head + sh.len) % ring_n;
        const gen = sh.gen;
        const room = sh.len < ring_n;
        if (!room or gen != dec.gen) {
            sh.unlock();
            return;
        }
        sh.src_w = src[0];
        sh.src_h = src[1];
        // Tamanho de saída: cabe no teto de agora (a conversa ou a tela cheia). Mudou:
        // só a vaga que vai ser escrita troca de tamanho (a interface não lê essa vaga;
        // as outras trocam quando chegar a vez delas).
        const out = fitSize(src[0], src[1], sh.box_w, sh.box_h);
        const slot = &sh.ring[idx];
        if (slot.w != out[0] or slot.h != out[1]) {
            if (alloc.alloc(u8, ffmpeg.rgbaSize(out[0], out[1]))) |px| {
                if (slot.px.len > 0) alloc.free(slot.px);
                slot.px = px;
                slot.w = out[0];
                slot.h = out[1];
            } else |_| {
                // Sem memória nem para o primeiro quadro: não toca. (Para o tamanho novo,
                // segue no de antes.)
                if (slot.px.len == 0) {
                    sh.unlock();
                    _ = failWith(sh, .format);
                    sh.stop.store(true, .release);
                    return;
                }
            }
        }
        const target = slot.*;
        sh.unlock();
        if (!m.toRgba(target.px, target.w, target.h)) return;
        sh.lock();
        // A interface pode ter pulado (seek) enquanto convertia: descarta.
        if (gen == sh.gen and sh.len < ring_n and (sh.head + sh.len) % ring_n == idx) {
            sh.ring[idx].pts_ms = t;
            sh.w = target.w;
            sh.h = target.h;
            const was_empty = sh.len == 0;
            sh.len += 1;
            sh.decoded += 1;
            sh.status = .ready;
            dec.last_out = t;
            sh.unlock();
            if (was_empty) platform.Window.wake(sh.wake_type, .media);
            return;
        }
        sh.unlock();
    }
};
