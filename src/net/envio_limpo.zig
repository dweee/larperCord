//! A cópia sem a localização e sem os dados da câmera de cada arquivo que vai para o
//! Discord (Configurações → Privacidade), feita na thread da rede logo antes do pedido:
//! a interface não espera, e um arquivo de 10 MB é lido uma vez só. A conta fica em
//! core/metadados.zig; a cópia, na pasta temporária só nossa (platform/temporarios.zig),
//! enquanto o pedido anda, e sai quando ele acaba, tenha dado certo ou não (o "tentar de
//! novo" limpa outra vez a partir do original, que nunca muda). Os dois gateways (o de
//! verdade e o da demonstração) passam por aqui.
const std = @import("std");
const c = @import("c");
const metadados = @import("../core/metadados.zig");
const temporarios = @import("../platform/temporarios.zig");

const alloc = std.heap.c_allocator;

/// Maior que isto vai como está: o app não deixa anexar mais de 10 MB, e um vídeo enorme
/// inteiro na memória não compensa.
const max_bytes: usize = 64 * 1024 * 1024;

pub const Preparo = union(enum) {
    /// Vai o arquivo da pessoa: nada a tirar, um formato que não mexemos, ou quebrado.
    original,
    /// Vai esta cópia (c_allocator); `soltar` depois do pedido.
    limpo: [:0]u8,
    /// Tinha o que tirar e a cópia não saiu (sem memória, sem pasta temporária): melhor
    /// não mandar do que mandar com o GPS que a pessoa pediu para tirar.
    falhou,
};

pub fn preparar(path: [:0]const u8) Preparo {
    // Os primeiros bytes dizem se é um dos formatos; o resto só é lido se for.
    var cab: [16]u8 = undefined;
    const io = c.SDL_IOFromFile(path.ptr, "rb") orelse return .original;
    const n = c.SDL_ReadIO(io, &cab, cab.len);
    _ = c.SDL_CloseIO(io);
    if (metadados.formato(cab[0..n]) == .outro) return .original;
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return .original;
    defer c.SDL_free(data);
    if (size > max_bytes) return .original;
    const bytes = @as([*]const u8, @ptrCast(data))[0..size];
    const limpo = (metadados.limpar(alloc, bytes) catch |e| return switch (e) {
        error.Malformado => .original,
        error.OutOfMemory => .falhou,
    }) orelse return .original;
    defer alloc.free(limpo);
    var pb: [1100]u8 = undefined;
    // Com o mesmo nome: é o que vai para o Discord.
    const novo = temporarios.novo(&pb, std.fs.path.basename(path)) orelse return .falhou;
    if (!c.SDL_SaveFile(novo.ptr, limpo.ptr, limpo.len)) {
        temporarios.apagar(novo);
        return .falhou;
    }
    const owned = alloc.dupeSentinel(u8, novo, 0) catch {
        temporarios.apagar(novo);
        return .falhou;
    };
    return .{ .limpo = owned };
}

/// Depois do pedido: apaga a cópia (o original fica).
pub fn soltar(p: Preparo) void {
    switch (p) {
        .limpo => |path| {
            temporarios.apagar(path);
            alloc.free(path);
        },
        else => {},
    }
}
