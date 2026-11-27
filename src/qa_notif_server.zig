//! Servidor de notificações de mentira, só para o QA: `larpercord --qa-notif-server
//! CAPS REGISTRO` (só no build com o QA). Fica com o org.freedesktop.Notifications numa
//! sessão D-Bus particular (qa_notificacao.zig sobe o dbus-daemon), responde
//! GetCapabilities com CAPS (separadas por vírgula: "actions,body,inline-reply" faz o
//! papel do KDE, sem "inline-reply" o do GNOME), anota em REGISTRO cada Notify e
//! CloseNotification, uma linha por chamada, e manda os sinais que o QA pede pela
//! entrada, como um servidor de verdade faz quando a pessoa clica:
//!
//!     token <id> <ficha>    ActivationToken
//!     action <id> <chave>   ActionInvoked, e a notificação fecha (NotificationClosed 2)
//!     reply <id> <texto>    NotificationReplied, e fecha
//!     quit                  sai
//!
//! O registro, com os campos separados por tabulação:
//!     pronto  <caps>
//!     notify  <id>  <título>  <corpo>  <chave>=<rótulo>|…  <dica>=<valor>;…
//!     close   <id>
//! Sem janela e sem SDL de vídeo: sai antes de o app começar, e sai sozinho quando a
//! entrada fecha (o app acabou).
const std = @import("std");
const c = @import("c");
const dbus = @import("platform/dbus.zig");

const d = &dbus.d;
const Out = dbus.Out;
const In = dbus.In;

const servico = "org.freedesktop.Notifications";
const caminho = "/org/freedesktop/Notifications";

var conn: *dbus.Conn = undefined;
var caps_buf: [512]u8 = undefined;
var caps: [16][*:0]const u8 = undefined;
var n_caps: usize = 0;
var registro: c_int = -1;
var proximo: u32 = 1;

pub fn run(lista: []const u8, arquivo: []const u8) noreturn {
    if (!dbus.load()) c._exit(2);
    // As capacidades, cada uma terminada em zero.
    var at: usize = 0;
    var it = std.mem.tokenizeScalar(u8, lista, ',');
    while (it.next()) |cap| {
        if (n_caps == caps.len or at + cap.len + 1 > caps_buf.len) break;
        @memcpy(caps_buf[at..][0..cap.len], cap);
        caps_buf[at + cap.len] = 0;
        caps[n_caps] = @ptrCast(caps_buf[at..].ptr);
        n_caps += 1;
        at += cap.len + 1;
    }
    var pb: [1024]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "{s}", .{arquivo}, 0) catch c._exit(2);
    registro = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_APPEND | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (registro < 0) c._exit(2);

    var err: dbus.Err = undefined;
    d.dbus_error_init(&err);
    conn = d.dbus_bus_get_private(dbus.bus_session, &err) orelse c._exit(3);
    d.dbus_connection_set_exit_on_disconnect(conn, 0);
    if (d.dbus_bus_request_name(conn, servico, dbus.name_do_not_queue, &err) != dbus.name_primary_owner) c._exit(4);
    var fd: c_int = -1;
    if (d.dbus_connection_add_filter(conn, &filtro, null, null) == 0 or d.dbus_connection_get_unix_fd(conn, &fd) == 0) c._exit(5);
    anotar("pronto\t{s}\n", .{lista});
    laco(fd);
}

fn anotar(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = c.write(registro, s.ptr, s.len);
}

/// Tabulação e quebra de linha viram espaço: um campo por coluna, uma chamada por linha.
fn plano(buf: []u8, s: []const u8) []const u8 {
    const k = @min(s.len, buf.len);
    for (s[0..k], 0..) |ch, i| buf[i] = if (ch == '\t' or ch == '\n') ' ' else ch;
    return buf[0..k];
}

fn laco(bus_fd: c_int) noreturn {
    var linha: [2048]u8 = undefined;
    var len: usize = 0;
    while (true) {
        while (true) {
            while (d.dbus_connection_dispatch(conn) == dbus.dispatch_data_remains) {}
            d.dbus_connection_flush(conn);
            if (d.dbus_connection_get_dispatch_status(conn) != dbus.dispatch_data_remains) break;
        }
        if (d.dbus_connection_get_is_connected(conn) == 0) c._exit(0);
        var fds = [2]c.struct_pollfd{
            .{ .fd = 0, .events = c.POLLIN, .revents = 0 },
            .{ .fd = bus_fd, .events = c.POLLIN, .revents = 0 },
        };
        if (c.poll(&fds, 2, -1) < 0) continue;
        if (fds[1].revents != 0) _ = d.dbus_connection_read_write(conn, 0);
        if (fds[0].revents != 0) {
            const r = c.read(0, linha[len..].ptr, linha.len - len);
            // O app acabou (ou fechou a entrada): sai junto.
            if (r <= 0) c._exit(0);
            len += @intCast(r);
            while (std.mem.indexOfScalar(u8, linha[0..len], '\n')) |nl| {
                comando(linha[0..nl]);
                std.mem.copyForwards(u8, linha[0 .. len - nl - 1], linha[nl + 1 .. len]);
                len -= nl + 1;
            }
            if (len == linha.len) len = 0;
        }
    }
}

fn comando(l: []const u8) void {
    var it = std.mem.splitScalar(u8, l, ' ');
    const nome = it.next() orelse return;
    if (std.mem.eql(u8, nome, "quit")) c._exit(0);
    const id = std.fmt.parseInt(u32, it.next() orelse return, 10) catch return;
    const resto = it.rest();
    var zb: [2048]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{resto}, 0) catch return;
    if (std.mem.eql(u8, nome, "token")) {
        sinal("ActivationToken", id, z.ptr, null);
    } else if (std.mem.eql(u8, nome, "action")) {
        sinal("ActionInvoked", id, z.ptr, null);
        sinal("NotificationClosed", id, null, 2);
    } else if (std.mem.eql(u8, nome, "reply")) {
        sinal("NotificationReplied", id, z.ptr, null);
        sinal("NotificationClosed", id, null, 2);
    }
    d.dbus_connection_flush(conn);
}

fn sinal(membro: [*:0]const u8, id: u32, texto: ?[*:0]const u8, numero: ?u32) void {
    const msg = d.dbus_message_new_signal(caminho, servico, membro) orelse return;
    defer d.dbus_message_unref(msg);
    var out: Out = .{};
    d.dbus_message_iter_init_append(msg, &out.it);
    out.uint(id);
    if (texto) |t| out.str(t);
    if (numero) |v| out.uint(v);
    _ = d.dbus_connection_send(conn, msg, null);
}

fn filtro(_: *dbus.Conn, msg: *dbus.Msg, _: ?*anyopaque) callconv(.c) c_int {
    if (d.dbus_message_get_type(msg) != dbus.msg_method_call) return dbus.not_yet;
    const member = dbus.span(d.dbus_message_get_member(msg)) orelse return dbus.not_yet;
    const reply = responder(msg, member) orelse return dbus.not_yet;
    if (d.dbus_message_get_no_reply(msg) == 0) _ = d.dbus_connection_send(conn, reply, null);
    d.dbus_message_unref(reply);
    return dbus.handled;
}

fn responder(msg: *dbus.Msg, member: []const u8) ?*dbus.Msg {
    const eql = std.mem.eql;
    if (eql(u8, member, "GetCapabilities")) {
        const r = d.dbus_message_new_method_return(msg) orelse return null;
        var out: Out = .{};
        d.dbus_message_iter_init_append(r, &out.it);
        var arr: Out = .{};
        out.open(&arr, 'a', "s");
        for (caps[0..n_caps]) |cap| arr.str(cap);
        out.close(&arr);
        return r;
    }
    if (eql(u8, member, "GetServerInformation")) {
        const r = d.dbus_message_new_method_return(msg) orelse return null;
        var out: Out = .{};
        d.dbus_message_iter_init_append(r, &out.it);
        out.str("larperCord QA");
        out.str("larperCord");
        out.str("1");
        out.str("1.2");
        return r;
    }
    if (eql(u8, member, "CloseNotification")) {
        var in: In = .{};
        const id = (if (in.start(msg)) in.uint() else null) orelse return d.dbus_message_new_error(msg, "org.freedesktop.DBus.Error.InvalidArgs", "id");
        anotar("close\t{d}\n", .{id});
        sinal("NotificationClosed", id, null, 3);
        return d.dbus_message_new_method_return(msg);
    }
    if (eql(u8, member, "Notify")) return notify(msg);
    return null;
}

/// Notify(app_name, replaces_id, app_icon, summary, body, actions, hints, expire_timeout).
fn notify(msg: *dbus.Msg) ?*dbus.Msg {
    var in: In = .{};
    if (!in.start(msg)) return d.dbus_message_new_error(msg, "org.freedesktop.DBus.Error.InvalidArgs", "args");
    _ = in.str();
    in.next();
    const replaces = in.uint() orelse 0;
    in.next();
    _ = in.str();
    in.next();
    const titulo = in.str() orelse "";
    in.next();
    const corpo = in.str() orelse "";
    in.next();
    var acoes: [1024]u8 = undefined;
    var na: usize = 0;
    if (in.kind() == 'a') {
        var sub: In = .{};
        in.recurse(&sub);
        var par = false;
        while (sub.str()) |s| : (sub.next()) {
            const sep: []const u8 = if (na == 0) "" else if (par) "=" else "|";
            const parte = std.fmt.bufPrint(acoes[na..], "{s}{s}", .{ sep, s }) catch break;
            na += parte.len;
            par = !par;
        }
    }
    in.next();
    var dicas: [1024]u8 = undefined;
    var nd: usize = 0;
    if (in.kind() == 'a') {
        var arr: In = .{};
        in.recurse(&arr);
        while (arr.kind() == 'e') : (arr.next()) {
            var e: In = .{};
            arr.recurse(&e);
            const k = e.str() orelse continue;
            e.next();
            var v: In = .{};
            e.recurse(&v);
            var vb: [24]u8 = undefined;
            const valor: []const u8 = if (v.str()) |s| s else if (v.byte()) |b| (std.fmt.bufPrint(&vb, "{d}", .{b}) catch "") else if (v.int()) |i| (std.fmt.bufPrint(&vb, "{d}", .{i}) catch "") else "?";
            const parte = std.fmt.bufPrint(dicas[nd..], "{s}{s}={s}", .{ if (nd == 0) "" else ";", k, valor }) catch break;
            nd += parte.len;
        }
    }
    const id = if (replaces != 0) replaces else blk: {
        defer proximo += 1;
        break :blk proximo;
    };
    var tb: [512]u8 = undefined;
    var cb: [1536]u8 = undefined;
    var ab: [1024]u8 = undefined;
    var db: [1024]u8 = undefined;
    anotar("notify\t{d}\t{s}\t{s}\t{s}\t{s}\n", .{ id, plano(&tb, titulo), plano(&cb, corpo), plano(&ab, acoes[0..na]), plano(&db, dicas[0..nd]) });
    const r = d.dbus_message_new_method_return(msg) orelse return null;
    var out: Out = .{};
    d.dbus_message_iter_init_append(r, &out.it);
    out.uint(id);
    return r;
}
