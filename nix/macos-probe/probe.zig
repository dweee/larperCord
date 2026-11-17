//! macOS runtime probe for CI (fork-only, not part of the client). It is
//! copied next to src/ and compiled against the client's own platform code,
//! so these are the exact functions the app runs:
//!
//!   probe keychain     store, update, read and delete a dummy token through
//!                      sys.keychain* under a test service name
//!   probe ffmpeg       load FFmpeg the way a video does (ffmpeg.get); run from
//!                      inside an .app it must come from Contents/Frameworks
//!   probe open <url>   SDL_OpenURL, which the app uses for every link
const std = @import("std");
const c = @import("c");
const sys = @import("platform/sys.zig");
const ffmpeg = @import("platform/ffmpeg.zig");

const service = "larpercord-ci-test";
const account = "4242";

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("FAIL: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn readBack(buf: []u8) ?[]const u8 {
    const got = sys.keychainRead(service, account, buf) orelse return null;
    return std.mem.trim(u8, got, " \r\n");
}

fn keychain() void {
    const first = "MTIzNDU2Nzg5MDEyMzQ1Njc4OTA.ci-test.dummy_token-one";
    const second = "MTIzNDU2Nzg5MDEyMzQ1Njc4OTA.ci-test.dummy_token-two";
    var buf: [256]u8 = undefined;
    sys.keychainDelete(service, null);
    if (readBack(&buf) != null) fail("an old test entry is still there", .{});
    if (!sys.keychainWrite(service, account, "larperCord (CI test)", first)) fail("keychainWrite (new entry)", .{});
    const a = readBack(&buf) orelse fail("keychainRead after the first write", .{});
    if (!std.mem.eql(u8, a, first)) fail("read {s}, wrote {s}", .{ a, first });
    // A second "Remember" for the same account replaces the secret (-U).
    if (!sys.keychainWrite(service, account, "larperCord (CI test)", second)) fail("keychainWrite (update)", .{});
    const b = readBack(&buf) orelse fail("keychainRead after the update", .{});
    if (!std.mem.eql(u8, b, second)) fail("read {s} after the update, wrote {s}", .{ b, second });
    // Values that cannot travel safely on the `security -i` line are refused.
    if (sys.keychainWrite(service, account, "x", "bad token\nadd-generic-password")) fail("an unsafe token was accepted", .{});
    sys.keychainDelete(service, account);
    if (readBack(&buf) != null) fail("the entry survived keychainDelete", .{});
    std.debug.print("keychain: stored, updated, read and deleted {s}/{s}\n", .{ service, account });
}

fn loadFfmpeg() void {
    if (ffmpeg.get() == null) {
        var dg: ffmpeg.Diag = undefined;
        ffmpeg.diagnosis(&dg);
        fail("FFmpeg did not load (failed file: {s}: {s})", .{ dg.failed_file.slice(), dg.failed_why.slice() });
    }
    var eb: [1024]u8 = undefined;
    std.debug.print("ffmpeg: FFmpeg {d} from {t} {s} (exe {s})\n", .{
        ffmpeg.loadedVersion(),
        ffmpeg.loadedSource(),
        ffmpeg.loadedDir(),
        sys.selfExe(&eb) orelse "?",
    });
}

fn openUrl(url: [:0]const u8) void {
    if (!c.SDL_OpenURL(url.ptr)) fail("SDL_OpenURL({s}): {s}", .{ url, c.SDL_GetError() });
    std.debug.print("open: SDL_OpenURL({s}) succeeded\n", .{url});
}

pub fn main(init: std.process.Init.Minimal) void {
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.skip();
    const cmd = it.next() orelse fail("usage: probe keychain|ffmpeg|open <url>", .{});
    if (std.mem.eql(u8, cmd, "keychain")) return keychain();
    if (std.mem.eql(u8, cmd, "ffmpeg")) return loadFfmpeg();
    if (std.mem.eql(u8, cmd, "open")) return openUrl(it.next() orelse fail("open needs a URL", .{}));
    fail("unknown command {s}", .{cmd});
}
