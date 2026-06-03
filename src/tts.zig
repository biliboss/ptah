// SPDX-License-Identifier: MIT OR Apache-2.0
// Drives macOS `say`. The daemon worker calls `spawnSay` (v0.3) so it can
// register the child PID with the queue (for SKIP → SIGTERM) before blocking
// on wait().
//
// v0.5: text is run through `preproc.process` before being handed to `say`
// (Pt-BR abbreviations, cardinal numbers, [[slnc N]] pauses). Failure of
// the preprocessor is non-fatal — we log and fall back to the raw text.

const std = @import("std");
const ipc = @import("ipc.zig");
const preproc = @import("preproc.zig");

pub const SAY_PATH = "/usr/bin/say";

pub const Spawned = struct {
    child: std.process.Child,
    rate_str: []const u8, // owned by arena passed to spawnSay
};

pub fn spawnSay(arena: std.mem.Allocator, io: std.Io, voice: []const u8, rate: u32, text: []const u8) !Spawned {
    const rate_str = try std.fmt.allocPrint(arena, "{d}", .{rate});

    const spoken: []const u8 = preproc.process(arena, text) catch |e| blk: {
        std.debug.print("[tts] preproc failed ({s}); falling back to raw text\n", .{@errorName(e)});
        break :blk text;
    };

    const argv = [_][]const u8{
        SAY_PATH,
        "-v",
        voice,
        "-r",
        rate_str,
        spoken,
    };
    const child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    return .{ .child = child, .rate_str = rate_str };
}

// Pre-warm the Speech Synthesis Manager: empty utterance loads the voice
// model into the Neural Engine so the next real play hits the cache.
pub fn preWarm(arena: std.mem.Allocator, io: std.Io, voice: []const u8) !void {
    const argv = [_][]const u8{ SAY_PATH, "-v", voice, " " };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try child.wait(io);
    _ = arena;
}
