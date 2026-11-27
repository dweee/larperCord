//! O que o Inspetor guarda do que passa pelo app enquanto grava: cada pedido HTTP (da API
//! do Discord, das imagens, dos plugins, do atualizador), cada quadro do gateway e do
//! gateway de voz, cada linha de log e cada mensagem entre a interface, o app e a rede.
//!
//! Só em memória, com teto de quantidade e de bytes (o mais velho sai primeiro), e só
//! enquanto `gravando()`: parado, cada ponto de gravação paga a leitura de um booleano.
//! O token nunca entra: o cabeçalho Authorization não é guardado, o "token" do IDENTIFY,
//! do RESUME e do gateway de voz vira asteriscos, e tudo passa pelo `scrub` do registro de
//! depuração (que apaga qualquer coisa com cara de token). Várias threads gravam (rede,
//! imagens, plugins, voz, log): cada lista tem a sua trava.
const std = @import("std");
const builtin = @import("builtin");
const debug_log = @import("../platform/debug_log.zig");
const descreve = @import("descreve.zig");
// O app trava e mede o tempo com o SDL, como o resto do código; os testes (sem SDL) com a
// biblioteca padrão (como em plugins/sync.zig).
const c = if (builtin.is_test) struct {} else @import("c");
const io = std.Options.debug_io;

const gpa = std.heap.c_allocator;

var rec: std.atomic.Value(bool) = .init(false);

pub inline fn gravando() bool {
    return rec.load(.monotonic);
}

pub fn gravar(on: bool) void {
    rec.store(on, .monotonic);
}

/// Hora do relógio (ms desde 1970), a que aparece nas listas.
pub fn agoraMs() i64 {
    if (builtin.is_test) return std.Io.Clock.real.now(io).toMilliseconds();
    var ns: c.SDL_Time = 0;
    if (!c.SDL_GetCurrentTime(&ns)) return 0;
    return @divTrunc(ns, std.time.ns_per_ms);
}

/// Contador para o "Tempo" relativo das listas e para as durações.
pub fn ticksUs() u64 {
    if (builtin.is_test) return @intCast(@max(0, std.Io.Clock.awake.now(io).toMicroseconds()));
    return c.SDL_GetTicksNS() / 1000;
}

const Lock = if (builtin.is_test) struct {
    m: std.Io.Mutex = .init,

    fn get(l: *@This()) void {
        l.m.lockUncancelable(io);
    }

    fn put(l: *@This()) void {
        l.m.unlock(io);
    }
} else struct {
    m: ?*c.SDL_Mutex = null,

    fn get(l: *@This()) void {
        // Criada na primeira gravação; antes disso ninguém gravou nem leu. Duas threads
        // gravando pela primeira vez ao mesmo tempo é coisa que não acontece: a gravação
        // liga na thread da interface e o primeiro registro vem depois.
        if (l.m == null) l.m = c.SDL_CreateMutex();
        c.SDL_LockMutex(l.m);
    }

    fn put(l: *@This()) void {
        c.SDL_UnlockMutex(l.m);
    }
};

/// Cópia que fica com o registro (o original é de quem gravou e pode sumir).
fn dup(s: []const u8, cap: usize) []u8 {
    const n = @min(s.len, cap);
    const out = gpa.alloc(u8, n) catch return &.{};
    @memcpy(out, s[0..n]);
    debug_log.scrub(out);
    return out;
}

fn free(s: []u8) void {
    if (s.len > 0) gpa.free(s);
}

/// O valor de `"token":"…"` (onde houver) vira asteriscos, sem mudar o tamanho.
pub fn hideToken(s: []u8) void {
    const key = "\"token\":";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, s, from, key)) |i| {
        var k = i + key.len;
        while (k < s.len and s[k] == ' ') k += 1;
        if (k >= s.len or s[k] != '"') {
            from = k;
            continue;
        }
        k += 1;
        while (k < s.len and s[k] != '"') : (k += 1) {
            if (s[k] == '\\' and k + 1 < s.len) {
                s[k] = '*';
                k += 1;
            }
            s[k] = '*';
        }
        from = k;
    }
}

// --- Rede ---------------------------------------------------------------------

pub const NetKind = enum(u8) { api, media, plugin, update, other };

pub const Net = struct {
    id: u32 = 0,
    kind: NetKind = .other,
    method: [8]u8 = @splat(0),
    url: []u8 = &.{},
    status: u16 = 0,
    pending: bool = true,
    /// Falhou sem resposta (sem conexão, cancelado, tempo esgotado).
    failed: bool = false,
    started_ms: i64 = 0,
    start_us: u64 = 0,
    dur_us: u64 = 0,
    // Do curl: até resolver o nome, conectar, terminar o TLS, o primeiro byte e o fim (µs).
    t_dns: u32 = 0,
    t_connect: u32 = 0,
    t_tls: u32 = 0,
    t_first: u32 = 0,
    t_total: u32 = 0,
    http: u8 = 0,
    attempt: u8 = 0,
    /// Quanto o pedido esperou o rate limit (ou um 429) antes de sair.
    waited_ms: u32 = 0,
    req_headers: []u8 = &.{},
    req_body: []u8 = &.{},
    req_len: usize = 0,
    resp_headers: []u8 = &.{},
    resp_body: []u8 = &.{},
    resp_len: usize = 0,
    content_type: [64]u8 = @splat(0),
    note: [96]u8 = @splat(0),
    thread: [16]u8 = @splat(0),

    pub fn methodStr(n: *const Net) []const u8 {
        return std.mem.sliceTo(&n.method, 0);
    }
    pub fn contentType(n: *const Net) []const u8 {
        return std.mem.sliceTo(&n.content_type, 0);
    }
    pub fn noteStr(n: *const Net) []const u8 {
        return std.mem.sliceTo(&n.note, 0);
    }
    pub fn threadStr(n: *const Net) []const u8 {
        return std.mem.sliceTo(&n.thread, 0);
    }
    pub fn bytes(n: *const Net) usize {
        return n.req_headers.len + n.req_body.len + n.resp_headers.len + n.resp_body.len + n.url.len;
    }

    fn release(n: *Net) void {
        free(n.url);
        free(n.req_headers);
        free(n.req_body);
        free(n.resp_headers);
        free(n.resp_body);
        n.* = .{};
    }
};

/// Quanto guardar de cada corpo: o suficiente para ler qualquer resposta da API; uma
/// imagem não precisa do corpo (o painel mostra a imagem pelo cache do app).
pub const body_cap = 512 * 1024;
const net_slots = 1500;
const net_budget = 32 * 1024 * 1024;

pub const NetLog = struct {
    lock: Lock = .{},
    /// Alocados na primeira gravação: quem nunca abre o Inspetor não paga nada.
    slots: []Net = &.{},
    /// Quantos já entraram desde o começo (o próximo id); o slot é `id % net_slots`.
    next: u32 = 1,
    bytes: usize = 0,
    /// Muda a cada gravação (quem desenha a lista sabe quando refazer o filtro).
    rev: std.atomic.Value(u32) = .init(0),
    cleared_at: u32 = 1,

    fn slot(l: *NetLog, id: u32) *Net {
        return &l.slots[id % net_slots];
    }

    fn ensure(l: *NetLog) bool {
        if (l.slots.len > 0) return true;
        const s = gpa.alloc(Net, net_slots) catch return false;
        @memset(s, .{});
        l.slots = s;
        return true;
    }

    /// Começa um pedido. Devolve o id (0 = não gravando) para `end`.
    pub fn begin(l: *NetLog, kind: NetKind, method: []const u8, url: []const u8, req_headers: []const u8, req_body: ?[]const u8, thread: []const u8) u32 {
        if (!gravando()) return 0;
        l.lock.get();
        defer l.lock.put();
        if (!l.ensure()) return 0;
        const id = l.next;
        l.next +%= 1;
        if (l.next == 0) l.next = 1;
        const s = l.slot(id);
        l.bytes -|= s.bytes();
        s.release();
        s.id = id;
        s.kind = kind;
        const m = @min(method.len, s.method.len);
        @memcpy(s.method[0..m], method[0..m]);
        s.url = dup(url, 4096);
        s.req_headers = dup(req_headers, 16 * 1024);
        if (req_body) |b| {
            s.req_len = b.len;
            s.req_body = dup(b, body_cap);
        }
        s.started_ms = agoraMs();
        s.start_us = ticksUs();
        const tn = @min(thread.len, s.thread.len);
        @memcpy(s.thread[0..tn], thread[0..tn]);
        l.bytes += s.bytes();
        l.trim();
        _ = l.rev.fetchAdd(1, .monotonic);
        return id;
    }

    pub const End = struct {
        status: u16 = 0,
        failed: bool = false,
        resp_headers: []const u8 = "",
        resp_body: ?[]const u8 = null,
        resp_len: ?usize = null,
        content_type: []const u8 = "",
        note: []const u8 = "",
        attempt: u8 = 0,
        http: u8 = 0,
        waited_ms: u32 = 0,
        t_dns: u32 = 0,
        t_connect: u32 = 0,
        t_tls: u32 = 0,
        t_first: u32 = 0,
        t_total: u32 = 0,
    };

    pub fn end(l: *NetLog, id: u32, e: End) void {
        if (id == 0) return;
        l.lock.get();
        defer l.lock.put();
        if (l.slots.len == 0) return;
        const s = l.slot(id);
        // O slot já foi reaproveitado por um pedido mais novo.
        if (s.id != id) return;
        l.bytes -|= s.bytes();
        s.pending = false;
        s.failed = e.failed;
        s.status = e.status;
        s.dur_us = ticksUs() -| s.start_us;
        free(s.resp_headers);
        s.resp_headers = dup(e.resp_headers, 16 * 1024);
        free(s.resp_body);
        s.resp_body = &.{};
        if (e.resp_body) |b| {
            s.resp_body = dup(b, body_cap);
            s.resp_len = b.len;
        }
        if (e.resp_len) |n| s.resp_len = n;
        const ct = @min(e.content_type.len, s.content_type.len - 1);
        @memset(&s.content_type, 0);
        @memcpy(s.content_type[0..ct], e.content_type[0..ct]);
        const nt = @min(e.note.len, s.note.len - 1);
        @memset(&s.note, 0);
        @memcpy(s.note[0..nt], e.note[0..nt]);
        s.attempt = e.attempt;
        s.http = e.http;
        s.waited_ms = e.waited_ms;
        s.t_dns = e.t_dns;
        s.t_connect = e.t_connect;
        s.t_tls = e.t_tls;
        s.t_first = e.t_first;
        s.t_total = e.t_total;
        l.bytes += s.bytes();
        l.trim();
        _ = l.rev.fetchAdd(1, .monotonic);
    }

    /// Passou do teto de bytes: os corpos dos mais velhos saem (a linha fica).
    fn trim(l: *NetLog) void {
        if (l.bytes <= net_budget) return;
        var id = l.oldest();
        while (l.bytes > net_budget and id != l.next) : (id +%= 1) {
            const s = l.slot(id);
            if (s.id != id) continue;
            l.bytes -|= s.resp_body.len + s.req_body.len;
            free(s.resp_body);
            free(s.req_body);
            s.resp_body = &.{};
            s.req_body = &.{};
        }
    }

    pub fn oldest(l: *const NetLog) u32 {
        const lo = if (l.next > net_slots) l.next - net_slots else 1;
        return @max(lo, l.cleared_at);
    }

    pub fn clear(l: *NetLog) void {
        l.lock.get();
        defer l.lock.put();
        l.cleared_at = l.next;
        _ = l.rev.fetchAdd(1, .monotonic);
    }

    /// Lê com a trava: `f` recebe cada registro do mais velho ao mais novo.
    /// Como `each`, só a partir do id `from` (quem já viu os anteriores).
    pub fn eachFrom(l: *NetLog, from: u32, ctx: anytype, comptime f: fn (@TypeOf(ctx), *const Net) void) void {
        l.lock.get();
        defer l.lock.put();
        if (l.slots.len == 0) return;
        var id = @max(l.oldest(), from);
        while (id != l.next and id < l.next) : (id +%= 1) {
            const s = l.slot(id);
            if (s.id == id) f(ctx, s);
        }
    }

    pub fn first(l: *NetLog) u32 {
        l.lock.get();
        defer l.lock.put();
        return l.oldest();
    }

    pub fn each(l: *NetLog, ctx: anytype, comptime f: fn (@TypeOf(ctx), *const Net) void) void {
        l.lock.get();
        defer l.lock.put();
        if (l.slots.len == 0) return;
        var id = l.oldest();
        while (id != l.next) : (id +%= 1) {
            const s = l.slot(id);
            if (s.id == id) f(ctx, s);
        }
    }

    /// Uma cópia (com os textos copiados também) para a interface ler sem a trava.
    pub fn copy(l: *NetLog, id: u32, out: *Net) bool {
        l.lock.get();
        defer l.lock.put();
        if (l.slots.len == 0) return false;
        const s = l.slot(id);
        if (s.id != id) return false;
        out.* = s.*;
        out.url = gpa.dupe(u8, s.url) catch &.{};
        out.req_headers = gpa.dupe(u8, s.req_headers) catch &.{};
        out.req_body = gpa.dupe(u8, s.req_body) catch &.{};
        out.resp_headers = gpa.dupe(u8, s.resp_headers) catch &.{};
        out.resp_body = gpa.dupe(u8, s.resp_body) catch &.{};
        return true;
    }

    pub fn freeCopy(n: *Net) void {
        n.release();
    }
};

pub var net: NetLog = .{};

// --- Gateway ------------------------------------------------------------------

pub const Conn = enum(u8) { main, voice };
pub const Dir = enum(u8) { in, out };

pub const Gw = struct {
    id: u32 = 0,
    conn: Conn = .main,
    dir: Dir = .in,
    time_ms: i64 = 0,
    us: u64 = 0,
    op: i16 = -1,
    seq: i64 = -1,
    /// Nome do evento (só no op 0 do gateway principal).
    t: [40]u8 = @splat(0),
    size: u32 = 0,
    payload: []u8 = &.{},

    pub fn name(g: *const Gw) []const u8 {
        return std.mem.sliceTo(&g.t, 0);
    }
};

const gw_slots = 6000;
pub const gw_frame_cap = 2 * 1024 * 1024;
const gw_budget = 48 * 1024 * 1024;

pub const GwLog = struct {
    lock: Lock = .{},
    /// Alocados na primeira gravação: quem nunca abre o Inspetor não paga nada.
    slots: []Gw = &.{},
    next: u32 = 1,
    bytes: usize = 0,
    rev: std.atomic.Value(u32) = .init(0),
    cleared_at: u32 = 1,
    /// Bytes que entraram e saíram (desde o começo da gravação), por conexão.
    bytes_in: [2]u64 = .{ 0, 0 },
    bytes_out: [2]u64 = .{ 0, 0 },

    fn slot(l: *GwLog, id: u32) *Gw {
        return &l.slots[id % gw_slots];
    }

    fn ensure(l: *GwLog) bool {
        if (l.slots.len > 0) return true;
        const s = gpa.alloc(Gw, gw_slots) catch return false;
        @memset(s, .{});
        l.slots = s;
        return true;
    }

    pub fn add(l: *GwLog, conn: Conn, dir: Dir, payload: []const u8, op: i64, seq: ?i64, event_name: ?[]const u8) void {
        if (!gravando()) return;
        l.lock.get();
        defer l.lock.put();
        if (!l.ensure()) return;
        const id = l.next;
        l.next +%= 1;
        if (l.next == 0) l.next = 1;
        const s = l.slot(id);
        l.bytes -|= s.payload.len;
        free(s.payload);
        s.* = .{ .id = id, .conn = conn, .dir = dir, .time_ms = agoraMs(), .us = ticksUs(), .op = @intCast(std.math.clamp(op, -1, 32767)), .seq = seq orelse -1, .size = @intCast(@min(payload.len, std.math.maxInt(u32))) };
        if (event_name) |name| {
            const n = @min(name.len, s.t.len - 1);
            @memcpy(s.t[0..n], name[0..n]);
        }
        s.payload = dup(payload, gw_frame_cap);
        hideToken(s.payload);
        l.bytes += s.payload.len;
        if (dir == .in) l.bytes_in[@intFromEnum(conn)] += payload.len else l.bytes_out[@intFromEnum(conn)] += payload.len;
        // Passou do teto: o conteúdo dos mais velhos sai (a linha fica).
        var old = l.oldest();
        while (l.bytes > gw_budget and old != l.next) : (old +%= 1) {
            const o = l.slot(old);
            if (o.id != old) continue;
            l.bytes -|= o.payload.len;
            free(o.payload);
            o.payload = &.{};
        }
        _ = l.rev.fetchAdd(1, .monotonic);
    }

    pub fn oldest(l: *const GwLog) u32 {
        const lo = if (l.next > gw_slots) l.next - gw_slots else 1;
        return @max(lo, l.cleared_at);
    }

    pub fn clear(l: *GwLog) void {
        l.lock.get();
        defer l.lock.put();
        l.cleared_at = l.next;
        _ = l.rev.fetchAdd(1, .monotonic);
    }

    /// Como `each`, só a partir do id `from` (quem já viu os anteriores).
    pub fn eachFrom(l: *GwLog, from: u32, ctx: anytype, comptime f: fn (@TypeOf(ctx), *const Gw) void) void {
        l.lock.get();
        defer l.lock.put();
        if (l.slots.len == 0) return;
        var id = @max(l.oldest(), from);
        while (id != l.next and id < l.next) : (id +%= 1) {
            const s = l.slot(id);
            if (s.id == id) f(ctx, s);
        }
    }

    pub fn first(l: *GwLog) u32 {
        l.lock.get();
        defer l.lock.put();
        return l.oldest();
    }

    pub fn each(l: *GwLog, ctx: anytype, comptime f: fn (@TypeOf(ctx), *const Gw) void) void {
        l.lock.get();
        defer l.lock.put();
        if (l.slots.len == 0) return;
        var id = l.oldest();
        while (id != l.next) : (id +%= 1) {
            const s = l.slot(id);
            if (s.id == id) f(ctx, s);
        }
    }

    /// O conteúdo de um quadro, copiado (a interface lê sem a trava).
    pub fn payloadCopy(l: *GwLog, id: u32) ?[]u8 {
        l.lock.get();
        defer l.lock.put();
        if (l.slots.len == 0) return null;
        const s = l.slot(id);
        if (s.id != id) return null;
        return gpa.dupe(u8, s.payload) catch null;
    }
};

pub var gw: GwLog = .{};

/// Quadro do gateway que saiu: o op vem do começo (`{"op":N`), como o app monta.
pub fn gwOut(conn: Conn, payload: []const u8) void {
    if (!gravando()) return;
    var op: i64 = -1;
    const head = "{\"op\":";
    if (std.mem.startsWith(u8, payload, head)) {
        var e = head.len;
        while (e < payload.len and std.ascii.isDigit(payload[e])) e += 1;
        op = std.fmt.parseInt(i64, payload[head.len..e], 10) catch -1;
    }
    gw.add(conn, .out, payload, op, null, null);
}

// --- Console ------------------------------------------------------------------

pub const Level = enum(u8) { debug, info, warn, err };

pub const Line = struct {
    id: u32 = 0,
    time_ms: i64 = 0,
    level: Level = .info,
    scope: [16]u8 = @splat(0),
    text: []u8 = &.{},

    pub fn scopeStr(l: *const Line) []const u8 {
        return std.mem.sliceTo(&l.scope, 0);
    }
};

const line_slots = 8000;

pub const LineLog = struct {
    lock: Lock = .{},
    /// Alocados na primeira gravação: quem nunca abre o Inspetor não paga nada.
    slots: []Line = &.{},
    next: u32 = 1,
    rev: std.atomic.Value(u32) = .init(0),
    cleared_at: u32 = 1,
    counts: [4]u32 = @splat(0),

    fn slot(l: *LineLog, id: u32) *Line {
        return &l.slots[id % line_slots];
    }

    fn ensure(l: *LineLog) bool {
        if (l.slots.len > 0) return true;
        const s = gpa.alloc(Line, line_slots) catch return false;
        @memset(s, .{});
        l.slots = s;
        return true;
    }

    pub fn add(l: *LineLog, level: Level, scope: []const u8, text: []const u8) void {
        if (!gravando()) return;
        l.lock.get();
        defer l.lock.put();
        if (!l.ensure()) return;
        const id = l.next;
        l.next +%= 1;
        if (l.next == 0) l.next = 1;
        const s = l.slot(id);
        free(s.text);
        s.* = .{ .id = id, .time_ms = agoraMs(), .level = level };
        const n = @min(scope.len, s.scope.len - 1);
        @memcpy(s.scope[0..n], scope[0..n]);
        s.text = dup(std.mem.trimEnd(u8, text, "\n"), 4096);
        l.counts[@intFromEnum(level)] += 1;
        _ = l.rev.fetchAdd(1, .monotonic);
    }

    pub fn oldest(l: *const LineLog) u32 {
        const lo = if (l.next > line_slots) l.next - line_slots else 1;
        return @max(lo, l.cleared_at);
    }

    pub fn clear(l: *LineLog) void {
        l.lock.get();
        defer l.lock.put();
        l.cleared_at = l.next;
        l.counts = @splat(0);
        _ = l.rev.fetchAdd(1, .monotonic);
    }

    /// Como `each`, só a partir do id `from` (quem já viu os anteriores).
    pub fn eachFrom(l: *LineLog, from: u32, ctx: anytype, comptime f: fn (@TypeOf(ctx), *const Line) void) void {
        l.lock.get();
        defer l.lock.put();
        if (l.slots.len == 0) return;
        var id = @max(l.oldest(), from);
        while (id != l.next and id < l.next) : (id +%= 1) {
            const s = l.slot(id);
            if (s.id == id) f(ctx, s);
        }
    }

    pub fn first(l: *LineLog) u32 {
        l.lock.get();
        defer l.lock.put();
        return l.oldest();
    }

    pub fn each(l: *LineLog, ctx: anytype, comptime f: fn (@TypeOf(ctx), *const Line) void) void {
        l.lock.get();
        defer l.lock.put();
        if (l.slots.len == 0) return;
        var id = l.oldest();
        while (id != l.next) : (id +%= 1) {
            const s = l.slot(id);
            if (s.id == id) f(ctx, s);
        }
    }
};

pub var lines: LineLog = .{};

/// Chamado pelo `logFn` (platform/debug_log.zig) com a linha já formatada.
pub fn logLine(comptime level: std.log.Level, scope: []const u8, text: []const u8) void {
    lines.add(switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    }, scope, text);
}

// --- Eventos internos (interface → app → rede → app) ----------------------------

pub const EvKind = enum(u8) { action, command, event };

pub const Ev = struct {
    id: u32 = 0,
    time_ms: i64 = 0,
    kind: EvKind = .action,
    tag: []const u8 = "",
    text: []u8 = &.{},
};

const ev_slots = 5000;

pub const EvLog = struct {
    lock: Lock = .{},
    /// Alocados na primeira gravação: quem nunca abre o Inspetor não paga nada.
    slots: []Ev = &.{},
    next: u32 = 1,
    rev: std.atomic.Value(u32) = .init(0),
    cleared_at: u32 = 1,

    fn slot(l: *EvLog, id: u32) *Ev {
        return &l.slots[id % ev_slots];
    }

    fn ensure(l: *EvLog) bool {
        if (l.slots.len > 0) return true;
        const s = gpa.alloc(Ev, ev_slots) catch return false;
        @memset(s, .{});
        l.slots = s;
        return true;
    }

    pub fn add(l: *EvLog, kind: EvKind, tag: []const u8, text: []const u8) void {
        if (!gravando()) return;
        l.lock.get();
        defer l.lock.put();
        if (!l.ensure()) return;
        const id = l.next;
        l.next +%= 1;
        if (l.next == 0) l.next = 1;
        const s = l.slot(id);
        free(s.text);
        s.* = .{ .id = id, .time_ms = agoraMs(), .kind = kind, .tag = tag, .text = dup(text, 2048) };
        _ = l.rev.fetchAdd(1, .monotonic);
    }

    pub fn oldest(l: *const EvLog) u32 {
        const lo = if (l.next > ev_slots) l.next - ev_slots else 1;
        return @max(lo, l.cleared_at);
    }

    pub fn clear(l: *EvLog) void {
        l.lock.get();
        defer l.lock.put();
        l.cleared_at = l.next;
        _ = l.rev.fetchAdd(1, .monotonic);
    }

    /// Como `each`, só a partir do id `from` (quem já viu os anteriores).
    pub fn eachFrom(l: *EvLog, from: u32, ctx: anytype, comptime f: fn (@TypeOf(ctx), *const Ev) void) void {
        l.lock.get();
        defer l.lock.put();
        if (l.slots.len == 0) return;
        var id = @max(l.oldest(), from);
        while (id != l.next and id < l.next) : (id +%= 1) {
            const s = l.slot(id);
            if (s.id == id) f(ctx, s);
        }
    }

    pub fn first(l: *EvLog) u32 {
        l.lock.get();
        defer l.lock.put();
        return l.oldest();
    }

    pub fn each(l: *EvLog, ctx: anytype, comptime f: fn (@TypeOf(ctx), *const Ev) void) void {
        l.lock.get();
        defer l.lock.put();
        if (l.slots.len == 0) return;
        var id = l.oldest();
        while (id != l.next) : (id +%= 1) {
            const s = l.slot(id);
            if (s.id == id) f(ctx, s);
        }
    }
};

pub var evs: EvLog = .{};

/// Uma mensagem do barramento (event.zig) em texto curto: a etiqueta e os campos, com
/// textos entre aspas, listas resumidas e profundidade limitada (descreve.zig).
pub fn evento(kind: EvKind, value: anytype) void {
    if (!gravando()) return;
    var buf: [1536]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const T = @TypeOf(value);
    const tag: []const u8 = switch (@typeInfo(T)) {
        .@"union" => descreve.uniao(&w, value),
        // Uma etiqueta sem dados (`.quit`) que ainda não virou a união.
        .@"enum" => @tagName(value),
        else => blk: {
            descreve.valor(&w, value);
            break :blk @typeName(T);
        },
    };
    evs.add(kind, tag, w.buffered());
}

const t = std.testing;

test "token do IDENTIFY, do RESUME e da voz vira asterisco" {
    var p = "{\"op\":2,\"d\":{\"token\":\"abc.def\",\"x\":1}}".*;
    hideToken(&p);
    try t.expectEqualStrings("{\"op\":2,\"d\":{\"token\":\"*******\",\"x\":1}}", &p);
    var r = "{\"op\":6,\"d\":{\"token\": \"q\\\"z\",\"session_id\":\"s\"}}".*;
    hideToken(&r);
    try t.expect(std.mem.indexOf(u8, &r, "q") == null);
    try t.expect(std.mem.indexOf(u8, &r, "session_id") != null);
    // Sem token: nada muda.
    var n = "{\"op\":1,\"d\":42}".*;
    hideToken(&n);
    try t.expectEqualStrings("{\"op\":1,\"d\":42}", &n);
}

test "rede: começo e fim, sem gravar nada parado, e o slot reaproveitado" {
    gravar(false);
    try t.expectEqual(@as(u32, 0), net.begin(.api, "GET", "/users/@me", "", null, "rede"));
    gravar(true);
    defer gravar(false);
    const id = net.begin(.api, "POST", "/channels/1/messages", "Content-Type: application/json\n", "{\"content\":\"oi\"}", "rede");
    try t.expect(id != 0);
    net.end(id, .{ .status = 200, .resp_body = "{\"id\":\"9\"}", .content_type = "application/json" });
    var got: Net = .{};
    try t.expect(net.copy(id, &got));
    defer NetLog.freeCopy(&got);
    try t.expectEqual(@as(u16, 200), got.status);
    try t.expect(!got.pending);
    try t.expectEqualStrings("{\"id\":\"9\"}", got.resp_body);
    try t.expectEqualStrings("POST", got.methodStr());
    // Um fim que chega depois de o slot ter sido reaproveitado não estraga o novo.
    net.end(id +% net_slots, .{ .status = 500 });
    try t.expectEqual(@as(u16, 200), net.slot(id).status);
}

test "evento curto: etiqueta, campos, textos entre aspas e listas resumidas" {
    gravar(true);
    defer gravar(false);
    const U = union(enum) { send: struct { channel: u64, text: []const u8, files: []const []const u8 }, quit };
    evento(.action, U{ .send = .{ .channel = 7, .text = "oi", .files = &.{ "a", "b" } } });
    const e = evs.slot(evs.next - 1);
    try t.expectEqualStrings("send", e.tag);
    try t.expectEqualStrings("{channel=7, text=\"oi\", files=[2]}", e.text);
    evento(.action, U.quit);
    try t.expectEqualStrings("quit", evs.slot(evs.next - 1).tag);
}
