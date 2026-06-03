// launchd integration (macOS auto-start) — v0.4.
//
// Manages a per-user LaunchAgent plist so the daemon survives logout/reboot
// and the first call of the day starts hitting an already-warm pre-loaded
// voice (KPI = TTFA).
//
// Plist path: $HOME/Library/LaunchAgents/<label>.plist
// Label:      cloud.mukutu.agent-tts  (override via env AGENT_TTS_LAUNCHD_LABEL
//             — used by the dry-run test in _qa/v0.4-baseline.md to avoid
//             clobbering a real install).
//
// Three subcommands wire in from main.zig:
//   agent-tts daemon install    → write plist + launchctl bootstrap gui/<uid>
//   agent-tts daemon uninstall  → launchctl bootout + delete plist
//   agent-tts daemon status     → loaded? + last exit reason
//
// Constraints:
//   - Plist write is atomic: createFileAtomic into the LaunchAgents dir then
//     replace(). The kernel sees either the old plist or the new one, never
//     a half-written file (launchd polls this dir on bootstrap).
//   - install refuses if the plist already exists ("uninstall first")
//   - uninstall refuses if the plist is not present
//   - getuid() via std.c — needed to build the gui/<uid> domain target so
//     launchctl finds the per-user domain without TTY heuristics.
//
// Self-locate: std.process.executablePath(io, buf) resolves the running
// binary on Darwin via _NSGetExecutablePath + realpath (see std.Io.Threaded
// processExecutablePath for the host implementation). Argv[0] is too fragile
// — launchd needs an absolute path that survives login shell rewrites.

const std = @import("std");

pub const DEFAULT_LABEL = "cloud.mukutu.agent-tts";
pub const LABEL_ENV = "AGENT_TTS_LAUNCHD_LABEL";

// Resolved set of paths derived from $HOME + label. Computed once, reused.
const Paths = struct {
    label: []const u8,
    plist_dir: []const u8,
    plist_basename: []const u8, // "<label>.plist"
    plist_abs: []const u8,
    cache_dir: []const u8,
    stdout_log: []const u8,
    stderr_log: []const u8,
    uid: std.c.uid_t,
};

fn computePaths(arena: std.mem.Allocator, home: []const u8, label: []const u8) !Paths {
    const plist_dir = try std.fmt.allocPrint(arena, "{s}/Library/LaunchAgents", .{home});
    const plist_basename = try std.fmt.allocPrint(arena, "{s}.plist", .{label});
    const plist_abs = try std.fmt.allocPrint(arena, "{s}/{s}", .{ plist_dir, plist_basename });
    const cache_dir = try std.fmt.allocPrint(arena, "{s}/.cache/agent-tts", .{home});
    const stdout_log = try std.fmt.allocPrint(arena, "{s}/daemon.out.log", .{cache_dir});
    const stderr_log = try std.fmt.allocPrint(arena, "{s}/daemon.err.log", .{cache_dir});
    return .{
        .label = label,
        .plist_dir = plist_dir,
        .plist_basename = plist_basename,
        .plist_abs = plist_abs,
        .cache_dir = cache_dir,
        .stdout_log = stdout_log,
        .stderr_log = stderr_log,
        .uid = std.c.getuid(),
    };
}

fn pickLabel(env: ?[]const u8) []const u8 {
    if (env) |s| {
        if (s.len > 0) return s;
    }
    return DEFAULT_LABEL;
}

// Resolve the absolute path of the running binary. Required because launchd
// rejects relative paths in ProgramArguments — and argv[0] from a login shell
// is often "agent-tts" without a directory. Darwin path uses
// _NSGetExecutablePath under the hood (see Threaded.processExecutablePath).
fn resolveExePath(arena: std.mem.Allocator, io: std.Io) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.executablePath(io, &buf);
    return arena.dupe(u8, buf[0..n]);
}

// XML-escape the five entities that matter inside <string> values. Keeps the
// plist parseable even if a user’s HOME ever contains an `&` (unusual but
// not impossible — Apple supports it).
fn xmlEscape(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, s.len);
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(arena, "&amp;"),
            '<' => try out.appendSlice(arena, "&lt;"),
            '>' => try out.appendSlice(arena, "&gt;"),
            '"' => try out.appendSlice(arena, "&quot;"),
            '\'' => try out.appendSlice(arena, "&apos;"),
            else => try out.append(arena, c),
        }
    }
    return out.toOwnedSlice(arena);
}

// Build the plist XML in-arena. KeepAlive uses the SuccessfulExit=false dict
// form so a clean `launchctl bootout` actually keeps it down — bare
// `<true/>` would race-restart it.
fn renderPlist(
    arena: std.mem.Allocator,
    label: []const u8,
    exe_path: []const u8,
    home: []const u8,
    cache_dir: []const u8,
    stdout_log: []const u8,
    stderr_log: []const u8,
) ![]u8 {
    const label_e = try xmlEscape(arena, label);
    const exe_e = try xmlEscape(arena, exe_path);
    const home_e = try xmlEscape(arena, home);
    const cache_e = try xmlEscape(arena, cache_dir);
    const stdout_e = try xmlEscape(arena, stdout_log);
    const stderr_e = try xmlEscape(arena, stderr_log);

    return std.fmt.allocPrint(arena,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>{s}</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>{s}</string>
        \\        <string>daemon</string>
        \\    </array>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\    <key>KeepAlive</key>
        \\    <dict>
        \\        <key>SuccessfulExit</key>
        \\        <false/>
        \\    </dict>
        \\    <key>StandardOutPath</key>
        \\    <string>{s}</string>
        \\    <key>StandardErrorPath</key>
        \\    <string>{s}</string>
        \\    <key>WorkingDirectory</key>
        \\    <string>{s}</string>
        \\    <key>EnvironmentVariables</key>
        \\    <dict>
        \\        <key>HOME</key>
        \\        <string>{s}</string>
        \\    </dict>
        \\    <key>ProcessType</key>
        \\    <string>Background</string>
        \\</dict>
        \\</plist>
        \\
    , .{ label_e, exe_e, stdout_e, stderr_e, cache_e, home_e });
}

// Atomic write into the LaunchAgents dir. createFileAtomic gives an unnamed
// temp file inside the destination dir; replace() does the rename. Either
// step failing leaves the previous plist (or nothing) intact.
fn writePlistAtomic(io: std.Io, paths: Paths, contents: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, paths.plist_dir) catch {};

    var dir = try std.Io.Dir.cwd().openDir(io, paths.plist_dir, .{});
    defer dir.close(io);

    var atomic = try dir.createFileAtomic(io, paths.plist_basename, .{
        .replace = true,
    });
    defer atomic.deinit(io);

    var write_buf: [4096]u8 = undefined;
    var fw = atomic.file.writer(io, &write_buf);
    try fw.interface.writeAll(contents);
    try fw.interface.flush();

    try atomic.replace(io);
}

fn plistExists(io: std.Io, paths: Paths) bool {
    std.Io.Dir.accessAbsolute(io, paths.plist_abs, .{ .read = true }) catch return false;
    return true;
}

fn launchctl(
    arena: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) !std.process.RunResult {
    return std.process.run(arena, io, .{ .argv = argv });
}

// install: write the plist + bootstrap into the per-user GUI domain.
// `launchctl bootstrap gui/<uid> <plist>` is the modern replacement for
// `launchctl load` (which is deprecated since 10.10 and outright unreliable
// on Sonoma+). Bootstrap loads + RunAtLoad fires it immediately.
pub fn install(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    label_override: ?[]const u8,
    exe_path_override: ?[]const u8,
) !void {
    const label = pickLabel(label_override);
    const paths = try computePaths(arena, home, label);

    if (plistExists(io, paths)) {
        std.debug.print(
            "[launchd] already installed at {s} — uninstall first\n",
            .{paths.plist_abs},
        );
        return error.AlreadyInstalled;
    }

    const exe_path = exe_path_override orelse try resolveExePath(arena, io);

    std.Io.Dir.cwd().createDirPath(io, paths.cache_dir) catch {};

    const plist_xml = try renderPlist(
        arena,
        paths.label,
        exe_path,
        home,
        paths.cache_dir,
        paths.stdout_log,
        paths.stderr_log,
    );

    try writePlistAtomic(io, paths, plist_xml);
    std.debug.print("[launchd] wrote {s} ({d} bytes)\n", .{ paths.plist_abs, plist_xml.len });

    const domain = try std.fmt.allocPrint(arena, "gui/{d}", .{paths.uid});
    const argv = [_][]const u8{ "/bin/launchctl", "bootstrap", domain, paths.plist_abs };

    const result = launchctl(arena, io, &argv) catch |e| {
        std.debug.print("[launchd] launchctl spawn failed: {s}\n", .{@errorName(e)});
        return e;
    };
    defer arena.free(result.stdout);
    defer arena.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                std.debug.print(
                    "[launchd] bootstrap OK (domain={s} label={s})\n",
                    .{ domain, paths.label },
                );
                return;
            }
            std.debug.print(
                "[launchd] launchctl bootstrap exited code={d}\nstdout: {s}\nstderr: {s}\n",
                .{ code, result.stdout, result.stderr },
            );
            return error.BootstrapFailed;
        },
        else => {
            std.debug.print("[launchd] launchctl bootstrap abnormal term\n", .{});
            return error.BootstrapFailed;
        },
    }
}

// uninstall: bootout (best-effort) + delete plist. Bootout can fail with
// EINVAL/EBUSY if the agent is mid-restart — we still try to delete so the
// user can re-run install cleanly.
pub fn uninstall(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    label_override: ?[]const u8,
) !void {
    const label = pickLabel(label_override);
    const paths = try computePaths(arena, home, label);

    if (!plistExists(io, paths)) {
        std.debug.print(
            "[launchd] not installed (no plist at {s})\n",
            .{paths.plist_abs},
        );
        return error.NotInstalled;
    }

    const domain = try std.fmt.allocPrint(arena, "gui/{d}", .{paths.uid});
    const argv = [_][]const u8{ "/bin/launchctl", "bootout", domain, paths.plist_abs };

    const result = launchctl(arena, io, &argv) catch |e| {
        std.debug.print("[launchd] launchctl spawn failed: {s}\n", .{@errorName(e)});
        return e;
    };
    defer arena.free(result.stdout);
    defer arena.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                std.debug.print("[launchd] bootout OK\n", .{});
            } else {
                // Non-fatal: print and continue to plist removal so user
                // isn't stuck with an orphan file.
                std.debug.print(
                    "[launchd] bootout warning code={d} (continuing)\nstdout: {s}\nstderr: {s}\n",
                    .{ code, result.stdout, result.stderr },
                );
            }
        },
        else => std.debug.print("[launchd] bootout abnormal term (continuing)\n", .{}),
    }

    std.Io.Dir.cwd().deleteFile(io, paths.plist_abs) catch |e| {
        std.debug.print("[launchd] could not delete plist: {s}\n", .{@errorName(e)});
        return e;
    };
    std.debug.print("[launchd] removed {s}\n", .{paths.plist_abs});
}

// status: print whether the agent is loaded and any captured exit info.
// `launchctl print gui/<uid>/<label>` returns a verbose record; we proxy
// stdout/stderr unedited so future launchd field renames don't break parsing.
pub fn status(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    label_override: ?[]const u8,
) !void {
    const label = pickLabel(label_override);
    const paths = try computePaths(arena, home, label);

    const present = plistExists(io, paths);
    std.debug.print(
        "[launchd] plist: {s} ({s})\n",
        .{ paths.plist_abs, if (present) "present" else "missing" },
    );
    std.debug.print("[launchd] label: {s}\n", .{paths.label});
    std.debug.print("[launchd] uid:   {d}\n", .{paths.uid});

    const service_target = try std.fmt.allocPrint(arena, "gui/{d}/{s}", .{ paths.uid, paths.label });
    const argv = [_][]const u8{ "/bin/launchctl", "print", service_target };

    const result = launchctl(arena, io, &argv) catch |e| {
        std.debug.print("[launchd] launchctl spawn failed: {s}\n", .{@errorName(e)});
        return;
    };
    defer arena.free(result.stdout);
    defer arena.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                std.debug.print("[launchd] launchctl print OK\n--- begin ---\n{s}--- end ---\n", .{result.stdout});
            } else {
                // 113 = "Could not find service" → agent not loaded.
                std.debug.print(
                    "[launchd] launchctl print code={d} (not loaded or unknown label)\nstderr: {s}\n",
                    .{ code, result.stderr },
                );
            }
        },
        else => std.debug.print("[launchd] launchctl print abnormal term\n", .{}),
    }
}

// Exposed for the _qa baseline so the dry-run test can render the plist
// without touching the filesystem.
pub fn renderPlistForTest(
    arena: std.mem.Allocator,
    label: []const u8,
    exe_path: []const u8,
    home: []const u8,
) ![]u8 {
    const cache_dir = try std.fmt.allocPrint(arena, "{s}/.cache/agent-tts", .{home});
    const stdout_log = try std.fmt.allocPrint(arena, "{s}/daemon.out.log", .{cache_dir});
    const stderr_log = try std.fmt.allocPrint(arena, "{s}/daemon.err.log", .{cache_dir});
    return renderPlist(arena, label, exe_path, home, cache_dir, stdout_log, stderr_log);
}

test "renderPlist contains required keys and escapes home" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const xml = try renderPlistForTest(
        arena,
        "cloud.mukutu.agent-tts.test",
        "/Users/test & co/bin/agent-tts",
        "/Users/test & co",
    );

    try std.testing.expect(std.mem.indexOf(u8, xml, "<key>Label</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "cloud.mukutu.agent-tts.test") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<key>RunAtLoad</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<key>KeepAlive</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<key>SuccessfulExit</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<key>StandardOutPath</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<key>StandardErrorPath</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<key>WorkingDirectory</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<key>EnvironmentVariables</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "Users/test &amp; co") != null);
    // Raw '&' must be escaped.
    try std.testing.expect(std.mem.indexOf(u8, xml, "test & co/bin") == null);
    // daemon arg must be present, exactly once.
    var i: usize = 0;
    var hits: usize = 0;
    while (std.mem.indexOfPos(u8, xml, i, "<string>daemon</string>")) |idx| : (i = idx + 1) {
        hits += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), hits);
}

test "pickLabel falls back to default" {
    try std.testing.expectEqualStrings(DEFAULT_LABEL, pickLabel(null));
    try std.testing.expectEqualStrings(DEFAULT_LABEL, pickLabel(""));
    try std.testing.expectEqualStrings("custom.label", pickLabel("custom.label"));
}

test "xmlEscape covers the five entities" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try xmlEscape(arena, "a&b<c>d\"e'f");
    try std.testing.expectEqualStrings("a&amp;b&lt;c&gt;d&quot;e&apos;f", out);
}
