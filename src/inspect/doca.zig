//! Onde a janela do Inspetor fica: encaixada à direita ou embaixo (o app passa a caber
//! no que sobra, como a página com as ferramentas do navegador abertas) ou solta por
//! cima. Separado da janela em si para o layout (ui/root.zig) saber o espaço sem
//! depender do resto do Inspetor.
const std = @import("std");
const layout = @import("../theme/layout.zig");

pub const Rect = layout.Rect;
pub const Lado = enum { direita, baixo, solta };

pub var aberto = false;
pub var lado: Lado = .direita;
/// Largura (à direita) e altura (embaixo) escolhidas, em pontos.
pub var largura: f32 = 600;
pub var altura: f32 = 340;
/// Solta: posição e tamanho.
pub var solta: Rect = .{ .x = 80, .y = 80, .w = 760, .h = 520 };
/// O retângulo do Inspetor neste quadro (o que `reserve` deixou para ele).
pub var area: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

/// O app nunca fica menor que isto: abaixo, o Inspetor encolhe.
const min_app_w: f32 = 560;
const min_app_h: f32 = 260;

/// O espaço do app com o Inspetor aberto; `area` fica com o do Inspetor.
pub fn reserve(win: Rect) Rect {
    if (!aberto) return win;
    switch (lado) {
        .direita => {
            const w = std.math.clamp(largura, 300, @max(300, win.w - min_app_w));
            area = .{ .x = win.right() - w, .y = win.y, .w = w, .h = win.h };
            var r = win;
            r.w = @max(0, win.w - w);
            return r;
        },
        .baixo => {
            const h = std.math.clamp(altura, 160, @max(160, win.h - min_app_h));
            area = .{ .x = win.x, .y = win.bottom() - h, .w = win.w, .h = h };
            var r = win;
            r.h = @max(0, win.h - h);
            return r;
        },
        .solta => {
            var s = solta;
            s.w = std.math.clamp(s.w, 360, @max(360, win.w));
            s.h = std.math.clamp(s.h, 220, @max(220, win.h));
            s.x = std.math.clamp(s.x, win.x - s.w + 80, win.right() - 80);
            s.y = std.math.clamp(s.y, win.y, win.bottom() - 40);
            area = s;
            return win;
        },
    }
}

const t = std.testing;

test "encaixado: o app fica com o resto, nunca menor que o mínimo" {
    aberto = true;
    defer aberto = false;
    lado = .direita;
    largura = 500;
    const win: Rect = .{ .x = 0, .y = 0, .w = 1200, .h = 800 };
    const app = reserve(win);
    try t.expectEqual(@as(f32, 700), app.w);
    try t.expectEqual(@as(f32, 700), area.x);
    // Janela estreita: o Inspetor encolhe até o mínimo dele, e o app fica com o resto.
    const small = reserve(.{ .x = 0, .y = 0, .w = 800, .h = 600 });
    try t.expectEqual(@as(f32, 500), small.w);
    const wide = reserve(.{ .x = 0, .y = 0, .w = 1100, .h = 600 });
    try t.expectEqual(@as(f32, 600), wide.w);
    lado = .baixo;
    altura = 300;
    const b = reserve(win);
    try t.expectEqual(@as(f32, 500), b.h);
    try t.expectEqual(@as(f32, 500), area.y);
    // Solta: o app não perde nada.
    lado = .solta;
    try t.expectEqual(win.w, reserve(win).w);
}
