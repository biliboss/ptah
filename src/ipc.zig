// SPDX-License-Identifier: MIT OR Apache-2.0
// Wire protocol between agent-tts client and daemon.
//
// Transport: UNIX stream socket at $HOME/.cache/agent-tts/sock
//
// Request lines (one per connection):
//   ENQUEUE\t<engine>\t<lang>\t<voice>\t<rate>\t<text>\n  → v1.1 6-field form
//   ENQUEUE\t<engine>\t<voice>\t<rate>\t<text>\n          → v0.7 5-field form
//   ENQUEUE\t<voice>\t<rate>\t<text>\n                    → v0.6 4-field form
//   QUEUE\n                                               → list items
//   SKIP\n                                                → skip current
//   CLEAR\n                                               → drop pending
//
// Backward compat (parseRequest):
//   1. Peek first token after ENQUEUE.
//      - Engine.fromStr matches      → new layout (v0.7 or v1.1)
//      - Not an engine               → legacy v0.6 (token is the voice)
//   2. In new layout, peek the second token.
//      - Lang.fromStr matches        → v1.1 6-field
//      - Not a lang                  → v0.7 5-field (token is the voice)
//
// Lang defaults to `.auto` when absent so v0.6/v0.7 clients keep working.
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

// v1.1 — Lang on Message. `auto` defers detection to the daemon (per-chunk
// via preproc.splitByLang). `pt` / `en` force a single voice end-to-end and
// skip detection. Kept distinct from `detect.Lang` because the IPC enum has
// exactly three callable values; the detector has four including `mixed`
// and `unknown`, which are daemon-internal.
pub const Lang = enum {
    auto,
    pt,
    en,

    pub fn fromStr(s: []const u8) ?Lang {
        if (std.mem.eql(u8, s, "auto")) return .auto;
        if (std.mem.eql(u8, s, "pt")) return .pt;
        if (std.mem.eql(u8, s, "en")) return .en;
        return null;
    }

    pub fn str(l: Lang) []const u8 {
        return @tagName(l);
    }
};

pub const Message = struct {
    engine: Engine = .say,
    lang: Lang = .auto,
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
        "ENQUEUE\t{s}\t{s}\t{s}\t{d}\t{s}\n",
        .{ msg.engine.str(), msg.lang.str(), msg.voice, msg.rate, msg.text },
    );
}

pub const ParseError = error{ Malformed, UnknownOp, InvalidRate };

pub fn parseRequest(arena: std.mem.Allocator, line: []const u8) ParseError!Request {
    var it = std.mem.splitScalar(u8, line, '\t');
    const op = it.next() orelse return error.Malformed;

    if (std.mem.eql(u8, op, "ENQUEUE")) {
        const first = it.next() orelse return error.Malformed;
        if (Engine.fromStr(first)) |engine| {
            // New layout (v0.7 or v1.1). Peek the next field for Lang.
            const second = it.next() orelse return error.Malformed;
            if (Lang.fromStr(second)) |lang| {
                // v1.1 6-field: ENQUEUE\t<engine>\t<lang>\t<voice>\t<rate>\t<text>
                const voice = it.next() orelse return error.Malformed;
                const rate_str = it.next() orelse return error.Malformed;
                const text = it.rest();
                if (text.len == 0) return error.Malformed;
                const rate = std.fmt.parseInt(u32, rate_str, 10) catch return error.InvalidRate;
                const voice_dup = arena.dupe(u8, voice) catch return error.Malformed;
                const text_dup = arena.dupe(u8, text) catch return error.Malformed;
                return .{ .enqueue = .{
                    .engine = engine,
                    .lang = lang,
                    .voice = voice_dup,
                    .rate = rate,
                    .text = text_dup,
                } };
            }
            // v0.7 5-field: `second` is the voice, lang defaults to .auto.
            const rate_str = it.next() orelse return error.Malformed;
            const text = it.rest();
            if (text.len == 0) return error.Malformed;
            const rate = std.fmt.parseInt(u32, rate_str, 10) catch return error.InvalidRate;
            const voice_dup = arena.dupe(u8, second) catch return error.Malformed;
            const text_dup = arena.dupe(u8, text) catch return error.Malformed;
            return .{ .enqueue = .{
                .engine = engine,
                .lang = .auto,
                .voice = voice_dup,
                .rate = rate,
                .text = text_dup,
            } };
        } else {
            // Legacy v0.6 4-field. `first` is the voice.
            const rate_str = it.next() orelse return error.Malformed;
            const text = it.rest();
            if (text.len == 0) return error.Malformed;
            const rate = std.fmt.parseInt(u32, rate_str, 10) catch return error.InvalidRate;
            const voice_dup = arena.dupe(u8, first) catch return error.Malformed;
            const text_dup = arena.dupe(u8, text) catch return error.Malformed;
            return .{ .enqueue = .{
                .engine = .say,
                .lang = .auto,
                .voice = voice_dup,
                .rate = rate,
                .text = text_dup,
            } };
        }
    }
    if (std.mem.eql(u8, op, "QUEUE")) return .queue;
    if (std.mem.eql(u8, op, "SKIP")) return .skip;
    if (std.mem.eql(u8, op, "CLEAR")) return .clear;
    return error.UnknownOp;
}

// ---- tests (v0.7 + v1.1) ----

test "parseRequest legacy v0.6 4-field ENQUEUE defaults engine=say lang=auto" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tLuciana\t330\tOlá mundo");
    try std.testing.expect(req == .enqueue);
    try std.testing.expectEqual(Engine.say, req.enqueue.engine);
    try std.testing.expectEqual(Lang.auto, req.enqueue.lang);
    try std.testing.expectEqualStrings("Luciana", req.enqueue.voice);
    try std.testing.expectEqual(@as(u32, 330), req.enqueue.rate);
    try std.testing.expectEqualStrings("Olá mundo", req.enqueue.text);
}

test "parseRequest v0.7 5-field ENQUEUE with explicit say + default lang=auto" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tsay\tLuciana\t330\tOlá");
    try std.testing.expectEqual(Engine.say, req.enqueue.engine);
    try std.testing.expectEqual(Lang.auto, req.enqueue.lang);
    try std.testing.expectEqualStrings("Luciana", req.enqueue.voice);
    try std.testing.expectEqualStrings("Olá", req.enqueue.text);
}

test "parseRequest v0.7 5-field ENQUEUE with piper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tpiper\tfaber\t330\tOlá");
    try std.testing.expectEqual(Engine.piper, req.enqueue.engine);
    try std.testing.expectEqual(Lang.auto, req.enqueue.lang);
    try std.testing.expectEqualStrings("faber", req.enqueue.voice);
}

test "parseRequest v1.1 6-field ENQUEUE with explicit lang=pt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tpiper\tpt\tfaber\t330\tOlá mundo");
    try std.testing.expectEqual(Engine.piper, req.enqueue.engine);
    try std.testing.expectEqual(Lang.pt, req.enqueue.lang);
    try std.testing.expectEqualStrings("faber", req.enqueue.voice);
    try std.testing.expectEqualStrings("Olá mundo", req.enqueue.text);
}

test "parseRequest v1.1 6-field ENQUEUE with lang=en" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tpiper\ten\tamy\t330\tHello world");
    try std.testing.expectEqual(Lang.en, req.enqueue.lang);
    try std.testing.expectEqualStrings("amy", req.enqueue.voice);
}

test "parseRequest v1.1 6-field ENQUEUE with lang=auto explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tpiper\tauto\tfaber\t330\tOlá");
    try std.testing.expectEqual(Lang.auto, req.enqueue.lang);
}

test "encodeEnqueue v1.1 round-trips through parseRequest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: Message = .{
        .engine = .piper,
        .lang = .en,
        .voice = "amy",
        .rate = 220,
        .text = "Hello, how are you?",
    };
    const wire = try encodeEnqueue(a, original);
    const line = wire[0 .. wire.len - 1];
    const req = try parseRequest(a, line);
    try std.testing.expectEqual(Engine.piper, req.enqueue.engine);
    try std.testing.expectEqual(Lang.en, req.enqueue.lang);
    try std.testing.expectEqualStrings("amy", req.enqueue.voice);
    try std.testing.expectEqual(@as(u32, 220), req.enqueue.rate);
    try std.testing.expectEqualStrings("Hello, how are you?", req.enqueue.text);
}

test "Engine.fromStr accepts known engines only" {
    try std.testing.expectEqual(Engine.say, Engine.fromStr("say").?);
    try std.testing.expectEqual(Engine.piper, Engine.fromStr("piper").?);
    try std.testing.expect(Engine.fromStr("Luciana") == null);
    try std.testing.expect(Engine.fromStr("xtts") == null);
}

test "Lang.fromStr accepts known langs only" {
    try std.testing.expectEqual(Lang.auto, Lang.fromStr("auto").?);
    try std.testing.expectEqual(Lang.pt, Lang.fromStr("pt").?);
    try std.testing.expectEqual(Lang.en, Lang.fromStr("en").?);
    try std.testing.expect(Lang.fromStr("fr") == null);
    try std.testing.expect(Lang.fromStr("Luciana") == null);
}
