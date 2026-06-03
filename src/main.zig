// agent-tts v0.2 — Pt-BR TTS via macOS `say`, with persistent daemon.
//
// Entry point. Routes argv:
//   agent-tts daemon         → daemon mode
//   agent-tts -h | --help    → help
//   agent-tts -V | --version → version
//   agent-tts ...            → client mode (enqueue to running daemon)
//
// v0.2 scope locked by docs/roadmap.md:
//   - Foreground daemon (no auto-start; v0.4 brings launchd)
//   - UNIX socket IPC + in-memory FIFO queue
//   - Pre-warm of Luciana voice on daemon boot
//   - Worker thread drains queue serially (never parallel `say`)
//
// KPI = time-to-first-audio (TTFA). Client measures round-trip ACK; real TTFA
// still needs dtruss + audio capture (roadmap _qa/).

const std = @import("std");

const client = @import("client.zig");
const daemon = @import("daemon.zig");

pub const VERSION = "0.2.0";

const HELP =
    \\agent-tts v{s} — Pt-BR TTS via macOS `say`
    \\
    \\Usage:
    \\  agent-tts "texto"                send to running daemon
    \\  agent-tts daemon                 run daemon (foreground)
    \\  agent-tts --voice "Felipe" "texto"
    \\  agent-tts --rate 220 "texto"
    \\
    \\Options:
    \\  --voice NAME   say voice (default: Luciana)
    \\  --rate WPM     words per minute (default: 330)
    \\  -h, --help     this help
    \\  -V, --version  print version
    \\
    \\v0.2 needs `agent-tts daemon` running in another terminal.
    \\Auto-start arrives in v0.4 (launchd).
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const home = init.environ_map.get("HOME") orelse "/tmp";

    if (args.len > 1) {
        const cmd = args[1];
        if (std.mem.eql(u8, cmd, "daemon")) {
            return daemon.run(arena, io, home);
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
