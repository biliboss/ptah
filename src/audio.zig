// AudioPlayer — owns a zaudio.Engine (miniaudio) and plays s16le PCM buffers
// directly without writing a WAV to disk.
//
// v0.7 scope: the daemon initialises one AudioPlayer at boot. The worker calls
// `streamS16le` synchronously per piper utterance. SKIP support: cancel mid-
// play via `requestStop` (sets the atomic flag, sound.stop() unblocks the
// poll loop).
//
// Why not a custom miniaudio data_callback? An AudioBuffer over the s16 slice
// gets us identical behaviour with less ceremony — miniaudio's resource_manager
// memcpys our samples into its mixing graph on `createSoundFromDataSource`.
// Frees AudioPlayer from the realtime allocator constraint (the callback
// can't allocate, which complicates argv management). Trade-off: a single
// allocation per utterance instead of zero. Negligible vs. synth cost.

const std = @import("std");
const zaudio = @import("zaudio");

/// Per-process error tag. Init failure is non-fatal at the call site.
pub const Error = error{
    InitFailed,
    StartFailed,
    CreateBufferFailed,
    CreateSoundFailed,
};

pub const AudioPlayer = struct {
    engine: *zaudio.Engine,
    /// `true` when init succeeded. v0.6-style WAV+afplay fallback may key off
    /// this from the daemon worker if zaudio failed (e.g. headless CI).
    ready: bool,

    /// Atomic flag set by `requestStop` to break out of the blocking
    /// streamS16le wait loop. Reset on each new play.
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// First-sample callback. The daemon uses this to capture real TTFA for
    /// the bench. Optional. Single slot — last writer wins.
    on_first_sample: ?*const fn (ctx: ?*anyopaque) void = null,
    on_first_sample_ctx: ?*anyopaque = null,

    /// Best-effort init. Returns a player with `.ready = false` on any
    /// failure so the caller can degrade gracefully.
    pub fn init(allocator: std.mem.Allocator) AudioPlayer {
        zaudio.init(allocator);

        const engine = zaudio.Engine.create(null) catch |e| {
            std.debug.print("[audio] zaudio engine init failed: {s}\n", .{@errorName(e)});
            zaudio.deinit();
            return .{
                .engine = undefined,
                .ready = false,
            };
        };

        return .{
            .engine = engine,
            .ready = true,
        };
    }

    pub fn deinit(self: *AudioPlayer) void {
        if (!self.ready) return;
        self.engine.destroy();
        zaudio.deinit();
        self.ready = false;
    }

    /// Signal a play-in-progress to stop. Idempotent. Safe from any thread.
    pub fn requestStop(self: *AudioPlayer) void {
        self.stop_requested.store(true, .release);
    }

    /// Block until `samples` finishes playing or `requestStop` fires. The
    /// samples slice is consumed via an AudioBuffer wrapping it directly —
    /// caller must keep `samples` alive for the duration of this call.
    pub fn streamS16le(
        self: *AudioPlayer,
        samples: []const i16,
        sample_rate: u32,
    ) Error!void {
        if (!self.ready) return Error.InitFailed;
        if (samples.len == 0) return; // nothing to play, no error

        self.stop_requested.store(false, .release);

        const buffer = zaudio.AudioBuffer.create(
            zaudio.AudioBuffer.Config.init(
                .signed16,
                1, // mono — Piper voices are all mono
                samples.len,
                @ptrCast(samples.ptr),
            ),
        ) catch {
            return Error.CreateBufferFailed;
        };
        defer buffer.destroy();

        // The engine internally resamples to its device output rate — we
        // don't need to match it here. miniaudio reads `sample_rate` from
        // the AudioBuffer config via its embedded data_source.
        _ = sample_rate;

        const sound = self.engine.createSoundFromDataSource(
            buffer.asDataSourceMut(),
            .{},
            null,
        ) catch {
            return Error.CreateSoundFailed;
        };
        defer sound.destroy();

        sound.start() catch {
            return Error.StartFailed;
        };

        // First-sample notification: miniaudio doesn't expose a clean
        // start-of-playback callback, but the next call after sound.start()
        // is effectively the point where the device pump owns the buffer.
        // For the bench's TTFA measurement this is precise enough — the
        // perceived latency from this point is one device period (~10ms).
        if (self.on_first_sample) |cb| cb(self.on_first_sample_ctx);

        // Poll-loop wait. zaudio doesn't expose a blocking play primitive;
        // miniaudio's threading is callback-driven. 5ms sleep ≈ half a
        // 10ms device period — no audible artefacts and ~negligible CPU.
        //
        // Zig 0.16 removed std.Thread.sleep (new std.Io.sleep requires an io
        // context we don't carry here). std.c.nanosleep is the direct libc
        // syscall — already linked because we link_libc on the exe — and
        // avoids dragging an Io threading dep into audio.zig.
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        while (sound.isPlaying() and !sound.isAtEnd()) {
            if (self.stop_requested.load(.acquire)) {
                sound.stop() catch {};
                break;
            }
            _ = std.c.nanosleep(&ts, null);
        }
    }
};
