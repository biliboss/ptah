// SPDX-License-Identifier: MIT OR Apache-2.0
// Wire protocol between agent-tts client and daemon.
//
// Transport: UNIX stream socket at $HOME/.cache/agent-tts/sock
//
// Request lines (one per connection):
//   ENQUEUE\t<engine>\t<voice>\t<rate>\t<text>\n   → enqueue a TTS item (v0.7+)
//   ENQUEUE\t<voice>\t<rate>\t<text>\n             → legacy form (v0.6 and older)
//   QUEUE\n                                        → list pending+playing items
//   SKIP\n                                         → skip current playing item
//   CLEAR\n                                        → mark all pending as skipped
//
// Backward compat: parseRequest peeks the first token after ENQUEUE. If it
// matches a known Engine tag (`say` / `piper`) the new 5-field shape applies,
// otherwise we fall through to the v0.6 4-field shape with engine=.say.
//
// Response lines:
//   OK\t<id>\n                           → enqueue/skip/clear ack
//   ERR\t<message>\n                     → error on any op
//   ITEM\t<id>\t<state>\t<engine>\t<voice>\t<rate>\t<text>\n  → QUEUE: one per item
//   END\n                                → QUEUE: end of list
//
// Text MUST NOT contain '\n' or '\t'. Client replaces them with ' '.

const std = @import("std");

pub const Op = enum { enqueue, queue, skip, clear };

pub const Engine = enum {
    say,
    piper,

    pub fn fromStr(s: []const u8) ?Engine {
        if (std.mem.eql(u8, s, "say")) return .say;
        if (std.mem.eql(u8, s, "piper")) return .piper;
        return null;
    }

    pub fn str(e: Engine) []const u8 {
        return @tagName(e);
    }
};

pub const Message = struct {
    engine: Engine = .say,
    voice: []const u8,
    rate: u32,
    text: []const u8,
};

pub const Request = union(Op) {
    enqueue: Message,
    queue: void,
    skip: void,
    clear: void,
};

pub fn socketPath(arena: std.mem.Allocator, io: std.Io, home: []const u8) ![]u8 {
    const dir = try std.fmt.allocPrint(arena, "{s}/.cache/agent-tts", .{home});
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    return try std.fmt.allocPrint(arena, "{s}/sock", .{dir});
}

pub fn queueDbPath(arena: std.mem.Allocator, io: std.Io, home: []const u8) ![]u8 {
    const dir = try std.fmt.allocPrint(arena, "{s}/.cache/agent-tts", .{home});
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    return try std.fmt.allocPrint(arena, "{s}/queue.db", .{dir});
}

pub fn sanitizeText(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    const buf = try arena.alloc(u8, raw.len);
    for (raw, 0..) |ch, i| {
        buf[i] = switch (ch) {
            '\n', '\t', '\r' => ' ',
            else => ch,
        };
    }
    return buf;
}

pub fn encodeEnqueue(arena: std.mem.Allocator, msg: Message) ![]u8 {
    return try std.fmt.allocPrint(
        arena,
        "ENQUEUE\t{s}\t{s}\t{d}\t{s}\n",
        .{ msg.engine.str(), msg.voice, msg.rate, msg.text },
    );
}

pub const ParseError = error{ Malformed, UnknownOp, InvalidRate };

pub fn parseRequest(arena: std.mem.Allocator, line: []const u8) ParseError!Request {
    var it = std.mem.splitScalar(u8, line, '\t');
    const op = it.next() orelse return error.Malformed;

    if (std.mem.eql(u8, op, "ENQUEUE")) {
        const first = it.next() orelse return error.Malformed;
        // v0.7 layout: ENQUEUE\t<engine>\t<voice>\t<rate>\t<text>
        // v0.6 layout: ENQUEUE\t<voice>\t<rate>\t<text>
        // Disambiguate by peeking the first field — Engine.fromStr resolves
        // when the layout is new, returns null otherwise.
        if (Engine.fromStr(first)) |engine| {
            const voice = it.next() orelse return error.Malformed;
            const rate_str = it.next() orelse return error.Malformed;
            const text = it.rest();
            if (text.len == 0) return error.Malformed;
            const rate = std.fmt.parseInt(u32, rate_str, 10) catch return error.InvalidRate;
            const voice_dup = arena.dupe(u8, voice) catch return error.Malformed;
            const text_dup = arena.dupe(u8, text) catch return error.Malformed;
            return .{ .enqueue = .{ .engine = engine, .voice = voice_dup, .rate = rate, .text = text_dup } };
        } else {
            // Legacy 4-field. `first` is the voice.
            const rate_str = it.next() orelse return error.Malformed;
            const text = it.rest();
            if (text.len == 0) return error.Malformed;
            const rate = std.fmt.parseInt(u32, rate_str, 10) catch return error.InvalidRate;
            const voice_dup = arena.dupe(u8, first) catch return error.Malformed;
            const text_dup = arena.dupe(u8, text) catch return error.Malformed;
            return .{ .enqueue = .{ .engine = .say, .voice = voice_dup, .rate = rate, .text = text_dup } };
        }
    }
    if (std.mem.eql(u8, op, "QUEUE")) return .queue;
    if (std.mem.eql(u8, op, "SKIP")) return .skip;
    if (std.mem.eql(u8, op, "CLEAR")) return .clear;
    return error.UnknownOp;
}

// ---- tests (v0.7) ----

test "parseRequest legacy 4-field ENQUEUE defaults engine=say" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tLuciana\t330\tOlá mundo");
    try std.testing.expect(req == .enqueue);
    try std.testing.expectEqual(Engine.say, req.enqueue.engine);
    try std.testing.expectEqualStrings("Luciana", req.enqueue.voice);
    try std.testing.expectEqual(@as(u32, 330), req.enqueue.rate);
    try std.testing.expectEqualStrings("Olá mundo", req.enqueue.text);
}

test "parseRequest new 5-field ENQUEUE with explicit say" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tsay\tLuciana\t330\tOlá");
    try std.testing.expectEqual(Engine.say, req.enqueue.engine);
    try std.testing.expectEqualStrings("Luciana", req.enqueue.voice);
    try std.testing.expectEqualStrings("Olá", req.enqueue.text);
}

test "parseRequest new 5-field ENQUEUE with piper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tpiper\tfaber\t330\tOlá");
    try std.testing.expectEqual(Engine.piper, req.enqueue.engine);
    try std.testing.expectEqualStrings("faber", req.enqueue.voice);
}

test "encodeEnqueue round-trips through parseRequest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: Message = .{ .engine = .piper, .voice = "faber", .rate = 220, .text = "Olá, tudo bem?" };
    const wire = try encodeEnqueue(a, original);
    // Strip trailing '\n'.
    const line = wire[0 .. wire.len - 1];
    const req = try parseRequest(a, line);
    try std.testing.expectEqual(Engine.piper, req.enqueue.engine);
    try std.testing.expectEqualStrings("faber", req.enqueue.voice);
    try std.testing.expectEqual(@as(u32, 220), req.enqueue.rate);
    try std.testing.expectEqualStrings("Olá, tudo bem?", req.enqueue.text);
}

test "Engine.fromStr accepts known engines only" {
    try std.testing.expectEqual(Engine.say, Engine.fromStr("say").?);
    try std.testing.expectEqual(Engine.piper, Engine.fromStr("piper").?);
    try std.testing.expect(Engine.fromStr("Luciana") == null);
    try std.testing.expect(Engine.fromStr("xtts") == null);
}
