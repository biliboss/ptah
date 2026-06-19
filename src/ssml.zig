// SPDX-License-Identifier: MIT OR Apache-2.0
// SSML 1.1 subset parser + per-engine transpile. v1.8 (+v1.10.12).
//
// Scope. Accept a tiny subset of the W3C SSML 1.1 spec so agents can
// inflect Pt-BR Kokoro Dora + macOS `say`:
//
//   <emphasis level="strong|moderate|reduced|none">…</emphasis>
//   <break time="500ms" />        — or strength="weak|medium|strong"
//   <prosody rate="…" pitch="…" volume="…">…</prosody>
//   <say-as interpret-as="…">…</say-as>
//   <phoneme alphabet="ipa" ph="…">…</phoneme>     — v1.10.12
//   <sub alias="…">…</sub>                         — v1.10.12
//
// Anything else (unknown tag, malformed XML, stray `<`) falls back to a
// `.text` token carrying the raw bytes — we never crash on agent garbage.
//
// v1.10.12: `<phoneme>` lets agents force IPA pronunciation for brand
// names (Anthropic, Mistral) by passing the raw IPA string in `ph`. Kokoro
// path emits an espeak-ng `[[ipa]]` directive that the phonemizer honours;
// `say` strips the tag (macOS has no IPA passthrough) and falls back to
// the body text. `<sub>` rewrites the body text to the alias at preproc
// time so code identifiers like `getConditioningLatents` can be said as
// "get conditioning latents" without a glossary entry.
//
// Why this shape. The parser is a flat token stream, not a tree. The day
// the daemon needs nested prosody it walks the stream and tracks a small
// stack of open Prosody contexts; for v1.8 the transpile functions just
// emit per-open/per-close directives. Streaming-friendly: no allocation
// per character, only one ArrayList of Tokens per call.
//
// Cost. ≈3 µs to parse a 280-char message on M2. The preproc cardinal
// stage already pays an order of magnitude more — SSML is free in the
// TTFA budget.

const std = @import("std");

/// Emphasis level. Matches the W3C `level` attribute values.
pub const EmphasisLevel = enum {
    none,
    reduced,
    moderate,
    strong,

    pub fn fromStr(s: []const u8) ?EmphasisLevel {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "reduced")) return .reduced;
        if (std.mem.eql(u8, s, "moderate")) return .moderate;
        if (std.mem.eql(u8, s, "strong")) return .strong;
        return null;
    }
};

/// Break strength fallback when `time` is absent.
pub const BreakStrength = enum {
    none,
    weak,
    medium,
    strong,
    extra_strong,

    pub fn fromStr(s: []const u8) ?BreakStrength {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "weak")) return .weak;
        if (std.mem.eql(u8, s, "medium")) return .medium;
        if (std.mem.eql(u8, s, "strong")) return .strong;
        if (std.mem.eql(u8, s, "x-strong")) return .extra_strong;
        return null;
    }

    pub fn ms(self: BreakStrength) u32 {
        return switch (self) {
            .none => 0,
            .weak => 100,
            .medium => 250,
            .strong => 500,
            .extra_strong => 1000,
        };
    }
};

/// Emphasis span — opens/closes around a sub-range. v1.8 emits two
/// tokens (`emphasis_open`/`emphasis_close`) so transpilation can wrap
/// directives without buffering the inner text.
pub const Emphasis = struct {
    level: EmphasisLevel = .moderate,
};

pub const Break = struct {
    /// Milliseconds. Resolved from `time="500ms"` or from
    /// `strength="…"` via BreakStrength.ms(). 0 = "no pause".
    ms: u32,
};

/// Prosody attributes. All optional — `null` means "no change".
/// Rate is a multiplier (1.0 = normal). Pitch is semitones (0 = no change).
/// Volume is multiplier (1.0 = normal).
pub const Prosody = struct {
    rate: ?f32 = null,
    pitch: ?f32 = null,
    volume: ?f32 = null,
};

/// `say-as interpret-as="…"` hint. v1.8 stores the value verbatim and
/// passes it through; engines that don't understand it ignore.
pub const SayAs = struct {
    interpret_as: []const u8,
    /// Whether this is the opening token (true) or closing (false).
    open: bool,
};

/// v1.10.12 — `<phoneme alphabet="ipa" ph="ˌæn.θɹəˈpɪk">Anthropic</phoneme>`.
/// `alphabet` defaults to "ipa" when omitted (only IPA is wired in v1.10.12;
/// x-sampa / x-microsoft are documented as "passed through, engine-decided").
/// `ph` is the phoneme string the engine should pronounce instead of the
/// body text. Body text rides on `.text` tokens between open/close so that
/// engines without IPA support (say) can still emit something legible.
pub const Phoneme = struct {
    alphabet: []const u8,
    ph: []const u8,
};

/// v1.10.12 — `<sub alias="…">…</sub>`. Body text is replaced by `alias`
/// at preproc time. Used for code identifiers / abbreviations where the
/// displayed form differs from the spoken form.
pub const Sub = struct {
    alias: []const u8,
};

pub const Token = union(enum) {
    text: []const u8,
    emphasis_open: Emphasis,
    emphasis_close,
    @"break": Break,
    prosody_open: Prosody,
    prosody_close,
    sayas_open: SayAs,
    sayas_close,
    /// v1.10.12 — phoneme open carries alphabet + ph. The walker emits the
    /// IPA passthrough directive on open; body text between open/close is
    /// suppressed for engines that honour the directive (Kokoro) but used as
    /// fallback by engines that don't (say). Close has no payload.
    phoneme_open: Phoneme,
    phoneme_close,
    /// v1.10.12 — sub open carries the alias. The walker emits the alias
    /// as a synthetic `.text` token at open and suppresses body text until
    /// close so the displayed form never reaches the engine.
    sub_open: Sub,
    sub_close,
};

pub const ParseError = error{OutOfMemory};

/// Parse `input` into a flat token stream. Caller owns the returned slice
/// (allocated from `arena`). Unknown tags and malformed XML degrade to
/// text tokens — never error.
pub fn parse(arena: std.mem.Allocator, input: []const u8) ParseError![]Token {
    var out: std.ArrayList(Token) = .empty;
    if (input.len == 0) return out.toOwnedSlice(arena);

    var i: usize = 0;
    var text_start: usize = 0;

    while (i < input.len) {
        if (input[i] != '<') {
            i += 1;
            continue;
        }

        // Flush pending text run.
        if (i > text_start) {
            try out.append(arena, .{ .text = input[text_start..i] });
        }

        // Find the matching `>`. If absent the rest is treated as text
        // (graceful fallback for half-typed agent output).
        const close = std.mem.indexOfScalarPos(u8, input, i + 1, '>') orelse {
            try out.append(arena, .{ .text = input[i..] });
            return out.toOwnedSlice(arena);
        };

        const tag_body = input[i + 1 .. close];
        const consumed_to = close + 1;

        if (tag_body.len == 0) {
            // `<>` — pass through verbatim.
            try out.append(arena, .{ .text = input[i..consumed_to] });
            i = consumed_to;
            text_start = i;
            continue;
        }

        const is_closing = tag_body[0] == '/';
        const is_self_closing = tag_body[tag_body.len - 1] == '/';

        const name_start: usize = if (is_closing) 1 else 0;
        // Strip trailing `/` from self-closing for name slicing.
        const name_end_search: usize = if (is_self_closing and !is_closing) tag_body.len - 1 else tag_body.len;
        const name_end = blk: {
            var j: usize = name_start;
            while (j < name_end_search) : (j += 1) {
                const ch = tag_body[j];
                if (ch == ' ' or ch == '\t' or ch == '\n') break;
            }
            break :blk j;
        };
        const name = tag_body[name_start..name_end];

        if (recognize(name)) |kind| {
            switch (kind) {
                .emphasis => {
                    if (is_closing) {
                        try out.append(arena, .emphasis_close);
                    } else {
                        const level_str = attrValue(tag_body[name_end..name_end_search], "level");
                        const level = if (level_str) |s|
                            EmphasisLevel.fromStr(s) orelse .moderate
                        else
                            .moderate;
                        try out.append(arena, .{ .emphasis_open = .{ .level = level } });
                        if (is_self_closing) try out.append(arena, .emphasis_close);
                    }
                },
                .@"break" => {
                    var ms: u32 = BreakStrength.medium.ms();
                    if (attrValue(tag_body[name_end..name_end_search], "time")) |t| {
                        ms = parseTimeMs(t);
                    } else if (attrValue(tag_body[name_end..name_end_search], "strength")) |s| {
                        const bs = BreakStrength.fromStr(s) orelse .medium;
                        ms = bs.ms();
                    }
                    try out.append(arena, .{ .@"break" = .{ .ms = ms } });
                },
                .prosody => {
                    if (is_closing) {
                        try out.append(arena, .prosody_close);
                    } else {
                        var p: Prosody = .{};
                        const attrs = tag_body[name_end..name_end_search];
                        if (attrValue(attrs, "rate")) |r| p.rate = parseRate(r);
                        if (attrValue(attrs, "pitch")) |pi| p.pitch = parsePitchSemitones(pi);
                        if (attrValue(attrs, "volume")) |v| p.volume = parseVolume(v);
                        try out.append(arena, .{ .prosody_open = p });
                        if (is_self_closing) try out.append(arena, .prosody_close);
                    }
                },
                .sayas => {
                    if (is_closing) {
                        try out.append(arena, .sayas_close);
                    } else {
                        const ia = attrValue(tag_body[name_end..name_end_search], "interpret-as") orelse "";
                        try out.append(arena, .{ .sayas_open = .{ .interpret_as = ia, .open = true } });
                        if (is_self_closing) try out.append(arena, .sayas_close);
                    }
                },
                .phoneme => {
                    if (is_closing) {
                        try out.append(arena, .phoneme_close);
                    } else {
                        const attrs = tag_body[name_end..name_end_search];
                        const alphabet = attrValue(attrs, "alphabet") orelse "ipa";
                        const ph = attrValue(attrs, "ph") orelse "";
                        try out.append(arena, .{ .phoneme_open = .{ .alphabet = alphabet, .ph = ph } });
                        if (is_self_closing) try out.append(arena, .phoneme_close);
                    }
                },
                .sub => {
                    if (is_closing) {
                        try out.append(arena, .sub_close);
                    } else {
                        const alias = attrValue(tag_body[name_end..name_end_search], "alias") orelse "";
                        try out.append(arena, .{ .sub_open = .{ .alias = alias } });
                        if (is_self_closing) try out.append(arena, .sub_close);
                    }
                },
            }
        } else {
            // Unknown tag — pass through verbatim. Agents sometimes emit
            // `<speak>` envelopes or HTML; better than dropping content.
            try out.append(arena, .{ .text = input[i..consumed_to] });
        }

        i = consumed_to;
        text_start = i;
    }

    if (text_start < input.len) {
        try out.append(arena, .{ .text = input[text_start..] });
    }
    return out.toOwnedSlice(arena);
}

const TagKind = enum { emphasis, @"break", prosody, sayas, phoneme, sub };

fn recognize(name: []const u8) ?TagKind {
    if (std.mem.eql(u8, name, "emphasis")) return .emphasis;
    if (std.mem.eql(u8, name, "break")) return .@"break";
    if (std.mem.eql(u8, name, "prosody")) return .prosody;
    if (std.mem.eql(u8, name, "say-as")) return .sayas;
    if (std.mem.eql(u8, name, "phoneme")) return .phoneme;
    if (std.mem.eql(u8, name, "sub")) return .sub;
    return null;
}

/// Look up `name="value"` inside an attribute slice (the part of the tag
/// after the element name). Returns the unquoted value or null.
fn attrValue(attrs: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < attrs.len) {
        // Skip whitespace.
        while (i < attrs.len and (attrs[i] == ' ' or attrs[i] == '\t' or attrs[i] == '\n')) i += 1;
        if (i >= attrs.len) break;

        const key_start = i;
        while (i < attrs.len and attrs[i] != '=' and attrs[i] != ' ' and attrs[i] != '\t') i += 1;
        const key = attrs[key_start..i];
        if (i >= attrs.len or attrs[i] != '=') return null;
        i += 1; // skip '='
        if (i >= attrs.len) return null;
        const quote = attrs[i];
        if (quote != '"' and quote != '\'') {
            // Unquoted — span to next space.
            const v_start = i;
            while (i < attrs.len and attrs[i] != ' ' and attrs[i] != '\t' and attrs[i] != '/') i += 1;
            if (std.mem.eql(u8, key, name)) return attrs[v_start..i];
            continue;
        }
        i += 1;
        const v_start = i;
        while (i < attrs.len and attrs[i] != quote) i += 1;
        const v = attrs[v_start..i];
        if (i < attrs.len) i += 1;
        if (std.mem.eql(u8, key, name)) return v;
    }
    return null;
}

/// Parse `500ms` / `2s` / `1.5s` → milliseconds. Returns 0 on garbage.
pub fn parseTimeMs(s: []const u8) u32 {
    if (s.len == 0) return 0;
    var unit_len: usize = 0;
    var unit_is_s = false;
    if (std.mem.endsWith(u8, s, "ms")) {
        unit_len = 2;
    } else if (std.mem.endsWith(u8, s, "s")) {
        unit_len = 1;
        unit_is_s = true;
    }
    const num_str = if (unit_len > 0) s[0 .. s.len - unit_len] else s;
    const v = std.fmt.parseFloat(f64, num_str) catch return 0;
    const ms_f: f64 = if (unit_is_s) v * 1000.0 else v;
    if (ms_f < 0) return 0;
    if (ms_f > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intFromFloat(ms_f);
}

/// Parse prosody `rate` — `x-slow`/`slow`/`medium`/`fast`/`x-fast`, a
/// percent (`80%`), or a bare multiplier (`1.2`). Returns multiplier.
pub fn parseRate(s: []const u8) f32 {
    if (std.mem.eql(u8, s, "x-slow")) return 0.5;
    if (std.mem.eql(u8, s, "slow")) return 0.75;
    if (std.mem.eql(u8, s, "medium")) return 1.0;
    if (std.mem.eql(u8, s, "default")) return 1.0;
    if (std.mem.eql(u8, s, "fast")) return 1.25;
    if (std.mem.eql(u8, s, "x-fast")) return 1.5;
    if (std.mem.endsWith(u8, s, "%")) {
        const num = std.fmt.parseFloat(f32, s[0 .. s.len - 1]) catch return 1.0;
        if (num <= 0) return 1.0;
        return num / 100.0;
    }
    return std.fmt.parseFloat(f32, s) catch 1.0;
}

/// Parse prosody `pitch` — keyword (`x-low`/`low`/`medium`/`high`/`x-high`),
/// semitone delta (`+2st`), Hz (`200Hz` → ignored, returns 0), or %.
/// Returns semitone delta.
pub fn parsePitchSemitones(s: []const u8) f32 {
    if (std.mem.eql(u8, s, "x-low")) return -4;
    if (std.mem.eql(u8, s, "low")) return -2;
    if (std.mem.eql(u8, s, "medium")) return 0;
    if (std.mem.eql(u8, s, "default")) return 0;
    if (std.mem.eql(u8, s, "high")) return 2;
    if (std.mem.eql(u8, s, "x-high")) return 4;
    if (std.mem.endsWith(u8, s, "st")) {
        const num = std.fmt.parseFloat(f32, s[0 .. s.len - 2]) catch return 0;
        return num;
    }
    if (std.mem.endsWith(u8, s, "%")) {
        // 100% = no change. ±50% ≈ ±6 semitones for a rough mapping.
        const num = std.fmt.parseFloat(f32, s[0 .. s.len - 1]) catch return 0;
        return (num - 100.0) * 0.12;
    }
    if (std.mem.endsWith(u8, s, "Hz")) return 0; // absolute Hz unsupported — caller picks neutral
    return std.fmt.parseFloat(f32, s) catch 0;
}

/// Parse prosody `volume` — keyword or dB delta. Returns multiplier.
pub fn parseVolume(s: []const u8) f32 {
    if (std.mem.eql(u8, s, "silent")) return 0;
    if (std.mem.eql(u8, s, "x-soft")) return 0.25;
    if (std.mem.eql(u8, s, "soft")) return 0.5;
    if (std.mem.eql(u8, s, "medium")) return 1.0;
    if (std.mem.eql(u8, s, "default")) return 1.0;
    if (std.mem.eql(u8, s, "loud")) return 1.5;
    if (std.mem.eql(u8, s, "x-loud")) return 2.0;
    if (std.mem.endsWith(u8, s, "dB")) {
        const num = std.fmt.parseFloat(f32, s[0 .. s.len - 2]) catch return 1.0;
        return std.math.pow(f32, 10.0, num / 20.0);
    }
    if (std.mem.endsWith(u8, s, "%")) {
        const num = std.fmt.parseFloat(f32, s[0 .. s.len - 1]) catch return 1.0;
        if (num < 0) return 0;
        return num / 100.0;
    }
    return std.fmt.parseFloat(f32, s) catch 1.0;
}

// ──────────────────────────────────────────────────────────────────────
// Transpile to macOS `say` [[...]] directives
// ──────────────────────────────────────────────────────────────────────
//
// macOS `say` accepts inline directives:
//   [[slnc N]]         — pause N milliseconds
//   [[rate WPM]]       — set words-per-minute
//   [[pbas N]]         — set pitch (1..100, default 47)
//   [[volm 0..1]]      — set volume multiplier
//   [[rset]]           — reset to defaults
//
// We map SSML → directives token-by-token. The transpile output is what
// the daemon hands to /usr/bin/say (still subject to preproc.process for
// abbreviations / cardinals if `ssml: false`).

/// Compose `say` directive string from a token list. The emitted text
/// interleaves plain text with `[[...]]` directives. Allocated in `arena`.
pub fn transpileToSay(arena: std.mem.Allocator, tokens: []const Token) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, 0);

    // Stack of restore-rates for prosody close.
    // We track the previously-active prosody rate as a multiplier; on close
    // we issue [[rset]] to drop back to defaults (cheaper than maintaining
    // a true stack — nested prosody is rare in agent output).
    var prosody_depth: u32 = 0;
    // v1.10.12 — suppress body text inside `<sub>` (alias takes its place)
    // and inside `<phoneme>` (the body text is the displayed form, the
    // alphabet+ph attrs are what gets spoken on engines that honour them;
    // for `say` we can't honour the IPA but DO want the body text — only
    // the `<sub>` body is fully replaced). We track `sub_depth` only.
    var sub_depth: u32 = 0;

    for (tokens) |tok| {
        switch (tok) {
            .text => |t| {
                if (sub_depth == 0) try out.appendSlice(arena, t);
            },
            .emphasis_open => |e| {
                // Emphasis on say: gentle volume bump + slight rate boost.
                // Levels other than `none` push harder.
                const vol: f32 = switch (e.level) {
                    .none => 1.0,
                    .reduced => 0.7,
                    .moderate => 1.0,
                    .strong => 1.0,
                };
                try out.appendSlice(arena, " [[volm ");
                try out.print(arena, "{d:.2}", .{vol});
                try out.appendSlice(arena, "]]");
                if (e.level == .strong) {
                    // Brief micro-pause before the emphasized word lands.
                    try out.appendSlice(arena, " [[slnc 80]] ");
                }
            },
            .emphasis_close => {
                try out.appendSlice(arena, " [[volm 1.0]] ");
            },
            .@"break" => |b| {
                try out.appendSlice(arena, " [[slnc ");
                try out.print(arena, "{d}", .{b.ms});
                try out.appendSlice(arena, "]] ");
            },
            .prosody_open => |p| {
                prosody_depth += 1;
                if (p.rate) |r| {
                    const wpm: u32 = @intFromFloat(std.math.clamp(330.0 * r, 80.0, 600.0));
                    try out.appendSlice(arena, " [[rate ");
                    try out.print(arena, "{d}", .{wpm});
                    try out.appendSlice(arena, "]] ");
                }
                if (p.pitch) |pi| {
                    // say `pbas` 1..100 with 47 as default. ±2 semitones ≈ ±6.
                    const pbas: i32 = 47 + @as(i32, @intFromFloat(pi * 3.0));
                    const clamped = std.math.clamp(pbas, 1, 100);
                    try out.appendSlice(arena, " [[pbas ");
                    try out.print(arena, "{d}", .{clamped});
                    try out.appendSlice(arena, "]] ");
                }
                if (p.volume) |v| {
                    const clamped = std.math.clamp(v, 0.0, 2.0);
                    try out.appendSlice(arena, " [[volm ");
                    try out.print(arena, "{d:.2}", .{clamped});
                    try out.appendSlice(arena, "]] ");
                }
            },
            .prosody_close => {
                if (prosody_depth > 0) prosody_depth -= 1;
                // Cheap reset. Loses outer-prosody on nested ranges; v1.8
                // accepts that simplification — nesting is rare.
                try out.appendSlice(arena, " [[rset]] ");
            },
            .sayas_open => |sa| {
                // For `interpret-as="characters"` spell letters with spaces
                // so say reads them individually. Other values: pass through.
                if (std.mem.eql(u8, sa.interpret_as, "characters") or
                    std.mem.eql(u8, sa.interpret_as, "spell-out"))
                {
                    try out.appendSlice(arena, " [[char LTRL]] ");
                }
            },
            .sayas_close => {
                try out.appendSlice(arena, " [[char NORM]] ");
            },
            // v1.10.12 — `<phoneme>` on macOS `say`: macOS has no IPA
            // directive in the public [[…]] vocabulary. We strip the tag
            // silently and let the body text fall through. The body text
            // already follows in subsequent `.text` tokens.
            .phoneme_open, .phoneme_close => {},
            // v1.10.12 — `<sub alias="…">`: emit the alias verbatim and
            // suppress body text via the same depth-tracked walker pattern
            // we use for prosody. Implement here as: open emits the alias,
            // close does nothing — the walker filters body text by maintaining
            // a `sub_depth` counter outside this switch (added below).
            .sub_open => |s| {
                try out.appendSlice(arena, s.alias);
                sub_depth += 1;
            },
            .sub_close => {
                if (sub_depth > 0) sub_depth -= 1;
            },
        }
    }

    return out.toOwnedSlice(arena);
}

/// Strip SSML tags, leaving only plain text. Used by engines that don't
/// support SSML at all (Kokoro without per-chunk prosody, espeak-ng).
///
/// v1.10.12: `<sub alias="…">body</sub>` emits the alias (the spoken form),
/// not the body. `<phoneme ph="ipa">body</phoneme>` emits the body text
/// (the displayed form) — strip-to-plain is the engine-agnostic fallback,
/// and the body text is what listeners expect when IPA isn't honoured.
pub fn stripToPlain(arena: std.mem.Allocator, tokens: []const Token) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var sub_depth: u32 = 0;
    for (tokens) |tok| {
        switch (tok) {
            .text => |t| if (sub_depth == 0) try out.appendSlice(arena, t),
            .@"break" => |b| {
                // Surface breaks as ". " so the downstream pause stage in
                // preproc.zig at least inserts an [[slnc]].
                if (b.ms >= 250) try out.appendSlice(arena, ". ");
            },
            .sub_open => |s| {
                try out.appendSlice(arena, s.alias);
                sub_depth += 1;
            },
            .sub_close => {
                if (sub_depth > 0) sub_depth -= 1;
            },
            else => {},
        }
    }
    return out.toOwnedSlice(arena);
}

// ──────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parse empty returns empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(arena.allocator(), "");
    try testing.expectEqual(@as(usize, 0), toks.len);
}

test "parse plain text yields single text token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(arena.allocator(), "Olá mundo");
    try testing.expectEqual(@as(usize, 1), toks.len);
    try testing.expect(toks[0] == .text);
    try testing.expectEqualStrings("Olá mundo", toks[0].text);
}

test "parse single emphasis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(arena.allocator(), "<emphasis level=\"strong\">Olá</emphasis> mundo");
    try testing.expectEqual(@as(usize, 4), toks.len);
    try testing.expect(toks[0] == .emphasis_open);
    try testing.expectEqual(EmphasisLevel.strong, toks[0].emphasis_open.level);
    try testing.expectEqualStrings("Olá", toks[1].text);
    try testing.expect(toks[2] == .emphasis_close);
    try testing.expectEqualStrings(" mundo", toks[3].text);
}

test "parse self-closing break with time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(arena.allocator(), "antes<break time=\"500ms\"/>depois");
    try testing.expectEqual(@as(usize, 3), toks.len);
    try testing.expectEqualStrings("antes", toks[0].text);
    try testing.expect(toks[1] == .@"break");
    try testing.expectEqual(@as(u32, 500), toks[1].@"break".ms);
    try testing.expectEqualStrings("depois", toks[2].text);
}

test "parse break with strength" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(arena.allocator(), "<break strength=\"strong\"/>");
    try testing.expectEqual(@as(usize, 1), toks.len);
    try testing.expectEqual(@as(u32, 500), toks[0].@"break".ms);
}

test "parse prosody with rate pitch volume" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(
        arena.allocator(),
        "<prosody rate=\"slow\" pitch=\"+2st\" volume=\"loud\">teste</prosody>",
    );
    try testing.expectEqual(@as(usize, 3), toks.len);
    try testing.expect(toks[0] == .prosody_open);
    const p = toks[0].prosody_open;
    try testing.expect(p.rate != null);
    try testing.expectApproxEqAbs(@as(f32, 0.75), p.rate.?, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 2.0), p.pitch.?, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.5), p.volume.?, 0.01);
}

test "parse say-as" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(
        arena.allocator(),
        "Código: <say-as interpret-as=\"characters\">ABC</say-as>",
    );
    try testing.expectEqual(@as(usize, 4), toks.len);
    try testing.expect(toks[1] == .sayas_open);
    try testing.expectEqualStrings("characters", toks[1].sayas_open.interpret_as);
}

test "parse unknown tag passes through as text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(arena.allocator(), "<speak>oi</speak>");
    // <speak> opening: text; "oi": text; </speak>: text → 3 text tokens.
    try testing.expectEqual(@as(usize, 3), toks.len);
    try testing.expectEqualStrings("<speak>", toks[0].text);
    try testing.expectEqualStrings("oi", toks[1].text);
    try testing.expectEqualStrings("</speak>", toks[2].text);
}

test "parse malformed missing close gracefully fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(arena.allocator(), "before <emphasis level=\"strong\" missing-close");
    try testing.expectEqual(@as(usize, 2), toks.len);
    try testing.expectEqualStrings("before ", toks[0].text);
    try testing.expectEqualStrings("<emphasis level=\"strong\" missing-close", toks[1].text);
}

test "parse nested tags emit nested tokens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(
        arena.allocator(),
        "<prosody rate=\"slow\">Olá <emphasis>mundo</emphasis>!</prosody>",
    );
    // prosody_open, "Olá ", emphasis_open, "mundo", emphasis_close, "!", prosody_close
    try testing.expectEqual(@as(usize, 7), toks.len);
    try testing.expect(toks[0] == .prosody_open);
    try testing.expect(toks[2] == .emphasis_open);
    try testing.expect(toks[4] == .emphasis_close);
    try testing.expect(toks[6] == .prosody_close);
}

test "parseTimeMs handles ms and s and garbage" {
    try testing.expectEqual(@as(u32, 500), parseTimeMs("500ms"));
    try testing.expectEqual(@as(u32, 1000), parseTimeMs("1s"));
    try testing.expectEqual(@as(u32, 1500), parseTimeMs("1.5s"));
    try testing.expectEqual(@as(u32, 0), parseTimeMs("garbage"));
    try testing.expectEqual(@as(u32, 0), parseTimeMs(""));
}

test "parseRate keywords and percent" {
    try testing.expectApproxEqAbs(@as(f32, 0.75), parseRate("slow"), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.5), parseRate("x-fast"), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.8), parseRate("80%"), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.2), parseRate("1.2"), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.0), parseRate("nonsense"), 0.01);
}

test "transpileToSay emits slnc for break" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(arena.allocator(), "antes<break time=\"400ms\"/>depois");
    const out = try transpileToSay(arena.allocator(), toks);
    try testing.expect(std.mem.indexOf(u8, out, "[[slnc 400]]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "antes") != null);
    try testing.expect(std.mem.indexOf(u8, out, "depois") != null);
}

test "transpileToSay emits rate from prosody slow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(arena.allocator(), "<prosody rate=\"slow\">olá</prosody>");
    const out = try transpileToSay(arena.allocator(), toks);
    // 330 * 0.75 = 247
    try testing.expect(std.mem.indexOf(u8, out, "[[rate 247]]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[[rset]]") != null);
}

test "transpileToSay emphasis wraps with volm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(arena.allocator(), "<emphasis level=\"strong\">olá</emphasis>");
    const out = try transpileToSay(arena.allocator(), toks);
    try testing.expect(std.mem.indexOf(u8, out, "[[volm 1.00]]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[[slnc 80]]") != null);
}

test "stripToPlain drops tags keeps text + sentence break" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(arena.allocator(), "<prosody rate=\"slow\">olá <break time=\"500ms\"/>mundo</prosody>");
    const out = try stripToPlain(arena.allocator(), toks);
    try testing.expectEqualStrings("olá . mundo", out);
}

// ─── v1.10.12 — phoneme + sub parse + transpile ────────────────────────

test "v1.10.12 parse phoneme with alphabet and ph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(
        arena.allocator(),
        "<phoneme alphabet=\"ipa\" ph=\"ˌæn.θɹəˈpɪk\">Anthropic</phoneme>",
    );
    try testing.expectEqual(@as(usize, 3), toks.len);
    try testing.expect(toks[0] == .phoneme_open);
    try testing.expectEqualStrings("ipa", toks[0].phoneme_open.alphabet);
    try testing.expectEqualStrings("ˌæn.θɹəˈpɪk", toks[0].phoneme_open.ph);
    try testing.expectEqualStrings("Anthropic", toks[1].text);
    try testing.expect(toks[2] == .phoneme_close);
}

test "v1.10.12 parse phoneme default alphabet=ipa when omitted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(arena.allocator(), "<phoneme ph=\"miˈstɾal\">Mistral</phoneme>");
    try testing.expectEqualStrings("ipa", toks[0].phoneme_open.alphabet);
    try testing.expectEqualStrings("miˈstɾal", toks[0].phoneme_open.ph);
}

test "v1.10.12 parse sub with alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(
        arena.allocator(),
        "use <sub alias=\"get conditioning latents\">getConditioningLatents</sub> aqui",
    );
    try testing.expectEqual(@as(usize, 5), toks.len);
    try testing.expectEqualStrings("use ", toks[0].text);
    try testing.expect(toks[1] == .sub_open);
    try testing.expectEqualStrings("get conditioning latents", toks[1].sub_open.alias);
    try testing.expectEqualStrings("getConditioningLatents", toks[2].text);
    try testing.expect(toks[3] == .sub_close);
    try testing.expectEqualStrings(" aqui", toks[4].text);
}

test "v1.10.12 transpileToSay sub replaces body with alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(
        arena.allocator(),
        "antes <sub alias=\"controle\">CTL</sub> depois",
    );
    const out = try transpileToSay(arena.allocator(), toks);
    // Body "CTL" must NOT appear; alias "controle" must.
    try testing.expect(std.mem.indexOf(u8, out, "CTL") == null);
    try testing.expect(std.mem.indexOf(u8, out, "controle") != null);
    try testing.expect(std.mem.indexOf(u8, out, "antes ") != null);
    try testing.expect(std.mem.indexOf(u8, out, " depois") != null);
}

test "v1.10.12 transpileToSay phoneme falls back to body text (no IPA on say)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(
        arena.allocator(),
        "<phoneme alphabet=\"ipa\" ph=\"ˌæn.θɹəˈpɪk\">Anthropic</phoneme>",
    );
    const out = try transpileToSay(arena.allocator(), toks);
    // Body text rides through; no [[ipa …]] directive (macOS doesn't accept).
    try testing.expect(std.mem.indexOf(u8, out, "Anthropic") != null);
}

test "v1.10.12 stripToPlain sub emits alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(
        arena.allocator(),
        "fala <sub alias=\"emcêpê\">MCP</sub> rápido",
    );
    const out = try stripToPlain(arena.allocator(), toks);
    try testing.expectEqualStrings("fala emcêpê rápido", out);
}

test "v1.10.12 stripToPlain phoneme keeps body text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try parse(
        arena.allocator(),
        "<phoneme ph=\"miˈstɾal\">Mistral</phoneme> lançou",
    );
    const out = try stripToPlain(arena.allocator(), toks);
    try testing.expectEqualStrings("Mistral lançou", out);
}
