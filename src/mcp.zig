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

// v1.10.13 — scoped logger so MCP transport errors are filterable.
const mlog = std.log.scoped(.mcp);

pub const VERSION = "1.10.10";
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
                mlog.warn("line exceeds {d}B — closing", .{READ_BUF});
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
            mlog.err("handle error: {s}", .{@errorName(e)});
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
        try toolDescriptor(a, "say", "Enqueue Pt-BR TTS on the running daemon. Returns the queue item id. v1.10.7: optional length_scale / noise_scale / noise_w override piper inference per call. v1.10.8: + tech mode (acronym/unit glossary), per-call pause overrides, multi-speaker selector.", try saySchema(a)),
        try toolDescriptor(a, "queue", "List items currently in the TTS queue (pending + playing).", try emptySchema(a)),
        try toolDescriptor(a, "skip", "Skip the currently playing TTS item. Returns the skipped id (0 = nothing playing).", try skipSchema(a)),
        try toolDescriptor(a, "clear", "Drop all pending TTS items. Returns the number dropped.", try emptySchema(a)),
        try toolDescriptor(a, "voices", "List installed voices for `say` and any piper ONNX models in ~/.cache/agent-tts/voices/.", try emptySchema(a)),
        try toolDescriptor(a, "say_stream", "Stream-feed Pt-BR TTS chunk-by-chunk. The server buffers bytes per stream_id, emits sentences to the daemon as terminators arrive, and flushes any remainder when final=true. Returns the count of sentences enqueued by this call.", try sayStreamSchema(a)),
        // v1.10.2 — player ops.
        try toolDescriptor(a, "pause", "Pause the active piper/cloned playback. Returns the paused item id (0 = nothing playing).", try emptySchema(a)),
        try toolDescriptor(a, "resume", "Resume a paused item. Returns the resumed item id (0 = not paused).", try emptySchema(a)),
        try toolDescriptor(a, "replay", "Re-enqueue a past item by id (any state). Returns the new pending id (0 = item not found).", try replaySchema(a)),
        try toolDescriptor(a, "history", "List the last N items, including done/skipped. Default limit 20, max 100.", try historySchema(a)),
        // v1.10.7 — A/B helper for piper inference knobs.
        try toolDescriptor(a, "synth_voice_test", "Enqueue a one-shot piper synth with explicit length_scale / noise_scale / noise_w (v1.10.8: + tech / pause overrides / speaker_id). Returns the enqueue id plus the resolved knobs so an agent can A/B Faber profiles without daemon restart.", try synthVoiceTestSchema(a)),
        // v1.10.8 — automate the discovery loop: one call, N variants enqueued.
        try toolDescriptor(a, "voice_knob_search", "Enqueue the same text once per `variants` entry, each with its own knob bundle (length_scale / noise_scale / noise_w / tech / *_pause_ms / speaker_id). Returns the list of `{id, knobs}` so the caller can compare A/B/.../N profiles in a single MCP round-trip. max_variants capped at 16.", try voiceKnobSearchSchema(a)),
        // v1.10.9 / v1.10.10 — curated 4-variant × 2-postfx matrix.
        try toolDescriptor(a, "tech_profile_search", "v1.10.10: enqueue a curated 4×2=8 tech-narration matrix — each of the 4 knob bundles (tight-narrator/stock-tech/broadcast/expressive) is enqueued twice: once dry (postfx=off) and once with the research-anchored RNNoise+EQ+deesser+comp chain (postfx=tech). Each variant runs through Faber piper with tech=true. Returns 8 `{id, name, postfx, knobs}` so the caller can A/B both knob AND post-fx in one round-trip.", try techProfileSearchSchema(a)),
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
        .{ "description", str("Pt-BR text to speak. Newlines/tabs are sanitized. Pass SSML markup (W3C 1.1 subset) when `ssml=true`.") },
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
    const ssml_prop = try obj(a, &.{
        .{ "type", str("boolean") },
        .{ "description", str("v1.8+: treat text as W3C SSML 1.1 subset (<emphasis>, <break>, <prosody>, <say-as>). Default false.") },
    });
    // v1.10.7 — per-call piper inference knobs. Omit to keep daemon
    // env / voice defaults; valid ranges enforced in callSay.
    const length_scale_prop = try obj(a, &.{
        .{ "type", str("number") },
        .{ "description", str("v1.10.7+: Piper length_scale (0.1..3.0). 1.0=default, <1=faster, >1=slower. Omit to keep voice/env default. Ignored for engine=say.") },
    });
    const noise_scale_prop = try obj(a, &.{
        .{ "type", str("number") },
        .{ "description", str("v1.10.7+: Piper noise_scale (0..2). Higher = more prosody variation. Omit to keep voice/env default. Faber sweet spot ~0.667. Ignored for engine=say.") },
    });
    const noise_w_prop = try obj(a, &.{
        .{ "type", str("number") },
        .{ "description", str("v1.10.7+: Piper noise_w (0..2). Higher = more pronunciation variation. Omit to keep voice/env default. Faber sweet spot ~0.8. Ignored for engine=say.") },
    });
    // v1.10.8 — tech mode + pause overrides + speaker selector.
    const tech_prop = try obj(a, &.{
        .{ "type", str("boolean") },
        .{ "description", str("v1.10.8+: tech-report mode. Expands acronyms (API → A P I, MCP → M C P), unit symbols (MB → megabytes, ms → milissegundos), and brand phonetics (ONNX → ônix). Pair with engine=piper for the cleanest result.") },
    });
    const comma_pause_prop = try obj(a, &.{
        .{ "type", str("integer") },
        .{ "description", str("v1.10.8+: pause ms after `,` (default 150). 0 = use default. Ignored for engine=piper continuous PCM.") },
    });
    const sentence_pause_prop = try obj(a, &.{
        .{ "type", str("integer") },
        .{ "description", str("v1.10.8+: pause ms after `.` `!` `?` (default 400). 0 = use default. Tech profile uses 500.") },
    });
    const newline_pause_prop = try obj(a, &.{
        .{ "type", str("integer") },
        .{ "description", str("v1.10.8+: pause ms after newline (default 600). 0 = use default.") },
    });
    const speaker_id_prop = try obj(a, &.{
        .{ "type", str("integer") },
        .{ "description", str("v1.10.8+: Piper multi-speaker integer index. -1 = use voice config default. Faber is single-speaker (ignored).") },
    });
    // v1.10.10 — ffmpeg post-fx selector.
    const postfx_enum = try arr(a, &.{ str("off"), str("clean"), str("tech"), str("broadcast") });
    const postfx_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "enum", postfx_enum },
        .{ "description", str("v1.10.10+: audio post-processing profile applied to the synth PCM before zaudio playback. `off` (default) is the dry path. `clean` is highpass+light comp. `tech` is the research-anchored chain (RNNoise+EQ+deesser+2:1 comp) — needs ffmpeg on PATH and an RNNoise model at AGENT_TTS_POSTFX_RNNN_MODEL or ~/.cache/agent-tts/rnnoise/cb.rnnn. `broadcast` is EQ+deesser+3:1 comp. Pass-through when ffmpeg is missing.") },
    });

    const props = try obj(a, &.{
        .{ "text", text_prop },
        .{ "engine", engine_prop },
        .{ "voice", voice_prop },
        .{ "rate", rate_prop },
        .{ "ssml", ssml_prop },
        .{ "length_scale", length_scale_prop },
        .{ "noise_scale", noise_scale_prop },
        .{ "noise_w", noise_w_prop },
        .{ "tech", tech_prop },
        .{ "comma_pause_ms", comma_pause_prop },
        .{ "sentence_pause_ms", sentence_pause_prop },
        .{ "newline_pause_ms", newline_pause_prop },
        .{ "speaker_id", speaker_id_prop },
        .{ "postfx", postfx_prop },
    });
    const required = try arr(a, &.{str("text")});

    return try obj(a, &.{
        .{ "type", str("object") },
        .{ "properties", props },
        .{ "required", required },
    });
}

fn synthVoiceTestSchema(a: std.mem.Allocator) !json.Value {
    const text_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("Sentence to synthesize. Always routed to piper Faber (Pt) so the knob effect is comparable across runs.") },
    });
    const length_scale_prop = try obj(a, &.{
        .{ "type", str("number") },
        .{ "description", str("Piper length_scale (0.1..3.0). 1.0=default, <1=faster.") },
    });
    const noise_scale_prop = try obj(a, &.{
        .{ "type", str("number") },
        .{ "description", str("Piper noise_scale (0..2). Higher = more prosody variation.") },
    });
    const noise_w_prop = try obj(a, &.{
        .{ "type", str("number") },
        .{ "description", str("Piper noise_w (0..2). Higher = more pronunciation variation.") },
    });
    // v1.10.8 — extras echoed back so the agent can record the full
    // A/B/C parameter vector per variant.
    const tech_prop = try obj(a, &.{ .{ "type", str("boolean") }, .{ "description", str("v1.10.8+: tech-report glossary substitution.") } });
    const comma_pause_prop = try obj(a, &.{ .{ "type", str("integer") }, .{ "description", str("v1.10.8+: comma pause override (ms).") } });
    const sentence_pause_prop = try obj(a, &.{ .{ "type", str("integer") }, .{ "description", str("v1.10.8+: sentence pause override (ms).") } });
    const newline_pause_prop = try obj(a, &.{ .{ "type", str("integer") }, .{ "description", str("v1.10.8+: newline pause override (ms).") } });
    const speaker_id_prop = try obj(a, &.{ .{ "type", str("integer") }, .{ "description", str("v1.10.8+: Piper speaker index (-1 = default).") } });
    // v1.10.10 — postfx selector mirrored from saySchema.
    const postfx_enum = try arr(a, &.{ str("off"), str("clean"), str("tech"), str("broadcast") });
    const postfx_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "enum", postfx_enum },
        .{ "description", str("v1.10.10+: ffmpeg post-fx chain. off (default) / clean / tech / broadcast.") },
    });
    const props = try obj(a, &.{
        .{ "text", text_prop },
        .{ "length_scale", length_scale_prop },
        .{ "noise_scale", noise_scale_prop },
        .{ "noise_w", noise_w_prop },
        .{ "tech", tech_prop },
        .{ "comma_pause_ms", comma_pause_prop },
        .{ "sentence_pause_ms", sentence_pause_prop },
        .{ "newline_pause_ms", newline_pause_prop },
        .{ "speaker_id", speaker_id_prop },
        .{ "postfx", postfx_prop },
    });
    const required = try arr(a, &.{str("text")});
    return try obj(a, &.{
        .{ "type", str("object") },
        .{ "properties", props },
        .{ "required", required },
    });
}

/// v1.10.8 — bulk knob search. Each variant is an object with the same
/// schema as `say` (minus `engine`/`voice`/`rate` — fixed to piper Faber
/// for comparability). The daemon enqueues each variant in order and the
/// MCP response carries the matched ids.
fn voiceKnobSearchSchema(a: std.mem.Allocator) !json.Value {
    const text_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("Sentence used for every variant. Pick something that exercises the dimensions you care about — acronym density, sentence cadence, prosody range.") },
    });
    // Sub-schema for each variant object. Pure documentation aid; the
    // dispatch reads fields case-by-case so it tolerates omissions.
    const variant_props = try obj(a, &.{
        .{ "length_scale", try obj(a, &.{ .{ "type", str("number") } }) },
        .{ "noise_scale", try obj(a, &.{ .{ "type", str("number") } }) },
        .{ "noise_w", try obj(a, &.{ .{ "type", str("number") } }) },
        .{ "tech", try obj(a, &.{ .{ "type", str("boolean") } }) },
        .{ "comma_pause_ms", try obj(a, &.{ .{ "type", str("integer") } }) },
        .{ "sentence_pause_ms", try obj(a, &.{ .{ "type", str("integer") } }) },
        .{ "newline_pause_ms", try obj(a, &.{ .{ "type", str("integer") } }) },
        .{ "speaker_id", try obj(a, &.{ .{ "type", str("integer") } }) },
        .{ "comment", try obj(a, &.{ .{ "type", str("string") }, .{ "description", str("Free-form label echoed back so the caller knows which variant produced which id.") } }) },
    });
    const variant_item_schema = try obj(a, &.{
        .{ "type", str("object") },
        .{ "properties", variant_props },
    });
    const variants_prop = try obj(a, &.{
        .{ "type", str("array") },
        .{ "items", variant_item_schema },
        .{ "description", str("List of knob bundles. Up to 16 entries — anything past is rejected to keep the daemon socket happy.") },
    });
    const max_prop = try obj(a, &.{
        .{ "type", str("integer") },
        .{ "description", str("Soft cap (1..16, default 8). Variants list longer than this is truncated; shorter list runs in full.") },
    });

    const props = try obj(a, &.{
        .{ "text", text_prop },
        .{ "variants", variants_prop },
        .{ "max_variants", max_prop },
    });
    const required = try arr(a, &.{ str("text"), str("variants") });
    return try obj(a, &.{
        .{ "type", str("object") },
        .{ "properties", props },
        .{ "required", required },
    });
}

/// v1.10.9 — `tech_profile_search` schema. Only `text` is exposed; the
/// four knob bundles are fixed in the implementation so the caller has a
/// curated, reproducible matrix to A/B.
fn techProfileSearchSchema(a: std.mem.Allocator) !json.Value {
    const text_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("Sentence to compare across the four curated tech-narration profiles. Pick something acronym-dense + cadence-sensitive (e.g. a release-note paragraph).") },
    });
    const props = try obj(a, &.{
        .{ "text", text_prop },
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

fn replaySchema(a: std.mem.Allocator) !json.Value {
    const id_prop = try obj(a, &.{
        .{ "type", str("integer") },
        .{ "description", str("Id of the past item to replay. Look it up via the `history` tool or `agent-tts queue`/`history`.") },
    });
    const props = try obj(a, &.{
        .{ "id", id_prop },
    });
    const required = try arr(a, &.{str("id")});
    return try obj(a, &.{
        .{ "type", str("object") },
        .{ "properties", props },
        .{ "required", required },
    });
}

fn historySchema(a: std.mem.Allocator) !json.Value {
    const limit_prop = try obj(a, &.{
        .{ "type", str("integer") },
        .{ "description", str("Number of rows to return (most recent first). Default 20, max 100. 0 → default.") },
    });
    const props = try obj(a, &.{
        .{ "limit", limit_prop },
    });
    return try obj(a, &.{
        .{ "type", str("object") },
        .{ "properties", props },
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
    // v1.10.2 — player ops.
    if (std.mem.eql(u8, tool, "pause")) return callPause(a, io, home, id);
    if (std.mem.eql(u8, tool, "resume")) return callResume(a, io, home, id);
    if (std.mem.eql(u8, tool, "replay")) return callReplay(a, io, home, id, args_val);
    if (std.mem.eql(u8, tool, "history")) return callHistory(a, io, home, id, args_val);
    // v1.10.7 — A/B Faber profiles inline.
    if (std.mem.eql(u8, tool, "synth_voice_test")) return callSynthVoiceTest(a, io, home, id, args_val);
    // v1.10.8 — bulk N-way knob search.
    if (std.mem.eql(u8, tool, "voice_knob_search")) return callVoiceKnobSearch(a, io, home, id, args_val);
    // v1.10.9 — curated 4-variant matrix specifically for tech narration.
    if (std.mem.eql(u8, tool, "tech_profile_search")) return callTechProfileSearch(a, io, home, id, args_val);

    return try toolErrorResponse(a, id, "unknown tool");
}

fn callPause(a: std.mem.Allocator, io: std.Io, home: []const u8, id: json.Value) ![]const u8 {
    const paused = client.pauseOp(a, io, home) catch |e| switch (e) {
        error.DaemonUnreachable => return try toolErrorResponse(a, id, "daemon not running"),
        error.DaemonError => return try toolErrorResponse(a, id, "daemon error"),
        error.UnexpectedResponse => return try toolErrorResponse(a, id, "daemon unexpected response"),
        else => return e,
    };
    const payload = try obj(a, &.{
        .{ "paused_id", int(@intCast(paused)) },
    });
    const text_block = try formatJsonAsText(a, payload);
    return try toolTextResponse(a, id, text_block);
}

fn callResume(a: std.mem.Allocator, io: std.Io, home: []const u8, id: json.Value) ![]const u8 {
    const resumed = client.resumeOp(a, io, home) catch |e| switch (e) {
        error.DaemonUnreachable => return try toolErrorResponse(a, id, "daemon not running"),
        error.DaemonError => return try toolErrorResponse(a, id, "daemon error"),
        error.UnexpectedResponse => return try toolErrorResponse(a, id, "daemon unexpected response"),
        else => return e,
    };
    const payload = try obj(a, &.{
        .{ "resumed_id", int(@intCast(resumed)) },
    });
    const text_block = try formatJsonAsText(a, payload);
    return try toolTextResponse(a, id, text_block);
}

fn callReplay(a: std.mem.Allocator, io: std.Io, home: []const u8, id: json.Value, args: json.Value) ![]const u8 {
    if (args != .object) return try toolErrorResponse(a, id, "arguments must be an object");
    const ao = args.object;
    const id_val = ao.get("id") orelse return try toolErrorResponse(a, id, "id is required");
    if (id_val != .integer) return try toolErrorResponse(a, id, "id must be an integer");
    if (id_val.integer <= 0) return try toolErrorResponse(a, id, "id must be > 0");
    const src_id: u64 = @intCast(id_val.integer);

    const new_id = client.replayOp(a, io, home, src_id) catch |e| switch (e) {
        error.DaemonUnreachable => return try toolErrorResponse(a, id, "daemon not running"),
        error.DaemonError => return try toolErrorResponse(a, id, "daemon error"),
        error.UnexpectedResponse => return try toolErrorResponse(a, id, "daemon unexpected response"),
        else => return e,
    };
    const payload = try obj(a, &.{
        .{ "new_id", int(@intCast(new_id)) },
    });
    const text_block = try formatJsonAsText(a, payload);
    return try toolTextResponse(a, id, text_block);
}

fn callHistory(a: std.mem.Allocator, io: std.Io, home: []const u8, id: json.Value, args: json.Value) ![]const u8 {
    var limit: u32 = 20;
    if (args == .object) {
        if (args.object.get("limit")) |l| {
            if (l != .integer) return try toolErrorResponse(a, id, "limit must be an integer");
            if (l.integer < 0 or l.integer > 100) return try toolErrorResponse(a, id, "limit out of range (0..100)");
            limit = @intCast(l.integer);
        }
    }
    const items = client.historyLines(a, io, home, limit) catch |e| switch (e) {
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
            .{ "finished_at", str(it.finished_at) },
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

    var ssml_flag: bool = false;
    if (ao.get("ssml")) |s| {
        if (s != .bool) return try toolErrorResponse(a, id, "ssml must be a boolean");
        ssml_flag = s.bool;
    }

    // v1.10.7 — per-call piper knobs. Each is optional; reject out-of-
    // range numerics here so the daemon doesn't have to.
    var length_scale: f32 = 0.0;
    if (ao.get("length_scale")) |v| {
        const f = try jsonNumberToF32(v) orelse return try toolErrorResponse(a, id, "length_scale must be a number");
        if (f < 0.1 or f > 3.0) return try toolErrorResponse(a, id, "length_scale out of range (0.1..3.0)");
        length_scale = f;
    }
    var noise_scale: f32 = -1.0;
    if (ao.get("noise_scale")) |v| {
        const f = try jsonNumberToF32(v) orelse return try toolErrorResponse(a, id, "noise_scale must be a number");
        if (f < 0.0 or f > 2.0) return try toolErrorResponse(a, id, "noise_scale out of range (0..2)");
        noise_scale = f;
    }
    var noise_w: f32 = -1.0;
    if (ao.get("noise_w")) |v| {
        const f = try jsonNumberToF32(v) orelse return try toolErrorResponse(a, id, "noise_w must be a number");
        if (f < 0.0 or f > 2.0) return try toolErrorResponse(a, id, "noise_w out of range (0..2)");
        noise_w = f;
    }
    // v1.10.8 — tech mode + pause overrides + speaker_id.
    var tech_flag: bool = false;
    if (ao.get("tech")) |v| {
        if (v != .bool) return try toolErrorResponse(a, id, "tech must be a boolean");
        tech_flag = v.bool;
    }
    var comma_pause_ms: u32 = 0;
    if (ao.get("comma_pause_ms")) |v| {
        if (v != .integer) return try toolErrorResponse(a, id, "comma_pause_ms must be an integer");
        if (v.integer < 0 or v.integer > 5000) return try toolErrorResponse(a, id, "comma_pause_ms out of range (0..5000)");
        comma_pause_ms = @intCast(v.integer);
    }
    var sentence_pause_ms: u32 = 0;
    if (ao.get("sentence_pause_ms")) |v| {
        if (v != .integer) return try toolErrorResponse(a, id, "sentence_pause_ms must be an integer");
        if (v.integer < 0 or v.integer > 5000) return try toolErrorResponse(a, id, "sentence_pause_ms out of range (0..5000)");
        sentence_pause_ms = @intCast(v.integer);
    }
    var newline_pause_ms: u32 = 0;
    if (ao.get("newline_pause_ms")) |v| {
        if (v != .integer) return try toolErrorResponse(a, id, "newline_pause_ms must be an integer");
        if (v.integer < 0 or v.integer > 5000) return try toolErrorResponse(a, id, "newline_pause_ms out of range (0..5000)");
        newline_pause_ms = @intCast(v.integer);
    }
    var speaker_id: i32 = -1;
    if (ao.get("speaker_id")) |v| {
        if (v != .integer) return try toolErrorResponse(a, id, "speaker_id must be an integer");
        if (v.integer < -1 or v.integer > 1000) return try toolErrorResponse(a, id, "speaker_id out of range (-1..1000)");
        speaker_id = @intCast(v.integer);
    }
    // v1.10.10 — postfx selector.
    var postfx_profile: ipc.Postfx = .off;
    if (ao.get("postfx")) |v| {
        if (v != .string) return try toolErrorResponse(a, id, "postfx must be a string");
        postfx_profile = ipc.Postfx.fromStr(v.string) orelse return try toolErrorResponse(a, id, "postfx must be off|clean|tech|broadcast");
    }

    const id_str = client.enqueueLineWithPostfx(
        a,
        io,
        home,
        engine,
        voice,
        rate,
        text,
        ssml_flag,
        length_scale,
        noise_scale,
        noise_w,
        tech_flag,
        comma_pause_ms,
        sentence_pause_ms,
        newline_pause_ms,
        speaker_id,
        postfx_profile,
    ) catch |e| switch (e) {
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

// v1.10.7 — accept both integer (json.Value.integer) and float
// (json.Value.float) for the piper knobs. Strings/other types return null
// so callers can surface a typed error. Returns an optional because
// `error` would require sloppy union returns; pure null is cleaner.
fn jsonNumberToF32(v: json.Value) !?f32 {
    return switch (v) {
        .integer => |i| @as(f32, @floatFromInt(i)),
        .float => |f| @as(f32, @floatCast(f)),
        else => null,
    };
}

fn callSynthVoiceTest(
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

    var length_scale: f32 = 0.0;
    if (ao.get("length_scale")) |v| {
        const f = try jsonNumberToF32(v) orelse return try toolErrorResponse(a, id, "length_scale must be a number");
        if (f < 0.1 or f > 3.0) return try toolErrorResponse(a, id, "length_scale out of range (0.1..3.0)");
        length_scale = f;
    }
    var noise_scale: f32 = -1.0;
    if (ao.get("noise_scale")) |v| {
        const f = try jsonNumberToF32(v) orelse return try toolErrorResponse(a, id, "noise_scale must be a number");
        if (f < 0.0 or f > 2.0) return try toolErrorResponse(a, id, "noise_scale out of range (0..2)");
        noise_scale = f;
    }
    var noise_w: f32 = -1.0;
    if (ao.get("noise_w")) |v| {
        const f = try jsonNumberToF32(v) orelse return try toolErrorResponse(a, id, "noise_w must be a number");
        if (f < 0.0 or f > 2.0) return try toolErrorResponse(a, id, "noise_w out of range (0..2)");
        noise_w = f;
    }
    // v1.10.8 — additional knobs echoed for full A/B/C parameter vectors.
    var tech_flag: bool = false;
    if (ao.get("tech")) |v| {
        if (v != .bool) return try toolErrorResponse(a, id, "tech must be a boolean");
        tech_flag = v.bool;
    }
    var comma_pause_ms: u32 = 0;
    if (ao.get("comma_pause_ms")) |v| {
        if (v != .integer) return try toolErrorResponse(a, id, "comma_pause_ms must be an integer");
        if (v.integer < 0 or v.integer > 5000) return try toolErrorResponse(a, id, "comma_pause_ms out of range (0..5000)");
        comma_pause_ms = @intCast(v.integer);
    }
    var sentence_pause_ms: u32 = 0;
    if (ao.get("sentence_pause_ms")) |v| {
        if (v != .integer) return try toolErrorResponse(a, id, "sentence_pause_ms must be an integer");
        if (v.integer < 0 or v.integer > 5000) return try toolErrorResponse(a, id, "sentence_pause_ms out of range (0..5000)");
        sentence_pause_ms = @intCast(v.integer);
    }
    var newline_pause_ms: u32 = 0;
    if (ao.get("newline_pause_ms")) |v| {
        if (v != .integer) return try toolErrorResponse(a, id, "newline_pause_ms must be an integer");
        if (v.integer < 0 or v.integer > 5000) return try toolErrorResponse(a, id, "newline_pause_ms out of range (0..5000)");
        newline_pause_ms = @intCast(v.integer);
    }
    var speaker_id: i32 = -1;
    if (ao.get("speaker_id")) |v| {
        if (v != .integer) return try toolErrorResponse(a, id, "speaker_id must be an integer");
        if (v.integer < -1 or v.integer > 1000) return try toolErrorResponse(a, id, "speaker_id out of range (-1..1000)");
        speaker_id = @intCast(v.integer);
    }
    var postfx_profile: ipc.Postfx = .off;
    if (ao.get("postfx")) |v| {
        if (v != .string) return try toolErrorResponse(a, id, "postfx must be a string");
        postfx_profile = ipc.Postfx.fromStr(v.string) orelse return try toolErrorResponse(a, id, "postfx must be off|clean|tech|broadcast");
    }

    const id_str = client.enqueueLineWithPostfx(
        a,
        io,
        home,
        .piper,
        "faber",
        client.DEFAULT_RATE,
        text,
        false,
        length_scale,
        noise_scale,
        noise_w,
        tech_flag,
        comma_pause_ms,
        sentence_pause_ms,
        newline_pause_ms,
        speaker_id,
        postfx_profile,
    ) catch |e| switch (e) {
        error.DaemonUnreachable => return try toolErrorResponse(a, id, "daemon not running"),
        error.DaemonError => return try toolErrorResponse(a, id, "daemon returned an error"),
        error.UnexpectedResponse => return try toolErrorResponse(a, id, "daemon returned an unexpected response"),
        else => return e,
    };

    // Echo the resolved knobs so the caller can record their A/B parameters.
    const payload = try obj(a, &.{
        .{ "id", str(id_str) },
        .{ "length_scale", json.Value{ .float = @floatCast(length_scale) } },
        .{ "noise_scale", json.Value{ .float = @floatCast(noise_scale) } },
        .{ "noise_w", json.Value{ .float = @floatCast(noise_w) } },
        .{ "tech", boolean(tech_flag) },
        .{ "comma_pause_ms", int(@intCast(comma_pause_ms)) },
        .{ "sentence_pause_ms", int(@intCast(sentence_pause_ms)) },
        .{ "newline_pause_ms", int(@intCast(newline_pause_ms)) },
        .{ "speaker_id", int(@intCast(speaker_id)) },
        .{ "postfx", str(postfx_profile.str()) },
    });
    const text_block = try formatJsonAsText(a, payload);
    return try toolTextResponse(a, id, text_block);
}

// v1.10.8 — voice_knob_search: enqueue one item per variant. Capped at 16
// to keep the daemon socket healthy. Each variant inherits the call's
// `text` and routes to piper Faber so the comparison is apples-to-apples.
fn callVoiceKnobSearch(
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

    const variants_val = ao.get("variants") orelse return try toolErrorResponse(a, id, "variants is required");
    if (variants_val != .array) return try toolErrorResponse(a, id, "variants must be an array");
    const variants = variants_val.array;
    if (variants.items.len == 0) return try toolErrorResponse(a, id, "variants must not be empty");

    var max_variants: usize = 8;
    if (ao.get("max_variants")) |v| {
        if (v != .integer) return try toolErrorResponse(a, id, "max_variants must be an integer");
        if (v.integer < 1 or v.integer > 16) return try toolErrorResponse(a, id, "max_variants out of range (1..16)");
        max_variants = @intCast(v.integer);
    }
    const HARD_CAP: usize = 16;
    const limit = @min(@min(variants.items.len, max_variants), HARD_CAP);

    var items: json.Array = .init(a);
    var idx: usize = 0;
    while (idx < limit) : (idx += 1) {
        const variant = variants.items[idx];
        if (variant != .object) return try toolErrorResponse(a, id, "each variant must be an object");
        const vo = variant.object;

        var length_scale: f32 = 0.0;
        if (vo.get("length_scale")) |v| {
            const f = try jsonNumberToF32(v) orelse return try toolErrorResponse(a, id, "variant.length_scale must be a number");
            if (f < 0.1 or f > 3.0) return try toolErrorResponse(a, id, "variant.length_scale out of range (0.1..3.0)");
            length_scale = f;
        }
        var noise_scale: f32 = -1.0;
        if (vo.get("noise_scale")) |v| {
            const f = try jsonNumberToF32(v) orelse return try toolErrorResponse(a, id, "variant.noise_scale must be a number");
            if (f < 0.0 or f > 2.0) return try toolErrorResponse(a, id, "variant.noise_scale out of range (0..2)");
            noise_scale = f;
        }
        var noise_w: f32 = -1.0;
        if (vo.get("noise_w")) |v| {
            const f = try jsonNumberToF32(v) orelse return try toolErrorResponse(a, id, "variant.noise_w must be a number");
            if (f < 0.0 or f > 2.0) return try toolErrorResponse(a, id, "variant.noise_w out of range (0..2)");
            noise_w = f;
        }
        var tech_flag: bool = false;
        if (vo.get("tech")) |v| {
            if (v != .bool) return try toolErrorResponse(a, id, "variant.tech must be a boolean");
            tech_flag = v.bool;
        }
        var comma_pause_ms: u32 = 0;
        if (vo.get("comma_pause_ms")) |v| {
            if (v != .integer) return try toolErrorResponse(a, id, "variant.comma_pause_ms must be an integer");
            if (v.integer < 0 or v.integer > 5000) return try toolErrorResponse(a, id, "variant.comma_pause_ms out of range");
            comma_pause_ms = @intCast(v.integer);
        }
        var sentence_pause_ms: u32 = 0;
        if (vo.get("sentence_pause_ms")) |v| {
            if (v != .integer) return try toolErrorResponse(a, id, "variant.sentence_pause_ms must be an integer");
            if (v.integer < 0 or v.integer > 5000) return try toolErrorResponse(a, id, "variant.sentence_pause_ms out of range");
            sentence_pause_ms = @intCast(v.integer);
        }
        var newline_pause_ms: u32 = 0;
        if (vo.get("newline_pause_ms")) |v| {
            if (v != .integer) return try toolErrorResponse(a, id, "variant.newline_pause_ms must be an integer");
            if (v.integer < 0 or v.integer > 5000) return try toolErrorResponse(a, id, "variant.newline_pause_ms out of range");
            newline_pause_ms = @intCast(v.integer);
        }
        var speaker_id: i32 = -1;
        if (vo.get("speaker_id")) |v| {
            if (v != .integer) return try toolErrorResponse(a, id, "variant.speaker_id must be an integer");
            if (v.integer < -1 or v.integer > 1000) return try toolErrorResponse(a, id, "variant.speaker_id out of range");
            speaker_id = @intCast(v.integer);
        }
        const comment: []const u8 = blk: {
            if (vo.get("comment")) |cv| {
                if (cv != .string) return try toolErrorResponse(a, id, "variant.comment must be a string");
                break :blk cv.string;
            }
            break :blk "";
        };

        const id_str = client.enqueueLineFull(
            a,
            io,
            home,
            .piper,
            "faber",
            client.DEFAULT_RATE,
            text,
            false,
            length_scale,
            noise_scale,
            noise_w,
            tech_flag,
            comma_pause_ms,
            sentence_pause_ms,
            newline_pause_ms,
            speaker_id,
        ) catch |e| switch (e) {
            error.DaemonUnreachable => return try toolErrorResponse(a, id, "daemon not running"),
            error.DaemonError => return try toolErrorResponse(a, id, "daemon returned an error mid-search"),
            error.UnexpectedResponse => return try toolErrorResponse(a, id, "daemon returned an unexpected response mid-search"),
            else => return e,
        };

        const knobs = try obj(a, &.{
            .{ "length_scale", json.Value{ .float = @floatCast(length_scale) } },
            .{ "noise_scale", json.Value{ .float = @floatCast(noise_scale) } },
            .{ "noise_w", json.Value{ .float = @floatCast(noise_w) } },
            .{ "tech", boolean(tech_flag) },
            .{ "comma_pause_ms", int(@intCast(comma_pause_ms)) },
            .{ "sentence_pause_ms", int(@intCast(sentence_pause_ms)) },
            .{ "newline_pause_ms", int(@intCast(newline_pause_ms)) },
            .{ "speaker_id", int(@intCast(speaker_id)) },
        });
        const entry = try obj(a, &.{
            .{ "id", str(id_str) },
            .{ "comment", str(comment) },
            .{ "knobs", knobs },
        });
        try items.append(entry);
    }

    const payload = try obj(a, &.{
        .{ "items", json.Value{ .array = items } },
        .{ "truncated", boolean(variants.items.len > limit) },
    });
    const text_block = try formatJsonAsText(a, payload);
    return try toolTextResponse(a, id, text_block);
}

// v1.10.9 — tech_profile_search: hardcoded 4-variant matrix derived from
// `_qa/v1.10.9-research-prompt-output.md`. The curated subset of the
// Resolution IV 2⁴⁻¹ generator (factors length / noise / noise_w / EQ)
// gives the caller a fast comparator without exposing every dial. Each
// variant forces `tech=true` so the glossary + identifier normalizer +
// CamelCase splitter all fire.
const TechProfile = struct {
    name: []const u8,
    length_scale: f32,
    noise_scale: f32,
    noise_w: f32,
    sentence_pause_ms: u32,
    comma_pause_ms: u32 = 0,
};

const TECH_PROFILES = [_]TechProfile{
    .{
        .name = "tight-narrator",
        .length_scale = 1.05,
        .noise_scale = 0.35,
        .noise_w = 0.45,
        .sentence_pause_ms = 500,
    },
    .{
        .name = "stock-tech",
        .length_scale = 0.95,
        .noise_scale = 0.667,
        .noise_w = 0.85,
        .sentence_pause_ms = 500,
    },
    .{
        .name = "broadcast",
        .length_scale = 1.10,
        .noise_scale = 0.55,
        .noise_w = 0.65,
        .sentence_pause_ms = 650,
        .comma_pause_ms = 200,
    },
    .{
        .name = "expressive",
        .length_scale = 1.00,
        .noise_scale = 0.85,
        .noise_w = 1.10,
        .sentence_pause_ms = 500,
        .comma_pause_ms = 160,
    },
};

fn callTechProfileSearch(
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

    // v1.10.10 — 4 knob bundles × 2 postfx variants = 8 enqueues per
    // call. Cap is 16 (matches voice_knob_search budget). Each entry
    // tags the resolved postfx so the caller can match audible result
    // to id without recomputing the matrix.
    const POSTFX_VARIANTS = [_]ipc.Postfx{ .off, .tech };
    const total: usize = TECH_PROFILES.len * POSTFX_VARIANTS.len;
    if (total > 16) return try toolErrorResponse(a, id, "tech_profile_search matrix exceeds 16 cap");

    var items: json.Array = .init(a);
    for (TECH_PROFILES) |p| {
        for (POSTFX_VARIANTS) |pfx| {
            const id_str = client.enqueueLineWithPostfx(
                a,
                io,
                home,
                .piper,
                "faber",
                client.DEFAULT_RATE,
                text,
                false, // ssml
                p.length_scale,
                p.noise_scale,
                p.noise_w,
                true, // tech
                p.comma_pause_ms,
                p.sentence_pause_ms,
                0, // newline_pause_ms (default)
                -1, // speaker_id
                pfx,
            ) catch |e| switch (e) {
                error.DaemonUnreachable => return try toolErrorResponse(a, id, "daemon not running"),
                error.DaemonError => return try toolErrorResponse(a, id, "daemon returned an error mid-search"),
                error.UnexpectedResponse => return try toolErrorResponse(a, id, "daemon returned an unexpected response mid-search"),
                else => return e,
            };

            const knobs = try obj(a, &.{
                .{ "length_scale", json.Value{ .float = @floatCast(p.length_scale) } },
                .{ "noise_scale", json.Value{ .float = @floatCast(p.noise_scale) } },
                .{ "noise_w", json.Value{ .float = @floatCast(p.noise_w) } },
                .{ "tech", boolean(true) },
                .{ "comma_pause_ms", int(@intCast(p.comma_pause_ms)) },
                .{ "sentence_pause_ms", int(@intCast(p.sentence_pause_ms)) },
            });
            // Comment makes the (name, postfx) pair searchable in
            // history dumps. Mirrors the voice_knob_search shape.
            const comment = try std.fmt.allocPrint(a, "{s} + postfx={s}", .{ p.name, pfx.str() });
            const entry = try obj(a, &.{
                .{ "id", str(id_str) },
                .{ "name", str(p.name) },
                .{ "postfx", str(pfx.str()) },
                .{ "comment", str(comment) },
                .{ "knobs", knobs },
            });
            try items.append(entry);
        }
    }

    const payload = try obj(a, &.{
        .{ "items", json.Value{ .array = items } },
        .{ "count", int(@intCast(total)) },
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

test "build tools/list returns 12 tools (v1.10.8 + voice_knob_search)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const resp = try buildToolsListResponse(a, .{ .integer = 2 });
    const parsed = try json.parseFromSliceLeaky(json.Value, a, resp, .{});
    const tools = parsed.object.get("result").?.object.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 12), tools.items.len);

    // Spot-check names. Order is fixed:
    //   say/queue/skip/clear/voices/say_stream/pause/resume/replay/history/synth_voice_test/voice_knob_search.
    try std.testing.expectEqualStrings("say", tools.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("queue", tools.items[1].object.get("name").?.string);
    try std.testing.expectEqualStrings("skip", tools.items[2].object.get("name").?.string);
    try std.testing.expectEqualStrings("clear", tools.items[3].object.get("name").?.string);
    try std.testing.expectEqualStrings("voices", tools.items[4].object.get("name").?.string);
    try std.testing.expectEqualStrings("say_stream", tools.items[5].object.get("name").?.string);
    try std.testing.expectEqualStrings("pause", tools.items[6].object.get("name").?.string);
    try std.testing.expectEqualStrings("resume", tools.items[7].object.get("name").?.string);
    try std.testing.expectEqualStrings("replay", tools.items[8].object.get("name").?.string);
    try std.testing.expectEqualStrings("history", tools.items[9].object.get("name").?.string);
    try std.testing.expectEqualStrings("synth_voice_test", tools.items[10].object.get("name").?.string);
    try std.testing.expectEqualStrings("voice_knob_search", tools.items[11].object.get("name").?.string);

    // Every tool has an inputSchema with type=object.
    for (tools.items) |t| {
        const schema = t.object.get("inputSchema").?.object;
        try std.testing.expectEqualStrings("object", schema.get("type").?.string);
    }
}

test "v1.10.8 say schema exposes tech + pause overrides + speaker_id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try saySchema(a);
    const props = schema.object.get("properties").?.object;
    try std.testing.expect(props.get("tech") != null);
    try std.testing.expect(props.get("comma_pause_ms") != null);
    try std.testing.expect(props.get("sentence_pause_ms") != null);
    try std.testing.expect(props.get("newline_pause_ms") != null);
    try std.testing.expect(props.get("speaker_id") != null);
}

test "v1.10.10 say schema exposes postfx with the 4-value enum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try saySchema(a);
    const props = schema.object.get("properties").?.object;
    const postfx = props.get("postfx") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("string", postfx.object.get("type").?.string);
    const enum_arr = postfx.object.get("enum").?.array;
    try std.testing.expectEqual(@as(usize, 4), enum_arr.items.len);
    try std.testing.expectEqualStrings("off", enum_arr.items[0].string);
    try std.testing.expectEqualStrings("tech", enum_arr.items[2].string);
}

test "v1.10.10 synth_voice_test schema exposes postfx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try synthVoiceTestSchema(a);
    const props = schema.object.get("properties").?.object;
    try std.testing.expect(props.get("postfx") != null);
}

test "v1.10.8 voice_knob_search schema requires text + variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try voiceKnobSearchSchema(a);
    const required = schema.object.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 2), required.items.len);
    try std.testing.expectEqualStrings("text", required.items[0].string);
    try std.testing.expectEqualStrings("variants", required.items[1].string);
    const props = schema.object.get("properties").?.object;
    try std.testing.expect(props.get("variants") != null);
    try std.testing.expect(props.get("max_variants") != null);
}

test "v1.10.7 say schema exposes length_scale/noise_scale/noise_w" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try saySchema(a);
    const props = schema.object.get("properties").?.object;
    try std.testing.expect(props.get("length_scale") != null);
    try std.testing.expect(props.get("noise_scale") != null);
    try std.testing.expect(props.get("noise_w") != null);
    try std.testing.expectEqualStrings("number", props.get("length_scale").?.object.get("type").?.string);
}

test "v1.10.7 synth_voice_test schema requires text and exposes 3 knobs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try synthVoiceTestSchema(a);
    const props = schema.object.get("properties").?.object;
    try std.testing.expect(props.get("text") != null);
    try std.testing.expect(props.get("length_scale") != null);
    try std.testing.expect(props.get("noise_scale") != null);
    try std.testing.expect(props.get("noise_w") != null);
    const required = schema.object.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 1), required.items.len);
    try std.testing.expectEqualStrings("text", required.items[0].string);
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
