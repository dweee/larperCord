//! Os pedidos HTTPS dos plugins, de verdade: uma thread por pedido, só enquanto
//! ele dura (parado, não existe nada). O que já foi conferido antes de chegar aqui
//! (host declarado e aprovado, URL, limites de quantidade) está em runtime.zig.
//!
//! Aqui valem os limites que dependem do curl: só HTTPS, sem seguir
//! redirecionamento (poderia levar a um host não aprovado), tamanho e tempo. O
//! pedido sai sem cookies e só com os cabeçalhos que vieram na lista permitida:
//! nada da conta do Discord passa por este arquivo.
const std = @import("std");
const insp = @import("../inspect/registros.zig");
const insp_curl = @import("../inspect/curl_insp.zig");
const c = @import("c");
const wire = @import("wire.zig");
const proxy = @import("../net/proxy.zig");
const sys = @import("../platform/sys.zig");
const build_options = @import("build_options");
const version: []const u8 = build_options.version;

pub const body_max = 1024 * 1024;
const max_threads = 8;

var flying = std.atomic.Value(u32).init(0);
var stopping = std.atomic.Value(bool).init(false);

/// Só nos builds com o robô de QA: manda tudo para um servidor local, para testar
/// o caminho inteiro sem falar com a internet. Fora deles nem compila.
pub const qa_builds = @import("../ui/qa.zig").compiled;
pub var qa_base: [if (qa_builds) 128 else 0]u8 = undefined;
pub var qa_base_len: usize = 0;
pub var qa_cainfo: [if (qa_builds) 256 else 0]u8 = undefined;
pub var qa_cainfo_len: usize = 0;

/// Começa um pedido. false = não deu (quem chama ainda é dono de `req`).
pub fn start(req: *wire.HttpReq) bool {
    if (stopping.load(.acquire)) return false;
    if (flying.fetchAdd(1, .acq_rel) >= max_threads) {
        _ = flying.fetchSub(1, .acq_rel);
        return false;
    }
    const t = c.SDL_CreateThread(threadMain, "plugin-http", req) orelse {
        _ = flying.fetchSub(1, .acq_rel);
        return false;
    };
    c.SDL_DetachThread(t);
    return true;
}

/// Cancela o que está no ar e espera acabar (ao fechar o app). Um DNS preso não
/// segura o encerramento: depois do prazo, a resposta é só descartada.
pub fn stop() void {
    stopping.store(true, .release);
    var waited: u32 = 0;
    while (flying.load(.acquire) > 0 and waited < 2000) : (waited += 10) c.SDL_Delay(10);
}

fn threadMain(raw: ?*anyopaque) callconv(.c) c_int {
    const req: *wire.HttpReq = @ptrCast(@alignCast(raw.?));
    defer _ = flying.fetchSub(1, .acq_rel);
    const gpa = req.gpa;
    var body: std.ArrayList(u8) = .empty;
    var res_err: wire.HttpError = .none;
    var status: u16 = 0;
    perform(req, &body, &status) catch |e| {
        res_err = if (e == error.TooBig) .too_big else .network;
        body.clearRetainingCapacity();
    };
    defer req.free();
    if (stopping.load(.acquire)) {
        body.deinit(gpa);
        return 0;
    }
    const res = gpa.create(wire.HttpRes) catch {
        body.deinit(gpa);
        return 0;
    };
    res.* = .{ .run = req.run, .id = req.id, .token = req.token, .status = status, .err = res_err, .body = body.toOwnedSlice(gpa) catch &.{} };
    req.done(req.done_ctx, res);
    return 0;
}

const Sink = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    too_big: bool = false,

    fn write(ptr: [*c]u8, size: usize, n: usize, ud: ?*anyopaque) callconv(.c) usize {
        const s: *Sink = @ptrCast(@alignCast(ud.?));
        const total = size * n;
        if (s.out.items.len + total > body_max) {
            s.too_big = true;
            return 0;
        }
        s.out.appendSlice(s.gpa, ptr[0..total]) catch return 0;
        return total;
    }
};

fn progress(_: ?*anyopaque, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
    return if (stopping.load(.acquire)) 1 else 0;
}

fn inspHeaderCb(ptr: [*c]u8, size: usize, n: usize, user: ?*anyopaque) callconv(.c) usize {
    const out: *std.ArrayList(u8) = @ptrCast(@alignCast(user.?));
    insp_curl.responseHeader(out, ptr[0 .. size * n]);
    return size * n;
}

fn perform(req: *wire.HttpReq, out: *std.ArrayList(u8), status: *u16) !void {
    const h = c.curl_easy_init() orelse return error.Network;
    defer c.curl_easy_cleanup(h);
    var sink: Sink = .{ .gpa = req.gpa, .out = out };
    var ua_buf: [64]u8 = undefined;
    const ua = std.fmt.bufPrintSentinel(&ua_buf, "larperCord/{s} (plugin)", .{version}, 0) catch "larperCord";
    var url_buf: [2400]u8 = undefined;
    var url: [:0]const u8 = req.url;
    var plain_qa = false;
    if (qa_builds and qa_base_len > 0) {
        // https://host/resto -> base/resto
        const after = req.url["https://".len..];
        const cut = std.mem.indexOfAny(u8, after, "/?") orelse after.len;
        url = std.fmt.bufPrintSentinel(&url_buf, "{s}{s}", .{ qa_base[0..qa_base_len], after[cut..] }, 0) catch return error.Network;
        plain_qa = std.mem.startsWith(u8, qa_base[0..qa_base_len], "http://");
    }
    _ = c.curl_easy_setopt(h, c.CURLOPT_URL, url.ptr);
    _ = c.curl_easy_setopt(h, c.CURLOPT_USERAGENT, ua.ptr);
    // Só HTTPS, e sem seguir redirecionamento: o 3xx volta para o plugin.
    _ = c.curl_easy_setopt(h, c.CURLOPT_PROTOCOLS_STR, @as([*:0]const u8, if (plain_qa) "http" else "https"));
    _ = c.curl_easy_setopt(h, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
    _ = c.curl_easy_setopt(h, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
    _ = c.curl_easy_setopt(h, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, 10));
    _ = c.curl_easy_setopt(h, c.CURLOPT_TIMEOUT, @as(c_long, 20));
    _ = c.curl_easy_setopt(h, c.CURLOPT_MAXFILESIZE_LARGE, @as(c.curl_off_t, body_max));
    _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEFUNCTION, Sink.write);
    _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEDATA, &sink);
    _ = c.curl_easy_setopt(h, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
    _ = c.curl_easy_setopt(h, c.CURLOPT_XFERINFOFUNCTION, progress);
    // Sem cookies: o motor de cookies do curl só liga se alguém pedir, e aqui ninguém pede.
    var list: ?*c.curl_slist = null;
    defer if (list) |l| c.curl_slist_free_all(l);
    for (req.headers) |line| list = c.curl_slist_append(list, line.ptr);
    if (list) |l| _ = c.curl_easy_setopt(h, c.CURLOPT_HTTPHEADER, l);
    if (req.post) {
        _ = c.curl_easy_setopt(h, c.CURLOPT_POST, @as(c_long, 1));
        _ = c.curl_easy_setopt(h, c.CURLOPT_POSTFIELDS, req.body.ptr);
        _ = c.curl_easy_setopt(h, c.CURLOPT_POSTFIELDSIZE_LARGE, @as(c.curl_off_t, @intCast(req.body.len)));
    }
    sys.curlTls(h);
    if (qa_builds and qa_cainfo_len > 0) _ = c.curl_easy_setopt(h, c.CURLOPT_CAINFO, @as([*]const u8, &qa_cainfo));
    var pb: proxy.Buf = undefined;
    if (proxy.forUrl(&pb, url)) |p| _ = c.curl_easy_setopt(h, c.CURLOPT_PROXY, p.ptr);
    // A aba Rede do Inspetor (só gravando), com os cabeçalhos que o plugin mandou.
    var insp_h: std.ArrayList(u8) = .empty;
    defer insp_h.deinit(std.heap.c_allocator);
    const insp_id = if (insp.gravando()) blk: {
        var req_h: std.ArrayList(u8) = .empty;
        defer req_h.deinit(std.heap.c_allocator);
        insp_curl.requestHeaders(&req_h, list, ua);
        _ = c.curl_easy_setopt(h, c.CURLOPT_HEADERFUNCTION, inspHeaderCb);
        _ = c.curl_easy_setopt(h, c.CURLOPT_HEADERDATA, &insp_h);
        break :blk insp.net.begin(.plugin, if (req.post) "POST" else "GET", url, req_h.items, if (req.post) req.body else null, "plugins");
    } else 0;
    const rc = c.curl_easy_perform(h);
    if (insp_id != 0) {
        var e: insp.NetLog.End = .{ .resp_headers = insp_h.items, .resp_body = out.items };
        insp_curl.endInfo(h, &e);
        if (rc != c.CURLE_OK) {
            e.failed = true;
            e.note = if (sink.too_big or rc == c.CURLE_FILESIZE_EXCEEDED) "grande demais para um plugin" else std.mem.span(c.curl_easy_strerror(rc));
        }
        insp.net.end(insp_id, e);
    }
    if (sink.too_big or rc == c.CURLE_FILESIZE_EXCEEDED) return error.TooBig;
    if (rc != c.CURLE_OK) return error.Network;
    var code: c_long = 0;
    _ = c.curl_easy_getinfo(h, c.CURLINFO_RESPONSE_CODE, &code);
    status.* = @intCast(std.math.clamp(code, 0, 65535));
}
