// SPDX-License-Identifier: MIT OR Apache-2.0
// v1.10.10 — audio post-processing pipeline.
//
// Goal: take the i16 PCM the synth path produces and run it through an
// ffmpeg filter chain (RNNoise + 4-band EQ + de-esser + 2:1 compressor)
// before the zaudio engine pumps it to the device. Opt-in per call via
// `Postfx` enum on the IPC message; the daemon worker calls `apply()`
// after `piper.synth*` returns and before `audio_player.streamS16le*`.
//
// Design choices:
//   - ffmpeg subprocess (s16le→s16le pipe), not a linked library. RNNoise
//     and the EQ chain need ffmpeg's filter graph plumbing; bundling
//     libavfilter would balloon the binary. The subprocess overhead is
//     ~5-10 ms per call to spawn + ~0.5 ms per audio second to filter on
//     M-series silicon — measurable but acceptable inside the TTFA budget.
//   - Pure pass-through when:
//       - postfx == .off
//       - ffmpeg binary not found (probed lazily on first call)
//   - Chain selection is hardcoded per profile so an agent can A/B without
//     stringly-typed filter graphs reaching MCP. Custom chains via env
//     var land in v1.10.11+ if anyone asks.
//
// The chain `tech` references the `arnndn` filter with a Conjoined Burgers
// 2018-08-28 RNNoise model. We probe for the model at
// `$AGENT_TTS_POSTFX_RNNN_MODEL` first, then
// `$HOME/.cache/agent-tts/rnnoise/cb.rnnn`. When neither exists we drop
// the `arnndn=…` segment from the chain and use the EQ+deesser+compressor
// subset — still a quality lift, no hard dependency.

const std = @import("std");

// v1.10.13 — scoped logger so the postfx pipeline can announce when its
// watchdog fires, when ffmpeg comes back non-zero, etc. without coupling
// to the daemon's print surface. Level discipline:
//   .err  → ffmpeg subprocess crashed or failed to spawn
//   .warn → watchdog kicked, or ffmpeg exit code != 0 (fallthrough path)
//   .info → first-call chain resolution
//   .debug → per-invocation chain string + wall-time
const flog = std.log.scoped(.postfx);

/// Selectable post-fx profiles. `off` is the no-op (return samples
/// unchanged, no subprocess spawn). Strings on the wire mirror the
/// tags so the IPC layer can format/parse them with `@tagName`.
pub const Postfx = enum {
    off,
    clean,
    tech,
    broadcast,

    pub fn fromStr(s: []const u8) ?Postfx {
        if (std.mem.eql(u8, s, "off")) return .off;
        if (std.mem.eql(u8, s, "clean")) return .clean;
        if (std.mem.eql(u8, s, "tech")) return .tech;
        if (std.mem.eql(u8, s, "broadcast")) return .broadcast;
        return null;
    }

    pub fn str(p: Postfx) []const u8 {
        return @tagName(p);
    }
};

pub const PostfxError = error{
    SpawnFailed,
    PipeWriteFailed,
    PipeReadFailed,
    SubprocessAbnormal,
    OutOfMemory,
};

/// Result of `apply`. `samples` lives in `arena` so callers can drop
/// everything by deinit'ing the arena. `was_processed` is false when
/// the no-op path was taken (postfx=.off OR ffmpeg unavailable) so the
/// caller knows the slice is the original PCM, not a fresh allocation.
/// `postfx_ms` is the wall-time wall-clock cost of the subprocess hop,
/// usable for the daemon's `postfx_ms=X` log line.
pub const ApplyResult = struct {
    samples: []const i16,
    was_processed: bool,
    postfx_ms: f64 = 0,
};

/// Build the ffmpeg `-af` chain string for a profile. `rnnn_path` is
/// the absolute path to the RNNoise model file when available; null
/// drops the `arnndn=…` segment from the `tech` chain. Returned string
/// is owned by `arena`.
pub fn buildChain(arena: std.mem.Allocator, profile: Postfx, rnnn_path: ?[]const u8) ![]const u8 {
    return switch (profile) {
        .off => "",
        .clean => try arena.dupe(u8, "highpass=f=80,acompressor=threshold=-18dB:ratio=2:attack=20:release=200:makeup=1dB"),
        .tech => blk: {
            // Research-anchored chain from `_qa/v1.10.9-research-prompt-output.md`
            // ("Acoustic post-processing" subsection). HPF clears rumble,
            // body shelf adds warmth, presence cut tames sibilants, air
            // shelf adds clarity, deesser catches what remains, comp
            // tightens the dynamic range to broadcast levels.
            const tail = "highpass=f=80,equalizer=f=280:width_type=o:width=2:g=2.5,equalizer=f=3500:width_type=o:width=1.5:g=-1.5,equalizer=f=10000:width_type=o:width=2:g=1.8,deesser=i=0.08:m=0.5,acompressor=threshold=-18dB:ratio=2:attack=20:release=200:makeup=2dB";
            if (rnnn_path) |p| {
                break :blk try std.fmt.allocPrint(arena, "arnndn=m={s}," ++ tail, .{p});
            }
            break :blk try arena.dupe(u8, tail);
        },
        .broadcast => try arena.dupe(u8, "highpass=f=80,equalizer=f=280:width_type=o:width=2:g=2.0,equalizer=f=3000:width_type=o:width=1.5:g=-1.0,deesser=i=0.08:m=0.4,acompressor=threshold=-14dB:ratio=3:attack=15:release=180:makeup=2.5dB"),
    };
}

/// Probe `AGENT_TTS_FFMPEG_PATH` env, then `/opt/homebrew/bin/ffmpeg`,
/// then `/usr/local/bin/ffmpeg`, then bare `ffmpeg`. Returns the first
/// path that opens (or `ffmpeg` as last-resort which std.process resolves
/// against PATH). Caller does NOT free; strings are static literals or
/// env-owned. The env pointer is borrowed via `std.mem.span` which keeps
/// it valid for the process lifetime.
pub fn resolveFfmpeg() ?[]const u8 {
    const c = @cImport({
        @cInclude("stdlib.h");
    });
    const env_ptr = c.getenv("AGENT_TTS_FFMPEG_PATH");
    if (env_ptr != null) {
        const env_str = std.mem.span(env_ptr);
        if (env_str.len > 0 and pathExecutable(env_str)) return env_str;
    }
    const candidates = [_][]const u8{
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
    };
    for (candidates) |p| {
        if (pathExecutable(p)) return p;
    }
    // Last resort: bare "ffmpeg" so std.process.spawn resolves it
    // against PATH. If PATH doesn't have it the spawn will fail and
    // the caller logs + falls back to pass-through.
    return "ffmpeg";
}

/// Probe `AGENT_TTS_POSTFX_RNNN_MODEL`, then
/// `$HOME/.cache/agent-tts/rnnoise/cb.rnnn`. Returns null when neither
/// exists. Caller owns the returned string (allocated from `arena`).
pub fn resolveRnnoiseModel(arena: std.mem.Allocator, home: []const u8) ?[]const u8 {
    const c = @cImport({
        @cInclude("stdlib.h");
    });
    const env_ptr = c.getenv("AGENT_TTS_POSTFX_RNNN_MODEL");
    if (env_ptr != null) {
        const env_str = std.mem.span(env_ptr);
        if (env_str.len > 0 and pathReadable(env_str)) {
            return arena.dupe(u8, env_str) catch return null;
        }
    }
    const default_path = std.fmt.allocPrint(arena, "{s}/.cache/agent-tts/rnnoise/cb.rnnn", .{home}) catch return null;
    if (pathReadable(default_path)) return default_path;
    return null;
}

fn pathExecutable(path: []const u8) bool {
    const c = @cImport({
        @cInclude("unistd.h");
    });
    const buf = std.heap.smp_allocator.dupeZ(u8, path) catch return false;
    defer std.heap.smp_allocator.free(buf);
    // X_OK = 1
    return c.access(buf.ptr, 1) == 0;
}

fn pathReadable(path: []const u8) bool {
    const buf = std.heap.smp_allocator.dupeZ(u8, path) catch return false;
    defer std.heap.smp_allocator.free(buf);
    const fd = std.c.open(buf.ptr, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return false;
    _ = std.c.close(fd);
    return true;
}

/// Apply the postfx chain to s16le mono PCM at `sample_rate`. When
/// `profile == .off` or ffmpeg isn't available, returns `samples`
/// unchanged with `was_processed=false`. Otherwise spawns ffmpeg, pipes
/// the PCM through, and returns the filtered output (lives in `arena`).
///
/// `home` is forwarded to `resolveRnnoiseModel` for the `tech` profile.
/// Pass the daemon's resolved `$HOME` so the user-cache fallback works
/// even when the daemon is launched by launchd (cwd != $HOME).
///
/// v1.10.13 — concurrent stdin write + stdout drain (was sequential).
/// The previous serial path (`writeStreamingAll(stdin); close; drain stdout`)
/// deadlocked when the input PCM exceeded the pipe buffer (~64 KiB on macOS):
/// ffmpeg's output filled its own pipe before we drained, so its filter
/// stopped consuming input, so the kernel blocked our `writeStreamingAll`.
/// That was the v1.10.12 stall: a ~52 s SSML synth produced ~2.3 MiB of PCM,
/// hit the pipe-buffer wall, and the worker thread sat on `writeStreamingAll`
/// forever — the queue advanced no further. We now spawn a stdout drainer
/// thread + a watchdog thread that SIGTERMs the subprocess after
/// `AGENT_TTS_POSTFX_TIMEOUT_MS` (default 5000) so a misbehaving filter or
/// runaway ffmpeg can never stall the worker again.
pub fn apply(
    arena: std.mem.Allocator,
    io: std.Io,
    samples: []const i16,
    sample_rate: u32,
    profile: Postfx,
    home: []const u8,
) PostfxError!ApplyResult {
    if (profile == .off or samples.len == 0) {
        return .{ .samples = samples, .was_processed = false };
    }

    const ffmpeg = resolveFfmpeg() orelse {
        return .{ .samples = samples, .was_processed = false };
    };

    // RNNoise model is best-effort. `null` drops the `arnndn=…` prefix
    // for the `tech` chain — the rest of the EQ+deesser+comp still runs.
    const rnnn_path: ?[]const u8 = if (profile == .tech) resolveRnnoiseModel(arena, home) else null;
    const chain = buildChain(arena, profile, rnnn_path) catch return error.OutOfMemory;
    if (chain.len == 0) {
        return .{ .samples = samples, .was_processed = false };
    }

    const rate_str = std.fmt.allocPrint(arena, "{d}", .{sample_rate}) catch return error.OutOfMemory;

    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(arena, &.{
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "s16le",
        "-ar",
        rate_str,
        "-ac",
        "1",
        "-i",
        "-",
        "-af",
        chain,
        "-f",
        "s16le",
        "-ar",
        rate_str,
        "-ac",
        "1",
        "-",
    }) catch return error.OutOfMemory;

    const t0 = std.Io.Clock.now(.awake, io);
    flog.debug("apply profile={s} sample_rate={d} bytes={d} chain_len={d}", .{
        profile.str(), sample_rate, samples.len * 2, chain.len,
    });

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch {
        // Subprocess didn't start — fall back to pass-through. Common
        // root causes: ffmpeg missing despite earlier probe (PATH
        // race), bad permissions, or a filter the ffmpeg build doesn't
        // ship. Silent pass-through keeps audio flowing.
        flog.warn("ffmpeg spawn failed for profile={s} — fallthrough", .{profile.str()});
        return .{ .samples = samples, .was_processed = false };
    };

    // Capture child pid for the watchdog. After `child.wait()` returns,
    // `child.id` is null — so we snapshot now.
    const child_pid: ?std.posix.pid_t = child.id;

    // PCM bytes view over the i16 buffer.
    const pcm_bytes: []const u8 = blk: {
        const p: [*]const u8 = @ptrCast(samples.ptr);
        break :blk p[0 .. samples.len * @sizeOf(i16)];
    };

    // -----------------------------------------------------------------
    // Concurrent drain thread + watchdog thread.
    //
    // Without the drainer, large inputs deadlock (see v1.10.12 stall
    // analysis above). Without the watchdog, a hung ffmpeg invocation
    // (filter crash, model load timeout) would stall the worker
    // forever. Both threads are joined before this function returns
    // so the per-call arena allocations stay valid.
    // -----------------------------------------------------------------

    var drain_state: DrainState = .{
        .arena = arena,
        .io = io,
        .buf = .empty,
        .done = std.atomic.Value(bool).init(false),
        .err = std.atomic.Value(bool).init(false),
        .stdout = if (child.stdout) |*s| s else null,
    };
    const drainer = std.Thread.spawn(.{}, drainThread, .{&drain_state}) catch {
        flog.err("drain thread spawn failed — fallthrough", .{});
        _ = child.wait(io) catch {};
        return .{ .samples = samples, .was_processed = false };
    };

    var watchdog_state: WatchdogState = .{
        .timeout_ms = postfxTimeoutMs(),
        .pid = child_pid,
        .fired = std.atomic.Value(bool).init(false),
        .done = std.atomic.Value(bool).init(false),
    };
    const watchdog = std.Thread.spawn(.{}, watchdogThread, .{&watchdog_state}) catch {
        // Without a watchdog we still proceed — the drainer alone
        // resolves the deadlock for normal-length inputs. Pathological
        // cases will block but that's strictly no worse than v1.10.12.
        flog.warn("watchdog spawn failed — proceeding without timeout protection", .{});
        proceedWithoutWatchdog(&child, io, pcm_bytes, &drain_state, drainer);
        return finalizePostfx(arena, io, samples, t0, &drain_state, &child, false, profile);
    };

    // Write PCM on the calling thread. The drainer concurrently reads
    // stdout so the kernel pipe buffers never fill — no deadlock.
    var write_failed = false;
    if (child.stdin) |*stdin| {
        stdin.writeStreamingAll(io, pcm_bytes) catch {
            write_failed = true;
        };
        stdin.close(io);
        child.stdin = null;
    }

    drainer.join();

    const term_or_err = child.wait(io);

    // Signal the watchdog we're done so it doesn't kill a healthy process
    // if it's still ticking.
    watchdog_state.done.store(true, .release);
    watchdog.join();

    const watchdog_fired = watchdog_state.fired.load(.acquire);
    const term = term_or_err catch {
        if (watchdog_fired) {
            flog.warn("watchdog killed ffmpeg after {d}ms — fallthrough", .{watchdog_state.timeout_ms});
        } else {
            flog.warn("ffmpeg wait failed — fallthrough", .{});
        }
        return .{ .samples = samples, .was_processed = false };
    };

    if (watchdog_fired) {
        flog.warn("watchdog killed ffmpeg after {d}ms — fallthrough", .{watchdog_state.timeout_ms});
        return .{ .samples = samples, .was_processed = false };
    }
    switch (term) {
        .exited => |code| if (code != 0) {
            flog.warn("ffmpeg exit code={d} — fallthrough", .{code});
            return .{ .samples = samples, .was_processed = false };
        },
        else => {
            flog.warn("ffmpeg abnormal termination — fallthrough", .{});
            return .{ .samples = samples, .was_processed = false };
        },
    }
    if (write_failed or drain_state.err.load(.acquire)) {
        flog.warn("ffmpeg pipe I/O failed — fallthrough", .{});
        return .{ .samples = samples, .was_processed = false };
    }

    const t1 = std.Io.Clock.now(.awake, io);
    const postfx_ms = @as(f64, @floatFromInt(t1.nanoseconds - t0.nanoseconds)) / 1_000_000.0;

    // Reinterpret the byte buffer as s16le. Drop a trailing odd byte
    // defensively — ffmpeg emits aligned frames in practice.
    const byte_len = drain_state.buf.items.len & ~@as(usize, 1);
    if (byte_len == 0) {
        // Filter produced nothing (unlikely for a non-empty input but
        // possible with broken chains). Fall back to pass-through.
        flog.warn("ffmpeg produced 0 bytes — fallthrough", .{});
        return .{ .samples = samples, .was_processed = false };
    }
    const out_samples = arena.alloc(i16, byte_len / 2) catch {
        drain_state.buf.deinit(arena);
        return error.OutOfMemory;
    };
    @memcpy(std.mem.sliceAsBytes(out_samples), drain_state.buf.items[0..byte_len]);
    drain_state.buf.deinit(arena);
    flog.info("apply profile={s} in_bytes={d} out_bytes={d} wall={d:.1}ms", .{
        profile.str(), samples.len * 2, byte_len, postfx_ms,
    });
    return .{ .samples = out_samples, .was_processed = true, .postfx_ms = postfx_ms };
}

// -----------------------------------------------------------------------
// Watchdog + drainer plumbing.
// -----------------------------------------------------------------------

const DrainState = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    buf: std.ArrayList(u8),
    done: std.atomic.Value(bool),
    err: std.atomic.Value(bool),
    stdout: ?*std.Io.File,
};

fn drainThread(s: *DrainState) void {
    defer s.done.store(true, .release);
    if (s.stdout == null) return;
    var stream_buf: [16 * 1024]u8 = undefined;
    var scratch: [16 * 1024]u8 = undefined;
    var sr = s.stdout.?.readerStreaming(s.io, &stream_buf);
    while (true) {
        const n = sr.interface.readSliceShort(scratch[0..]) catch {
            s.err.store(true, .release);
            return;
        };
        if (n == 0) return;
        s.buf.appendSlice(s.arena, scratch[0..n]) catch {
            s.err.store(true, .release);
            return;
        };
    }
}

const WatchdogState = struct {
    timeout_ms: u32,
    pid: ?std.posix.pid_t,
    fired: std.atomic.Value(bool),
    done: std.atomic.Value(bool),
};

fn watchdogThread(s: *WatchdogState) void {
    // Sleep in short slices so an early-finish call site doesn't wait
    // the full timeout when joining. Slice = 50ms.
    const slice_ns: i64 = 50 * std.time.ns_per_ms;
    const ts: std.c.timespec = .{ .sec = 0, .nsec = slice_ns };
    var elapsed_ms: u32 = 0;
    while (elapsed_ms < s.timeout_ms) : (elapsed_ms += 50) {
        if (s.done.load(.acquire)) return;
        _ = std.c.nanosleep(&ts, null);
    }
    // Deadline reached — SIGTERM the child. The waiter (apply()) will
    // observe the abnormal exit and return a fallthrough result.
    if (s.pid) |p| {
        std.posix.kill(p, .TERM) catch {};
        s.fired.store(true, .release);
        // Brief grace period, then SIGKILL if it's still around.
        const grace: std.c.timespec = .{ .sec = 1, .nsec = 0 };
        _ = std.c.nanosleep(&grace, null);
        if (!s.done.load(.acquire)) {
            std.posix.kill(p, .KILL) catch {};
        }
    }
}

fn postfxTimeoutMs() u32 {
    const c = @cImport({
        @cInclude("stdlib.h");
    });
    const ptr = c.getenv("AGENT_TTS_POSTFX_TIMEOUT_MS");
    if (ptr == null) return 5000;
    const s = std.mem.span(ptr);
    if (s.len == 0) return 5000;
    return std.fmt.parseInt(u32, s, 10) catch 5000;
}

fn proceedWithoutWatchdog(
    child: *std.process.Child,
    io: std.Io,
    pcm_bytes: []const u8,
    drain_state: *DrainState,
    drainer: std.Thread,
) void {
    if (child.stdin) |*stdin| {
        stdin.writeStreamingAll(io, pcm_bytes) catch {};
        stdin.close(io);
        child.stdin = null;
    }
    drainer.join();
    _ = drain_state;
}

fn finalizePostfx(
    arena: std.mem.Allocator,
    io: std.Io,
    samples: []const i16,
    t0: std.Io.Timestamp,
    drain_state: *DrainState,
    child: *std.process.Child,
    write_failed: bool,
    profile: Postfx,
) PostfxError!ApplyResult {
    const term_or_err = child.wait(io);
    const term = term_or_err catch {
        drain_state.buf.deinit(arena);
        return .{ .samples = samples, .was_processed = false };
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            drain_state.buf.deinit(arena);
            return .{ .samples = samples, .was_processed = false };
        },
        else => {
            drain_state.buf.deinit(arena);
            return .{ .samples = samples, .was_processed = false };
        },
    }
    if (write_failed or drain_state.err.load(.acquire)) {
        drain_state.buf.deinit(arena);
        return .{ .samples = samples, .was_processed = false };
    }
    const byte_len = drain_state.buf.items.len & ~@as(usize, 1);
    if (byte_len == 0) {
        drain_state.buf.deinit(arena);
        return .{ .samples = samples, .was_processed = false };
    }
    const out_samples = arena.alloc(i16, byte_len / 2) catch {
        drain_state.buf.deinit(arena);
        return error.OutOfMemory;
    };
    @memcpy(std.mem.sliceAsBytes(out_samples), drain_state.buf.items[0..byte_len]);
    drain_state.buf.deinit(arena);
    const t1 = std.Io.Clock.now(.awake, io);
    const postfx_ms = @as(f64, @floatFromInt(t1.nanoseconds - t0.nanoseconds)) / 1_000_000.0;
    flog.info("apply (no-watchdog) profile={s} in_bytes={d} out_bytes={d} wall={d:.1}ms", .{
        profile.str(), samples.len * 2, byte_len, postfx_ms,
    });
    return .{ .samples = out_samples, .was_processed = true, .postfx_ms = postfx_ms };
}

// ---- tests --------------------------------------------------------------

test "Postfx.fromStr accepts known profiles" {
    try std.testing.expectEqual(Postfx.off, Postfx.fromStr("off").?);
    try std.testing.expectEqual(Postfx.clean, Postfx.fromStr("clean").?);
    try std.testing.expectEqual(Postfx.tech, Postfx.fromStr("tech").?);
    try std.testing.expectEqual(Postfx.broadcast, Postfx.fromStr("broadcast").?);
    try std.testing.expect(Postfx.fromStr("bogus") == null);
    try std.testing.expect(Postfx.fromStr("") == null);
}

test "Postfx.str round-trips through fromStr" {
    inline for ([_]Postfx{ .off, .clean, .tech, .broadcast }) |p| {
        try std.testing.expectEqual(p, Postfx.fromStr(p.str()).?);
    }
}

test "buildChain off returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const chain = try buildChain(arena.allocator(), .off, null);
    try std.testing.expectEqual(@as(usize, 0), chain.len);
}

test "buildChain clean returns highpass + acompressor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const chain = try buildChain(arena.allocator(), .clean, null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "highpass=f=80") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "acompressor=") != null);
    // No EQ in clean chain.
    try std.testing.expect(std.mem.indexOf(u8, chain, "equalizer=") == null);
}

test "buildChain tech without rnnn drops arnndn prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const chain = try buildChain(arena.allocator(), .tech, null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "arnndn=") == null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "highpass=f=80") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "deesser=") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "equalizer=f=280") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "equalizer=f=3500") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "equalizer=f=10000") != null);
}

test "buildChain tech with rnnn prefixes arnndn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const chain = try buildChain(arena.allocator(), .tech, "/tmp/cb.rnnn");
    try std.testing.expect(std.mem.startsWith(u8, chain, "arnndn=m=/tmp/cb.rnnn,"));
    try std.testing.expect(std.mem.indexOf(u8, chain, "deesser=") != null);
}

test "buildChain broadcast contains presence cut" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const chain = try buildChain(arena.allocator(), .broadcast, null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "equalizer=f=3000") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "deesser=i=0.08") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain, "ratio=3") != null);
}

test "apply postfx=off returns samples unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // We can't easily get a std.Io in tests without an event loop; the
    // off path returns before touching io so a zero-value is fine here.
    const io_storage: std.Io = undefined;
    const samples = [_]i16{ 0, 1, 2, 3 };
    const res = try apply(arena.allocator(), io_storage, &samples, 22050, .off, "/tmp");
    try std.testing.expectEqual(false, res.was_processed);
    try std.testing.expectEqual(@as(usize, 4), res.samples.len);
    try std.testing.expectEqual(@as(i16, 2), res.samples[2]);
}

test "apply empty samples returns unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io_storage: std.Io = undefined;
    const samples = [_]i16{};
    const res = try apply(arena.allocator(), io_storage, &samples, 22050, .tech, "/tmp");
    try std.testing.expectEqual(false, res.was_processed);
    try std.testing.expectEqual(@as(usize, 0), res.samples.len);
}
