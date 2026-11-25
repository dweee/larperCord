//! QA do mascote do canto parado: o desenho dele se repete de um quadro para o outro sem
//! ser refeito (ui/carimbo.zig; no invisível, a textura da camada, ui/camada.zig), e o
//! quadro sai igual, pixel a pixel, ao desenhado de novo a cada quadro. Em casa, dormindo,
//! com um visual cheio de peças, no invisível e com a interface em 125%. Com uma peça que
//! mexe com o relógio (a hélice) ele não se repete; e cada peça que mexe com o relógio
//! está em `partes.movesWithClock` (senão ela ficaria parada). Parte da QA_SUITE=mascote.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const pet = @import("ui/mascote_pet.zig");
const terminal = @import("ui/mascote_terminal.zig");
const partes = @import("ui/mascote_partes.zig");
const visual = @import("ui/mascote_visual.zig");
const mascote = @import("ui/mascote.zig");
const Text = @import("ui/settings_state.zig").Text;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}

// --- Os pixels em volta dele ---------------------------------------------------------

const max_px = 192 * 192 * 4;
var px_a: [max_px]u8 = undefined;
var px_prev: [max_px]u8 = undefined;
var px_now: [max_px]u8 = undefined;
var len_a: usize = 0;
var len_prev: usize = 0;
var area: c.SDL_Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

/// Em pixels, o retângulo em volta do Terminal do canto (com folga para chapéu e orelhas).
fn petArea(app: *App) c.SDL_Rect {
    const g = pet.qaDrawn();
    const k = app.io.*.DisplayFramebufferScale.x;
    const x0 = @floor((g[0] - 0.7 * g[2]) * k);
    const y0 = @floor((g[1] - 0.85 * g[2]) * k);
    const x1 = @ceil((g[0] + 0.7 * g[2]) * k);
    const y1 = @ceil((g[1] + 0.6 * g[2]) * k);
    return .{ .x = @intFromFloat(@max(x0, 0)), .y = @intFromFloat(@max(y0, 0)), .w = @intFromFloat(@max(x1 - @max(x0, 0), 1)), .h = @intFromFloat(@max(y1 - @max(y0, 0), 1)) };
}

/// Os pixels de `r` no quadro que acabou de ser desenhado, em RGBA.
fn read(app: *App, r: c.SDL_Rect, out: []u8) ?usize {
    const ren = app.win.renderer orelse return null;
    const surf = c.SDL_RenderReadPixels(ren, &r) orelse return null;
    defer c.SDL_DestroySurface(surf);
    const rgba = c.SDL_ConvertSurface(surf, c.SDL_PIXELFORMAT_RGBA32) orelse return null;
    defer c.SDL_DestroySurface(rgba);
    const row: usize = @intCast(rgba.*.w * 4);
    const h: usize = @intCast(rgba.*.h);
    if (row * h > out.len) return null;
    const src: [*]const u8 = @ptrCast(rgba.*.pixels orelse return null);
    const pitch: usize = @intCast(rgba.*.pitch);
    for (0..h) |y| @memcpy(out[y * row ..][0..row], src[y * pitch ..][0..row]);
    return row * h;
}

/// Cores diferentes (o mascote na tela tem várias; o fundo liso, uma).
fn colorCount(px: []const u8) usize {
    var seen: [32]u32 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i + 4 <= px.len and n < seen.len) : (i += 4) {
        const v = std.mem.readInt(u32, px[i..][0..4], .little);
        if (std.mem.indexOfScalar(u32, seen[0..n], v) == null) {
            seen[n] = v;
            n += 1;
        }
    }
    return n;
}

/// Parado: em casa, sem reação nem nada que ele faça sozinho.
fn still() bool {
    return pet.mode() == .home and pet.reaction() == .none and pet.activity() == .none and pet.qaDrawn()[2] > 0;
}

// --- Cada caso --------------------------------------------------------------------------

/// Como o caso começa: visual, status, escala e se dorme.
const Case = struct {
    look: []const u8 = "",
    tweaks: []const u8 = "",
    status: u8 = 0,
    scale: f32 = 1,
    asleep: bool = false,
};

fn setup(comptime cs: Case) fn (*App) void {
    return struct {
        fn f(app: *App) void {
            const set = &app.st.settings;
            set.mascot = 0;
            set.mascot_pet = true;
            set.mascot_life = 0;
            set.mascot_cursor = false;
            set.mascot_away = false;
            set.mascot_typing = false;
            set.mascot_games = false;
            set.mascot_plant = false;
            set.mascot_date_hats = false;
            set.mascot_file.set("");
            set.mascot_look.set(cs.look);
            set.mascot_tweaks.set(cs.tweaks);
            set.my_status = cs.status;
            set.ui_scale = cs.scale;
            app.st.popup = .none;
            pet.qaUnhide();
            pet.qaLifeReset(app.images.now_ms);
            pet.qaHome();
            pet.qaIdleFor(if (cs.asleep) 3 * 60 * 1000 + 12_000 else 0, app.images.now_ms);
            // O mouse longe dele e parado: os olhos não mexem entre as fotos.
            c.ImGuiIO_AddMousePosEvent(app.io, 12, 12);
            pet.qa_redraw = true;
            len_prev = 0;
        }
    }.f;
}

/// Desenhado de novo a cada quadro (como era): a tela em volta dele fica igual por dois
/// quadros seguidos (nada mais anima ali), e esse é o quadro de referência.
fn referenceStill(app: *App) bool {
    if (!pet.qa_redraw or !still()) return false;
    const r = petArea(app);
    const n = read(app, r, &px_now) orelse return false;
    const same = len_prev == n and area.x == r.x and area.y == r.y and area.w == r.w and std.mem.eql(u8, px_now[0..n], px_prev[0..n]);
    area = r;
    @memcpy(px_prev[0..n], px_now[0..n]);
    len_prev = n;
    if (!same or colorCount(px_now[0..n]) < 3) return false;
    @memcpy(px_a[0..n], px_now[0..n]);
    len_a = n;
    return true;
}

var repeats0: u64 = 0;
fn repeatOn(_: *App) void {
    pet.qa_redraw = false;
    repeats0 = pet.qaRepeats();
}
/// Parado, o desenho se repete (alguns quadros seguidos sem refazer).
fn repeating(_: *App) bool {
    return still() and pet.qaRepeats() >= repeats0 + 3;
}

var diff_n: usize = 0;
var diff_max: u8 = 0;
/// O quadro com o desenho repetido é o de referência, pixel a pixel.
fn samePixels(app: *App) bool {
    if (!still() or len_a == 0) return false;
    if (!std.meta.eql(petArea(app), area)) return false;
    const n = read(app, area, &px_now) orelse return false;
    if (n != len_a) return false;
    diff_n = 0;
    diff_max = 0;
    var i: usize = 0;
    while (i < n) : (i += 4) {
        var px_diff: u8 = 0;
        for (0..4) |ch| px_diff = @max(px_diff, if (px_now[i + ch] > px_a[i + ch]) px_now[i + ch] - px_a[i + ch] else px_a[i + ch] - px_now[i + ch]);
        if (px_diff > 0) diff_n += 1;
        diff_max = @max(diff_max, px_diff);
    }
    return diff_n == 0;
}
fn report(_: *App) void {
    if (diff_n > 0) std.debug.print("       mascote repetido: {d} pixels diferentes (até {d} por canal) em {d}x{d}\n", .{ diff_n, diff_max, area.w, area.h });
}

fn caseOps(comptime name: []const u8, comptime cs: Case) [7]Op {
    return .{
        run(setup(cs)),
        .{ .wait = 400 },
        .{ .expect = .{ .name = name ++ ": parado, desenhado de novo a cada quadro (a referência)", .check = referenceStill, .timeout_ms = 4000 } },
        run(repeatOn),
        expect(name ++ ": parado, o desenho se repete sem refazer", repeating),
        expect(name ++ ": e o quadro sai igual ao de referência, pixel a pixel", samePixels),
        run(report),
    };
}

// --- A hélice gira: com ela, nada de repetir --------------------------------------------

fn propellerNoRepeat(_: *App) bool {
    return still() and terminal.look.hat == .propeller and pet.qaRepeats() == repeats0;
}

// --- Cada peça que mexe com o relógio está na lista ---------------------------------------

var probe: c.ImDrawList = std.mem.zeroes(c.ImDrawList);
var clock_bad: [96]u8 = undefined;
var clock_bad_len: usize = 0;

/// O Terminal do canto numa lista à parte, com o relógio em `clock`: o resumo dos vértices.
fn drawAt(size: f32, clock: f32) u64 {
    probe._Data = c.ImGui_GetDrawListSharedData();
    c.ImDrawList__ResetForNewFrame(&probe);
    c.ImDrawList__SetPixelDensity(&probe, 1);
    c.ImDrawList_PushClipRect(&probe, .{ .x = -10_000, .y = -10_000 }, .{ .x = 10_000, .y = 10_000 }, false);
    c.ImDrawList_PushTexture(&probe, .{ ._TexData = c.ImGui_GetIO().*.Fonts.*.TexData, ._TexID = 0 });
    terminal.pet(&probe, 300, 300, size, .{ .clock = clock });
    const vtx = probe.VtxBuffer.Data[0..@intCast(probe.VtxBuffer.Size)];
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(vtx));
}

/// Desenha com cada peça (chapéu, boca, olhos, orelhas, acessório), pequeno e grande, em
/// dois relógios: mexeu só quem está em `partes.movesWithClock`, e quem está lá mexeu.
fn clockListRight(_: *App) bool {
    defer c.ImDrawList__ClearFreeMemory(&probe);
    const was = mascote.borrow(&terminal.look);
    defer mascote.restore(was);
    var ok = true;
    clock_bad_len = 0;
    const Try = struct {
        fn one(lk: visual.Look, what: []const u8, okp: *bool) void {
            _ = mascote.borrow(&lk);
            for ([_]f32{ 50, 90 }) |size| {
                const moved = drawAt(size, 1.0) != drawAt(size, 1.37);
                const listed = partes.movesWithClock(&terminal.look, size < 64);
                if (moved != listed) {
                    okp.* = false;
                    const msg = std.fmt.bufPrint(clock_bad[clock_bad_len..], "{s}/{d} ", .{ what, @as(u32, @intFromFloat(size)) }) catch clock_bad[0..0];
                    clock_bad_len += msg.len;
                }
            }
        }
    };
    inline for (.{ visual.Hat, visual.Mouth, visual.Eyes, visual.Ears }) |E| {
        for (std.enums.values(E)) |v| {
            if (comptime E == visual.Eyes) if (v == .custom) continue;
            if (comptime E == visual.Mouth) if (v == .custom) continue;
            var lk: visual.Look = .{};
            switch (E) {
                visual.Hat => lk.hat = v,
                visual.Mouth => lk.mouth = v,
                visual.Eyes => lk.eyes = v,
                visual.Ears => lk.ears = v,
                else => unreachable,
            }
            Try.one(lk, @tagName(v), &ok);
        }
    }
    for (std.enums.values(visual.Acc)) |a| {
        var lk: visual.Look = .{};
        lk.toggle(a);
        Try.one(lk, @tagName(a), &ok);
    }
    if (!ok) std.debug.print("       mexem com o relógio sem estar na lista (ou o contrário): {s}\n", .{clock_bad[0..clock_bad_len]});
    return ok;
}

/// As configurações que os casos mexem, como estavam antes (voltam no fim).
const Saved = struct {
    mascot: u8,
    life: u8,
    cursor: bool,
    away: bool,
    typing: bool,
    games: bool,
    plant: bool,
    date_hats: bool,
    look: Text,
    tweaks: Text,
    file: Text,
    status: u8,
    scale: f32,
};
var saved: Saved = undefined;
fn save(app: *App) void {
    const set = &app.st.settings;
    saved = .{ .mascot = set.mascot, .life = set.mascot_life, .cursor = set.mascot_cursor, .away = set.mascot_away, .typing = set.mascot_typing, .games = set.mascot_games, .plant = set.mascot_plant, .date_hats = set.mascot_date_hats, .look = set.mascot_look, .tweaks = set.mascot_tweaks, .file = set.mascot_file, .status = set.my_status, .scale = set.ui_scale };
}
fn cleanup(app: *App) void {
    const set = &app.st.settings;
    pet.qa_redraw = false;
    set.mascot = saved.mascot;
    set.mascot_life = saved.life;
    set.mascot_cursor = saved.cursor;
    set.mascot_away = saved.away;
    set.mascot_typing = saved.typing;
    set.mascot_games = saved.games;
    set.mascot_plant = saved.plant;
    set.mascot_date_hats = saved.date_hats;
    set.mascot_look = saved.look;
    set.mascot_tweaks = saved.tweaks;
    set.mascot_file = saved.file;
    set.my_status = saved.status;
    set.ui_scale = saved.scale;
    pet.qaIdleFor(0, app.images.now_ms);
    pet.qaHome();
}

pub const ops = [_]Op{
    s("mascote parado: repetido sem refazer, igual pixel a pixel"),
    run(save),
} ++ caseOps("em casa", .{}) ++
    // Logo depois de "em casa", com tudo igual menos o visual (e com as cores de sempre,
    // que também entram no resumo): o resumo tem que ver o visual, senão repetiria o
    // desenho de antes.
    caseOps("com um visual cheio de peças", .{ .look = "eyes=big mouth=fang hat=viking ears=bunny acc=glasses,scarf,blush", .tweaks = "roundness=3 body-width=2 ear-size=2" }) ++
    caseOps("dormindo", .{ .asleep = true }) ++
    caseOps("invisível (a textura da camada)", .{ .status = 3 }) ++
    caseOps("com a interface em 125%", .{ .scale = 1.25 }) ++
    caseOps("invisível, com a interface em 125%", .{ .status = 3, .scale = 1.25, .look = "hat=crown acc=monocle pal=oceano" }) ++
    [_]Op{
        run(setup(.{ .look = "hat=propeller" })),
        .{ .wait = 400 },
        run(repeatOn),
        .{ .wait = 400 },
        expect("com a hélice (gira com o relógio), o desenho não se repete", propellerNoRepeat),
        expect("cada peça que mexe com o relógio está na lista (e só elas)", clockListRight),
        run(cleanup),
    };
