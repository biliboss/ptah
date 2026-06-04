// SPDX-License-Identifier: MIT OR Apache-2.0
// Client: connect to running daemon, dispatch one of:
//   enqueue (default)     — `agent-tts "texto"`
//   queue                 — `agent-tts queue` lists pending+playing items
//   skip                  — `agent-tts skip` kills current playing item
//   clear                 — `agent-tts clear` drops all pending items
//
// v0.3 does NOT auto-start the daemon — if connect fails, user is told to
// start it manually with `agent-tts daemon`. Auto-start lands in v0.4.

const std = @import("std");
const ipc = @import("ipc.zig");

pub const DEFAULT_VOICE = "Luciana";
pub const DEFAULT_RATE: u32 = 330;
const READ_BUF = 64 * 1024;
const WRITE_BUF = 16 * 1024;

/// Single ITEM row returned by `queueLines`. Slices live in caller arena.
pub const QueueItem = struct {
    id: []const u8,
    state: []const u8,
    engine: []const u8,
    voice: []const u8,
    rate: []const u8,
    text: []const u8,
};

const HELP =
    \\agent-tts — multilingual TTS via macOS `say` or libpiper (v1.1+)
    \\
    \\Usage:
    \\  agent-tts "texto"                enqueue text on the running daemon
    \\  agent-tts queue                  list pending + playing items
    \\  agent-tts skip                   skip the current playing item
    \\  agent-tts clear                  drop all pending items
    \\  agent-tts pause                  pause active playback (v1.10.2)
    \\  agent-tts resume                 resume paused playback (v1.10.2)
    \\  agent-tts replay <id>            re-enqueue a past item (v1.10.2)
    \\  agent-tts history [--limit N]    list last N items, any state (v1.10.2)
    \\  agent-tts daemon                 run daemon (foreground)
    \\
    \\Options (for enqueue):
    \\  --engine say|piper  TTS backend (default: piper; say = fallback)
    \\  --lang auto|pt|en   language routing (default: auto; piper-only)
    \\  --voice NAME        voice name (default: Luciana for say, faber for piper)
    \\  --rate WPM          words per minute (default: 330; ignored by piper)
    \\  --ssml              treat text as W3C SSML 1.1 subset (v1.8+;
    \\                      <emphasis> <break> <prosody> <say-as>)
    \\  --length-scale F    Piper length_scale (v1.10.7+; 0.5..2.0; 0=unset).
    \\                      <1 = faster; >1 = slower.
    \\  --noise-scale F     Piper noise_scale (v1.10.7+; 0..2; <0=unset).
    \\                      Higher = more prosody variation.
    \\  --noise-w F         Piper noise_w (v1.10.7+; 0..2; <0=unset).
    \\                      Higher = more pronunciation variation.
    \\  --tech              v1.10.8+: tech-report mode (acronym + unit glossary).
    \\  --comma-pause MS    v1.10.8+: override `[[slnc N]]` after `,` (default 150).
    \\  --sentence-pause MS v1.10.8+: override `[[slnc N]]` after .!? (default 400).
    \\  --newline-pause MS  v1.10.8+: override `[[slnc N]]` after `\n` (default 600).
    \\  --speaker-id N      v1.10.8+: Piper multi-speaker index (-1 = voice default).
    \\  --profile tech      v1.10.9: research-anchored Faber tech-narration —
    \\                                --tech + length_scale=1.05 + noise_scale=0.35
    \\                                + noise_w=0.45 + sentence_pause_ms=500.
    \\                                Lower noise = stable but flatter; A/B
    \\                                via voice_knob_search if you prefer
    \\                                expressiveness.
    \\  -h, --help          this help
    \\  -V, --version       print version
    \\
;

pub fn run(arena: std.mem.Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    // Subcommand dispatch (only when not paired with a flag — `queue`,
    // `skip`, `clear`, `pause`, `resume`, `history` take no/few args).
    if (args.len >= 2) {
        const sub = args[1];
        if (std.mem.eql(u8, sub, "queue")) return cmdQueue(arena, io, home);
        if (std.mem.eql(u8, sub, "skip")) return cmdSkip(arena, io, home);
        if (std.mem.eql(u8, sub, "clear")) return cmdClear(arena, io, home);
        // v1.10.2 — player ops.
        if (std.mem.eql(u8, sub, "pause")) return cmdPause(arena, io, home);
        if (std.mem.eql(u8, sub, "resume")) return cmdResume(arena, io, home);
        if (std.mem.eql(u8, sub, "replay")) return cmdReplay(arena, io, home, args);
        if (std.mem.eql(u8, sub, "history")) return cmdHistory(arena, io, home, args);
    }
    return cmdEnqueue(arena, io, home, args);
}

fn cmdEnqueue(arena: std.mem.Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    var engine: ipc.Engine = .piper;
    var engine_explicit = false;
    var lang: ipc.Lang = .auto;
    var voice_arg: ?[]const u8 = null;
    var rate: u32 = DEFAULT_RATE;
    var ssml_flag: bool = false;
    // v1.10.7 — per-call piper knobs. Sentinels match ipc.Message.
    var length_scale: f32 = 0.0;
    var noise_scale: f32 = -1.0;
    var noise_w: f32 = -1.0;
    // v1.10.8 — tech mode + pause overrides + speaker selector.
    var tech_flag: bool = false;
    var comma_pause_ms: u32 = 0;
    var sentence_pause_ms: u32 = 0;
    var newline_pause_ms: u32 = 0;
    var speaker_id: i32 = -1;
    var text: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--engine")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --engine needs value (say|piper)\n", .{});
                std.process.exit(2);
            }
            engine = ipc.Engine.fromStr(args[i]) orelse {
                std.debug.print("error: --engine invalid (got '{s}') — expected say|piper|cloned\n", .{args[i]});
                std.process.exit(2);
            };
            engine_explicit = true;
        } else if (std.mem.eql(u8, a, "--lang")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --lang needs value (auto|pt|en)\n", .{});
                std.process.exit(2);
            }
            lang = ipc.Lang.fromStr(args[i]) orelse {
                std.debug.print("error: --lang invalid (got '{s}') — expected auto|pt|en\n", .{args[i]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--voice")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --voice needs value\n", .{});
                std.process.exit(2);
            }
            voice_arg = args[i];
        } else if (std.mem.eql(u8, a, "--rate")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --rate needs value\n", .{});
                std.process.exit(2);
            }
            rate = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("error: --rate invalid (got '{s}')\n", .{args[i]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--ssml")) {
            // v1.8 — boolean toggle. Daemon parses W3C SSML subset.
            // Skip sanitisation of `<`/`>` so markup survives.
            ssml_flag = true;
        } else if (std.mem.eql(u8, a, "--length-scale")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --length-scale needs value\n", .{});
                std.process.exit(2);
            }
            length_scale = std.fmt.parseFloat(f32, args[i]) catch {
                std.debug.print("error: --length-scale invalid (got '{s}')\n", .{args[i]});
                std.process.exit(2);
            };
            if (length_scale < 0.1 or length_scale > 3.0) {
                std.debug.print("error: --length-scale out of range (0.1..3.0)\n", .{});
                std.process.exit(2);
            }
        } else if (std.mem.eql(u8, a, "--noise-scale")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --noise-scale needs value\n", .{});
                std.process.exit(2);
            }
            noise_scale = std.fmt.parseFloat(f32, args[i]) catch {
                std.debug.print("error: --noise-scale invalid (got '{s}')\n", .{args[i]});
                std.process.exit(2);
            };
            if (noise_scale < 0 or noise_scale > 2.0) {
                std.debug.print("error: --noise-scale out of range (0..2)\n", .{});
                std.process.exit(2);
            }
        } else if (std.mem.eql(u8, a, "--noise-w")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --noise-w needs value\n", .{});
                std.process.exit(2);
            }
            noise_w = std.fmt.parseFloat(f32, args[i]) catch {
                std.debug.print("error: --noise-w invalid (got '{s}')\n", .{args[i]});
                std.process.exit(2);
            };
            if (noise_w < 0 or noise_w > 2.0) {
                std.debug.print("error: --noise-w out of range (0..2)\n", .{});
                std.process.exit(2);
            }
        } else if (std.mem.eql(u8, a, "--tech")) {
            tech_flag = true;
        } else if (std.mem.eql(u8, a, "--comma-pause")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --comma-pause needs value (ms)\n", .{});
                std.process.exit(2);
            }
            comma_pause_ms = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("error: --comma-pause invalid (got '{s}')\n", .{args[i]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--sentence-pause")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --sentence-pause needs value (ms)\n", .{});
                std.process.exit(2);
            }
            sentence_pause_ms = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("error: --sentence-pause invalid (got '{s}')\n", .{args[i]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--newline-pause")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --newline-pause needs value (ms)\n", .{});
                std.process.exit(2);
            }
            newline_pause_ms = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("error: --newline-pause invalid (got '{s}')\n", .{args[i]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--speaker-id")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --speaker-id needs value\n", .{});
                std.process.exit(2);
            }
            speaker_id = std.fmt.parseInt(i32, args[i], 10) catch {
                std.debug.print("error: --speaker-id invalid (got '{s}')\n", .{args[i]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--profile")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --profile needs value (tech)\n", .{});
                std.process.exit(2);
            }
            const profile = args[i];
            if (std.mem.eql(u8, profile, "tech")) {
                // v1.10.9 — research-anchored Faber tech-narration defaults
                // sourced from `_qa/v1.10.9-research-prompt-output.md`:
                // intelligibility-first on MCV-trained read-speech. Lower
                // noise = stable but flatter prosody; the counter-argument
                // is documented next to the help text. For more expressive
                // output use `voice_knob_search` or `tech_profile_search`.
                tech_flag = true;
                if (length_scale == 0.0) length_scale = 1.05;
                if (noise_scale < 0) noise_scale = 0.35;
                if (noise_w < 0) noise_w = 0.45;
                if (sentence_pause_ms == 0) sentence_pause_ms = 500;
            } else {
                std.debug.print("error: --profile unknown (got '{s}'; expected: tech)\n", .{profile});
                std.process.exit(2);
            }
        } else {
            text = a;
        }
    }

    if (text == null) {
        std.debug.print(HELP, .{});
        std.process.exit(2);
    }

    // Engine-specific voice defaults. For piper we pick Pt vs En default
    // model name based on `--lang`. When `--lang auto`, the daemon may
    // override per-chunk; the value here is just the catch-all voice the
    // daemon falls back to for the default lang.
    const voice: []const u8 = voice_arg orelse switch (engine) {
        .say => DEFAULT_VOICE,
        .piper => switch (lang) {
            .auto, .pt => "faber",
            .en => "amy",
        },
        // No default slug for cloned — daemon routes by directory match.
        // Without a voice flag, user gets a hard error from the daemon's
        // missing-embedding fallback rather than a silent misroute.
        .cloned => "",
    };

    // Implicit routing: if user passed `--voice <slug>` without an explicit
    // `--engine`, peek the slug to decide. faber → piper, Luciana/known say
    // voices keep the current default, anything else with a matching dir
    // under ~/.cache/agent-tts/voices/<slug>/ routes to cloned.
    if (!engine_explicit and voice_arg != null) {
        engine = resolveEngineFromVoice(arena, io, home, voice_arg.?);
    }

    const clean = try ipc.sanitizeText(arena, text.?);
    const msg = ipc.Message{
        .engine = engine,
        .lang = lang,
        .voice = voice,
        .rate = rate,
        .ssml = ssml_flag,
        .length_scale = length_scale,
        .noise_scale = noise_scale,
        .noise_w = noise_w,
        .tech = tech_flag,
        .comma_pause_ms = comma_pause_ms,
        .sentence_pause_ms = sentence_pause_ms,
        .newline_pause_ms = newline_pause_ms,
        .speaker_id = speaker_id,
        .text = clean,
    };

    var stream = try openSocket(arena, io, home);
    defer stream.close(io);

    var read_buf: [READ_BUF]u8 = undefined;
    var write_buf: [WRITE_BUF]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    const t_start = std.Io.Clock.now(.awake, io);
    // v1.10.7 — single funnel through ipc.encodeEnqueue so the 8-field
    // wire format with optional tune triplet stays in one place. Daemon
    // handles older 4/5/6/7-field forms for ABI compatibility.
    const wire = try ipc.encodeEnqueue(arena, msg);
    try sw.interface.writeAll(wire);
    try sw.interface.flush();

    const line = try sr.interface.takeDelimiterExclusive('\n');
    const t_end = std.Io.Clock.now(.awake, io);
    const rt_ms = @as(f64, @floatFromInt(t_end.nanoseconds - t_start.nanoseconds)) / 1_000_000.0;

    if (std.mem.startsWith(u8, line, "OK\t")) {
        std.debug.print("[agent-tts] enqueued id={s} round-trip={d:.1}ms\n", .{ line[3..], rt_ms });
    } else if (std.mem.startsWith(u8, line, "ERR\t")) {
        std.debug.print("[agent-tts] daemon error: {s}\n", .{line[4..]});
        std.process.exit(1);
    } else {
        std.debug.print("[agent-tts] unexpected response: {s}\n", .{line});
        std.process.exit(1);
    }
}

fn cmdQueue(arena: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    var stream = try openSocket(arena, io, home);
    defer stream.close(io);

    var read_buf: [READ_BUF]u8 = undefined;
    var write_buf: [128]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    const t_start = std.Io.Clock.now(.awake, io);
    try sw.interface.writeAll("QUEUE\n");
    try sw.interface.flush();

    // Use streaming mode for stdout: positional writes (default) silently
    // fail on pipes/ttys after the first call, swallowing subsequent output.
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    var w = &stdout.interface;

    var n_items: u32 = 0;
    while (true) {
        // takeDelimiterInclusive returns a slice including the trailing '\n';
        // strip it before matching. takeDelimiterExclusive leaves the '\n'
        // in the buffer (per std docs) — fine for a single-line read, but in
        // a loop it produces empty reads forever.
        const raw = try sr.interface.takeDelimiterInclusive('\n');
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
        if (std.mem.eql(u8, line, "END")) break;
        if (std.mem.startsWith(u8, line, "ERR\t")) {
            std.debug.print("[agent-tts] daemon error: {s}\n", .{line[4..]});
            std.process.exit(1);
        }
        if (std.mem.startsWith(u8, line, "ITEM\t")) {
            const rest = line[5..];
            // v0.7 ITEM\t<id>\t<state>\t<engine>\t<voice>\t<rate>\t<text>
            var it = std.mem.splitScalar(u8, rest, '\t');
            const id = it.next() orelse continue;
            const state = it.next() orelse continue;
            const engine_or_voice = it.next() orelse continue;
            const next_field = it.next() orelse continue;
            // Disambiguate v0.6 (voice here) vs v0.7 (engine here). Same
            // trick as ipc.parseRequest.
            var engine: []const u8 = "say";
            var voice: []const u8 = engine_or_voice;
            var rate: []const u8 = next_field;
            if (std.mem.eql(u8, engine_or_voice, "say") or std.mem.eql(u8, engine_or_voice, "piper")) {
                engine = engine_or_voice;
                voice = next_field;
                rate = it.next() orelse continue;
            }
            const text = it.rest();
            if (n_items == 0) {
                try w.writeAll("  id  state    engine  voice                  rate  text\n");
            }
            try w.print("  {s:>4}  {s:<8} {s:<6}  {s:<22} {s:>4}  {s}\n", .{ id, state, engine, voice, rate, text });
            n_items += 1;
        }
    }

    const t_end = std.Io.Clock.now(.awake, io);
    const rt_ms = @as(f64, @floatFromInt(t_end.nanoseconds - t_start.nanoseconds)) / 1_000_000.0;

    if (n_items == 0) {
        try w.print("(empty) round-trip={d:.1}ms\n", .{rt_ms});
    } else {
        try w.print("{d} item(s) round-trip={d:.1}ms\n", .{ n_items, rt_ms });
    }
    try w.flush();
}

fn cmdSkip(arena: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    const line = try simpleOp(arena, io, home, "SKIP\n");
    if (std.mem.startsWith(u8, line, "OK\t")) {
        const id_str = line[3..];
        const id = std.fmt.parseInt(u64, id_str, 10) catch 0;
        if (id == 0) {
            std.debug.print("[agent-tts] nothing playing\n", .{});
        } else {
            std.debug.print("[agent-tts] skipped id={d}\n", .{id});
        }
    } else {
        std.debug.print("[agent-tts] unexpected: {s}\n", .{line});
        std.process.exit(1);
    }
}

fn cmdClear(arena: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    const line = try simpleOp(arena, io, home, "CLEAR\n");
    if (std.mem.startsWith(u8, line, "OK\t")) {
        std.debug.print("[agent-tts] cleared {s} pending\n", .{line[3..]});
    } else {
        std.debug.print("[agent-tts] unexpected: {s}\n", .{line});
        std.process.exit(1);
    }
}

// v1.10.2 — pause/resume CLI ops. Both ack `OK\t<id>` of the active item
// or print the daemon's ERR reason verbatim ("nothing playing" / "not
// paused" / "item not found").
fn cmdPause(arena: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    const line = try simpleOp(arena, io, home, "PAUSE\n");
    if (std.mem.startsWith(u8, line, "OK\t")) {
        std.debug.print("[agent-tts] paused id={s}\n", .{line[3..]});
    } else if (std.mem.startsWith(u8, line, "ERR\t")) {
        std.debug.print("[agent-tts] {s}\n", .{line[4..]});
        std.process.exit(1);
    } else {
        std.debug.print("[agent-tts] unexpected: {s}\n", .{line});
        std.process.exit(1);
    }
}

fn cmdResume(arena: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    const line = try simpleOp(arena, io, home, "RESUME\n");
    if (std.mem.startsWith(u8, line, "OK\t")) {
        std.debug.print("[agent-tts] resumed id={s}\n", .{line[3..]});
    } else if (std.mem.startsWith(u8, line, "ERR\t")) {
        std.debug.print("[agent-tts] {s}\n", .{line[4..]});
        std.process.exit(1);
    } else {
        std.debug.print("[agent-tts] unexpected: {s}\n", .{line});
        std.process.exit(1);
    }
}

fn cmdReplay(arena: std.mem.Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    if (args.len < 3) {
        std.debug.print("usage: agent-tts replay <id>\n", .{});
        std.process.exit(2);
    }
    const id = std.fmt.parseInt(u64, args[2], 10) catch {
        std.debug.print("error: replay id must be an integer (got '{s}')\n", .{args[2]});
        std.process.exit(2);
    };
    const cmd = try std.fmt.allocPrint(arena, "REPLAY\t{d}\n", .{id});
    const line = try simpleOp(arena, io, home, cmd);
    if (std.mem.startsWith(u8, line, "OK\t")) {
        std.debug.print("[agent-tts] replayed id={d} as new id={s}\n", .{ id, line[3..] });
    } else if (std.mem.startsWith(u8, line, "ERR\t")) {
        std.debug.print("[agent-tts] {s}\n", .{line[4..]});
        std.process.exit(1);
    } else {
        std.debug.print("[agent-tts] unexpected: {s}\n", .{line});
        std.process.exit(1);
    }
}

// v1.10.2 — history listing. Default limit 20, max 100 (daemon clamps).
// Wire shape is ITEM\t<id>\t<state>\t<engine>\t<voice>\t<rate>\t<finished_at>\t<text>.
fn cmdHistory(arena: std.mem.Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    var limit: u32 = 20;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--limit")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --limit needs value\n", .{});
                std.process.exit(2);
            }
            limit = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("error: --limit invalid (got '{s}')\n", .{args[i]});
                std.process.exit(2);
            };
        }
    }
    var stream = try openSocket(arena, io, home);
    defer stream.close(io);

    var read_buf: [READ_BUF]u8 = undefined;
    var write_buf: [128]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    try sw.interface.print("HISTORY\t{d}\n", .{limit});
    try sw.interface.flush();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    var w = &stdout.interface;

    var n_items: u32 = 0;
    while (true) {
        const raw = try sr.interface.takeDelimiterInclusive('\n');
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
        if (std.mem.eql(u8, line, "END")) break;
        if (std.mem.startsWith(u8, line, "ERR\t")) {
            std.debug.print("[agent-tts] daemon error: {s}\n", .{line[4..]});
            std.process.exit(1);
        }
        if (!std.mem.startsWith(u8, line, "ITEM\t")) continue;
        const rest = line[5..];
        var it = std.mem.splitScalar(u8, rest, '\t');
        const id = it.next() orelse continue;
        const state = it.next() orelse continue;
        const engine = it.next() orelse continue;
        const voice = it.next() orelse continue;
        const rate = it.next() orelse continue;
        const finished = it.next() orelse continue;
        const text = it.rest();
        if (n_items == 0) {
            try w.writeAll("  id  state    engine  voice                  rate  finished     text\n");
        }
        try w.print("  {s:>4}  {s:<8} {s:<6}  {s:<22} {s:>4}  {s:>10}  {s}\n", .{
            id, state, engine, voice, rate, finished, text,
        });
        n_items += 1;
    }
    if (n_items == 0) {
        try w.writeAll("(no history yet)\n");
    } else {
        try w.print("{d} item(s)\n", .{n_items});
    }
    try w.flush();
}

fn simpleOp(arena: std.mem.Allocator, io: std.Io, home: []const u8, cmd: []const u8) ![]u8 {
    var stream = try openSocket(arena, io, home);
    defer stream.close(io);

    var read_buf: [READ_BUF]u8 = undefined;
    var write_buf: [64]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    try sw.interface.writeAll(cmd);
    try sw.interface.flush();

    const line = try sr.interface.takeDelimiterExclusive('\n');
    if (std.mem.startsWith(u8, line, "ERR\t")) {
        std.debug.print("[agent-tts] daemon error: {s}\n", .{line[4..]});
        std.process.exit(1);
    }
    return try arena.dupe(u8, line);
}

// v1.4 — when `--voice <slug>` is given without `--engine`, decide which engine
// the daemon should route to:
//   - "faber"                             → piper (the bundled neural voice)
//   - <slug> with metadata.json on disk   → cloned (XTTS-v2 sidecar)
//   - everything else                     → say (existing macOS path)
// Daemon revalidates on its side, so a missed lookup here just falls back
// rather than crashing.
fn resolveEngineFromVoice(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    voice: []const u8,
) ipc.Engine {
    if (std.mem.eql(u8, voice, "faber")) return .piper;
    const meta_path = std.fmt.allocPrint(
        arena,
        "{s}/.cache/agent-tts/voices/{s}/metadata.json",
        .{ home, voice },
    ) catch return .say;
    var f = std.Io.Dir.cwd().openFile(io, meta_path, .{}) catch return .say;
    f.close(io);
    return .cloned;
}

fn openSocket(arena: std.mem.Allocator, io: std.Io, home: []const u8) !std.Io.net.Stream {
    const sock_path = try ipc.socketPath(arena, io, home);
    var addr = try std.Io.net.UnixAddress.init(sock_path);
    const stream = addr.connect(io) catch |e| {
        std.debug.print(
            "error: cannot reach daemon at {s} ({s}).\nstart with: agent-tts daemon\n",
            .{ sock_path, @errorName(e) },
        );
        std.process.exit(1);
    };
    return stream;
}

// ---- v1.5: helpers reused by mcp.zig ----------------------------------
//
// The MCP server in `mcp.zig` is a thin shim over the same UNIX socket the
// CLI uses. These helpers expose ENQUEUE/QUEUE/SKIP/CLEAR as pure functions
// returning data — no stdout writes, no process.exit. The CLI commands above
// stay verbose because they are user-facing; these are for tool callers.

pub const ClientError = error{
    DaemonUnreachable,
    DaemonError,
    UnexpectedResponse,
};

fn openSocketSilent(arena: std.mem.Allocator, io: std.Io, home: []const u8) !std.Io.net.Stream {
    const sock_path = try ipc.socketPath(arena, io, home);
    var addr = try std.Io.net.UnixAddress.init(sock_path);
    return addr.connect(io) catch return error.DaemonUnreachable;
}

/// Enqueue a TTS item on the running daemon and return its id as a string.
/// Slice is owned by `arena`. Sanitizes `text` (tabs/newlines → spaces).
pub fn enqueueLine(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    engine: ipc.Engine,
    voice: []const u8,
    rate: u32,
    text: []const u8,
) ![]u8 {
    return enqueueLineSsml(arena, io, home, engine, voice, rate, text, false);
}

/// v1.8 — enqueue with the SSML flag. Same wire as the CLI's 7-field
/// ENQUEUE; daemon parses SSML when `ssml_flag` is true and routes
/// per-engine. MCP `say` tool uses this when its `ssml` argument is set.
pub fn enqueueLineSsml(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    engine: ipc.Engine,
    voice: []const u8,
    rate: u32,
    text: []const u8,
    ssml_flag: bool,
) ![]u8 {
    return enqueueLineTuned(arena, io, home, engine, voice, rate, text, ssml_flag, 0.0, -1.0, -1.0);
}

/// v1.10.7 — enqueue with all per-call piper inference knobs. Pass the
/// sentinels (`length_scale=0`, `noise_scale=-1`, `noise_w=-1`) when the
/// caller doesn't want to override. MCP `say` tool exposes the three
/// optional numeric arguments and funnels through this entry point.
pub fn enqueueLineTuned(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    engine: ipc.Engine,
    voice: []const u8,
    rate: u32,
    text: []const u8,
    ssml_flag: bool,
    length_scale: f32,
    noise_scale: f32,
    noise_w: f32,
) ![]u8 {
    return enqueueLineFull(arena, io, home, engine, voice, rate, text, ssml_flag, length_scale, noise_scale, noise_w, false, 0, 0, 0, -1);
}

/// v1.10.8 — enqueue with every per-call knob exposed: SSML flag, all
/// three Piper inference knobs, tech-report mode, per-call pause
/// overrides, AND multi-speaker selector. All sentinels work — pass
/// `false` / `0` / `-1` to keep the daemon's defaults.
pub fn enqueueLineFull(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    engine: ipc.Engine,
    voice: []const u8,
    rate: u32,
    text: []const u8,
    ssml_flag: bool,
    length_scale: f32,
    noise_scale: f32,
    noise_w: f32,
    tech: bool,
    comma_pause_ms: u32,
    sentence_pause_ms: u32,
    newline_pause_ms: u32,
    speaker_id: i32,
) ![]u8 {
    const clean = try ipc.sanitizeText(arena, text);
    const msg = ipc.Message{
        .engine = engine,
        .voice = voice,
        .rate = rate,
        .ssml = ssml_flag,
        .length_scale = length_scale,
        .noise_scale = noise_scale,
        .noise_w = noise_w,
        .tech = tech,
        .comma_pause_ms = comma_pause_ms,
        .sentence_pause_ms = sentence_pause_ms,
        .newline_pause_ms = newline_pause_ms,
        .speaker_id = speaker_id,
        .text = clean,
    };

    var stream = try openSocketSilent(arena, io, home);
    defer stream.close(io);

    var read_buf: [READ_BUF]u8 = undefined;
    var write_buf: [WRITE_BUF]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    const wire = try ipc.encodeEnqueue(arena, msg);
    try sw.interface.writeAll(wire);
    try sw.interface.flush();

    const line = try sr.interface.takeDelimiterExclusive('\n');
    if (std.mem.startsWith(u8, line, "OK\t")) return try arena.dupe(u8, line[3..]);
    if (std.mem.startsWith(u8, line, "ERR\t")) return error.DaemonError;
    return error.UnexpectedResponse;
}

/// Returns all items currently in the queue (pending + playing). Slices live
/// in `arena`. Empty list when the queue is empty.
pub fn queueLines(arena: std.mem.Allocator, io: std.Io, home: []const u8) ![]QueueItem {
    var stream = try openSocketSilent(arena, io, home);
    defer stream.close(io);

    var read_buf: [READ_BUF]u8 = undefined;
    var write_buf: [128]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    try sw.interface.writeAll("QUEUE\n");
    try sw.interface.flush();

    var list: std.ArrayList(QueueItem) = .empty;
    while (true) {
        const raw = try sr.interface.takeDelimiterInclusive('\n');
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
        if (std.mem.eql(u8, line, "END")) break;
        if (std.mem.startsWith(u8, line, "ERR\t")) return error.DaemonError;
        if (!std.mem.startsWith(u8, line, "ITEM\t")) continue;

        const rest = line[5..];
        var it = std.mem.splitScalar(u8, rest, '\t');
        const id = it.next() orelse continue;
        const state = it.next() orelse continue;
        const engine_or_voice = it.next() orelse continue;
        const next_field = it.next() orelse continue;
        var engine: []const u8 = "say";
        var voice: []const u8 = engine_or_voice;
        var rate_s: []const u8 = next_field;
        if (std.mem.eql(u8, engine_or_voice, "say") or std.mem.eql(u8, engine_or_voice, "piper")) {
            engine = engine_or_voice;
            voice = next_field;
            rate_s = it.next() orelse continue;
        }
        const text = it.rest();
        try list.append(arena, .{
            .id = try arena.dupe(u8, id),
            .state = try arena.dupe(u8, state),
            .engine = try arena.dupe(u8, engine),
            .voice = try arena.dupe(u8, voice),
            .rate = try arena.dupe(u8, rate_s),
            .text = try arena.dupe(u8, text),
        });
    }
    return list.toOwnedSlice(arena);
}

/// Returns the id of the skipped item (0 = nothing was playing).
pub fn skipOp(arena: std.mem.Allocator, io: std.Io, home: []const u8) !u64 {
    const line = try simpleOpSilent(arena, io, home, "SKIP\n");
    if (!std.mem.startsWith(u8, line, "OK\t")) return error.UnexpectedResponse;
    return std.fmt.parseInt(u64, line[3..], 10) catch return error.UnexpectedResponse;
}

/// Returns the number of items dropped from the pending queue.
pub fn clearOp(arena: std.mem.Allocator, io: std.Io, home: []const u8) !u64 {
    const line = try simpleOpSilent(arena, io, home, "CLEAR\n");
    if (!std.mem.startsWith(u8, line, "OK\t")) return error.UnexpectedResponse;
    return std.fmt.parseInt(u64, line[3..], 10) catch return error.UnexpectedResponse;
}

/// v1.10.2 — pause the active item. Returns the paused id, or 0 when
/// the daemon reports "nothing playing". Other ERRs surface as
/// DaemonError. Used by mcp.zig and the menubar FloatingPlayer.
pub fn pauseOp(arena: std.mem.Allocator, io: std.Io, home: []const u8) !u64 {
    const line = try simpleOpSilent(arena, io, home, "PAUSE\n");
    if (std.mem.startsWith(u8, line, "OK\t")) {
        return std.fmt.parseInt(u64, line[3..], 10) catch return error.UnexpectedResponse;
    }
    if (std.mem.startsWith(u8, line, "ERR\t")) {
        // "nothing playing" → return 0 so callers can render a friendly
        // empty-state without an error path. Anything else is a real error.
        if (std.mem.indexOf(u8, line, "nothing playing") != null) return 0;
        return error.DaemonError;
    }
    return error.UnexpectedResponse;
}

/// v1.10.2 — resume the paused item. Same shape as pauseOp.
pub fn resumeOp(arena: std.mem.Allocator, io: std.Io, home: []const u8) !u64 {
    const line = try simpleOpSilent(arena, io, home, "RESUME\n");
    if (std.mem.startsWith(u8, line, "OK\t")) {
        return std.fmt.parseInt(u64, line[3..], 10) catch return error.UnexpectedResponse;
    }
    if (std.mem.startsWith(u8, line, "ERR\t")) {
        if (std.mem.indexOf(u8, line, "not paused") != null) return 0;
        return error.DaemonError;
    }
    return error.UnexpectedResponse;
}

/// v1.10.2 — replay an item by id. Returns the new pending id, or 0 when
/// the daemon reports "item not found".
pub fn replayOp(arena: std.mem.Allocator, io: std.Io, home: []const u8, src_id: u64) !u64 {
    const cmd = try std.fmt.allocPrint(arena, "REPLAY\t{d}\n", .{src_id});
    const line = try simpleOpSilent(arena, io, home, cmd);
    if (std.mem.startsWith(u8, line, "OK\t")) {
        return std.fmt.parseInt(u64, line[3..], 10) catch return error.UnexpectedResponse;
    }
    if (std.mem.startsWith(u8, line, "ERR\t")) {
        if (std.mem.indexOf(u8, line, "item not found") != null) return 0;
        return error.DaemonError;
    }
    return error.UnexpectedResponse;
}

/// v1.10.2 — single history row returned by `historyLines`. Mirrors
/// `client.zig`'s `QueueItem` shape but with the extra finished_at field.
pub const HistoryItem = struct {
    id: []const u8,
    state: []const u8,
    engine: []const u8,
    voice: []const u8,
    rate: []const u8,
    finished_at: []const u8,
    text: []const u8,
};

/// v1.10.2 — fetch the last `limit` items via HISTORY. limit clamped to
/// 100 by the daemon. Slices owned by `arena`.
pub fn historyLines(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    limit: u32,
) ![]HistoryItem {
    var stream = try openSocketSilent(arena, io, home);
    defer stream.close(io);

    var read_buf: [READ_BUF]u8 = undefined;
    var write_buf: [128]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    try sw.interface.print("HISTORY\t{d}\n", .{limit});
    try sw.interface.flush();

    var list: std.ArrayList(HistoryItem) = .empty;
    while (true) {
        const raw = try sr.interface.takeDelimiterInclusive('\n');
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
        if (std.mem.eql(u8, line, "END")) break;
        if (std.mem.startsWith(u8, line, "ERR\t")) return error.DaemonError;
        if (!std.mem.startsWith(u8, line, "ITEM\t")) continue;

        const rest = line[5..];
        var it = std.mem.splitScalar(u8, rest, '\t');
        const id = it.next() orelse continue;
        const state = it.next() orelse continue;
        const engine = it.next() orelse continue;
        const voice = it.next() orelse continue;
        const rate = it.next() orelse continue;
        const finished = it.next() orelse continue;
        const text = it.rest();
        try list.append(arena, .{
            .id = try arena.dupe(u8, id),
            .state = try arena.dupe(u8, state),
            .engine = try arena.dupe(u8, engine),
            .voice = try arena.dupe(u8, voice),
            .rate = try arena.dupe(u8, rate),
            .finished_at = try arena.dupe(u8, finished),
            .text = try arena.dupe(u8, text),
        });
    }
    return list.toOwnedSlice(arena);
}

fn simpleOpSilent(arena: std.mem.Allocator, io: std.Io, home: []const u8, cmd: []const u8) ![]u8 {
    var stream = try openSocketSilent(arena, io, home);
    defer stream.close(io);

    var read_buf: [READ_BUF]u8 = undefined;
    var write_buf: [64]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    try sw.interface.writeAll(cmd);
    try sw.interface.flush();

    const line = try sr.interface.takeDelimiterExclusive('\n');
    if (std.mem.startsWith(u8, line, "ERR\t")) return error.DaemonError;
    return try arena.dupe(u8, line);
}

// ---- tests ------------------------------------------------------------

test "QueueItem struct holds the 6 fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const it: QueueItem = .{
        .id = try a.dupe(u8, "42"),
        .state = try a.dupe(u8, "pending"),
        .engine = try a.dupe(u8, "piper"),
        .voice = try a.dupe(u8, "faber"),
        .rate = try a.dupe(u8, "330"),
        .text = try a.dupe(u8, "olá"),
    };
    try std.testing.expectEqualStrings("42", it.id);
    try std.testing.expectEqualStrings("piper", it.engine);
}
