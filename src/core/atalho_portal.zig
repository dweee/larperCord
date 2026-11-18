//! Nome da tecla no formato XDG (keysym sem o prefixo XKB_KEY_).
const std = @import("std");

pub fn trigger(buf: *[16]u8, scan: u16, key: u32) ?[:0]const u8 {
    switch (scan) {
        58...69 => return std.fmt.bufPrintSentinel(buf, "F{d}", .{scan - 57}, 0) catch unreachable,
        104...115 => return std.fmt.bufPrintSentinel(buf, "F{d}", .{scan - 91}, 0) catch unreachable,
        40 => return "Return",
        41 => return "Escape",
        42 => return "BackSpace",
        43 => return "Tab",
        57 => return "Caps_Lock",
        70 => return "Print",
        71 => return "Scroll_Lock",
        72 => return "Pause",
        73 => return "Insert",
        74 => return "Home",
        75 => return "Page_Up",
        76 => return "Delete",
        77 => return "End",
        78 => return "Page_Down",
        79 => return "Right",
        80 => return "Left",
        81 => return "Down",
        82 => return "Up",
        83 => return "Num_Lock",
        84 => return "KP_Divide",
        85 => return "KP_Multiply",
        86 => return "KP_Subtract",
        87 => return "KP_Add",
        88 => return "KP_Enter",
        89...97 => return std.fmt.bufPrintSentinel(buf, "KP_{d}", .{scan - 88}, 0) catch unreachable,
        98 => return "KP_0",
        99 => return "KP_Decimal",
        224 => return "Control_L",
        225 => return "Shift_L",
        226 => return "Alt_L",
        227 => return "Super_L",
        228 => return "Control_R",
        229 => return "Shift_R",
        230 => return "Alt_R",
        231 => return "Super_R",
        else => {},
    }
    return switch (key) {
        'a'...'z', 'A'...'Z', '0'...'9' => blk: {
            buf[0] = std.ascii.toLower(@intCast(key));
            buf[1] = 0;
            break :blk buf[0..1 :0];
        },
        ' ' => "space",
        '-' => "minus",
        '=' => "equal",
        '[' => "bracketleft",
        ']' => "bracketright",
        '\\' => "backslash",
        ';' => "semicolon",
        '\'' => "apostrophe",
        '`' => "grave",
        ',' => "comma",
        '.' => "period",
        '/' => "slash",
        0x00a0...0x10ffff => std.fmt.bufPrintSentinel(buf, "U{X:0>4}", .{key}, 0) catch unreachable,
        else => null,
    };
}

test "atalho do portal usa o leiaute e distingue teclas especiais" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("q", trigger(&buf, 4, 'q').?);
    try std.testing.expectEqualStrings("F13", trigger(&buf, 104, 0).?);
    try std.testing.expectEqualStrings("F24", trigger(&buf, 115, 0).?);
    try std.testing.expectEqualStrings("space", trigger(&buf, 44, ' ').?);
    try std.testing.expectEqualStrings("KP_1", trigger(&buf, 89, '1').?);
    try std.testing.expect(trigger(&buf, 0, 0) == null);
}
