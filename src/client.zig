// Client: connect to running daemon, enqueue text, print ACK.
//
// v0.2 does NOT auto-start the daemon — if connect fails, user is told to
// start it manually with `agent-tts daemon`. Auto-start lands in v0.4.

const std = @import("std");
const ipc = @import("ipc.zig");

const DEFAULT_VOICE = "Luciana";
const DEFAULT_RATE: u32 = 330;
const READ_BUF = 1024;
const WRITE_BUF = 16 * 1024;

const HELP =
    \\agent-tts — Pt-BR TTS via macOS `say`
    \\
    \\Usage:
    \\  agent-tts "texto"
    \\  agent-tts --voice "Felipe" --rate 220 "texto"
    \\  agent-tts daemon
    \\
    \\Options:
    \\  --voice NAME   say voice (default: Luciana)
    \\  --rate WPM     words per minute (default: 330)
    \\  -h, --help     this help
    \\  -V, --version  print version
    \\
;

pub fn run(arena: std.mem.Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    var voice: []const u8 = DEFAULT_VOICE;
    var rate: u32 = DEFAULT_RATE;
    var text: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--voice")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --voice needs value\n", .{});
                std.process.exit(2);
            }
            voice = args[i];
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

    const clean = try ipc.sanitizeText(arena, text.?);
    const msg = ipc.Message{ .voice = voice, .rate = rate, .text = clean };

    const sock_path = try ipc.socketPath(arena, io, home);
    var addr = try std.Io.net.UnixAddress.init(sock_path);

    const t_start = std.Io.Clock.now(.awake, io);

    var stream = addr.connect(io) catch |e| {
        std.debug.print(
            "error: cannot reach daemon at {s} ({s}).\nstart with: agent-tts daemon\n",
            .{ sock_path, @errorName(e) },
        );
        std.process.exit(1);
    };
    defer stream.close(io);

    var read_buf: [READ_BUF]u8 = undefined;
    var write_buf: [WRITE_BUF]u8 = undefined;
    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    try sw.interface.print("ENQUEUE\t{s}\t{d}\t{s}\n", .{ msg.voice, msg.rate, msg.text });
    try sw.interface.flush();

    const line = try sr.interface.takeDelimiterExclusive('\n');
    const t_end = std.Io.Clock.now(.awake, io);
    const rt_ms = @as(f64, @floatFromInt(t_end.nanoseconds - t_start.nanoseconds)) / 1_000_000.0;

    if (std.mem.startsWith(u8, line, "OK\t")) {
        const id = line[3..];
        std.debug.print("[agent-tts] enqueued id={s} round-trip={d:.1}ms\n", .{ id, rt_ms });
    } else if (std.mem.startsWith(u8, line, "ERR\t")) {
        std.debug.print("[agent-tts] daemon error: {s}\n", .{line[4..]});
        std.process.exit(1);
    } else {
        std.debug.print("[agent-tts] unexpected response: {s}\n", .{line});
        std.process.exit(1);
    }
}
