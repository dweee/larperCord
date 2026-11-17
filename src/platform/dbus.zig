//! Símbolos da libdbus-1, aberta pelo SDL sem dependência no build.
const c = @import("c");

pub const Conn = opaque {};
pub const Msg = opaque {};
pub const Pending = opaque {};
/// DBusMessageIter tem 72 bytes e DBusError, 32: os dois com folga.
pub const Iter = [16]u64;
pub const Err = extern struct { name: ?[*:0]const u8, message: ?[*:0]const u8, rest: [6]usize };

const Filter = *const fn (*Conn, *Msg, ?*anyopaque) callconv(.c) c_int;
const Notify = *const fn (*Pending, ?*anyopaque) callconv(.c) void;

/// Os nomes dos campos são os das funções da libdbus.
pub const Fns = struct {
    dbus_threads_init_default: *const fn () callconv(.c) u32,
    dbus_error_init: *const fn (*Err) callconv(.c) void,
    dbus_error_free: *const fn (*Err) callconv(.c) void,
    dbus_bus_get_private: *const fn (c_int, ?*Err) callconv(.c) ?*Conn,
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
    dbus_pending_call_set_notify: *const fn (*Pending, Notify, ?*anyopaque, ?*const anyopaque) callconv(.c) u32,
    dbus_pending_call_steal_reply: *const fn (*Pending) callconv(.c) ?*Msg,
    dbus_pending_call_cancel: *const fn (*Pending) callconv(.c) void,
    dbus_pending_call_unref: *const fn (*Pending) callconv(.c) void,
    dbus_message_new_method_call: *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*Msg,
    dbus_message_new_method_return: *const fn (*Msg) callconv(.c) ?*Msg,
    dbus_message_new_error: *const fn (*Msg, [*:0]const u8, [*:0]const u8) callconv(.c) ?*Msg,
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

pub fn load(d: *Fns) ?*c.SDL_SharedObject {
    const lib = c.SDL_LoadObject("libdbus-1.so.3") orelse return null;
    inline for (@typeInfo(Fns).@"struct".field_names) |fname| {
        const sym = c.SDL_LoadFunction(lib, fname.ptr) orelse {
            c.SDL_UnloadObject(lib);
            return null;
        };
        @field(d, fname) = @ptrCast(sym);
    }
    return lib;
}
