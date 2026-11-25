//! Aba Rede: cada pedido HTTP do app (a API do Discord, as imagens e vídeos, os plugins),
//! com o status, o tempo, o tamanho e quanto esperou o rate limit. Escolhido um, os
//! cabeçalhos (o Authorization nunca é gravado), o que foi enviado, a resposta (JSON em
//! árvore) e os tempos de cada fase (nome, conexão, TLS, primeiro byte).
const std = @import("std");
const c = @import("c");
const d = @import("../ui/draw.zig");
const i18n = @import("../ui/i18n.zig");
const kit = @import("kit.zig");
const qa = @import("../ui/qa.zig");
const reg = @import("registros.zig");
const json_view = @import("json_view.zig");
const App = @import("../app.zig").App;

const gpa = std.heap.c_allocator;

/// O resumo de cada pedido, copiado do registro quando ele muda (a lista desenha daqui).
const Row = struct {
    id: u32,
    kind: reg.NetKind,
    method: [8]u8,
    url: []u8,
    status: u16,
    pending: bool,
    failed: bool,
    dur_us: u64,
    size: usize,
    waited_ms: u32,
    started_ms: i64,
};

var rows: std.ArrayList(Row) = .empty;
var seen_rev: u32 = std.math.maxInt(u32);
var shown: std.ArrayList(usize) = .empty;
var filter: [96]u8 = @splat(0);
var kinds = [_]bool{ true, true, true, true, true };
var only_errors = false;
var selected: ?u32 = null;
var detail: reg.Net = .{};
var detail_id: u32 = 0;
var detail_rev: u32 = 0;
const Sub = enum { headers, payload, response, timing };
var sub: Sub = .response;
var view_req: json_view.View = .{};
var view_resp: json_view.View = .{};
var split: f32 = 0.5;
var failed_n: u32 = 0;

fn refresh() void {
    const rev = reg.net.rev.load(.monotonic);
    if (rev == seen_rev) return;
    seen_rev = rev;
    for (rows.items) |r| gpa.free(r.url);
    rows.clearRetainingCapacity();
    failed_n = 0;
    reg.net.each({}, struct {
        fn f(_: void, n: *const reg.Net) void {
            const url = gpa.dupe(u8, n.url) catch return;
            rows.append(gpa, .{
                .id = n.id,
                .kind = n.kind,
                .method = n.method,
                .url = url,
                .status = n.status,
                .pending = n.pending,
                .failed = n.failed,
                .dur_us = n.dur_us,
                .size = n.resp_len,
                .waited_ms = n.waited_ms,
                .started_ms = n.started_ms,
            }) catch gpa.free(url);
            if (n.failed or n.status >= 400) failed_n += 1;
        }
    }.f);
}

/// Pedidos que falharam ou voltaram com erro (o número na aba).
pub fn failedCount() u32 {
    refresh();
    return failed_n;
}

fn isError(r: *const Row) bool {
    return r.failed or r.status >= 400;
}

fn statusColor(r: *const Row) kit.Rgba {
    if (r.pending) return kit.pal.dim;
    if (r.failed or r.status >= 500) return kit.pal.err;
    if (r.status == 429 or r.status >= 400) return kit.pal.warn;
    if (r.status >= 300) return kit.pal.info;
    return kit.pal.ok;
}

/// "host" e "caminho" de um endereço.
fn split2(url: []const u8) struct { host: []const u8, path: []const u8 } {
    var s = url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse s.len;
    return .{ .host = s[0..slash], .path = if (slash < s.len) s[slash..] else "/" };
}

pub fn draw(u: *kit.Ui, app: *App, r: kit.Rect) void {
    _ = app;
    refresh();
    const bar_h: f32 = 30;
    kit.rect(u, .{ .x = r.x, .y = r.y, .w = r.w, .h = bar_h }, kit.pal.panel, 0);
    kit.hline(u, r.x, r.right(), r.y + bar_h - 1, kit.pal.line);
    var x = r.x + 4;
    if (kit.toolButton(u, .{ .x = x, .y = r.y + 2, .w = 26, .h = 26 }, .clear, false, i18n.tr("Limpar a lista", "Clear the list"))) {
        reg.net.clear();
        selected = null;
    }
    x += 30;
    const fw = @min(220, r.w * 0.28);
    _ = kit.search(u, "##net-filter", .{ .x = x, .y = r.y + 4, .w = fw, .h = bar_h - 8 }, &filter, i18n.trZ("Filtrar endereço ou método", "Filter URL or method"));
    x += fw + 8;
    const chips = [_]struct { k: reg.NetKind, pt: []const u8, en: []const u8 }{
        .{ .k = .api, .pt = "API", .en = "API" },
        .{ .k = .media, .pt = "Mídia", .en = "Media" },
        .{ .k = .plugin, .pt = "Plugins", .en = "Plugins" },
    };
    for (chips) |ch| {
        var count: u32 = 0;
        for (rows.items) |row| {
            if (row.kind == ch.k) count += 1;
        }
        const b = kit.chip(u, x, r.y + 6, bar_h - 12, i18n.tr(ch.pt, ch.en), kinds[@intFromEnum(ch.k)], count);
        if (b.clicked) kinds[@intFromEnum(ch.k)] = !kinds[@intFromEnum(ch.k)];
        x += b.w + 4;
    }
    const eb = kit.chip(u, x, r.y + 6, bar_h - 12, i18n.tr("Só erros", "Errors only"), only_errors, if (failed_n > 0) failed_n else null);
    if (eb.clicked) only_errors = !only_errors;

    const body: kit.Rect = .{ .x = r.x, .y = r.y + bar_h, .w = r.w, .h = r.h - bar_h - 22 };
    const has_detail = selected != null;
    const side = body.w >= 760;
    const list_r: kit.Rect = if (!has_detail) body else if (side) .{ .x = body.x, .y = body.y, .w = body.w * split, .h = body.h } else .{ .x = body.x, .y = body.y, .w = body.w, .h = body.h * split };
    list(u, list_r, side and has_detail);
    if (has_detail) {
        const det_r: kit.Rect = if (side) .{ .x = body.x + body.w * split + 1, .y = body.y, .w = body.w * (1 - split) - 1, .h = body.h } else .{ .x = body.x, .y = body.y + body.h * split + 1, .w = body.w, .h = body.h * (1 - split) - 1 };
        details(u, det_r);
        kit.splitter(u, body, side, &split, 220, 220, 0xe2);
    }
    summary(u, .{ .x = r.x, .y = r.bottom() - 22, .w = r.w, .h = 22 });
}

fn list(u: *kit.Ui, r: kit.Rect, narrow: bool) void {
    const q = kit.bufStr(&filter);
    shown.clearRetainingCapacity();
    for (rows.items, 0..) |*row, i| {
        if (!kinds[@intFromEnum(row.kind)]) continue;
        if (only_errors and !isError(row)) continue;
        if (q.len > 0 and !kit.has(row.url, q) and !kit.has(std.mem.sliceTo(&row.method, 0), q)) continue;
        shown.append(gpa, i) catch break;
    }
    // Cabeçalho das colunas.
    const head_h: f32 = 22;
    kit.rect(u, .{ .x = r.x, .y = r.y, .w = r.w, .h = head_h }, kit.pal.toolbar, 0);
    kit.hline(u, r.x, r.right(), r.y + head_h - 1, kit.pal.line);
    const cols = columns(r, narrow);
    _ = u.text(cols.status, u.mid(r.y, head_h), kit.pal.dim, "Status");
    _ = u.text(cols.method, u.mid(r.y, head_h), kit.pal.dim, i18n.tr("Método", "Method"));
    _ = u.text(cols.name, u.mid(r.y, head_h), kit.pal.dim, i18n.tr("Endereço", "URL"));
    if (!narrow) {
        _ = u.text(cols.size, u.mid(r.y, head_h), kit.pal.dim, i18n.tr("Tamanho", "Size"));
        _ = u.text(cols.time, u.mid(r.y, head_h), kit.pal.dim, i18n.tr("Tempo", "Time"));
    }
    const lr: kit.Rect = .{ .x = r.x, .y = r.y + head_h, .w = r.w, .h = r.h - head_h };
    const parent = u.dl;
    const rh: f32 = 21;
    const l = kit.beginList(u, "##net-list", lr, shown.items.len, rh, true, null);
    for (shown.items[l.first..l.last], l.first..) |ri, k| {
        const row = &rows.items[ri];
        const y = l.y0 + @as(f32, @floatFromInt(k - l.first)) * rh;
        const rr: kit.Rect = .{ .x = lr.x, .y = y, .w = lr.w, .h = rh };
        qa.mark(rr, "insp-net-row:{d}", .{k});
        const sel = selected == row.id;
        const over = u.over(rr);
        if (sel) kit.rect(u, rr, kit.pal.sel, 0) else if (isError(row)) kit.rect(u, rr, kit.pal.err_bg.alpha(0.6), 0) else if (over) kit.rect(u, rr, kit.pal.hover, 0);
        const ty = u.midCode(y, rh);
        var sb: [16]u8 = undefined;
        const st = if (row.pending) "…" else if (row.failed) i18n.tr("falhou", "failed") else kit.bufSay(&sb, "{d}", &.{ kit.arg(row.status) }) orelse "";
        _ = u.code(cols.status, ty, statusColor(row), st);
        _ = u.code(cols.method, ty, kit.pal.dim, std.mem.sliceTo(&row.method, 0));
        const parts = split2(row.url);
        var run: kit.Run = .{ .u = u, .x = cols.name, .y = ty, .max_x = (if (narrow) lr.right() else cols.size) - 8 };
        run.put(kit.pal.text, parts.path);
        run.put(kit.pal.faint, "  ");
        run.put(kit.pal.faint, parts.host);
        if (row.waited_ms > 0) {
            run.put(kit.pal.faint, "  ");
            run.say(kit.pal.warn, "⏳ {d} ms", &.{ kit.arg(row.waited_ms) });
        }
        if (!narrow) {
            var bb: [24]u8 = undefined;
            _ = u.code(cols.size, ty, kit.pal.dim, if (row.pending) "" else kit.bytesText(&bb, row.size));
            var db: [24]u8 = undefined;
            _ = u.code(cols.time, ty, kit.pal.dim, if (row.pending) "" else kit.durText(&db, row.dur_us));
        }
        if (over and c.ImGui_IsMouseClicked(0)) {
            selected = if (sel) null else row.id;
        }
    }
    if (shown.items.len == 0) {
        const msg = if (!reg.gravando()) i18n.tr("A gravação está desligada.", "Recording is off.") else if (rows.items.len == 0) i18n.tr("Nenhum pedido ainda. Eles aparecem aqui enquanto o Inspetor está aberto.", "No requests yet. They show up here while the Inspector is open.") else i18n.tr("Nada com esse filtro.", "Nothing matches the filter.");
        _ = u.text(lr.x + (lr.w - u.textW(msg)) / 2, lr.y + 30, kit.pal.faint, msg);
    }
    kit.endList(u, l, shown.items.len, rh, parent);
}

const Cols = struct { status: f32, method: f32, name: f32, size: f32, time: f32 };

fn columns(r: kit.Rect, narrow: bool) Cols {
    const x = r.x + 8;
    return .{
        .status = x,
        .method = x + 54,
        .name = x + 112,
        .size = if (narrow) r.right() else r.right() - 150,
        .time = r.right() - 74,
    };
}

fn summary(u: *kit.Ui, r: kit.Rect) void {
    kit.rect(u, r, kit.pal.toolbar, 0);
    kit.hline(u, r.x, r.right(), r.y, kit.pal.line);
    var total: usize = 0;
    var api: usize = 0;
    var waited: u64 = 0;
    for (rows.items) |row| {
        total += row.size;
        if (row.kind == .api) api += 1;
        waited += row.waited_ms;
    }
    var b: [200]u8 = undefined;
    var tb: [24]u8 = undefined;
    const s = i18n.fmt(&b, "{d} pedidos · {d} da API · {s} recebidos · {d} ms esperando o rate limit", "{d} requests · {d} to the API · {s} received · {d} ms waiting on the rate limit", .{ rows.items.len, api, kit.bytesText(&tb, total), waited });
    _ = u.clip(r.x + 8, u.mid(r.y, r.h), kit.pal.dim, s, r.w - 16);
}

fn details(u: *kit.Ui, r: kit.Rect) void {
    const id = selected orelse return;
    kit.rect(u, r, kit.pal.panel, 0);
    // A cópia do pedido (refeita quando ele muda, por exemplo ao terminar).
    const rev = reg.net.rev.load(.monotonic);
    if (detail_id != id or detail_rev != rev) {
        reg.NetLog.freeCopy(&detail);
        if (!reg.net.copy(id, &detail)) {
            selected = null;
            return;
        }
        if (detail_id != id) {
            view_req.reset();
            view_resp.reset();
        }
        detail_id = id;
        detail_rev = rev;
    }
    const n = &detail;
    // Abas do detalhe.
    const tab_h: f32 = 28;
    kit.rect(u, .{ .x = r.x, .y = r.y, .w = r.w, .h = tab_h }, kit.pal.toolbar, 0);
    kit.hline(u, r.x, r.right(), r.y + tab_h - 1, kit.pal.line);
    var x = r.x + 4;
    const tabs = [_]struct { s: Sub, pt: []const u8, en: []const u8 }{
        .{ .s = .headers, .pt = "Cabeçalhos", .en = "Headers" },
        .{ .s = .payload, .pt = "Enviado", .en = "Payload" },
        .{ .s = .response, .pt = "Resposta", .en = "Response" },
        .{ .s = .timing, .pt = "Tempos", .en = "Timing" },
    };
    for (tabs) |tb| {
        const label = i18n.tr(tb.pt, tb.en);
        const w = u.textW(label) + 18;
        const tr: kit.Rect = .{ .x = x, .y = r.y, .w = w, .h = tab_h };
        qa.mark(tr, "insp-net-sub:{s}", .{@tagName(tb.s)});
        const over = u.over(tr);
        _ = u.text(x + 9, u.mid(r.y, tab_h), if (sub == tb.s or over) kit.pal.text else kit.pal.dim, label);
        if (sub == tb.s) kit.rect(u, .{ .x = x + 3, .y = r.y + tab_h - 3, .w = w - 6, .h = 2 }, kit.pal.accent, 1);
        if (over and c.ImGui_IsMouseClicked(0)) sub = tb.s;
        x += w;
    }
    if (kit.toolButton(u, .{ .x = r.right() - 28, .y = r.y + 1, .w = 26, .h = 26 }, .close, false, i18n.tr("Fechar", "Close"))) {
        selected = null;
        return;
    }
    const cp = kit.button(u, r.right() - 34 - (u.textW(i18n.tr("Copiar como curl", "Copy as curl")) + 34), r.y + 3, 22, i18n.tr("Copiar como curl", "Copy as curl"), .copy);
    if (cp.clicked) copyCurl(n);
    const body: kit.Rect = .{ .x = r.x, .y = r.y + tab_h, .w = r.w, .h = r.h - tab_h };
    switch (sub) {
        .headers => headers(u, n, body),
        .payload => if (n.req_body.len > 0) {
            view_req.load(n.id, n.req_body);
            json_view.draw(u, &view_req, "##net-req", body);
        } else empty(u, body, i18n.tr("Sem corpo (o pedido só tem o endereço).", "No body (the request is just the URL).")),
        .response => if (n.pending) {
            empty(u, body, i18n.tr("Esperando a resposta…", "Waiting for the response…"));
        } else if (n.resp_body.len > 0) {
            view_resp.load(n.id, n.resp_body);
            json_view.draw(u, &view_resp, "##net-resp", body);
        } else empty(u, body, if (n.kind == .media) i18n.tr("Mídia: o conteúdo não fica gravado (veja o tamanho e o tipo nos cabeçalhos).", "Media: the content isn't recorded (see the size and type in the headers).") else i18n.tr("Resposta sem corpo.", "Empty response.")),
        .timing => timing(u, n, body),
    }
}

fn empty(u: *kit.Ui, r: kit.Rect, msg: []const u8) void {
    _ = u.clip(r.x + 12, r.y + 16, kit.pal.faint, msg, r.w - 24);
}

fn headers(u: *kit.Ui, n: *const reg.Net, r: kit.Rect) void {
    const parent = u.dl;
    var y = kit.beginPane(u, "##net-headers", r);
    const x = r.x;
    const w = r.w - 10;
    var open_g = true;
    if (kit.section(u, x, &y, w + 10, i18n.tr("Geral", "General"), &open_g)) {
        kit.kv(u, x, &y, w, "URL", n.url, kit.pal.text);
        kit.kv(u, x, &y, w, i18n.tr("Método", "Method"), n.methodStr(), kit.pal.text);
        var sb: [64]u8 = undefined;
        const st = if (n.pending) i18n.tr("esperando", "pending") else if (n.failed) i18n.tr("falhou", "failed") else kit.bufSay(&sb, "{d}", &.{ kit.arg(n.status) }) orelse "";
        kit.kv(u, x, &y, w, "Status", st, if (n.failed or n.status >= 400) kit.pal.err else kit.pal.ok);
        if (n.noteStr().len > 0) kit.kv(u, x, &y, w, i18n.tr("Motivo", "Reason"), n.noteStr(), kit.pal.err);
        if (n.http > 0) {
            var hb: [16]u8 = undefined;
            kit.kv(u, x, &y, w, "HTTP", kit.bufSay(&hb, "{d}.{d}", &.{ kit.arg(n.http / 10), kit.arg(n.http % 10) }) orelse "", kit.pal.dim);
        }
        if (n.contentType().len > 0) kit.kv(u, x, &y, w, i18n.tr("Tipo", "Type"), n.contentType(), kit.pal.dim);
        var tb: [24]u8 = undefined;
        kit.kv(u, x, &y, w, i18n.tr("Começou", "Started"), kit.clock(&tb, n.started_ms), kit.pal.dim);
        if (n.attempt > 0) {
            var ab: [24]u8 = undefined;
            kit.kv(u, x, &y, w, i18n.tr("Tentativa", "Attempt"), kit.bufSay(&ab, "{d}", &.{ kit.arg(n.attempt + 1) }) orelse "", kit.pal.warn);
        }
        if (n.waited_ms > 0) {
            var wb: [32]u8 = undefined;
            kit.kv(u, x, &y, w, i18n.tr("Esperou o rate limit", "Waited on the rate limit"), kit.bufSay(&wb, "{d} ms", &.{ kit.arg(n.waited_ms) }) orelse "", kit.pal.warn);
        }
        kit.kv(u, x, &y, w, i18n.tr("Quem pediu", "Requested by"), n.threadStr(), kit.pal.dim);
        y += 6;
    }
    // O rate limit do balde, em destaque (é o que mais importa para a conta).
    var rl_open = true;
    if (hasRateHeaders(n.resp_headers)) if (kit.section(u, x, &y, w + 10, i18n.tr("Rate limit", "Rate limit"), &rl_open)) {
        var it = std.mem.splitScalar(u8, n.resp_headers, '\n');
        while (it.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " ");
            if (!std.ascii.startsWithIgnoreCase(name, "x-ratelimit") and !std.ascii.eqlIgnoreCase(name, "retry-after")) continue;
            kit.kv(u, x, &y, w, name, std.mem.trim(u8, line[colon + 1 ..], " "), kit.pal.warn);
        }
        y += 6;
    };
    var resp_open = true;
    if (kit.section(u, x, &y, w + 10, i18n.tr("Cabeçalhos da resposta", "Response headers"), &resp_open)) {
        headerLines(u, n.resp_headers, x, &y, w);
        y += 6;
    }
    var req_open = true;
    if (kit.section(u, x, &y, w + 10, i18n.tr("Cabeçalhos do pedido", "Request headers"), &req_open)) {
        headerLines(u, n.req_headers, x, &y, w);
        y += 6;
    }
    kit.endPane(u, r, y, parent);
}

fn hasRateHeaders(h: []const u8) bool {
    return kit.has(h, "x-ratelimit") or kit.has(h, "retry-after");
}

fn headerLines(u: *kit.Ui, text: []const u8, x: f32, y: *f32, w: f32) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "HTTP/")) {
            kit.kv(u, x, y, w, "", line, kit.pal.dim);
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            kit.kv(u, x, y, w, "", line, kit.pal.text);
            continue;
        };
        kit.kv(u, x, y, w, std.mem.trim(u8, line[0..colon], " "), std.mem.trim(u8, line[colon + 1 ..], " "), kit.pal.text);
    }
}

fn timing(u: *kit.Ui, n: *const reg.Net, r: kit.Rect) void {
    var y = r.y + 12;
    const x = r.x + 12;
    const w = r.w - 24;
    if (n.t_total == 0) {
        empty(u, r, i18n.tr("Sem os tempos (o pedido não terminou ou falhou antes de conectar).", "No timings (the request didn't finish or failed before connecting)."));
        return;
    }
    // As fases como o curl mede: cada tempo é desde o começo; a barra é o pedaço de cada uma.
    const phases = [_]struct { pt: []const u8, en: []const u8, from: u32, to: u32, col: kit.Rgba }{
        .{ .pt = "Resolver o nome", .en = "DNS lookup", .from = 0, .to = n.t_dns, .col = kit.Rgba.hex(0x1AA260) },
        .{ .pt = "Conectar", .en = "Connect", .from = n.t_dns, .to = n.t_connect, .col = kit.Rgba.hex(0xF29900) },
        .{ .pt = "TLS", .en = "TLS", .from = n.t_connect, .to = @max(n.t_tls, n.t_connect), .col = kit.Rgba.hex(0xA142F4) },
        .{ .pt = "Esperando a resposta", .en = "Waiting for the response", .from = @max(n.t_tls, n.t_connect), .to = n.t_first, .col = kit.Rgba.hex(0x1A73E8) },
        .{ .pt = "Baixando", .en = "Downloading", .from = n.t_first, .to = n.t_total, .col = kit.Rgba.hex(0x12B5CB) },
    };
    const total: f32 = @floatFromInt(n.t_total);
    const label_w: f32 = 170;
    for (phases) |p| {
        const a: f32 = @floatFromInt(@min(p.from, n.t_total));
        const b: f32 = @floatFromInt(@min(@max(p.to, p.from), n.t_total));
        _ = u.clip(x, u.mid(y, 20), kit.pal.dim, i18n.tr(p.pt, p.en), label_w - 8);
        const bar_w = w - label_w - 70;
        kit.rect(u, .{ .x = x + label_w, .y = y + 6, .w = bar_w, .h = 8 }, kit.pal.line.alpha(0.5), 2);
        if (b > a) kit.rect(u, .{ .x = x + label_w + bar_w * a / total, .y = y + 6, .w = @max(2, bar_w * (b - a) / total), .h = 8 }, p.col, 2);
        var db: [24]u8 = undefined;
        _ = u.code(x + w - 62, u.midCode(y, 20), kit.pal.text, kit.durText(&db, @intFromFloat(b - a)));
        y += 24;
    }
    kit.hline(u, x, x + w, y + 2, kit.pal.line);
    y += 10;
    var db: [24]u8 = undefined;
    _ = u.textB(x, y, kit.pal.text, i18n.tr("Total", "Total"));
    _ = u.code(x + w - 62, y, kit.pal.text, kit.durText(&db, n.t_total));
    y += 24;
    if (n.t_connect == 0 and n.t_dns == 0) _ = u.clip(x, y, kit.pal.faint, i18n.tr("Conexão reaproveitada: sem nome, conexão nem TLS desta vez.", "Reused connection: no DNS, connect or TLS this time."), w);
}

/// O pedido como linha do curl, com o token trocado por uma variável (nunca o de verdade).
fn copyCurl(n: *const reg.Net) void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    kit.say(w, "curl -X {s} '{s}'", &.{ kit.arg(n.methodStr()), kit.arg(n.url) }) catch return;
    var it = std.mem.splitScalar(u8, n.req_headers, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.ascii.startsWithIgnoreCase(line, "authorization:")) {
            w.writeAll(" \\\n  -H \"Authorization: $LARPER_TOKEN\"") catch return;
            continue;
        }
        kit.say(w, " \\\n  -H '{s}'", &.{ kit.arg(line) }) catch return;
    }
    if (n.req_body.len > 0 and n.req_body[0] != '(') kit.say(w, " \\\n  --data-raw '{s}'", &.{ kit.arg(n.req_body) }) catch return;
    kit.copyLong(out.written());
}

const t = std.testing;

test "endereço em host e caminho" {
    const p = split2("https://discord.com/api/v9/users/@me?x=1");
    try t.expectEqualStrings("discord.com", p.host);
    try t.expectEqualStrings("/api/v9/users/@me?x=1", p.path);
    try t.expectEqualStrings("/", split2("https://cdn.discordapp.com").path);
}
