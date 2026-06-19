// SPDX-License-Identifier: MIT OR Apache-2.0
// v1.10.13 — structured logging foundation.
//
// Goal: replace the ad-hoc `std.debug.print` calls scattered across the
// daemon with a `std.log.scoped(...)` interface that writes:
//
//   1. stderr (for launchd capture — the existing user habit), AND
//   2. a rotating file at `~/.cache/ptah/daemon.log`.
//
// Each line is prefixed with an ISO 8601 UTC timestamp, the level, and
// the scope name. Filtering by level + scope happens at runtime so an
// operator can flip `PTAH_LOG_LEVEL=debug` (or scope it down with
// `PTAH_LOG_SCOPES=worker,postfx`) without rebuilding the daemon.
//
// Threading: the file sink is shared between the worker thread, the
// accept thread, and any auxiliary threads (synth pipeline, postfx
// watchdog). A single `std.Thread.Mutex` guards the formatter+writer
// so each `log.info(...)` call appends one complete line atomically.
// The stderr write is guarded by `std.debug.lockStderr` separately.
//
// Rotation: when the active file exceeds `PTAH_LOG_MAX_BYTES`
// (default 10 MiB), we rename `daemon.log → daemon.log.1`, shifting
// any older rotations down (.1 → .2, .2 → .3) and dropping `.3`. The
// rotation runs inside the same mutex so a concurrent writer can't see
// a partially-renamed pair.

const std = @import("std");

// libc binding. We go through @cImport for the time/stat/file
// primitives that std.c doesn't directly expose (gmtime_r,
// fstat-by-fd, mkdir, rename). The header set is portable on
// macOS+Linux which is the only space we ship to.
const cdef = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("time.h");
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

// -----------------------------------------------------------------------
// Public API: pointed at by `std_options.logFn` in main.zig.
// -----------------------------------------------------------------------

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // Cheap level filter first — avoids any allocation/formatting work
    // when the operator dialled the daemon down to `warn`/`err`.
    const cfg = config();
    if (@intFromEnum(level) > @intFromEnum(cfg.level)) return;

    const scope_name = comptime @tagName(scope);
    if (!scopeAllowed(cfg, scope_name)) return;

    // Format the user message into a fixed-size stack buffer. We cap at
    // 4 KiB which is far larger than every existing call site (longest
    // observed: ~300 bytes of knob dump). Overflow truncates and adds a
    // `…` marker so the daemon never crashes on a poorly-chosen format.
    var msg_buf: [4096]u8 = undefined;
    const msg_slice = std.fmt.bufPrint(&msg_buf, format, args) catch blk: {
        const truncated_marker = "…";
        const max = msg_buf.len - truncated_marker.len;
        @memcpy(msg_buf[max..][0..truncated_marker.len], truncated_marker);
        break :blk msg_buf[0..msg_buf.len];
    };

    var ts_buf: [40]u8 = undefined;
    const ts = isoTimestamp(&ts_buf);

    var line_buf: [4400]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{s} [{s}] [{s}] {s}\n", .{
        ts,
        level.asText(),
        scope_name,
        msg_slice,
    }) catch line_buf[0..0];

    writeLine(line);
}

// -----------------------------------------------------------------------
// Config — initialised lazily on first call. Runtime env reads happen
// once; the cached values stay good for the lifetime of the daemon. A
// SIGHUP-driven reload would be a v1.11 nicety; the current launchd
// kickstart flow already restarts the daemon, so the cache lifetime
// matches operational expectations.
// -----------------------------------------------------------------------

const Config = struct {
    level: std.log.Level,
    max_bytes: u64,
    /// Up to 16 scope filter strings. Empty `scope_count` == "all scopes pass".
    scope_buf: [16][32]u8,
    scope_lens: [16]u8,
    scope_count: u8,
    path_buf: [512]u8,
    path_len: usize,
    /// libc file descriptor. `-1` until first writeLine acquires the
    /// mutex and opens the file. We use libc directly to keep the
    /// log infra independent of `std.Io` — `std.fs.File` would force
    /// the call site to pipe an io value through every call frame.
    fd: c_int,
};

var cfg_init_flag: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var cfg_storage: Config = undefined;
/// Spinlock-style atomic flag that guards file-sink mutation. Zig 0.16 removed
/// `std.Thread.Mutex` and the replacement `std.Io.Mutex` requires an `io`
/// value at lock time — log call sites are stdlib-style and don't carry one,
/// so we roll a tiny CAS spin. Contention is rare (one writer per log line,
/// sub-millisecond hold time) so the spin never costs anything visible.
var cfg_mu: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

fn lock() void {
    const ts: std.c.timespec = .{ .sec = 0, .nsec = 1_000 }; // 1 µs backoff
    while (true) {
        if (cfg_mu.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) return;
        _ = std.c.nanosleep(&ts, null);
    }
}

fn unlock() void {
    cfg_mu.store(0, .release);
}

fn config() *Config {
    // Fast path — already initialised. States: 0 = uninit, 1 = busy, 2 = ready.
    if (cfg_init_flag.load(.acquire) == 2) return &cfg_storage;

    // Race the init: a single thread wins the 0→1 CAS and runs initConfig.
    // Losers spin on the flag (sub-millisecond on cold path) until it flips to 2.
    if (cfg_init_flag.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
        initConfig();
        cfg_init_flag.store(2, .release);
    } else {
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 1_000 };
        while (cfg_init_flag.load(.acquire) != 2) {
            _ = std.c.nanosleep(&ts, null);
        }
    }
    return &cfg_storage;
}

fn initConfig() void {
    cfg_storage = .{
        .level = parseLevelEnv(),
        .max_bytes = parseMaxBytesEnv(),
        .scope_buf = undefined,
        .scope_lens = [_]u8{0} ** 16,
        .scope_count = 0,
        .path_buf = undefined,
        .path_len = 0,
        .fd = -1,
    };
    parseScopesEnv(&cfg_storage);
    resolvePath(&cfg_storage);
}

fn parseLevelEnv() std.log.Level {
    const s = envStr("PTAH_LOG_LEVEL") orelse return .info;
    if (eqi(s, "err") or eqi(s, "error")) return .err;
    if (eqi(s, "warn") or eqi(s, "warning")) return .warn;
    if (eqi(s, "info")) return .info;
    if (eqi(s, "debug")) return .debug;
    return .info;
}

fn parseMaxBytesEnv() u64 {
    const s = envStr("PTAH_LOG_MAX_BYTES") orelse return 10 * 1024 * 1024;
    return std.fmt.parseInt(u64, s, 10) catch (10 * 1024 * 1024);
}

fn parseScopesEnv(c: *Config) void {
    const s = envStr("PTAH_LOG_SCOPES") orelse return;
    if (s.len == 0) return;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, " \t");
        if (tok.len == 0) continue;
        if (c.scope_count >= c.scope_buf.len) break;
        const cap = c.scope_buf[c.scope_count].len;
        const n = @min(tok.len, cap);
        @memcpy(c.scope_buf[c.scope_count][0..n], tok[0..n]);
        c.scope_lens[c.scope_count] = @intCast(n);
        c.scope_count += 1;
    }
}

fn resolvePath(c: *Config) void {
    if (envStr("PTAH_LOG_PATH")) |env_p| {
        const n = @min(env_p.len, c.path_buf.len - 1);
        @memcpy(c.path_buf[0..n], env_p[0..n]);
        c.path_buf[n] = 0;
        c.path_len = n;
        return;
    }
    const home = envStr("HOME") orelse "/tmp";
    const suffix = "/.cache/ptah/daemon.log";
    if (home.len + suffix.len + 1 >= c.path_buf.len) {
        const fallback = "/tmp/ptah-daemon.log";
        @memcpy(c.path_buf[0..fallback.len], fallback);
        c.path_buf[fallback.len] = 0;
        c.path_len = fallback.len;
        return;
    }
    @memcpy(c.path_buf[0..home.len], home);
    @memcpy(c.path_buf[home.len..][0..suffix.len], suffix);
    c.path_buf[home.len + suffix.len] = 0;
    c.path_len = home.len + suffix.len;
}

fn scopeAllowed(c: *const Config, name: []const u8) bool {
    if (c.scope_count == 0) return true;
    var i: u8 = 0;
    while (i < c.scope_count) : (i += 1) {
        const len = c.scope_lens[i];
        if (len == name.len and std.mem.eql(u8, c.scope_buf[i][0..len], name)) return true;
    }
    return false;
}

// -----------------------------------------------------------------------
// Output sinks — file (with size-based rotation) + stderr.
// -----------------------------------------------------------------------

fn writeLine(line: []const u8) void {
    const c = config();
    lock();
    defer unlock();

    ensureFileOpenLocked(c);
    if (c.fd >= 0) {
        // Best-effort write — the file sink is a diagnostics surface,
        // not a crash boundary. If the disk is full or the fd was
        // closed under us, fall through to stderr without aborting.
        _ = cdef.write(c.fd, line.ptr, line.len);
        maybeRotateLocked(c);
    }

    // stderr — guarded by std.debug.lockStderr so we don't interleave
    // bytes with someone using std.debug.print elsewhere (e.g. the test
    // harness or a legacy CLI call site we didn't migrate yet).
    var stderr_buf: [4400]u8 = undefined;
    const terminal = std.debug.lockStderr(&stderr_buf).terminal();
    defer std.debug.unlockStderr();
    terminal.writer.writeAll(line) catch {};
    terminal.writer.flush() catch {};
}

fn ensureFileOpenLocked(c: *Config) void {
    if (c.fd >= 0) return;
    if (c.path_len == 0) return;

    // Make sure the parent directory exists. We mkdir each component
    // ignoring EEXIST so launchd's initial run on a fresh box still
    // gets ~/.cache/ptah/.
    mkdirParents(@ptrCast(&c.path_buf[0]));

    // O_WRONLY | O_CREAT | O_APPEND. Append preserves logs across
    // daemon restarts. cdef exposes the symbolic flag constants.
    const flags = cdef.O_WRONLY | cdef.O_CREAT | cdef.O_APPEND;
    const fd = cdef.open(@ptrCast(&c.path_buf[0]), flags, @as(c_uint, 0o644));
    if (fd >= 0) c.fd = fd;
}

fn maybeRotateLocked(c: *Config) void {
    if (c.fd < 0) return;
    const size = fdSizeBytes(c.fd);
    if (size < c.max_bytes) return;

    // Close current handle, rotate filenames, then reopen on next
    // writeLine via ensureFileOpenLocked.
    _ = cdef.close(c.fd);
    c.fd = -1;

    var src_buf: [528]u8 = undefined;
    var dst_buf: [528]u8 = undefined;
    const base = c.path_buf[0..c.path_len];

    // Drop the oldest rotation (.3) if it exists.
    {
        const oldest = std.fmt.bufPrintZ(&src_buf, "{s}.3", .{base}) catch return;
        _ = cdef.unlink(oldest.ptr);
    }
    // Shift .2 → .3, .1 → .2, current → .1
    var idx: usize = 3;
    while (idx >= 1) : (idx -= 1) {
        if (idx == 1) {
            const dst = std.fmt.bufPrintZ(&dst_buf, "{s}.1", .{base}) catch return;
            _ = cdef.rename(@ptrCast(&c.path_buf[0]), dst.ptr);
        } else {
            const src = std.fmt.bufPrintZ(&src_buf, "{s}.{d}", .{ base, idx - 1 }) catch return;
            const dst = std.fmt.bufPrintZ(&dst_buf, "{s}.{d}", .{ base, idx }) catch return;
            _ = cdef.rename(src.ptr, dst.ptr);
        }
    }
}

fn fdSizeBytes(fd: c_int) u64 {
    var st: cdef.struct_stat = undefined;
    if (cdef.fstat(fd, &st) != 0) return 0;
    return @intCast(st.st_size);
}

fn mkdirParents(path: [*:0]const u8) void {
    // Walk the path creating each directory component. We mutate a
    // scratch copy in place — null-terminating at each slash, mkdir,
    // restore — so we never need to touch the underlying path buf.
    var buf: [512]u8 = undefined;
    const slice = std.mem.span(path);
    if (slice.len >= buf.len) return;
    @memcpy(buf[0..slice.len], slice);
    buf[slice.len] = 0;

    // Trim the final component (the actual file name).
    var end = slice.len;
    while (end > 0 and buf[end - 1] != '/') : (end -= 1) {}
    if (end == 0) return;
    buf[end - 1] = 0;

    // Walk from root, creating each segment.
    var i: usize = 1;
    while (i < end - 1) : (i += 1) {
        if (buf[i] == '/') {
            buf[i] = 0;
            _ = cdef.mkdir(@ptrCast(&buf[0]), 0o755);
            buf[i] = '/';
        }
    }
    _ = cdef.mkdir(@ptrCast(&buf[0]), 0o755);
}

// -----------------------------------------------------------------------
// Timestamp — ISO 8601 with millisecond resolution, always UTC. Uses
// libc clock_gettime + gmtime_r because std.time.epoch in Zig 0.16 is a
// thin formatter that still wants a Writer; we want a fixed buffer.
// -----------------------------------------------------------------------

fn isoTimestamp(buf: []u8) []const u8 {
    var ts: cdef.struct_timespec = undefined;
    if (cdef.clock_gettime(cdef.CLOCK_REALTIME, &ts) != 0) {
        return std.fmt.bufPrint(buf, "1970-01-01T00:00:00.000Z", .{}) catch buf[0..0];
    }
    const sec: cdef.time_t = ts.tv_sec;
    const ms: u16 = @intCast(@divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000));

    var tm: cdef.struct_tm = undefined;
    const tm_ptr = cdef.gmtime_r(&sec, &tm);
    if (tm_ptr == null) {
        return std.fmt.bufPrint(buf, "1970-01-01T00:00:00.{d:0>3}Z", .{ms}) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u16, @intCast(tm.tm_year + 1900)),
        @as(u8, @intCast(tm.tm_mon + 1)),
        @as(u8, @intCast(tm.tm_mday)),
        @as(u8, @intCast(tm.tm_hour)),
        @as(u8, @intCast(tm.tm_min)),
        @as(u8, @intCast(tm.tm_sec)),
        ms,
    }) catch buf[0..0];
}

// -----------------------------------------------------------------------
// Helpers — getenv + case-insensitive compare.
// -----------------------------------------------------------------------

fn envStr(name: [*:0]const u8) ?[]const u8 {
    const ptr = cdef.getenv(name);
    if (ptr == null) return null;
    const s = std.mem.span(ptr);
    if (s.len == 0) return null;
    return s;
}

fn eqi(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[i]);
        if (ca != cb) return false;
    }
    return true;
}

// -----------------------------------------------------------------------
// Tests — light, focused on the pure helpers. The file sink is exercised
// at integration time (the daemon writes real lines during validation).
// -----------------------------------------------------------------------

test "scopeAllowed empty filter accepts every scope" {
    var c: Config = .{
        .level = .info,
        .max_bytes = 0,
        .scope_buf = undefined,
        .scope_lens = [_]u8{0} ** 16,
        .scope_count = 0,
        .path_buf = undefined,
        .path_len = 0,
        .fd = -1,
    };
    try std.testing.expect(scopeAllowed(&c, "worker"));
    try std.testing.expect(scopeAllowed(&c, "postfx"));
    try std.testing.expect(scopeAllowed(&c, "anything"));
}

test "scopeAllowed honors explicit allow list" {
    var c: Config = .{
        .level = .info,
        .max_bytes = 0,
        .scope_buf = undefined,
        .scope_lens = [_]u8{0} ** 16,
        .scope_count = 0,
        .path_buf = undefined,
        .path_len = 0,
        .fd = -1,
    };
    const names = [_][]const u8{ "worker", "postfx" };
    for (names, 0..) |n, i| {
        @memcpy(c.scope_buf[i][0..n.len], n);
        c.scope_lens[i] = @intCast(n.len);
        c.scope_count += 1;
    }
    try std.testing.expect(scopeAllowed(&c, "worker"));
    try std.testing.expect(scopeAllowed(&c, "postfx"));
    try std.testing.expect(!scopeAllowed(&c, "piper"));
    try std.testing.expect(!scopeAllowed(&c, ""));
}

test "isoTimestamp produces 24-char ISO 8601 string" {
    var buf: [40]u8 = undefined;
    const s = isoTimestamp(&buf);
    try std.testing.expectEqual(@as(usize, 24), s.len);
    try std.testing.expectEqual(@as(u8, '-'), s[4]);
    try std.testing.expectEqual(@as(u8, '-'), s[7]);
    try std.testing.expectEqual(@as(u8, 'T'), s[10]);
    try std.testing.expectEqual(@as(u8, ':'), s[13]);
    try std.testing.expectEqual(@as(u8, ':'), s[16]);
    try std.testing.expectEqual(@as(u8, '.'), s[19]);
    try std.testing.expectEqual(@as(u8, 'Z'), s[23]);
}

test "eqi case-insensitive ASCII compare" {
    try std.testing.expect(eqi("warn", "warn"));
    try std.testing.expect(eqi("warn", "WARN"));
    try std.testing.expect(eqi("Warn", "wArN"));
    try std.testing.expect(!eqi("warn", "info"));
    try std.testing.expect(!eqi("warn", "warning"));
}
