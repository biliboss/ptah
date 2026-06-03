// Drives macOS `say`. v0.2 still spawns a fresh `say` per message; pre-warm
// is best-effort and may not survive across spawns. v1.0 will revisit
// embedding AVSpeechSynthesizer via Cocoa if TTFA stalls above target.

const std = @import("std");
const ipc = @import("ipc.zig");

pub const SAY_PATH = "/usr/bin/say";

pub fn play(arena: std.mem.Allocator, io: std.Io, msg: ipc.Message) !void {
    const rate_str = try std.fmt.allocPrint(arena, "{d}", .{msg.rate});

    const argv = [_][]const u8{
        SAY_PATH,
        "-v",
        msg.voice,
        "-r",
        rate_str,
        msg.text,
    };

    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("[tts] say exited code={d}\n", .{code});
            return error.SayFailed;
        },
        else => {
            std.debug.print("[tts] say abnormal term\n", .{});
            return error.SayFailed;
        },
    }
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
