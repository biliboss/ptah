// SPDX-License-Identifier: MIT OR Apache-2.0
// Model Context Protocol (MCP) server — v1.5.
//
// Single subcommand: `agent-tts mcp` opens a JSON-RPC 2.0 loop over
// stdin/stdout. Newline-delimited JSON, NOT LSP-style Content-Length
// headers — that's the MCP stdio transport convention.
//
// Scope (tools only, MCP 2024-11-05 spec):
//
//   initialize                → capability handshake (tools.listChanged = false)
//   notifications/initialized → ack, no response
//   tools/list                → 6 tools (say / queue / skip / clear / voices / say_stream)
//   tools/call                → dispatch one of the 6
//
// The base 5 tools are thin shims over the same UNIX socket the CLI uses
// (see `client.zig`): say / queue / skip / clear / voices. No new wire
// protocol, no daemon changes.
//
// v1.7 adds `say_stream(stream_id, chunk, final?)` — an incremental
// counterpart to `say`. State for in-flight streams lives in a process-
// scoped hashmap keyed by `stream_id`. Each call appends `chunk` into the
// stream's `preproc.IncrementalChunker`; completed sentences are
// forwarded to the daemon via `client.enqueueLine`. `final=true` flushes
// the chunker, emits any remainder, and drops the stream from the map.
//
// Honest deferrals: prompts/, resources/, sampling, listChanged
// notifications, server-initiated progress. Those land when somebody
// actually asks for them. Voice agents only need tools.

const std = @import("std");
const json = std.json;

const ipc = @import("ipc.zig");
const client = @import("client.zig");
const preproc = @import("preproc.zig");

pub const VERSION = "1.7.0";
pub const PROTOCOL_VERSION = "2024-11-05";

const READ_BUF = 256 * 1024; // long agent monologues hit ~8 KB after escaping
const WRITE_BUF = 64 * 1024;

// v1.7 — in-flight say_stream sessions. Keyed by `stream_id` (caller-
// chosen string). Each session owns an IncrementalChunker plus a long-
// lived arena to back the chunker's buffer + dup'd chunk slices. When
// `final=true` arrives the session flushes and is dropped from the map.
//
// Scope: process-local. A new `agent-tts mcp` process starts with an
// empty map. Multiple clients sharing one MCP process see each other's
// stream_ids — collisions are caller's responsibility (treat stream_id
// like a UUID).
const StreamSession = struct {
    chunker: preproc.IncrementalChunker,
    arena_state: *std.heap.ArenaAllocator,

    fn deinit(self: *StreamSession) void {
        // The chunker's buffer lives in arena_state — arena_deinit frees it.
        // The arena_state struct itself lives on the heap (gpa); freed below.
        const gpa = std.heap.smp_allocator;
        self.arena_state.deinit();
        gpa.destroy(self.arena_state);
    }
};

var stream_sessions: std.StringHashMapUnmanaged(StreamSession) = .empty;

// stdio loop. Exits on EOF (client disconnect) or a malformed line that
// is not recoverable. Every JSON-RPC parse error is reported back as an
// error response when an id is recoverable, otherwise logged to stderr.
pub fn run(arena: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    var read_buf: [READ_BUF]u8 = undefined;
    var write_buf: [WRITE_BUF]u8 = undefined;

    var stdin = std.Io.File.stdin().readerStreaming(io, &read_buf);
    var stdout = std.Io.File.stdout().writerStreaming(io, &write_buf);
    const r = &stdin.interface;
    const w = &stdout.interface;

    while (true) {
        // takeDelimiterInclusive returns the slice INCLUDING the trailing
        // '\n' AND consumes it. The exclusive variant leaves the delimiter
        // in the buffer, so a re-call would loop forever on the same byte.
        const raw = r.takeDelimiterInclusive('\n') catch |e| switch (e) {
            error.EndOfStream => return,
            error.StreamTooLong => {
                std.debug.print("[mcp] line exceeds {d}B — closing\n", .{READ_BUF});
                return;
            },
            else => return e,
        };
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
        if (line.len == 0) continue;

        // Per-request arena so we don't leak parsed Value trees between
        // calls. The outer arena is shared across the entire process,
        // which would balloon under a busy agent.
        var req_arena = std.heap.ArenaAllocator.init(arena);
        defer req_arena.deinit();

        const response = handleLine(req_arena.allocator(), io, home, line) catch |e| blk: {
            std.debug.print("[mcp] handle error: {s}\n", .{@errorName(e)});
            break :blk null;
        };
        if (response) |resp| {
            try w.writeAll(resp);
            try w.writeAll("\n");
            try w.flush();
        }
    }
}

// Returns null when the request is a notification (no response expected).
// Returns a freshly-allocated JSON string (owned by `a`) otherwise.
fn handleLine(a: std.mem.Allocator, io: std.Io, home: []const u8, line: []const u8) !?[]const u8 {
    const parsed = json.parseFromSliceLeaky(json.Value, a, line, .{}) catch {
        return try errorResponse(a, .{ .null = {} }, -32700, "Parse error");
    };
    if (parsed != .object) {
        return try errorResponse(a, .{ .null = {} }, -32600, "Invalid Request");
    }
    const req_obj = parsed.object;

    const method_val = req_obj.get("method") orelse {
        return try errorResponse(a, .{ .null = {} }, -32600, "Invalid Request");
    };
    if (method_val != .string) {
        return try errorResponse(a, .{ .null = {} }, -32600, "Invalid Request");
    }
    const method = method_val.string;

    // id may be absent (notification), null, integer or string. We pass
    // it through verbatim into the response so the client can correlate.
    const id_val: json.Value = req_obj.get("id") orelse .{ .null = {} };
    const is_notification = !req_obj.contains("id");

    const params: json.Value = req_obj.get("params") orelse .{ .null = {} };

    if (std.mem.eql(u8, method, "initialize")) {
        return try buildInitializeResponse(a, id_val);
    }
    if (std.mem.eql(u8, method, "notifications/initialized")) {
        return null; // notification — no response
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        return try buildToolsListResponse(a, id_val);
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        return try buildToolsCallResponse(a, io, home, id_val, params);
    }
    if (std.mem.eql(u8, method, "ping")) {
        // MCP ping — empty result.
        return try okResponse(a, id_val, .{ .object = .empty });
    }

    if (is_notification) return null;
    return try errorResponse(a, id_val, -32601, "Method not found");
}

// ---- small JSON-builder helpers ----------------------------------------
//
// json.ObjectMap is `ArrayHashMap` so every `put` needs the allocator.
// Wrapping that in `obj()` / `kv()` keeps the call sites readable.

fn obj(a: std.mem.Allocator, pairs: []const struct { []const u8, json.Value }) !json.Value {
    var m: json.ObjectMap = .empty;
    for (pairs) |p| try m.put(a, p[0], p[1]);
    return .{ .object = m };
}

fn arr(a: std.mem.Allocator, items: []const json.Value) !json.Value {
    var list: json.Array = .init(a);
    try list.appendSlice(items);
    return .{ .array = list };
}

fn str(s: []const u8) json.Value {
    return .{ .string = s };
}

fn int(n: i64) json.Value {
    return .{ .integer = n };
}

fn boolean(b: bool) json.Value {
    return .{ .bool = b };
}

// ---- response builders --------------------------------------------------

fn buildInitializeResponse(a: std.mem.Allocator, id: json.Value) ![]const u8 {
    const server_info = try obj(a, &.{
        .{ "name", str("agent-tts") },
        .{ "version", str(VERSION) },
    });
    const tools_cap = try obj(a, &.{
        .{ "listChanged", boolean(false) },
    });
    const caps = try obj(a, &.{
        .{ "tools", tools_cap },
    });
    const result = try obj(a, &.{
        .{ "protocolVersion", str(PROTOCOL_VERSION) },
        .{ "capabilities", caps },
        .{ "serverInfo", server_info },
    });
    return try okResponse(a, id, result);
}

fn buildToolsListResponse(a: std.mem.Allocator, id: json.Value) ![]const u8 {
    const tools = try arr(a, &.{
        try toolDescriptor(a, "say", "Enqueue Pt-BR TTS on the running daemon. Returns the queue item id.", try saySchema(a)),
        try toolDescriptor(a, "queue", "List items currently in the TTS queue (pending + playing).", try emptySchema(a)),
        try toolDescriptor(a, "skip", "Skip the currently playing TTS item. Returns the skipped id (0 = nothing playing).", try skipSchema(a)),
        try toolDescriptor(a, "clear", "Drop all pending TTS items. Returns the number dropped.", try emptySchema(a)),
        try toolDescriptor(a, "voices", "List installed voices for `say` and any piper ONNX models in ~/.cache/agent-tts/voices/.", try emptySchema(a)),
        try toolDescriptor(a, "say_stream", "Stream-feed Pt-BR TTS chunk-by-chunk. The server buffers bytes per stream_id, emits sentences to the daemon as terminators arrive, and flushes any remainder when final=true. Returns the count of sentences enqueued by this call.", try sayStreamSchema(a)),
    });
    const result = try obj(a, &.{
        .{ "tools", tools },
    });
    return try okResponse(a, id, result);
}

fn toolDescriptor(a: std.mem.Allocator, name: []const u8, desc: []const u8, schema: json.Value) !json.Value {
    return try obj(a, &.{
        .{ "name", str(name) },
        .{ "description", str(desc) },
        .{ "inputSchema", schema },
    });
}

fn emptySchema(a: std.mem.Allocator) !json.Value {
    const props = try obj(a, &.{});
    return try obj(a, &.{
        .{ "type", str("object") },
        .{ "properties", props },
    });
}

fn saySchema(a: std.mem.Allocator) !json.Value {
    const engine_enum = try arr(a, &.{ str("say"), str("piper") });

    const text_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("Pt-BR text to speak. Newlines/tabs are sanitized.") },
    });
    const engine_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("say (macOS voice) or piper (neural ONNX). Default: piper if available.") },
        .{ "enum", engine_enum },
    });
    const voice_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("Voice name. say defaults to Luciana, piper to faber.") },
    });
    const rate_prop = try obj(a, &.{
        .{ "type", str("integer") },
        .{ "description", str("Words per minute (default 330, ignored by piper).") },
    });

    const props = try obj(a, &.{
        .{ "text", text_prop },
        .{ "engine", engine_prop },
        .{ "voice", voice_prop },
        .{ "rate", rate_prop },
    });
    const required = try arr(a, &.{str("text")});

    return try obj(a, &.{
        .{ "type", str("object") },
        .{ "properties", props },
        .{ "required", required },
    });
}

fn sayStreamSchema(a: std.mem.Allocator) !json.Value {
    const engine_enum = try arr(a, &.{ str("say"), str("piper") });

    const stream_id_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("Caller-chosen stream identifier. Reuse across calls of the same stream; treat like a UUID to avoid collisions across MCP clients.") },
    });
    const chunk_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("Bytes to feed. Newlines/tabs sanitized before forwarding to the daemon. May be partial — sentences emit only as terminators (. ! ? \\n) arrive.") },
    });
    const final_prop = try obj(a, &.{
        .{ "type", str("boolean") },
        .{ "description", str("When true, flush any remainder as a final chunk and drop the stream. Default: false.") },
    });
    const engine_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("TTS backend for this stream's sentences. Set on the first call; subsequent calls keep the stream's initial choice. Default: piper if available.") },
        .{ "enum", engine_enum },
    });
    const voice_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("Voice name. say defaults to Luciana, piper to faber.") },
    });
    const rate_prop = try obj(a, &.{
        .{ "type", str("integer") },
        .{ "description", str("Words per minute (default 330, ignored by piper).") },
    });

    const props = try obj(a, &.{
        .{ "stream_id", stream_id_prop },
        .{ "chunk", chunk_prop },
        .{ "final", final_prop },
        .{ "engine", engine_prop },
        .{ "voice", voice_prop },
        .{ "rate", rate_prop },
    });
    const required = try arr(a, &.{ str("stream_id"), str("chunk") });

    return try obj(a, &.{
        .{ "type", str("object") },
        .{ "properties", props },
        .{ "required", required },
    });
}

fn skipSchema(a: std.mem.Allocator) !json.Value {
    const id_prop = try obj(a, &.{
        .{ "type", str("integer") },
        .{ "description", str("Optional id of the item to skip. Currently ignored — the daemon always skips the playing item.") },
    });
    const props = try obj(a, &.{
        .{ "id", id_prop },
    });
    return try obj(a, &.{
        .{ "type", str("object") },
        .{ "properties", props },
    });
}

// ---- tools/call dispatch -----------------------------------------------

fn buildToolsCallResponse(
    a: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    id: json.Value,
    params: json.Value,
) ![]const u8 {
    if (params != .object) {
        return try errorResponse(a, id, -32602, "params must be an object");
    }
    const p = params.object;

    const name_val = p.get("name") orelse {
        return try errorResponse(a, id, -32602, "params.name missing");
    };
    if (name_val != .string) {
        return try errorResponse(a, id, -32602, "params.name must be a string");
    }
    const tool = name_val.string;

    const empty_obj: json.Value = .{ .object = .empty };
    const args_val: json.Value = p.get("arguments") orelse empty_obj;

    if (std.mem.eql(u8, tool, "say")) return callSay(a, io, home, id, args_val);
    if (std.mem.eql(u8, tool, "queue")) return callQueue(a, io, home, id);
    if (std.mem.eql(u8, tool, "skip")) return callSkip(a, io, home, id);
    if (std.mem.eql(u8, tool, "clear")) return callClear(a, io, home, id);
    if (std.mem.eql(u8, tool, "voices")) return callVoices(a, io, home, id);
    if (std.mem.eql(u8, tool, "say_stream")) return callSayStream(a, io, home, id, args_val);

    return try toolErrorResponse(a, id, "unknown tool");
}

fn callSay(
    a: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    id: json.Value,
    args: json.Value,
) ![]const u8 {
    if (args != .object) return try toolErrorResponse(a, id, "arguments must be an object");
    const ao = args.object;

    const text_val = ao.get("text") orelse return try toolErrorResponse(a, id, "text is required");
    if (text_val != .string) return try toolErrorResponse(a, id, "text must be a string");
    const text = text_val.string;

    var engine: ipc.Engine = .piper;
    if (ao.get("engine")) |e| {
        if (e != .string) return try toolErrorResponse(a, id, "engine must be a string");
        engine = ipc.Engine.fromStr(e.string) orelse return try toolErrorResponse(a, id, "engine must be 'say' or 'piper'");
    }

    var voice: []const u8 = switch (engine) {
        .say => client.DEFAULT_VOICE,
        .piper => "faber",
        .cloned => "",
    };
    if (ao.get("voice")) |v| {
        if (v != .string) return try toolErrorResponse(a, id, "voice must be a string");
        voice = v.string;
    }

    var rate: u32 = client.DEFAULT_RATE;
    if (ao.get("rate")) |r| {
        if (r != .integer) return try toolErrorResponse(a, id, "rate must be an integer");
        if (r.integer <= 0 or r.integer > 1000) return try toolErrorResponse(a, id, "rate out of range (1..1000)");
        rate = @intCast(r.integer);
    }

    const id_str = client.enqueueLine(a, io, home, engine, voice, rate, text) catch |e| switch (e) {
        error.DaemonUnreachable => return try toolErrorResponse(a, id, "daemon not running — start with `agent-tts daemon` or `agent-tts daemon install`"),
        error.DaemonError => return try toolErrorResponse(a, id, "daemon returned an error"),
        error.UnexpectedResponse => return try toolErrorResponse(a, id, "daemon returned an unexpected response"),
        else => return e,
    };

    const payload = try obj(a, &.{
        .{ "id", str(id_str) },
    });
    const text_block = try formatJsonAsText(a, payload);
    return try toolTextResponse(a, id, text_block);
}

fn callQueue(a: std.mem.Allocator, io: std.Io, home: []const u8, id: json.Value) ![]const u8 {
    const items = client.queueLines(a, io, home) catch |e| switch (e) {
        error.DaemonUnreachable => return try toolErrorResponse(a, id, "daemon not running"),
        error.DaemonError => return try toolErrorResponse(a, id, "daemon error"),
        else => return e,
    };

    var list: json.Array = .init(a);
    for (items) |it| {
        const item_obj = try obj(a, &.{
            .{ "id", str(it.id) },
            .{ "state", str(it.state) },
            .{ "engine", str(it.engine) },
            .{ "voice", str(it.voice) },
            .{ "rate", str(it.rate) },
            .{ "text", str(it.text) },
        });
        try list.append(item_obj);
    }
    const payload = try obj(a, &.{
        .{ "items", json.Value{ .array = list } },
    });
    const text_block = try formatJsonAsText(a, payload);
    return try toolTextResponse(a, id, text_block);
}

fn callSkip(a: std.mem.Allocator, io: std.Io, home: []const u8, id: json.Value) ![]const u8 {
    const skipped = client.skipOp(a, io, home) catch |e| switch (e) {
        error.DaemonUnreachable => return try toolErrorResponse(a, id, "daemon not running"),
        error.DaemonError => return try toolErrorResponse(a, id, "daemon error"),
        error.UnexpectedResponse => return try toolErrorResponse(a, id, "daemon unexpected response"),
        else => return e,
    };
    const payload = try obj(a, &.{
        .{ "skipped_id", int(@intCast(skipped)) },
    });
    const text_block = try formatJsonAsText(a, payload);
    return try toolTextResponse(a, id, text_block);
}

fn callClear(a: std.mem.Allocator, io: std.Io, home: []const u8, id: json.Value) ![]const u8 {
    const n = client.clearOp(a, io, home) catch |e| switch (e) {
        error.DaemonUnreachable => return try toolErrorResponse(a, id, "daemon not running"),
        error.DaemonError => return try toolErrorResponse(a, id, "daemon error"),
        error.UnexpectedResponse => return try toolErrorResponse(a, id, "daemon unexpected response"),
        else => return e,
    };
    const payload = try obj(a, &.{
        .{ "cleared_count", int(@intCast(n)) },
    });
    const text_block = try formatJsonAsText(a, payload);
    return try toolTextResponse(a, id, text_block);
}

// v1.7 — say_stream. Per-stream state lives in `stream_sessions`, keyed by
// the caller's `stream_id`. Each call:
//   1. Resolves the session (creating one on first sight).
//   2. Feeds `chunk` into the IncrementalChunker.
//   3. Forwards each emitted sentence to the daemon via enqueueLine.
//   4. If `final=true`, flushes the remainder and drops the session.
//
// We hold engine/voice/rate per-session (locked in on first feed) so a
// caller can switch the params on a new stream_id without affecting an
// in-flight stream. The map keys + session state allocator is gpa
// (smp_allocator) — survives across per-request arenas.
fn callSayStream(
    a: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    id: json.Value,
    args: json.Value,
) ![]const u8 {
    if (args != .object) return try toolErrorResponse(a, id, "arguments must be an object");
    const ao = args.object;

    const stream_id_val = ao.get("stream_id") orelse return try toolErrorResponse(a, id, "stream_id is required");
    if (stream_id_val != .string) return try toolErrorResponse(a, id, "stream_id must be a string");
    const stream_id = stream_id_val.string;
    if (stream_id.len == 0) return try toolErrorResponse(a, id, "stream_id must be non-empty");

    const chunk_val = ao.get("chunk") orelse return try toolErrorResponse(a, id, "chunk is required");
    if (chunk_val != .string) return try toolErrorResponse(a, id, "chunk must be a string");
    const chunk_text = chunk_val.string;

    var final_flag: bool = false;
    if (ao.get("final")) |f| {
        if (f != .bool) return try toolErrorResponse(a, id, "final must be a boolean");
        final_flag = f.bool;
    }

    var engine: ipc.Engine = .piper;
    if (ao.get("engine")) |e| {
        if (e != .string) return try toolErrorResponse(a, id, "engine must be a string");
        engine = ipc.Engine.fromStr(e.string) orelse return try toolErrorResponse(a, id, "engine must be 'say' or 'piper'");
    }
    var voice: []const u8 = switch (engine) {
        .say => client.DEFAULT_VOICE,
        .piper => "faber",
        .cloned => "",
    };
    if (ao.get("voice")) |v| {
        if (v != .string) return try toolErrorResponse(a, id, "voice must be a string");
        voice = v.string;
    }
    var rate: u32 = client.DEFAULT_RATE;
    if (ao.get("rate")) |r| {
        if (r != .integer) return try toolErrorResponse(a, id, "rate must be an integer");
        if (r.integer <= 0 or r.integer > 1000) return try toolErrorResponse(a, id, "rate out of range (1..1000)");
        rate = @intCast(r.integer);
    }

    // Resolve / create the session. Map storage allocator is gpa so the
    // entry outlives the per-request arena `a`.
    const gpa = std.heap.smp_allocator;
    const gop = stream_sessions.getOrPut(gpa, stream_id) catch return try toolErrorResponse(a, id, "stream session allocation failed");
    if (!gop.found_existing) {
        // Dup the key into gpa so the map owns it independently of the
        // request arena (the request arena dies when this handler returns).
        const key_dup = gpa.dupe(u8, stream_id) catch {
            _ = stream_sessions.remove(stream_id);
            return try toolErrorResponse(a, id, "stream session key dup failed");
        };
        gop.key_ptr.* = key_dup;
        const arena_box = gpa.create(std.heap.ArenaAllocator) catch {
            gpa.free(key_dup);
            _ = stream_sessions.remove(stream_id);
            return try toolErrorResponse(a, id, "stream session arena alloc failed");
        };
        arena_box.* = std.heap.ArenaAllocator.init(gpa);
        gop.value_ptr.* = .{
            .chunker = .{},
            .arena_state = arena_box,
        };
    }
    const session = gop.value_ptr;
    const session_arena = session.arena_state.allocator();

    var n_enqueued: u32 = 0;

    // Feed any non-empty chunk.
    if (chunk_text.len > 0) {
        const emitted = session.chunker.feed(session_arena, chunk_text) catch {
            return try toolErrorResponse(a, id, "chunker feed failed");
        };
        for (emitted) |c| {
            _ = client.enqueueLine(a, io, home, engine, voice, rate, c.text) catch |e| switch (e) {
                error.DaemonUnreachable => return try toolErrorResponse(a, id, "daemon not running — start with `agent-tts daemon` or `agent-tts daemon install`"),
                error.DaemonError => return try toolErrorResponse(a, id, "daemon returned an error mid-stream"),
                error.UnexpectedResponse => return try toolErrorResponse(a, id, "daemon returned an unexpected response mid-stream"),
                else => return e,
            };
            n_enqueued += 1;
        }
    }

    if (final_flag) {
        const tail = session.chunker.flush(session_arena) catch {
            return try toolErrorResponse(a, id, "chunker flush failed");
        };
        for (tail) |c| {
            _ = client.enqueueLine(a, io, home, engine, voice, rate, c.text) catch |e| switch (e) {
                error.DaemonUnreachable => return try toolErrorResponse(a, id, "daemon not running"),
                error.DaemonError => return try toolErrorResponse(a, id, "daemon returned an error on final flush"),
                error.UnexpectedResponse => return try toolErrorResponse(a, id, "daemon returned an unexpected response on final flush"),
                else => return e,
            };
            n_enqueued += 1;
        }
        // Drop the session. Free the key and the arena_state.
        const key_dup = gop.key_ptr.*;
        session.deinit();
        _ = stream_sessions.remove(stream_id);
        gpa.free(key_dup);
    }

    const payload = try obj(a, &.{
        .{ "enqueued_count", int(@intCast(n_enqueued)) },
        .{ "final", boolean(final_flag) },
    });
    const text_block = try formatJsonAsText(a, payload);
    return try toolTextResponse(a, id, text_block);
}

fn callVoices(a: std.mem.Allocator, io: std.Io, home: []const u8, id: json.Value) ![]const u8 {
    var list: json.Array = .init(a);

    // Hardcoded `say` voices we ship as defaults. Anything else the user
    // has installed shows up via `say -v ?` but enumerating that would
    // require spawning say; defer to v1.6.
    try list.append(try voiceEntry(a, "say", "Luciana", "Pt-BR Premium voice (default for say)"));
    try list.append(try voiceEntry(a, "say", "Felipe", "Pt-BR Premium male voice"));

    // Piper voices: ONNX files in ~/.cache/agent-tts/voices/.
    const voices_dir = try std.fmt.allocPrint(a, "{s}/.cache/agent-tts/voices", .{home});
    addPiperVoices(a, io, voices_dir, &list) catch {};

    const payload = try obj(a, &.{
        .{ "voices", json.Value{ .array = list } },
    });
    const text_block = try formatJsonAsText(a, payload);
    return try toolTextResponse(a, id, text_block);
}

fn voiceEntry(a: std.mem.Allocator, engine: []const u8, name: []const u8, desc: []const u8) !json.Value {
    return try obj(a, &.{
        .{ "engine", str(engine) },
        .{ "name", str(name) },
        .{ "description", str(desc) },
    });
}

fn addPiperVoices(a: std.mem.Allocator, io: std.Io, dir_path: []const u8, list: *json.Array) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".onnx")) continue;
        const name = try a.dupe(u8, entry.name[0 .. entry.name.len - ".onnx".len]);
        const desc = try std.fmt.allocPrint(a, "piper ONNX voice (file: {s})", .{entry.name});
        try list.append(try voiceEntry(a, "piper", name, desc));
    }
}

// ---- JSON-RPC envelopes -------------------------------------------------

fn okResponse(a: std.mem.Allocator, id: json.Value, result: json.Value) ![]const u8 {
    const env = try obj(a, &.{
        .{ "jsonrpc", str("2.0") },
        .{ "id", id },
        .{ "result", result },
    });
    return try json.Stringify.valueAlloc(a, env, .{});
}

fn errorResponse(a: std.mem.Allocator, id: json.Value, code: i64, message: []const u8) ![]const u8 {
    const err_obj = try obj(a, &.{
        .{ "code", int(code) },
        .{ "message", str(message) },
    });
    const env = try obj(a, &.{
        .{ "jsonrpc", str("2.0") },
        .{ "id", id },
        .{ "error", err_obj },
    });
    return try json.Stringify.valueAlloc(a, env, .{});
}

// tools/call results carry isError + content. content is a list of
// `{ type: "text", text: "..." }` blocks per the spec.
fn toolTextResponse(a: std.mem.Allocator, id: json.Value, text: []const u8) ![]const u8 {
    const block = try obj(a, &.{
        .{ "type", str("text") },
        .{ "text", str(text) },
    });
    const content = try arr(a, &.{block});
    const result = try obj(a, &.{
        .{ "content", content },
        .{ "isError", boolean(false) },
    });
    return try okResponse(a, id, result);
}

fn toolErrorResponse(a: std.mem.Allocator, id: json.Value, text: []const u8) ![]const u8 {
    const block = try obj(a, &.{
        .{ "type", str("text") },
        .{ "text", str(text) },
    });
    const content = try arr(a, &.{block});
    const result = try obj(a, &.{
        .{ "content", content },
        .{ "isError", boolean(true) },
    });
    return try okResponse(a, id, result);
}

fn formatJsonAsText(a: std.mem.Allocator, v: json.Value) ![]const u8 {
    return try json.Stringify.valueAlloc(a, v, .{});
}

// ---- tests --------------------------------------------------------------

test "parse initialize request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0"}}}
    ;
    const parsed = try json.parseFromSliceLeaky(json.Value, a, req, .{});
    try std.testing.expectEqualStrings("initialize", parsed.object.get("method").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.object.get("id").?.integer);
}

test "build initialize response shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const resp = try buildInitializeResponse(a, .{ .integer = 7 });
    // Round-trip through the parser.
    const parsed = try json.parseFromSliceLeaky(json.Value, a, resp, .{});
    try std.testing.expectEqualStrings("2.0", parsed.object.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, 7), parsed.object.get("id").?.integer);

    const result = parsed.object.get("result").?.object;
    try std.testing.expectEqualStrings(PROTOCOL_VERSION, result.get("protocolVersion").?.string);
    const caps = result.get("capabilities").?.object;
    const tools = caps.get("tools").?.object;
    try std.testing.expectEqual(false, tools.get("listChanged").?.bool);
}

test "build tools/list returns 5 tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const resp = try buildToolsListResponse(a, .{ .integer = 2 });
    const parsed = try json.parseFromSliceLeaky(json.Value, a, resp, .{});
    const tools = parsed.object.get("result").?.object.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 5), tools.items.len);

    // Spot-check names. Order is fixed (say/queue/skip/clear/voices).
    try std.testing.expectEqualStrings("say", tools.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("queue", tools.items[1].object.get("name").?.string);
    try std.testing.expectEqualStrings("skip", tools.items[2].object.get("name").?.string);
    try std.testing.expectEqualStrings("clear", tools.items[3].object.get("name").?.string);
    try std.testing.expectEqualStrings("voices", tools.items[4].object.get("name").?.string);

    // Every tool has an inputSchema with type=object.
    for (tools.items) |t| {
        const schema = t.object.get("inputSchema").?.object;
        try std.testing.expectEqualStrings("object", schema.get("type").?.string);
    }
}

test "parse tools/call request for say" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const req =
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"say","arguments":{"text":"olá","engine":"piper"}}}
    ;
    const parsed = try json.parseFromSliceLeaky(json.Value, a, req, .{});
    const params = parsed.object.get("params").?.object;
    try std.testing.expectEqualStrings("say", params.get("name").?.string);
    const args = params.get("arguments").?.object;
    try std.testing.expectEqualStrings("olá", args.get("text").?.string);
    try std.testing.expectEqualStrings("piper", args.get("engine").?.string);
}

test "error response includes error.code and error.message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const resp = try errorResponse(a, .{ .integer = 99 }, -32601, "Method not found");
    const parsed = try json.parseFromSliceLeaky(json.Value, a, resp, .{});
    try std.testing.expectEqual(@as(i64, 99), parsed.object.get("id").?.integer);
    const err_obj = parsed.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32601), err_obj.get("code").?.integer);
    try std.testing.expectEqualStrings("Method not found", err_obj.get("message").?.string);
}

test "tool text response carries isError=false and content array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const resp = try toolTextResponse(a, .{ .integer = 11 }, "{\"id\":\"42\"}");
    const parsed = try json.parseFromSliceLeaky(json.Value, a, resp, .{});
    const result = parsed.object.get("result").?.object;
    try std.testing.expectEqual(false, result.get("isError").?.bool);
    const content = result.get("content").?.array;
    try std.testing.expectEqual(@as(usize, 1), content.items.len);
    try std.testing.expectEqualStrings("text", content.items[0].object.get("type").?.string);
}
