//! As pastas da barra no Discord de verdade (core/pastas.zig, net/settings_proto.zig):
//! gravar o que mudou aqui e passar adiante o que vem nas configurações. Roda na
//! thread da rede, chamado pelo gateway de net/discord.zig (`g` é o `Gateway` de lá;
//! a demonstração passa o dela, net/fake_pastas.zig).
//!
//! O endpoint das configurações tem rate limit pesado: cada gravação é um pedido só.
//! O gateway guarda a última cópia inteira das configurações gerais (`Cache`), que já
//! chega sem pedir nada: no READY (`user_settings_proto`), em cada
//! USER_SETTINGS_PROTO_UPDATE e na resposta de cada PATCH. O PATCH sai dela, com a
//! versão dela. Um GET só quando não há cópia (o READY veio na forma antiga, em JSON,
//! ou a cópia não deu para ler).
const std = @import("std");
const types = @import("../core/types.zig");
const ev = @import("../core/event.zig");
const settings_proto = @import("settings_proto.zig");
const status_proto = @import("status_proto.zig");
const j = @import("jsonx.zig");
const i18n = @import("../ui/i18n.zig");
const Value = std.json.Value;

const alloc = std.heap.c_allocator;

/// As pastas de `layout` como a lista do Store (c_allocator). Consome `layout`.
/// `keep_empty`: sem pasta nenhuma, devolve a lista vazia em vez de null (uma
/// resposta de gravação diz como ficou, mesmo vazia).
pub fn toFolders(layout: settings_proto.Layout, keep_empty: bool) ?[]types.GuildFolder {
    defer layout.deinit(alloc);
    if (layout.folders.len == 0 and !keep_empty) return null;
    const out = alloc.alloc(types.GuildFolder, layout.folders.len) catch return null;
    var n: usize = 0;
    for (layout.folders) |f| {
        const guilds = alloc.dupe(types.Id, f.guilds) catch continue;
        const name = alloc.dupe(u8, f.name) catch {
            alloc.free(guilds);
            continue;
        };
        out[n] = .{ .id = f.id, .name = name, .color = f.color, .guilds = guilds };
        n += 1;
    }
    return out[0..n];
}

/// As pastas das configurações `bytes` (já decodificadas). null: não deu para ler.
pub fn foldersOf(bytes: []const u8) ?[]types.GuildFolder {
    const layout = settings_proto.fromProto(alloc, bytes) catch return null;
    return toFolders(layout, true);
}

/// As pastas de um `user_settings_proto` / USER_SETTINGS_PROTO_UPDATE (base64), como
/// o evento que o Store recebe. null: não veio pasta (uma atualização parcial sem
/// elas não apaga as que já temos) ou não deu para ler.
pub fn eventFromBase64(b64: []const u8) ?ev.Event {
    const layout = settings_proto.fromProtoBase64(alloc, b64) catch return null;
    return .{ .guild_folders = toFolders(layout, false) orelse return null };
}

fn decode(a: std.mem.Allocator, b64: []const u8) ?[]u8 {
    return status_proto.decodeBase64(a, b64) catch null;
}

/// A última cópia inteira das configurações gerais (tipo 1), já decodificada.
pub const Cache = struct {
    bytes: std.ArrayList(u8) = .empty,
    have: bool = false,

    pub fn set(c: *Cache, data: []const u8) void {
        c.bytes.clearRetainingCapacity();
        c.bytes.appendSlice(alloc, data) catch return c.forget();
        c.have = true;
    }

    pub fn forget(c: *Cache) void {
        c.bytes.clearRetainingCapacity();
        c.have = false;
    }

    pub fn deinit(c: *Cache) void {
        c.bytes.deinit(alloc);
        c.* = .{};
    }

    /// As configurações inteiras em base64: o READY, a resposta de um PATCH ou de um GET.
    pub fn remember(c: *Cache, b64: []const u8) void {
        const bytes = status_proto.decodeBase64(alloc, b64) catch return c.forget();
        defer alloc.free(bytes);
        c.set(bytes);
    }

    /// USER_SETTINGS_PROTO_UPDATE (tipo 1). Parcial: os campos de cima que vieram trocam
    /// os da cópia (settings_proto.zig `mergeTop`); sem cópia, continua sem.
    pub fn update(c: *Cache, b64: []const u8, partial: bool) void {
        if (!partial) return c.remember(b64);
        if (!c.have) return;
        const bytes = status_proto.decodeBase64(alloc, b64) catch return c.forget();
        defer alloc.free(bytes);
        const merged = settings_proto.mergeTop(alloc, c.bytes.items, bytes) catch return c.forget();
        defer alloc.free(merged);
        c.set(merged);
    }
};

/// As configurações gerais (tipo 1) como estão agora na conta, já decodificadas.
fn current(g: anytype, a: std.mem.Allocator) ?[]u8 {
    var resp = g.request("GET", "/users/@me/settings-proto/1", null) orelse {
        g.notice("não deu para ler as pastas da conta", "couldn't read the account's folders", .{});
        return null;
    };
    defer resp.body.deinit(alloc);
    if (resp.status != 200) {
        g.noticeHttp(i18n.tr("não deu para ler as pastas da conta", "couldn't read the account's folders"), &resp);
        return null;
    }
    const v = std.json.parseFromSliceLeaky(Value, a, resp.body.items, .{}) catch return null;
    return decode(a, j.str(j.get(v, "settings")) orelse return null);
}

fn done(g: anytype, seq: u32, ok: bool, bytes: ?[]const u8) void {
    g.emit(.{ .folders_saved = .{ .seq = seq, .ok = ok, .folders = if (bytes) |b| foldersOf(b) else null } });
}

/// Grava as mudanças nas pastas: aplica as operações na cópia das configurações e
/// manda só o campo das pastas, com a versão da cópia: um pedido. Sem cópia, um GET
/// antes. Se outro aparelho gravou algo que ainda não chegou aqui, o Discord recusa
/// (`out_of_date`) em vez de voltar a mudança dele e responde com as configurações como
/// estão: as operações são aplicadas de novo sobre elas (uma vez; sem elas na resposta,
/// um GET). Dando errado, a barra volta ao que a conta tem e um aviso diz por quê.
pub fn save(g: anytype, f: ev.FolderEdit) void {
    const what = i18n.tr("não deu para salvar as pastas", "couldn't save the folders");
    const cache: *Cache = g.settingsCache();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var tries: u8 = 0;
    while (true) : (tries += 1) {
        if (!cache.have) {
            const got = current(g, a) orelse return done(g, f.seq, false, null);
            cache.set(got);
        }
        // Uma cópia: o gateway pode trocar a guardada enquanto o PATCH espera.
        const raw = a.dupe(u8, cache.bytes.items) catch return done(g, f.seq, false, null);
        const out = settings_proto.edit(a, raw, f.ops, f.known) catch {
            g.notice("{s}: as configurações da conta vieram num formato que o app não entende", "{s}: the account settings came in a format the app doesn't understand", .{what});
            return done(g, f.seq, false, raw);
        } orelse return done(g, f.seq, true, raw);
        // Sem a versão (o formato mudou), o corpo vai sem ela.
        const version = status_proto.dataVersion(raw) catch null;
        const body = settings_proto.patchBody(a, out, version) catch return done(g, f.seq, false, raw);
        var resp = g.request("PATCH", "/users/@me/settings-proto/1", body) orelse {
            g.notice("{s}", "{s}", .{what});
            return done(g, f.seq, false, raw);
        };
        defer resp.body.deinit(alloc);
        if (resp.status >= 300) {
            g.noticeHttp(what, &resp);
            return done(g, f.seq, false, raw);
        }
        const v = std.json.parseFromSliceLeaky(Value, a, resp.body.items, .{}) catch null;
        const stale = if (v) |x| if (j.get(x, "out_of_date")) |o| o == .bool and o.bool else false else false;
        // A resposta traz as configurações como ficaram: é a cópia nova. Sem elas, a
        // versão da cópia ficou velha e a próxima gravação lê de novo.
        const saved = if (v) |x| if (j.str(j.get(x, "settings"))) |st| decode(a, st) else null else null;
        if (saved) |x| cache.set(x) else cache.forget();
        if (stale) {
            if (tries == 0) continue;
            g.notice("as configurações mudaram em outro aparelho: tente de novo", "the settings changed on another device: try again", .{});
            return done(g, f.seq, false, saved orelse raw);
        }
        return done(g, f.seq, true, saved orelse out);
    }
}

pub fn free(f: ev.FolderEdit) void {
    alloc.free(f.ops);
    alloc.free(f.known);
}
