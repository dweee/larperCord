//! A linha de comando do controle de fora: `larpercord ctl …` fala com o larperCord
//! aberto (app_ctl.zig), escreve a resposta na saída padrão e sai com 0 se deu certo ou
//! 1 se não. Roda antes do SDL e da janela (main.zig). No Windows o executável de
//! release não tem console: a saída vai para onde foi redirecionada ou, sem isso, para o
//! terminal que chamou (AttachConsole).
const std = @import("std");
const c = @import("c");
const sys = @import("platform/sys.zig");
const ctl = @import("platform/ctl.zig");
const proto = @import("core/ctl.zig");
const app_ctl = @import("app_ctl.zig");
const i18n = @import("ui/i18n.zig");

const alloc = std.heap.c_allocator;

/// Quanto esperar uma resposta: o app tem `ctl.reply_ms` para responder e avisa se
/// passou; isto é para um app parado de vez (o processo suspenso, por exemplo).
const answer_ms = ctl.reply_ms + 5000;
/// Sem o app aberto, o `watch` tenta de novo a cada tanto (o waybar fica com a linha
/// "fechado" enquanto isso).
const retry_ms = 3000;

pub fn main(args: []const []const u8) u8 {
    // A ajuda e os erros daqui no idioma do sistema (o app usa o das configurações).
    i18n.set(i18n.system());
    var buf: [proto.max_line]u8 = undefined;
    switch (proto.parseCli(args, &buf)) {
        .help => return printHelp(),
        .bad => |b| return complain(switch (b) {
            .format => i18n.tr("watch aceita --waybar ou --format json|waybar|text", "watch takes --waybar or --format json|waybar|text"),
            .newline => i18n.tr("um argumento não pode ter quebra de linha", "an argument can't have a line break"),
            .too_long => i18n.tr("comando longo demais", "command too long"),
        }),
        .send => |s| return if (s.watch) |fmt| watchLoop(s.line, fmt) else once(s.line),
    }
}

fn portFile(buf: []u8) ?[:0]const u8 {
    return ctl.portPath(buf, c.SDL_getenv("LARPER_CTL") != null);
}

fn openError(e: ctl.Conn.OpenError) []const u8 {
    return switch (e) {
        error.NotRunning => i18n.tr("o larperCord não está aberto (ou Configurações → Avançado → Controle externo está desligado)", "larperCord isn't running (or Settings → Advanced → External control is off)"),
        error.NoAnswer => i18n.tr("o larperCord não respondeu", "larperCord didn't answer"),
        error.Refused => i18n.tr("o larperCord recusou a conexão (o arquivo da porta é de outra vez?)", "larperCord refused the connection (is the port file from an older run?)"),
        error.Busy => codeText(.busy),
    };
}

/// O erro que o app mandou, no idioma daqui. O de uso traz o detalhe do comando (em
/// inglês, como os nomes dos comandos); um código de uma versão mais nova, a mensagem dele.
fn errText(code: ?proto.Code, text: []const u8) []const u8 {
    const k = code orelse return text;
    return if (k == .usage and text.len > 0) text else codeText(k);
}

fn codeText(code: proto.Code) []const u8 {
    return switch (code) {
        .auth => i18n.tr("chave errada ou ausente", "wrong or missing key"),
        .busy => i18n.tr("conexões demais ao mesmo tempo", "too many connections at once"),
        .timeout => i18n.tr("o larperCord não respondeu a tempo", "larperCord didn't answer in time"),
        .unknown => i18n.tr("comando desconhecido (veja larpercord ctl help)", "unknown command (see larpercord ctl help)"),
        .usage => i18n.tr("argumentos errados (veja larpercord ctl help)", "wrong arguments (see larpercord ctl help)"),
        .not_ptt => i18n.tr("o modo de voz não é aperte para falar (Configurações → Voz)", "the voice mode isn't push to talk (Settings → Voice)"),
        .no_call => i18n.tr("fora de call", "not in a call"),
        .not_ready => i18n.tr("ainda sem conexão com o Discord", "not connected to Discord yet"),
        .not_found => i18n.tr("esse canal não está nesta conta", "that channel isn't on this account"),
        .not_text => i18n.tr("não é um canal de texto", "not a text channel"),
        .closing => i18n.tr("o larperCord está fechando", "larperCord is closing"),
        .failed => i18n.tr("não deu certo", "it didn't work"),
    };
}

/// Um comando: a resposta na saída padrão, ou o erro na de erros.
fn once(line: []const u8) u8 {
    var pb: [512]u8 = undefined;
    const path = portFile(&pb) orelse return complain(openError(error.NotRunning));
    var conn = ctl.Conn.open(path) catch |e| return complain(openError(e));
    defer conn.close();
    if (!conn.send(line)) return complain(openError(error.NoAnswer));
    var r = conn.response(alloc, answer_ms) orelse return complain(openError(error.NoAnswer));
    defer r.deinit(alloc);
    if (!r.ok) return complain(errText(r.code, r.text));
    _ = write(.out, r.body.items);
    return 0;
}

/// O `watch`: cada linha do app assim que chega. Fechado ou desligado, uma linha dizendo
/// isso e outra tentativa daqui a pouco (a barra não fica com a última foto do app).
/// Só termina quando ninguém mais lê a saída.
fn watchLoop(line: []const u8, fmt: proto.Format) u8 {
    var offline_shown = false;
    while (true) {
        var pb: [512]u8 = undefined;
        const path = portFile(&pb) orelse return complain(openError(error.NotRunning));
        if (ctl.Conn.open(path)) |opened| {
            var conn = opened;
            defer conn.close();
            if (conn.send(line)) if (conn.readLine(answer_ms)) |status| {
                switch (proto.parseReply(status) orelse proto.Reply{ .err = .{ .code = null, .text = status } }) {
                    .ok => {},
                    .err => |e| return complain(errText(e.code, e.text)),
                }
                offline_shown = false;
                while (conn.readLine(null)) |raw| {
                    const body = proto.unstuff(raw) orelse break;
                    if (!write(.out, body) or !write(.out, "\n")) return 0;
                }
            };
        } else |_| {}
        if (!offline_shown) {
            offline_shown = true;
            if (!offlineLine(fmt)) return 0;
        }
        c.SDL_Delay(retry_ms);
    }
}

/// A linha do app fechado, no formato do `watch`.
fn offlineLine(fmt: proto.Format) bool {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const l: proto.Labels = .{
        .head = i18n.tr("o larperCord não está aberto", "larperCord isn't running"),
        .offline = i18n.tr("fechado", "not running"),
    };
    const s: proto.Snapshot = .{ .connection = "not_running" };
    switch (fmt) {
        .json => out.appendSlice(alloc, "{\"running\":false,\"connected\":false}") catch return false,
        .waybar => proto.waybar(&out, alloc, &s, &l) catch return false,
        .text => proto.textLine(&out, alloc, &s, &l) catch return false,
    }
    out.append(alloc, '\n') catch return false;
    return write(.out, out.items);
}

fn printHelp() u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.appendSlice(alloc, i18n.tr(
        "larpercord ctl — controla o larperCord que está aberto\n\nuso: larpercord ctl COMANDO [ARGUMENTOS]\n\n",
        "larpercord ctl — controls the larperCord that is running\n\nusage: larpercord ctl COMMAND [ARGUMENTS]\n\n",
    )) catch return 1;
    app_ctl.writeHelp(&out, alloc) catch return 1;
    out.appendSlice(alloc, i18n.tr(
        "\nAperte para falar por um atalho do sistema: ptt-down ao apertar a tecla e ptt-up ao soltar\n" ++
            "(Configurações → Voz → Aperte para falar). Precisa de Configurações → Avançado →\n" ++
            "Controle externo ligado. Sai com 0 se deu certo, 1 se não.\n" ++
            "LARPER_CTL=1 nos dois lados fala com uma demonstração (--demo) aberta com ela.\n" ++
            "Exemplos (Hyprland, Sway, KDE, GNOME, waybar, polybar, Windows): docs/ctl.md\n",
        "\nPush to talk from a system shortcut: ptt-down on key press and ptt-up on release\n" ++
            "(Settings → Voice → Push to talk). Needs Settings → Advanced → External control on.\n" ++
            "Exits with 0 when it worked, 1 when it didn't.\n" ++
            "LARPER_CTL=1 on both sides talks to a demo (--demo) started with it.\n" ++
            "Examples (Hyprland, Sway, KDE, GNOME, waybar, polybar, Windows): docs/ctl.md\n",
    )) catch return 1;
    return if (write(.out, out.items)) 0 else 1;
}

fn complain(msg: []const u8) u8 {
    _ = write(.err, "larpercord ctl: ");
    _ = write(.err, msg);
    _ = write(.err, "\n");
    return 1;
}

// --- Saída -------------------------------------------------------------------------------

pub const Stream = enum { out, err };

/// Escreve tudo na saída padrão ou na de erros. Falso: ninguém está lendo (o waybar
/// fechou o cano, por exemplo).
pub fn write(which: Stream, bytes: []const u8) bool {
    if (sys.windows) return winWrite(which, bytes);
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(if (which == .out) 1 else 2, rest.ptr, rest.len);
        if (n < 0 and std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
        if (n <= 0) return false;
        rest = rest[@intCast(n)..];
    }
    return true;
}

var console_tried = false;
var console_out: ?c.HANDLE = null;

/// No Windows: a saída redirecionada (cano, arquivo) vem do GetStdHandle, como antes;
/// sem ela, o console de quem chamou, se houver um.
fn winHandle(which: Stream) ?c.HANDLE {
    const id: c.DWORD = if (which == .out) c.STD_OUTPUT_HANDLE else c.STD_ERROR_HANDLE;
    const h = c.GetStdHandle(id);
    if (h != null and h != c.INVALID_HANDLE_VALUE) return h;
    if (!console_tried) {
        console_tried = true;
        // ATTACH_PARENT_PROCESS ((DWORD)-1, que o translate-c não traduz).
        if (c.AttachConsole(0xFFFFFFFF) != 0) {
            const again = c.GetStdHandle(id);
            if (again != null and again != c.INVALID_HANDLE_VALUE) return again;
            const con = c.CreateFileA("CONOUT$", c.GENERIC_READ | c.GENERIC_WRITE, c.FILE_SHARE_READ | c.FILE_SHARE_WRITE, null, c.OPEN_EXISTING, 0, null);
            if (con != c.INVALID_HANDLE_VALUE) console_out = con;
        }
    } else {
        const again = c.GetStdHandle(id);
        if (again != null and again != c.INVALID_HANDLE_VALUE) return again;
    }
    return console_out;
}

fn winWrite(which: Stream, bytes: []const u8) bool {
    const h = winHandle(which) orelse return false;
    var mode: c.DWORD = 0;
    if (c.GetConsoleMode(h, &mode) != 0) {
        // No console, em UTF-16: em bytes, os acentos sairiam na página de código dele.
        var rest = bytes;
        while (rest.len > 0) {
            var n = @min(rest.len, 2048);
            // Sem cortar um caractere no meio.
            while (n < rest.len and n > 0 and (rest[n] & 0xC0) == 0x80) n -= 1;
            if (n == 0) n = @min(rest.len, 2048);
            var wide: [2048]u16 = undefined;
            const wn = c.MultiByteToWideChar(65001, 0, rest.ptr, @intCast(n), &wide, wide.len);
            if (wn <= 0) return false;
            var done: c.DWORD = 0;
            if (c.WriteConsoleW(h, &wide, @intCast(wn), &done, null) == 0) return false;
            rest = rest[n..];
        }
        return true;
    }
    var rest = bytes;
    while (rest.len > 0) {
        var done: c.DWORD = 0;
        if (c.WriteFile(h, rest.ptr, @intCast(@min(rest.len, 1 << 30)), &done, null) == 0 or done == 0) return false;
        rest = rest[done..];
    }
    return true;
}
