//! Pastas da barra de servidores na interface (core/pastas.zig, app_pastas.zig):
//! arrastar (servidor em cima de outro faz pasta; para dentro, para fora, reordenar),
//! o menu da pasta, "Adicionar à pasta" e "Remover da pasta" no menu do servidor e a
//! janela de configurações da pasta (nome e cor). Cada coisa vira uma operação
//! (`ctx.act(.{ .pasta = … })`): a barra muda na hora e o app grava na conta.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const i18n = @import("i18n.zig");
const popup = @import("popup.zig");
const forum = @import("forum.zig");
const inbox = @import("inbox.zig");
const state = @import("state.zig");
const types = @import("../core/types.zig");
const pastas = @import("../core/pastas.zig");
const Id = types.Id;

// --- Arrastar ------------------------------------------------------------------

pub const Axis = enum { vertical, horizontal };

/// Uma coisa da barra desenhada neste quadro.
pub const Slot = struct {
    item: pastas.Item,
    /// A pasta onde o servidor está (0 = solto). Numa pasta, 0.
    parent: u64 = 0,
    rect: d.Rect,
    /// Pasta aberta: os servidores dela vêm logo depois.
    open: bool = false,
};

pub const Drag = struct { item: pastas.Item, parent: u64 };

var drag: ?Drag = null;
/// Esc desistiu do arraste: nada recomeça (nem vira clique) até soltar o botão.
var cancelled = false;
var slots: [400]Slot = undefined;
var n_slots: usize = 0;
var axis: Axis = .vertical;
/// Barra sem pastas (dock, abas de texto): só reordena. Numa ponta de um grupo, o
/// servidor fica fora da pasta; no meio dele, entra.
var flat = false;
var area: d.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
/// Distância (em pontos) que o mouse anda segurando antes de virar arraste.
const threshold: f32 = 6;

/// Começa um quadro da barra (`r`: onde ela está).
pub fn begin(ax: Axis, flat_bar: bool, r: d.Rect) void {
    axis = ax;
    flat = flat_bar;
    area = r;
    n_slots = 0;
}

/// Anota o que foi desenhado e começa o arraste se a pessoa segurou e mexeu.
pub fn slot(s: Slot, hb: d.Hit) void {
    if (n_slots < slots.len) {
        slots[n_slots] = s;
        n_slots += 1;
    }
    if (drag == null and !cancelled and hb.held and c.ImGui_IsMouseDragging(0, threshold)) drag = .{ .item = s.item, .parent = s.parent };
}

/// O que está sendo arrastado.
pub fn dragged() ?Drag {
    return drag;
}

/// Um clique de verdade (soltar no fim de um arraste não seleciona nada).
pub fn clicked(hb: d.Hit) bool {
    return hb.clicked and drag == null and !cancelled;
}

const Zone = enum { before, center, after };
const Target = struct { i: usize, zone: Zone };

fn span(r: d.Rect) [2]f32 {
    return if (axis == .vertical) .{ r.y, r.bottom() } else .{ r.x, r.right() };
}

/// Onde o mouse está: a coisa mais perto ao longo da barra e em que parte dela. Fora
/// da barra (com folga), em lugar nenhum: soltar lá não muda nada.
fn target(ctx: *const d.Ctx) ?Target {
    const m = ctx.mouse;
    const pad: f32 = 24;
    if (m.x < area.x - pad or m.x > area.right() + pad or m.y < area.y - pad or m.y > area.bottom() + pad) return null;
    const p = if (axis == .vertical) m.y else m.x;
    var best: ?usize = null;
    var best_d = std.math.floatMax(f32);
    for (slots[0..n_slots], 0..) |s, i| {
        const sp = span(s.rect);
        const dist = if (p < sp[0]) sp[0] - p else if (p > sp[1]) p - sp[1] else 0;
        if (dist < best_d) {
            best_d = dist;
            best = i;
        }
    }
    const i = best orelse return null;
    const sp = span(slots[i].rect);
    const rel = (p - sp[0]) / @max(sp[1] - sp[0], 1);
    // Uma pasta só vai antes ou depois; numa barra sem pastas, também.
    const halves = flat or drag.?.item == .folder;
    const zone: Zone = if (rel < 0) .before else if (rel > 1) .after else if (halves)
        (if (rel < 0.5) .before else .after)
    else if (rel < 0.25) .before else if (rel > 0.75) .after else .center;
    return .{ .i = i, .zone = zone };
}

fn top(g: Id, where: pastas.Where) pastas.Op {
    return .{ .move_guild = .{ .guild = g, .where = where } };
}

fn edgeOfGroup(i: usize, first: bool) bool {
    const p = slots[i].parent;
    if (first) return i == 0 or slots[i - 1].parent != p;
    return i + 1 >= n_slots or slots[i + 1].parent != p;
}

var prng: ?std.Random.DefaultPrng = null;

/// Id de pasta nova (core/pastas.zig `newId`), diferente de todas as da barra.
pub fn newFolderId(ctx: *const d.Ctx) u64 {
    if (prng == null) prng = std.Random.DefaultPrng.init(c.SDL_GetTicksNS() ^ @as(u64, @bitCast(ctx.now_ms)));
    return pastas.newId(prng.?.random(), ctx.store.folders);
}

/// A operação de soltar `dg` em `t` (null = nada muda).
fn opFor(ctx: *const d.Ctx, dg: Drag, t: Target) ?pastas.Op {
    const s = slots[t.i];
    if (std.meta.eql(s.item, dg.item)) return null;
    const before = t.zone == .before;
    switch (dg.item) {
        .guild => |g| switch (s.item) {
            .guild => |h| {
                if (t.zone == .center) return .{ .merge = .{ .guild = g, .onto = h, .folder = newFolderId(ctx) } };
                const it: pastas.Item = .{ .guild = h };
                const where: pastas.Where = if (before) .{ .before = it } else .{ .after = it };
                if (s.parent == 0) return top(g, where);
                if (flat and edgeOfGroup(t.i, before))
                    return top(g, if (before) .{ .before = .{ .folder = s.parent } } else .{ .after = .{ .folder = s.parent } });
                return .{ .move_guild = .{ .guild = g, .folder = s.parent, .where = where } };
            },
            .folder => |f| return switch (t.zone) {
                .center => .{ .move_guild = .{ .guild = g, .folder = f, .where = .end } },
                .before => top(g, .{ .before = .{ .folder = f } }),
                // Logo depois de uma pasta aberta é o começo dela.
                .after => if (s.open) .{ .move_guild = .{ .guild = g, .folder = f, .where = .start } } else top(g, .{ .after = .{ .folder = f } }),
            },
        },
        .folder => |f| {
            const anchor: pastas.Item = switch (s.item) {
                .folder => |x| .{ .folder = x },
                .guild => |h| if (s.parent != 0) .{ .folder = s.parent } else .{ .guild = h },
            };
            if (anchor == .folder and anchor.folder == f) return null;
            return .{ .move_folder = .{ .folder = f, .where = if (before) .{ .before = anchor } else .{ .after = anchor } } };
        },
    }
}

/// Fim do quadro da barra: mostra onde vai cair e, se a pessoa soltou, muda a barra.
pub fn end(ctx: *d.Ctx) void {
    if (!c.ImGui_IsMouseDown(0)) cancelled = false;
    const dg = drag orelse return;
    const t = target(ctx);
    const op = if (t) |x| opFor(ctx, dg, x) else null;
    if (t != null and op != null) indicator(ctx, slots[t.?.i], t.?.zone);
    // Esc desiste do arraste.
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape) and c.ImGui_IsMouseDown(0)) {
        drag = null;
        cancelled = true;
        return;
    }
    if (c.ImGui_IsMouseDown(0)) return;
    drag = null;
    if (op) |o| ctx.act(.{ .pasta = o });
}

fn indicator(ctx: *d.Ctx, s: Slot, zone: Zone) void {
    const fg = ctx.fg;
    const col = ctx.col(.accent);
    const r = s.rect;
    qa.mark(r, "folder-drop:{s}", .{@tagName(zone)});
    switch (zone) {
        .center => d.border(fg, r.inset(-3, -3), col, @min(r.w, r.h) * 0.35, 2.5),
        .before, .after => if (axis == .vertical) {
            const y = if (zone == .before) r.y - 4 else r.bottom() + 4;
            d.rect(fg, .{ .x = r.x - 4, .y = y - 1.5, .w = r.w + 8, .h = 3 }, col, 1.5);
        } else {
            const x = if (zone == .before) r.x - 5 else r.right() + 5;
            d.rect(fg, .{ .x = x - 1.5, .y = r.y - 4, .w = 3, .h = r.h + 8 }, col, 1.5);
        },
    }
}

// --- Nomes -------------------------------------------------------------------------

/// O nome da pasta; sem nome, os nomes dos servidores dela (como o cliente oficial).
pub fn folderLabel(ctx: *const d.Ctx, f: *const types.GuildFolder, buf: []u8) []const u8 {
    if (f.name.len > 0) return f.name;
    var len: usize = 0;
    var n: usize = 0;
    for (f.guilds) |gid| {
        const g = ctx.store.guild(gid) orelse continue;
        const sep: []const u8 = if (n > 0) ", " else "";
        if (len + sep.len >= buf.len) break;
        @memcpy(buf[len..][0..sep.len], sep);
        len += sep.len;
        // O que não cabe é cortado sem partir um caractere.
        const part = d.utf8Prefix(g.name, buf.len - len);
        @memcpy(buf[len..][0..part.len], part);
        len += part.len;
        n += 1;
        if (part.len < g.name.len) break;
    }
    if (n == 0) return i18n.tr("Pasta", "Folder");
    return buf[0..len];
}

// --- Menus ---------------------------------------------------------------------------

const Item = popup.Item;

pub const id_add: u8 = 96;
pub const id_remove: u8 = 97;
const id_new: u8 = 99;
const id_settings: u8 = 1;
const id_read: u8 = 2;
const id_delete: u8 = 3;

/// "Adicionar à pasta…" e, se ele está numa, "Remover da pasta" (menu do servidor).
pub fn guildItems(ctx: *const d.Ctx, gid: Id, out: []Item) usize {
    if (out.len < 2) return 0;
    out[0] = .{ .label = "Adicionar à pasta…", .en = "Add to Folder…", .id = id_add, .sep = true };
    if (ctx.store.folderOf(gid) == 0) return 1;
    out[1] = .{ .label = "Remover da pasta", .en = "Remove from Folder", .id = id_remove };
    return 2;
}

var pick_names: [24][96]u8 = undefined;
var pick_ids: [24]u64 = undefined;
var pick_n: usize = 0;

/// A segunda lista de "Adicionar à pasta…": as pastas (menos a dele) e "Nova pasta".
pub fn pickItems(ctx: *const d.Ctx, gid: Id, out: []Item) usize {
    const cur = ctx.store.folderOf(gid);
    var n: usize = 0;
    pick_n = 0;
    for (ctx.store.folders) |*f| {
        if (f.id == 0 or f.id == cur) continue;
        if (pick_n == pick_ids.len or n + 1 >= out.len) break;
        const label = folderLabel(ctx, f, &pick_names[pick_n]);
        pick_ids[pick_n] = f.id;
        out[n] = .{ .label = label, .en = label, .id = @intCast(100 + pick_n), .raw = true };
        n += 1;
        pick_n += 1;
    }
    out[n] = .{ .label = "Nova pasta", .en = "New Folder", .id = id_new, .sep = n > 0 };
    return n + 1;
}

/// O menu da pasta (botão direito nela).
pub fn folderItems(ctx: *const d.Ctx, fid: u64, out: []Item) usize {
    if (ctx.store.folderById(fid) == null or out.len < 3) return 0;
    out[0] = .{ .label = "Marcar pasta como lida", .en = "Mark Folder as Read", .id = id_read };
    out[1] = .{ .label = "Configurações da pasta…", .en = "Folder Settings…", .id = id_settings };
    out[2] = .{ .label = "Remover pasta", .en = "Remove Folder", .id = id_delete, .danger = true, .sep = true };
    return 3;
}

/// Uma escolha nos menus das pastas. false: não é daqui.
pub fn choose(ctx: *d.Ctx, kind: state.MenuKind, id: Id, item: u8, r: d.Rect) bool {
    switch (kind) {
        .folder => switch (item) {
            id_settings => openSettings(ctx, id),
            id_read => ctx.act(.{ .mark_folder_read = id }),
            id_delete => ctx.act(.{ .pasta = .{ .remove_folder = id } }),
            else => {},
        },
        .folder_pick => if (item == id_new) {
            // A pasta nova aparece já com a janela do nome aberta.
            const fid = newFolderId(ctx);
            ctx.act(.{ .pasta = .{ .new_folder = .{ .guild = id, .folder = fid } } });
            openWith(ctx, fid, "", 0);
        } else if (item >= 100 and item - 100 < pick_n) {
            ctx.act(.{ .pasta = .{ .move_guild = .{ .guild = id, .folder = pick_ids[item - 100], .where = .end } } });
        },
        .guild => switch (item) {
            id_add => ctx.st.popup = .{ .menu = .{ .kind = .folder_pick, .id = id, .x = r.x + r.w - 8, .y = r.y + 40 } },
            id_remove => ctx.act(.{ .pasta = .{ .ungroup = id } }),
            else => return false,
        },
        else => return false,
    }
    return true;
}

// --- Configurações da pasta ------------------------------------------------------

var name_buf: [pastas.max_name + 1]u8 = @splat(0);
var hex_buf: [8]u8 = @splat(0);
var color: u32 = 0;
var start_name: [pastas.max_name]u8 = undefined;
var start_name_len: usize = 0;
var start_color: u32 = 0;

pub fn openSettings(ctx: *d.Ctx, fid: u64) void {
    const f = ctx.store.folderById(fid) orelse return;
    openWith(ctx, fid, f.name, f.color);
}

fn openWith(ctx: *d.Ctx, fid: u64, name: []const u8, col: u32) void {
    const nm = d.utf8Prefix(name, pastas.max_name);
    name_buf = @splat(0);
    @memcpy(name_buf[0..nm.len], nm);
    @memcpy(start_name[0..nm.len], nm);
    start_name_len = nm.len;
    color = col;
    start_color = col;
    writeHex(col);
    ctx.st.popup = .{ .folder_settings = .{ .folder = fid } };
}

fn writeHex(col: u32) void {
    hex_buf = @splat(0);
    if (col == 0) return;
    _ = std.fmt.bufPrint(&hex_buf, "{X:0>6}", .{col}) catch {};
}

pub fn drawSettings(ctx: *d.Ctx, fid: u64) void {
    const f = ctx.store.folderById(fid) orelse return popup.close(ctx);
    const palette = &@import("../app.zig").App.accents;
    const r = forum.dialogRect(ctx, 440, 282);
    const dl = popup.beginWindow("##folder-settings", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    inbox.panelFrame(ctx, dl, r);
    qa.mark(r, "folder-settings", .{});
    const fam = ctx.ui;
    _ = d.textClipped(dl, fam.get(.bold), 17, r.x + 18, r.y + 16, ctx.col(.text), i18n.tr("Configurações da pasta", "Folder Settings"), r.w - 36);

    d.text(dl, fam.get(.semibold), 12, r.x + 18, r.y + 52, ctx.col(.muted), i18n.tr("Nome da pasta", "Folder Name"));
    const ir: d.Rect = .{ .x = r.x + 18, .y = r.y + 70, .w = r.w - 36, .h = 36 };
    qa.mark(ir, "folder-name", .{});
    if (popup.appearing) c.ImGui_SetKeyboardFocusHere();
    // Sem nome, a dica é o que a barra mostra no lugar dele: os nomes dos servidores.
    var lb: [120]u8 = undefined;
    var hb: [128]u8 = undefined;
    const hint = std.fmt.bufPrintSentinel(&hb, "{s}", .{folderLabel(ctx, f, &lb)}, 0) catch "";
    const enter = forum.textInput(ctx, dl, ir, "##folder-name", if (f.name.len == 0 and hint.len > 0) hint.ptr else i18n.trZ("Nome da pasta", "Folder name").ptr, &name_buf, c.ImGuiInputTextFlags_EnterReturnsTrue);

    d.text(dl, fam.get(.semibold), 12, r.x + 18, r.y + 120, ctx.col(.muted), i18n.tr("Cor da pasta", "Folder Color"));
    const sw: f32 = 26;
    const gap: f32 = 8;
    var x = r.x + 18;
    const y = r.y + 140;
    for (0..palette.len + 1) |i| {
        const sr: d.Rect = .{ .x = x, .y = y, .w = sw, .h = sw };
        const h = d.hit(ctx, 0x7a00 + i, sr);
        qa.mark(sr, "folder-color:{d}", .{i});
        const val: u32 = if (i == 0) 0 else palette[i - 1];
        const sel = color == val;
        const cx = x + sw / 2;
        const cy = y + sw / 2;
        if (i == 0) {
            // Sem cor: anel com um risco.
            c.ImDrawList_AddCircleEx(dl, d.v(cx, cy), 9, ctx.col(.faint).u(), 0, 1.5, 0);
            d.line(dl, cx - 6, cy + 6, cx + 6, cy - 6, ctx.col(.faint), 1.5);
            d.tip(ctx, sr, i18n.tr("Sem cor", "No color"), h.hovered);
        } else d.circle(dl, cx, cy, 10, d.Rgba.hex(val));
        if (sel or h.hovered) c.ImDrawList_AddCircleEx(dl, d.v(cx, cy), 13, (if (sel) ctx.col(.text) else ctx.col(.muted)).u(), 0, 1.5, 0);
        if (h.clicked) {
            color = val;
            writeHex(val);
        }
        x += sw + gap;
    }
    // Qualquer cor: o código em hexadecimal.
    const hr: d.Rect = .{ .x = r.x + 18, .y = y + 40, .w = 120, .h = 32 };
    qa.mark(hr, "folder-hex", .{});
    d.text(dl, fam.get(.medium), 14, hr.x + 1, d.centerY(hr, 14), ctx.col(.muted), "#");
    const hex_in: d.Rect = .{ .x = hr.x + 14, .y = hr.y, .w = hr.w - 14, .h = hr.h };
    if (forum.textInput(ctx, dl, hex_in, "##folder-hex", "RRGGBB", hex_buf[0..7], c.ImGuiInputTextFlags_CharsHexadecimal | c.ImGuiInputTextFlags_CharsUppercase)) {
        const typed = std.mem.sliceTo(&hex_buf, 0);
        if (pastas.parseHex(typed)) |v| color = v else if (typed.len == 0) color = 0;
    }
    const pr: d.Rect = .{ .x = hr.right() + 10, .y = hr.y + 4, .w = 24, .h = 24 };
    if (color != 0) d.rect(dl, pr, d.Rgba.hex(color), 6) else d.border(dl, pr, ctx.col(.faint), 6, 1.5);

    const save = i18n.tr("Salvar", "Save");
    const bw = d.width(fam.get(.semibold), 13.5, save) + 36;
    const br: d.Rect = .{ .x = r.right() - 18 - bw, .y = r.bottom() - 50, .w = bw, .h = 34 };
    qa.mark(br, "folder-save", .{});
    const clicked_save = forum.primary(ctx, dl, fam, 0x7a40, br, save, true);
    const cancel = i18n.tr("Cancelar", "Cancel");
    const cw = inbox.buttonWidth(ctx, cancel);
    const cr: d.Rect = .{ .x = br.x - cw - 10, .y = br.y + 3, .w = cw, .h = 28 };
    qa.mark(cr, "folder-cancel", .{});
    if (inbox.button(ctx, dl, 0x7a41, cr, cancel, false)) return popup.close(ctx);
    if (clicked_save or enter) {
        const name = pastas.Name.init(std.mem.sliceTo(&name_buf, 0));
        const name_changed = !std.mem.eql(u8, name.slice(), start_name[0..start_name_len]);
        const color_changed = color != start_color;
        if (name_changed or color_changed) ctx.act(.{ .pasta = .{ .edit = .{
            .folder = fid,
            .name = if (name_changed) name else null,
            .color = if (color_changed) color else null,
        } } });
        popup.close(ctx);
    }
}
