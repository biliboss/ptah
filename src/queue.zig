// Thread-safe FIFO queue of TTS messages.
//
// One producer (daemon accept loop) — many enqueue sources are serialized via
// the mutex. One consumer (worker thread) — pop blocks on condition variable
// when empty. close() drains and unblocks the consumer for clean shutdown.

const std = @import("std");
const ipc = @import("ipc.zig");

pub const Queue = struct {
    arena: std.mem.Allocator,
    mu: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    items: std.ArrayList(ipc.Message) = .empty,
    closed: bool = false,
    next_id: u64 = 1,

    pub fn push(q: *Queue, io: std.Io, msg: ipc.Message) !u64 {
        try q.mu.lock(io);
        defer q.mu.unlock(io);
        try q.items.append(q.arena, msg);
        const id = q.next_id;
        q.next_id += 1;
        q.cond.signal(io);
        return id;
    }

    pub fn pop(q: *Queue, io: std.Io) ?ipc.Message {
        q.mu.lockUncancelable(io);
        defer q.mu.unlock(io);
        while (q.items.items.len == 0 and !q.closed) {
            q.cond.waitUncancelable(io, &q.mu);
        }
        if (q.items.items.len == 0) return null; // closed
        return q.items.orderedRemove(0);
    }

    pub fn close(q: *Queue, io: std.Io) void {
        q.mu.lockUncancelable(io);
        defer q.mu.unlock(io);
        q.closed = true;
        q.cond.broadcast(io);
    }

    pub fn pending(q: *Queue, io: std.Io) usize {
        q.mu.lockUncancelable(io);
        defer q.mu.unlock(io);
        return q.items.items.len;
    }
};
