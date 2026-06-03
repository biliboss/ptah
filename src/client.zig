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

const DEFAULT_VOICE = "Luciana";
const DEFAULT_RATE: u32 = 330;
const READ_BUF = 64 * 1024;
const WRITE_BUF = 16 * 1024;

const HELP =
    \\agent-tts — Pt-BR TTS via macOS `say` or libpiper (v0.7+)
    \\
    \\Usage:
    \\  agent-tts "texto"                enqueue text on the running daemon
    \\  agent-tts queue                  list pending + playing items
    \\  agent-tts skip                   skip the current playing item
    \\  agent-tts clear                  drop all pending items
    \\  agent-tts daemon                 run daemon (foreground)
    \\
    \\Options (for enqueue):
    \\  --engine say|piper  TTS backend (default: piper; say = fallback)
    \\  --voice NAME        voice name (default: Luciana for say, faber for piper)
    \\  --rate WPM          words per minute (default: 330; ignored by piper)
    \\  -h, --help          this help
    \\  -V, --version       print version
    \\
;

pub fn run(arena: std.mem.Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    // Subcommand dispatch (only when not paired with a flag — `queue`,
    // `skip`, `clear` take no args).
    if (args.len >= 2) {
        const sub = args[1];
        if (std.mem.eql(u8, sub, "queue")) return cmdQueue(arena, io, home);
        if (std.mem.eql(u8, sub, "skip")) return cmdSkip(arena, io, home);
        if (std.mem.eql(u8, sub, "clear")) return cmdClear(arena, io, home);
    }
    return cmdEnqueue(arena, io, home, args);
}

fn cmdEnqueue(arena: std.mem.Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    var engine: ipc.Engine = .piper;
    var voice_arg: ?[]const u8 = null;
    var rate: u32 = DEFAULT_RATE;
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
                std.debug.print("error: --engine invalid (got '{s}') — expected say|piper\n", .{args[i]});
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
        } else {
            text = a;
        }
    }

    if (text == null) {
        std.debug.print(HELP, .{});
        std.process.exit(2);
    }

    // Engine-specific voice defaults. Piper ignores `voice` for now (Faber
    // is the only one shipped) but we still pass it through for protocol
    // consistency and future-proofing.
    const voice: []const u8 = voice_arg orelse switch (engine) {
        .say => DEFAULT_VOICE,
        .piper => "faber",
    };

    const clean = try ipc.sanitizeText(arena, text.?);
    const msg = ipc.Message{ .engine = engine, .voice = voice, .rate = rate, .text = clean };

    var stream = try openSocket(arena, io, home);
    defer stream.close(io);

    var read_buf: [READ_BUF]u8 = undefined;
    var write_buf: [WRITE_BUF]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    const t_start = std.Io.Clock.now(.awake, io);
    try sw.interface.print("ENQUEUE\t{s}\t{s}\t{d}\t{s}\n", .{ msg.engine.str(), msg.voice, msg.rate, msg.text });
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
