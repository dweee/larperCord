//! QA do arrastar para mover de call (ui/arrastar_voz.zig): na call do servidor da
//! demonstração, arrastar a Ana até outro canal de voz move ela; soltar fora não move.
//!
//! `QA_SUITE=arrastar` roda isto.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const arrastar = @import("ui/arrastar_voz.zig");
const Id = types.Id;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}

const g0: Id = gw.guildId(0);
const madrugada: Id = gw.channelId(0, 13);
const jogando: Id = gw.channelId(0, 14);
const ana: Id = 1001;

fn openGuild0(app: *App) void {
    app.handle(.{ .select_guild = g0 });
}
fn anaIn(comptime ch: Id) fn (*App) bool {
    return struct {
        fn f(app: *App) bool {
            return app.store.voiceChannelOf(ana, app.st.guild) == ch and arrastar.arraste == null;
        }
    }.f;
}
fn marks(_: *App) bool {
    return qa.find("voice-member:500014:1001") != null and qa.find("channel:500015") != null;
}
fn tMember(_: *App, b: []u8) []const u8 {
    return std.fmt.bufPrint(b, "voice-member:{d}:{d}", .{ madrugada, ana }) catch "";
}
fn tTarget(_: *App, b: []u8) []const u8 {
    return std.fmt.bufPrint(b, "channel:{d}", .{jogando}) catch "";
}

pub const ops = [_]Op{
    s("arrastar para mover de call"),
    run(openGuild0),
    expect("a Ana está na Call da madrugada", anaIn(madrugada)),
    expect("as linhas da call e do outro canal estão na tela", marks),
    .{ .drag = .{ .from = .{ .dyn = tMember }, .to = .{ .mark = "guild-header" } } },
    expect("soltar fora de um canal de voz não move", anaIn(madrugada)),
    .{ .drag = .{ .from = .{ .dyn = tMember }, .to = .{ .dyn = tTarget } } },
    expect("soltar no canal Jogando move a Ana para lá", anaIn(jogando)),
};
