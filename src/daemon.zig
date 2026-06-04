// SPDX-License-Identifier: MIT OR Apache-2.0
// Daemon: accept loop on UNIX socket, worker thread drains SQLite queue and
// routes playback per item engine (`say` → spawn `/usr/bin/say`; `piper` →
// libpiper synth → zaudio streaming PCM).
//
// v0.7 adds:
//   - AudioPlayer (zaudio.Engine) initialised at boot. Best-effort: failure
//     leaves it `.ready = false` and the piper path falls back to
//     synthToWav + afplay so output still reaches the speakers.
//   - PiperEngine boot when AGENT_TTS_PIPER=1 (env) AND build_options.enabled.
//     The engine is held in a Resources struct passed into the worker.
//   - runOne routes by item.engine. SKIP cancels via AudioPlayer.requestStop
//     for the piper path, mirroring the SIGTERM path for `say`.
//
// Auto-detach (fork+exec to background) lives in v0.4 with launchd.

const std = @import("std");
const ipc = @import("ipc.zig");
const tts = @import("tts.zig");
const Queue = @import("queue.zig").Queue;
const queue_mod = @import("queue.zig");
const audio = @import("audio.zig");
const preproc = @import("preproc.zig");
const postfx_mod = @import("postfx.zig");
const build_options = @import("build_options");

// v1.10.13 — scoped loggers per concern. `.daemon` for boot/IPC plumbing,
// `.worker` for queue drain + per-item play results. Other modules import
// their own scopes (.audio / .postfx / .piper / .voice / .mcp / .stream).
const dlog = std.log.scoped(.daemon);
const wlog = std.log.scoped(.worker);

// Piper is only @imported when the build enables it — otherwise piper.h
// isn't on the include path and `@cImport` blows up at translate time.
// `usingnamespace` or a comptime-typed pointer would let us hold the
// engine in Resources without the import; we just guard call sites instead.
const piper_mod = if (build_options.enabled) @import("piper.zig") else struct {
    pub const Error = error{ CreateFailed, SynthesizeStartFailed, SynthesizeNextFailed, WriteFailed };
    pub const PiperEngine = struct {
        pub fn deinit(_: *@This()) void {}
    };
    pub const MultiPiperEngine = struct {
        pub const Route = enum { pt, en };

        pub fn deinit(_: *@This()) void {}
        pub fn hasEn(_: *const @This()) bool {
            return false;
        }
        pub fn sampleRate(_: *const @This()) u32 {
            return 22050;
        }
        // Stub mirrors the real signature so daemon.zig type-checks with
        // `-Dwith-piper=false`. The path that calls this is gated by
        // `if (!build_options.enabled) unreachable;` in runPiper, so the
        // stub body is never reached at runtime.
        pub fn synthLang(
            _: *@This(),
            _: std.mem.Allocator,
            _: []const u8,
            _: Route,
        ) Error![]i16 {
            return Error.CreateFailed;
        }
        /// v1.10.7 — stub mirror of the per-call-knobs synth path.
        pub fn synthLangTuned(
            _: *@This(),
            _: std.mem.Allocator,
            _: []const u8,
            _: Route,
            _: f32,
            _: f32,
            _: f32,
        ) Error![]i16 {
            return Error.CreateFailed;
        }
        /// v1.10.8 — stub mirror of the per-call + speaker synth path.
        pub fn synthLangTunedSpeaker(
            _: *@This(),
            _: std.mem.Allocator,
            _: []const u8,
            _: Route,
            _: f32,
            _: f32,
            _: f32,
            _: i32,
        ) Error![]i16 {
            return Error.CreateFailed;
        }
        pub fn initMulti(
            _: std.mem.Allocator,
            _: []const u8,
            _: ?[]const u8,
            _: []const u8,
        ) Error!@This() {
            return Error.CreateFailed;
        }
    };
};

const detect = @import("detect.zig");

const READ_BUF = 16 * 1024;
const WRITE_BUF = 64 * 1024;
const DEFAULT_VOICE = "Luciana";

/// Daemon-scoped handles the worker borrows. PiperEngine is optional (env opt-
/// in); AudioPlayer is always created but may be `.ready = false`. The Queue
/// pointer drives the worker's main loop. io is forwarded from the daemon
/// run() — std.Io is a value type and safely shareable to the worker thread
/// when the daemon main remains alive for the worker's lifetime (we never
/// join, so that's always true).
const Resources = struct {
    queue: *Queue,
    audio_player: *audio.AudioPlayer,
    // v1.1: MultiPiperEngine holds Pt + (optional) En voices for code-switch
    // routing. Single-voice v1.0 behaviour is preserved when the En voice
    // isn't on disk — synth falls back to Pt and the warning logs once.
    piper: ?*piper_mod.MultiPiperEngine,
    io: std.Io,
    /// v1.10.10 — forwarded $HOME so postfx can probe
    /// `~/.cache/agent-tts/rnnoise/cb.rnnn` for the RNNoise model.
    home: []const u8,
    /// v1.10.2 — id of the row the worker is currently playing. Set when
    /// runOne begins, cleared on completion. IPC PAUSE/RESUME read this to
    /// ack the affected id. 0 means "nothing playing right now". Atomic so
    /// the accept thread can read without taking q.mu.
    current_playing_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

pub fn run(arena: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    const sock_path = try ipc.socketPath(arena, io, home);
    const db_path = try ipc.queueDbPath(arena, io, home);

    // Remove orphan socket if any. Cheap; ignored if not present.
    std.Io.Dir.cwd().deleteFile(io, sock_path) catch {};

    var addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    dlog.info("listening on {s}", .{sock_path});
    dlog.info("queue db {s}", .{db_path});

    var queue: Queue = .{ .arena = arena };
    try queue.init(db_path);
    defer queue.deinit();

    // Crash recovery already ran in queue.init (any 'playing' → 'pending').
    const pend_on_boot = queue.pending(io);
    if (pend_on_boot > 0) {
        dlog.info("recovered {d} pending items from previous run", .{pend_on_boot});
    }

    // Pre-warm the voice. Best-effort.
    const t_warm0 = std.Io.Clock.now(.awake, io);
    tts.preWarm(arena, io, DEFAULT_VOICE) catch |e| {
        dlog.warn("pre-warm failed: {s}", .{@errorName(e)});
    };
    const t_warm1 = std.Io.Clock.now(.awake, io);
    const warm_ms = @as(f64, @floatFromInt(t_warm1.nanoseconds - t_warm0.nanoseconds)) / 1_000_000.0;
    dlog.info("pre-warm done in {d:.1}ms", .{warm_ms});

    // v0.7: AudioPlayer (zaudio.Engine). Best-effort. Init takes ~10ms on
    // a working macOS audio session; failure leaves ready=false and the
    // piper path falls back to WAV+afplay.
    const t_audio0 = std.Io.Clock.now(.awake, io);
    var audio_player = audio.AudioPlayer.init(arena);
    const t_audio1 = std.Io.Clock.now(.awake, io);
    const audio_ms = @as(f64, @floatFromInt(t_audio1.nanoseconds - t_audio0.nanoseconds)) / 1_000_000.0;
    if (audio_player.ready) {
        dlog.info("zaudio engine init in {d:.1}ms", .{audio_ms});
    } else {
        dlog.warn("zaudio engine init failed ({d:.1}ms) — piper path will fall back to afplay", .{audio_ms});
    }
    defer audio_player.deinit();

    // v1.10.11 — apply ONNX runtime + miniaudio env knobs BEFORE the
    // libpiper engine boots. ONNX Runtime reads its thread-pool env vars
    // (`OMP_NUM_THREADS`, `ORT_NUM_THREADS`, `OMP_THREAD_LIMIT`) once at
    // session creation; setting them post-boot is too late.
    //
    // libpiper's public C ABI (`vendor/piper1-gpl/libpiper/include/piper.h`)
    // does NOT expose `OrtSessionOptions` — there's no `piper_create_options`
    // or builder hook in v1.4.2 — so the env-var fallback is the realistic
    // ship for v1.10.11. The Faber-medium VITS export is 15M params and
    // single-graph; intra-op parallelism beyond 1 thread costs more in
    // synchronization than it saves in matmul. Apple Silicon's P-cores want
    // one hot thread per inference, not four contended ones.
    //
    // We `setenv` only when the env isn't already provided so a CI / power
    // user override still wins. `overwrite=0` is the POSIX flag for that.
    {
        const cenv = @cImport({
            @cInclude("stdlib.h");
        });
        _ = cenv.setenv("OMP_NUM_THREADS", "1", 0);
        _ = cenv.setenv("ORT_NUM_THREADS", "1", 0);
        _ = cenv.setenv("OMP_THREAD_LIMIT", "1", 0);
        dlog.info(
            "v1.10.11 onnx env: OMP_NUM_THREADS=1 ORT_NUM_THREADS=1 OMP_THREAD_LIMIT=1 (libpiper exposes no OrtSessionOptions builder)",
            .{},
        );
    }

    // libpiper engine. Loads on every boot when the binary is built with
    // -Dwith-piper=true. Pt (Faber) mandatory; En (Amy) best-effort. Cold
    // cost ~700 ms when both load. Opt-out via AGENT_TTS_PIPER=0 (kept for
    // CI / debugging — daemon then runs `say`-only like the v1.0 universal
    // binary).
    var piper_engine_storage: ?piper_mod.MultiPiperEngine = null;
    var piper_engine_ptr: ?*piper_mod.MultiPiperEngine = null;
    if (build_options.enabled) {
        const c = @cImport({
            @cInclude("stdlib.h");
        });
        const env_ptr = c.getenv("AGENT_TTS_PIPER");
        const piper_off = env_ptr != null and std.mem.eql(u8, std.mem.span(env_ptr), "0");
        if (!piper_off) {
            if (bootMultiPiper(arena, io, home)) |engine| {
                piper_engine_storage = engine;
                piper_engine_ptr = &piper_engine_storage.?;
            }
        }
    }
    defer if (piper_engine_storage) |*p| @constCast(p).deinit();

    var resources: Resources = .{
        .queue = &queue,
        .audio_player = &audio_player,
        .piper = piper_engine_ptr,
        .io = io,
        .home = home,
    };

    const worker = try std.Thread.spawn(.{}, workerLoop, .{&resources});
    worker.detach();

    // v1.10.13 — heartbeat thread. Every 10s, log `worker heartbeat
    // queue=N current_playing_id=X` at debug level. Confirms the worker
    // process is alive even when the queue is empty (the worker pop is
    // blocking on a cond — no log line emerges from a fully idle daemon
    // without this). Detached; lives as long as the process does.
    const heartbeat = try std.Thread.spawn(.{}, heartbeatLoop, .{&resources});
    heartbeat.detach();

    while (true) {
        var stream = server.accept(io) catch |e| {
            dlog.err("accept failed: {s}", .{@errorName(e)});
            continue;
        };
        handleClient(arena, io, &stream, &resources) catch |e| {
            dlog.warn("handle failed: {s}", .{@errorName(e)});
        };
        stream.close(io);
    }
}

/// v1.10.13 — heartbeat loop. Sleeps 10 s and emits one debug-level
/// `worker heartbeat queue=<pending> current_playing_id=<id>` line. The
/// worker thread itself blocks inside `queue.pop` waiting on its cond
/// variable, so without this thread an idle daemon emits no log lines
/// at all. A stalled daemon (postfx watchdog tripped + recovery bug)
/// keeps emitting heartbeats with `current_playing_id != 0` — the
/// operator can spot it in the log file.
fn heartbeatLoop(res: *Resources) void {
    const sleep_ns: i64 = 10 * std.time.ns_per_s;
    const ts: std.c.timespec = .{ .sec = @intCast(@divTrunc(sleep_ns, std.time.ns_per_s)), .nsec = 0 };
    while (true) {
        _ = std.c.nanosleep(&ts, null);
        const playing_id = res.current_playing_id.load(.acquire);
        const pending = res.queue.pending(res.io);
        wlog.debug("worker heartbeat queue={d} current_playing_id={d}", .{ pending, playing_id });
    }
}

fn workerLoop(res: *Resources) void {
    // GPA for per-play scratch allocations (spawn argv strings, popped item
    // buffers). Each iteration owns its allocations and frees at the end.
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();

    const io = res.io;

    while (res.queue.pop(io, gpa)) |item| {
        defer gpa.free(item.voice);
        defer gpa.free(item.text);
        // v1.10.2 — publish the active id for PAUSE/RESUME ack. Cleared
        // unconditionally on exit so a worker error doesn't leave a stale
        // id visible to the next IPC client.
        res.current_playing_id.store(item.id, .release);
        defer res.current_playing_id.store(0, .release);
        // v1.10.13 — belt-and-braces: every runOne path is supposed to call
        // finishPlaying on success and error, but a v1.10.12 audit found
        // paths (e.g. an OutOfMemory escape from the SSML/cadence prep)
        // that left the row stuck in `playing`. The next pop then re-saw
        // the head item as already-playing and stalled. A defer here
        // guarantees the row flips to `done` regardless of which sub-call
        // raised. `finishPlaying` is idempotent over `state='playing'` so
        // the well-behaved paths that already called it are unaffected.
        wlog.info("pop id={d} engine={s} state=playing", .{ item.id, item.engine.str() });
        defer res.queue.finishPlaying(io, item.id);
        runOne(res, io, gpa, item) catch |e| {
            wlog.err("play id={d} engine={s} failed: {s}", .{
                item.id, item.engine.str(), @errorName(e),
            });
        };
        wlog.info("drained id={d}", .{item.id});
    }
}

/// v1.10.12 — true when `AGENT_TTS_BREATH_WAV` env var is set to a
/// non-empty path. Used by the cadence pipeline to decide whether the
/// `[[breath]]` marker becomes an audible splice. When the env var is
/// missing we still emit the marker as a literal (it's a noop for piper
/// because the bracket form looks like an espeak-ng IPA passthrough that
/// expands to silence in most voices).
fn breathEnabled() bool {
    const stdlib = @cImport({
        @cInclude("stdlib.h");
    });
    const ptr = stdlib.getenv("AGENT_TTS_BREATH_WAV");
    if (ptr == null) return false;
    const s = std.mem.span(ptr);
    return s.len > 0;
}

fn runOne(res: *Resources, io: std.Io, gpa: std.mem.Allocator, item: queue_mod.PoppedItem) !void {
    var spawn_arena = std.heap.ArenaAllocator.init(gpa);
    defer spawn_arena.deinit();
    const sa = spawn_arena.allocator();

    switch (item.engine) {
        .say => return runSay(res, io, sa, item),
        .piper => {
            if (!build_options.enabled or res.piper == null) {
                wlog.warn("id={d} requested piper but engine not available — falling back to say", .{item.id});
                return runSay(res, io, sa, item);
            }
            return runPiper(res, io, sa, item);
        },
        .cloned => return runCloned(res, io, sa, item),
    }
}

// v1.4 — cloned voice path. Spawns scripts/voice_synth.py with the voice slug
// (item.voice) and the text on stdin. Sidecar writes raw s16le mono 22050Hz
// PCM to stdout, which we drain into a buffer and feed AudioPlayer. If the
// sidecar fails (Python missing, model missing, embedding missing), the
// worker logs and falls back to piper Faber (when available) or say.
//
// The sidecar lives outside the binary on purpose — v1.4 explicitly relaxes
// the "only Zig" constraint for cloning (see docs/motor.md). Faber + say
// remain Python-free.
fn runCloned(res: *Resources, io: std.Io, sa: std.mem.Allocator, item: queue_mod.PoppedItem) !void {
    // Resolve voice dir + embedding before spawning Python — early exit
    // saves the ~1.5s Python startup tax on misconfigured slugs.
    const home_env = blk: {
        const c = @cImport({
            @cInclude("stdlib.h");
        });
        const ptr = c.getenv("HOME") orelse break :blk "/tmp";
        break :blk std.mem.span(ptr);
    };
    const voice_dir = try std.fmt.allocPrint(sa, "{s}/.cache/agent-tts/voices/{s}", .{ home_env, item.voice });
    const embedding_path = try std.fmt.allocPrint(sa, "{s}/embedding.npz", .{voice_dir});

    var probe = std.Io.Dir.cwd().openFile(io, embedding_path, .{}) catch {
        wlog.warn(
            "id={d} cloned voice '{s}' has no embedding at {s} — falling back",
            .{ item.id, item.voice, embedding_path },
        );
        return fallbackCloned(res, io, sa, item);
    };
    probe.close(io);

    res.queue.setPlaying(io, item.id, @intCast(std.c.getpid()));

    const t_synth0 = std.Io.Clock.now(.awake, io);
    const samples = synthClonedViaSidecar(sa, io, embedding_path, item.text) catch |e| {
        wlog.warn("id={d} cloned sidecar failed: {s} — falling back", .{ item.id, @errorName(e) });
        return fallbackCloned(res, io, sa, item);
    };
    const t_synth1 = std.Io.Clock.now(.awake, io);

    // XTTS-v2 emits at 24000 Hz by default; the sidecar resamples to 22050
    // so we share Faber's pipeline. Document in motor.md.
    const sample_rate: u32 = 22050;
    const t_play0 = std.Io.Clock.now(.awake, io);
    // v1.10.10 — cloned path uses streamS16le (non-append) per the
    // pre-existing behaviour. postfx applied inline when item.postfx != .off.
    try playWithPostfx(res, io, sa, item.id, samples, sample_rate, item.postfx, false);
    const t_play1 = std.Io.Clock.now(.awake, io);

    const synth_ms = @as(f64, @floatFromInt(t_synth1.nanoseconds - t_synth0.nanoseconds)) / 1_000_000.0;
    const play_ms = @as(f64, @floatFromInt(t_play1.nanoseconds - t_play0.nanoseconds)) / 1_000_000.0;
    wlog.info("cloned id={d} slug={s} synth={d:.1}ms play={d:.1}ms samples={d}", .{
        item.id, item.voice, synth_ms, play_ms, samples.len,
    });

    res.queue.finishPlaying(io, item.id);
}

fn fallbackCloned(res: *Resources, io: std.Io, sa: std.mem.Allocator, item: queue_mod.PoppedItem) !void {
    // Prefer piper Faber when loaded — same neural quality slot. Otherwise say.
    // PoppedItem.voice is `[]u8` (mutable), so dupe the literal to satisfy the
    // type — the fallback slot is short-lived and lives in the spawn arena.
    if (build_options.enabled and res.piper != null) {
        const fallback_voice = try sa.dupe(u8, "faber");
        const fallback_item: queue_mod.PoppedItem = .{
            .id = item.id,
            .engine = .piper,
            .voice = fallback_voice,
            .rate = item.rate,
            .text = item.text,
        };
        return runPiper(res, io, sa, fallback_item);
    }
    const fallback_voice = try sa.dupe(u8, DEFAULT_VOICE);
    const fallback_item: queue_mod.PoppedItem = .{
        .id = item.id,
        .engine = .say,
        .voice = fallback_voice,
        .rate = item.rate,
        .text = item.text,
    };
    return runSay(res, io, sa, fallback_item);
}

// v1.10.5: resolve `voice_synth.py` + `.venv-voice/bin/python` via probe.
// Daemon's cwd isn't the repo root (launchd starts under HOME), so the v1.4
// relative-path spawn fails. Probe order:
//   1. $AGENT_TTS_REPO_ROOT/scripts/voice_synth.py + $AGENT_TTS_REPO_ROOT/.venv-voice/bin/python
//   2. /opt/homebrew/share/agent-tts/scripts/voice_synth.py + same prefix venv
//   3. /usr/local/share/agent-tts/...
//   4. cwd-relative (legacy, v1.4 dev path)
fn resolveSidecarPaths(sa: std.mem.Allocator) struct { script: []const u8, venv_python: ?[]const u8 } {
    const c = @cImport({
        @cInclude("stdlib.h");
    });
    const env_root = c.getenv("AGENT_TTS_REPO_ROOT");
    const candidates: []const []const u8 = if (env_root != null and std.mem.span(env_root).len > 0)
        &.{
            std.mem.span(env_root),
            "/opt/homebrew/share/agent-tts",
            "/usr/local/share/agent-tts",
        }
    else
        &.{
            "/opt/homebrew/share/agent-tts",
            "/usr/local/share/agent-tts",
        };
    for (candidates) |root| {
        const script = std.fmt.allocPrint(sa, "{s}/scripts/voice_synth.py", .{root}) catch continue;
        const venv = std.fmt.allocPrint(sa, "{s}/.venv-voice/bin/python", .{root}) catch continue;
        if (fileExists(script)) {
            const py: ?[]const u8 = if (fileExists(venv)) venv else null;
            return .{ .script = script, .venv_python = py };
        }
    }
    return .{ .script = "scripts/voice_synth.py", .venv_python = null };
}

fn fileExists(path: []const u8) bool {
    const buf = std.heap.smp_allocator.dupeZ(u8, path) catch return false;
    defer std.heap.smp_allocator.free(buf);
    const fd = std.c.open(buf.ptr, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return false;
    _ = std.c.close(fd);
    return true;
}

// Spawn scripts/voice_synth.py, write text on stdin, drain s16le PCM from
// stdout. v1.10.5 probes for absolute script + venv python so daemon-spawned
// (launchd cwd ≠ repo root) calls succeed.
fn synthClonedViaSidecar(
    sa: std.mem.Allocator,
    io: std.Io,
    embedding_path: []const u8,
    text: []const u8,
) ![]i16 {
    const paths = resolveSidecarPaths(sa);
    const argv: [][]const u8 = if (paths.venv_python) |py| blk: {
        const a = try sa.alloc([]const u8, 6);
        a[0] = py;
        a[1] = paths.script;
        a[2] = "--embedding";
        a[3] = embedding_path;
        a[4] = "--rate";
        a[5] = "22050";
        break :blk a;
    } else if (lookPathSimple("uv")) blk: {
        var b = try sa.alloc([]const u8, 9);
        b[0] = "uv";
        b[1] = "run";
        b[2] = "--with";
        b[3] = "TTS";
        b[4] = paths.script;
        b[5] = "--embedding";
        b[6] = embedding_path;
        b[7] = "--rate";
        b[8] = "22050";
        break :blk b;
    } else blk: {
        const a = try sa.alloc([]const u8, 6);
        a[0] = "python3";
        a[1] = paths.script;
        a[2] = "--embedding";
        a[3] = embedding_path;
        a[4] = "--rate";
        a[5] = "22050";
        break :blk a;
    };

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    // Write text + close stdin so the sidecar can return.
    if (child.stdin) |*stdin| {
        try stdin.writeStreamingAll(io, text);
        stdin.close(io);
        child.stdin = null;
    }

    // Drain stdout into an ArrayList(u8) of bytes, then reinterpret as i16.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(sa);
    var chunk: [16 * 1024]u8 = undefined;
    if (child.stdout) |*stdout| {
        var sr = stdout.readerStreaming(io, &chunk);
        // readSliceShort returns 0 on EOF (no error). Spin until short read
        // delivers nothing.
        while (true) {
            const n = try sr.interface.readSliceShort(chunk[0..]);
            if (n == 0) break;
            try buf.appendSlice(sa, chunk[0..n]);
        }
    }

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.SidecarExit,
        else => return error.SidecarAbnormal,
    }

    // Reinterpret buffer as s16le. Drop a trailing odd byte if the sidecar
    // ever emits one (defensive — XTTS-v2 emits aligned frames).
    const byte_len = buf.items.len & ~@as(usize, 1);
    const samples = try sa.alloc(i16, byte_len / 2);
    @memcpy(std.mem.sliceAsBytes(samples), buf.items[0..byte_len]);
    return samples;
}

fn lookPathSimple(name: []const u8) bool {
    const c = @cImport({
        @cInclude("stdlib.h");
    });
    const env_ptr = c.getenv("PATH");
    if (env_ptr == null) return false;
    const path_env = std.mem.span(env_ptr);
    var it = std.mem.splitScalar(u8, path_env, ':');
    var buf: [4096]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        const fd = std.c.open(full.ptr, .{ .ACCMODE = .RDONLY });
        if (fd >= 0) {
            _ = std.c.close(fd);
            return true;
        }
    }
    return false;
}

fn runSay(res: *Resources, io: std.Io, sa: std.mem.Allocator, item: queue_mod.PoppedItem) !void {
    // v1.10.8 — fan out to spawnSayTuned when tech mode or any pause
    // override is set. The tuned path falls back to the legacy spawn
    // internally when every knob is at its default, so the cold path stays
    // a single syscall.
    const pauses: preproc.Pauses = .{
        .comma_ms = item.comma_pause_ms,
        .sentence_ms = item.sentence_pause_ms,
        .newline_ms = item.newline_pause_ms,
    };
    // v1.10.12 — apply cadence tricks before handing off to `say`. The
    // tricks emit SSML which spawnSayTuned routes through the SSML walker
    // when item.ssml is set; otherwise it falls through as bonus prosody
    // hints + a literal `[[breath]]` marker that say says as a word —
    // acceptable since breathing is opt-in via the env var.
    const text_for_say: []const u8 = if (item.tech)
        preproc.applyCadenceTricks(sa, item.text, .{ .enable_breathing = breathEnabled() }) catch item.text
    else
        item.text;
    var spawned = try tts.spawnSayTuned(sa, io, item.voice, item.rate, text_for_say, item.ssml, item.tech, pauses);

    const pid = spawned.child.id orelse return error.SpawnNoPid;
    res.queue.setPlaying(io, item.id, pid);

    _ = spawned.child.wait(io) catch |e| {
        res.queue.finishPlaying(io, item.id);
        return e;
    };
    res.queue.finishPlaying(io, item.id);
}

fn runPiper(res: *Resources, io: std.Io, sa: std.mem.Allocator, item: queue_mod.PoppedItem) !void {
    // Only compiled when libpiper is linked (-Dwith-piper=true).
    if (!build_options.enabled) unreachable;
    const engine = res.piper.?;

    // v1.10.12 — when cadence is set, apply the cadence tricks first
    // (emitting SSML prosody + breath markers) and then force the SSML
    // walker path so the resulting `<prosody>` / `<break>` survive into
    // the synth pipeline. Without this hop, the prosody tags would be
    // glossary-expanded as raw text and read aloud.
    var effective_item = item;
    if (item.tech) {
        const cadence_opts: preproc.CadenceOptions = .{ .enable_breathing = breathEnabled() };
        const after_cadence = preproc.applyCadenceTricks(sa, item.text, cadence_opts) catch item.text;
        // The cadence output is SSML; route through the SSML walker.
        const new_text = sa.dupe(u8, after_cadence) catch item.text;
        effective_item.text = new_text;
        effective_item.ssml = true;
    }

    // v1.8 — SSML routing. Single-pass walk of the token stream: the
    // streaming chunker can't see inside tags safely (a sentence period
    // inside `<prosody>` would split the scope), so SSML inputs take a
    // simpler non-streaming path. Trade-off documented in motor.md.
    if (effective_item.ssml) {
        runPiperSsml(res, io, sa, effective_item, engine) catch |e| {
            res.queue.finishPlaying(io, item.id);
            return e;
        };
        res.queue.finishPlaying(io, item.id);
        return;
    }

    // v1.1+v1.2: sentence-chunked (so long inputs stream chunk-by-chunk),
    // then per-chunk language detect (or forced via item.lang) routes Pt
    // sentences to Faber and En sentences to Amy. Single-chunk inputs
    // skip the pipeline and take the v0.7 fast path below.
    const sentence_chunks = preproc.chunkSentences(sa, effective_item.text) catch |e| {
        res.queue.finishPlaying(io, item.id);
        return e;
    };
    if (sentence_chunks.len == 0) {
        res.queue.finishPlaying(io, item.id);
        return;
    }
    // Per-chunk lang via detect. queue.zig doesn't persist Message.lang
    // across daemon restarts (v1.1 honest scope), so we always re-detect
    // here. Single-voice deployments (En voice missing) fall back to Pt
    // inside MultiPiperEngine.synthLang anyway.
    const chunks = try sa.alloc(preproc.Chunk, sentence_chunks.len);
    for (sentence_chunks, 0..) |sc, i| {
        const lang = detect.detect(sa, sc.text) catch detect.Lang.unknown;
        chunks[i] = .{ .text = sc.text, .lang = lang };
    }

    // SKIP routes through audio_player.requestStop for piper items; we
    // still register a sentinel PID so `agent-tts queue` shows "playing".
    res.queue.setPlaying(io, item.id, @intCast(std.c.getpid()));

    if (chunks.len == 1) {
        try runPiperSingle(res, io, sa, item, engine, chunks[0]);
        res.queue.finishPlaying(io, item.id);
        return;
    }

    runPiperStreaming(res, io, sa, item, engine, chunks) catch |e| {
        res.queue.finishPlaying(io, item.id);
        return e;
    };
    res.queue.finishPlaying(io, item.id);
}

// v1.8 — SSML synth path. Parses tokens, walks them in piper.synthLangSSML
// (which honours `<prosody rate>` via length-scale + `<break>` via silent
// frames), then plays the concatenated PCM in one go. Skips chunking
// because `<prosody>` scopes may cross sentence boundaries.
fn runPiperSsml(
    res: *Resources,
    io: std.Io,
    sa: std.mem.Allocator,
    item: queue_mod.PoppedItem,
    engine: *piper_mod.MultiPiperEngine,
) !void {
    if (!build_options.enabled) unreachable;
    const ssml_mod = @import("ssml.zig");

    const t_parse0 = std.Io.Clock.now(.awake, io);
    const tokens = try ssml_mod.parse(sa, item.text);
    const t_parse1 = std.Io.Clock.now(.awake, io);

    // Lang detection: scan the plain text portion of the token stream.
    const plain = try ssml_mod.stripToPlain(sa, tokens);
    const lang = detect.detect(sa, plain) catch detect.Lang.unknown;
    const route: piper_mod.MultiPiperEngine.Route = switch (lang) {
        .en => .en,
        else => .pt,
    };

    res.queue.setPlaying(io, item.id, @intCast(std.c.getpid()));

    const t_synth0 = std.Io.Clock.now(.awake, io);
    const samples = try engine.synthLangSSML(sa, tokens, route);
    const t_synth1 = std.Io.Clock.now(.awake, io);

    const sample_rate = engine.sampleRate();
    const t_play0 = std.Io.Clock.now(.awake, io);
    try playWithPostfx(res, io, sa, item.id, samples, sample_rate, item.postfx, true);
    const t_play1 = std.Io.Clock.now(.awake, io);

    const parse_us = @as(f64, @floatFromInt(t_parse1.nanoseconds - t_parse0.nanoseconds)) / 1_000.0;
    const synth_ms = @as(f64, @floatFromInt(t_synth1.nanoseconds - t_synth0.nanoseconds)) / 1_000_000.0;
    const play_ms = @as(f64, @floatFromInt(t_play1.nanoseconds - t_play0.nanoseconds)) / 1_000_000.0;
    wlog.info("piper-ssml id={d} tokens={d} parse={d:.1}µs synth={d:.1}ms play={d:.1}ms samples={d}", .{
        item.id, tokens.len, parse_us, synth_ms, play_ms, samples.len,
    });
}

// v0.7 fast path — one synth, one play, no thread spawn. v1.1: synth via
// MultiPiperEngine.synthLang so single-chunk en-only items still route
// through Amy when available. v1.10.7: route through synthLangTuned so
// per-call knobs (length_scale / noise_scale / noise_w) ride along.
// v1.10.8: tech glossary substitution before synth, speaker_id passes
// through, pause overrides flow via the same path the streaming pipeline
// uses (no Piper-side pause directive — Piper's PCM concatenation is
// continuous, so pause overrides only affect `say`).
fn runPiperSingle(
    res: *Resources,
    io: std.Io,
    sa: std.mem.Allocator,
    item: queue_mod.PoppedItem,
    engine: *piper_mod.MultiPiperEngine,
    chunk: preproc.Chunk,
) !void {
    if (!build_options.enabled) unreachable;
    const route: piper_mod.MultiPiperEngine.Route = switch (chunk.lang) {
        .en => .en,
        else => .pt,
    };
    // v1.10.7+v1.10.8 — log knobs when ANY override is set so A/B
    // experiments surface in the daemon log. Quiet when everything is at
    // default sentinels.
    const has_knobs = item.length_scale > 0 or item.noise_scale >= 0 or item.noise_w >= 0;
    const has_extras = item.tech or item.speaker_id >= 0 or
        item.sentence_pause_ms != 0 or item.comma_pause_ms != 0 or item.newline_pause_ms != 0;
    if (has_knobs or has_extras) {
        wlog.debug(
            "piper id={d} tech={any} length_scale={d:.3} noise_scale={d:.3} noise_w={d:.3} speaker_id={d} sentence_pause_ms={d}",
            .{ item.id, item.tech, item.length_scale, item.noise_scale, item.noise_w, item.speaker_id, item.sentence_pause_ms },
        );
    }
    // v1.10.8 — tech glossary substitution per chunk. Piper's espeak-ng
    // frontend ingests the text directly, so a glossary that swaps "API"
    // → "A P I" already gives the model spelled-out letters to phonemize.
    const synth_text: []const u8 = if (item.tech) blk: {
        const after = preproc.processTech(sa, chunk.text, .{}) catch chunk.text;
        break :blk after;
    } else chunk.text;
    const t_synth0 = std.Io.Clock.now(.awake, io);
    const samples = try engine.synthLangTunedSpeaker(
        sa,
        synth_text,
        route,
        item.length_scale,
        item.noise_scale,
        item.noise_w,
        item.speaker_id,
    );
    const t_synth1 = std.Io.Clock.now(.awake, io);

    const sample_rate = engine.sampleRate();
    const t_play0 = std.Io.Clock.now(.awake, io);
    try playWithPostfx(res, io, sa, item.id, samples, sample_rate, item.postfx, true);
    const t_play1 = std.Io.Clock.now(.awake, io);

    const synth_ms = @as(f64, @floatFromInt(t_synth1.nanoseconds - t_synth0.nanoseconds)) / 1_000_000.0;
    const play_ms = @as(f64, @floatFromInt(t_play1.nanoseconds - t_play0.nanoseconds)) / 1_000_000.0;
    wlog.info("piper id={d} lang={s} synth={d:.1}ms play={d:.1}ms samples={d}", .{
        item.id, chunk.lang.str(), synth_ms, play_ms, samples.len,
    });
}

// ──────────────────────────────────────────────────────────────────────
// v1.2 — pipelined synth + playback (single-producer / single-consumer)
// ──────────────────────────────────────────────────────────────────────
//
// Bounded ring of 2-slot capacity: the synth thread is allowed exactly one
// chunk ahead of the audio thread. Slot lifetime is owned by a per-chunk
// arena allocated under the worker's GPA; the audio thread frees the
// arena once playback returns (or fails). No std.Thread.Mutex (Zig 0.16
// removed it) — atomic head/tail + 5ms nanosleep polling match audio.zig.

const RING_CAP: usize = 2;

const ChunkSlot = struct {
    arena: ?std.heap.ArenaAllocator = null,
    samples: []const i16 = &.{},
    sample_rate: u32 = 0,
    synth_err: bool = false,
};

const ChunkChannel = struct {
    slots: [RING_CAP]ChunkSlot = [_]ChunkSlot{.{}} ** RING_CAP,
    head: std.atomic.Value(usize) = .init(0), // next write index
    tail: std.atomic.Value(usize) = .init(0), // next read index
    closed: std.atomic.Value(bool) = .init(false),
    skip: std.atomic.Value(bool) = .init(false),

    fn pendingCount(self: *const ChunkChannel) usize {
        const h = self.head.load(.acquire);
        const t = self.tail.load(.acquire);
        return h - t;
    }

    // Producer: block until there's a free slot OR consumer closed/skipped.
    fn waitForSlot(self: *ChunkChannel) bool {
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 2 * std.time.ns_per_ms };
        while (true) {
            if (self.skip.load(.acquire)) return false;
            if (self.pendingCount() < RING_CAP) return true;
            _ = std.c.nanosleep(&ts, null);
        }
    }

    fn push(self: *ChunkChannel, slot: ChunkSlot) void {
        const h = self.head.load(.acquire);
        self.slots[h % RING_CAP] = slot;
        self.head.store(h + 1, .release);
    }

    // Consumer: block until there's a chunk OR producer signaled closed.
    fn pop(self: *ChunkChannel) ?ChunkSlot {
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 2 * std.time.ns_per_ms };
        while (true) {
            if (self.skip.load(.acquire)) return null;
            const h = self.head.load(.acquire);
            const t = self.tail.load(.acquire);
            if (h > t) {
                const slot = self.slots[t % RING_CAP];
                self.tail.store(t + 1, .release);
                return slot;
            }
            if (self.closed.load(.acquire)) return null;
            _ = std.c.nanosleep(&ts, null);
        }
    }
};

const SynthArgs = struct {
    engine: *piper_mod.MultiPiperEngine,
    chunks: []const preproc.Chunk,
    chan: *ChunkChannel,
    gpa: std.mem.Allocator,
    /// v1.10.7 — per-call piper knobs forwarded from the popped queue
    /// row. Sentinels (length_scale==0 / others < 0) preserve env + voice
    /// defaults inside `synthToSamplesTuned`.
    length_scale: f32 = 0.0,
    noise_scale: f32 = -1.0,
    noise_w: f32 = -1.0,
    /// v1.10.8 — tech glossary substitution + multi-speaker selector.
    /// `tech=true` runs `preproc.processTech` per chunk before synth;
    /// `speaker_id ≥ 0` overrides the voice config default.
    tech: bool = false,
    speaker_id: i32 = -1,
};

fn synthWorker(args: SynthArgs) void {
    if (!build_options.enabled) unreachable;
    for (args.chunks) |chunk| {
        if (!args.chan.waitForSlot()) break;
        // Per-chunk arena owns the synth output. Consumer frees on play
        // completion. The arena lives on the heap so the slot can move
        // through the ring without invalidating pointers.
        const arena_box = args.gpa.create(std.heap.ArenaAllocator) catch {
            args.chan.push(.{ .synth_err = true });
            continue;
        };
        arena_box.* = std.heap.ArenaAllocator.init(args.gpa);
        const route: piper_mod.MultiPiperEngine.Route = switch (chunk.lang) {
            .en => .en,
            else => .pt,
        };
        // v1.10.8 — tech glossary per chunk. Falls through to chunk.text
        // on allocator failure so streaming never stalls on a preproc
        // error mid-pipeline.
        const synth_text: []const u8 = if (args.tech)
            preproc.processTech(arena_box.allocator(), chunk.text, .{}) catch chunk.text
        else
            chunk.text;
        const samples = args.engine.synthLangTunedSpeaker(
            arena_box.allocator(),
            synth_text,
            route,
            args.length_scale,
            args.noise_scale,
            args.noise_w,
            args.speaker_id,
        ) catch {
            arena_box.deinit();
            args.gpa.destroy(arena_box);
            args.chan.push(.{ .synth_err = true });
            continue;
        };
        const rate = args.engine.sampleRate();
        args.chan.push(.{
            .arena = arena_box.*,
            .samples = samples,
            .sample_rate = rate,
        });
        // Transfer ownership of the heap box: the consumer's slot copy
        // carries the arena state. We free the *outer* pointer here; the
        // arena state itself lives on inside the slot until consumer
        // deinits it. (ArenaAllocator is a value type whose internals
        // are heap-backed, so this copy is safe.)
        args.gpa.destroy(arena_box);
    }
    args.chan.closed.store(true, .release);
}

fn runPiperStreaming(
    res: *Resources,
    io: std.Io,
    sa: std.mem.Allocator,
    item: queue_mod.PoppedItem,
    engine: *piper_mod.MultiPiperEngine,
    chunks: []const preproc.Chunk,
) !void {
    if (!build_options.enabled) unreachable;
    _ = sa;
    var chan = ChunkChannel{};

    // Streaming pipeline allocates per-chunk arenas off a thread-safe
    // allocator (smp_allocator is per-CPU, lock-free fast path) so the
    // synth thread and the worker thread don't contend on a debug GPA.
    const gpa = std.heap.smp_allocator;

    // v1.10.7+v1.10.8 — log knobs once before the streaming pipeline so
    // the same diagnostic shows up regardless of single-chunk vs streaming
    // path.
    const has_knobs = item.length_scale > 0 or item.noise_scale >= 0 or item.noise_w >= 0;
    const has_extras = item.tech or item.speaker_id >= 0 or
        item.sentence_pause_ms != 0 or item.comma_pause_ms != 0 or item.newline_pause_ms != 0;
    if (has_knobs or has_extras) {
        wlog.debug(
            "piper id={d} tech={any} length_scale={d:.3} noise_scale={d:.3} noise_w={d:.3} speaker_id={d} sentence_pause_ms={d}",
            .{ item.id, item.tech, item.length_scale, item.noise_scale, item.noise_w, item.speaker_id, item.sentence_pause_ms },
        );
    }
    const args = SynthArgs{
        .engine = engine,
        .chunks = chunks,
        .chan = &chan,
        .gpa = gpa,
        .length_scale = item.length_scale,
        .noise_scale = item.noise_scale,
        .noise_w = item.noise_w,
        .tech = item.tech,
        .speaker_id = item.speaker_id,
    };
    const synth_thread = try std.Thread.spawn(.{}, synthWorker, .{args});

    const t_pipeline0 = std.Io.Clock.now(.awake, io);
    var first_play_started: bool = false;
    var t_first_audio_ns: i128 = 0;
    var played_chunks: usize = 0;
    var total_samples: usize = 0;

    while (chan.pop()) |slot_const| {
        var slot = slot_const;
        if (slot.synth_err) {
            if (slot.arena) |*a| @constCast(a).deinit();
            wlog.err("piper id={d} streaming synth error on chunk {d}", .{ item.id, played_chunks });
            continue;
        }

        if (!first_play_started) {
            const t_first = std.Io.Clock.now(.awake, io);
            t_first_audio_ns = t_first.nanoseconds;
            first_play_started = true;
        }

        // v1.10.10 — route this chunk's PCM through postfx before
        // playback when item.postfx != .off. The processed buffer is
        // allocated inside the slot's per-chunk arena so it dies with
        // the slot at the end of this loop iteration.
        var play_samples: []const i16 = slot.samples;
        if (item.postfx != .off) {
            const slot_alloc: ?std.mem.Allocator = if (slot.arena) |*a| @constCast(a).allocator() else null;
            if (slot_alloc) |arena_alloc| {
                const apply_res = postfx_mod.apply(arena_alloc, io, slot.samples, slot.sample_rate, item.postfx, res.home) catch postfx_mod.ApplyResult{ .samples = slot.samples, .was_processed = false };
                if (apply_res.was_processed) {
                    play_samples = apply_res.samples;
                    const warn = if (apply_res.postfx_ms > 100.0) " (>100ms — eating into TTFA)" else "";
                    wlog.debug("id={d} chunk={d} postfx={s} postfx_ms={d:.1}{s}", .{ item.id, played_chunks, item.postfx.str(), apply_res.postfx_ms, warn });
                }
            }
        }

        const play_res = if (res.audio_player.ready) blk: {
            break :blk res.audio_player.streamS16leAppend(play_samples, slot.sample_rate);
        } else blk: {
            // afplay fallback needs a short-lived arena for the tmp WAV path.
            var fb_arena = std.heap.ArenaAllocator.init(gpa);
            defer fb_arena.deinit();
            break :blk playViaAfplay(io, fb_arena.allocator(), play_samples, slot.sample_rate);
        };

        played_chunks += 1;
        total_samples += slot.samples.len;

        if (slot.arena) |*a| @constCast(a).deinit();

        // SKIP between chunks: streamS16le honors requestStop within the
        // active chunk; we also bail the rest of the pipeline so the
        // synth thread doesn't keep working on bytes the user wants gone.
        if (res.audio_player.stop_requested.load(.acquire)) {
            chan.skip.store(true, .release);
            while (chan.pop()) |drain_const| {
                var d = drain_const;
                if (d.arena) |*a| @constCast(a).deinit();
            }
            break;
        }

        play_res catch |e| {
            wlog.err("piper id={d} streaming play error on chunk {d}: {s}", .{ item.id, played_chunks, @errorName(e) });
            // Signal synth to bail; drain remaining slots' arenas.
            chan.skip.store(true, .release);
            while (chan.pop()) |drain_const| {
                var d = drain_const;
                if (d.arena) |*a| @constCast(a).deinit();
            }
            synth_thread.join();
            return e;
        };
    }

    synth_thread.join();

    const t_pipeline1 = std.Io.Clock.now(.awake, io);
    if (first_play_started) {
        const first_audio_ms = @as(f64, @floatFromInt(t_first_audio_ns - t_pipeline0.nanoseconds)) / 1_000_000.0;
        const total_ms = @as(f64, @floatFromInt(t_pipeline1.nanoseconds - t_pipeline0.nanoseconds)) / 1_000_000.0;
        wlog.info("piper id={d} streaming chunks={d} first_audio={d:.1}ms total={d:.1}ms samples={d}", .{
            item.id, played_chunks, first_audio_ms, total_ms, total_samples,
        });
    } else {
        wlog.warn("piper id={d} streaming produced no audio", .{item.id});
    }
}

/// v1.1 chunking: build the list of `Chunk` for this item according to the
/// `lang` field on the queue entry. We don't (yet) persist `lang` in the
/// DB — it lives on `ipc.Message` and rides the in-memory hop only. When
/// the item came from a v0.x ENQUEUE the default is `.auto`, so we
/// detect; explicit `.pt` / `.en` short-circuit detection.
fn buildChunks(sa: std.mem.Allocator, item: queue_mod.PoppedItem) !?[]preproc.Chunk {
    // Queue currently doesn't persist Lang. v1.1 uses item.text only —
    // detection runs at synth time. Future versions may serialise lang
    // alongside engine; for now `auto` is the de-facto default for the
    // worker path.
    const chunks = try preproc.splitByLang(sa, item.text, .pt);
    if (chunks.len == 0) return null;
    return chunks;
}

/// v1.10.10 — play samples through the postfx chain (when item.postfx
/// != .off) and onto the device. Encapsulates the
/// `postfx.apply → audio_player.streamS16leAppend → afplay-fallback`
/// path so the three runPiper* call sites and the cloned path share
/// the same routing. Logs a single `postfx=<profile> postfx_ms=<ms>`
/// line per call when the chain actually ran.
fn playWithPostfx(
    res: *Resources,
    io: std.Io,
    sa: std.mem.Allocator,
    item_id: u64,
    samples: []const i16,
    sample_rate: u32,
    profile: ipc.Postfx,
    append: bool,
) !void {
    var processed = samples;
    if (profile != .off) {
        const apply_res = postfx_mod.apply(sa, io, samples, sample_rate, profile, res.home) catch |e| blk: {
            wlog.warn("id={d} postfx={s} apply error: {s} — falling back to dry PCM", .{ item_id, profile.str(), @errorName(e) });
            break :blk postfx_mod.ApplyResult{ .samples = samples, .was_processed = false };
        };
        if (apply_res.was_processed) {
            processed = apply_res.samples;
            const warn = if (apply_res.postfx_ms > 100.0) " (>100ms — eating into TTFA)" else "";
            wlog.info("id={d} postfx={s} postfx_ms={d:.1}{s}", .{ item_id, profile.str(), apply_res.postfx_ms, warn });
        } else {
            wlog.warn("id={d} postfx={s} passthrough (ffmpeg/model unavailable)", .{ item_id, profile.str() });
        }
    }

    if (res.audio_player.ready) {
        const play_res = if (append)
            res.audio_player.streamS16leAppend(processed, sample_rate)
        else
            res.audio_player.streamS16le(processed, sample_rate);
        play_res catch |e| {
            wlog.warn("zaudio play failed: {s} — falling back to afplay", .{@errorName(e)});
            try playViaAfplay(io, sa, processed, sample_rate);
        };
    } else {
        try playViaAfplay(io, sa, processed, sample_rate);
    }
}

// Last-resort playback when zaudio.Engine isn't ready (headless CI, audio
// session denied). Writes a tmp WAV and spawns /usr/bin/afplay. Slower
// (disk I/O + process spawn) but keeps the piper path functional so a
// release ships without a hard audio dependency.
fn playViaAfplay(io: std.Io, sa: std.mem.Allocator, samples: []const i16, sample_rate: u32) !void {
    const tmp_path = try std.fmt.allocPrint(sa, "/tmp/agent-tts-{d}.wav", .{std.c.getpid()});
    try writeWav(io, tmp_path, samples, sample_rate);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    const argv = [_][]const u8{ "/usr/bin/afplay", tmp_path };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try child.wait(io);
}

// Minimal RIFF/WAVE writer (mirrors piper.zig's; duplicated here so the
// fallback path doesn't require -Dwith-piper=true to compile).
fn writeWav(io: std.Io, path: []const u8, samples: []const i16, sample_rate: u32) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    const num_channels: u16 = 1;
    const bits_per_sample: u16 = 16;
    const byte_rate: u32 = sample_rate * num_channels * (bits_per_sample / 8);
    const block_align: u16 = num_channels * (bits_per_sample / 8);
    const data_bytes: u32 = @intCast(samples.len * @sizeOf(i16));
    const riff_size: u32 = 36 + data_bytes;

    var header: [44]u8 = undefined;
    @memcpy(header[0..4], "RIFF");
    std.mem.writeInt(u32, header[4..8], riff_size, .little);
    @memcpy(header[8..12], "WAVE");
    @memcpy(header[12..16], "fmt ");
    std.mem.writeInt(u32, header[16..20], 16, .little);
    std.mem.writeInt(u16, header[20..22], 1, .little);
    std.mem.writeInt(u16, header[22..24], num_channels, .little);
    std.mem.writeInt(u32, header[24..28], sample_rate, .little);
    std.mem.writeInt(u32, header[28..32], byte_rate, .little);
    std.mem.writeInt(u16, header[32..34], block_align, .little);
    std.mem.writeInt(u16, header[34..36], bits_per_sample, .little);
    @memcpy(header[36..40], "data");
    std.mem.writeInt(u32, header[40..44], data_bytes, .little);

    try file.writeStreamingAll(io, &header);
    const bytes: [*]const u8 = @ptrCast(samples.ptr);
    try file.writeStreamingAll(io, bytes[0 .. samples.len * @sizeOf(i16)]);
}

fn handleClient(
    arena: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    res: *Resources,
) !void {
    var read_buf: [READ_BUF]u8 = undefined;
    var write_buf: [WRITE_BUF]u8 = undefined;

    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    const queue = res.queue;
    const audio_player = res.audio_player;

    const line = sr.interface.takeDelimiterExclusive('\n') catch |e| {
        try writeErr(&sw.interface, @errorName(e));
        return;
    };

    const req = ipc.parseRequest(arena, line) catch |e| {
        try writeErr(&sw.interface, @errorName(e));
        return;
    };

    switch (req) {
        .enqueue => |msg| {
            const id = queue.push(io, msg) catch |e| {
                try writeErr(&sw.interface, @errorName(e));
                return;
            };
            try sw.interface.print("OK\t{d}\n", .{id});
            try sw.interface.flush();
        },
        .queue => {
            const items = queue.list(io, arena) catch |e| {
                try writeErr(&sw.interface, @errorName(e));
                return;
            };
            for (items) |it| {
                try sw.interface.print("ITEM\t{d}\t{s}\t{s}\t{s}\t{d}\t{s}\n", .{
                    it.id, it.state.str(), it.engine.str(), it.voice, it.rate, it.text,
                });
            }
            try sw.interface.writeAll("END\n");
            try sw.interface.flush();
        },
        .skip => {
            // SIGTERM the `say` child (if any) AND signal the AudioPlayer
            // to abort. Whichever path is active reacts; the other no-ops.
            const id = queue.skipCurrent(io);
            audio_player.requestStop();
            try sw.interface.print("OK\t{d}\n", .{id});
            try sw.interface.flush();
        },
        .clear => {
            const n = queue.clearPending(io);
            try sw.interface.print("OK\t{d}\n", .{n});
            try sw.interface.flush();
        },
        // v1.10.2 — pause the active piper/cloned playback. Returns the
        // current_playing_id on success, ERR when nothing is playing or
        // when the active path is `say` (separate process — pause would
        // require SIGSTOP and bring SIGCONT complexity for v1.10.3+).
        .pause => {
            const id = res.current_playing_id.load(.acquire);
            if (id == 0) {
                try writeErr(&sw.interface, "nothing playing");
                return;
            }
            if (!audio_player.pause()) {
                try writeErr(&sw.interface, "nothing playing");
                return;
            }
            try sw.interface.print("OK\t{d}\n", .{id});
            try sw.interface.flush();
        },
        .resume_play => {
            const id = res.current_playing_id.load(.acquire);
            if (id == 0) {
                try writeErr(&sw.interface, "not paused");
                return;
            }
            if (!audio_player.resume_play()) {
                try writeErr(&sw.interface, "not paused");
                return;
            }
            try sw.interface.print("OK\t{d}\n", .{id});
            try sw.interface.flush();
        },
        .replay => |src_id| {
            const gpa = std.heap.smp_allocator;
            const new_id_opt = queue.replay(io, gpa, src_id) catch |e| {
                try writeErr(&sw.interface, @errorName(e));
                return;
            };
            const new_id = new_id_opt orelse {
                try writeErr(&sw.interface, "item not found");
                return;
            };
            try sw.interface.print("OK\t{d}\n", .{new_id});
            try sw.interface.flush();
        },
        .history => |limit| {
            const items = queue.history(io, arena, limit) catch |e| {
                try writeErr(&sw.interface, @errorName(e));
                return;
            };
            // History ITEM wire shape extends QUEUE's by appending the
            // `finished_at` field BEFORE the text. New consumers parse
            // the extra column; old consumers won't be calling HISTORY.
            for (items) |it| {
                try sw.interface.print("ITEM\t{d}\t{s}\t{s}\t{s}\t{d}\t{d}\t{s}\n", .{
                    it.id, it.state.str(), it.engine.str(), it.voice, it.rate, it.finished_at, it.text,
                });
            }
            try sw.interface.writeAll("END\n");
            try sw.interface.flush();
        },
    }
}

fn writeErr(w: *std.Io.Writer, msg: []const u8) !void {
    try w.print("ERR\t{s}\n", .{msg});
    try w.flush();
}

// Cold-load PiperEngine for the daemon. Returns the engine on success, null
// on failure (logged inline so the caller doesn't have to). Caller deinits
// at process exit. Only compiled when -Dwith-piper=true.
fn bootPiper(arena: std.mem.Allocator, io: std.Io, home: []const u8) ?piper_mod.PiperEngine {
    if (!build_options.enabled) return null;

    const voice_path = std.fmt.allocPrint(
        arena,
        "{s}/.cache/agent-tts/voices/pt_BR-faber-medium.onnx",
        .{home},
    ) catch return null;
    const espeak_data = "vendor/piper1-gpl/libpiper/dist/share/espeak-ng-data";

    const t0 = std.Io.Clock.now(.awake, io);
    const engine = piper_mod.PiperEngine.init(arena, voice_path, espeak_data) catch |e| {
        dlog.err("piper engine load failed: {s}", .{@errorName(e)});
        dlog.err("  voice: {s}", .{voice_path});
        dlog.err("  espeak: {s}", .{espeak_data});
        return null;
    };
    const t1 = std.Io.Clock.now(.awake, io);
    const load_ns: f64 = @floatFromInt(t1.nanoseconds - t0.nanoseconds);
    const load_ms = load_ns / 1_000_000.0;
    dlog.info("piper engine loaded in {d:.1}ms", .{load_ms});

    return engine;
}

// v1.1 — boot Pt + En voices into a MultiPiperEngine. Pt is mandatory; En is
// best-effort (Amy file may not be on disk yet — user opts in via
// `scripts/fetch-voice-en.sh`). When En load fails, MultiPiperEngine.hasEn()
// returns false and `synthLang(.en)` silently falls back to Pt at the call
// site. Total cold cost on success: Pt ~340 ms + En ~340 ms = ~680 ms.
// Single-voice fall-through (no En on disk) matches v0.7 cold time.
fn bootMultiPiper(arena: std.mem.Allocator, io: std.Io, home: []const u8) ?piper_mod.MultiPiperEngine {
    if (!build_options.enabled) return null;

    const pt_voice_path = std.fmt.allocPrint(
        arena,
        "{s}/.cache/agent-tts/voices/pt_BR-faber-medium.onnx",
        .{home},
    ) catch return null;
    const en_voice_path = std.fmt.allocPrint(
        arena,
        "{s}/.cache/agent-tts/voices/en_US-amy-medium.onnx",
        .{home},
    ) catch return null;
    const espeak_data = "vendor/piper1-gpl/libpiper/dist/share/espeak-ng-data";

    // Probe En voice file before passing the path — keeps the inner load
    // failure message clean and gives the user a single "En voice not
    // installed" hint on boot.
    const en_path_opt: ?[]const u8 = blk: {
        var f = std.Io.Dir.cwd().openFile(io, en_voice_path, .{}) catch {
            dlog.warn("en voice not installed at {s} — code-switch will fall back to pt", .{en_voice_path});
            dlog.warn("  install: ./scripts/fetch-voice-en.sh", .{});
            break :blk null;
        };
        f.close(io);
        break :blk en_voice_path;
    };

    const t0 = std.Io.Clock.now(.awake, io);
    const engine = piper_mod.MultiPiperEngine.initMulti(arena, pt_voice_path, en_path_opt, espeak_data) catch |e| {
        dlog.err("multi piper engine load failed: {s}", .{@errorName(e)});
        dlog.err("  pt voice: {s}", .{pt_voice_path});
        dlog.err("  espeak: {s}", .{espeak_data});
        return null;
    };
    const t1 = std.Io.Clock.now(.awake, io);
    const load_ms = @as(f64, @floatFromInt(t1.nanoseconds - t0.nanoseconds)) / 1_000_000.0;
    dlog.info(
        "multi piper engine loaded in {d:.1}ms (pt={s} en={s})",
        .{ load_ms, "faber", if (engine.hasEn()) "amy" else "off" },
    );

    return engine;
}
