//! Pastas da barra de servidores, do lado do app (core/pastas.zig): a barra muda na
//! hora (o Store guarda a mudança até a conta responder) e a conta grava.
//!
//! Uma gravação por mudança, mas mudanças seguidas (arrastar vários servidores em
//! sequência) viram uma só: a primeira depois de um tempo parado sai na hora; as que
//! vêm em menos de `delay_ms` esperam até `delay_ms` depois da última e saem juntas.
//! Sem relógio próprio: o laço do app acorda em `due()` só enquanto há algo esperando.
const std = @import("std");
const App = @import("app.zig").App;
const pastas = @import("core/pastas.zig");
const types = @import("core/types.zig");
const nowMs = @import("net/fake_gateway.zig").nowMs;
const Id = types.Id;

pub const delay_ms: i64 = 1000;

const ca = std.heap.c_allocator;

var batch: std.ArrayList(pastas.Op) = .empty;
/// O número (no Store) da última mudança do lote.
var batch_seq: u32 = 0;
var due_ms: i64 = std.math.maxInt(i64);
var last_ms: ?i64 = null;

pub fn handle(app: *App, op: pastas.Op) void {
    const seq = (app.store.editFolders(op) catch null) orelse return;
    batch.append(ca, op) catch {
        // Sem memória para guardar: a barra volta ao que a conta tem.
        app.store.apply(.{ .folders_saved = .{ .seq = seq, .ok = false } }, nowMs()) catch {};
        return;
    };
    batch_seq = seq;
    const now = nowMs();
    const quiet = if (last_ms) |l| now - l >= delay_ms else true;
    last_ms = now;
    if (quiet) send(app) else due_ms = now + delay_ms;
}

/// Hora de mandar o que esperava? (chamado a cada volta do laço do app)
pub fn pump(app: *App) void {
    if (nowMs() >= due_ms) send(app);
}

/// Quando o laço precisa acordar para `pump` (maxInt = nada esperando).
pub fn due() i64 {
    return due_ms;
}

fn send(app: *App) void {
    due_ms = std.math.maxInt(i64);
    if (batch.items.len == 0) return;
    defer batch.clearRetainingCapacity();
    // Sem rede (antes do login): o pedido não iria a lugar nenhum.
    if (app.net == .none) return dropped(app);
    const ops = ca.dupe(pastas.Op, batch.items) catch return dropped(app);
    const known = ca.alloc(Id, app.store.guilds.items.len) catch {
        ca.free(ops);
        return dropped(app);
    };
    for (app.store.guilds.items, known) |g, *k| k.* = g.id;
    app.cmd(.{ .folders = .{ .seq = batch_seq, .ops = ops, .known = known } });
}

fn dropped(app: *App) void {
    app.store.apply(.{ .folders_saved = .{ .seq = batch_seq, .ok = false } }, nowMs()) catch {};
}

/// Outra conta (ou sair): o que esperava não vai para a próxima.
pub fn reset() void {
    batch.clearRetainingCapacity();
    due_ms = std.math.maxInt(i64);
    last_ms = null;
}

/// Há mudança esperando para sair (o QA confere que a rajada vira uma gravação).
pub fn waiting() usize {
    return batch.items.len;
}
