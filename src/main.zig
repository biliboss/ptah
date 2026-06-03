// agent-tts — Pt-BR TTS via macOS `say`.
//
// Single binary, modes:
//   agent-tts daemon              → daemon (foreground)
//   agent-tts daemon install      → write LaunchAgent plist + bootstrap
//   agent-tts daemon uninstall    → bootout + delete plist
//   agent-tts daemon status       → loaded?/last exit (via launchctl print)
//   agent-tts queue               → client: list pending+playing items
//   agent-tts skip                → client: skip current playing item
//   agent-tts clear               → client: drop all pending items
//   agent-tts -h | --help         → help
//   agent-tts -V | --version      → version
//   agent-tts ...                 → client: enqueue text on running daemon
//
// v0.3: SQLite WAL queue at ~/.cache/agent-tts/queue.db.
// v0.4: launchd LaunchAgent (~/Library/LaunchAgents/cloud.mukutu.agent-tts.plist).
// v0.5: Pt-BR text preprocessor (abbreviations, cardinals 0..9999, [[slnc N]] pauses).
//
// KPI = time-to-first-audio (TTFA).

const std = @import("std");

const client = @import("client.zig");
const daemon = @import("daemon.zig");
const launchd = @import("launchd.zig");

pub const VERSION = "0.5.0";

const HELP =
    \\agent-tts v{s} — Pt-BR TTS via macOS `say`
    \\
    \\Usage:
    \\  agent-tts "texto"                send to running daemon
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
    \\Options:
    \\  --voice NAME   say voice (default: Luciana)
    \\  --rate WPM     words per minute (default: 330)
    \\  -h, --help     this help
    \\  -V, --version  print version
    \\
    \\v0.5 ships the Pt-BR text preprocessor: abbreviations (Sr./Dr./Av./R$/…),
    \\cardinal numbers 0..9999 (e.g. 2026 → "dois mil e vinte e seis"), and
    \\[[slnc N]] pauses for commas, sentences and newlines. Cadência humana.
    \\
    \\launchd plist lives at ~/Library/LaunchAgents/cloud.mukutu.agent-tts.plist
    \\(override label via AGENT_TTS_LAUNCHD_LABEL env var — used by tests).
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const home = init.environ_map.get("HOME") orelse "/tmp";

    // Optional override for the LaunchAgent label, used by the dry-run test
    // in _qa/v0.4-baseline.md so we never clobber the real install.
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
