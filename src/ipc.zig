// Wire protocol between agent-tts client and daemon.
//
// Transport: UNIX stream socket at $HOME/.cache/agent-tts/sock
//
// Request line:
//   ENQUEUE\t<voice>\t<rate>\t<text>\n
//
// Response line:
//   OK\t<id>\n
//   ERR\t<message>\n
//
// Text MUST NOT contain '\n' or '\t'. Client replaces them with ' '.

const std = @import("std");

pub const Message = struct {
    voice: []const u8,
    rate: u32,
    text: []const u8,
};

pub fn socketPath(arena: std.mem.Allocator, io: std.Io, home: []const u8) ![]u8 {
    const dir = try std.fmt.allocPrint(arena, "{s}/.cache/agent-tts", .{home});
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    return try std.fmt.allocPrint(arena, "{s}/sock", .{dir});
}

pub fn sanitizeText(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    const buf = try arena.alloc(u8, raw.len);
    for (raw, 0..) |c, i| {
        buf[i] = switch (c) {
            '\n', '\t', '\r' => ' ',
            else => c,
        };
    }
    return buf;
}

pub fn encodeRequest(arena: std.mem.Allocator, msg: Message) ![]u8 {
    return try std.fmt.allocPrint(arena, "ENQUEUE\t{s}\t{d}\t{s}\n", .{ msg.voice, msg.rate, msg.text });
}

pub const ParseError = error{ Malformed, UnknownOp, InvalidRate };

pub fn parseRequest(arena: std.mem.Allocator, line: []const u8) ParseError!Message {
    var it = std.mem.splitScalar(u8, line, '\t');
    const op = it.next() orelse return error.Malformed;
    if (!std.mem.eql(u8, op, "ENQUEUE")) return error.UnknownOp;
    const voice = it.next() orelse return error.Malformed;
    const rate_str = it.next() orelse return error.Malformed;
    const text = it.rest();
    if (text.len == 0) return error.Malformed;
    const rate = std.fmt.parseInt(u32, rate_str, 10) catch return error.InvalidRate;
    // Dupe into arena so message survives past the read buffer.
    const voice_dup = arena.dupe(u8, voice) catch return error.Malformed;
    const text_dup = arena.dupe(u8, text) catch return error.Malformed;
    return .{ .voice = voice_dup, .rate = rate, .text = text_dup };
}
