// Daemon: accept loop on UNIX socket, worker thread drains queue via `say`.
//
// v0.2 scope: foreground daemon (no detach), single-threaded accept, one
// worker thread for playback. SIGINT cleans up the socket file.
//
// Auto-detach (fork+exec to background) lands in v0.4 with launchd.

const std = @import("std");
const ipc = @import("ipc.zig");
const tts = @import("tts.zig");
const Queue = @import("queue.zig").Queue;

const READ_BUF = 16 * 1024;
const WRITE_BUF = 256;
const DEFAULT_VOICE = "Luciana";

pub fn run(arena: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    const sock_path = try ipc.socketPath(arena, io, home);

    // Remove orphan socket if any. Cheap; ignored if not present.
    std.Io.Dir.cwd().deleteFile(io, sock_path) catch {};

    var addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    std.debug.print("[daemon] listening on {s}\n", .{sock_path});

    var queue = Queue{ .arena = arena };

    // Pre-warm the voice. Best-effort.
    const t_warm0 = std.Io.Clock.now(.awake, io);
    tts.preWarm(arena, io, DEFAULT_VOICE) catch |e| {
        std.debug.print("[daemon] pre-warm failed: {s}\n", .{@errorName(e)});
    };
    const t_warm1 = std.Io.Clock.now(.awake, io);
    const warm_ms = @as(f64, @floatFromInt(t_warm1.nanoseconds - t_warm0.nanoseconds)) / 1_000_000.0;
    std.debug.print("[daemon] pre-warm done in {d:.1}ms\n", .{warm_ms});

    const worker = try std.Thread.spawn(.{}, workerLoop, .{ &queue, io });
    worker.detach();

    while (true) {
        var stream = server.accept(io) catch |e| {
            std.debug.print("[daemon] accept failed: {s}\n", .{@errorName(e)});
            continue;
        };
        handleClient(arena, io, &stream, &queue) catch |e| {
            std.debug.print("[daemon] handle failed: {s}\n", .{@errorName(e)});
        };
        stream.close(io);
    }
}

fn workerLoop(queue: *Queue, io: std.Io) void {
    // GPA for per-play scratch allocations.
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();

    while (queue.pop(io)) |msg| {
        tts.play(gpa, io, msg) catch |e| {
            std.debug.print("[worker] play failed: {s}\n", .{@errorName(e)});
        };
    }
}

fn handleClient(arena: std.mem.Allocator, io: std.Io, stream: *std.Io.net.Stream, queue: *Queue) !void {
    var read_buf: [READ_BUF]u8 = undefined;
    var write_buf: [WRITE_BUF]u8 = undefined;

    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    const line = sr.interface.takeDelimiterExclusive('\n') catch |e| {
        try writeErr(&sw.interface, @errorName(e));
        return;
    };

    const msg = ipc.parseRequest(arena, line) catch |e| {
        try writeErr(&sw.interface, @errorName(e));
        return;
    };

    const id = queue.push(io, msg) catch |e| {
        try writeErr(&sw.interface, @errorName(e));
        return;
    };

    try sw.interface.print("OK\t{d}\n", .{id});
    try sw.interface.flush();
}

fn writeErr(w: *std.Io.Writer, msg: []const u8) !void {
    try w.print("ERR\t{s}\n", .{msg});
    try w.flush();
}
