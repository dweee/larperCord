//! A pasta temporária só nossa, <temp>/larpercord-privados-<pid> (só o dono entra), onde
//! ficam as imagens coladas, as editadas na bandeja (ui/editor_imagem.zig) e as cópias
//! sem localização que a rede manda (net/envio_limpo.zig). Cada arquivo numa subpasta
//! própria: o nome dele é o que vai para o Discord, e dois com o mesmo nome não se
//! atropelam. Quem envia apaga depois de enviado; o que sobrar (um envio que falhou e foi
//! descartado) vai embora junto com a pasta ao fechar o app.
const std = @import("std");
const c = @import("c");
const sys = @import("sys.zig");
const types = @import("../core/types.zig");

/// As subpastas numeradas (a rede e a interface criam ao mesmo tempo).
var seq: std.atomic.Value(u32) = .init(0);

fn base(buf: []u8) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}{d}", .{ sys.tempDir(), types.private_dir_prefix, c.getpid() }, 0) catch null;
}

/// Cria a pasta só para o dono. Uma que já existia e não é só nossa (outro usuário
/// criou antes, no /tmp comum) não serve.
fn criar(dir: [:0]const u8) bool {
    if (sys.windows) {
        // A do SDL entende UTF-8 (o %TEMP% de "João" também).
        _ = c.SDL_CreateDirectory(dir.ptr);
        return sys.exists(dir.ptr);
    }
    sys.mkdirPrivate(dir.ptr);
    _ = c.chmod(dir.ptr, 0o700);
    return sys.ownerOnly(dir.ptr);
}

/// Um caminho novo, <pasta>/<n>/<nome>, com a subpasta já criada. null: sem pasta
/// temporária que sirva, ou o nome não cabe.
pub fn novo(buf: []u8, nome: []const u8) ?[:0]const u8 {
    var bb: [512]u8 = undefined;
    const dir = base(&bb) orelse return null;
    if (!criar(dir)) return null;
    var sb: [560]u8 = undefined;
    const sub = std.fmt.bufPrintSentinel(&sb, "{s}/{d}", .{ dir, seq.fetchAdd(1, .monotonic) + 1 }, 0) catch return null;
    if (!criar(sub)) return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ sub, nome }, 0) catch null;
}

/// Apaga um arquivo temporário nosso (types.isPastedFile) e, se ele morava numa subpasta
/// da pasta privada, a subpasta junto.
pub fn apagar(path: []const u8) void {
    var b: [1100]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&b, "{s}", .{path}, 0) catch return;
    _ = c.SDL_RemovePath(z.ptr);
    if (!types.isPrivateFile(path)) return;
    const cut = std.mem.lastIndexOfAny(u8, z, "/\\") orelse return;
    z[cut] = 0;
    _ = c.SDL_RemovePath(z.ptr);
}

/// Ao fechar o app: a pasta inteira, com o que ficou nela.
pub fn limparTudo() void {
    var bb: [512]u8 = undefined;
    const dir = base(&bb) orelse return;
    apagarPasta(dir, 0);
}

fn apagarPasta(dir: [:0]const u8, nivel: u8) void {
    // A pasta, as subpastas e os arquivos delas; nada mais fundo é nosso.
    var n: c_int = 0;
    const lista = if (nivel < 2) c.SDL_GlobDirectory(dir.ptr, null, 0, &n) else null;
    if (lista != null) {
        defer c.SDL_free(@ptrCast(lista));
        for (0..@intCast(@max(n, 0))) |i| {
            var b: [1100]u8 = undefined;
            const p = std.fmt.bufPrintSentinel(&b, "{s}/{s}", .{ dir, std.mem.span(lista[i]) }, 0) catch continue;
            var info: c.SDL_PathInfo = undefined;
            if (!c.SDL_GetPathInfo(p.ptr, &info)) continue;
            if (info.type == c.SDL_PATHTYPE_DIRECTORY) apagarPasta(p, nivel + 1) else _ = c.SDL_RemovePath(p.ptr);
        }
    }
    _ = c.SDL_RemovePath(dir.ptr);
}
