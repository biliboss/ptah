// SPDX-License-Identifier: MIT OR Apache-2.0
// AudioPlayer — afplay-only stub (no audio-library dependency, v0.7+ → Ptah).
//
// Ptah ships a single engine (Kokoro Dora) which synthesises a whole utterance
// at once. We play it with macOS-native `afplay` (write s16le → temp WAV →
// spawn afplay) from the daemon's `playViaAfplay`. That keeps the binary
// dependency-free (no vendored audio library) — Gabriel's "zero peso".
//
// This type stays as a thin, always-not-ready shim so the daemon's existing
// `if (audio_player.ready) <stream> else <afplay>` branch always takes the
// afplay path. The public API is preserved so callers compile unchanged;
// every method is a safe no-op. requestStop sets a flag the daemon can read
// to decide whether to kill the in-flight afplay child.

const std = @import("std");
const alog = std.log.scoped(.audio);

/// Per-process error tag. With the afplay-only player, streaming always
/// reports InitFailed (ready=false) so the daemon falls back to afplay.
pub const Error = error{
    InitFailed,
    StartFailed,
    CreateBufferFailed,
    CreateSoundFailed,
};

pub const AudioPlayer = struct {
    /// Always false — playback goes through the daemon's afplay path.
    ready: bool = false,

    /// Set by `requestStop` so the daemon can cancel an in-flight afplay.
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// First-sample callback slot (bench TTFA hook). Kept for API parity.
    on_first_sample: ?*const fn (ctx: ?*anyopaque) void = null,
    on_first_sample_ctx: ?*anyopaque = null,

    /// Pause state machine — retained for API parity; afplay is fire-and-forget
    /// so there is no live sound to pause, and these always short-circuit.
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    paused_at_ns: std.atomic.Value(i128) = std.atomic.Value(i128).init(0),

    /// Always returns a not-ready player; the daemon uses afplay.
    pub fn init(allocator: std.mem.Allocator) AudioPlayer {
        _ = allocator;
        alog.info("audio: afplay-only player (no audio-lib dep — zero vendor weight)", .{});
        return .{ .ready = false };
    }

    pub fn deinit(self: *AudioPlayer) void {
        _ = self;
    }

    /// Signal an in-flight play to stop. Idempotent, thread-safe. The daemon
    /// reads this flag to decide whether to terminate the afplay child.
    pub fn requestStop(self: *AudioPlayer) void {
        self.stop_requested.store(true, .release);
    }

    /// No live sound in afplay mode — nothing to pause.
    pub fn pause(self: *AudioPlayer) bool {
        _ = self;
        return false;
    }

    /// Counterpart to `pause`. Nothing paused → false.
    pub fn resume_play(self: *AudioPlayer) bool {
        _ = self;
        return false;
    }

    pub fn is_paused(self: *const AudioPlayer) bool {
        return self.paused.load(.acquire);
    }

    /// API parity with the old streaming player. Always reports not-ready so
    /// the daemon takes the afplay branch.
    pub fn streamS16leAppend(
        self: *AudioPlayer,
        samples: []const i16,
        sample_rate: u32,
    ) Error!void {
        return self.streamS16le(samples, sample_rate);
    }

    pub fn streamS16le(
        self: *AudioPlayer,
        samples: []const i16,
        sample_rate: u32,
    ) Error!void {
        _ = self;
        _ = samples;
        _ = sample_rate;
        return Error.InitFailed;
    }
};

// ---- tests ----

test "AudioPlayer is not ready (afplay-only) and pause/resume are no-ops" {
    var player: AudioPlayer = .{};
    try std.testing.expectEqual(false, player.ready);
    try std.testing.expectEqual(false, player.is_paused());
    try std.testing.expectEqual(false, player.pause());
    try std.testing.expectEqual(false, player.resume_play());
    try std.testing.expectError(Error.InitFailed, player.streamS16le(&[_]i16{ 1, 2, 3 }, 24000));
}

test "AudioPlayer requestStop latches the flag" {
    var player: AudioPlayer = .{};
    try std.testing.expectEqual(false, player.stop_requested.load(.acquire));
    player.requestStop();
    try std.testing.expectEqual(true, player.stop_requested.load(.acquire));
}
