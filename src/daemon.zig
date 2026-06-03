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
const build_options = @import("build_options");

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

const preproc = @import("preproc.zig");
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
};

pub fn run(arena: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    const sock_path = try ipc.socketPath(arena, io, home);
    const db_path = try ipc.queueDbPath(arena, io, home);

    // Remove orphan socket if any. Cheap; ignored if not present.
    std.Io.Dir.cwd().deleteFile(io, sock_path) catch {};

    var addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    std.debug.print("[daemon] listening on {s}\n", .{sock_path});
    std.debug.print("[daemon] queue db {s}\n", .{db_path});

    var queue: Queue = .{ .arena = arena };
    try queue.init(db_path);
    defer queue.deinit();

    // Crash recovery already ran in queue.init (any 'playing' → 'pending').
    const pend_on_boot = queue.pending(io);
    if (pend_on_boot > 0) {
        std.debug.print("[daemon] recovered {d} pending items from previous run\n", .{pend_on_boot});
    }

    // Pre-warm the voice. Best-effort.
    const t_warm0 = std.Io.Clock.now(.awake, io);
    tts.preWarm(arena, io, DEFAULT_VOICE) catch |e| {
        std.debug.print("[daemon] pre-warm failed: {s}\n", .{@errorName(e)});
    };
    const t_warm1 = std.Io.Clock.now(.awake, io);
    const warm_ms = @as(f64, @floatFromInt(t_warm1.nanoseconds - t_warm0.nanoseconds)) / 1_000_000.0;
    std.debug.print("[daemon] pre-warm done in {d:.1}ms\n", .{warm_ms});

    // v0.7: AudioPlayer (zaudio.Engine). Best-effort. Init takes ~10ms on
    // a working macOS audio session; failure leaves ready=false and the
    // piper path falls back to WAV+afplay.
    const t_audio0 = std.Io.Clock.now(.awake, io);
    var audio_player = audio.AudioPlayer.init(arena);
    const t_audio1 = std.Io.Clock.now(.awake, io);
    const audio_ms = @as(f64, @floatFromInt(t_audio1.nanoseconds - t_audio0.nanoseconds)) / 1_000_000.0;
    if (audio_player.ready) {
        std.debug.print("[daemon] zaudio engine init in {d:.1}ms\n", .{audio_ms});
    } else {
        std.debug.print("[daemon] zaudio engine init failed ({d:.1}ms) — piper path will fall back to afplay\n", .{audio_ms});
    }
    defer audio_player.deinit();

    // Optional libpiper engine. Off by default; opt in via AGENT_TTS_PIPER=1.
    // Lives until process exit so v0.7's worker can synth without paying the
    // ~400ms cold load each call.
    //
    // v1.1: load BOTH voices when piper is enabled. Pt (Faber) is mandatory;
    // En (Amy) is best-effort — daemon stays usable if the En voice isn't
    // on disk yet. Cold cost ~700 ms when both load (was ~340 ms in v0.7
    // with just Pt). User who never wants En can stick to v1.0 by not
    // running `scripts/fetch-voice-en.sh`.
    var piper_engine_storage: ?piper_mod.MultiPiperEngine = null;
    var piper_engine_ptr: ?*piper_mod.MultiPiperEngine = null;
    if (build_options.enabled) {
        const c = @cImport({
            @cInclude("stdlib.h");
        });
        const env_ptr = c.getenv("AGENT_TTS_PIPER");
        if (env_ptr != null and std.mem.eql(u8, std.mem.span(env_ptr), "1")) {
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
    };

    const worker = try std.Thread.spawn(.{}, workerLoop, .{&resources});
    worker.detach();

    while (true) {
        var stream = server.accept(io) catch |e| {
            std.debug.print("[daemon] accept failed: {s}\n", .{@errorName(e)});
            continue;
        };
        handleClient(arena, io, &stream, &queue, &audio_player) catch |e| {
            std.debug.print("[daemon] handle failed: {s}\n", .{@errorName(e)});
        };
        stream.close(io);
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
        runOne(res, io, gpa, item) catch |e| {
            std.debug.print("[worker] play id={d} engine={s} failed: {s}\n", .{
                item.id, item.engine.str(), @errorName(e),
            });
        };
    }
}

fn runOne(res: *Resources, io: std.Io, gpa: std.mem.Allocator, item: queue_mod.PoppedItem) !void {
    var spawn_arena = std.heap.ArenaAllocator.init(gpa);
    defer spawn_arena.deinit();
    const sa = spawn_arena.allocator();

    switch (item.engine) {
        .say => return runSay(res, io, sa, item),
        .piper => {
            if (!build_options.enabled or res.piper == null) {
                std.debug.print("[worker] id={d} requested piper but engine not available — falling back to say\n", .{item.id});
                return runSay(res, io, sa, item);
            }
            return runPiper(res, io, sa, item);
        },
    }
}

fn runSay(res: *Resources, io: std.Io, sa: std.mem.Allocator, item: queue_mod.PoppedItem) !void {
    var spawned = try tts.spawnSay(sa, io, item.voice, item.rate, item.text);

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

    // v1.1: route per chunk. `--lang pt|en` forces single-voice synth
    // (no detect call). `--lang auto` runs splitByLang which calls the
    // detector once per sentence; chunks coalesce same-lang runs so
    // typical messages stay one synth call.
    const chunks: []const preproc.Chunk = blk: {
        const maybe = buildChunks(sa, item) catch |e| {
            std.debug.print("[worker] id={d} splitByLang failed: {s} — synth as pt\n", .{ item.id, @errorName(e) });
            const single = try sa.alloc(preproc.Chunk, 1);
            single[0] = .{ .text = item.text, .lang = .pt };
            break :blk single;
        };
        if (maybe) |slice| break :blk slice;
        const single = try sa.alloc(preproc.Chunk, 1);
        single[0] = .{ .text = item.text, .lang = .pt };
        break :blk single;
    };

    // SKIP routes through audio_player.requestStop for piper items; we
    // still register a sentinel PID so `agent-tts queue` shows "playing".
    res.queue.setPlaying(io, item.id, @intCast(std.c.getpid()));

    var total_samples: usize = 0;
    var total_synth_ns: u64 = 0;
    var total_play_ns: u64 = 0;
    var n_chunks: usize = 0;

    for (chunks) |ch| {
        const route: piper_mod.MultiPiperEngine.Route = switch (ch.lang) {
            .en => .en,
            else => .pt,
        };
        const t_synth0 = std.Io.Clock.now(.awake, io);
        const samples = engine.synthLang(sa, ch.text, route) catch |e| {
            std.debug.print("[worker] id={d} chunk synth failed: {s}\n", .{ item.id, @errorName(e) });
            res.queue.finishPlaying(io, item.id);
            return e;
        };
        const t_synth1 = std.Io.Clock.now(.awake, io);
        total_synth_ns += @intCast(t_synth1.nanoseconds - t_synth0.nanoseconds);

        const sample_rate = engine.sampleRate();
        const t_play0 = std.Io.Clock.now(.awake, io);
        if (res.audio_player.ready) {
            res.audio_player.streamS16le(samples, sample_rate) catch |e| {
                std.debug.print("[worker] zaudio play failed: {s} — falling back to afplay\n", .{@errorName(e)});
                try playViaAfplay(io, sa, samples, sample_rate);
            };
        } else {
            try playViaAfplay(io, sa, samples, sample_rate);
        }
        const t_play1 = std.Io.Clock.now(.awake, io);
        total_play_ns += @intCast(t_play1.nanoseconds - t_play0.nanoseconds);
        total_samples += samples.len;
        n_chunks += 1;
    }

    const synth_ms = @as(f64, @floatFromInt(total_synth_ns)) / 1_000_000.0;
    const play_ms = @as(f64, @floatFromInt(total_play_ns)) / 1_000_000.0;
    std.debug.print(
        "[worker] piper id={d} chunks={d} synth={d:.1}ms play={d:.1}ms samples={d}\n",
        .{ item.id, n_chunks, synth_ms, play_ms, total_samples },
    );

    res.queue.finishPlaying(io, item.id);
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
    queue: *Queue,
    audio_player: *audio.AudioPlayer,
) !void {
    var read_buf: [READ_BUF]u8 = undefined;
    var write_buf: [WRITE_BUF]u8 = undefined;

    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

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
        std.debug.print("[daemon] piper engine load failed: {s}\n", .{@errorName(e)});
        std.debug.print("  voice: {s}\n", .{voice_path});
        std.debug.print("  espeak: {s}\n", .{espeak_data});
        return null;
    };
    const t1 = std.Io.Clock.now(.awake, io);
    const load_ns: f64 = @floatFromInt(t1.nanoseconds - t0.nanoseconds);
    const load_ms = load_ns / 1_000_000.0;
    std.debug.print("[daemon] piper engine loaded in {d:.1}ms\n", .{load_ms});

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
            std.debug.print("[daemon] en voice not installed at {s} — code-switch will fall back to pt\n", .{en_voice_path});
            std.debug.print("  install: ./scripts/fetch-voice-en.sh\n", .{});
            break :blk null;
        };
        f.close(io);
        break :blk en_voice_path;
    };

    const t0 = std.Io.Clock.now(.awake, io);
    const engine = piper_mod.MultiPiperEngine.initMulti(arena, pt_voice_path, en_path_opt, espeak_data) catch |e| {
        std.debug.print("[daemon] multi piper engine load failed: {s}\n", .{@errorName(e)});
        std.debug.print("  pt voice: {s}\n", .{pt_voice_path});
        std.debug.print("  espeak: {s}\n", .{espeak_data});
        return null;
    };
    const t1 = std.Io.Clock.now(.awake, io);
    const load_ms = @as(f64, @floatFromInt(t1.nanoseconds - t0.nanoseconds)) / 1_000_000.0;
    std.debug.print(
        "[daemon] multi piper engine loaded in {d:.1}ms (pt={s} en={s})\n",
        .{ load_ms, "faber", if (engine.hasEn()) "amy" else "off" },
    );

    return engine;
}
