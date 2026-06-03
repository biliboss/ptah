// SPDX-License-Identifier: MIT OR Apache-2.0
// systemd user-unit integration (Linux auto-start) — v1.3.
//
// Parallels launchd.zig. Writes a per-user unit to
// `$XDG_CONFIG_HOME/systemd/user/agent-tts.service` (falling back to
// `$HOME/.config/systemd/user/`) and drives the lifecycle via
// `systemctl --user`. Same install / uninstall / status surface so
// `agent-tts daemon install` reads the same on Linux as on macOS.
//
// Unit path: $XDG_CONFIG_HOME/systemd/user/agent-tts.service
// Unit name: agent-tts.service  (override via AGENT_TTS_SYSTEMD_UNIT —
//            same role as AGENT_TTS_LAUNCHD_LABEL on macOS)
//
// Three subcommands wire in from main.zig:
//   agent-tts daemon install    → write unit + systemctl --user enable --now
//   agent-tts daemon uninstall  → systemctl --user disable --now + delete unit
//   agent-tts daemon status     → systemctl --user status agent-tts
//
// Constraints (mirror launchd.zig):
//   - Unit write is atomic: createFileAtomic into the unit dir then replace().
//     systemd reload picks the new file up on the next daemon-reload.
//   - install refuses if the unit already exists ("uninstall first")
//   - uninstall refuses if the unit is not present
//
// Self-locate: std.process.executablePath resolves the running binary on
// Linux via /proc/self/exe + readlink. systemd requires absolute paths in
// ExecStart, so we never trust argv[0].
//
// Honest scope: this module compiles + runs on Linux. macOS callers don't
// reach it (platform dispatcher routes them to launchd.zig). End-to-end
// runtime exercise is the CI job on ubuntu-latest — the v1.3 ship lands
// before a hardened-Linux smoke baseline is published.

const std = @import("std");

pub const DEFAULT_UNIT = "agent-tts.service";
pub const UNIT_ENV = "AGENT_TTS_SYSTEMD_UNIT";

const Paths = struct {
    unit: []const u8,
    unit_dir: []const u8,
    unit_abs: []const u8,
    cache_dir: []const u8,
};

fn pickUnit(env: ?[]const u8) []const u8 {
    if (env) |s| {
        if (s.len > 0) return s;
    }
    return DEFAULT_UNIT;
}

fn computePaths(
    arena: std.mem.Allocator,
    home: []const u8,
    xdg_config: ?[]const u8,
    unit: []const u8,
) !Paths {
    const unit_dir = if (xdg_config) |x| blk: {
        if (x.len > 0) break :blk try std.fmt.allocPrint(arena, "{s}/systemd/user", .{x});
        break :blk try std.fmt.allocPrint(arena, "{s}/.config/systemd/user", .{home});
    } else try std.fmt.allocPrint(arena, "{s}/.config/systemd/user", .{home});

    const unit_abs = try std.fmt.allocPrint(arena, "{s}/{s}", .{ unit_dir, unit });
    const cache_dir = try std.fmt.allocPrint(arena, "{s}/.cache/agent-tts", .{home});
    return .{
        .unit = unit,
        .unit_dir = unit_dir,
        .unit_abs = unit_abs,
        .cache_dir = cache_dir,
    };
}

fn resolveExePath(arena: std.mem.Allocator, io: std.Io) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.executablePath(io, &buf);
    return arena.dupe(u8, buf[0..n]);
}

// Render the unit file. Restart=on-failure mirrors the launchd KeepAlive=
// {SuccessfulExit=false} contract: clean exit stays down, crash recovers.
// StandardOutput / StandardError go to journald — `journalctl --user -u
// agent-tts` is the canonical debugging path on Linux.
fn renderUnit(
    arena: std.mem.Allocator,
    exe_path: []const u8,
    home: []const u8,
    cache_dir: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(arena,
        \\[Unit]
        \\Description=agent-tts daemon (Pt-BR TTS)
        \\Documentation=https://biliboss.github.io/agent-tts/
        \\After=default.target sound.target
        \\
        \\[Service]
        \\Type=simple
        \\ExecStart={s} daemon
        \\WorkingDirectory={s}
        \\Environment=HOME={s}
        \\Restart=on-failure
        \\RestartSec=2
        \\StandardOutput=journal
        \\StandardError=journal
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    , .{ exe_path, cache_dir, home });
}

fn writeUnitAtomic(io: std.Io, paths: Paths, contents: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, paths.unit_dir) catch {};

    var dir = try std.Io.Dir.cwd().openDir(io, paths.unit_dir, .{});
    defer dir.close(io);

    var atomic = try dir.createFileAtomic(io, paths.unit, .{
        .replace = true,
    });
    defer atomic.deinit(io);

    var write_buf: [4096]u8 = undefined;
    var fw = atomic.file.writer(io, &write_buf);
    try fw.interface.writeAll(contents);
    try fw.interface.flush();

    try atomic.replace(io);
}

fn unitExists(io: std.Io, paths: Paths) bool {
    std.Io.Dir.accessAbsolute(io, paths.unit_abs, .{ .read = true }) catch return false;
    return true;
}

fn systemctl(
    arena: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) !std.process.RunResult {
    return std.process.run(arena, io, .{ .argv = argv });
}

// install: write the unit + `systemctl --user daemon-reload` + enable --now.
// `daemon-reload` is required because systemd caches unit files; without it
// `enable --now` would race against the file change on the same boot.
pub fn install(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    xdg_config: ?[]const u8,
    unit_override: ?[]const u8,
    exe_path_override: ?[]const u8,
) !void {
    const unit = pickUnit(unit_override);
    const paths = try computePaths(arena, home, xdg_config, unit);

    if (unitExists(io, paths)) {
        std.debug.print(
            "[systemd] already installed at {s} — uninstall first\n",
            .{paths.unit_abs},
        );
        return error.AlreadyInstalled;
    }

    const exe_path = exe_path_override orelse try resolveExePath(arena, io);

    std.Io.Dir.cwd().createDirPath(io, paths.cache_dir) catch {};

    const unit_text = try renderUnit(arena, exe_path, paths.cache_dir, home);
    try writeUnitAtomic(io, paths, unit_text);
    std.debug.print("[systemd] wrote {s} ({d} bytes)\n", .{ paths.unit_abs, unit_text.len });

    {
        const argv = [_][]const u8{ "systemctl", "--user", "daemon-reload" };
        const result = systemctl(arena, io, &argv) catch |e| {
            std.debug.print("[systemd] systemctl daemon-reload spawn failed: {s}\n", .{@errorName(e)});
            return e;
        };
        defer arena.free(result.stdout);
        defer arena.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print(
                    "[systemd] daemon-reload exited code={d}\nstdout: {s}\nstderr: {s}\n",
                    .{ code, result.stdout, result.stderr },
                );
                return error.DaemonReloadFailed;
            },
            else => {
                std.debug.print("[systemd] daemon-reload abnormal term\n", .{});
                return error.DaemonReloadFailed;
            },
        }
    }

    const argv = [_][]const u8{ "systemctl", "--user", "enable", "--now", unit };
    const result = systemctl(arena, io, &argv) catch |e| {
        std.debug.print("[systemd] systemctl enable --now spawn failed: {s}\n", .{@errorName(e)});
        return e;
    };
    defer arena.free(result.stdout);
    defer arena.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                std.debug.print("[systemd] enable --now OK (unit={s})\n", .{unit});
                return;
            }
            std.debug.print(
                "[systemd] enable --now exited code={d}\nstdout: {s}\nstderr: {s}\n",
                .{ code, result.stdout, result.stderr },
            );
            return error.EnableFailed;
        },
        else => {
            std.debug.print("[systemd] enable --now abnormal term\n", .{});
            return error.EnableFailed;
        },
    }
}

// uninstall: disable --now (best-effort) + delete unit + daemon-reload.
// disable --now stops the service AND removes the WantedBy symlink; we
// still try to delete the unit file so a re-install starts from a clean
// slate even if systemctl fails (eg user has been logged out).
pub fn uninstall(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    xdg_config: ?[]const u8,
    unit_override: ?[]const u8,
) !void {
    const unit = pickUnit(unit_override);
    const paths = try computePaths(arena, home, xdg_config, unit);

    if (!unitExists(io, paths)) {
        std.debug.print(
            "[systemd] not installed (no unit at {s})\n",
            .{paths.unit_abs},
        );
        return error.NotInstalled;
    }

    {
        const argv = [_][]const u8{ "systemctl", "--user", "disable", "--now", unit };
        const result = systemctl(arena, io, &argv) catch |e| {
            std.debug.print("[systemd] disable --now spawn failed: {s}\n", .{@errorName(e)});
            return e;
        };
        defer arena.free(result.stdout);
        defer arena.free(result.stderr);
        switch (result.term) {
            .exited => |code| {
                if (code == 0) {
                    std.debug.print("[systemd] disable --now OK\n", .{});
                } else {
                    // Non-fatal: print and continue to file removal.
                    std.debug.print(
                        "[systemd] disable --now warning code={d} (continuing)\nstdout: {s}\nstderr: {s}\n",
                        .{ code, result.stdout, result.stderr },
                    );
                }
            },
            else => std.debug.print("[systemd] disable --now abnormal term (continuing)\n", .{}),
        }
    }

    std.Io.Dir.cwd().deleteFile(io, paths.unit_abs) catch |e| {
        std.debug.print("[systemd] could not delete unit: {s}\n", .{@errorName(e)});
        return e;
    };
    std.debug.print("[systemd] removed {s}\n", .{paths.unit_abs});

    const argv = [_][]const u8{ "systemctl", "--user", "daemon-reload" };
    const result = systemctl(arena, io, &argv) catch |e| {
        std.debug.print("[systemd] post-uninstall daemon-reload spawn failed: {s} (non-fatal)\n", .{@errorName(e)});
        return;
    };
    defer arena.free(result.stdout);
    defer arena.free(result.stderr);
    _ = result.term;
}

// status: proxy `systemctl --user status` output. Non-zero exit just means
// the unit isn't loaded — we still print the path probe + unit name so the
// user can diagnose without remembering the command.
pub fn status(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    xdg_config: ?[]const u8,
    unit_override: ?[]const u8,
) !void {
    const unit = pickUnit(unit_override);
    const paths = try computePaths(arena, home, xdg_config, unit);

    const present = unitExists(io, paths);
    std.debug.print(
        "[systemd] unit: {s} ({s})\n",
        .{ paths.unit_abs, if (present) "present" else "missing" },
    );
    std.debug.print("[systemd] name: {s}\n", .{unit});

    const argv = [_][]const u8{ "systemctl", "--user", "status", unit };
    const result = systemctl(arena, io, &argv) catch |e| {
        std.debug.print("[systemd] systemctl status spawn failed: {s}\n", .{@errorName(e)});
        return;
    };
    defer arena.free(result.stdout);
    defer arena.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            std.debug.print(
                "[systemd] systemctl status code={d}\n--- begin ---\n{s}--- end ---\n",
                .{ code, result.stdout },
            );
            if (result.stderr.len > 0) {
                std.debug.print("stderr: {s}\n", .{result.stderr});
            }
        },
        else => std.debug.print("[systemd] systemctl status abnormal term\n", .{}),
    }
}

// Exposed for tests so they can render the unit without touching the FS.
pub fn renderUnitForTest(
    arena: std.mem.Allocator,
    exe_path: []const u8,
    home: []const u8,
) ![]u8 {
    const cache_dir = try std.fmt.allocPrint(arena, "{s}/.cache/agent-tts", .{home});
    return renderUnit(arena, exe_path, home, cache_dir);
}

test "renderUnit contains required sections" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try renderUnitForTest(
        arena,
        "/home/test/bin/agent-tts",
        "/home/test",
    );

    try std.testing.expect(std.mem.indexOf(u8, text, "[Unit]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[Service]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[Install]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ExecStart=/home/test/bin/agent-tts daemon") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Restart=on-failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "WantedBy=default.target") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Environment=HOME=/home/test") != null);
}

test "pickUnit falls back to default" {
    try std.testing.expectEqualStrings(DEFAULT_UNIT, pickUnit(null));
    try std.testing.expectEqualStrings(DEFAULT_UNIT, pickUnit(""));
    try std.testing.expectEqualStrings("custom.service", pickUnit("custom.service"));
}

test "computePaths honours XDG_CONFIG_HOME" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const with_xdg = try computePaths(arena, "/home/test", "/home/test/.cfg", "agent-tts.service");
    try std.testing.expectEqualStrings("/home/test/.cfg/systemd/user", with_xdg.unit_dir);
    try std.testing.expectEqualStrings("/home/test/.cfg/systemd/user/agent-tts.service", with_xdg.unit_abs);

    const fallback = try computePaths(arena, "/home/test", null, "agent-tts.service");
    try std.testing.expectEqualStrings("/home/test/.config/systemd/user", fallback.unit_dir);
}
