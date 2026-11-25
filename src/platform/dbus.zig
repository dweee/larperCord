//! A libdbus-1 aberta na hora, sem dependência nova no build: o ícone da bandeja
//! (sni.zig, no processo do ícone), as notificações do sistema (notif_dbus.zig, numa
//! thread do app) e o servidor de notificações de mentira do QA usam a mesma tabela
//! de funções e os mesmos ajudantes para escrever e ler os argumentos.
const std = @import("std");
const c = @import("c");

pub const Conn = opaque {};
pub const Msg = opaque {};
pub const Pending = opaque {};
/// DBusMessageIter tem 72 bytes e DBusError, 32: os dois com folga.
pub const Iter = [16]u64;
pub const Err = extern struct { name: ?[*:0]const u8, message: ?[*:0]const u8, rest: [6]usize };

pub const Filter = *const fn (*Conn, *Msg, ?*anyopaque) callconv(.c) c_int;
pub const Notify = *const fn (*Pending, ?*anyopaque) callconv(.c) void;
pub const Free = *const fn (?*anyopaque) callconv(.c) void;

/// Os nomes dos campos são os das funções da libdbus.
pub const Fns = struct {
    dbus_threads_init_default: *const fn () callconv(.c) u32,
    dbus_error_init: *const fn (*Err) callconv(.c) void,
    dbus_error_free: *const fn (*Err) callconv(.c) void,
    dbus_bus_get_private: *const fn (c_int, ?*Err) callconv(.c) ?*Conn,
    dbus_bus_register: *const fn (*Conn, *Err) callconv(.c) u32,
    dbus_connection_open_private: *const fn ([*:0]const u8, *Err) callconv(.c) ?*Conn,
    dbus_bus_request_name: *const fn (*Conn, [*:0]const u8, c_uint, *Err) callconv(.c) c_int,
    dbus_bus_add_match: *const fn (*Conn, [*:0]const u8, *Err) callconv(.c) void,
    dbus_connection_set_exit_on_disconnect: *const fn (*Conn, u32) callconv(.c) void,
    dbus_connection_close: *const fn (*Conn) callconv(.c) void,
    dbus_connection_unref: *const fn (*Conn) callconv(.c) void,
    dbus_connection_add_filter: *const fn (*Conn, Filter, ?*anyopaque, ?*const anyopaque) callconv(.c) u32,
    dbus_connection_get_unix_fd: *const fn (*Conn, *c_int) callconv(.c) u32,
    dbus_connection_read_write: *const fn (*Conn, c_int) callconv(.c) u32,
    dbus_connection_pop_message: *const fn (*Conn) callconv(.c) ?*Msg,
    dbus_connection_dispatch: *const fn (*Conn) callconv(.c) c_int,
    dbus_connection_get_dispatch_status: *const fn (*Conn) callconv(.c) c_int,
    dbus_connection_flush: *const fn (*Conn) callconv(.c) void,
    dbus_connection_get_is_connected: *const fn (*Conn) callconv(.c) u32,
    dbus_connection_send: *const fn (*Conn, *Msg, ?*u32) callconv(.c) u32,
    dbus_connection_send_with_reply: *const fn (*Conn, *Msg, *?*Pending, c_int) callconv(.c) u32,
    dbus_connection_send_with_reply_and_block: *const fn (*Conn, *Msg, c_int, ?*Err) callconv(.c) ?*Msg,
    dbus_pending_call_set_notify: *const fn (*Pending, Notify, ?*anyopaque, ?Free) callconv(.c) u32,
    dbus_pending_call_steal_reply: *const fn (*Pending) callconv(.c) ?*Msg,
    dbus_pending_call_cancel: *const fn (*Pending) callconv(.c) void,
    dbus_pending_call_unref: *const fn (*Pending) callconv(.c) void,
    dbus_message_new_method_call: *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*Msg,
    dbus_message_new_method_return: *const fn (*Msg) callconv(.c) ?*Msg,
    dbus_message_new_error: *const fn (*Msg, [*:0]const u8, [*:0]const u8) callconv(.c) ?*Msg,
    dbus_message_new_signal: *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*Msg,
    dbus_message_set_no_reply: *const fn (*Msg, u32) callconv(.c) void,
    dbus_message_unref: *const fn (*Msg) callconv(.c) void,
    dbus_message_get_type: *const fn (*Msg) callconv(.c) c_int,
    dbus_message_get_path: *const fn (*Msg) callconv(.c) ?[*:0]const u8,
    dbus_message_get_interface: *const fn (*Msg) callconv(.c) ?[*:0]const u8,
    dbus_message_get_member: *const fn (*Msg) callconv(.c) ?[*:0]const u8,
    dbus_message_get_sender: *const fn (*Msg) callconv(.c) ?[*:0]const u8,
    dbus_message_get_error_name: *const fn (*Msg) callconv(.c) ?[*:0]const u8,
    dbus_message_get_no_reply: *const fn (*Msg) callconv(.c) u32,
    dbus_message_iter_init: *const fn (*Msg, *Iter) callconv(.c) u32,
    dbus_message_iter_get_arg_type: *const fn (*Iter) callconv(.c) c_int,
    dbus_message_iter_get_basic: *const fn (*Iter, *anyopaque) callconv(.c) void,
    dbus_message_iter_next: *const fn (*Iter) callconv(.c) u32,
    dbus_message_iter_recurse: *const fn (*Iter, *Iter) callconv(.c) void,
    dbus_message_iter_init_append: *const fn (*Msg, *Iter) callconv(.c) void,
    dbus_message_iter_append_basic: *const fn (*Iter, c_int, *const anyopaque) callconv(.c) u32,
    dbus_message_iter_append_fixed_array: *const fn (*Iter, c_int, *const anyopaque, c_int) callconv(.c) u32,
    dbus_message_iter_open_container: *const fn (*Iter, c_int, ?[*:0]const u8, *Iter) callconv(.c) u32,
    dbus_message_iter_close_container: *const fn (*Iter, *Iter) callconv(.c) u32,
};
pub var d: Fns = undefined;

pub const bus_session: c_int = 0;
pub const msg_method_call = 1;
pub const msg_method_return = 2;
pub const msg_error = 3;
pub const msg_signal = 4;
pub const handled: c_int = 0;
pub const not_yet: c_int = 1;
pub const dispatch_data_remains: c_int = 0;
pub const timeout_infinite: c_int = 0x7fffffff;
pub const name_do_not_queue: c_uint = 4;
pub const name_primary_owner: c_int = 1;

var tried = false;
var loaded = false;

/// Abre a biblioteca uma vez (as threads e o processo do ícone podem pedir de novo).
/// Falso: sem a libdbus-1 ou sem alguma função dela.
pub fn load() bool {
    if (tried) return loaded;
    tried = true;
    _ = loadInto(&d) orelse return false;
    // A conexão é de uma thread só, mas o SDL também fala com a libdbus nas dele.
    _ = d.dbus_threads_init_default();
    loaded = true;
    return true;
}

pub fn loadInto(functions: *Fns) ?*c.SDL_SharedObject {
    const lib = c.SDL_LoadObject("libdbus-1.so.3") orelse return null;
    inline for (@typeInfo(Fns).@"struct".field_names) |fname| {
        const sym = c.SDL_LoadFunction(lib, fname.ptr) orelse {
            c.SDL_UnloadObject(lib);
            return null;
        };
        @field(functions, fname) = @ptrCast(sym);
    }
    return lib;
}

/// Escreve os argumentos de uma mensagem.
pub const Out = struct {
    it: Iter = undefined,

    pub fn basic(o: *Out, t: u8, v: *const anyopaque) void {
        _ = d.dbus_message_iter_append_basic(&o.it, t, v);
    }
    pub fn str(o: *Out, s: [*:0]const u8) void {
        o.basic('s', @ptrCast(&s));
    }
    pub fn objPath(o: *Out, s: [*:0]const u8) void {
        o.basic('o', @ptrCast(&s));
    }
    pub fn int(o: *Out, v: i32) void {
        o.basic('i', @ptrCast(&v));
    }
    pub fn uint(o: *Out, v: u32) void {
        o.basic('u', @ptrCast(&v));
    }
    pub fn byte(o: *Out, v: u8) void {
        o.basic('y', @ptrCast(&v));
    }
    pub fn boolean(o: *Out, v: bool) void {
        const x: u32 = @intFromBool(v);
        o.basic('b', @ptrCast(&x));
    }
    pub fn open(o: *Out, sub: *Out, t: u8, sig: ?[*:0]const u8) void {
        _ = d.dbus_message_iter_open_container(&o.it, t, sig, &sub.it);
    }
    pub fn close(o: *Out, sub: *Out) void {
        _ = d.dbus_message_iter_close_container(&o.it, &sub.it);
    }
    pub fn bytes(o: *Out, data: []const u8) void {
        var arr: Out = .{};
        o.open(&arr, 'a', "y");
        const p: [*]const u8 = data.ptr;
        _ = d.dbus_message_iter_append_fixed_array(&arr.it, 'y', @ptrCast(&p), @intCast(data.len));
        o.close(&arr);
    }
    pub fn variantStr(o: *Out, s: [*:0]const u8) void {
        var v: Out = .{};
        o.open(&v, 'v', "s");
        v.str(s);
        o.close(&v);
    }
    pub fn variantBool(o: *Out, b: bool) void {
        var v: Out = .{};
        o.open(&v, 'v', "b");
        v.boolean(b);
        o.close(&v);
    }
    pub fn variantByte(o: *Out, b: u8) void {
        var v: Out = .{};
        o.open(&v, 'v', "y");
        v.byte(b);
        o.close(&v);
    }
    /// Uma entrada {sv} de um dicionário de propriedades: abre e escreve a chave; o
    /// valor (variante) vai em `e`, e `close(e)` fecha a entrada.
    pub fn entry(o: *Out, e: *Out, key: [*:0]const u8) void {
        o.open(e, 'e', null);
        e.str(key);
    }
};

/// Lê os argumentos de uma mensagem.
pub const In = struct {
    it: Iter = undefined,

    pub fn start(i: *In, msg: *Msg) bool {
        return d.dbus_message_iter_init(msg, &i.it) != 0;
    }
    pub fn kind(i: *In) u8 {
        return @truncate(@as(c_uint, @bitCast(d.dbus_message_iter_get_arg_type(&i.it))));
    }
    pub fn next(i: *In) void {
        _ = d.dbus_message_iter_next(&i.it);
    }
    pub fn recurse(i: *In, sub: *In) void {
        d.dbus_message_iter_recurse(&i.it, &sub.it);
    }
    pub fn str(i: *In) ?[]const u8 {
        if (i.kind() != 's' and i.kind() != 'o') return null;
        var p: [*:0]const u8 = undefined;
        d.dbus_message_iter_get_basic(&i.it, @ptrCast(&p));
        return std.mem.span(p);
    }
    pub fn int(i: *In) ?i32 {
        if (i.kind() != 'i') return null;
        var v: i32 = 0;
        d.dbus_message_iter_get_basic(&i.it, @ptrCast(&v));
        return v;
    }
    pub fn uint(i: *In) ?u32 {
        if (i.kind() != 'u') return null;
        var v: u32 = 0;
        d.dbus_message_iter_get_basic(&i.it, @ptrCast(&v));
        return v;
    }
    pub fn byte(i: *In) ?u8 {
        if (i.kind() != 'y') return null;
        var v: u8 = 0;
        d.dbus_message_iter_get_basic(&i.it, @ptrCast(&v));
        return v;
    }
};

pub fn span(p: ?[*:0]const u8) ?[]const u8 {
    return if (p) |s| std.mem.span(s) else null;
}
