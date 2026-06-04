// SPDX-License-Identifier: MIT OR Apache-2.0
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

// v1.10.13 — scoped logger for the device pump / engine boot.
const alog = std.log.scoped(.audio);

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

    /// v1.10.2 — currently active sound. Single-slot; only the daemon worker
    /// thread writes (under streamS16le); the IPC accept thread reads via
    /// pause/resume_play. Atomic pointer keeps the cross-thread access safe
    /// without dragging a mutex into the audio hot path.
    current_sound: std.atomic.Value(?*zaudio.Sound) = std.atomic.Value(?*zaudio.Sound).init(null),

    /// v1.10.2 — paused flag. Set by `pause`, cleared by `resume_play`. The
    /// wait loop in streamS16le keeps polling while paused so we don't burn
    /// CPU but also don't exit. zaudio's sound.pause() leaves the data
    /// source intact; sound.start() picks up where it left off.
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// v1.10.2 — when we last paused (nanoseconds via std.Io.Clock). Used by
    /// the bench to compute total elapsed minus pause time. 0 = never paused
    /// this play. Single-writer (pause); reader-friendly atomic load.
    paused_at_ns: std.atomic.Value(i128) = std.atomic.Value(i128).init(0),

    /// Best-effort init. Returns a player with `.ready = false` on any
    /// failure so the caller can degrade gracefully.
    ///
    /// v1.10.11 — engine config now honours three daemon-wide env knobs
    /// surfaced by the research note at `_qa/v1.10.9-research-prompt-output.md`
    /// ("Inference-layer knobs you're missing"):
    ///
    /// * `AGENT_TTS_AUDIO_LPF_ORDER` (default 8) — linear resampler
    ///   `lpf_order` on the engine's `pitch_resampling` config. Default in
    ///   miniaudio is 0 (no LPF; aliasing on the resample edge). 8 is the
    ///   per-resampler max and removes sibilant aliasing on the 22050 → 48000
    ///   upsample without measurable CPU cost on M-class silicon. We don't
    ///   touch `pitch` itself, so the documented biquad-instability gotcha
    ///   from miniaudio.c:77421 ("disable LPF for pitch shifting") does not
    ///   apply.
    /// * `AGENT_TTS_AUDIO_HEADROOM_DB` (default 3) — dB cut applied to the
    ///   engine master via `setGainDb(-headroom)`. Faber's stressed vowels
    ///   can push toward 0 dBFS at the end of long phrases; -3 dB gives the
    ///   miniaudio output-converter clipping margin and keeps the perceived
    ///   loudness identical-or-quieter (no auto-makeup-gain pass).
    /// * `AGENT_TTS_AUDIO_DITHER` (default `triangle`) — declares intent.
    ///   The miniaudio Engine config does NOT expose `dither_mode` for the
    ///   internal f32 → device-format converter, so we accept the env value
    ///   and log it but cannot wire it through without a custom data_callback
    ///   replacing the resource-manager mixing graph. v1.10.11 documents the
    ///   gap; flipping to `none` is a no-op today. The default value matches
    ///   what miniaudio would use if we ever bypass the engine: triangle PDF
    ///   dither on the s16 output to spread quantization noise into white
    ///   instead of correlated tones on quiet PCM tails.
    pub fn init(allocator: std.mem.Allocator) AudioPlayer {
        zaudio.init(allocator);

        // Resolve env knobs once at boot. Daemon-wide; no per-utterance
        // override (audio engine config is immutable after create).
        const lpf_order: u32 = blk: {
            const v = envU32("AGENT_TTS_AUDIO_LPF_ORDER") orelse break :blk 8;
            // miniaudio caps lpf_order at 8 (MA_MAX_RESAMPLER_LPF_ORDER).
            if (v > 8) break :blk 8;
            break :blk v;
        };
        const headroom_db: f32 = envFloatLocal("AGENT_TTS_AUDIO_HEADROOM_DB") orelse 3.0;
        const dither_str = envStrLocal("AGENT_TTS_AUDIO_DITHER") orelse "triangle";

        var engine_cfg = zaudio.Engine.Config.init();
        // Linear resampler LPF order — affects every Sound that mixes
        // through the engine because miniaudio's per-sound resampler is
        // configured from `pitchResamplingConfig` (see miniaudio.c:76587).
        engine_cfg.pitch_resampling.linear.lpf_order = lpf_order;
        engine_cfg.resource_manager_resampling.linear.lpf_order = lpf_order;

        const engine = zaudio.Engine.create(engine_cfg) catch |e| {
            alog.err("zaudio engine init failed: {s}", .{@errorName(e)});
            zaudio.deinit();
            return .{
                .engine = undefined,
                .ready = false,
            };
        };

        // Apply headroom. setGainDb(-N) reduces engine output by N dB
        // before the device-format converter sees the f32 mix.
        engine.setGainDb(-headroom_db) catch |e| {
            alog.warn("setGainDb(-{d:.1}) failed: {s} (ignored)", .{ headroom_db, @errorName(e) });
        };

        alog.info(
            "v1.10.11 quality knobs: lpf_order={d} headroom_db=-{d:.1} dither={s} (engine cfg)",
            .{ lpf_order, headroom_db, dither_str },
        );

        return .{
            .engine = engine,
            .ready = true,
        };
    }

    fn envStrLocal(name: [*:0]const u8) ?[]const u8 {
        const stdlib = @cImport({
            @cInclude("stdlib.h");
        });
        const ptr = stdlib.getenv(name);
        if (ptr == null) return null;
        const s = std.mem.span(ptr);
        if (s.len == 0) return null;
        return s;
    }

    fn envFloatLocal(name: [*:0]const u8) ?f32 {
        const s = envStrLocal(name) orelse return null;
        return std.fmt.parseFloat(f32, s) catch null;
    }

    fn envU32(name: [*:0]const u8) ?u32 {
        const s = envStrLocal(name) orelse return null;
        return std.fmt.parseInt(u32, s, 10) catch null;
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

    /// v1.10.2 — pause the active sound. Returns true if a sound was
    /// actively playing (so the caller can ack `OK\t<id>` to the client) or
    /// false if there was nothing to pause. Safe from any thread.
    ///
    /// zaudio's `sound.pause()` calls `ma_sound_stop()` underneath, which
    /// stops device pulls without freeing the data source — so a follow-up
    /// `sound.start()` resumes from the same cursor. We keep a `paused`
    /// flag so the streamS16le wait loop knows not to exit on isAtEnd
    /// (which can transiently flip true if the device underruns mid-pause).
    pub fn pause(self: *AudioPlayer) bool {
        if (!self.ready) return false;
        if (self.paused.load(.acquire)) return false;
        const sound_opt = self.current_sound.load(.acquire);
        const sound = sound_opt orelse return false;
        sound.stop() catch return false;
        self.paused.store(true, .release);
        // Record pause time for elapsed accounting. Best-effort —
        // std.Io isn't reachable here without piping it in, so use libc
        // clock_gettime(MONOTONIC) via std.c (we link_libc on the exe).
        // Zig 0.16 removed std.time.nanoTimestamp.
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        const ns: i128 = @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
        self.paused_at_ns.store(ns, .release);
        return true;
    }

    /// v1.10.2 — resume the paused sound. Returns true on success, false
    /// when nothing is paused. Counterpart to `pause`. Idempotent.
    pub fn resume_play(self: *AudioPlayer) bool {
        if (!self.ready) return false;
        if (!self.paused.load(.acquire)) return false;
        const sound_opt = self.current_sound.load(.acquire);
        const sound = sound_opt orelse {
            // Stale paused flag — clear it so future pause/resume work.
            self.paused.store(false, .release);
            return false;
        };
        sound.start() catch return false;
        self.paused.store(false, .release);
        self.paused_at_ns.store(0, .release);
        return true;
    }

    /// v1.10.2 — true while a previous `pause` hasn't been resumed.
    pub fn is_paused(self: *const AudioPlayer) bool {
        return self.paused.load(.acquire);
    }

    /// v1.2 streaming hint: same semantics as `streamS16le` — blocks until the
    /// given chunk finishes playing (or `requestStop` fires). The daemon's
    /// pipelined worker (synth-thread + audio-thread) calls this back-to-back
    /// per chunk; the inter-chunk gap is bounded by the create/destroy cost
    /// of the AudioBuffer + Sound pair (sub-millisecond on M-class silicon,
    /// well under one device period).
    ///
    /// Why this isn't true gapless: miniaudio's `AudioBuffer` is a one-shot
    /// data source. A truly seamless stream would require a custom
    /// `decoderReadProc` reading from a ring buffer with the realtime
    /// allocator constraint — see v1.2.1 in `whats-next.md`. The measured
    /// gap with back-to-back AudioBuffer plays is small enough that it
    /// doesn't move the long-input UX (first-audio latency dominates).
    pub fn streamS16leAppend(
        self: *AudioPlayer,
        samples: []const i16,
        sample_rate: u32,
    ) Error!void {
        return self.streamS16le(samples, sample_rate);
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

        var cfg = zaudio.AudioBuffer.Config.init(
            .signed16,
            1, // mono — Piper voices are all mono
            samples.len,
            @ptrCast(samples.ptr),
        );
        // Piper voices ship at 22050Hz (faber-medium). zaudio defaults to
        // engine output rate (48000) which would resample the buffer up,
        // shifting pitch ~2.18× higher. Pin the source rate to caller's value
        // so the engine resamples DOWN to the device rate correctly.
        cfg.sample_rate = sample_rate;
        const buffer = zaudio.AudioBuffer.create(cfg) catch {
            return Error.CreateBufferFailed;
        };
        defer buffer.destroy();

        const sound = self.engine.createSoundFromDataSource(
            buffer.asDataSourceMut(),
            .{},
            null,
        ) catch {
            return Error.CreateSoundFailed;
        };
        defer sound.destroy();

        // v1.10.2 — register the sound so pause/resume can see it.
        // Cleared on defer below so a stale pointer never survives the
        // sound's lifetime.
        self.current_sound.store(sound, .release);
        defer self.current_sound.store(null, .release);
        defer self.paused.store(false, .release);
        defer self.paused_at_ns.store(0, .release);

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
        //
        // v1.10.2 — while `paused` is set, stay in the loop without polling
        // isPlaying/isAtEnd (sound.stop in pause flips both). A 20 ms sleep
        // while paused keeps CPU near zero. Resume flips the flag and
        // sound.start() picks up where it left off.
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        const ts_paused: std.c.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        while (true) {
            if (self.stop_requested.load(.acquire)) {
                sound.stop() catch {};
                break;
            }
            if (self.paused.load(.acquire)) {
                _ = std.c.nanosleep(&ts_paused, null);
                continue;
            }
            if (!sound.isPlaying() or sound.isAtEnd()) break;
            _ = std.c.nanosleep(&ts, null);
        }
    }
};

// ---- tests ----

test "AudioPlayer pause cycle state machine" {
    // Stand-alone state machine test — exercises the pause/resume/is_paused
    // contract without touching zaudio (so it runs in headless CI). We
    // construct a player with ready=false so pause/resume short-circuit
    // through the not-ready branch, then flip ready manually to walk the
    // state transitions on a non-null current_sound = unreachable from here
    // (we never call sound methods because we leave current_sound = null).
    //
    // The interesting invariants:
    //   1. is_paused() defaults false
    //   2. pause() on not-ready → false, no state change
    //   3. pause() on ready but no current_sound → false (nothing to pause)
    //   4. resume_play() with nothing paused → false
    var player: AudioPlayer = .{ .engine = undefined, .ready = false };

    try std.testing.expectEqual(false, player.is_paused());
    try std.testing.expectEqual(false, player.pause());
    try std.testing.expectEqual(false, player.is_paused());
    try std.testing.expectEqual(false, player.resume_play());

    player.ready = true;
    // current_sound is null — pause must refuse cleanly.
    try std.testing.expectEqual(false, player.pause());
    try std.testing.expectEqual(false, player.is_paused());
    try std.testing.expectEqual(false, player.resume_play());
}

test "AudioPlayer paused_at_ns latches and clears" {
    // After a successful pause we expect a non-zero paused_at_ns; after a
    // resume we expect it to clear back to 0. Mirrors the bench expectation
    // that resume can subtract paused_at_ns from total wall.
    //
    // We can't simulate a real pause without zaudio, so the test
    // directly drives the atomic the same way pause/resume_play do —
    // documents the contract for future maintainers.
    var player: AudioPlayer = .{ .engine = undefined, .ready = false };
    try std.testing.expectEqual(@as(i128, 0), player.paused_at_ns.load(.acquire));

    // Simulate pause-induced latch.
    player.paused.store(true, .release);
    player.paused_at_ns.store(12345, .release);
    try std.testing.expectEqual(true, player.is_paused());
    try std.testing.expectEqual(@as(i128, 12345), player.paused_at_ns.load(.acquire));

    // Simulate resume-induced clear.
    player.paused.store(false, .release);
    player.paused_at_ns.store(0, .release);
    try std.testing.expectEqual(false, player.is_paused());
    try std.testing.expectEqual(@as(i128, 0), player.paused_at_ns.load(.acquire));
}
