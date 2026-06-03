// SPDX-License-Identifier: MIT OR Apache-2.0
// System TTS engine dispatcher. The daemon worker calls `spawnSay` (v0.3
// name kept for back-compat — see Spawned struct) so it can register the
// child PID with the queue (for SKIP → SIGTERM) before blocking on wait().
//
// v0.5: text is run through `preproc.process` before being handed to the
// system engine (Pt-BR abbreviations, cardinal numbers, [[slnc N]] pauses).
// Failure of the preprocessor is non-fatal — we log and fall back to the
// raw text.
//
// v1.3 — Cross-platform:
//   - macOS:   /usr/bin/say -v <voice> -r <rate> <text>   (existing path)
//   - linux:   espeak-ng -v pt-br -s <rate> <text>        (NEW)
//   - windows: powershell -c "Add-Type ... SpeechSynthesizer"  (best-effort,
//              code path compiled but runtime untested)
//
// `[[slnc N]]` cues from the preprocessor only render on macOS `say`.
// espeak-ng and System.Speech ignore them silently. The cardinal/abbrev
// transforms still help across platforms; the pause cues just no-op.
//
// Pre-warm is macOS-only — `espeak-ng` and System.Speech have no equivalent
// to the Neural Engine voice cache. Non-macOS callers get a no-op so the
// daemon boot path stays identical.

const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("ipc.zig");
const preproc = @import("preproc.zig");
const platform = @import("platform.zig");

pub const SAY_PATH = "/usr/bin/say";
pub const ESPEAK_NAME = "espeak-ng";

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

    // Per-platform argv. Comptime switch so dead branches drop out of the
    // binary on the host target.
    const argv: []const []const u8 = switch (comptime platform.current()) {
        .macos => &[_][]const u8{
            SAY_PATH,
            "-v",
            voice,
            "-r",
            rate_str,
            spoken,
        },
        .linux => &[_][]const u8{
            // espeak-ng quirks vs say:
            //   -v <voice>  : "pt-br" not "Luciana". Caller still passes the
            //                  macOS voice name; we map a few common ones,
            //                  fall through to literal otherwise.
            //   -s <wpm>    : same semantic as `say -r`.
            //   text       : single positional arg (no -- separator needed).
            ESPEAK_NAME,
            "-v",
            mapLinuxVoice(voice),
            "-s",
            rate_str,
            spoken,
        },
        .windows => blk: {
            // Best-effort Windows path. Spawns powershell + loads
            // System.Speech.SpeechSynthesizer + calls Speak(<text>).
            // Voice / rate not threaded through yet — needs a templated
            // -Command string. Marked TODO until somebody validates it.
            const ps_cmd = try std.fmt.allocPrint(
                arena,
                "Add-Type -AssemblyName System.Speech; " ++
                    "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; " ++
                    "$s.Speak('{s}')",
                .{spoken},
            );
            break :blk &[_][]const u8{
                "powershell",
                "-NoProfile",
                "-Command",
                ps_cmd,
            };
        },
    };
    const child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    return .{ .child = child, .rate_str = rate_str };
}

// Pre-warm the Speech Synthesis Manager: empty utterance loads the voice
// model into the Neural Engine so the next real play hits the cache.
// macOS-only — espeak-ng has no equivalent warm cache, System.Speech
// initialises lazily inside powershell startup which we don't keep alive.
pub fn preWarm(arena: std.mem.Allocator, io: std.Io, voice: []const u8) !void {
    switch (comptime platform.current()) {
        .macos => {
            const argv = [_][]const u8{ SAY_PATH, "-v", voice, " " };
            var child = try std.process.spawn(io, .{
                .argv = &argv,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            _ = try child.wait(io);
            _ = arena;
        },
        .linux, .windows => {
            // No-op. Stays a function call so the daemon boot path doesn't
            // branch on platform. Params accepted for signature parity.
        },
    }
}

// Map a macOS voice name to an espeak-ng voice identifier. The macOS-named
// voices stay valid client-side defaults; on Linux we translate.
//
// We pass through anything we don't recognise — espeak-ng accepts language
// codes (`pt-br`), variant codes (`mb-br1`), and full names. A literal
// "Luciana" simply prints a warning from espeak-ng and falls back to
// the default voice; that's the best behaviour we can give without a
// platform-aware client.
fn mapLinuxVoice(voice: []const u8) []const u8 {
    if (std.mem.eql(u8, voice, "Luciana") or
        std.mem.eql(u8, voice, "Luciana (Premium)") or
        std.mem.eql(u8, voice, "Felipe") or
        std.mem.eql(u8, voice, "Felipe (Premium)"))
    {
        return "pt-br";
    }
    return voice;
}

test "mapLinuxVoice translates macOS Pt-BR voices" {
    try std.testing.expectEqualStrings("pt-br", mapLinuxVoice("Luciana"));
    try std.testing.expectEqualStrings("pt-br", mapLinuxVoice("Luciana (Premium)"));
    try std.testing.expectEqualStrings("pt-br", mapLinuxVoice("Felipe"));
    try std.testing.expectEqualStrings("pt-br", mapLinuxVoice("Felipe (Premium)"));
    try std.testing.expectEqualStrings("en-us", mapLinuxVoice("en-us"));
    try std.testing.expectEqualStrings("mb-br1", mapLinuxVoice("mb-br1"));
}
