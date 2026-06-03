// SPDX-License-Identifier: MIT OR Apache-2.0
// agent-tts — Pt-BR TTS via macOS `say` + libpiper (v0.7+).
//
// Single binary, modes:
//   agent-tts daemon                       → daemon (foreground)
//   agent-tts daemon install               → write LaunchAgent plist + bootstrap
//   agent-tts daemon uninstall             → bootout + delete plist
//   agent-tts daemon status                → loaded?/last exit
//   agent-tts queue                        → client: list pending+playing items
//   agent-tts skip                         → client: skip current playing item
//   agent-tts clear                        → client: drop all pending items
//   agent-tts piper-test "<text>" <out>    → libpiper one-shot synth (cold init)
//   agent-tts ttfa-bench --engine X --warm N → measure first-sample latency
//   agent-tts -h | --help                  → help
//   agent-tts -V | --version               → version
//   agent-tts [--engine X] [--voice V] [--rate R] "..." → enqueue on daemon
//
// v0.3: SQLite WAL queue at ~/.cache/agent-tts/queue.db.
// v0.4: launchd LaunchAgent (~/Library/LaunchAgents/io.github.biliboss.agent-tts.plist).
// v0.5: Pt-BR text preprocessor (abbreviations, cardinals 0..9999, [[slnc N]] pauses).
// v0.6: libpiper FFI baseline (PiperEngine loaded but not routed yet).
// v0.7: zaudio streaming PCM + --engine routing. Piper resident in daemon.
//
// KPI = time-to-first-audio (TTFA).

const std = @import("std");

const client = @import("client.zig");
const daemon = @import("daemon.zig");
const launchd = @import("launchd.zig");
const ipc = @import("ipc.zig");
const audio = @import("audio.zig");
const build_options = @import("build_options");

pub const VERSION = "1.0.0";

const HELP =
    \\agent-tts v{s} — Pt-BR TTS via macOS `say` or libpiper
    \\
    \\Usage:
    \\  agent-tts "texto"                send to running daemon
    \\  agent-tts --engine piper "..."   route to libpiper instead of say
    \\  agent-tts queue                  list pending + playing items
    \\  agent-tts skip                   skip current playing item
    \\  agent-tts clear                  drop all pending items
    \\  agent-tts daemon                 run daemon (foreground)
    \\  agent-tts daemon install         install launchd LaunchAgent (auto-start)
    \\  agent-tts daemon uninstall       remove launchd LaunchAgent
    \\  agent-tts daemon status          print launchd load state
    \\  agent-tts --voice "Felipe" "texto"
    \\  agent-tts --rate 220 "texto"
    \\
    \\Piper backend (v0.7+):
    \\  agent-tts --engine piper "texto"               route via libpiper
    \\                                                 (requires -Dwith-piper=true
    \\                                                  + AGENT_TTS_PIPER=1 on daemon)
    \\  agent-tts piper-test "texto" out.wav           synth one WAV (cold init)
    \\  agent-tts ttfa-bench --engine say|piper --warm N  measure first-sample latency
    \\
    \\Options:
    \\  --engine say|piper  TTS backend (default: piper; say = fallback)
    \\  --voice NAME        voice name (default: Luciana for say, faber for piper)
    \\  --rate WPM          words per minute (default: 330; ignored by piper)
    \\  -h, --help          this help
    \\  -V, --version       print version
    \\
    \\v0.7 ships zaudio streaming PCM playback + --engine routing. PiperEngine
    \\stays resident in the daemon, eliminating the ~400ms cold init cost from
    \\v0.6, and zaudio plays raw s16le without WAV+afplay.
    \\
    \\launchd plist lives at ~/Library/LaunchAgents/io.github.biliboss.agent-tts.plist
    \\(override label via AGENT_TTS_LAUNCHD_LABEL env var — used by tests).
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const home = init.environ_map.get("HOME") orelse "/tmp";

    const label_override = init.environ_map.get(launchd.LABEL_ENV);

    if (args.len > 1) {
        const cmd = args[1];
        if (std.mem.eql(u8, cmd, "daemon")) {
            if (args.len > 2) {
                const sub = args[2];
                if (std.mem.eql(u8, sub, "install")) {
                    return launchd.install(arena, io, home, label_override, null);
                }
                if (std.mem.eql(u8, sub, "uninstall")) {
                    return launchd.uninstall(arena, io, home, label_override);
                }
                if (std.mem.eql(u8, sub, "status")) {
                    return launchd.status(arena, io, home, label_override);
                }
                std.debug.print("error: unknown daemon subcommand '{s}'\n", .{sub});
                std.process.exit(2);
            }
            return daemon.run(arena, io, home);
        }
        if (std.mem.eql(u8, cmd, "piper-test")) {
            return runPiperTest(arena, io, home, args);
        }
        if (std.mem.eql(u8, cmd, "ttfa-bench")) {
            return runTtfaBench(arena, io, home, args);
        }
        if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
            std.debug.print(HELP, .{VERSION});
            return;
        }
        if (std.mem.eql(u8, cmd, "-V") or std.mem.eql(u8, cmd, "--version")) {
            std.debug.print("agent-tts {s}\n", .{VERSION});
            return;
        }
    }
    return client.run(arena, io, home, args);
}

fn runPiperTest(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    args: []const []const u8,
) !void {
    if (!build_options.enabled) {
        std.debug.print(
            "error: piper-test requires `zig build -Dwith-piper=true` and a built libpiper.dylib (see vendor/README.md)\n",
            .{},
        );
        std.process.exit(2);
    }
    if (args.len < 4) {
        std.debug.print("usage: agent-tts piper-test \"<text>\" <out.wav>\n", .{});
        std.process.exit(2);
    }
    const text = args[2];
    const out_path = args[3];

    const piper = @import("piper.zig");

    const voice_path = try std.fmt.allocPrint(
        arena,
        "{s}/.cache/agent-tts/voices/pt_BR-faber-medium.onnx",
        .{home},
    );
    const espeak_data = "vendor/piper1-gpl/libpiper/dist/share/espeak-ng-data";

    const t_init0 = std.Io.Clock.now(.awake, io);
    var engine = piper.PiperEngine.init(arena, voice_path, espeak_data) catch |e| {
        std.debug.print("error: PiperEngine.init failed: {s}\n", .{@errorName(e)});
        std.debug.print("  voice: {s}\n", .{voice_path});
        std.debug.print("  espeak: {s}\n", .{espeak_data});
        std.process.exit(1);
    };
    defer engine.deinit();
    const t_init1 = std.Io.Clock.now(.awake, io);
    const init_ms = @as(f64, @floatFromInt(t_init1.nanoseconds - t_init0.nanoseconds)) / 1_000_000.0;

    const t_synth0 = std.Io.Clock.now(.awake, io);
    engine.synthToWav(io, text, out_path) catch |e| {
        std.debug.print("error: synthToWav failed: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    const t_synth1 = std.Io.Clock.now(.awake, io);
    const synth_ms = @as(f64, @floatFromInt(t_synth1.nanoseconds - t_synth0.nanoseconds)) / 1_000_000.0;

    std.debug.print("[piper-test] init={d:.1}ms synth={d:.1}ms total={d:.1}ms out={s}\n", .{
        init_ms, synth_ms, init_ms + synth_ms, out_path,
    });
}

// ttfa-bench: hidden bench subcommand. Spins through N warm synth+play cycles
// for the given engine, prints first-sample latency stats. For piper, init
// runs once (the "warm" precondition). For say, we measure the spawn-to-first
// audio path. Output is a single line of CSV-like stats to keep capture easy.
fn runTtfaBench(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    args: []const []const u8,
) !void {
    // Parse --engine and --warm flags.
    var engine: ipc.Engine = .say;
    var warm: u32 = 5;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--engine")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --engine needs value\n", .{});
                std.process.exit(2);
            }
            engine = ipc.Engine.fromStr(args[i]) orelse {
                std.debug.print("error: --engine invalid (got '{s}')\n", .{args[i]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--warm")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --warm needs value\n", .{});
                std.process.exit(2);
            }
            warm = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("error: --warm invalid (got '{s}')\n", .{args[i]});
                std.process.exit(2);
            };
        }
    }

    if (engine == .piper and !build_options.enabled) {
        std.debug.print("error: --engine piper requires zig build -Dwith-piper=true\n", .{});
        std.process.exit(2);
    }

    const text = "Olá, este é um teste de latência.";

    // Engine-specific bench paths. Both report "TTFA real" — wall-clock time
    // from t0 (after init / pre-warm) to first audio frame entering the
    // device pump. For piper that's synth+zaudio start; for say it's the
    // round-trip until /usr/bin/say wakes up and starts pushing audio.
    switch (engine) {
        .say => try benchSay(arena, io, warm, text),
        .piper => try benchPiper(arena, io, home, warm, text),
    }
}

fn benchSay(arena: std.mem.Allocator, io: std.Io, warm: u32, text: []const u8) !void {
    // Pre-warm the Luciana voice once so the "warm" precondition holds.
    const tts = @import("tts.zig");
    tts.preWarm(arena, io, "Luciana") catch {};

    var i: u32 = 0;
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    while (i < warm) : (i += 1) {
        const t0 = std.Io.Clock.now(.awake, io);
        var spawned = try tts.spawnSay(arena, io, "Luciana", 330, text);
        _ = try spawned.child.wait(io);
        const t1 = std.Io.Clock.now(.awake, io);
        const dt: u64 = @intCast(t1.nanoseconds - t0.nanoseconds);
        total_ns += dt;
        if (dt < min_ns) min_ns = dt;
        if (dt > max_ns) max_ns = dt;
    }
    const avg = @as(f64, @floatFromInt(total_ns / warm)) / 1_000_000.0;
    const min_ms = @as(f64, @floatFromInt(min_ns)) / 1_000_000.0;
    const max_ms = @as(f64, @floatFromInt(max_ns)) / 1_000_000.0;
    std.debug.print(
        "[ttfa-bench] engine=say warm={d} avg={d:.1}ms min={d:.1}ms max={d:.1}ms\n",
        .{ warm, avg, min_ms, max_ms },
    );
    std.debug.print(
        "  note: `say` runs as a separate process; this measures spawn+playback wall time,\n  not the first-sample latency the speakers hear. Real TTFA is dominated by say's\n  internal pre-warm — daemon path is faster because the voice stays warm.\n",
        .{},
    );
}

fn benchPiper(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    warm: u32,
    text: []const u8,
) !void {
    if (!build_options.enabled) unreachable;
    const piper = @import("piper.zig");

    const voice_path = try std.fmt.allocPrint(
        arena,
        "{s}/.cache/agent-tts/voices/pt_BR-faber-medium.onnx",
        .{home},
    );
    const espeak_data = "vendor/piper1-gpl/libpiper/dist/share/espeak-ng-data";

    // Init once — "warm" precondition.
    const t_init0 = std.Io.Clock.now(.awake, io);
    var engine = try piper.PiperEngine.init(arena, voice_path, espeak_data);
    defer engine.deinit();
    const t_init1 = std.Io.Clock.now(.awake, io);
    const init_ms = @as(f64, @floatFromInt(t_init1.nanoseconds - t_init0.nanoseconds)) / 1_000_000.0;

    var player = audio.AudioPlayer.init(arena);
    defer player.deinit();
    if (!player.ready) {
        std.debug.print("[ttfa-bench] zaudio init failed — bench measures synth-only times\n", .{});
    }

    // First-sample capture: writes a timestamp into a heap cell when zaudio
    // pumps the buffer. For the say-fallback (no zaudio) we skip this and
    // record synth time as a TTFA proxy.
    var first_sample_ns: i128 = 0;
    const FirstSampleCtx = struct {
        ns: *i128,
        io: std.Io,
        fn cb(ctx_opaque: ?*anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(ctx_opaque.?));
            const now = std.Io.Clock.now(.awake, ctx.io);
            ctx.ns.* = now.nanoseconds;
        }
    };
    var ctx = FirstSampleCtx{ .ns = &first_sample_ns, .io = io };
    player.on_first_sample = FirstSampleCtx.cb;
    player.on_first_sample_ctx = @ptrCast(&ctx);

    var i: u32 = 0;
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var synth_total_ns: u64 = 0;
    while (i < warm) : (i += 1) {
        first_sample_ns = 0;
        const t0 = std.Io.Clock.now(.awake, io);

        const samples = try engine.synthToSamples(arena, text);
        const t_synth_done = std.Io.Clock.now(.awake, io);
        synth_total_ns += @intCast(t_synth_done.nanoseconds - t0.nanoseconds);

        if (player.ready) {
            try player.streamS16le(samples, engine.sampleRate());
        }

        // TTFA = first_sample_ns - t0, or synth time if zaudio unavailable.
        const ttfa_ns: u64 = if (player.ready and first_sample_ns > 0)
            @intCast(first_sample_ns - t0.nanoseconds)
        else
            @intCast(t_synth_done.nanoseconds - t0.nanoseconds);
        total_ns += ttfa_ns;
        if (ttfa_ns < min_ns) min_ns = ttfa_ns;
        if (ttfa_ns > max_ns) max_ns = ttfa_ns;
    }
    const avg = @as(f64, @floatFromInt(total_ns / warm)) / 1_000_000.0;
    const min_ms = @as(f64, @floatFromInt(min_ns)) / 1_000_000.0;
    const max_ms = @as(f64, @floatFromInt(max_ns)) / 1_000_000.0;
    const synth_avg = @as(f64, @floatFromInt(synth_total_ns / warm)) / 1_000_000.0;
    std.debug.print(
        "[ttfa-bench] engine=piper warm={d} init={d:.1}ms ttfa avg={d:.1}ms min={d:.1}ms max={d:.1}ms synth_avg={d:.1}ms zaudio={s}\n",
        .{
            warm,                       init_ms,
            avg,                        min_ms,
            max_ms,                     synth_avg,
            if (player.ready) "on" else "off",
        },
    );
}
