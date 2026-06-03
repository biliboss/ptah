// SPDX-License-Identifier: MIT OR Apache-2.0
// agent-tts — multilingual TTS via macOS `say` + libpiper (v1.1+).
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
//   agent-tts [--engine X] [--lang L] [--voice V] [--rate R] "..." → enqueue
//
// v0.3: SQLite WAL queue at ~/.cache/agent-tts/queue.db.
// v0.4: launchd LaunchAgent (~/Library/LaunchAgents/io.github.biliboss.agent-tts.plist).
// v0.5: Pt-BR text preprocessor (abbreviations, cardinals 0..9999, [[slnc N]] pauses).
// v0.6: libpiper FFI baseline (PiperEngine loaded but not routed yet).
// v0.7: zaudio streaming PCM + --engine routing. Piper resident in daemon.
// v1.0: universal binary + brew tap + GitHub Pages docs.
// v1.1: language detection + En Piper voice routing (code-switch Pt+En).
// v1.2: sentence chunking + pipelined synth/audio (streaming long inputs).
// v1.3: cross-platform — Linux espeak-ng + systemd, Windows best-effort.
// v1.4: `voice clone` + `voice list` subcommands; XTTS-v2 Python sidecar.
// v1.5: stdio JSON-RPC MCP server (`agent-tts mcp`) for Claude Code / Cursor / Cline.
// v1.7: streaming text input — `agent-tts stream` (stdin) + `say_stream` MCP tool.
//
// KPI = time-to-first-audio (TTFA).

const std = @import("std");

const client = @import("client.zig");
const daemon = @import("daemon.zig");
const launchd = @import("launchd.zig");
const systemd = @import("systemd.zig");
const platform = @import("platform.zig");
const ipc = @import("ipc.zig");
const audio = @import("audio.zig");
const voice = @import("voice.zig");
const mcp = @import("mcp.zig");
const stream_mod = @import("stream.zig");
const build_options = @import("build_options");

pub const VERSION = "1.7.0";

const HELP =
    \\agent-tts v{s} — multilingual TTS via system voice or libpiper
    \\
    \\Usage:
    \\  agent-tts "texto"                send to running daemon
    \\  agent-tts --engine piper "..."   route to libpiper instead of system voice
    \\  agent-tts --lang en "Hello"      force English voice (Amy)
    \\  agent-tts --lang pt "Olá"        force Portuguese voice (Faber)
    \\  agent-tts queue                  list pending + playing items
    \\  agent-tts skip                   skip current playing item
    \\  agent-tts clear                  drop all pending items
    \\  agent-tts daemon                 run daemon (foreground)
    \\  agent-tts daemon install         install auto-start unit
    \\                                   (launchd on macOS, systemd on Linux)
    \\  agent-tts daemon uninstall       remove auto-start unit
    \\  agent-tts daemon status          print auto-start load state
    \\  agent-tts voice clone            clone a voice from a 20-120s WAV (v1.4+)
    \\    --sample <wav> --name <slug>
    \\  agent-tts voice list             list installed voices (faber + cloned)
    \\  agent-tts mcp                    speak over stdio MCP (Claude Code / Cursor / Cline) (v1.5+)
    \\  agent-tts stream                 read stdin, enqueue each sentence as terminators arrive (v1.7+)
    \\    [--engine X] [--voice V] [--rate R]
    \\  agent-tts --voice "Felipe" "texto"
    \\  agent-tts --voice gabriel "..."  use a cloned voice (v1.4+)
    \\  agent-tts --rate 220 "texto"
    \\
    \\Piper backend (v0.7+):
    \\  agent-tts --engine piper "texto"               route via libpiper
    \\                                                 (requires -Dwith-piper=true
    \\                                                  + AGENT_TTS_PIPER=1 on daemon)
    \\  agent-tts piper-test "texto" out.wav           synth one WAV (cold init)
    \\  agent-tts ttfa-bench --engine say|piper --warm N [--input short|long|stream]
    \\                                                 measure first-sample latency
    \\                                                 (--input long enables v1.2 streaming bench;
    \\                                                  --input stream simulates token-by-token feed)
    \\
    \\Options:
    \\  --engine say|piper  TTS backend (default: piper; say = system fallback)
    \\  --lang auto|pt|en   language routing (default: auto; piper-only)
    \\  --voice NAME        voice name (default: Luciana for say, faber for piper;
    \\                      on Linux Luciana auto-maps to espeak-ng pt-br)
    \\  --rate WPM          words per minute (default: 330; ignored by piper)
    \\  -h, --help          this help
    \\  -V, --version       print version
    \\
    \\System voice per platform:
    \\  macOS    /usr/bin/say                  (Luciana / Felipe Premium)
    \\  Linux    espeak-ng -v pt-br            (apt install espeak-ng)
    \\  Windows  powershell System.Speech      (best-effort, runtime untested)
    \\
    \\Multilingual code-switching (v1.1): the daemon loads both Pt (Faber) and
    \\En (Amy) voices when -Dwith-piper=true. Each enqueued message is
    \\sentence-split, each sentence detected via a stopword tokenizer, and
    \\routed to the matching voice. Force a single voice with --lang pt|en.
    \\Install voices: scripts/fetch-voice.sh + scripts/fetch-voice-en.sh.
    \\
    \\Auto-start per platform:
    \\  macOS    ~/Library/LaunchAgents/io.github.biliboss.agent-tts.plist
    \\           (override label via AGENT_TTS_LAUNCHD_LABEL)
    \\  Linux    ~/.config/systemd/user/agent-tts.service
    \\           (override unit name via AGENT_TTS_SYSTEMD_UNIT)
    \\  Windows  not implemented — runs foreground only in v1.3
    \\
    \\Claude Code MCP wire-up (single line in ~/.claude.json):
    \\  "mcpServers": {{ "agent-tts": {{ "command": "agent-tts", "args": ["mcp"] }} }}
    \\See ./scripts/install-mcp.sh for an idempotent installer.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const home = init.environ_map.get("HOME") orelse "/tmp";

    const label_override = init.environ_map.get(launchd.LABEL_ENV);
    const systemd_unit_override = init.environ_map.get(systemd.UNIT_ENV);
    const xdg_config = init.environ_map.get("XDG_CONFIG_HOME");

    if (args.len > 1) {
        const cmd = args[1];
        if (std.mem.eql(u8, cmd, "daemon")) {
            if (args.len > 2) {
                const sub = args[2];
                if (std.mem.eql(u8, sub, "install")) {
                    return switch (comptime platform.current()) {
                        .macos => launchd.install(arena, io, home, label_override, null),
                        .linux => systemd.install(arena, io, home, xdg_config, systemd_unit_override, null),
                        .windows => {
                            std.debug.print(
                                "error: daemon install not implemented on Windows (v1.3 best-effort) — run `agent-tts daemon` from a Startup folder shortcut or schtasks /create\n",
                                .{},
                            );
                            std.process.exit(2);
                        },
                    };
                }
                if (std.mem.eql(u8, sub, "uninstall")) {
                    return switch (comptime platform.current()) {
                        .macos => launchd.uninstall(arena, io, home, label_override),
                        .linux => systemd.uninstall(arena, io, home, xdg_config, systemd_unit_override),
                        .windows => {
                            std.debug.print("error: daemon uninstall not implemented on Windows\n", .{});
                            std.process.exit(2);
                        },
                    };
                }
                if (std.mem.eql(u8, sub, "status")) {
                    return switch (comptime platform.current()) {
                        .macos => launchd.status(arena, io, home, label_override),
                        .linux => systemd.status(arena, io, home, xdg_config, systemd_unit_override),
                        .windows => {
                            std.debug.print("error: daemon status not implemented on Windows\n", .{});
                            std.process.exit(2);
                        },
                    };
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
        if (std.mem.eql(u8, cmd, "voice")) {
            return voice.run(arena, io, home, args);
        }
        if (std.mem.eql(u8, cmd, "mcp")) {
            return mcp.run(arena, io, home);
        }
        if (std.mem.eql(u8, cmd, "stream")) {
            return stream_mod.run(arena, io, home, args);
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
    // Parse --engine, --warm, --input flags.
    var engine: ipc.Engine = .say;
    var warm: u32 = 5;
    var input_mode: InputMode = .short;
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
        } else if (std.mem.eql(u8, a, "--input")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --input needs value (short|long|stream)\n", .{});
                std.process.exit(2);
            }
            if (std.mem.eql(u8, args[i], "short")) {
                input_mode = .short;
            } else if (std.mem.eql(u8, args[i], "long")) {
                input_mode = .long;
            } else if (std.mem.eql(u8, args[i], "stream")) {
                input_mode = .stream;
            } else {
                std.debug.print("error: --input must be short|long|stream (got '{s}')\n", .{args[i]});
                std.process.exit(2);
            }
        }
    }

    if (engine == .piper and !build_options.enabled) {
        std.debug.print("error: --engine piper requires zig build -Dwith-piper=true\n", .{});
        std.process.exit(2);
    }

    // Engine-specific bench paths. Both report "TTFA real" — wall-clock time
    // from t0 (after init / pre-warm) to first audio frame entering the
    // device pump. For piper that's synth+zaudio start; for say it's the
    // round-trip until /usr/bin/say wakes up and starts pushing audio.
    //
    // v1.2: `--input long` routes piper through the streaming pipeline bench
    // (sentence chunking + first-audio capture + inter-chunk gap stats). For
    // `say` the long-input path falls back to the standard wall-time bench —
    // streaming is a piper-only optimization (say is one-shot per spawn).
    switch (engine) {
        .say => {
            const text = if (input_mode == .long or input_mode == .stream) try loadLongInput(arena, io) else "Olá, este é um teste de latência.";
            try benchSay(arena, io, warm, text);
        },
        .piper => switch (input_mode) {
            .short => try benchPiper(arena, io, home, warm, "Olá, este é um teste de latência."),
            .long => {
                const text = try loadLongInput(arena, io);
                try benchPiperLong(arena, io, home, warm, text);
            },
            .stream => {
                const text = try loadLongInput(arena, io);
                try benchPiperStream(arena, io, home, warm, text);
            },
        },
        .cloned => {
            std.debug.print(
                "[ttfa-bench] engine=cloned not benchable from this path (sidecar startup dominates). " ++
                    "Use `agent-tts --voice <slug> '...'` against a running daemon to measure end-to-end.\n",
                .{},
            );
        },
    }
}

const InputMode = enum { short, long, stream };

// Hardcoded fallback: short paragraph if `_qa/v1.2-long-input.txt` isn't
// readable from cwd (e.g. binary invoked outside the repo). Long enough to
// trigger multi-chunk streaming so the bench still produces meaningful
// first-audio + gap numbers even without the file.
const LONG_INPUT_FALLBACK =
    \\Olá. Este é um teste do pipeline de streaming da versão 1.2.
    \\O texto tem várias sentenças. Cada uma vira um chunk. O sintetizador roda em uma thread.
    \\A engine de áudio toca em outra. O buffer entre as duas é pequeno. A primeira amostra sai cedo.
    \\Esperamos que a latência do primeiro áudio caia para perto do tempo de síntese da primeira sentença.
    \\No fluxo antigo, o usuário esperava o texto inteiro. Agora ouve quase que imediatamente.
;

fn loadLongInput(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const path = "_qa/v1.2-long-input.txt";
    // 64 KB ceiling — long inputs are paragraphs, not novels.
    const limit: std.Io.Limit = .limited(64 * 1024);
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch |e| {
        std.debug.print("[ttfa-bench] long-input '{s}' unreadable ({s}), using inline fallback\n", .{ path, @errorName(e) });
        return LONG_INPUT_FALLBACK;
    };
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
            warm,                              init_ms,
            avg,                               min_ms,
            max_ms,                            synth_avg,
            if (player.ready) "on" else "off",
        },
    );
}

// v1.2 long-input bench. Runs piper through the streaming pipeline (chunk →
// synth thread → audio thread). Captures: first-audio latency (t0 → first
// sample enters zaudio), total wall time, inter-chunk gap (median + max).
//
// "Inter-chunk gap" is the time between the end of chunk N's playback and
// the start of chunk N+1's playback. With back-to-back AudioBuffer plays
// that's bounded by the create/destroy cost of the next Sound — sub-ms on
// M-class silicon, well under one device period.
fn benchPiperLong(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    warm: u32,
    text: []const u8,
) !void {
    if (!build_options.enabled) unreachable;
    const piper = @import("piper.zig");
    const preproc = @import("preproc.zig");

    const voice_path = try std.fmt.allocPrint(
        arena,
        "{s}/.cache/agent-tts/voices/pt_BR-faber-medium.onnx",
        .{home},
    );
    const espeak_data = "vendor/piper1-gpl/libpiper/dist/share/espeak-ng-data";

    const t_init0 = std.Io.Clock.now(.awake, io);
    var engine = try piper.PiperEngine.init(arena, voice_path, espeak_data);
    defer engine.deinit();
    const t_init1 = std.Io.Clock.now(.awake, io);
    const init_ms = @as(f64, @floatFromInt(t_init1.nanoseconds - t_init0.nanoseconds)) / 1_000_000.0;

    var player = audio.AudioPlayer.init(arena);
    defer player.deinit();
    if (!player.ready) {
        std.debug.print("[ttfa-bench] zaudio init failed — long-input bench requires zaudio; aborting\n", .{});
        return;
    }

    // Chunk the input once. Same path the daemon takes; chunk count drives
    // the gap stats.
    const chunks = try preproc.chunkSentences(arena, text);
    std.debug.print("[ttfa-bench] long-input bytes={d} chunks={d}\n", .{ text.len, chunks.len });
    if (chunks.len == 0) {
        std.debug.print("[ttfa-bench] long-input produced 0 chunks — nothing to bench\n", .{});
        return;
    }

    // Per-iteration result store. Keeps allocations off the hot loop.
    const Result = struct {
        first_audio_ms: f64,
        total_ms: f64,
        gap_median_ms: f64,
        gap_max_ms: f64,
        synth_total_ms: f64,
    };
    var results: std.ArrayList(Result) = .empty;
    try results.ensureTotalCapacity(arena, warm);

    var iter: u32 = 0;
    while (iter < warm) : (iter += 1) {
        // Single-producer / single-consumer ring with the same shape the
        // daemon uses, but inlined here so the bench owns timing.
        const RING_CAP: usize = 2;
        const ChunkSlot = struct {
            arena: ?std.heap.ArenaAllocator = null,
            samples: []const i16 = &.{},
            sample_rate: u32 = 0,
            synth_err: bool = false,
        };

        var slots: [RING_CAP]ChunkSlot = [_]ChunkSlot{.{}} ** RING_CAP;
        var head: std.atomic.Value(usize) = .init(0);
        var tail: std.atomic.Value(usize) = .init(0);
        var closed: std.atomic.Value(bool) = .init(false);

        const Producer = struct {
            engine: *piper.PiperEngine,
            chunks: []const preproc.Chunk,
            slots: *[RING_CAP]ChunkSlot,
            head: *std.atomic.Value(usize),
            tail: *std.atomic.Value(usize),
            closed: *std.atomic.Value(bool),

            fn run(p: @This()) void {
                const ts: std.c.timespec = .{ .sec = 0, .nsec = 2 * std.time.ns_per_ms };
                for (p.chunks) |chunk| {
                    // Wait for free slot.
                    while (true) {
                        const h = p.head.load(.acquire);
                        const t = p.tail.load(.acquire);
                        if (h - t < RING_CAP) break;
                        _ = std.c.nanosleep(&ts, null);
                    }
                    const gpa = std.heap.smp_allocator;
                    const arena_box = gpa.create(std.heap.ArenaAllocator) catch {
                        const h2 = p.head.load(.acquire);
                        p.slots[h2 % RING_CAP] = .{ .synth_err = true };
                        p.head.store(h2 + 1, .release);
                        continue;
                    };
                    arena_box.* = std.heap.ArenaAllocator.init(gpa);
                    const samples = p.engine.synthToSamples(arena_box.allocator(), chunk.text) catch {
                        arena_box.deinit();
                        gpa.destroy(arena_box);
                        const h2 = p.head.load(.acquire);
                        p.slots[h2 % RING_CAP] = .{ .synth_err = true };
                        p.head.store(h2 + 1, .release);
                        continue;
                    };
                    const rate = p.engine.sampleRate();
                    const h2 = p.head.load(.acquire);
                    p.slots[h2 % RING_CAP] = .{
                        .arena = arena_box.*,
                        .samples = samples,
                        .sample_rate = rate,
                    };
                    p.head.store(h2 + 1, .release);
                    gpa.destroy(arena_box);
                }
                p.closed.store(true, .release);
            }
        };

        var first_sample_ns: i128 = 0;
        const FsCtx = struct {
            ns: *i128,
            io: std.Io,
            fn cb(opaque_ctx: ?*anyopaque) void {
                const c: *@This() = @ptrCast(@alignCast(opaque_ctx.?));
                // Latch on first fire only — every chunk calls back after its
                // sound.start(), but TTFA is the FIRST chunk's start time.
                if (c.ns.* != 0) return;
                const now = std.Io.Clock.now(.awake, c.io);
                c.ns.* = now.nanoseconds;
            }
        };
        var fs_ctx = FsCtx{ .ns = &first_sample_ns, .io = io };
        player.on_first_sample = FsCtx.cb;
        player.on_first_sample_ctx = @ptrCast(&fs_ctx);

        // Per-chunk inter-arrival gaps. gap[N] = play_start[N] - play_end[N-1].
        var gaps_ns: std.ArrayList(u64) = .empty;
        try gaps_ns.ensureTotalCapacity(arena, chunks.len);

        const producer_args = Producer{
            .engine = &engine,
            .chunks = chunks,
            .slots = &slots,
            .head = &head,
            .tail = &tail,
            .closed = &closed,
        };

        const t0 = std.Io.Clock.now(.awake, io);
        const producer_thread = try std.Thread.spawn(.{}, Producer.run, .{producer_args});

        var prev_play_end_ns: i128 = 0;
        var played: usize = 0;
        var total_samples: usize = 0;

        const ts_pop: std.c.timespec = .{ .sec = 0, .nsec = 2 * std.time.ns_per_ms };
        consumer: while (true) {
            const h = head.load(.acquire);
            const t = tail.load(.acquire);
            if (h <= t) {
                if (closed.load(.acquire)) break :consumer;
                _ = std.c.nanosleep(&ts_pop, null);
                continue;
            }
            var slot = slots[t % RING_CAP];
            tail.store(t + 1, .release);

            if (slot.synth_err) {
                if (slot.arena) |*a| @constCast(a).deinit();
                continue;
            }

            const t_play_start = std.Io.Clock.now(.awake, io);
            if (prev_play_end_ns != 0) {
                const gap: u64 = @intCast(t_play_start.nanoseconds - prev_play_end_ns);
                try gaps_ns.append(arena, gap);
            }

            try player.streamS16leAppend(slot.samples, slot.sample_rate);
            const t_play_end = std.Io.Clock.now(.awake, io);
            prev_play_end_ns = t_play_end.nanoseconds;

            played += 1;
            total_samples += slot.samples.len;
            if (slot.arena) |*a| @constCast(a).deinit();
        }
        producer_thread.join();
        const t_end = std.Io.Clock.now(.awake, io);

        const first_audio_ms = if (first_sample_ns > 0)
            @as(f64, @floatFromInt(first_sample_ns - t0.nanoseconds)) / 1_000_000.0
        else
            0.0;
        const total_ms = @as(f64, @floatFromInt(t_end.nanoseconds - t0.nanoseconds)) / 1_000_000.0;

        // Median + max gap.
        var gap_median_ms: f64 = 0;
        var gap_max_ms: f64 = 0;
        if (gaps_ns.items.len > 0) {
            std.mem.sort(u64, gaps_ns.items, {}, std.sort.asc(u64));
            const mid_ns = gaps_ns.items[gaps_ns.items.len / 2];
            gap_median_ms = @as(f64, @floatFromInt(mid_ns)) / 1_000_000.0;
            const max_ns = gaps_ns.items[gaps_ns.items.len - 1];
            gap_max_ms = @as(f64, @floatFromInt(max_ns)) / 1_000_000.0;
        }

        try results.append(arena, .{
            .first_audio_ms = first_audio_ms,
            .total_ms = total_ms,
            .gap_median_ms = gap_median_ms,
            .gap_max_ms = gap_max_ms,
            .synth_total_ms = 0.0, // synth runs on its own thread; not measured per-iter here
        });

        std.debug.print(
            "[ttfa-bench] long iter={d}/{d} chunks={d} first_audio={d:.1}ms total={d:.1}ms gap_med={d:.2}ms gap_max={d:.2}ms samples={d}\n",
            .{ iter + 1, warm, played, first_audio_ms, total_ms, gap_median_ms, gap_max_ms, total_samples },
        );
    }

    // Aggregate.
    var sum_first: f64 = 0;
    var min_first: f64 = std.math.floatMax(f64);
    var max_first: f64 = 0;
    var sum_total: f64 = 0;
    var sum_gap_med: f64 = 0;
    var max_gap: f64 = 0;
    for (results.items) |r| {
        sum_first += r.first_audio_ms;
        if (r.first_audio_ms < min_first) min_first = r.first_audio_ms;
        if (r.first_audio_ms > max_first) max_first = r.first_audio_ms;
        sum_total += r.total_ms;
        sum_gap_med += r.gap_median_ms;
        if (r.gap_max_ms > max_gap) max_gap = r.gap_max_ms;
    }
    const n_f: f64 = @floatFromInt(results.items.len);
    std.debug.print(
        "[ttfa-bench] engine=piper input=long warm={d} init={d:.1}ms first_audio avg={d:.1}ms min={d:.1}ms max={d:.1}ms total_avg={d:.1}ms gap_med_avg={d:.2}ms gap_max={d:.2}ms\n",
        .{
            warm,                          init_ms,
            sum_first / n_f,               min_first,
            max_first,                     sum_total / n_f,
            sum_gap_med / n_f,             max_gap,
        },
    );
}

// v1.7 stream bench. Simulates a token-by-token feed: the input text is
// sliced into ~ASCII-word tokens, each token fed into an
// IncrementalChunker with a 10 ms sleep between tokens (mirrors LLM
// streaming output speed). Captures: time from the FIRST token entering
// the chunker → first audio frame entering zaudio.
//
// "Token" here is a delimiter-bounded slice (split on space). Whitespace
// is preserved by attaching it to the trailing edge of the previous
// token, so the chunker reconstructs the original text. 10 ms is the
// observed inter-token gap from Claude streaming at ~100 tok/s.
//
// Pipeline shape mirrors benchPiperLong: a synth thread drains a chunk
// queue, an audio thread plays. The difference is the synth-feed side:
// instead of pre-computing all chunks, we feed bytes incrementally and
// drain emitted chunks into the synth queue as they appear.
fn benchPiperStream(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    warm: u32,
    text: []const u8,
) !void {
    if (!build_options.enabled) unreachable;
    const piper = @import("piper.zig");
    const preproc = @import("preproc.zig");

    const voice_path = try std.fmt.allocPrint(
        arena,
        "{s}/.cache/agent-tts/voices/pt_BR-faber-medium.onnx",
        .{home},
    );
    const espeak_data = "vendor/piper1-gpl/libpiper/dist/share/espeak-ng-data";

    const t_init0 = std.Io.Clock.now(.awake, io);
    var engine = try piper.PiperEngine.init(arena, voice_path, espeak_data);
    defer engine.deinit();
    const t_init1 = std.Io.Clock.now(.awake, io);
    const init_ms = @as(f64, @floatFromInt(t_init1.nanoseconds - t_init0.nanoseconds)) / 1_000_000.0;

    var player = audio.AudioPlayer.init(arena);
    defer player.deinit();
    if (!player.ready) {
        std.debug.print("[ttfa-bench] zaudio init failed — stream bench requires zaudio; aborting\n", .{});
        return;
    }

    // Tokenise the input on whitespace, attaching the trailing space to
    // each token so the chunker sees the original byte sequence. The last
    // token has no trailing space.
    const tokens = try tokenizeForStream(arena, text);
    std.debug.print("[ttfa-bench] stream-input bytes={d} tokens={d}\n", .{ text.len, tokens.len });
    if (tokens.len == 0) {
        std.debug.print("[ttfa-bench] stream-input produced 0 tokens — nothing to bench\n", .{});
        return;
    }

    const TOKEN_GAP_NS: u64 = 10 * std.time.ns_per_ms;

    var iter: u32 = 0;
    var sum_first: f64 = 0;
    var min_first: f64 = std.math.floatMax(f64);
    var max_first: f64 = 0;
    var sum_total: f64 = 0;
    while (iter < warm) : (iter += 1) {
        var chunker: preproc.IncrementalChunker = .{};
        defer chunker.deinit(arena);

        // Synth queue: simple bounded ring like benchPiperLong.
        const RING_CAP: usize = 4;
        const ChunkSlot = struct {
            arena: ?std.heap.ArenaAllocator = null,
            samples: []const i16 = &.{},
            sample_rate: u32 = 0,
            synth_err: bool = false,
        };
        var slots: [RING_CAP]ChunkSlot = [_]ChunkSlot{.{}} ** RING_CAP;
        var head: std.atomic.Value(usize) = .init(0);
        var tail: std.atomic.Value(usize) = .init(0);
        var closed: std.atomic.Value(bool) = .init(false);
        var pending_chunks: std.atomic.Value(usize) = .init(0);

        const SynthCtx = struct {
            engine: *piper.PiperEngine,
            slots: *[RING_CAP]ChunkSlot,
            head: *std.atomic.Value(usize),
            tail: *std.atomic.Value(usize),
            closed: *std.atomic.Value(bool),
            pending: *std.atomic.Value(usize),
            // Bounded ring of pending chunk texts (gpa-owned).
            queue: *std.ArrayList([]const u8),
            queue_mu: *std.atomic.Value(bool),

            fn pushText(c: @This(), text_dup: []const u8) void {
                while (c.queue_mu.swap(true, .acquire)) {
                    const ts: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
                    _ = std.c.nanosleep(&ts, null);
                }
                c.queue.append(std.heap.smp_allocator, text_dup) catch {};
                _ = c.pending.fetchAdd(1, .release);
                c.queue_mu.store(false, .release);
            }

            fn popText(c: @This()) ?[]const u8 {
                while (c.queue_mu.swap(true, .acquire)) {
                    const ts: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
                    _ = std.c.nanosleep(&ts, null);
                }
                defer c.queue_mu.store(false, .release);
                if (c.queue.items.len == 0) return null;
                const item = c.queue.items[0];
                _ = c.queue.orderedRemove(0);
                _ = c.pending.fetchSub(1, .release);
                return item;
            }

            fn run(c: @This()) void {
                const ts_wait: std.c.timespec = .{ .sec = 0, .nsec = 2 * std.time.ns_per_ms };
                while (true) {
                    const maybe = c.popText();
                    if (maybe) |txt| {
                        // Wait for free ring slot.
                        while (true) {
                            const h = c.head.load(.acquire);
                            const t = c.tail.load(.acquire);
                            if (h - t < RING_CAP) break;
                            _ = std.c.nanosleep(&ts_wait, null);
                        }
                        const gpa = std.heap.smp_allocator;
                        const arena_box = gpa.create(std.heap.ArenaAllocator) catch {
                            gpa.free(txt);
                            continue;
                        };
                        arena_box.* = std.heap.ArenaAllocator.init(gpa);
                        const samples = c.engine.synthToSamples(arena_box.allocator(), txt) catch {
                            arena_box.deinit();
                            gpa.destroy(arena_box);
                            gpa.free(txt);
                            const h2 = c.head.load(.acquire);
                            c.slots[h2 % RING_CAP] = .{ .synth_err = true };
                            c.head.store(h2 + 1, .release);
                            continue;
                        };
                        const rate = c.engine.sampleRate();
                        const h2 = c.head.load(.acquire);
                        c.slots[h2 % RING_CAP] = .{
                            .arena = arena_box.*,
                            .samples = samples,
                            .sample_rate = rate,
                        };
                        c.head.store(h2 + 1, .release);
                        gpa.destroy(arena_box);
                        gpa.free(txt);
                        continue;
                    }
                    if (c.closed.load(.acquire) and c.pending.load(.acquire) == 0) break;
                    _ = std.c.nanosleep(&ts_wait, null);
                }
            }
        };

        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(std.heap.smp_allocator);
        var queue_mu: std.atomic.Value(bool) = .init(false);

        const synth_ctx = SynthCtx{
            .engine = &engine,
            .slots = &slots,
            .head = &head,
            .tail = &tail,
            .closed = &closed,
            .pending = &pending_chunks,
            .queue = &queue,
            .queue_mu = &queue_mu,
        };

        // First-sample latch.
        var first_sample_ns: i128 = 0;
        const FsCtx = struct {
            ns: *i128,
            io: std.Io,
            fn cb(opaque_ctx: ?*anyopaque) void {
                const c: *@This() = @ptrCast(@alignCast(opaque_ctx.?));
                if (c.ns.* != 0) return;
                const now = std.Io.Clock.now(.awake, c.io);
                c.ns.* = now.nanoseconds;
            }
        };
        var fs_ctx = FsCtx{ .ns = &first_sample_ns, .io = io };
        player.on_first_sample = FsCtx.cb;
        player.on_first_sample_ctx = @ptrCast(&fs_ctx);

        // Audio consumer thread: drains the synth ring into zaudio.
        const AudioCtx = struct {
            player: *audio.AudioPlayer,
            slots: *[RING_CAP]ChunkSlot,
            head: *std.atomic.Value(usize),
            tail: *std.atomic.Value(usize),
            closed: *std.atomic.Value(bool),
            pending: *std.atomic.Value(usize),

            fn run(c: @This()) void {
                const ts_pop: std.c.timespec = .{ .sec = 0, .nsec = 2 * std.time.ns_per_ms };
                while (true) {
                    const h = c.head.load(.acquire);
                    const t = c.tail.load(.acquire);
                    if (h <= t) {
                        if (c.closed.load(.acquire) and c.pending.load(.acquire) == 0) return;
                        _ = std.c.nanosleep(&ts_pop, null);
                        continue;
                    }
                    var slot = c.slots[t % RING_CAP];
                    c.tail.store(t + 1, .release);
                    if (slot.synth_err) {
                        if (slot.arena) |*ar| @constCast(ar).deinit();
                        continue;
                    }
                    c.player.streamS16leAppend(slot.samples, slot.sample_rate) catch {};
                    if (slot.arena) |*ar| @constCast(ar).deinit();
                }
            }
        };

        const audio_ctx = AudioCtx{
            .player = &player,
            .slots = &slots,
            .head = &head,
            .tail = &tail,
            .closed = &closed,
            .pending = &pending_chunks,
        };

        const t0 = std.Io.Clock.now(.awake, io);
        const synth_thread = try std.Thread.spawn(.{}, SynthCtx.run, .{synth_ctx});
        const audio_thread = try std.Thread.spawn(.{}, AudioCtx.run, .{audio_ctx});

        // Drive the producer side: feed each token with a 10 ms gap.
        const ts_token: std.c.timespec = .{ .sec = 0, .nsec = @intCast(TOKEN_GAP_NS) };
        for (tokens) |tok| {
            const emitted = chunker.feed(arena, tok) catch &[_]preproc.Chunk{};
            for (emitted) |c| {
                const gpa = std.heap.smp_allocator;
                const dup = gpa.dupe(u8, c.text) catch continue;
                synth_ctx.pushText(dup);
            }
            _ = std.c.nanosleep(&ts_token, null);
        }
        const tail_chunks = chunker.flush(arena) catch &[_]preproc.Chunk{};
        for (tail_chunks) |c| {
            const gpa = std.heap.smp_allocator;
            const dup = gpa.dupe(u8, c.text) catch continue;
            synth_ctx.pushText(dup);
        }

        closed.store(true, .release);
        synth_thread.join();
        audio_thread.join();
        const t_end = std.Io.Clock.now(.awake, io);

        const first_audio_ms = if (first_sample_ns > 0)
            @as(f64, @floatFromInt(first_sample_ns - t0.nanoseconds)) / 1_000_000.0
        else
            0.0;
        const total_ms = @as(f64, @floatFromInt(t_end.nanoseconds - t0.nanoseconds)) / 1_000_000.0;
        sum_first += first_audio_ms;
        if (first_audio_ms < min_first) min_first = first_audio_ms;
        if (first_audio_ms > max_first) max_first = first_audio_ms;
        sum_total += total_ms;

        std.debug.print(
            "[ttfa-bench] stream iter={d}/{d} tokens={d} first_audio={d:.1}ms total={d:.1}ms\n",
            .{ iter + 1, warm, tokens.len, first_audio_ms, total_ms },
        );
    }

    const n_f: f64 = @floatFromInt(warm);
    std.debug.print(
        "[ttfa-bench] engine=piper input=stream warm={d} init={d:.1}ms first_audio avg={d:.1}ms min={d:.1}ms max={d:.1}ms total_avg={d:.1}ms token_gap=10ms\n",
        .{
            warm,            init_ms,
            sum_first / n_f, min_first,
            max_first,       sum_total / n_f,
        },
    );
}

// Slice `text` on whitespace boundaries; each returned token includes its
// trailing whitespace so concatenating all tokens reproduces `text`. This
// matches how an LLM streams: small bursts that almost always end at a
// word boundary.
fn tokenizeForStream(arena: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        // Consume word bytes.
        const start = i;
        while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '\n') : (i += 1) {}
        // Consume one whitespace run (so the token carries its trailing ws).
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n')) : (i += 1) {}
        if (i > start) try out.append(arena, text[start..i]);
    }
    return out.toOwnedSlice(arena);
}
