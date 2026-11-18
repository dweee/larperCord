//! Aperte para falar pelo GlobalShortcuts do Wayland. Só na thread da janela.
const std = @import("std");
const portal = @import("portal.zig");
const window = @import("window.zig");

const iface = "org.freedesktop.portal.GlobalShortcuts";
const request_iface = "org.freedesktop.portal.Request";
const session_iface = "org.freedesktop.portal.Session";

const Path = portal.Text;

pub const Shortcut = struct {
    bus: ?portal.Bus = null,
    origin: Path = .{},
    request: Path = .{},
    session: Path = .{},
    id: [24]u8 = undefined,
    id_len: usize = 0,
    bound: bool = false,
    down: bool = false,
    logged: bool = false,
    deadline: u64 = 0,

    pub fn close(s: *Shortcut) void {
        if (s.bus) |*b| {
            if (s.request.len != 0) closeObject(b, &s.request, request_iface);
            if (s.session.len != 0) closeObject(b, &s.session, session_iface);
            b.close();
            s.bus = null;
        }
        s.request.len = 0;
        s.session.len = 0;
        s.bound = false;
        s.down = false;
    }

    fn closeObject(b: *portal.Bus, path: *const Path, interface: [*:0]const u8) void {
        const msg = b.method(path.slice(), interface, "Close") orelse return;
        defer b.free(msg);
        if (b.call(msg)) |reply| b.free(reply);
    }

    pub fn unavailable(s: *Shortcut) void {
        s.close();
        if (!s.logged) std.log.info("voz: GlobalShortcuts indisponível, atalho só com a janela em foco", .{});
        s.logged = true;
    }

    pub fn start(s: *Shortcut, key: u16, now: u64, wake_type: u32) void {
        s.close();
        // O portal guarda a escolha por ID. Uma tecla nova é um novo pedido.
        s.id_len = (std.fmt.bufPrintSentinel(&s.id, "ptt-{d}", .{key}, 0) catch unreachable).len;
        s.bus = portal.Bus.open(wake_type) orelse return s.unavailable();
        const b = &s.bus.?;
        register(b);
        if (!b.match(iface) or !b.match(request_iface) or !b.match(session_iface) or !b.watchOwner()) return s.unavailable();
        const msg = b.method(portal.desktop, iface, "CreateSession") orelse return s.unavailable();
        var args = b.output(msg);
        var opts = args.open('a', "{sv}");
        opts.option("handle_token", "ptt_create");
        opts.option("session_handle_token", "larpercord_ptt");
        args.close(&opts);
        const reply = b.call(msg);
        b.free(msg);
        const r = reply orelse return s.unavailable();
        const sender = b.d.dbus_message_get_sender(r);
        var input = b.input(r);
        const path = input.str('o');
        const ok = s.origin.set(sender orelse "") and s.request.set(path orelse "") and s.origin.len != 0 and s.request.len != 0;
        b.free(r);
        if (!ok) return s.unavailable();
        s.deadline = now + 2500;
    }

    // Os portais atuais exigem a identificação do aplicativo fora da sandbox.
    // Em portais antigos (ou na sandbox), a sessão pode abrir sem este registro.
    fn register(b: *portal.Bus) void {
        const msg = b.method(portal.desktop, "org.freedesktop.host.portal.Registry", "Register") orelse return;
        defer b.free(msg);
        var args = b.output(msg);
        args.put('s', window.app_id);
        var opts = args.open('a', "{sv}");
        args.close(&opts);
        if (b.call(msg)) |reply| b.free(reply);
    }

    fn bind(s: *Shortcut, trigger: [*:0]const u8, description: [*:0]const u8) bool {
        const b = &s.bus.?;
        const msg = b.method(portal.desktop, iface, "BindShortcuts") orelse return false;
        defer b.free(msg);
        var args = b.output(msg);
        args.put('o', s.session.slice());
        var shortcuts = args.open('a', "(sa{sv})");
        var shortcut = shortcuts.open('r', null);
        shortcut.put('s', s.id[0..s.id_len :0]);
        var props = shortcut.open('a', "{sv}");
        props.option("description", description);
        props.option("preferred_trigger", trigger);
        shortcut.close(&props);
        shortcuts.close(&shortcut);
        args.close(&shortcuts);
        args.put('s', "");
        var opts = args.open('a', "{sv}");
        opts.option("handle_token", "ptt_bind");
        args.close(&opts);
        const reply = b.call(msg) orelse return false;
        defer b.free(reply);
        var input = b.input(reply);
        return s.request.set(input.str('o') orelse return false);
    }

    fn assigned(s: *const Shortcut, entries: *portal.Iter) bool {
        if (entries.kind() != 'a') return false;
        var list = entries.child();
        while (list.kind() == 'r') : (list.next()) {
            var shortcut = list.child();
            if (!portal.eql(shortcut.str('s'), s.id[0..s.id_len])) continue;
            shortcut.next();
            var description = shortcut.field("trigger_description") orelse return true;
            return !portal.eql(description.str('s'), "");
        }
        return false;
    }

    /// Os sinais só valem para a sessão e o atalho deste pedido.
    fn onMessage(s: *Shortcut, b: *portal.Bus, msg: *portal.Msg, trigger: [*:0]const u8, description: [*:0]const u8) bool {
        if (b.ownerChanged(msg)) {
            var owner = b.input(msg);
            owner.next();
            return !portal.eql(owner.str('s'), s.origin.slice());
        }
        if (!portal.eql(b.d.dbus_message_get_sender(msg), s.origin.slice())) return true;
        const path = b.d.dbus_message_get_path(msg);
        var args = b.input(msg);
        if (s.request.len != 0 and portal.eql(path, s.request.slice()) and b.signal(msg, request_iface, "Response")) {
            s.request.len = 0;
            if (args.read(u32, 'u') != 0) return false;
            args.next();
            if (s.session.len == 0) {
                var handle = args.field("session_handle") orelse return false;
                if (!s.session.set(handle.str('s') orelse handle.str('o') orelse return false)) return false;
                return s.bind(trigger, description);
            }
            var entries = args.field("shortcuts") orelse return false;
            s.bound = s.assigned(&entries);
            return true;
        }
        if (s.session.len != 0 and portal.eql(path, s.session.slice()) and b.signal(msg, session_iface, "Closed")) return false;
        if (s.session.len != 0 and portal.eql(path, portal.desktop) and portal.eql(args.str('o'), s.session.slice())) {
            args.next();
            if (b.signal(msg, iface, "ShortcutsChanged")) {
                s.bound = s.assigned(&args);
                s.down = false;
                return true;
            }
            if (!s.bound) return true;
            if (portal.eql(args.str('s'), s.id[0..s.id_len])) {
                if (b.signal(msg, iface, "Activated")) s.down = true;
                if (b.signal(msg, iface, "Deactivated")) s.down = false;
            }
        }
        return true;
    }

    pub fn creating(s: *const Shortcut) bool {
        return s.bus != null and s.session.len == 0;
    }

    pub fn pump(s: *Shortcut, now: u64, trigger: [*:0]const u8, description: [*:0]const u8) void {
        const b = if (s.bus) |*b| b else return;
        if (b.d.dbus_connection_read_write(b.conn, 0) == 0) return s.unavailable();
        while (b.d.dbus_connection_pop_message(b.conn)) |msg| {
            const ok = s.onMessage(b, msg, trigger, description);
            b.free(msg);
            if (!ok) return s.unavailable();
        }
        b.drained();
        if (s.session.len == 0 and now >= s.deadline) s.unavailable();
    }
};
