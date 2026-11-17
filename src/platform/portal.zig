//! Transporte dos portais do desktop. A conexão privada pertence à interface.
const std = @import("std");
const c = @import("c");
const dbus = @import("dbus.zig");
const sys = @import("sys.zig");
const window = @import("window.zig");

pub const service = "org.freedesktop.portal.Desktop";
pub const desktop = "/org/freedesktop/portal/desktop";
pub const Msg = dbus.Msg;

const dbus_service = "org.freedesktop.DBus";

pub const Text = struct {
    buf: [256]u8 = @splat(0),
    len: usize = 0,

    pub fn set(p: *Text, value: [*:0]const u8) bool {
        const s = std.mem.span(value);
        if (s.len >= p.buf.len) return false;
        @memcpy(p.buf[0..s.len], s);
        p.buf[s.len] = 0;
        p.len = s.len;
        return true;
    }

    pub fn slice(p: *const Text) [:0]const u8 {
        return p.buf[0..p.len :0];
    }
};

/// O SDL não espera um descritor do D-Bus. Esta thread só vigia o socket;
/// a thread da janela continua sendo a única que usa a conexão.
const Watch = struct {
    stop: sys.Wake,
    ack: *c.SDL_Semaphore,
    fd: c_int,
    wake_type: u32,
    thread: *c.SDL_Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),
    waiting: std.atomic.Value(bool) = .init(false),

    fn start(fd: c_int, wake_type: u32) error{Watch}!*Watch {
        var stop = sys.Wake.open();
        if (!sys.valid(stop.read)) return error.Watch;
        errdefer stop.close();
        const ack = c.SDL_CreateSemaphore(0) orelse return error.Watch;
        errdefer c.SDL_DestroySemaphore(ack);
        const w = std.heap.c_allocator.create(Watch) catch return error.Watch;
        errdefer std.heap.c_allocator.destroy(w);
        w.* = .{ .stop = stop, .ack = ack, .fd = fd, .wake_type = wake_type };
        w.thread = c.SDL_CreateThread(run, "portal", w) orelse return error.Watch;
        return w;
    }

    fn close(w: *Watch) void {
        w.done.store(true, .release);
        sys.wakeSignal(w.stop.write);
        c.SDL_SignalSemaphore(w.ack);
        c.SDL_WaitThread(w.thread, null);
        w.stop.close();
        c.SDL_DestroySemaphore(w.ack);
        std.heap.c_allocator.destroy(w);
    }

    fn run(data: ?*anyopaque) callconv(.c) c_int {
        const w: *Watch = @ptrCast(@alignCast(data.?));
        var fds = [_]c.struct_pollfd{
            .{ .fd = w.stop.read, .events = c.POLLIN, .revents = 0 },
            .{ .fd = w.fd, .events = c.POLLIN, .revents = 0 },
        };
        while (!w.done.load(.acquire)) {
            if (c.poll(&fds, fds.len, -1) < 0) {
                if (std.c.errno(-1) == .INTR) continue;
                break;
            }
            if (fds[0].revents != 0) break;
            if (fds[1].revents == 0) continue;
            w.waiting.store(true, .release);
            var ev = std.mem.zeroes(c.SDL_Event);
            ev.type = w.wake_type;
            ev.user.code = @backingInt(window.Wake.portal);
            while (!w.done.load(.acquire) and !c.SDL_PushEvent(&ev)) c.SDL_Delay(10);
            c.SDL_WaitSemaphore(w.ack);
            if (w.done.load(.acquire)) break;
        }
        return 0;
    }

    fn drained(w: *Watch) void {
        if (w.waiting.swap(false, .acq_rel)) c.SDL_SignalSemaphore(w.ack);
    }
};

pub const Bus = struct {
    d: dbus.Fns,
    lib: *c.SDL_SharedObject,
    conn: *dbus.Conn,
    watch: *Watch,

    pub fn open(wake_type: u32) ?Bus {
        var d: dbus.Fns = undefined;
        const lib = dbus.load(&d) orelse return null;
        if (d.dbus_threads_init_default() == 0) {
            c.SDL_UnloadObject(lib);
            return null;
        }
        const conn = d.dbus_bus_get_private(0, null) orelse {
            c.SDL_UnloadObject(lib);
            return null;
        };
        d.dbus_connection_set_exit_on_disconnect(conn, 0);
        var fd: c_int = -1;
        const watch = if (d.dbus_connection_get_unix_fd(conn, &fd) != 0)
            Watch.start(fd, wake_type) catch null
        else
            null;
        if (watch == null) {
            d.dbus_connection_close(conn);
            d.dbus_connection_unref(conn);
            c.SDL_UnloadObject(lib);
            return null;
        }
        return .{ .d = d, .lib = lib, .conn = conn, .watch = watch.? };
    }

    pub fn close(b: *Bus) void {
        b.watch.close();
        b.d.dbus_connection_close(b.conn);
        b.d.dbus_connection_unref(b.conn);
        c.SDL_UnloadObject(b.lib);
    }

    pub fn drained(b: *Bus) void {
        b.watch.drained();
    }

    pub fn match(b: *Bus, comptime iface: []const u8) bool {
        var err: dbus.Err = undefined;
        b.d.dbus_error_init(&err);
        defer b.d.dbus_error_free(&err);
        b.d.dbus_bus_add_match(b.conn, "type='signal',sender='" ++ service ++ "',interface='" ++ iface ++ "'", &err);
        return err.name == null;
    }

    pub fn watchOwner(b: *Bus) bool {
        var err: dbus.Err = undefined;
        b.d.dbus_error_init(&err);
        defer b.d.dbus_error_free(&err);
        b.d.dbus_bus_add_match(b.conn, "type='signal',sender='" ++ dbus_service ++ "',interface='" ++ dbus_service ++ "',member='NameOwnerChanged',arg0='" ++ service ++ "'", &err);
        return err.name == null;
    }

    pub fn ownerChanged(b: *Bus, msg: *Msg) bool {
        if (!b.signal(msg, dbus_service, "NameOwnerChanged") or
            !eql(b.d.dbus_message_get_sender(msg), dbus_service)) return false;
        var args = b.input(msg);
        return eql(args.str('s'), service);
    }

    pub fn method(b: *Bus, path: [*:0]const u8, iface: [*:0]const u8, name: [*:0]const u8) ?*Msg {
        return b.d.dbus_message_new_method_call(service, path, iface, name);
    }

    // Só espera o retorno do método, nunca a decisão do usuário no diálogo.
    pub fn call(b: *Bus, msg: *Msg) ?*Msg {
        return b.d.dbus_connection_send_with_reply_and_block(b.conn, msg, 750, null);
    }

    pub fn free(b: *Bus, msg: *Msg) void {
        b.d.dbus_message_unref(msg);
    }

    pub fn signal(b: *Bus, msg: *Msg, iface: []const u8, member: []const u8) bool {
        return b.d.dbus_message_get_type(msg) == 4 and
            eql(b.d.dbus_message_get_interface(msg), iface) and
            eql(b.d.dbus_message_get_member(msg), member);
    }

    pub fn input(b: *Bus, msg: *Msg) Iter {
        var i: Iter = .{ .d = &b.d };
        _ = b.d.dbus_message_iter_init(msg, &i.it);
        return i;
    }

    pub fn output(b: *Bus, msg: *Msg) Iter {
        var i: Iter = .{ .d = &b.d };
        b.d.dbus_message_iter_init_append(msg, &i.it);
        return i;
    }
};

pub fn eql(z: ?[*:0]const u8, s: []const u8) bool {
    return if (z) |p| std.mem.eql(u8, std.mem.span(p), s) else false;
}

pub const Iter = struct {
    d: *const dbus.Fns,
    it: dbus.Iter = undefined,

    pub fn kind(i: *Iter) c_int {
        return i.d.dbus_message_iter_get_arg_type(&i.it);
    }

    pub fn next(i: *Iter) void {
        _ = i.d.dbus_message_iter_next(&i.it);
    }

    pub fn child(i: *Iter) Iter {
        var sub: Iter = .{ .d = i.d };
        i.d.dbus_message_iter_recurse(&i.it, &sub.it);
        return sub;
    }

    pub fn read(i: *Iter, comptime T: type, t: c_int) ?T {
        if (i.kind() != t) return null;
        var val: T = undefined;
        i.d.dbus_message_iter_get_basic(&i.it, @ptrCast(&val));
        return val;
    }

    pub fn str(i: *Iter, t: c_int) ?[*:0]const u8 {
        return i.read([*:0]const u8, t);
    }

    pub fn field(i: *Iter, key: []const u8) ?Iter {
        if (i.kind() != 'a') return null;
        var arr = i.child();
        while (arr.kind() == 'e') : (arr.next()) {
            var entry = arr.child();
            if (!eql(entry.str('s'), key)) continue;
            entry.next();
            if (entry.kind() == 'v') return entry.child();
        }
        return null;
    }

    pub fn put(i: *Iter, t: c_int, s: [*:0]const u8) void {
        _ = i.d.dbus_message_iter_append_basic(&i.it, t, @ptrCast(&s));
    }

    pub fn open(i: *Iter, t: c_int, sig: ?[*:0]const u8) Iter {
        var sub: Iter = .{ .d = i.d };
        if (i.d.dbus_message_iter_open_container(&i.it, t, sig, &sub.it) == 0) @panic("sem memória para mensagem D-Bus");
        return sub;
    }

    pub fn close(i: *Iter, sub: *Iter) void {
        if (i.d.dbus_message_iter_close_container(&i.it, &sub.it) == 0) @panic("sem memória para mensagem D-Bus");
    }

    pub fn option(i: *Iter, key: [*:0]const u8, value: [*:0]const u8) void {
        var entry = i.open('e', null);
        entry.put('s', key);
        var variant = entry.open('v', "s");
        variant.put('s', value);
        entry.close(&variant);
        i.close(&entry);
    }
};
