// SPDX-License-Identifier: MIT OR Apache-2.0
// ptah — Pt-BR TTS via Kokoro Dora (ONNX + espeak-ng, no Python).
//
// Single binary, modes:
//   ptah daemon                       → daemon (foreground)
//   ptah daemon install               → write LaunchAgent plist + bootstrap
//   ptah daemon uninstall             → bootout + delete plist
//   ptah daemon status                → loaded?/last exit
//   ptah queue                        → client: list pending+playing items
//   ptah skip                         → client: skip current playing item
//   ptah clear                        → client: drop all pending items
//   ptah mcp                          → stdio MCP server
//   ptah stream                       → stdin sentence pipe
//   ptah -h | --help                  → help
//   ptah -V | --version               → version
//   ptah [--voice V] [--speed F] "..." → enqueue via Kokoro Dora
//
// KPI = time-to-first-audio (TTFA).

const std = @import("std");

const client = @import("client.zig");
const daemon = @import("daemon.zig");
const launchd = @import("launchd.zig");
const systemd = @import("systemd.zig");
const platform = @import("platform.zig");
const ipc = @import("ipc.zig");
const mcp = @import("mcp.zig");
const stream_mod = @import("stream.zig");
const log_mod = @import("log.zig");

pub const VERSION = "1.10.13";

pub const std_options: std.Options = .{
    .logFn = log_mod.logFn,
    .log_level = .debug,
};

const HELP =
    \\ptah v{s} — Pt-BR TTS via Kokoro Dora (ONNX + espeak-ng)
    \\
    \\Usage:
    \\  ptah "texto"                    send to running daemon (Kokoro Dora)
    \\  ptah queue                      list pending + playing items
    \\  ptah skip                       skip current playing item
    \\  ptah clear                      drop all pending items
    \\  ptah pause                      pause active playback
    \\  ptah resume                     resume paused playback
    \\  ptah replay <id>                re-enqueue a past item
    \\  ptah history [--limit N]        list last N items, any state
    \\  ptah daemon                     run daemon (foreground)
    \\  ptah daemon install             install auto-start unit (launchd/systemd)
    \\  ptah daemon uninstall           remove auto-start unit
    \\  ptah daemon status              print auto-start load state
    \\  ptah mcp                        stdio MCP server (Claude Code / Cursor)
    \\  ptah stream [--voice V] [--speed F]   read stdin, enqueue per sentence
    \\  ptah --voice "pf_dora" "texto"
    \\  ptah --speed 1.0 "texto"
    \\
    \\Engine: Kokoro Dora is the sole TTS engine.
    \\  Model: ~/.cache/ptah/kokoro-v1.0.onnx (or KOKORO_MODEL env var)
    \\  Voice: ~/.cache/ptah/pf_dora.bin      (or KOKORO_VOICE env var)
    \\  espeak-ng: brew install espeak-ng      (or ESPEAK_DATA_PATH env var)
    \\
    \\Options:
    \\  --voice NAME        voice binary (default: pf_dora)
    \\  --speed F           synthesis speed (default: 1.0; <1=slower, >1=faster)
    \\  --lang auto|pt|en   language hint (default: auto)
    \\  --ssml              treat text as W3C SSML 1.1 subset
    \\  --tech              tech-report mode (acronym + unit glossary)
    \\  --postfx P          ffmpeg post-fx: off (default) / clean / tech / broadcast
    \\  -h, --help          this help
    \\  -V, --version       print version
    \\
    \\Auto-start per platform:
    \\  macOS    ~/Library/LaunchAgents/io.github.biliboss.ptah.plist
    \\  Linux    ~/.config/systemd/user/ptah.service
    \\
    \\Claude Code MCP wire-up:
    \\  "mcpServers": {{ "ptah": {{ "command": "ptah", "args": ["mcp"] }} }}
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
                                "error: daemon install not implemented on Windows\n",
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
            std.debug.print("ptah {s}\n", .{VERSION});
            return;
        }
    }
    return client.run(arena, io, home, args);
}
