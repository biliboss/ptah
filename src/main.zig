// agent-tts v0.4 — Pt-BR TTS via macOS `say`, with persistent daemon + launchd.
//
// Entry point. Routes argv:
//   agent-tts daemon              → daemon mode (foreground)
//   agent-tts daemon install      → write LaunchAgent plist + bootstrap
//   agent-tts daemon uninstall    → bootout + delete plist
//   agent-tts daemon status       → loaded?/last exit (via launchctl print)
//   agent-tts -h | --help         → help
//   agent-tts -V | --version      → version
//   agent-tts ...                 → client mode (enqueue to running daemon)
//
// v0.4 scope locked by docs/roadmap.md:
//   - launchd LaunchAgent at ~/Library/LaunchAgents/cloud.mukutu.agent-tts.plist
//   - Atomic plist write via createFileAtomic + replace
//   - `launchctl bootstrap gui/<uid>` for load, `launchctl bootout` for unload
//   - Daemon survives logout/reboot — first call of the day keeps TTFA warm
//   - Self-locate via std.process.executablePath (Darwin: _NSGetExecutablePath)
//
// KPI = time-to-first-audio (TTFA). Auto-start removes the "did you forget to
// run the daemon?" failure mode without changing the warm-path round-trip.

const std = @import("std");

const client = @import("client.zig");
const daemon = @import("daemon.zig");
const launchd = @import("launchd.zig");

pub const VERSION = "0.4.0";

const HELP =
    \\agent-tts v{s} — Pt-BR TTS via macOS `say`
    \\
    \\Usage:
    \\  agent-tts "texto"                send to running daemon
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
    // in _qa/v0.4-baseline.md so we never clobber the real install. Empty
    // string ⇒ fall back to DEFAULT_LABEL (see launchd.pickLabel).
    const label_override = init.environ_map.get(launchd.LABEL_ENV);

    if (args.len > 1) {
        const cmd = args[1];
        if (std.mem.eql(u8, cmd, "daemon")) {
            // Daemon subcommands: install/uninstall/status. Bare `daemon`
            // keeps existing foreground behavior (v0.2 contract).
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
