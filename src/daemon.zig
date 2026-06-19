// SPDX-License-Identifier: MIT OR Apache-2.0
// Daemon: accept loop on UNIX socket, worker thread drains SQLite queue and
// routes all synthesis to KokoroEngine (ONNX + espeak-ng, no Python).
//
// Kokoro is the sole engine. Piper/say/cloned paths removed.
// The KokoroEngine is initialised once at daemon boot (amortises model load
// over the lifetime of the process — keeps TTFA warm after first call).
//
// Asset resolution order (model + voice):
//   1. KOKORO_MODEL / KOKORO_VOICE env vars
//   2. ~/.cache/ptah/kokoro-v1.0.onnx / ~/.cache/ptah/pf_dora.bin
//   3. $PTAH_REPO_ROOT/assets/  (dev path, probe only)
//   4. /opt/homebrew/share/ptah/assets/ (brew install path)
//
// espeak-ng data dir: ESPEAK_DATA_PATH or /opt/homebrew/opt/espeak-ng/share

const std = @import("std");
const ipc = @import("ipc.zig");
const Queue = @import("queue.zig").Queue;
const queue_mod = @import("queue.zig");
const audio = @import("audio.zig");
const preproc = @import("preproc.zig");
const postfx_mod = @import("postfx.zig");
const kokoro_mod = @import("kokoro.zig");

const dlog = std.log.scoped(.daemon);
const wlog = std.log.scoped(.worker);

const READ_BUF = 16 * 1024;
const WRITE_BUF = 64 * 1024;
const DEFAULT_VOICE = "pf_dora";
const DEFAULT_SPEED: f32 = 1.0;

/// Daemon-scoped handles the worker borrows.
const Resources = struct {
    queue: *Queue,
    audio_player: *audio.AudioPlayer,
    kokoro: ?*kokoro_mod.KokoroEngine,
    io: std.Io,
    home: []const u8,
    /// Speed override from KOKORO_SPEED env var (default 1.0).
    speed: f32,
    /// v1.10.2 — id of the row the worker is currently playing.
    current_playing_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

pub fn run(arena: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    const sock_path = try ipc.socketPath(arena, io, home);
    const db_path = try ipc.queueDbPath(arena, io, home);

    std.Io.Dir.cwd().deleteFile(io, sock_path) catch {};

    var addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    dlog.info("listening on {s}", .{sock_path});
    dlog.info("queue db {s}", .{db_path});

    var queue: Queue = .{ .arena = arena };
    try queue.init(db_path);
    defer queue.deinit();

    const pend_on_boot = queue.pending(io);
    if (pend_on_boot > 0) {
        dlog.info("recovered {d} pending items from previous run", .{pend_on_boot});
    }

    // Audio player (afplay wrapper). Best-effort.
    const t_audio0 = std.Io.Clock.now(.awake, io);
    var audio_player = audio.AudioPlayer.init(arena);
    const t_audio1 = std.Io.Clock.now(.awake, io);
    const audio_ms = @as(f64, @floatFromInt(t_audio1.nanoseconds - t_audio0.nanoseconds)) / 1_000_000.0;
    if (audio_player.ready) {
        dlog.info("audio player init in {d:.1}ms", .{audio_ms});
    } else {
        dlog.warn("audio player init failed ({d:.1}ms) — will fall back to afplay", .{audio_ms});
    }
    defer audio_player.deinit();

    // ONNX threading: use the machine's cores. kokoro.zig calls
    // SetIntraOpNumThreads(0) so ORT picks the physical-core count. We do NOT
    // force single-thread anymore (that was a piper-era knob) — Kokoro VITS
    // synth is the TTFA bottleneck and wants the cores. Honor an explicit
    // PTAH_ORT_THREADS override if set, otherwise leave OMP/ORT at ORT default.
    {
        const cenv = @cImport({
            @cInclude("stdlib.h");
        });
        if (cenv.getenv("PTAH_ORT_THREADS")) |n| {
            _ = cenv.setenv("OMP_NUM_THREADS", n, 1);
            _ = cenv.setenv("ORT_NUM_THREADS", n, 1);
            dlog.info("onnx threading: PTAH_ORT_THREADS={s}", .{std.mem.span(n)});
        } else {
            dlog.info("onnx threading: multi-thread (ORT auto intra-op)", .{});
        }
    }

    // Speed from env (overridable per-call later via --speed flag when wired).
    const speed = blk: {
        const c = @cImport({
            @cInclude("stdlib.h");
        });
        const ptr = c.getenv("KOKORO_SPEED");
        if (ptr == null) break :blk DEFAULT_SPEED;
        const s = std.mem.span(ptr);
        break :blk std.fmt.parseFloat(f32, s) catch DEFAULT_SPEED;
    };

    // Boot KokoroEngine. Resolve asset paths.
    var kokoro_engine_storage: ?kokoro_mod.KokoroEngine = null;
    var kokoro_engine_ptr: ?*kokoro_mod.KokoroEngine = null;
    if (bootKokoro(arena, io, home)) |engine| {
        kokoro_engine_storage = engine;
        kokoro_engine_ptr = &kokoro_engine_storage.?;
    }
    defer if (kokoro_engine_storage) |*e| @constCast(e).deinit();

    var resources: Resources = .{
        .queue = &queue,
        .audio_player = &audio_player,
        .kokoro = kokoro_engine_ptr,
        .io = io,
        .home = home,
        .speed = speed,
    };

    const worker = try std.Thread.spawn(.{}, workerLoop, .{&resources});
    worker.detach();

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
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();

    const io = res.io;

    while (res.queue.pop(io, gpa)) |item| {
        defer gpa.free(item.voice);
        defer gpa.free(item.text);
        res.current_playing_id.store(item.id, .release);
        defer res.current_playing_id.store(0, .release);
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

fn runOne(res: *Resources, io: std.Io, gpa: std.mem.Allocator, item: queue_mod.PoppedItem) !void {
    var spawn_arena = std.heap.ArenaAllocator.init(gpa);
    defer spawn_arena.deinit();
    const sa = spawn_arena.allocator();

    // All items route through Kokoro. If engine not available, log and skip.
    const engine = res.kokoro orelse {
        wlog.err("id={d} KokoroEngine not available — item skipped", .{item.id});
        return;
    };

    res.queue.setPlaying(io, item.id, @intCast(std.c.getpid()));

    // Speed: use res.speed (daemon-wide) as default.
    const speed = res.speed;

    const t_synth0 = std.Io.Clock.now(.awake, io);
    const result = engine.synth(item.text, speed, sa) catch |e| {
        wlog.err("id={d} kokoro synth failed: {s}", .{ item.id, @errorName(e) });
        return e;
    };
    const t_synth1 = std.Io.Clock.now(.awake, io);

    const sample_rate = kokoro_mod.KokoroEngine.SAMPLE_RATE;

    const t_play0 = std.Io.Clock.now(.awake, io);
    try playWithPostfx(res, io, sa, item.id, result.pcm, sample_rate, item.postfx, false);
    const t_play1 = std.Io.Clock.now(.awake, io);

    const synth_ms = @as(f64, @floatFromInt(t_synth1.nanoseconds - t_synth0.nanoseconds)) / 1_000_000.0;
    const play_ms = @as(f64, @floatFromInt(t_play1.nanoseconds - t_play0.nanoseconds)) / 1_000_000.0;
    wlog.info("kokoro id={d} synth={d:.1}ms play={d:.1}ms samples={d} rtf={d:.3}", .{
        item.id, synth_ms, play_ms, result.pcm.len, result.infer_s / result.duration_s,
    });

    res.queue.finishPlaying(io, item.id);
}

/// Play samples through the postfx chain (when postfx != .off) then onto
/// the device. Falls back to afplay when afplay is unavailable.
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
            wlog.warn("afplay play failed: {s} — falling back to afplay", .{@errorName(e)});
            try playViaAfplay(io, sa, processed, sample_rate);
        };
    } else {
        try playViaAfplay(io, sa, processed, sample_rate);
    }
}

fn playViaAfplay(io: std.Io, sa: std.mem.Allocator, samples: []const i16, sample_rate: u32) !void {
    const tmp_path = try std.fmt.allocPrint(sa, "/tmp/ptah-{d}.wav", .{std.c.getpid()});
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

fn fileExists(path: []const u8) bool {
    const buf = std.heap.smp_allocator.dupeZ(u8, path) catch return false;
    defer std.heap.smp_allocator.free(buf);
    const fd = std.c.open(buf.ptr, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return false;
    _ = std.c.close(fd);
    return true;
}

/// Resolve Kokoro asset paths and boot the engine.
/// Priority: env vars → ~/.cache/ptah/ → repo assets/ → brew share path.
/// Returns null on failure (daemon runs degraded — enqueues silently drop).
fn bootKokoro(arena: std.mem.Allocator, io: std.Io, home: []const u8) ?kokoro_mod.KokoroEngine {
    const c = @cImport({
        @cInclude("stdlib.h");
    });

    // Model path
    const model_path: [:0]const u8 = blk: {
        const env_ptr = c.getenv("KOKORO_MODEL");
        if (env_ptr != null) {
            const s = std.mem.span(env_ptr);
            if (s.len > 0) break :blk arena.dupeZ(u8, s) catch return null;
        }
        // ~/.cache/ptah/kokoro-v1.0.onnx
        const cache = std.fmt.allocPrint(arena, "{s}/.cache/ptah/kokoro-v1.0.onnx", .{home}) catch return null;
        if (fileExists(cache)) break :blk arena.dupeZ(u8, cache) catch return null;
        // $PTAH_REPO_ROOT/assets/
        const env_root = c.getenv("PTAH_REPO_ROOT");
        if (env_root != null) {
            const s = std.mem.span(env_root);
            if (s.len > 0) {
                const repo = std.fmt.allocPrint(arena, "{s}/assets/kokoro-v1.0.onnx", .{s}) catch return null;
                if (fileExists(repo)) break :blk arena.dupeZ(u8, repo) catch return null;
            }
        }
        // brew
        const brew = "/opt/homebrew/share/ptah/assets/kokoro-v1.0.onnx";
        if (fileExists(brew)) break :blk arena.dupeZ(u8, brew) catch return null;
        dlog.err("KokoroEngine: model not found — set KOKORO_MODEL or place kokoro-v1.0.onnx in ~/.cache/ptah/", .{});
        return null;
    };

    // Voice path (pf_dora.bin)
    const voice_path: [:0]const u8 = blk: {
        const env_ptr = c.getenv("KOKORO_VOICE");
        if (env_ptr != null) {
            const s = std.mem.span(env_ptr);
            if (s.len > 0) break :blk arena.dupeZ(u8, s) catch return null;
        }
        const cache = std.fmt.allocPrint(arena, "{s}/.cache/ptah/pf_dora.bin", .{home}) catch return null;
        if (fileExists(cache)) break :blk arena.dupeZ(u8, cache) catch return null;
        const env_root = c.getenv("PTAH_REPO_ROOT");
        if (env_root != null) {
            const s = std.mem.span(env_root);
            if (s.len > 0) {
                const repo = std.fmt.allocPrint(arena, "{s}/assets/pf_dora.bin", .{s}) catch return null;
                if (fileExists(repo)) break :blk arena.dupeZ(u8, repo) catch return null;
            }
        }
        const brew = "/opt/homebrew/share/ptah/assets/pf_dora.bin";
        if (fileExists(brew)) break :blk arena.dupeZ(u8, brew) catch return null;
        dlog.err("KokoroEngine: voice not found — set KOKORO_VOICE or place pf_dora.bin in ~/.cache/ptah/", .{});
        return null;
    };

    // espeak-ng data dir
    const espeak_dir: [:0]const u8 = blk: {
        const env_ptr = c.getenv("ESPEAK_DATA_PATH");
        if (env_ptr != null) {
            const s = std.mem.span(env_ptr);
            if (s.len > 0) break :blk arena.dupeZ(u8, s) catch return null;
        }
        break :blk "/opt/homebrew/opt/espeak-ng/share";
    };

    dlog.info("KokoroEngine: model={s}", .{model_path});
    dlog.info("KokoroEngine: voice={s}", .{voice_path});
    dlog.info("KokoroEngine: espeak={s}", .{espeak_dir});

    const t0 = std.Io.Clock.now(.awake, io);
    const engine = kokoro_mod.KokoroEngine.init(io, arena, model_path, voice_path, espeak_dir) catch |e| {
        dlog.err("KokoroEngine.init failed: {s}", .{@errorName(e)});
        return null;
    };
    const t1 = std.Io.Clock.now(.awake, io);
    const load_ms = @as(f64, @floatFromInt(t1.nanoseconds - t0.nanoseconds)) / 1_000_000.0;
    dlog.info("KokoroEngine loaded in {d:.1}ms", .{load_ms});

    return engine;
}
