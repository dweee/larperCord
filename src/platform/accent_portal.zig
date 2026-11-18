//! Cor de destaque do desktop Linux, lida na thread da janela.
const std = @import("std");
const portal = @import("portal.zig");
const Rgba = @import("../theme/color.zig").Rgba;

const iface = "org.freedesktop.portal.Settings";
const appearance = "org.freedesktop.appearance";
const key = "accent-color";

pub const Settings = struct {
    bus: ?portal.Bus = null,
    owner: portal.Text = .{},
    color: ?Rgba = null,
    active: bool = false,

    pub fn close(s: *Settings) void {
        if (s.bus) |*b| b.close();
        s.* = .{};
    }

    fn readOne(s: *Settings, b: *portal.Bus) ?Rgba {
        const msg = b.method(portal.desktop, iface, "ReadOne") orelse return null;
        defer b.free(msg);
        var args = b.output(msg);
        args.put('s', appearance);
        args.put('s', key);
        const reply = b.call(msg) orelse return null;
        defer b.free(reply);
        if (!s.owner.set(b.d.dbus_message_get_sender(reply) orelse return null)) return null;
        var value = b.input(reply);
        return decode(&value);
    }

    fn start(s: *Settings, wake_type: u32) void {
        s.bus = portal.Bus.open(wake_type) orelse return;
        const b = &s.bus.?;
        if (!b.match(iface) or !b.watchOwner()) {
            b.close();
            s.bus = null;
            return;
        }
        s.color = s.readOne(b);
        // ReadOne pode falhar enquanto a cor ainda não está disponível.
        if (s.owner.len == 0) _ = b.owner(&s.owner);
    }

    fn onMessage(s: *Settings, b: *portal.Bus, msg: *portal.Msg) void {
        if (b.ownerChanged(msg)) {
            var args = b.input(msg);
            args.next();
            const previous = args.str('s') orelse return;
            args.next();
            const current = args.str('s') orelse return;
            // O aviso da ativação para o nosso ReadOne inicial já foi atendido.
            if (portal.eql(current, s.owner.slice())) return;
            if (!portal.eql(previous, s.owner.slice())) return;
            _ = s.owner.set(current);
            s.color = if (s.owner.len == 0) null else s.readOne(b);
            return;
        }
        if (s.owner.len == 0 or !portal.eql(b.d.dbus_message_get_sender(msg), s.owner.slice()) or
            !portal.eql(b.d.dbus_message_get_path(msg), portal.desktop) or !b.signal(msg, iface, "SettingChanged")) return;
        var args = b.input(msg);
        if (!portal.eql(args.str('s'), appearance)) return;
        args.next();
        if (!portal.eql(args.str('s'), key)) return;
        args.next();
        s.color = decode(&args);
    }

    pub fn pump(s: *Settings, enabled: bool, wake_type: u32) bool {
        const before = s.color;
        const toggled = enabled != s.active;
        if (toggled) {
            s.active = enabled;
            if (enabled) s.start(wake_type) else s.close();
        }
        if (s.bus) |*b| {
            if (b.d.dbus_connection_read_write(b.conn, 0) == 0) {
                b.close();
                s.bus = null;
                s.color = null;
            } else {
                while (b.d.dbus_connection_pop_message(b.conn)) |msg| {
                    s.onMessage(b, msg);
                    b.free(msg);
                }
                b.drained();
            }
        }
        return toggled or !std.meta.eql(before, s.color);
    }
};

fn decode(value: *portal.Iter) ?Rgba {
    if (value.kind() != 'v') return null;
    var variant = value.child();
    if (variant.kind() != 'r') return null;
    var tuple = variant.child();
    var rgb: [3]f64 = undefined;
    for (&rgb) |*channel| {
        channel.* = tuple.read(f64, 'd') orelse return null;
        tuple.next();
    }
    return if (tuple.kind() == 0) fromRgb(rgb) else null;
}

fn fromRgb(rgb: [3]f64) ?Rgba {
    for (rgb) |channel| {
        if (!std.math.isFinite(channel) or channel < 0 or channel > 1) return null;
    }
    return .{ .r = @floatCast(rgb[0]), .g = @floatCast(rgb[1]), .b = @floatCast(rgb[2]) };
}

test "cor do portal aceita RGB no intervalo ou conserva a cor do tema" {
    const color = fromRgb(.{ 0.25, 0.5, 1 }).?;
    try std.testing.expectEqual(Rgba{ .r = 0.25, .g = 0.5, .b = 1 }, color);
    try std.testing.expect(fromRgb(.{ 0, -0.1, 1 }) == null);
    try std.testing.expect(fromRgb(.{ 0, 0, 1.1 }) == null);
    try std.testing.expect(fromRgb(.{ 0, std.math.nan(f64), 1 }) == null);
}
