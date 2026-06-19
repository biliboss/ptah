// SPDX-License-Identifier: MIT OR Apache-2.0
// Wire protocol between ptah client and daemon.
//
// Transport: UNIX stream socket at $HOME/.cache/ptah/sock
//
// Request lines (one per connection):
//   ENQUEUE\t<engine>\t<lang>\t<voice>\t<rate>\t<ssml>\t<tune>\t<extra>\t<postfx>\t<text>\n → v1.10.10 10-field form
//   ENQUEUE\t<engine>\t<lang>\t<voice>\t<rate>\t<ssml>\t<tune>\t<extra>\t<text>\n → v1.10.8 9-field form
//   ENQUEUE\t<engine>\t<lang>\t<voice>\t<rate>\t<ssml>\t<tune>\t<text>\n         → v1.10.7 8-field form
//   ENQUEUE\t<engine>\t<lang>\t<voice>\t<rate>\t<ssml>\t<text>\n                 → v1.8 7-field form
//   ENQUEUE\t<engine>\t<lang>\t<voice>\t<rate>\t<text>\n                         → v1.1 6-field form
//   ENQUEUE\t<engine>\t<voice>\t<rate>\t<text>\n                                 → v0.7 5-field form
//   ENQUEUE\t<voice>\t<rate>\t<text>\n                                           → v0.6 4-field form
//   QUEUE\n                                                             → list items
//   SKIP\n                                                              → skip current
//   CLEAR\n                                                             → drop pending
//
// Backward compat (parseRequest):
//   1. Peek first token after ENQUEUE.
//      - Engine.fromStr matches      → new layout (v0.7+)
//      - Not an engine               → legacy v0.6 (token is the voice)
//   2. In new layout, peek the second token.
//      - Lang.fromStr matches        → v1.1+ (6/7/8-field)
//      - Not a lang                  → v0.7 5-field (token is the voice)
//   3. In v1.1+ layout, peek the field after the rate.
//      - "0" / "1" exactly           → v1.8+ 7- or 8-field (token is ssml flag)
//      - Anything else               → v1.1 6-field (rest is text)
//   4. In v1.8+ layout, peek the field after the ssml flag.
//      - empty "" OR contains ':'    → v1.10.7+ 8/9-field (token is the tune triplet)
//      - Anything else               → v1.8 7-field (rest is text)
//   5. In v1.10.7+ layout, peek the field after the tune triplet.
//      - empty "" OR contains ':' with ≥4 colons → v1.10.8 9-field (extra quintuple)
//      - Anything else               → v1.10.7 8-field (rest is text)
//   6. In v1.10.8+ layout, peek the field after the extra quintuple.
//      - matches Postfx tag (off/clean/tech/broadcast) → v1.10.10 10-field
//      - Anything else               → v1.10.8 9-field (rest is text)
//
// Tune triplet format (v1.10.7 8-field): `<length>:<noise>:<noise_w>`. Each
// component is either a float literal (e.g. `1.05`) or `-` for unset. An
// entirely-empty field also means "all unset". Sentinels: `length_scale = 0`
// AND `noise_scale < 0` AND `noise_w < 0` all mean "use voice/env default".
//
// Lang defaults to `.auto`, ssml defaults to `false`, and the tune knobs
// default to their unset sentinels when absent so v0.6/v0.7/v1.1/v1.8 clients
// keep working unchanged.
//
// Response lines:
//   OK\t<id>\n                           → enqueue/skip/clear ack
//   ERR\t<message>\n                     → error on any op
//   ITEM\t<id>\t<state>\t<engine>\t<voice>\t<rate>\t<text>\n  → QUEUE: one per item
//   END\n                                → QUEUE: end of list
//
// Text MUST NOT contain '\n' or '\t'. Client replaces them with ' '.

const std = @import("std");
const postfx_mod = @import("postfx.zig");

pub const Postfx = postfx_mod.Postfx;

pub const Op = enum { enqueue, queue, skip, clear, pause, resume_play, replay, history };

pub const Engine = enum {
    kokoro,

    pub fn fromStr(s: []const u8) ?Engine {
        if (std.mem.eql(u8, s, "kokoro")) return .kokoro;
        // Legacy compat: old wire tokens map to kokoro (sole engine now).
        if (std.mem.eql(u8, s, "say")) return .kokoro;
        if (std.mem.eql(u8, s, "piper")) return .kokoro;
        if (std.mem.eql(u8, s, "cloned")) return .kokoro;
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
    engine: Engine = .kokoro,
    lang: Lang = .auto,
    voice: []const u8,
    rate: u32,
    /// v1.8 — input contains W3C SSML 1.1 subset markup. When `false`,
    /// the daemon runs the v0.5 Pt-BR preprocessor as before. When
    /// `true`, the daemon parses SSML, applies engine-specific transpile
    /// (say → [[…]] directives, piper → prosody scaling), then routes.
    ssml: bool = false,
    /// v1.10.7 — per-call piper inference knobs. Sentinel `0.0` means
    /// "use voice / env / built-in default" so older callers that don't
    /// set the field keep the legacy behaviour. Range when set: 0.1..3.0.
    length_scale: f32 = 0.0,
    /// v1.10.7 — Piper noise_scale knob. Sentinel `< 0` means unset.
    /// Range when set: 0.0..2.0. Higher = more variation in prosody.
    noise_scale: f32 = -1.0,
    /// v1.10.7 — Piper noise_w knob. Sentinel `< 0` means unset.
    /// Range when set: 0.0..2.0. Higher = more variation in pronunciation.
    noise_w: f32 = -1.0,
    /// v1.10.8 — tech-report mode. When true, the daemon runs the
    /// `processTech*` preproc instead of `process*`, expanding curated
    /// acronyms (API → A P I) and units (MB → megabytes).
    tech: bool = false,
    /// v1.10.8 — per-call pause overrides. 0 = use the built-in default
    /// from `preproc.Pause`. Non-zero stretches/shrinks the corresponding
    /// `[[slnc N]]` directive.
    comma_pause_ms: u32 = 0,
    sentence_pause_ms: u32 = 0,
    newline_pause_ms: u32 = 0,
    /// v1.10.8 — Piper multi-speaker selector. `-1` means "use voice
    /// config default". Single-speaker voices (Dora) ignore this.
    speaker_id: i32 = -1,
    /// v1.10.10 — opt-in audio post-processing chain. `.off` means the
    /// daemon plays the synth PCM unchanged. The other variants route
    /// the PCM through an ffmpeg subprocess (RNNoise + EQ + de-esser +
    /// compressor) before the afplay device pump. See `postfx.zig`.
    postfx: Postfx = .off,
    text: []const u8,
};

pub const Request = union(Op) {
    enqueue: Message,
    queue: void,
    skip: void,
    clear: void,
    /// v1.10.2 — pause/resume the actively playing item. Both return
    /// `OK\t<id>` on success or `ERR\t<reason>` when there's nothing to act
    /// on. No payload on the wire — the daemon reads `current_playing_id`.
    pause: void,
    resume_play: void,
    /// v1.10.2 — replay a prior item by id. Wire shape: `REPLAY\t<id>\n`.
    /// Daemon copies the source row's engine/voice/rate/ssml/text into a
    /// new pending row and acks `OK\t<new_id>`.
    replay: u64,
    /// v1.10.2 — list the last N items (any state). Wire shape:
    /// `HISTORY\t<limit>\n`. Daemon emits `ITEM\t…` lines (same shape as
    /// QUEUE but with extra finished_at field) followed by `END`. Limit is
    /// clamped to 100 in the daemon for buffer hygiene.
    history: u32,
};

pub fn socketPath(arena: std.mem.Allocator, io: std.Io, home: []const u8) ![]u8 {
    const dir = try std.fmt.allocPrint(arena, "{s}/.cache/ptah", .{home});
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    return try std.fmt.allocPrint(arena, "{s}/sock", .{dir});
}

pub fn queueDbPath(arena: std.mem.Allocator, io: std.Io, home: []const u8) ![]u8 {
    const dir = try std.fmt.allocPrint(arena, "{s}/.cache/ptah", .{home});
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
    // v1.10.10 wire format: 10 fields when `postfx != .off`. When
    // postfx is at its default (.off), the slot is omitted entirely
    // so older daemons fed by a newer client keep parsing as 9-field.
    // The `tune` triplet + `extra` quintuple still collapse to empty
    // strings when all defaults, preserving the compact common case.
    const ssml_str: []const u8 = if (msg.ssml) "1" else "0";
    const tune = try formatTuneTriplet(arena, msg.length_scale, msg.noise_scale, msg.noise_w);
    const extra = try formatExtraQuintuple(
        arena,
        msg.tech,
        msg.comma_pause_ms,
        msg.sentence_pause_ms,
        msg.newline_pause_ms,
        msg.speaker_id,
    );
    if (msg.postfx == .off) {
        return try std.fmt.allocPrint(
            arena,
            "ENQUEUE\t{s}\t{s}\t{s}\t{d}\t{s}\t{s}\t{s}\t{s}\n",
            .{ msg.engine.str(), msg.lang.str(), msg.voice, msg.rate, ssml_str, tune, extra, msg.text },
        );
    }
    return try std.fmt.allocPrint(
        arena,
        "ENQUEUE\t{s}\t{s}\t{s}\t{d}\t{s}\t{s}\t{s}\t{s}\t{s}\n",
        .{ msg.engine.str(), msg.lang.str(), msg.voice, msg.rate, ssml_str, tune, extra, msg.postfx.str(), msg.text },
    );
}

/// v1.10.8 — format the extra quintuple `<tech>:<comma>:<sentence>:<newline>:<speaker>`.
/// Each component is either its concrete value or `-` for "unset". When
/// every component is at its default, returns an empty string so the
/// 8-field common case stays untouched on the wire.
pub fn formatExtraQuintuple(
    arena: std.mem.Allocator,
    tech: bool,
    comma_ms: u32,
    sentence_ms: u32,
    newline_ms: u32,
    speaker_id: i32,
) ![]u8 {
    const all_default = !tech and comma_ms == 0 and sentence_ms == 0 and newline_ms == 0 and speaker_id < 0;
    if (all_default) return try arena.dupe(u8, "");

    var bufs: [5][32]u8 = undefined;
    const tech_str: []const u8 = if (tech) "1" else "-";
    const comma_str: []const u8 = if (comma_ms == 0) "-" else try std.fmt.bufPrint(&bufs[0], "{d}", .{comma_ms});
    const sent_str: []const u8 = if (sentence_ms == 0) "-" else try std.fmt.bufPrint(&bufs[1], "{d}", .{sentence_ms});
    const nl_str: []const u8 = if (newline_ms == 0) "-" else try std.fmt.bufPrint(&bufs[2], "{d}", .{newline_ms});
    const sp_str: []const u8 = if (speaker_id < 0) "-" else try std.fmt.bufPrint(&bufs[3], "{d}", .{speaker_id});
    return try std.fmt.allocPrint(arena, "{s}:{s}:{s}:{s}:{s}", .{ tech_str, comma_str, sent_str, nl_str, sp_str });
}

/// v1.10.8 — parsed extra quintuple. `tech` defaults false; pause /
/// speaker defaults are the unset sentinels (0 / -1).
pub const ExtraQuintuple = struct {
    tech: bool = false,
    comma_ms: u32 = 0,
    sentence_ms: u32 = 0,
    newline_ms: u32 = 0,
    speaker_id: i32 = -1,
};

pub fn parseExtraQuintuple(s: []const u8) ParseError!ExtraQuintuple {
    var out: ExtraQuintuple = .{};
    if (s.len == 0) return out;

    var it = std.mem.splitScalar(u8, s, ':');
    const a = it.next() orelse return error.Malformed;
    const b = it.next() orelse return error.Malformed;
    const c = it.next() orelse return error.Malformed;
    const d = it.next() orelse return error.Malformed;
    const e = it.next() orelse return error.Malformed;
    if (it.next() != null) return error.Malformed;

    if (a.len > 0 and !std.mem.eql(u8, a, "-")) {
        if (std.mem.eql(u8, a, "1")) {
            out.tech = true;
        } else if (std.mem.eql(u8, a, "0")) {
            out.tech = false;
        } else return error.Malformed;
    }
    if (b.len > 0 and !std.mem.eql(u8, b, "-")) {
        out.comma_ms = std.fmt.parseInt(u32, b, 10) catch return error.Malformed;
    }
    if (c.len > 0 and !std.mem.eql(u8, c, "-")) {
        out.sentence_ms = std.fmt.parseInt(u32, c, 10) catch return error.Malformed;
    }
    if (d.len > 0 and !std.mem.eql(u8, d, "-")) {
        out.newline_ms = std.fmt.parseInt(u32, d, 10) catch return error.Malformed;
    }
    if (e.len > 0 and !std.mem.eql(u8, e, "-")) {
        out.speaker_id = std.fmt.parseInt(i32, e, 10) catch return error.Malformed;
    }
    return out;
}

/// v1.10.8 — heuristic: does this field look like the 5-tuple extra
/// slot? Empty is yes (signals all defaults). Otherwise the field needs
/// at least 4 colons AND every character must be in `[0-9-:]` (no
/// dots — those would be tune triplet floats, not pause integers).
fn looksLikeExtraQuintuple(s: []const u8) bool {
    if (s.len == 0) return true;
    var colon_count: usize = 0;
    for (s) |ch| {
        if (ch == ':') {
            colon_count += 1;
            continue;
        }
        const ok = (ch >= '0' and ch <= '9') or ch == '-';
        if (!ok) return false;
    }
    return colon_count == 4;
}

/// v1.10.7 — format the per-call tune triplet for the 8-field wire.
/// Each unset component is encoded as `-`; all-unset returns an empty
/// string so the parser can short-circuit the common case.
pub fn formatTuneTriplet(
    arena: std.mem.Allocator,
    length_scale: f32,
    noise_scale: f32,
    noise_w: f32,
) ![]u8 {
    const len_set = length_scale > 0;
    const ns_set = noise_scale >= 0;
    const nw_set = noise_w >= 0;
    if (!len_set and !ns_set and !nw_set) return try arena.dupe(u8, "");

    var len_buf: [32]u8 = undefined;
    var ns_buf: [32]u8 = undefined;
    var nw_buf: [32]u8 = undefined;
    const len_str: []const u8 = if (len_set)
        try std.fmt.bufPrint(&len_buf, "{d}", .{length_scale})
    else
        "-";
    const ns_str: []const u8 = if (ns_set)
        try std.fmt.bufPrint(&ns_buf, "{d}", .{noise_scale})
    else
        "-";
    const nw_str: []const u8 = if (nw_set)
        try std.fmt.bufPrint(&nw_buf, "{d}", .{noise_w})
    else
        "-";
    return try std.fmt.allocPrint(arena, "{s}:{s}:{s}", .{ len_str, ns_str, nw_str });
}

/// v1.10.7 — parse a tune triplet of the form `<length>:<noise>:<noise_w>`.
/// Components may be `-` (or empty) to leave the corresponding knob at its
/// sentinel default. Empty input returns all-sentinels. Returns
/// `error.Malformed` on shape errors (wrong colon count, invalid float).
pub const TuneTriplet = struct {
    length_scale: f32,
    noise_scale: f32,
    noise_w: f32,
};

pub fn parseTuneTriplet(s: []const u8) ParseError!TuneTriplet {
    var out: TuneTriplet = .{
        .length_scale = 0.0,
        .noise_scale = -1.0,
        .noise_w = -1.0,
    };
    if (s.len == 0) return out;

    var it = std.mem.splitScalar(u8, s, ':');
    const a = it.next() orelse return error.Malformed;
    const b = it.next() orelse return error.Malformed;
    const c = it.next() orelse return error.Malformed;
    if (it.next() != null) return error.Malformed;

    if (a.len > 0 and !std.mem.eql(u8, a, "-")) {
        out.length_scale = std.fmt.parseFloat(f32, a) catch return error.Malformed;
    }
    if (b.len > 0 and !std.mem.eql(u8, b, "-")) {
        out.noise_scale = std.fmt.parseFloat(f32, b) catch return error.Malformed;
    }
    if (c.len > 0 and !std.mem.eql(u8, c, "-")) {
        out.noise_w = std.fmt.parseFloat(f32, c) catch return error.Malformed;
    }
    return out;
}

/// v1.10.7 — detect whether the field between ssml and text is a tune
/// triplet (8-field form) versus the text itself (7-field form). An empty
/// field IS the tune slot — text is never empty post-sanitization. A field
/// containing `:` AND only `[0-9.\-:]` characters is also unambiguously a
/// tune triplet; the 7-field text could in principle contain `:` (e.g.
/// "10:30") so we additionally require all characters to look numeric.
fn looksLikeTuneTriplet(s: []const u8) bool {
    if (s.len == 0) return true;
    if (std.mem.indexOfScalar(u8, s, ':') == null) return false;
    for (s) |ch| {
        const ok = (ch >= '0' and ch <= '9') or ch == '.' or ch == '-' or ch == ':';
        if (!ok) return false;
    }
    return true;
}

pub const ParseError = error{ Malformed, UnknownOp, InvalidRate };

pub fn parseRequest(arena: std.mem.Allocator, line: []const u8) ParseError!Request {
    var it = std.mem.splitScalar(u8, line, '\t');
    const op = it.next() orelse return error.Malformed;

    if (std.mem.eql(u8, op, "ENQUEUE")) {
        const first = it.next() orelse return error.Malformed;
        if (Engine.fromStr(first)) |engine| {
            // New layout (v0.7 or v1.1+). Peek the next field for Lang.
            const second = it.next() orelse return error.Malformed;
            if (Lang.fromStr(second)) |lang| {
                // v1.1 6-field or v1.8 7-field. Both share the prefix
                // ENQUEUE\t<engine>\t<lang>\t<voice>\t<rate>; the
                // disambiguator sits between rate and text.
                const voice = it.next() orelse return error.Malformed;
                const rate_str = it.next() orelse return error.Malformed;
                const after_rate = it.next() orelse return error.Malformed;
                const rate = std.fmt.parseInt(u32, rate_str, 10) catch return error.InvalidRate;
                const voice_dup = arena.dupe(u8, voice) catch return error.Malformed;

                // v1.8: a bare "0" or "1" between rate and text marks the
                // ssml flag. Old clients send text directly — anything
                // longer than one byte or not in {'0','1'} keeps the
                // v1.1 6-field shape (after_rate IS the text).
                if (after_rate.len == 1 and (after_rate[0] == '0' or after_rate[0] == '1')) {
                    const ssml_flag = after_rate[0] == '1';
                    // v1.10.7: peek the next field to disambiguate 7- vs 8-
                    // field. The 8-field form inserts a tune triplet between
                    // ssml and text (`<length>:<noise>:<noise_w>` or empty).
                    // The 7-field form puts text here directly. Differ:
                    //   - empty field => always the tune slot (text never empty)
                    //   - looks like tune triplet => 8-field
                    //   - otherwise => 7-field, this token IS the first text segment
                    const peek = it.next() orelse {
                        // No more fields means after_rate must have been text
                        // for v1.8 — but that requires text="0"/"1" which is
                        // possible. Honor it.
                        return error.Malformed;
                    };

                    if (looksLikeTuneTriplet(peek)) {
                        // v1.10.7 8-field or v1.10.8 9-field path. Parse the
                        // tune triplet first, then peek the NEXT field: if it
                        // looks like the extra quintuple (empty OR
                        // [0-9-:] only with 4 colons) we're in 9-field land.
                        // Otherwise that field IS the text head and we're in
                        // legacy 8-field.
                        const tune = try parseTuneTriplet(peek);

                        const extra_peek_opt = it.next();
                        if (extra_peek_opt == null) return error.Malformed;
                        const extra_peek = extra_peek_opt.?;

                        if (looksLikeExtraQuintuple(extra_peek)) {
                            const extra = try parseExtraQuintuple(extra_peek);
                            // v1.10.10 — peek next field. If it's a Postfx
                            // tag we're in 10-field land; otherwise it
                            // starts the text and we're in legacy 9-field.
                            const post_peek_opt = it.next();
                            if (post_peek_opt == null) return error.Malformed;
                            const post_peek = post_peek_opt.?;
                            const maybe_postfx = Postfx.fromStr(post_peek);
                            if (maybe_postfx) |pfx| {
                                const text = it.rest();
                                if (text.len == 0) return error.Malformed;
                                const text_dup = arena.dupe(u8, text) catch return error.Malformed;
                                return .{ .enqueue = .{
                                    .engine = engine,
                                    .lang = lang,
                                    .voice = voice_dup,
                                    .rate = rate,
                                    .ssml = ssml_flag,
                                    .length_scale = tune.length_scale,
                                    .noise_scale = tune.noise_scale,
                                    .noise_w = tune.noise_w,
                                    .tech = extra.tech,
                                    .comma_pause_ms = extra.comma_ms,
                                    .sentence_pause_ms = extra.sentence_ms,
                                    .newline_pause_ms = extra.newline_ms,
                                    .speaker_id = extra.speaker_id,
                                    .postfx = pfx,
                                    .text = text_dup,
                                } };
                            }
                            // v1.10.8 9-field: post_peek is text head;
                            // splice with the remainder.
                            const rest_after_extra = it.rest();
                            const text_dup_9 = blk9: {
                                if (rest_after_extra.len == 0) {
                                    const dup = arena.dupe(u8, post_peek) catch return error.Malformed;
                                    break :blk9 dup;
                                }
                                const total = arena.alloc(u8, post_peek.len + 1 + rest_after_extra.len) catch return error.Malformed;
                                @memcpy(total[0..post_peek.len], post_peek);
                                total[post_peek.len] = '\t';
                                @memcpy(total[post_peek.len + 1 ..], rest_after_extra);
                                break :blk9 total;
                            };
                            if (text_dup_9.len == 0) return error.Malformed;
                            return .{ .enqueue = .{
                                .engine = engine,
                                .lang = lang,
                                .voice = voice_dup,
                                .rate = rate,
                                .ssml = ssml_flag,
                                .length_scale = tune.length_scale,
                                .noise_scale = tune.noise_scale,
                                .noise_w = tune.noise_w,
                                .tech = extra.tech,
                                .comma_pause_ms = extra.comma_ms,
                                .sentence_pause_ms = extra.sentence_ms,
                                .newline_pause_ms = extra.newline_ms,
                                .speaker_id = extra.speaker_id,
                                .text = text_dup_9,
                            } };
                        }

                        // v1.10.7 8-field: extra_peek IS the first text segment.
                        const rest_after_tune = it.rest();
                        const text_dup = blk3: {
                            if (rest_after_tune.len == 0) {
                                const dup = arena.dupe(u8, extra_peek) catch return error.Malformed;
                                break :blk3 dup;
                            }
                            const total = arena.alloc(u8, extra_peek.len + 1 + rest_after_tune.len) catch return error.Malformed;
                            @memcpy(total[0..extra_peek.len], extra_peek);
                            total[extra_peek.len] = '\t';
                            @memcpy(total[extra_peek.len + 1 ..], rest_after_tune);
                            break :blk3 total;
                        };
                        if (text_dup.len == 0) return error.Malformed;
                        return .{ .enqueue = .{
                            .engine = engine,
                            .lang = lang,
                            .voice = voice_dup,
                            .rate = rate,
                            .ssml = ssml_flag,
                            .length_scale = tune.length_scale,
                            .noise_scale = tune.noise_scale,
                            .noise_w = tune.noise_w,
                            .text = text_dup,
                        } };
                    }

                    // v1.8 7-field path: `peek` is the first text segment;
                    // splice with whatever the iterator still has.
                    const rest_after = it.rest();
                    const text_dup = blk2: {
                        if (rest_after.len == 0) {
                            const dup = arena.dupe(u8, peek) catch return error.Malformed;
                            break :blk2 dup;
                        }
                        const total = arena.alloc(u8, peek.len + 1 + rest_after.len) catch return error.Malformed;
                        @memcpy(total[0..peek.len], peek);
                        total[peek.len] = '\t';
                        @memcpy(total[peek.len + 1 ..], rest_after);
                        break :blk2 total;
                    };
                    if (text_dup.len == 0) return error.Malformed;
                    return .{ .enqueue = .{
                        .engine = engine,
                        .lang = lang,
                        .voice = voice_dup,
                        .rate = rate,
                        .ssml = ssml_flag,
                        .text = text_dup,
                    } };
                }

                // v1.1 6-field — after_rate is the first text field; we
                // need to splice it back together with whatever the
                // iterator still has.
                const rest = it.rest();
                const text_dup = blk: {
                    if (rest.len == 0) {
                        const dup = arena.dupe(u8, after_rate) catch return error.Malformed;
                        break :blk dup;
                    }
                    const total = arena.alloc(u8, after_rate.len + 1 + rest.len) catch return error.Malformed;
                    @memcpy(total[0..after_rate.len], after_rate);
                    total[after_rate.len] = '\t';
                    @memcpy(total[after_rate.len + 1 ..], rest);
                    break :blk total;
                };
                if (text_dup.len == 0) return error.Malformed;
                return .{ .enqueue = .{
                    .engine = engine,
                    .lang = lang,
                    .voice = voice_dup,
                    .rate = rate,
                    .ssml = false,
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
                .engine = .kokoro,
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
    // v1.10.2 — pause / resume / replay / history. PAUSE and RESUME take
    // no payload. REPLAY takes a single u64 id. HISTORY takes a single
    // u32 limit (clamped to 100 here).
    if (std.mem.eql(u8, op, "PAUSE")) return .pause;
    if (std.mem.eql(u8, op, "RESUME")) return .resume_play;
    if (std.mem.eql(u8, op, "REPLAY")) {
        const id_str = it.next() orelse return error.Malformed;
        const id = std.fmt.parseInt(u64, id_str, 10) catch return error.Malformed;
        return .{ .replay = id };
    }
    if (std.mem.eql(u8, op, "HISTORY")) {
        const limit_str = it.next() orelse return error.Malformed;
        const raw = std.fmt.parseInt(u32, limit_str, 10) catch return error.Malformed;
        const limit: u32 = if (raw == 0) 20 else @min(raw, 100);
        return .{ .history = limit };
    }
    return error.UnknownOp;
}

// ---- tests (v0.7 + v1.1) ----

test "parseRequest legacy v0.6 4-field ENQUEUE defaults engine=kokoro lang=auto" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tpf_dora\t330\tOlá mundo");
    try std.testing.expect(req == .enqueue);
    // v0.6: first token is voice (not engine); engine defaults to kokoro
    try std.testing.expectEqual(Lang.auto, req.enqueue.lang);
    try std.testing.expectEqualStrings("pf_dora", req.enqueue.voice);
    try std.testing.expectEqual(@as(u32, 330), req.enqueue.rate);
    try std.testing.expectEqualStrings("Olá mundo", req.enqueue.text);
}

test "parseRequest v0.7 5-field ENQUEUE with explicit kokoro + default lang=auto" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tkokoro\tpf_dora\t330\tOlá");
    try std.testing.expectEqual(Engine.kokoro, req.enqueue.engine);
    try std.testing.expectEqual(Lang.auto, req.enqueue.lang);
    try std.testing.expectEqualStrings("pf_dora", req.enqueue.voice);
    try std.testing.expectEqualStrings("Olá", req.enqueue.text);
}

test "parseRequest v0.7 5-field legacy say token maps to kokoro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tsay\tpf_dora\t330\tOlá");
    try std.testing.expectEqual(Engine.kokoro, req.enqueue.engine);
    try std.testing.expectEqual(Lang.auto, req.enqueue.lang);
    try std.testing.expectEqualStrings("pf_dora", req.enqueue.voice);
}

test "parseRequest v0.7 5-field legacy piper token maps to kokoro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tpiper\tpf_dora\t330\tOlá");
    try std.testing.expectEqual(Engine.kokoro, req.enqueue.engine);
    try std.testing.expectEqual(Lang.auto, req.enqueue.lang);
    try std.testing.expectEqualStrings("pf_dora", req.enqueue.voice);
}

test "parseRequest v1.1 6-field ENQUEUE with explicit lang=pt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tkokoro\tpt\tpf_dora\t330\tOlá mundo");
    try std.testing.expectEqual(Engine.kokoro, req.enqueue.engine);
    try std.testing.expectEqual(Lang.pt, req.enqueue.lang);
    try std.testing.expectEqualStrings("pf_dora", req.enqueue.voice);
    try std.testing.expectEqualStrings("Olá mundo", req.enqueue.text);
}

test "parseRequest v1.1 6-field ENQUEUE with lang=en" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tkokoro\ten\tpf_dora\t330\tHello world");
    try std.testing.expectEqual(Lang.en, req.enqueue.lang);
    try std.testing.expectEqualStrings("pf_dora", req.enqueue.voice);
}

test "parseRequest v1.1 6-field ENQUEUE with lang=auto explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tkokoro\tauto\tpf_dora\t330\tOlá");
    try std.testing.expectEqual(Lang.auto, req.enqueue.lang);
}

test "encodeEnqueue v1.1 round-trips through parseRequest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: Message = .{
        .engine = .kokoro,
        .lang = .en,
        .voice = "pf_dora",
        .rate = 220,
        .text = "Hello, how are you?",
    };
    const wire = try encodeEnqueue(a, original);
    const line = wire[0 .. wire.len - 1];
    const req = try parseRequest(a, line);
    try std.testing.expectEqual(Engine.kokoro, req.enqueue.engine);
    try std.testing.expectEqual(Lang.en, req.enqueue.lang);
    try std.testing.expectEqualStrings("pf_dora", req.enqueue.voice);
    try std.testing.expectEqual(@as(u32, 220), req.enqueue.rate);
    try std.testing.expectEqualStrings("Hello, how are you?", req.enqueue.text);
}

test "Engine.fromStr accepts kokoro and legacy compat tokens" {
    try std.testing.expectEqual(Engine.kokoro, Engine.fromStr("kokoro").?);
    // Legacy compat — all old engine strings map to kokoro now.
    try std.testing.expectEqual(Engine.kokoro, Engine.fromStr("say").?);
    try std.testing.expectEqual(Engine.kokoro, Engine.fromStr("piper").?);
    try std.testing.expectEqual(Engine.kokoro, Engine.fromStr("cloned").?);
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

test "parseRequest v1.8 7-field ENQUEUE with ssml=1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tkokoro\tpt\tpf_dora\t330\t1\t<emphasis>Olá</emphasis>",
    );
    try std.testing.expectEqual(Engine.kokoro, req.enqueue.engine);
    try std.testing.expectEqual(Lang.pt, req.enqueue.lang);
    try std.testing.expectEqual(true, req.enqueue.ssml);
    try std.testing.expectEqualStrings("<emphasis>Olá</emphasis>", req.enqueue.text);
}

test "parseRequest v1.8 7-field ENQUEUE with ssml=0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tkokoro\tauto\tpf_dora\t330\t0\tOlá mundo",
    );
    try std.testing.expectEqual(false, req.enqueue.ssml);
    try std.testing.expectEqualStrings("Olá mundo", req.enqueue.text);
}

test "parseRequest v1.1 text starting with digit is not misread as ssml flag" {
    // A v1.1 client sending text "1 dois 3" must still parse as v1.1 (ssml=false).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tkokoro\tpt\tpf_dora\t330\t1 dois 3",
    );
    try std.testing.expectEqual(false, req.enqueue.ssml);
    try std.testing.expectEqualStrings("1 dois 3", req.enqueue.text);
}

test "parseRequest v1.1 6-field still works (ssml defaults false)" {
    // Backward-compat: pre-v1.8 clients omit the ssml field. Parser must
    // recognise the absence and default to ssml=false.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tkokoro\tpt\tpf_dora\t330\tOlá mundo",
    );
    try std.testing.expectEqual(false, req.enqueue.ssml);
    try std.testing.expectEqualStrings("Olá mundo", req.enqueue.text);
}

test "encodeEnqueue v1.8 round-trips ssml flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: Message = .{
        .engine = .kokoro,
        .lang = .pt,
        .voice = "pf_dora",
        .rate = 300,
        .ssml = true,
        .text = "<emphasis>Olá</emphasis>",
    };
    const wire = try encodeEnqueue(a, original);
    const line = wire[0 .. wire.len - 1];
    const req = try parseRequest(a, line);
    try std.testing.expectEqual(true, req.enqueue.ssml);
    try std.testing.expectEqualStrings(original.text, req.enqueue.text);
}

test "parseRequest legacy 5-field ENQUEUE with cloned engine maps to kokoro" {
    // Legacy cloned token now maps to kokoro (sole engine).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "ENQUEUE\tcloned\tpf_dora\t330\tOlá");
    try std.testing.expectEqual(Engine.kokoro, req.enqueue.engine);
    try std.testing.expectEqualStrings("pf_dora", req.enqueue.voice);
}

// v1.10.2 — pause / resume / replay / history parser tests.

test "parseRequest PAUSE has no payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "PAUSE");
    try std.testing.expect(req == .pause);
}

test "parseRequest RESUME has no payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "RESUME");
    try std.testing.expect(req == .resume_play);
}

test "parseRequest REPLAY parses u64 id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "REPLAY\t42");
    try std.testing.expect(req == .replay);
    try std.testing.expectEqual(@as(u64, 42), req.replay);
}

test "parseRequest REPLAY without id is malformed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Malformed, parseRequest(arena.allocator(), "REPLAY"));
}

test "parseRequest REPLAY with non-numeric id is malformed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Malformed, parseRequest(arena.allocator(), "REPLAY\tabc"));
}

test "parseRequest HISTORY parses u32 limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "HISTORY\t10");
    try std.testing.expect(req == .history);
    try std.testing.expectEqual(@as(u32, 10), req.history);
}

test "parseRequest HISTORY clamps limit to 100" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "HISTORY\t999");
    try std.testing.expectEqual(@as(u32, 100), req.history);
}

test "parseRequest HISTORY with 0 defaults to 20" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(), "HISTORY\t0");
    try std.testing.expectEqual(@as(u32, 20), req.history);
}

test "parseRequest unknown op still errors (no false positive on PAUSE prefix)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnknownOp, parseRequest(arena.allocator(), "PAUSED"));
}

test "v1.10.2 backward-compat: old QUEUE/SKIP/CLEAR still parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try parseRequest(arena.allocator(), "QUEUE")) == .queue);
    try std.testing.expect((try parseRequest(arena.allocator(), "SKIP")) == .skip);
    try std.testing.expect((try parseRequest(arena.allocator(), "CLEAR")) == .clear);
}

// ---- v1.10.7 — per-call piper knobs (8-field wire) ----

test "v1.10.7 parseRequest 8-field ENQUEUE with all 3 knobs set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tkokoro\tpt\tpf_dora\t330\t0\t1.05:0.8:1\tOlá warm Dora.",
    );
    try std.testing.expectEqual(Engine.kokoro, req.enqueue.engine);
    try std.testing.expectEqual(Lang.pt, req.enqueue.lang);
    try std.testing.expectEqualStrings("pf_dora", req.enqueue.voice);
    try std.testing.expectEqual(@as(u32, 330), req.enqueue.rate);
    try std.testing.expectEqual(false, req.enqueue.ssml);
    try std.testing.expectApproxEqAbs(@as(f32, 1.05), req.enqueue.length_scale, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), req.enqueue.noise_scale, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), req.enqueue.noise_w, 0.0001);
    try std.testing.expectEqualStrings("Olá warm Dora.", req.enqueue.text);
}

test "v1.10.7 parseRequest 8-field ENQUEUE with empty tune triplet means defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tpiper\tpt\tfaber\t330\t0\t\tOlá",
    );
    try std.testing.expectEqual(@as(f32, 0.0), req.enqueue.length_scale);
    try std.testing.expectEqual(@as(f32, -1.0), req.enqueue.noise_scale);
    try std.testing.expectEqual(@as(f32, -1.0), req.enqueue.noise_w);
    try std.testing.expectEqualStrings("Olá", req.enqueue.text);
}

test "v1.10.7 parseRequest 8-field ENQUEUE with only noise_w set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tpiper\tpt\tfaber\t330\t0\t-:-:0.95\tOi.",
    );
    try std.testing.expectEqual(@as(f32, 0.0), req.enqueue.length_scale);
    try std.testing.expectEqual(@as(f32, -1.0), req.enqueue.noise_scale);
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), req.enqueue.noise_w, 0.0001);
}

test "v1.10.7 encodeEnqueue round-trips per-call knobs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: Message = .{
        .engine = .kokoro,
        .lang = .pt,
        .voice = "faber",
        .rate = 330,
        .ssml = false,
        .length_scale = 1.1,
        .noise_scale = 0.7,
        .noise_w = 1.0,
        .text = "Teste warm.",
    };
    const wire = try encodeEnqueue(a, original);
    const line = wire[0 .. wire.len - 1];
    const req = try parseRequest(a, line);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), req.enqueue.length_scale, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), req.enqueue.noise_scale, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), req.enqueue.noise_w, 0.001);
    try std.testing.expectEqualStrings("Teste warm.", req.enqueue.text);
}

test "v1.10.7 encodeEnqueue with all knobs unset emits empty tune slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: Message = .{
        .engine = .kokoro,
        .lang = .pt,
        .voice = "faber",
        .rate = 330,
        .text = "Olá",
    };
    const wire = try encodeEnqueue(a, original);
    // The triplet between ssml and text should be empty.
    try std.testing.expect(std.mem.indexOf(u8, wire, "\t\t") != null);
    const line = wire[0 .. wire.len - 1];
    const req = try parseRequest(a, line);
    try std.testing.expectEqual(@as(f32, 0.0), req.enqueue.length_scale);
    try std.testing.expectEqual(@as(f32, -1.0), req.enqueue.noise_scale);
    try std.testing.expectEqual(@as(f32, -1.0), req.enqueue.noise_w);
}

test "v1.10.7 parseTuneTriplet handles dashes and floats" {
    const t1 = try parseTuneTriplet("1.05:0.8:1.0");
    try std.testing.expectApproxEqAbs(@as(f32, 1.05), t1.length_scale, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), t1.noise_scale, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), t1.noise_w, 0.001);

    const t2 = try parseTuneTriplet("-:-:-");
    try std.testing.expectEqual(@as(f32, 0.0), t2.length_scale);
    try std.testing.expectEqual(@as(f32, -1.0), t2.noise_scale);
    try std.testing.expectEqual(@as(f32, -1.0), t2.noise_w);

    const t3 = try parseTuneTriplet("");
    try std.testing.expectEqual(@as(f32, 0.0), t3.length_scale);

    try std.testing.expectError(error.Malformed, parseTuneTriplet("1.0:0.8"));
    try std.testing.expectError(error.Malformed, parseTuneTriplet("abc:0.8:1.0"));
}

// ---- v1.10.8 — extra quintuple (9-field wire) ----

test "v1.10.8 parseRequest 9-field ENQUEUE with tech=1 and pauses set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tpiper\tpt\tfaber\t330\t0\t-:-:-\t1:120:500:700:-\tAPI rodou.",
    );
    try std.testing.expectEqual(true, req.enqueue.tech);
    try std.testing.expectEqual(@as(u32, 120), req.enqueue.comma_pause_ms);
    try std.testing.expectEqual(@as(u32, 500), req.enqueue.sentence_pause_ms);
    try std.testing.expectEqual(@as(u32, 700), req.enqueue.newline_pause_ms);
    try std.testing.expectEqual(@as(i32, -1), req.enqueue.speaker_id);
    try std.testing.expectEqualStrings("API rodou.", req.enqueue.text);
}

test "v1.10.8 parseRequest 9-field with speaker_id set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tpiper\tpt\tfaber\t330\t0\t-:-:-\t-:-:-:-:3\tOlá",
    );
    try std.testing.expectEqual(false, req.enqueue.tech);
    try std.testing.expectEqual(@as(i32, 3), req.enqueue.speaker_id);
}

test "v1.10.8 parseRequest 9-field empty extra slot keeps defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tpiper\tpt\tfaber\t330\t0\t1.05:0.667:0.85\t\tTeste warm.",
    );
    try std.testing.expectEqual(false, req.enqueue.tech);
    try std.testing.expectEqual(@as(u32, 0), req.enqueue.comma_pause_ms);
    try std.testing.expectEqual(@as(i32, -1), req.enqueue.speaker_id);
    try std.testing.expectApproxEqAbs(@as(f32, 1.05), req.enqueue.length_scale, 0.001);
    try std.testing.expectEqualStrings("Teste warm.", req.enqueue.text);
}

test "v1.10.8 encodeEnqueue round-trips extra quintuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: Message = .{
        .engine = .kokoro,
        .lang = .pt,
        .voice = "faber",
        .rate = 330,
        .ssml = false,
        .length_scale = 0.95,
        .noise_scale = 0.667,
        .noise_w = 0.85,
        .tech = true,
        .comma_pause_ms = 120,
        .sentence_pause_ms = 500,
        .newline_pause_ms = 700,
        .speaker_id = 2,
        .text = "API e MCP rodam em CPU.",
    };
    const wire = try encodeEnqueue(a, original);
    const line = wire[0 .. wire.len - 1];
    const req = try parseRequest(a, line);
    try std.testing.expectEqual(true, req.enqueue.tech);
    try std.testing.expectEqual(@as(u32, 120), req.enqueue.comma_pause_ms);
    try std.testing.expectEqual(@as(u32, 500), req.enqueue.sentence_pause_ms);
    try std.testing.expectEqual(@as(u32, 700), req.enqueue.newline_pause_ms);
    try std.testing.expectEqual(@as(i32, 2), req.enqueue.speaker_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), req.enqueue.length_scale, 0.001);
    try std.testing.expectEqualStrings("API e MCP rodam em CPU.", req.enqueue.text);
}

test "v1.10.8 encodeEnqueue all extras unset emits empty extra slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: Message = .{
        .engine = .kokoro,
        .lang = .pt,
        .voice = "faber",
        .rate = 330,
        .text = "Olá",
    };
    const wire = try encodeEnqueue(a, original);
    // Wire should contain two adjacent tabs (empty tune AND empty extra
    // → "\t\t\t" sequence between rate-field and text).
    try std.testing.expect(std.mem.indexOf(u8, wire, "\t\t\t") != null);
    const line = wire[0 .. wire.len - 1];
    const req = try parseRequest(a, line);
    try std.testing.expectEqual(false, req.enqueue.tech);
    try std.testing.expectEqual(@as(i32, -1), req.enqueue.speaker_id);
    try std.testing.expectEqualStrings("Olá", req.enqueue.text);
}

test "v1.10.8 parseExtraQuintuple shapes" {
    const t1 = try parseExtraQuintuple("1:120:500:700:2");
    try std.testing.expectEqual(true, t1.tech);
    try std.testing.expectEqual(@as(u32, 120), t1.comma_ms);
    try std.testing.expectEqual(@as(u32, 500), t1.sentence_ms);
    try std.testing.expectEqual(@as(u32, 700), t1.newline_ms);
    try std.testing.expectEqual(@as(i32, 2), t1.speaker_id);

    const t2 = try parseExtraQuintuple("-:-:-:-:-");
    try std.testing.expectEqual(false, t2.tech);
    try std.testing.expectEqual(@as(u32, 0), t2.comma_ms);
    try std.testing.expectEqual(@as(i32, -1), t2.speaker_id);

    const t3 = try parseExtraQuintuple("");
    try std.testing.expectEqual(false, t3.tech);
    try std.testing.expectEqual(@as(i32, -1), t3.speaker_id);

    try std.testing.expectError(error.Malformed, parseExtraQuintuple("1:120:500"));
    try std.testing.expectError(error.Malformed, parseExtraQuintuple("x:120:500:700:2"));
}

test "v1.10.8 backward-compat: v1.10.7 8-field still parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tpiper\tpt\tfaber\t330\t0\t1.05:0.8:1\tOlá warm Dora.",
    );
    try std.testing.expectApproxEqAbs(@as(f32, 1.05), req.enqueue.length_scale, 0.001);
    try std.testing.expectEqual(false, req.enqueue.tech);
    try std.testing.expectEqual(@as(i32, -1), req.enqueue.speaker_id);
    try std.testing.expectEqualStrings("Olá warm Dora.", req.enqueue.text);
}

test "v1.10.7 backward-compat: v1.8 7-field still parses with knobs at sentinels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tpiper\tpt\tfaber\t330\t0\tTexto sem tune.",
    );
    try std.testing.expectEqual(@as(f32, 0.0), req.enqueue.length_scale);
    try std.testing.expectEqual(@as(f32, -1.0), req.enqueue.noise_scale);
    try std.testing.expectEqualStrings("Texto sem tune.", req.enqueue.text);
}

// ---- v1.10.10 — postfx (10-field wire) ----

test "v1.10.10 parseRequest 10-field ENQUEUE with postfx=tech" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tpiper\tpt\tfaber\t330\t0\t1.05:0.35:0.45\t1:-:500:-:-\ttech\tAPI rodou.",
    );
    try std.testing.expectEqual(Engine.kokoro, req.enqueue.engine);
    try std.testing.expectEqual(Postfx.tech, req.enqueue.postfx);
    try std.testing.expectEqual(true, req.enqueue.tech);
    try std.testing.expectApproxEqAbs(@as(f32, 1.05), req.enqueue.length_scale, 0.001);
    try std.testing.expectEqualStrings("API rodou.", req.enqueue.text);
}

test "v1.10.10 parseRequest 10-field with postfx=off explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tpiper\tpt\tfaber\t330\t0\t-:-:-\t\toff\tOlá",
    );
    try std.testing.expectEqual(Postfx.off, req.enqueue.postfx);
    try std.testing.expectEqualStrings("Olá", req.enqueue.text);
}

test "v1.10.10 parseRequest accepts clean and broadcast postfx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r1 = try parseRequest(a, "ENQUEUE\tpiper\tpt\tfaber\t330\t0\t\t\tclean\tOi");
    try std.testing.expectEqual(Postfx.clean, r1.enqueue.postfx);
    const r2 = try parseRequest(a, "ENQUEUE\tpiper\tpt\tfaber\t330\t0\t\t\tbroadcast\tOi");
    try std.testing.expectEqual(Postfx.broadcast, r2.enqueue.postfx);
}

test "v1.10.10 encodeEnqueue with postfx=tech round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: Message = .{
        .engine = .kokoro,
        .lang = .pt,
        .voice = "faber",
        .rate = 330,
        .ssml = false,
        .length_scale = 1.05,
        .noise_scale = 0.35,
        .noise_w = 0.45,
        .tech = true,
        .sentence_pause_ms = 500,
        .postfx = .tech,
        .text = "ptah versão 1.10.10",
    };
    const wire = try encodeEnqueue(a, original);
    const line = wire[0 .. wire.len - 1];
    const req = try parseRequest(a, line);
    try std.testing.expectEqual(Postfx.tech, req.enqueue.postfx);
    try std.testing.expectEqual(true, req.enqueue.tech);
    try std.testing.expectApproxEqAbs(@as(f32, 1.05), req.enqueue.length_scale, 0.001);
    try std.testing.expectEqualStrings("ptah versão 1.10.10", req.enqueue.text);
}

test "v1.10.10 encodeEnqueue with postfx=off omits the postfx field (9-field wire)" {
    // Default postfx (.off) keeps the 9-field shape so older daemons
    // fed by a newer client parse cleanly.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: Message = .{
        .engine = .kokoro,
        .lang = .pt,
        .voice = "faber",
        .rate = 330,
        .text = "Olá",
    };
    const wire = try encodeEnqueue(a, original);
    // Count tabs — 9-field has 8 tabs after ENQUEUE.
    var tab_count: usize = 0;
    for (wire) |ch| {
        if (ch == '\t') tab_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), tab_count);
    const line = wire[0 .. wire.len - 1];
    const req = try parseRequest(a, line);
    try std.testing.expectEqual(Postfx.off, req.enqueue.postfx);
}

test "v1.10.10 backward-compat: v1.10.8 9-field still parses, postfx defaults off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tpiper\tpt\tfaber\t330\t0\t-:-:-\t1:120:500:700:-\tAPI rodou.",
    );
    try std.testing.expectEqual(Postfx.off, req.enqueue.postfx);
    try std.testing.expectEqual(true, req.enqueue.tech);
    try std.testing.expectEqual(@as(u32, 120), req.enqueue.comma_pause_ms);
    try std.testing.expectEqualStrings("API rodou.", req.enqueue.text);
}

test "v1.10.10 parseRequest text head that happens to look like Postfx is treated as 10-field" {
    // Edge case: a 9-field message whose text begins with the literal
    // word "tech" would tip into the 10-field path. We accept that —
    // callers needing the literal word "tech" as text head should send
    // explicit `--postfx off` so the field separator is unambiguous.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(
        arena.allocator(),
        "ENQUEUE\tpiper\tpt\tfaber\t330\t0\t-:-:-\t\ttech\trodou ok.",
    );
    try std.testing.expectEqual(Postfx.tech, req.enqueue.postfx);
    try std.testing.expectEqualStrings("rodou ok.", req.enqueue.text);
}
