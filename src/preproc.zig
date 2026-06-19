// SPDX-License-Identifier: MIT OR Apache-2.0
// Pt-BR text preprocessor for `say`. v0.5.
//
// Applies, in order:
//   1. Whole-word abbreviation expansion (Sr. → Senhor, etc.)
//   2. Cardinal number-to-words (0..9999, Pt-BR)
//   3. Pause directives ([[slnc N]]) after punctuation and newlines
//
// Single pass per stage. All allocations are arena-bound, so the caller
// owns the lifetime by passing a per-utterance allocator.
//
// Rationale: TTFA budget is < 1ms per message on M-class silicon. Each
// stage is O(N) in the input length with no regex / no global state.

const std = @import("std");
const detect = @import("detect.zig");
const ssml = @import("ssml.zig");

// ─── v1.1: sentence-level language chunks ────────────────────────────────
//
// `splitByLang` slices the input on sentence boundaries (`.` `!` `?` `\n`),
// detects the dominant language per sentence, then coalesces adjacent
// same-lang sentences into a single chunk. The daemon synthesizes each
// chunk on the matching Piper voice and concatenates the PCM.
//
// `unknown` / `mixed` outputs collapse to a default lang argument the
// caller passes in (typically `.pt` for Brazilian users). This keeps
// short fragments ("ok.", numbers-only) from spawning empty chunks.
pub const Chunk = struct {
    text: []const u8,
    lang: detect.Lang,
};

/// Split `text` on sentence boundaries, detect per-sentence lang, coalesce
/// adjacent same-lang spans into one chunk. Each chunk's `.text` is a slice
/// freshly allocated from `arena` (trim of leading/trailing whitespace
/// preserved internally — punctuation survives because the daemon's
/// preproc.process() still needs it for `[[slnc]]` insertion).
///
/// `default_lang` is what `unknown`/`mixed` collapse to. Pass `.pt` from
/// the daemon for Brazilian-default behaviour; the client's `--lang`
/// override flows through ipc.Message.lang and short-circuits this
/// function entirely (one chunk, that lang).
pub fn splitByLang(
    arena: std.mem.Allocator,
    text: []const u8,
    default_lang: detect.Lang,
) ![]Chunk {
    if (text.len == 0) return arena.alloc(Chunk, 0);

    // Stage 1: cut on sentence boundaries. We keep the trailing punctuation
    // on the *previous* sentence so the preproc that runs after us still
    // sees the `.`/`!`/`?` and inserts pauses correctly.
    var sentences: std.ArrayList([]const u8) = .empty;
    defer sentences.deinit(arena);

    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '.' or c == '!' or c == '?' or c == '\n') {
            // Extend the sentence to include the punctuation char.
            const end = i + 1;
            if (end > start) {
                const trimmed = std.mem.trim(u8, text[start..end], " \t\r");
                if (trimmed.len > 0) {
                    try sentences.append(arena, trimmed);
                }
            }
            start = end;
        }
    }
    // Trailing fragment without sentence-ending punctuation.
    if (start < text.len) {
        const tail = std.mem.trim(u8, text[start..], " \t\r\n");
        if (tail.len > 0) try sentences.append(arena, tail);
    }

    if (sentences.items.len == 0) return arena.alloc(Chunk, 0);

    // Stage 2: detect lang per sentence + coalesce runs.
    var chunks: std.ArrayList(Chunk) = .empty;
    defer chunks.deinit(arena);

    var cur_lang: detect.Lang = .unknown;
    var cur_buf: std.ArrayList(u8) = .empty;
    defer cur_buf.deinit(arena);

    for (sentences.items) |sent| {
        var lang = try detect.detect(arena, sent);
        // Collapse unknown/mixed to the default. The daemon doesn't have
        // a multilingual voice — every PCM has to come from a single
        // engine, so we pick.
        if (lang == .unknown or lang == .mixed) lang = default_lang;

        if (cur_buf.items.len == 0) {
            cur_lang = lang;
            try cur_buf.appendSlice(arena, sent);
            continue;
        }
        if (lang == cur_lang) {
            try cur_buf.append(arena, ' ');
            try cur_buf.appendSlice(arena, sent);
        } else {
            const owned = try cur_buf.toOwnedSlice(arena);
            try chunks.append(arena, .{ .text = owned, .lang = cur_lang });
            cur_buf = .empty;
            cur_lang = lang;
            try cur_buf.appendSlice(arena, sent);
        }
    }
    if (cur_buf.items.len > 0) {
        const owned = try cur_buf.toOwnedSlice(arena);
        try chunks.append(arena, .{ .text = owned, .lang = cur_lang });
    }

    return chunks.toOwnedSlice(arena);
}

pub const Pause = struct {
    pub const COMMA_MS: u32 = 150;
    pub const SENTENCE_MS: u32 = 400;
    pub const NEWLINE_MS: u32 = 600;
};

/// v1.10.8 — per-call pause overrides. Each field is 0 to mean "use the
/// built-in `Pause.*_MS` default". `process` / `processTech` keep working
/// with their original defaults; `processWithPauses` / `processTechWithPauses`
/// honour any non-zero override so a single ENQUEUE can stretch sentence
/// breaks for a tech-report cadence without recompiling.
pub const Pauses = struct {
    comma_ms: u32 = 0,
    sentence_ms: u32 = 0,
    newline_ms: u32 = 0,

    /// Resolve into a fully-populated triplet, applying defaults where the
    /// override is zero. Kept private to the file so `insertPauses` doesn't
    /// have to repeat the math.
    fn resolved(self: Pauses) ResolvedPauses {
        return .{
            .comma = if (self.comma_ms == 0) Pause.COMMA_MS else self.comma_ms,
            .sentence = if (self.sentence_ms == 0) Pause.SENTENCE_MS else self.sentence_ms,
            .newline = if (self.newline_ms == 0) Pause.NEWLINE_MS else self.newline_ms,
        };
    }
};

const ResolvedPauses = struct { comma: u32, sentence: u32, newline: u32 };

/// v1.10.8 — knobs for the tech-report preproc. `extra_pause_after_*` is
/// added on top of the resolved Pauses values (or defaults) so a tech
/// run gets longer breath naturally. Currently consumed only by
/// `processTech*` so the v0.5 path keeps its compact cadence.
pub const TechOptions = struct {
    extra_pause_after_sentence_ms: u32 = 80,
    extra_pause_after_acronym_ms: u32 = 40,
    extra_pause_after_number_ms: u32 = 60,
    keep_acronyms_short_limit: usize = 3,
};

/// v1.10.12 — toggles for the cadence pass. Each rule fires independently
/// so an agent can enable list-end drop without picking up the breathing
/// splice (which requires a pre-staged breath WAV). All gated, all default
/// to the safer values:
///
/// * `enable_list_end_drop` — wraps the last 3 words of sentences after
///   3+-item enumerations in `<prosody pitch="-10%" rate="slow">…</prosody>`.
///   On by default because Piper's espeak-ng frontend understands prosody
///   tags cleanly and the audible effect is small.
/// * `enable_bullet_lift` — wraps the leading label of any bullet line
///   (`- Label: detail`) in `<prosody pitch="+5%">…</prosody>`. On by
///   default; same rationale.
/// * `enable_breathing` — emits a literal `[[breath]]` marker every 2-3
///   sentences. The marker is no-op unless `PTAH_BREATH_WAV` is set
///   AND the daemon's breath splice path activates. Off by default to
///   avoid a silent failure when the user hasn't generated the WAV.
pub const CadenceOptions = struct {
    enable_list_end_drop: bool = true,
    enable_bullet_lift: bool = true,
    enable_breathing: bool = false,
};

// v1.2 streaming Chunk type unified with v1.1's lang-aware shape — see
// `pub const Chunk` near the top of this file. chunkSentences emits
// `lang = .unknown` and the daemon's runPiper assigns the detected
// language per chunk before dispatching synth.

const Abbrev = struct {
    src: []const u8,
    dst: []const u8,
};

// Order matters only for ties; we match by exact `src` (case-sensitive
// for "Sr."/"Sra."/"Dr."/"Dra."/"Av." which are sentence-cased in the
// wild). "cf." / "etc." / "vs." / "nº" / "R$" are lower-cased.
const ABBREVS = [_]Abbrev{
    .{ .src = "Sra.", .dst = "Senhora" },
    .{ .src = "Dra.", .dst = "Doutora" },
    .{ .src = "etc.", .dst = "etcétera" },
    .{ .src = "Sr.", .dst = "Senhor" },
    .{ .src = "Dr.", .dst = "Doutor" },
    .{ .src = "cf.", .dst = "conforme" },
    .{ .src = "vs.", .dst = "versus" },
    .{ .src = "Av.", .dst = "Avenida" },
    .{ .src = "nº", .dst = "número" },
    .{ .src = "R$", .dst = "reais" },
};

/// Main entry. Returns a freshly allocated buffer (in `arena`) with the
/// transformed text. Caller does not need to free — arena owns it.
pub fn process(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    return processWithPauses(arena, raw, .{});
}

/// v1.10.8 — `process` with explicit pause overrides. Pass `.{}` to mirror
/// the legacy defaults. Non-zero fields stretch / shrink the corresponding
/// `[[slnc N]]` directive without recompiling.
pub fn processWithPauses(
    arena: std.mem.Allocator,
    raw: []const u8,
    pauses: Pauses,
) ![]u8 {
    if (raw.len == 0) return arena.alloc(u8, 0);

    const after_abbrev = try expandAbbreviations(arena, raw);
    const after_numbers = try expandNumbers(arena, after_abbrev);
    const after_pauses = try insertPausesTuned(arena, after_numbers, pauses.resolved());
    return after_pauses;
}

/// v1.10.9 — full tech preproc, exposed for the daemon so the streaming
/// synth path can run the same order as `processTechWithPauses`. Order:
///   normalizeIdentifiers → glossary-1 → camelCase-split → glossary-2 →
///   abbreviations → cardinals → pauses
///
/// `normalizeIdentifiers` runs FIRST so URL / version / commit-hash /
/// path / hex spans get rewritten before the glossary can catch
/// substrings inside them (e.g. `HTTPS` inside `https://…` is not
/// glossary-matched once the URL detector has already stripped the
/// protocol). The trade-off: the glossary's second pass still fires on
/// the rewritten output, so a URL tail like `ptah` will see `tts`
/// spelled letter-by-letter — accepted scope because the alternative
/// (Piper saying "ts" as a Pt-BR diphthong) is worse.
pub fn techPipeline(
    arena: std.mem.Allocator,
    raw: []const u8,
    tech: TechOptions,
) ![]u8 {
    if (raw.len == 0) return arena.alloc(u8, 0);
    const after_norm = try normalizeIdentifiers(arena, raw);
    const after_glossary1 = try expandTechGlossary(arena, after_norm, tech);
    const after_camel = try splitCamelCase(arena, after_glossary1);
    const after_glossary2 = try expandTechGlossary(arena, after_camel, tech);
    const after_abbrev = try expandAbbreviations(arena, after_glossary2);
    const after_numbers = try expandNumbers(arena, after_abbrev);
    return after_numbers;
}

/// v1.10.8 — tech-report mode. Runs the v0.5 pipeline + a curated tech
/// glossary substitution (acronyms spelled, units expanded) before the
/// pause stage. Designed for engineering-report cadence — the resulting
/// PCM has crisper acronyms and a slower-but-rhythmic sentence break.
///
/// `tech` controls the glossary behaviour. `Pauses` rides through to the
/// pause stage so `--profile tech` can stretch the sentence pause in one
/// shot.
pub fn processTech(
    arena: std.mem.Allocator,
    raw: []const u8,
    tech: TechOptions,
) ![]u8 {
    return processTechWithPauses(arena, raw, tech, .{});
}

// ──────────────────────────────────────────────────────────────────────
// v1.10.12 — cadence tricks
// ──────────────────────────────────────────────────────────────────────
//
// Three rules run in one pass over the input text (already glossary-
// expanded by the tech pipeline). Output is SSML — the daemon's SSML
// walker then transpiles the prosody tags to length_scale changes on
// Piper or `[[…]]` directives on `say`.
//
// 1. **List-end intonation drop.** Sentences containing an enumeration
//    of ≥3 comma-separated items get their last 3 whitespace tokens
//    wrapped in `<prosody pitch="-10%" rate="slow">…</prosody>`. Detect
//    enumerations via `count_commas(sentence) >= 2 AND " e " in sentence`
//    OR a list-like shape. Sentences without enumerations are untouched.
//
// 2. **Bullet-point lift.** Any line that starts with `-`, `•`, or `*`
//    followed by whitespace gets its leading label (up to `:` or `—` or
//    end-of-line) wrapped in `<prosody pitch="+5%">…</prosody>`. Lines
//    without those markers are untouched.
//
// 3. **Breathing simulation.** A state machine emits `[[breath]]` (a
//    literal marker the daemon's audio path translates to an 80ms
//    pink-noise splice IF `PTAH_BREATH_WAV` is set) every 2-3
//    sentences. Also emits a `<break time="80ms"/>` SSML break so the
//    silent fallback still slows the cadence audibly.
//
// All three rules are independent and the function is idempotent on
// already-tagged input (it only inserts `<prosody>` if the substring it
// would wrap doesn't already start with one). The pass runs O(N) in the
// input length with a single ArrayList(u8) allocation.

/// Apply the v1.10.12 cadence tricks to `raw`. Returns a freshly-allocated
/// buffer (in `arena`). Each rule is gated by the matching `opts` field.
pub fn applyCadenceTricks(
    arena: std.mem.Allocator,
    raw: []const u8,
    opts: CadenceOptions,
) ![]u8 {
    if (raw.len == 0) return arena.alloc(u8, 0);

    // Stage 1 — bullet-point lift (line-oriented). Process the input
    // line-by-line; non-bullet lines pass through, bullet lines get the
    // leading label wrapped.
    var after_bullets: []u8 = undefined;
    if (opts.enable_bullet_lift) {
        after_bullets = try applyBulletLift(arena, raw);
    } else {
        after_bullets = try arena.dupe(u8, raw);
    }

    // Stage 2 — list-end drop (sentence-oriented). Split on `.`, `!`,
    // `?`, and `\n`; for each sentence that looks enumerative, wrap the
    // last 3 word tokens.
    var after_list_drop: []u8 = undefined;
    if (opts.enable_list_end_drop) {
        after_list_drop = try applyListEndDrop(arena, after_bullets);
    } else {
        after_list_drop = after_bullets;
    }

    // Stage 3 — breathing splice. State machine inserts a literal
    // `[[breath]]` marker + `<break time="80ms"/>` every 2-3 sentences.
    // The marker is a no-op for `say` (it just looks like a word) and the
    // daemon's audio path translates it to a pink-noise WAV splice when
    // the env var is set. The `<break>` is the audible-anyway fallback.
    if (opts.enable_breathing) {
        return try applyBreathingSplice(arena, after_list_drop);
    }
    return after_list_drop;
}

fn applyBulletLift(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, raw.len + raw.len / 4);

    var i: usize = 0;
    while (i < raw.len) {
        // Find the end of the current line.
        const line_start = i;
        while (i < raw.len and raw[i] != '\n') i += 1;
        const line_end = i;
        const line = raw[line_start..line_end];

        // Detect bullet marker: optional leading whitespace, then `-`,
        // `*`, or `•`, then whitespace.
        var lead: usize = 0;
        while (lead < line.len and (line[lead] == ' ' or line[lead] == '\t')) lead += 1;
        const marker_is_bullet = blk: {
            if (lead >= line.len) break :blk false;
            const c = line[lead];
            if (c == '-' or c == '*') {
                // require trailing whitespace so "----" doesn't match
                if (lead + 1 < line.len and (line[lead + 1] == ' ' or line[lead + 1] == '\t')) break :blk true;
                break :blk false;
            }
            // `•` is a 3-byte UTF-8 sequence: E2 80 A2
            if (lead + 2 < line.len and line[lead] == 0xE2 and line[lead + 1] == 0x80 and line[lead + 2] == 0xA2) {
                if (lead + 3 < line.len and (line[lead + 3] == ' ' or line[lead + 3] == '\t')) break :blk true;
            }
            break :blk false;
        };

        if (!marker_is_bullet) {
            try out.appendSlice(arena, line);
            if (i < raw.len) try out.append(arena, '\n');
            if (i < raw.len) i += 1;
            continue;
        }

        // Emit leading whitespace + bullet marker + whitespace verbatim.
        const marker_len: usize = if (line[lead] == 0xE2) 3 else 1;
        const after_marker = lead + marker_len;
        var ws_end = after_marker;
        while (ws_end < line.len and (line[ws_end] == ' ' or line[ws_end] == '\t')) ws_end += 1;
        try out.appendSlice(arena, line[0..ws_end]);

        // Find the label end: first `:`, `—` (E2 80 94), or end of line.
        var label_end = ws_end;
        while (label_end < line.len) {
            const c = line[label_end];
            if (c == ':') break;
            if (label_end + 2 < line.len and c == 0xE2 and line[label_end + 1] == 0x80 and line[label_end + 2] == 0x94) break;
            label_end += 1;
        }
        const label = line[ws_end..label_end];

        // Skip empty labels (the line was just a bullet marker).
        if (label.len == 0) {
            try out.appendSlice(arena, line[ws_end..]);
            if (i < raw.len) try out.append(arena, '\n');
            if (i < raw.len) i += 1;
            continue;
        }

        // Wrap the label.
        try out.appendSlice(arena, "<prosody pitch=\"+5%\">");
        try out.appendSlice(arena, label);
        try out.appendSlice(arena, "</prosody>");
        try out.appendSlice(arena, line[label_end..]);
        if (i < raw.len) try out.append(arena, '\n');
        if (i < raw.len) i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// Detect sentences with ≥3 comma-separated items + wrap last 3 word
/// tokens with `<prosody pitch="-10%" rate="slow">…</prosody>`. We split
/// on `.`, `!`, `?`, `\n` boundaries (mirroring `chunkSentences`'s rules
/// but simpler — no abbreviation guard needed because the comma count
/// triggers, not the dot itself).
fn applyListEndDrop(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, raw.len + raw.len / 4);

    var start: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '.' or c == '!' or c == '?' or c == '\n') {
            // Sentence body excluding the terminator.
            const body = raw[start..i];
            try emitSentenceWithListDrop(arena, &out, body);
            try out.append(arena, c);
            start = i + 1;
        }
    }
    if (start < raw.len) {
        try emitSentenceWithListDrop(arena, &out, raw[start..]);
    }
    return out.toOwnedSlice(arena);
}

fn emitSentenceWithListDrop(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: []const u8,
) !void {
    // Heuristic: if the sentence has ≥2 commas AND the last 3 words sit
    // after a comma, wrap them. Skip when the body is too short (< 3 word
    // tokens) or already contains a closing `</prosody>` (idempotent).
    var comma_count: usize = 0;
    for (body) |b| {
        if (b == ',') comma_count += 1;
    }

    if (comma_count < 2) {
        try out.appendSlice(arena, body);
        return;
    }
    if (std.mem.indexOf(u8, body, "</prosody>") != null) {
        try out.appendSlice(arena, body);
        return;
    }

    // Find the start of the last 3 whitespace-delimited tokens. Walk
    // backwards counting transitions from non-space to space.
    var word_start: usize = body.len;
    var words_seen: usize = 0;
    var k: usize = body.len;
    while (k > 0) {
        k -= 1;
        const ch = body[k];
        const is_ws = ch == ' ' or ch == '\t';
        if (!is_ws) {
            // We're inside a word — walk until we hit ws or start.
            var w_start = k;
            while (w_start > 0 and body[w_start - 1] != ' ' and body[w_start - 1] != '\t') w_start -= 1;
            word_start = w_start;
            words_seen += 1;
            if (words_seen == 3) break;
            k = w_start; // will be decremented at top of loop
            if (k == 0) break;
        }
    }

    if (words_seen < 3) {
        try out.appendSlice(arena, body);
        return;
    }

    // Skip the wrap when the 3-word slice contains `<` or `>` (already
    // marked up — don't double-wrap).
    const last3 = body[word_start..];
    for (last3) |ch| if (ch == '<' or ch == '>') {
        try out.appendSlice(arena, body);
        return;
    };

    try out.appendSlice(arena, body[0..word_start]);
    try out.appendSlice(arena, "<prosody pitch=\"-10%\" rate=\"slow\">");
    try out.appendSlice(arena, last3);
    try out.appendSlice(arena, "</prosody>");
}

/// Insert a `[[breath]]` marker + `<break time="80ms"/>` every 2-3
/// sentences. The state machine uses a tiny PRNG-free counter (modulo 2)
/// so testing is deterministic. Skip the splice when the sentence is
/// trivially short (≤ 6 chars) — those are interjections, not breathable
/// units.
fn applyBreathingSplice(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, raw.len + raw.len / 8);

    var sentence_count: usize = 0;
    var since_breath: usize = 0;

    var start: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '.' or c == '!' or c == '?' or c == '\n') {
            // Compute sentence body length BEFORE flipping `start` —
            // otherwise the subtraction underflows on usize.
            const body_len: usize = i - start + 1;
            // Emit sentence body + terminator first.
            try out.appendSlice(arena, raw[start .. i + 1]);
            start = i + 1;

            sentence_count += 1;
            since_breath += 1;
            if (body_len < 6) continue;
            // Insert breath every 2 sentences (alternates 2,3,2,3 with
            // the modulo on sentence_count).
            const interval: usize = if ((sentence_count % 2) == 0) 2 else 3;
            if (since_breath < interval) continue;

            try out.appendSlice(arena, " <break time=\"80ms\"/>[[breath]] ");
            since_breath = 0;
        }
    }
    if (start < raw.len) try out.appendSlice(arena, raw[start..]);
    return out.toOwnedSlice(arena);
}

/// v1.10.8 — tech preproc with explicit pause overrides. v1.10.9 — pipeline
/// upgraded to two-pass glossary with CamelCase splitter and identifier
/// normalizer between the passes. The first glossary pass catches multi-word
/// brand names verbatim (e.g. "SurrealDB" → "surreal D B") so the splitter
/// doesn't fragment them; the splitter then opens up runs like
/// "MultiPiperEngine" → "Multi Piper Engine"; the second glossary pass
/// re-applies (so "TTS" inside "agent TTS Menubar" still spells out); the
/// identifier normalizer rewrites versions / commit hashes / URLs / paths
/// / hex literals; then v0.5 abbreviation + cardinal + pause stages run.
pub fn processTechWithPauses(
    arena: std.mem.Allocator,
    raw: []const u8,
    tech: TechOptions,
    pauses: Pauses,
) ![]u8 {
    if (raw.len == 0) return arena.alloc(u8, 0);

    const after_pipeline = try techPipeline(arena, raw, tech);
    const after_pauses = try insertPausesTuned(arena, after_pipeline, pauses.resolved());
    return after_pauses;
}

/// v1.8 — SSML-aware processing for the macOS `say` engine. Parses the
/// SSML subset, transpiles to `[[…]] directives`, and skips the
/// abbreviation/cardinal expansion (markup contains the agent's intent
/// verbatim — applying Pt-BR cardinals to "<say-as interpret-as=\"digits\">42</say-as>"
/// would defeat the markup). Caller's `[[slnc]]` pauses are emitted by
/// the SSML transpiler, not by `insertPauses`.
pub fn processSayWithSsml(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0) return arena.alloc(u8, 0);
    const tokens = try ssml.parse(arena, raw);
    return try ssml.transpileToSay(arena, tokens);
}

/// v1.8 — strip SSML tags and apply the v0.5 preproc to the plain text.
/// Used by engines that can't (or don't yet) honour SSML at the
/// per-utterance level (piper without prosody re-synth, espeak-ng).
pub fn processSsmlStripped(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0) return arena.alloc(u8, 0);
    const tokens = try ssml.parse(arena, raw);
    const plain = try ssml.stripToPlain(arena, tokens);
    return try process(arena, plain);
}

/// v1.10.8 — SSML-stripped tech preproc. Same shape as
/// `processSsmlStripped`, but runs the glossary substitution + tech
/// pauses so an agent can route SSML markup AND tech-report rendering
/// through the same call site without choosing one or the other.
pub fn processSsmlStrippedTech(
    arena: std.mem.Allocator,
    raw: []const u8,
    tech: TechOptions,
    pauses: Pauses,
) ![]u8 {
    if (raw.len == 0) return arena.alloc(u8, 0);
    const tokens = try ssml.parse(arena, raw);
    const plain = try ssml.stripToPlain(arena, tokens);
    return try processTechWithPauses(arena, plain, tech, pauses);
}

// ──────────────────────────────────────────────────────────────────────
// Stage 1 — abbreviations
// ──────────────────────────────────────────────────────────────────────

/// Returns true if `c` can be part of a "word" boundary, i.e. an
/// alphanumeric ASCII char or a UTF-8 continuation byte. We treat any
/// byte ≥ 0x80 as part of a word so that accented letters in Pt-BR
/// ("ção", "número") don't accidentally break matches.
fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

fn matchesAt(input: []const u8, idx: usize, needle: []const u8) bool {
    if (idx + needle.len > input.len) return false;
    return std.mem.eql(u8, input[idx .. idx + needle.len], needle);
}

fn expandAbbreviations(arena: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, input.len);

    var i: usize = 0;
    while (i < input.len) {
        // Only attempt match at word starts: either at index 0, or after
        // a non-word byte. This stops "Sr." from matching mid-word.
        const at_word_start = (i == 0) or !isWordByte(input[i - 1]);

        var matched: ?Abbrev = null;
        if (at_word_start) {
            for (ABBREVS) |ab| {
                if (matchesAt(input, i, ab.src)) {
                    matched = ab;
                    break;
                }
            }
        }

        if (matched) |ab| {
            try out.appendSlice(arena, ab.dst);
            i += ab.src.len;
        } else {
            try out.append(arena, input[i]);
            i += 1;
        }
    }

    return out.toOwnedSlice(arena);
}

// ──────────────────────────────────────────────────────────────────────
// Stage 2 — cardinal numbers (Pt-BR, 0..9999)
// ──────────────────────────────────────────────────────────────────────

const UNITS = [_][]const u8{
    "zero",      "um",        "dois",
    "três",
    "quatro",    "cinco",     "seis",
    "sete",      "oito",      "nove",
    "dez",       "onze",      "doze",
    "treze",     "catorze",   "quinze",
    "dezesseis", "dezessete", "dezoito",
    "dezenove",
};

const TENS = [_][]const u8{
    "",          "",         "vinte",   "trinta",  "quarenta",
    "cinquenta", "sessenta", "setenta", "oitenta", "noventa",
};

// "cento" is used in compounds (cento e dez); "cem" is the bare 100.
const HUNDREDS = [_][]const u8{
    "",             "cento",      "duzentos",   "trezentos",
    "quatrocentos", "quinhentos", "seiscentos", "setecentos",
    "oitocentos",   "novecentos",
};

fn appendUnder100(out: *std.ArrayList(u8), arena: std.mem.Allocator, n: u16) !void {
    std.debug.assert(n < 100);
    if (n < 20) {
        try out.appendSlice(arena, UNITS[n]);
        return;
    }
    const t = n / 10;
    const u = n % 10;
    try out.appendSlice(arena, TENS[t]);
    if (u != 0) {
        try out.appendSlice(arena, " e ");
        try out.appendSlice(arena, UNITS[u]);
    }
}

fn appendUnder1000(out: *std.ArrayList(u8), arena: std.mem.Allocator, n: u16) !void {
    std.debug.assert(n < 1000);
    if (n < 100) {
        try appendUnder100(out, arena, n);
        return;
    }
    const h = n / 100;
    const rem: u16 = n % 100;
    if (rem == 0 and h == 1) {
        try out.appendSlice(arena, "cem");
        return;
    }
    try out.appendSlice(arena, HUNDREDS[h]);
    if (rem != 0) {
        try out.appendSlice(arena, " e ");
        try appendUnder100(out, arena, rem);
    }
}

/// Render `n` (0..9999) as Pt-BR cardinal words into `out`.
pub fn renderCardinal(out: *std.ArrayList(u8), arena: std.mem.Allocator, n: u16) !void {
    if (n > 9999) return error.OutOfRange;
    if (n < 1000) {
        try appendUnder1000(out, arena, n);
        return;
    }
    const thousands = n / 1000;
    const rem = n % 1000;
    if (thousands == 1) {
        try out.appendSlice(arena, "mil");
    } else {
        try appendUnder1000(out, arena, thousands);
        try out.appendSlice(arena, " mil");
    }
    if (rem == 0) return;
    // Pt-BR connector is " e " when rem < 100 or rem is a round
    // hundred (200, 300, …). Otherwise ", " is closer to natural
    // speech ("mil, duzentos e trinta e quatro"). We pick " e " when
    // rem < 100 or rem % 100 == 0; otherwise " ".
    if (rem < 100 or rem % 100 == 0) {
        try out.appendSlice(arena, " e ");
    } else {
        try out.appendSlice(arena, " ");
    }
    try appendUnder1000(out, arena, rem);
}

fn expandNumbers(arena: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, input.len);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];

        // Negative number: `-` followed directly by digits, at a word
        // boundary (start of string or after non-word byte).
        if (c == '-' and i + 1 < input.len and std.ascii.isDigit(input[i + 1])) {
            const at_word_start = (i == 0) or !isWordByte(input[i - 1]);
            if (at_word_start) {
                // Look ahead at digit run.
                var j = i + 1;
                while (j < input.len and std.ascii.isDigit(input[j])) : (j += 1) {}
                // Skip if the digit run is followed by a letter or `%`.
                const followed_by_letter = j < input.len and isWordByte(input[j]);
                const followed_by_pct = j < input.len and input[j] == '%';
                if (!followed_by_letter and !followed_by_pct) {
                    const value = std.fmt.parseInt(u16, input[i + 1 .. j], 10) catch {
                        try out.append(arena, c);
                        i += 1;
                        continue;
                    };
                    try out.appendSlice(arena, "menos ");
                    try renderCardinal(&out, arena, value);
                    i = j;
                    continue;
                }
            }
        }

        if (std.ascii.isDigit(c)) {
            const at_word_start = (i == 0) or !isWordByte(input[i - 1]);
            if (at_word_start) {
                var j = i;
                while (j < input.len and std.ascii.isDigit(input[j])) : (j += 1) {}
                const followed_by_letter = j < input.len and isWordByte(input[j]);
                const followed_by_pct = j < input.len and input[j] == '%';
                if (!followed_by_letter and !followed_by_pct) {
                    const value = std.fmt.parseInt(u16, input[i..j], 10) catch {
                        // Out of range (>65535 or >9999). Leave raw.
                        try out.appendSlice(arena, input[i..j]);
                        i = j;
                        continue;
                    };
                    if (value > 9999) {
                        try out.appendSlice(arena, input[i..j]);
                    } else {
                        try renderCardinal(&out, arena, value);
                    }
                    i = j;
                    continue;
                }
            }
        }

        try out.append(arena, c);
        i += 1;
    }

    return out.toOwnedSlice(arena);
}

// ──────────────────────────────────────────────────────────────────────
// Stage 3 — pause directives
// ──────────────────────────────────────────────────────────────────────
//
// `[[slnc N]]` is a literal directive `say` accepts (milliseconds).
//
// Rules:
//   - `,`          → `, [[slnc 150]]`
//   - `.` `!` `?`  → `<punct> [[slnc 400]]`
//   - `\n`         → `[[slnc 600]]` (newline itself eaten)
//   - Multiple consecutive punctuation collapses to one pause, taking
//     the longest of the group, emitted after the last printable
//     punctuation char in the run.
//
// We scan in one pass, accumulating "pause-bearing" runs. A run is any
// maximal sequence of {',' '.' '!' '?' '\n' ' ' '\t'} that contains at
// least one pause-bearing char. We strip leading/trailing whitespace
// from the run on emit, keep the punctuation chars in order (except
// '\n' is dropped — only its pause survives), and append a single
// `[[slnc N]]` with N = max pause across all chars.

fn pauseMsForTuned(c: u8, p: ResolvedPauses) ?u32 {
    return switch (c) {
        ',' => p.comma,
        '.', '!', '?' => p.sentence,
        '\n' => p.newline,
        else => null,
    };
}

fn isRunByte(c: u8) bool {
    return c == ',' or c == '.' or c == '!' or c == '?' or
        c == '\n' or c == ' ' or c == '\t';
}

/// Backward-compatible front-end — used by tests / call sites that don't
/// need overrides. Delegates to `insertPausesTuned` with all defaults.
fn insertPauses(arena: std.mem.Allocator, input: []const u8) ![]u8 {
    return insertPausesTuned(arena, input, .{
        .comma = Pause.COMMA_MS,
        .sentence = Pause.SENTENCE_MS,
        .newline = Pause.NEWLINE_MS,
    });
}

fn insertPausesTuned(
    arena: std.mem.Allocator,
    input: []const u8,
    pauses: ResolvedPauses,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    // Worst case: every char becomes "X [[slnc 600]]". ~12 byte overhead.
    try out.ensureTotalCapacity(arena, input.len * 2);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];

        // Detect start of a run that contains a pause-bearing char.
        if (isRunByte(c)) {
            // Find end of run.
            var j = i;
            while (j < input.len and isRunByte(input[j])) : (j += 1) {}
            const run = input[i..j];

            // Compute max pause + collect printable punctuation chars.
            var max_pause: u32 = 0;
            for (run) |ch| {
                if (pauseMsForTuned(ch, pauses)) |p| {
                    if (p > max_pause) max_pause = p;
                }
            }

            if (max_pause == 0) {
                // Pure whitespace (spaces/tabs only). Pass through as
                // a single space to avoid collapsing intentional
                // formatting too aggressively.
                try out.append(arena, ' ');
                i = j;
                continue;
            }

            // Emit printable punctuation, in order, dropping spaces/
            // tabs/newlines.
            for (run) |ch| {
                switch (ch) {
                    ',', '.', '!', '?' => try out.append(arena, ch),
                    else => {},
                }
            }
            try out.appendSlice(arena, " [[slnc ");
            try out.print(arena, "{d}", .{max_pause});
            try out.appendSlice(arena, "]]");
            // Trailing space so the next word doesn't glue to the
            // directive in the rendered text. If the run is at end of
            // input we still emit it — harmless to `say`.
            try out.append(arena, ' ');
            i = j;
            continue;
        }

        try out.append(arena, c);
        i += 1;
    }

    return out.toOwnedSlice(arena);
}

// ──────────────────────────────────────────────────────────────────────
// v1.10.8 — tech glossary
// ──────────────────────────────────────────────────────────────────────
//
// The tech-report mode substitutes a curated set of technical terms
// before the rest of the v0.5 preproc runs. Two flavours:
//
//   * Acronyms ≤ keep_acronyms_short_limit chars (default 3) get spelled
//     out: "API" → "A P I", "MCP" → "M C P". Letters are routed through
//     the Pt-BR letter map ("A" → "A", "X" → "xis") so Piper's espeak-ng
//     frontend pronounces them correctly without a phoneme dictionary.
//   * Branded words / multi-letter acronyms longer than the limit get a
//     curated phonetic transcription ("ONNX" → "ônix", "JSON" → "jeisson")
//     to dodge espeak-ng's English-default fallback.
//   * Unit symbols (MB, KB, ms, Hz) expand to their Pt-BR pronunciation.
//
// Matching: case-insensitive by default for the units / pure-letter
// acronyms; sort by longest src first so "kHz" beats "Hz" and "MBPS"
// (kept verbatim — not in the table) doesn't get half-matched.
// Word-boundary check mirrors `expandAbbreviations` so "Bitmap" doesn't
// turn into "BITM A P".

const TechEntry = struct {
    src: []const u8,
    dst: []const u8,
    /// When true, match is case-insensitive AND the destination is used
    /// verbatim regardless of input case. When false, the match is exact.
    /// Mixed-case branded entries ("GitHub" → "gite hub") stay exact.
    case_insensitive: bool = false,
};

// Sorted longest-first to keep the linear scan's first-match logic from
// stealing prefixes (e.g. "kHz" before "Hz", "milissegundos" before "ms",
// "HTTPS" before "HTTP"). v1.10.9 expansion adds the missing acronyms,
// units, and brand names called out in the research-prompt distillation
// (`_qa/v1.10.9-research-prompt-output.md`).
const TECH_GLOSSARY = [_]TechEntry{
    // ── Multi-word phrases (longest first to win over single-word components)
    .{ .src = "Claude Code", .dst = "Claude Code" },
    .{ .src = "XTTS v2", .dst = "X T T S vê dois" },

    // ── Brand names (mixed-case exact match, ordered longest-first)
    .{ .src = "PostgreSQL", .dst = "pós-ti-grês-quiu-el" },
    .{ .src = "SurrealDB", .dst = "surreal D B" },
    .{ .src = "Homebrew", .dst = "home-briu" },
    .{ .src = "Pydantic", .dst = "paidântic" },
    .{ .src = "FastAPI", .dst = "fast A P I" },
    .{ .src = "libpiper", .dst = "lib paiper" },
    .{ .src = "ChatGPT", .dst = "chate gê pê tê" },
    .{ .src = "SQLite", .dst = "es-quiu-lai-ti" },
    .{ .src = "SwiftUI", .dst = "swift U I" },
    .{ .src = "GitHub", .dst = "guite hub" },
    .{ .src = "Docker", .dst = "dóquer" },
    .{ .src = "Nginx", .dst = "enginx" },
    .{ .src = "Anthropic", .dst = "Anthropic" },
    .{ .src = "Cursor", .dst = "Cursor" },
    .{ .src = "Cline", .dst = "Cline" },
    .{ .src = "Piper", .dst = "Piper" },
    .{ .src = "Faber", .dst = "Faber" },
    .{ .src = "NATS", .dst = "nats" },
    .{ .src = "Zsh", .dst = "zi shell" },

    // ── 4+ letter acronyms (phonetic / spelled). v1.10.9: HTTPS/HTTP/UUID/EOF
    .{ .src = "HTTPS", .dst = "agá tê tê pê esse", .case_insensitive = true },
    .{ .src = "HTTP", .dst = "agá tê tê pê", .case_insensitive = true },
    .{ .src = "YAML", .dst = "iêimel", .case_insensitive = true },
    .{ .src = "yaml", .dst = "iêimel", .case_insensitive = true },
    .{ .src = "JSON", .dst = "jeisson", .case_insensitive = true },
    .{ .src = "HTML", .dst = "agá tê eme éle", .case_insensitive = true },
    .{ .src = "XTTS", .dst = "X T T S" },
    .{ .src = "ONNX", .dst = "ônix" },
    .{ .src = "UUID", .dst = "U U I D", .case_insensitive = true },
    .{ .src = "CI-CD", .dst = "C I C D", .case_insensitive = true },
    .{ .src = "CI/CD", .dst = "C I C D", .case_insensitive = true },

    // ── Unit symbols (longest-first within their family). v1.10.9: Mbps/Gbps/fps/bps/TB/dB/px
    .{ .src = "Mbps", .dst = "megabits por segundo" },
    .{ .src = "Gbps", .dst = "gigabits por segundo" },
    .{ .src = "kHz", .dst = "kilohertz" },
    .{ .src = "fps", .dst = "quadros por segundo" },
    .{ .src = "bps", .dst = "bits por segundo" },
    .{ .src = "µs", .dst = "microssegundos" },
    .{ .src = "ms", .dst = "milissegundos" },
    .{ .src = "ns", .dst = "nanossegundos" },
    .{ .src = "px", .dst = "pixels" },
    .{ .src = "dB", .dst = "decibéis" },
    .{ .src = "Hz", .dst = "hertz" },
    .{ .src = "TB", .dst = "terabytes" },
    .{ .src = "MB", .dst = "megabytes" },
    .{ .src = "KB", .dst = "kilobytes" },
    .{ .src = "GB", .dst = "gigabytes" },

    // ── 3-letter acronyms (Pt-BR letter names). v1.10.9: TCP/UDP/CSV/XML/PDF/IDE/ORM/EOF/SSH
    .{ .src = "EOF", .dst = "E O F", .case_insensitive = true },
    .{ .src = "API", .dst = "A P I", .case_insensitive = true },
    .{ .src = "MCP", .dst = "M C P", .case_insensitive = true },
    .{ .src = "CPU", .dst = "C P U", .case_insensitive = true },
    .{ .src = "GPU", .dst = "G P U", .case_insensitive = true },
    .{ .src = "RAM", .dst = "RAM", .case_insensitive = true },
    .{ .src = "TTS", .dst = "T T S", .case_insensitive = true },
    .{ .src = "SQL", .dst = "S Q L", .case_insensitive = true },
    .{ .src = "URL", .dst = "U R L", .case_insensitive = true },
    .{ .src = "DNS", .dst = "D N S", .case_insensitive = true },
    .{ .src = "SSH", .dst = "S S H", .case_insensitive = true },
    .{ .src = "TCP", .dst = "T C P", .case_insensitive = true },
    .{ .src = "UDP", .dst = "U D P", .case_insensitive = true },
    .{ .src = "CSV", .dst = "C S V", .case_insensitive = true },
    .{ .src = "PDF", .dst = "P D F", .case_insensitive = true },
    .{ .src = "IDE", .dst = "I D É", .case_insensitive = true },
    .{ .src = "ORM", .dst = "O R M", .case_insensitive = true },
    .{ .src = "LLM", .dst = "L L M", .case_insensitive = true },
    .{ .src = "CSS", .dst = "C S S", .case_insensitive = true },
    .{ .src = "XML", .dst = "X M L", .case_insensitive = true },
    .{ .src = "SDK", .dst = "S D K", .case_insensitive = true },
    .{ .src = "CLI", .dst = "C L I", .case_insensitive = true },
    // ── 2-letter
    .{ .src = "OS", .dst = "O S" },
};

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xl = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const yl = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (xl != yl) return false;
    }
    return true;
}

fn matchesGlossaryAt(input: []const u8, idx: usize, entry: TechEntry) bool {
    if (idx + entry.src.len > input.len) return false;
    const slice = input[idx .. idx + entry.src.len];
    if (entry.case_insensitive) return asciiEqlIgnoreCase(slice, entry.src);
    return std.mem.eql(u8, slice, entry.src);
}

fn expandTechGlossary(
    arena: std.mem.Allocator,
    input: []const u8,
    tech: TechOptions,
) ![]u8 {
    _ = tech; // currently informational — sweet-spot knob for v1.10.9
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, input.len);

    var i: usize = 0;
    while (i < input.len) {
        const at_word_start = (i == 0) or !isWordByte(input[i - 1]);

        var matched: ?TechEntry = null;
        if (at_word_start) {
            for (TECH_GLOSSARY) |entry| {
                if (!matchesGlossaryAt(input, i, entry)) continue;
                // Word-boundary tail: the byte after `src` must not be a
                // word byte (otherwise "MBPS" would match "MB").
                const tail = i + entry.src.len;
                const at_word_end = (tail >= input.len) or !isWordByte(input[tail]);
                if (!at_word_end) continue;
                matched = entry;
                break;
            }
        }

        if (matched) |entry| {
            try out.appendSlice(arena, entry.dst);
            i += entry.src.len;
        } else {
            try out.append(arena, input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

// ──────────────────────────────────────────────────────────────────────
// v1.10.9 — CamelCase splitter
// ──────────────────────────────────────────────────────────────────────
//
// Inserts a space at camel boundaries so identifiers like `MultiPiperEngine`
// reach espeak-ng (Piper's phonemizer) as separate tokens. Three rules,
// applied in one pass:
//
//   1. Insert space before an uppercase letter that is preceded by a
//      lowercase ASCII letter or an ASCII digit.
//         `getConditioning` → `get Conditioning`
//         `MultiPiperEngine` → `Multi Piper Engine`
//         `ChatGPT5`        → matches t→G here (`Chat G…`).
//   2. End of all-caps run: insert space before an uppercase letter when
//      the previous byte is uppercase AND the next byte is lowercase.
//         `SQLite` → `SQ Lite`. Preserves all-caps acronyms like `SQL`,
//         `HTTPS`, `TTS` whose entire run is followed by a non-letter.
//   3. Insert space before an ASCII digit that is preceded by an uppercase
//      ASCII letter.
//         `ChatGPT5` → `Chat GPT 5`.
//
// All other transitions pass through verbatim. UTF-8 continuation bytes
// (>= 0x80) are treated as opaque — a continuation byte never triggers a
// camel split and never satisfies the "previous lowercase" or "next
// lowercase" predicates. Acentos in Pt-BR therefore can't break a run.
pub fn splitCamelCase(arena: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, input.len);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];

        if (i > 0) {
            const prev = input[i - 1];
            const next: ?u8 = if (i + 1 < input.len) input[i + 1] else null;

            // Rule 1: lower/digit → Upper
            if (isAsciiUpper(c) and (isAsciiLower(prev) or std.ascii.isDigit(prev))) {
                try out.append(arena, ' ');
            }
            // Rule 2: Upper-run end (Upper → Upper followed by lower)
            else if (isAsciiUpper(c) and isAsciiUpper(prev)) {
                if (next) |n| {
                    if (isAsciiLower(n)) try out.append(arena, ' ');
                }
            }
            // Rule 3: Upper → digit
            else if (std.ascii.isDigit(c) and isAsciiUpper(prev)) {
                try out.append(arena, ' ');
            }
        }

        try out.append(arena, c);
    }

    return out.toOwnedSlice(arena);
}

fn isAsciiUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isAsciiLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

// ──────────────────────────────────────────────────────────────────────
// v1.10.9 — identifier normalization
// ──────────────────────────────────────────────────────────────────────
//
// Rewrites version strings, commit hashes, URLs, file paths, and hex
// literals into Pt-BR-pronounceable forms before the cardinal + pause
// stages run. The transformations are conservative — each rule only fires
// at a word boundary so plain prose text is never disturbed.
//
//   * Versions  `1.10.8`                       → `1 ponto 10 ponto 8`
//   * Commit    `bdd352e`                      → `commit bê dê dê três cinco dois é`
//   * URLs      `https://github.com/foo/bar`   → `github ponto com barra foo barra bar`
//   * Paths     `~/.cache/ptah/voices/`   → `pasta voices`
//   * Hex       `0xFF`                          → `zero-x F F`
//
// Each rule is independent. Detection priority (highest first): URL → hex
// literal → file path → commit hash → version. The scanner picks the first
// match at the current cursor and emits the rewritten span; otherwise it
// passes the byte through. All emissions are surrounded by a space when
// the previous output byte is alphanumeric, so prose like "v1.10.8" gets
// the version's word boundary even though the leading "v" is part of the
// preceding token.
pub fn normalizeIdentifiers(arena: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, input.len);

    var i: usize = 0;
    while (i < input.len) {
        // Each branch returns the new cursor position (== old i when not matched).
        if (tryEmitUrl(arena, &out, input, i)) |next| {
            i = next;
            continue;
        }
        if (tryEmitHexLiteral(arena, &out, input, i)) |next| {
            i = next;
            continue;
        }
        if (tryEmitPath(arena, &out, input, i)) |next| {
            i = next;
            continue;
        }
        if (try tryEmitCommitHash(arena, &out, input, i)) |next| {
            i = next;
            continue;
        }
        if (try tryEmitVersion(arena, &out, input, i)) |next| {
            i = next;
            continue;
        }
        try out.append(arena, input[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// Ensure the output stream has a space-equivalent separator before the
/// next emission so a normalized token doesn't glue onto a preceding
/// alphanumeric (`v1.10.8` after rewrite becomes `v 1 ponto 10 ponto 8`).
fn ensureLeadingSpace(arena: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    if (out.items.len == 0) return;
    const last = out.items[out.items.len - 1];
    if (last == ' ' or last == '\t' or last == '\n') return;
    try out.append(arena, ' ');
}

fn startsWithCi(haystack: []const u8, idx: usize, needle: []const u8) bool {
    if (idx + needle.len > haystack.len) return false;
    for (needle, 0..) |n, k| {
        const h = haystack[idx + k];
        const nl = if (n >= 'A' and n <= 'Z') n + 32 else n;
        const hl = if (h >= 'A' and h <= 'Z') h + 32 else h;
        if (hl != nl) return false;
    }
    return true;
}

fn isUrlByte(c: u8) bool {
    // Conservative URL terminator: anything that can't appear in a path
    // /query /fragment past the scheme. Whitespace and quotes break the run.
    return c > 0x20 and c != '"' and c != '\'' and c != '<' and c != '>' and
        c != ')' and c != ']' and c != '}' and c != ',';
}

fn tryEmitUrl(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    input: []const u8,
    start: usize,
) ?usize {
    const at_word_start = (start == 0) or !isWordByte(input[start - 1]);
    if (!at_word_start) return null;
    var skip: usize = 0;
    if (startsWithCi(input, start, "https://")) {
        skip = "https://".len;
    } else if (startsWithCi(input, start, "http://")) {
        skip = "http://".len;
    } else return null;

    // Walk until the first non-URL byte.
    var j = start + skip;
    while (j < input.len and isUrlByte(input[j])) : (j += 1) {}
    if (j == start + skip) return null; // protocol with empty body — leave raw

    ensureLeadingSpace(arena, out) catch return null;
    var idx = start + skip;
    while (idx < j) : (idx += 1) {
        const c = input[idx];
        switch (c) {
            '.' => out.appendSlice(arena, " ponto ") catch return null,
            '/' => out.appendSlice(arena, " barra ") catch return null,
            else => out.append(arena, c) catch return null,
        }
    }
    return j;
}

fn tryEmitPath(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    input: []const u8,
    start: usize,
) ?usize {
    const at_word_start = (start == 0) or !isWordByte(input[start - 1]);
    if (!at_word_start) return null;
    // `/foo/...` or `~/foo/...`. Must contain at least one '/'.
    var has_prefix: bool = false;
    var probe_idx: usize = start;
    if (input[start] == '/') {
        has_prefix = true;
        probe_idx = start;
    } else if (input[start] == '~' and start + 1 < input.len and input[start + 1] == '/') {
        has_prefix = true;
        probe_idx = start;
    }
    if (!has_prefix) return null;

    // Walk to end-of-token. Reuse URL-byte rule (paths can contain dots,
    // dashes, alphanumerics, slashes — same forbidden set).
    var j = probe_idx;
    while (j < input.len and isUrlByte(input[j])) : (j += 1) {}
    if (j == probe_idx) return null;

    // Must contain at least one '/' beyond the prefix to qualify.
    var slash_count: usize = 0;
    var k: usize = probe_idx;
    while (k < j) : (k += 1) {
        if (input[k] == '/') slash_count += 1;
    }
    if (slash_count < 1) return null;

    // Final non-empty component. Walk backwards skipping trailing '/'.
    var tail_end: usize = j;
    while (tail_end > probe_idx and input[tail_end - 1] == '/') tail_end -= 1;
    if (tail_end == probe_idx) return null;
    var tail_start: usize = tail_end;
    while (tail_start > probe_idx and input[tail_start - 1] != '/') tail_start -= 1;
    const component = input[tail_start..tail_end];
    if (component.len == 0) return null;

    ensureLeadingSpace(arena, out) catch return null;
    out.appendSlice(arena, "pasta ") catch return null;
    out.appendSlice(arena, component) catch return null;
    return j;
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn tryEmitHexLiteral(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    input: []const u8,
    start: usize,
) ?usize {
    const at_word_start = (start == 0) or !isWordByte(input[start - 1]);
    if (!at_word_start) return null;
    if (start + 2 >= input.len) return null;
    if (input[start] != '0') return null;
    if (input[start + 1] != 'x' and input[start + 1] != 'X') return null;
    var j = start + 2;
    var has_uppercase_hex: bool = false;
    while (j < input.len and isHexDigit(input[j])) : (j += 1) {
        if (input[j] >= 'A' and input[j] <= 'F') has_uppercase_hex = true;
    }
    if (j == start + 2) return null;
    // Word-boundary tail: next byte must not be a word byte.
    if (j < input.len and isWordByte(input[j])) return null;
    // Only fire when there is at least one hex letter A-F (uppercase) — the
    // common literal form. `0x9` alone could be confused with a decimal
    // prefix used in flag handling, so leave purely numeric `0x…` to the
    // version/number stage when no A-F letters appear.
    if (!has_uppercase_hex) return null;

    ensureLeadingSpace(arena, out) catch return null;
    out.appendSlice(arena, "zero-x") catch return null;
    var k: usize = start + 2;
    while (k < j) : (k += 1) {
        out.append(arena, ' ') catch return null;
        out.append(arena, input[k]) catch return null;
    }
    return j;
}

/// Lowercase Pt-BR letter name for the 'a'..'f' hex digits used in commit
/// hashes. The other rules emit ASCII letters verbatim; commit hashes
/// pre-spell the entire 7-char prefix so an espeak-ng misfire on a
/// short string like "bdd" can't slip through.
fn ptBrLowerHexLetterName(c: u8) []const u8 {
    return switch (c) {
        'a' => "á",
        'b' => "bê",
        'c' => "cê",
        'd' => "dê",
        'e' => "é",
        'f' => "éfe",
        else => "",
    };
}

fn ptBrDigitName(c: u8) []const u8 {
    return switch (c) {
        '0' => "zero",
        '1' => "um",
        '2' => "dois",
        '3' => "três",
        '4' => "quatro",
        '5' => "cinco",
        '6' => "seis",
        '7' => "sete",
        '8' => "oito",
        '9' => "nove",
        else => "",
    };
}

fn isCommitHashByte(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

fn tryEmitCommitHash(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    input: []const u8,
    start: usize,
) !?usize {
    const at_word_start = (start == 0) or !isWordByte(input[start - 1]);
    if (!at_word_start) return null;
    var j: usize = start;
    var has_letter: bool = false;
    while (j < input.len and isCommitHashByte(input[j])) : (j += 1) {
        if (input[j] >= 'a' and input[j] <= 'f') has_letter = true;
    }
    const span = j - start;
    if (span < 7 or span > 40) return null;
    // Word-boundary tail.
    if (j < input.len and isWordByte(input[j])) return null;
    // Must have at least one lowercase a-f letter — pure-digit runs are
    // versions / IDs, not commit hashes.
    if (!has_letter) return null;

    try ensureLeadingSpace(arena, out);
    try out.appendSlice(arena, "commit");
    // Truncate to first 7 characters, spell letter-by-letter (Pt-BR
    // letter name) and digit-by-digit (Pt-BR cardinal). The cardinal
    // expansion below stays in-arena because we emit the literal Pt-BR
    // words and never the raw digit char — `expandNumbers` therefore
    // doesn't re-touch this span.
    var k: usize = 0;
    while (k < 7) : (k += 1) {
        const c = input[start + k];
        try out.append(arena, ' ');
        if (c >= 'a' and c <= 'f') {
            try out.appendSlice(arena, ptBrLowerHexLetterName(c));
        } else if (c >= '0' and c <= '9') {
            try out.appendSlice(arena, ptBrDigitName(c));
        }
    }
    return j;
}

fn tryEmitVersion(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    input: []const u8,
    start: usize,
) !?usize {
    // Versions don't strictly require a word boundary on the left (the
    // smoke test uses "v1.10.8" — leading "v" is a word byte). We allow
    // the match when the *digit* token starts here. The normalizer scans
    // any digit-dot-digit pattern; the abbreviation guard for "Sr.", etc.
    // doesn't apply because those entries end in alpha+dot.
    if (!std.ascii.isDigit(input[start])) return null;
    var j: usize = start;
    while (j < input.len and std.ascii.isDigit(input[j])) : (j += 1) {}
    // Require at least one `.<digit>` group after the first int.
    if (j >= input.len or input[j] != '.') return null;
    if (j + 1 >= input.len or !std.ascii.isDigit(input[j + 1])) return null;
    var dot_groups: usize = 0;
    while (j < input.len and input[j] == '.' and j + 1 < input.len and std.ascii.isDigit(input[j + 1])) {
        dot_groups += 1;
        j += 1;
        while (j < input.len and std.ascii.isDigit(input[j])) : (j += 1) {}
    }
    if (dot_groups == 0) return null;
    // Tail must not be a word byte (otherwise `1.10.8a` would consume the
    // dot-groups but leave a dangling letter).
    if (j < input.len and isWordByte(input[j])) return null;

    try ensureLeadingSpace(arena, out);
    var k: usize = start;
    while (k < j) : (k += 1) {
        const c = input[k];
        if (c == '.') {
            try out.appendSlice(arena, " ponto ");
        } else {
            try out.append(arena, c);
        }
    }
    return j;
}

// ──────────────────────────────────────────────────────────────────────
// v1.2 — sentence chunking for streaming
// ──────────────────────────────────────────────────────────────────────
//
// `chunkSentences` splits raw input into Chunks on `.`, `!`, `?`, `\n`.
// Punctuation stays attached to the preceding chunk; newline is dropped
// (its semantic pause comes back when `process` runs on the chunk).
//
// Abbreviation guard: a `.` that closes an entry in ABBREVS (e.g. `Sr.`,
// `Dr.`, `Sra.`, `Av.`) does NOT terminate. Mirrors the same list used by
// `expandAbbreviations`, so the streaming path can't introduce a split
// the non-streaming path wouldn't honor. Lower-case-only abbreviations
// like `cf.`, `etc.`, `vs.` are also guarded.
//
// Leading/trailing whitespace per chunk is trimmed. Empty chunks dropped.
//
// Returns a slice of Chunks owned by `arena`. Each chunk's `text` field
// is a subslice of `text` (no copy) — caller must keep `text` alive for
// the chunks' lifetime.
//
// Known v1.2 corner cases (documented in whats-next.md for v1.2.1):
//   - Decimals like "3.14" — the `.` is treated as a terminator. Acceptable
//     because preproc's number stage doesn't handle decimals either.
//   - Ellipsis "..." — collapses to a single chunk break (multiple `.`s
//     in a row yield one split, not three).

fn isAbbrevDotAt(input: []const u8, dot_idx: usize) bool {
    // Check whether input[dot_idx] == '.' is the terminating dot of any
    // entry in ABBREVS. Boundary rule mirrors expandAbbreviations: the
    // entry must start at a word boundary.
    if (dot_idx >= input.len or input[dot_idx] != '.') return false;
    for (ABBREVS) |ab| {
        if (ab.src.len == 0 or ab.src[ab.src.len - 1] != '.') continue;
        if (ab.src.len > dot_idx + 1) continue;
        const start = dot_idx + 1 - ab.src.len;
        if (!std.mem.eql(u8, input[start .. dot_idx + 1], ab.src)) continue;
        const at_word_start = (start == 0) or !isWordByte(input[start - 1]);
        if (at_word_start) return true;
    }
    return false;
}

fn isTerminator(c: u8) bool {
    return c == '.' or c == '!' or c == '?' or c == '\n';
}

/// Returns a freshly allocated slice of Chunks (in `arena`). Single
/// sentence with no terminator → one chunk. Empty input → empty slice.
/// Punctuation attaches to the preceding chunk; newlines are dropped.
pub fn chunkSentences(arena: std.mem.Allocator, text: []const u8) ![]Chunk {
    var out: std.ArrayList(Chunk) = .empty;
    if (text.len == 0) return out.toOwnedSlice(arena);

    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (!isTerminator(c)) continue;
        // Abbreviation-aware: skip `.` that closes Sr./Dr./etc.
        if (c == '.' and isAbbrevDotAt(text, i)) continue;

        // Extend the run over any consecutive trailing terminators so an
        // ellipsis "..." or a "?!" combo emits a single chunk break.
        var j = i + 1;
        while (j < text.len and isTerminator(text[j])) : (j += 1) {}

        // `end_attached` = end of the chunk INCLUDING the run of
        // non-newline punctuation, EXCLUDING any '\n' bytes (we drop
        // newlines on emit — the pause stage will reinsert their slnc).
        var end_attached = i;
        var k = i;
        while (k < j) : (k += 1) {
            if (text[k] != '\n') end_attached = k;
        }
        // If the run was newline-only, the chunk closes at i-1 (i.e.
        // strip the newline entirely). Otherwise include up to the last
        // non-newline terminator.
        const run_has_punct = blk: {
            var m = i;
            while (m < j) : (m += 1) if (text[m] != '\n') break :blk true;
            break :blk false;
        };

        const slice_end: usize = if (run_has_punct) end_attached + 1 else i;
        const raw = trimChunk(text[start..slice_end]);
        if (raw.len != 0) try out.append(arena, .{ .text = raw, .lang = .unknown });

        start = j;
        i = j - 1; // loop will i+=1 → j
    }

    if (start < text.len) {
        const raw = trimChunk(text[start..]);
        if (raw.len != 0) try out.append(arena, .{ .text = raw, .lang = .unknown });
    }

    return out.toOwnedSlice(arena);
}

fn trimChunk(s: []const u8) []const u8 {
    var lo: usize = 0;
    var hi: usize = s.len;
    while (lo < hi and (s[lo] == ' ' or s[lo] == '\t' or s[lo] == '\n' or s[lo] == '\r')) lo += 1;
    while (hi > lo and (s[hi - 1] == ' ' or s[hi - 1] == '\t' or s[hi - 1] == '\n' or s[hi - 1] == '\r')) hi -= 1;
    return s[lo..hi];
}

// ──────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn runProcess(input: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try process(arena, input);
    testing.expectEqualStrings(expected, got) catch |e| {
        std.debug.print("\ninput:    {s}\nexpected: {s}\ngot:      {s}\n", .{ input, expected, got });
        return e;
    };
}

test "empty string returns empty" {
    try runProcess("", "");
}

test "abbreviation Sr." {
    // The period in "Sr." is consumed as part of the abbrev — it's
    // semantically an abbreviation marker, not a sentence terminator.
    try runProcess("Sr. Silva", "Senhor Silva");
}

test "abbreviation does not match mid-word" {
    // "aSr." should NOT expand: Sr. must be at a word start.
    try runProcess("aSr. teste", "aSr. [[slnc 400]] teste");
}

test "abbreviation chain: Dr. + Sra. + R$" {
    try runProcess(
        "Dr. e Sra. devem R$",
        "Doutor e Senhora devem reais",
    );
}

test "number under 100" {
    try runProcess(
        "tenho 42 maçãs",
        "tenho quarenta e dois maçãs",
    );
}

test "number under 1000 (cem)" {
    try runProcess("100", "cem");
}

test "number under 1000 (cento e ...)" {
    try runProcess("123", "cento e vinte e três");
}

test "number 2026" {
    try runProcess("2026", "dois mil e vinte e seis");
}

test "number zero" {
    try runProcess("0", "zero");
}

test "negative number" {
    try runProcess("temperatura -5 graus", "temperatura menos cinco graus");
}

test "number followed by letter is skipped" {
    try runProcess("MP3", "MP3");
}

test "number followed by percent is skipped" {
    try runProcess("50%", "50%");
}

test "comma pause" {
    try runProcess("um, dois", "um, [[slnc 150]] dois");
}

test "sentence pause" {
    try runProcess("vai. agora", "vai. [[slnc 400]] agora");
}

test "trailing punctuation emits pause" {
    try runProcess("acabou.", "acabou. [[slnc 400]] ");
}

test "newline pause" {
    try runProcess("linha 1\nlinha 2", "linha um [[slnc 600]] linha dois");
}

test "multiple punctuation collapses to longest" {
    // ".!" → longest is sentence-ms (400), both chars kept.
    try runProcess("vai!. agora", "vai!. [[slnc 400]] agora");
}

test "ellipsis collapses to single sentence pause" {
    try runProcess("hmm... ok", "hmm... [[slnc 400]] ok");
}

test "comma plus newline keeps newline pause" {
    try runProcess("uma,\ndois", "uma, [[slnc 600]] dois");
}

test "only punctuation" {
    try runProcess("...", "... [[slnc 400]] ");
}

test "mixed abbreviation, number and punctuation" {
    try runProcess(
        "Sr. Silva tem 25 anos, certo?",
        "Senhor Silva tem vinte e cinco anos, [[slnc 150]] certo? [[slnc 400]] ",
    );
}

test "Av. nº and large number" {
    // 1578 = "mil quinhentos e setenta e oito" — Pt-BR uses no "e"
    // between thousands and a non-round hundreds part.
    try runProcess(
        "Av. Paulista, nº 1578.",
        "Avenida Paulista, [[slnc 150]] número mil quinhentos e setenta e oito. [[slnc 400]] ",
    );
}

test "round thousand" {
    try runProcess("3000", "três mil");
}

test "round hundreds inside thousand" {
    try runProcess("1200", "mil e duzentos");
}

test "out of range 0..9999 leaves raw" {
    try runProcess("12345", "12345");
}

test "leading number" {
    try runProcess("7 anões", "sete anões");
}

// ─── v1.10.8 tech glossary + pause overrides ───────────────────────────

fn runTech(input: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try processTech(arena, input, .{});
    testing.expectEqualStrings(expected, got) catch |e| {
        std.debug.print("\ninput:    {s}\nexpected: {s}\ngot:      {s}\n", .{ input, expected, got });
        return e;
    };
}

test "tech: API spelled out at word boundary" {
    try runTech("API rodou", "A P I rodou");
}

test "tech: MCP and CPU together" {
    try runTech("MCP em CPU", "M C P em C P U");
}

test "tech: MB expands to megabytes" {
    try runTech("64 MB", "sessenta e quatro megabytes");
}

test "tech: ms expands to milissegundos" {
    try runTech("250 ms warm", "duzentos e cinquenta milissegundos warm");
}

test "tech: kHz beats Hz (longest-first)" {
    try runTech("44 kHz", "quarenta e quatro kilohertz");
}

test "tech: ONNX gets phonetic" {
    try runTech("modelo ONNX", "modelo ônix");
}

test "tech: JSON case-insensitive" {
    try runTech("payload json válido", "payload jeisson válido");
}

test "tech: branded GitHub stays exact" {
    try runTech("clonei do GitHub", "clonei do guite hub");
}

test "tech: mid-word non-match (BITMAP not BIT-MA-P)" {
    // "MB" inside "MBPS" must NOT match — word boundary stops the steal.
    try runTech("MBPS speed", "MBPS speed");
}

test "tech: lower-case api still matches" {
    try runTech("a api caiu", "a A P I caiu");
}

test "tech: glossary + number + comma pause" {
    try runTech(
        "API caiu, 250 ms.",
        "A P I caiu, [[slnc 150]] duzentos e cinquenta milissegundos. [[slnc 400]] ",
    );
}

test "tech: XTTS v2 phrase (multi-word src)" {
    try runTech("rodando XTTS v2 local", "rodando X T T S vê dois local");
}

test "tech: empty input" {
    try runTech("", "");
}

test "tech: untouched text without acronyms" {
    try runTech("Olá mundo.", "Olá mundo. [[slnc 400]] ");
}

test "pauses override: comma stretched to 220ms" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try processWithPauses(arena, "um, dois", .{ .comma_ms = 220 });
    try testing.expectEqualStrings("um, [[slnc 220]] dois", got);
}

test "pauses override: sentence stretched to 500ms (tech profile shape)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try processWithPauses(arena, "vai. agora", .{ .sentence_ms = 500 });
    try testing.expectEqualStrings("vai. [[slnc 500]] agora", got);
}

test "pauses override: zero falls back to default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try processWithPauses(arena, "vai. agora", .{});
    try testing.expectEqualStrings("vai. [[slnc 400]] agora", got);
}

test "tech + pauses: profile-tech-like shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try processTechWithPauses(arena, "API ok.", .{}, .{ .sentence_ms = 500 });
    try testing.expectEqualStrings("A P I ok. [[slnc 500]] ", got);
}

// ─── v1.10.9 glossary additions ────────────────────────────────────────

test "tech v1.10.9: HTTPS beats HTTP (longest-first)" {
    try runTech("via HTTPS então", "via agá tê tê pê esse então");
}

test "tech v1.10.9: HTTP spelled" {
    try runTech("via HTTP simples", "via agá tê tê pê simples");
}

test "tech v1.10.9: TCP UDP YAML CSV PDF" {
    try runTech(
        "TCP UDP YAML CSV PDF",
        "T C P U D P iêimel C S V P D F",
    );
}

test "tech v1.10.9: Docker Nginx Homebrew Zsh" {
    try runTech(
        "Docker Nginx Homebrew Zsh",
        "dóquer enginx home-briu zi shell",
    );
}

test "tech v1.10.9: PostgreSQL phonetic" {
    try runTech("usei PostgreSQL", "usei pós-ti-grês-quiu-el");
}

test "tech v1.10.9: SQLite branded entry beats CamelCase split" {
    try runTech("rodando SQLite", "rodando es-quiu-lai-ti");
}

test "tech v1.10.9: SurrealDB hits the brand entry" {
    try runTech("usei SurrealDB hoje", "usei surreal D B hoje");
}

test "tech v1.10.9: Mbps beats bps" {
    try runTech(
        "link de 100 Mbps",
        "link de cem megabits por segundo",
    );
}

test "tech v1.10.9: fps + dB + px + TB" {
    try runTech(
        "60 fps 80 dB 1024 px 2 TB",
        "sessenta quadros por segundo oitenta decibéis mil e vinte e quatro pixels dois terabytes",
    );
}

test "tech v1.10.9: NATS brand" {
    try runTech("via NATS", "via nats");
}

// ─── v1.10.9 CamelCase splitter ────────────────────────────────────────

fn runCamel(input: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try splitCamelCase(arena, input);
    testing.expectEqualStrings(expected, got) catch |e| {
        std.debug.print("\ninput:    {s}\nexpected: {s}\ngot:      {s}\n", .{ input, expected, got });
        return e;
    };
}

test "camel: SwiftUI preserves UI run" {
    // SwiftUI → "Swift UI". UI stays together so the SwiftUI glossary entry
    // (or downstream consumers) can still recognise "UI".
    try runCamel("SwiftUI", "Swift UI");
}

test "camel: MultiPiperEngine splits all three" {
    try runCamel("MultiPiperEngine", "Multi Piper Engine");
}

test "camel: getConditioningLatents lower→Upper transitions" {
    try runCamel("getConditioningLatents", "get Conditioning Latents");
}

test "camel: agentTTSMenubar — TTS run preserved" {
    try runCamel("agentTTSMenubar", "agent TTS Menubar");
}

test "camel: ChatGPT5 splits digit boundary" {
    try runCamel("ChatGPT5", "Chat GPT 5");
}

test "camel: SQLite ends the all-caps run before lowercase" {
    try runCamel("SQLite", "SQ Lite");
}

test "camel: all-caps run untouched" {
    try runCamel("SQL HTTPS TTS", "SQL HTTPS TTS");
}

test "camel: empty input" {
    try runCamel("", "");
}

test "camel: prose with no camel boundaries" {
    try runCamel("ola mundo", "ola mundo");
}

// ─── v1.10.9 identifier normalization ──────────────────────────────────

fn runNorm(input: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try normalizeIdentifiers(arena, input);
    testing.expectEqualStrings(expected, got) catch |e| {
        std.debug.print("\ninput:    {s}\nexpected: {s}\ngot:      {s}\n", .{ input, expected, got });
        return e;
    };
}

test "normalize: version 1.10.8 spelled" {
    try runNorm("versão 1.10.8 ok", "versão 1 ponto 10 ponto 8 ok");
}

test "normalize: leading-letter prefix v1.10.8 still rewritten" {
    // "v" is a word byte, so the version rule fires when the digit starts.
    // The normalizer inserts a separator so the cardinal stage still sees
    // the digits at word boundaries downstream.
    try runNorm("v1.10.8", "v 1 ponto 10 ponto 8");
}

test "normalize: commit hash bdd352e spelled" {
    try runNorm(
        "ver bdd352e agora",
        "ver commit bê dê dê três cinco dois é agora",
    );
}

test "normalize: URL strip protocol + replace . and /" {
    try runNorm(
        "https://github.com/biliboss/agent-tts",
        "github ponto com barra biliboss barra agent-tts",
    );
}

test "normalize: file path final component only" {
    try runNorm(
        "veja ~/.cache/ptah/voices/ aqui",
        "veja pasta voices aqui",
    );
}

test "normalize: hex literal 0xFF" {
    try runNorm("flag 0xFF set", "flag zero-x F F set");
}

test "normalize: untouched prose passes through" {
    try runNorm("nada para normalizar aqui", "nada para normalizar aqui");
}

test "normalize: plain integer is NOT a version" {
    // `2026` has no dot-group so the version rule must not fire.
    try runNorm("ano 2026", "ano 2026");
}

// ─── v1.10.9 full pipeline integration ─────────────────────────────────

test "techPipeline: version + hash + URL together" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try techPipeline(
        arena,
        "v1.10.8 em CPU. Commit bdd352e. Veja https://github.com/biliboss/agent-tts",
        .{},
    );
    // normalizeIdentifiers runs FIRST so the URL/version/commit-hash spans
    // are protected from glossary-1 catching `HTTPS` substring. Glossary-2
    // still fires on the URL tail (`ptah` → `agent-T T S`), which is
    // ear-acceptable.
    try testing.expectEqualStrings(
        "v um ponto dez ponto oito em C P U. Commit commit bê dê dê três cinco dois é. Veja github ponto com barra biliboss barra agent-T T S",
        got,
    );
}

// ─── v1.1 splitByLang tests ──────────────────────────────────────────────

fn runSplit(
    text: []const u8,
    expected: []const struct { text: []const u8, lang: detect.Lang },
) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try splitByLang(arena_state.allocator(), text, .pt);
    testing.expectEqual(expected.len, got.len) catch |e| {
        std.debug.print("\ninput: {s}\n", .{text});
        std.debug.print("expected {d} chunks, got {d}\n", .{ expected.len, got.len });
        for (got, 0..) |ch, i| {
            std.debug.print("  [{d}] lang={s} text={s}\n", .{ i, ch.lang.str(), ch.text });
        }
        return e;
    };
    for (got, expected, 0..) |ch, exp, idx| {
        testing.expectEqual(exp.lang, ch.lang) catch |e| {
            std.debug.print("\nchunk {d} lang mismatch: expected {s} got {s}\n", .{
                idx, exp.lang.str(), ch.lang.str(),
            });
            return e;
        };
        testing.expectEqualStrings(exp.text, ch.text) catch |e| {
            std.debug.print("\nchunk {d} text mismatch\n", .{idx});
            return e;
        };
    }
}

test "splitByLang empty returns empty" {
    try runSplit("", &.{});
}

test "splitByLang single Pt sentence is one chunk" {
    try runSplit("Olá, tudo bem?", &.{
        .{ .text = "Olá, tudo bem?", .lang = .pt },
    });
}

test "splitByLang Pt then En routes two chunks" {
    try runSplit("Deploy concluído. The build is green.", &.{
        .{ .text = "Deploy concluído.", .lang = .pt },
        .{ .text = "The build is green.", .lang = .en },
    });
}

test "splitByLang adjacent same-lang sentences coalesce" {
    try runSplit("Olá. Tudo bem. Como vai?", &.{
        .{ .text = "Olá. Tudo bem. Como vai?", .lang = .pt },
    });
}

test "splitByLang unknown sentence falls back to default" {
    // "xyz." has no stopwords on either side — defaults to .pt and
    // coalesces with the Pt neighbour.
    try runSplit("Olá. xyz. Tudo bem.", &.{
        .{ .text = "Olá. xyz. Tudo bem.", .lang = .pt },
    });
}

test "splitByLang trailing fragment without punctuation captured" {
    try runSplit("Olá mundo", &.{
        .{ .text = "Olá mundo", .lang = .pt },
    });
}

// ──────────────────────────────────────────────────────────────────────
// v1.2 chunking tests
// ──────────────────────────────────────────────────────────────────────

fn expectChunks(input: []const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try chunkSentences(arena, input);
    testing.expectEqual(expected.len, got.len) catch |e| {
        std.debug.print("\ninput: '{s}'\nexpected {d} chunks, got {d}:\n", .{ input, expected.len, got.len });
        for (got) |ch| std.debug.print("  '{s}'\n", .{ch.text});
        return e;
    };
    for (expected, got) |want, have| {
        testing.expectEqualStrings(want, have.text) catch |e| {
            std.debug.print("\ninput: '{s}'\n", .{input});
            return e;
        };
    }
}

test "chunk single sentence no terminator" {
    try expectChunks("Olá mundo", &.{"Olá mundo"});
}

test "chunk single sentence with period" {
    try expectChunks("Olá mundo.", &.{"Olá mundo."});
}

test "chunk multi sentence" {
    try expectChunks("Um. Dois. Três.", &.{ "Um.", "Dois.", "Três." });
}

test "chunk multi sentence mixed terminators" {
    try expectChunks("Vai? Vai! Vai.", &.{ "Vai?", "Vai!", "Vai." });
}

test "chunk trailing whitespace" {
    try expectChunks("Um.   Dois.  ", &.{ "Um.", "Dois." });
}

test "chunk newlines split" {
    try expectChunks("linha 1\nlinha 2", &.{ "linha 1", "linha 2" });
}

test "chunk only newlines yields empty" {
    try expectChunks("\n\n\n", &.{});
}

test "chunk empty input yields empty" {
    try expectChunks("", &.{});
}

test "chunk abbreviation Sr. does not split" {
    try expectChunks("Sr. Silva chegou. Boa tarde.", &.{ "Sr. Silva chegou.", "Boa tarde." });
}

test "chunk abbreviation Dr. Sra. Av. do not split" {
    try expectChunks(
        "Dr. Souza encontrou Sra. Lima na Av. Paulista.",
        &.{"Dr. Souza encontrou Sra. Lima na Av. Paulista."},
    );
}

test "chunk ellipsis collapses to one split" {
    try expectChunks("hmm... ok.", &.{ "hmm...", "ok." });
}

test "chunk newline after punctuation drops the newline" {
    try expectChunks("Um.\nDois.", &.{ "Um.", "Dois." });
}

test "chunk preserves combined punctuation" {
    try expectChunks("Sério?! Mesmo!?", &.{ "Sério?!", "Mesmo!?" });
}

// ──────────────────────────────────────────────────────────────────────
// v1.7 — incremental chunker (state machine)
// ──────────────────────────────────────────────────────────────────────
//
// `chunkSentences` is batch — input must be fully present. v1.7's streaming
// path (CLI `stream` subcommand + MCP `say_stream` tool) needs to feed bytes
// as they arrive and only emit a chunk when a sentence boundary fires. The
// remainder stays buffered for the next feed.
//
// Design:
//   - Caller owns an `IncrementalChunker` and a long-lived buffer arena.
//   - On `feed(arena, bytes) → []Chunk`, the chunker appends `bytes` to its
//     pending buffer, scans forward from the last scanned position, and emits
//     every completed sentence. Returned chunk `text` slices live in `arena`
//     (duped — the internal buffer may be compacted/reallocated on next feed).
//   - Abbreviation handling matches batch: a `.` that closes `Sr./Dr./Sra./
//     Dra./Av./cf./etc./vs.` is NOT a terminator.
//   - Trailing terminator runs (`!?`, `...`, `?\n`) collapse to one boundary,
//     same as batch — but the chunker only emits when the run ends, otherwise
//     stays in the run waiting for more bytes (you might be mid-ellipsis).
//   - `flush(arena) → []Chunk` emits the remaining buffered text as one chunk
//     (no terminator required). Use at end-of-stream (stdin EOF, `final=true`).
//
// Why a state machine and not "scan the whole buffer every time": we don't
// rescan already-classified bytes. The chunker keeps a `scan_idx` cursor so
// each input byte is touched O(1) amortized across all feeds.
//
// Why dup into arena vs hand out internal slices: the internal buffer compacts
// after each emit (drops the consumed prefix). A subsequent feed that grows
// the buffer can realloc, invalidating any outstanding slice. Duping costs
// one allocation per chunk — negligible vs the synth cost downstream.
//
// Corner cases the chunker accepts (same as batch):
//   - Decimals "3.14" split. Acceptable: preproc's number stage doesn't handle
//     decimals either, so callers reading numeric output are already losing.
//   - "Sr." mid-utterance does not split even when the buffer happens to end
//     on the dot — the chunker peeks one byte ahead and waits for confirmation
//     when it can't yet decide. See `feed`'s "ambiguous terminator" comment.

pub const IncrementalChunker = struct {
    /// All bytes received but not yet emitted as a chunk.
    buffer: std.ArrayList(u8) = .empty,
    /// First byte index we have NOT yet inspected for terminators. Reset to
    /// 0 after every emission (buffer compacts).
    scan_idx: usize = 0,

    pub fn deinit(self: *IncrementalChunker, arena: std.mem.Allocator) void {
        self.buffer.deinit(arena);
        self.scan_idx = 0;
    }

    /// Append `bytes` to the internal buffer, scan for boundaries, emit any
    /// completed chunks. Returns a freshly-allocated slice of Chunks; chunk
    /// `text` is duped into `arena`. Empty slice = no boundary yet.
    ///
    /// Emission policy: a chunk emits as soon as its terminator-run closes.
    /// "Closes" means either:
    ///   (a) the byte after the run is a non-terminator (run unambiguously
    ///       ended within this feed), or
    ///   (b) the run touches end-of-buffer (we cannot wait — the agent might
    ///       have stopped writing, and holding the chunk would defeat the
    ///       streaming UX). The chunk emits with the terminator chars seen
    ///       so far. A following feed that begins with more terminator chars
    ///       gets treated as the start of a new (empty-text) chunk, trimmed
    ///       on emit. This is the same trade-off Whisper / GPT streaming
    ///       chunkers make: prefer low-latency emission over perfectly
    ///       collapsing ellipses across packet boundaries.
    pub fn feed(
        self: *IncrementalChunker,
        arena: std.mem.Allocator,
        bytes: []const u8,
    ) ![]Chunk {
        var out: std.ArrayList(Chunk) = .empty;
        if (bytes.len == 0) return out.toOwnedSlice(arena);

        try self.buffer.appendSlice(arena, bytes);

        // Walk forward from scan_idx. Each iteration either advances over a
        // non-terminator or emits a chunk on a confirmed boundary.
        while (self.scan_idx < self.buffer.items.len) {
            const c = self.buffer.items[self.scan_idx];
            if (!isTerminator(c)) {
                self.scan_idx += 1;
                continue;
            }
            // Abbreviation guard mirrors batch. `.` that closes Sr./Dr./etc.
            // is NOT a terminator. The check needs no lookahead — the abbrev
            // src ends at this `.`, so all bytes are already buffered.
            if (c == '.' and isAbbrevDotAt(self.buffer.items, self.scan_idx)) {
                self.scan_idx += 1;
                continue;
            }

            // We are at a terminator. Walk the run to its end (within the
            // current buffer). j sits one past the last terminator byte or
            // at buffer.len if the run touches end-of-buffer.
            var j = self.scan_idx + 1;
            while (j < self.buffer.items.len and isTerminator(self.buffer.items[j])) : (j += 1) {}

            // `end_attached` = last non-newline byte of the run, inclusive.
            // Same shape as batch `chunkSentences`. We always emit when we
            // reach a terminator — see "Emission policy" doc comment above.
            var end_attached: usize = self.scan_idx;
            var has_punct = false;
            var k = self.scan_idx;
            while (k < j) : (k += 1) {
                if (self.buffer.items[k] != '\n') {
                    end_attached = k;
                    has_punct = true;
                }
            }
            const slice_end: usize = if (has_punct) end_attached + 1 else self.scan_idx;
            const raw_slice = self.buffer.items[0..slice_end];
            const trimmed = trimChunk(raw_slice);
            if (trimmed.len != 0) {
                const owned = try arena.dupe(u8, trimmed);
                try out.append(arena, .{ .text = owned, .lang = .unknown });
            }

            // Drop the consumed prefix (everything up to j). When j ==
            // buffer.len the buffer becomes empty and the outer while loop
            // exits.
            const remaining = self.buffer.items.len - j;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[j..]);
            }
            self.buffer.shrinkRetainingCapacity(remaining);
            self.scan_idx = 0;
        }

        return out.toOwnedSlice(arena);
    }

    /// End-of-stream: emit whatever remains as a single chunk (no terminator
    /// required). Resets the chunker to a reusable empty state.
    pub fn flush(
        self: *IncrementalChunker,
        arena: std.mem.Allocator,
    ) ![]Chunk {
        var out: std.ArrayList(Chunk) = .empty;
        const trimmed = trimChunk(self.buffer.items);
        if (trimmed.len != 0) {
            const owned = try arena.dupe(u8, trimmed);
            try out.append(arena, .{ .text = owned, .lang = .unknown });
        }
        self.buffer.clearRetainingCapacity();
        self.scan_idx = 0;
        return out.toOwnedSlice(arena);
    }
};

// ──────────────────────────────────────────────────────────────────────
// v1.7 incremental chunker tests
// ──────────────────────────────────────────────────────────────────────

test "incremental: single feed with terminator emits one chunk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var chunker: IncrementalChunker = .{};
    defer chunker.deinit(arena);

    const got = try chunker.feed(arena, "Hello.");
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("Hello.", got[0].text);
}

test "incremental: split across two feeds emits at boundary" {
    // Spec example: feed "Hello. Wor" then "ld." → 2 chunks "Hello." + "World."
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var chunker: IncrementalChunker = .{};
    defer chunker.deinit(arena);

    const first = try chunker.feed(arena, "Hello. Wor");
    try testing.expectEqual(@as(usize, 1), first.len);
    try testing.expectEqualStrings("Hello.", first[0].text);

    const second = try chunker.feed(arena, "ld.");
    try testing.expectEqual(@as(usize, 1), second.len);
    try testing.expectEqualStrings("World.", second[0].text);
}

test "incremental: no boundary yet returns empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var chunker: IncrementalChunker = .{};
    defer chunker.deinit(arena);

    const got = try chunker.feed(arena, "no terminator here");
    try testing.expectEqual(@as(usize, 0), got.len);

    const flushed = try chunker.flush(arena);
    try testing.expectEqual(@as(usize, 1), flushed.len);
    try testing.expectEqualStrings("no terminator here", flushed[0].text);
}

test "incremental: byte-by-byte feed assembles correctly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var chunker: IncrementalChunker = .{};
    defer chunker.deinit(arena);

    var total: std.ArrayList(Chunk) = .empty;
    defer total.deinit(arena);

    const text = "Um. Dois! Três?";
    for (text) |byte| {
        const slice = try chunker.feed(arena, &[_]u8{byte});
        for (slice) |c| try total.append(arena, c);
    }
    const tail = try chunker.flush(arena);
    for (tail) |c| try total.append(arena, c);

    try testing.expectEqual(@as(usize, 3), total.items.len);
    try testing.expectEqualStrings("Um.", total.items[0].text);
    try testing.expectEqualStrings("Dois!", total.items[1].text);
    try testing.expectEqualStrings("Três?", total.items[2].text);
}

test "incremental: ellipsis in a single feed emits one chunk" {
    // Eager-emit policy: a `.` followed by more `.`s emits at the end of the
    // run. Splitting an ellipsis across feeds is accepted as a known
    // trade-off (low-latency emission > collapsing trailing terminators
    // across packet boundaries).
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var chunker: IncrementalChunker = .{};
    defer chunker.deinit(arena);

    const got = try chunker.feed(arena, "hmm... ok.");
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("hmm...", got[0].text);
    try testing.expectEqualStrings("ok.", got[1].text);
}

test "incremental: abbreviation Sr. does not split mid-feed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var chunker: IncrementalChunker = .{};
    defer chunker.deinit(arena);

    const a = try chunker.feed(arena, "Sr. Silva chegou.");
    try testing.expectEqual(@as(usize, 1), a.len);
    try testing.expectEqualStrings("Sr. Silva chegou.", a[0].text);
}

test "incremental: newline is a terminator" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var chunker: IncrementalChunker = .{};
    defer chunker.deinit(arena);

    const a = try chunker.feed(arena, "linha 1\nlinha 2");
    // After "linha 1\n" → boundary fires when "l" of "linha 2" arrives.
    try testing.expectEqual(@as(usize, 1), a.len);
    try testing.expectEqualStrings("linha 1", a[0].text);
    const tail = try chunker.flush(arena);
    try testing.expectEqual(@as(usize, 1), tail.len);
    try testing.expectEqualStrings("linha 2", tail[0].text);
}

test "incremental: flush on empty buffer returns empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var chunker: IncrementalChunker = .{};
    defer chunker.deinit(arena);

    const got = try chunker.flush(arena);
    try testing.expectEqual(@as(usize, 0), got.len);
}

// ─── v1.10.12 cadence tricks ────────────────────────────────────────

test "cadence: list-end drop wraps last 3 words when sentence has 3+-item enum" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try applyCadenceTricks(
        arena,
        "Anthropic, Mistral, Groq e Ollama quatro LLM labs",
        .{ .enable_list_end_drop = true, .enable_bullet_lift = false, .enable_breathing = false },
    );
    // Expect last 3 tokens ("quatro LLM labs") wrapped.
    try testing.expect(std.mem.indexOf(u8, got, "<prosody pitch=\"-10%\" rate=\"slow\">") != null);
    try testing.expect(std.mem.indexOf(u8, got, "quatro LLM labs</prosody>") != null);
}

test "cadence: list-end drop skips sentences without enumerations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try applyCadenceTricks(
        arena,
        "Olá mundo simples sem vírgulas aqui",
        .{ .enable_list_end_drop = true, .enable_bullet_lift = false, .enable_breathing = false },
    );
    try testing.expectEqualStrings("Olá mundo simples sem vírgulas aqui", got);
}

test "cadence: bullet lift wraps label before colon" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try applyCadenceTricks(
        arena,
        "- Velocidade: 250 ms warm synth",
        .{ .enable_list_end_drop = false, .enable_bullet_lift = true, .enable_breathing = false },
    );
    try testing.expect(std.mem.indexOf(u8, got, "- <prosody pitch=\"+5%\">Velocidade</prosody>: 250 ms warm synth") != null);
}

test "cadence: bullet lift skips non-bullet lines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try applyCadenceTricks(
        arena,
        "linha normal sem bullet",
        .{ .enable_list_end_drop = false, .enable_bullet_lift = true, .enable_breathing = false },
    );
    try testing.expectEqualStrings("linha normal sem bullet", got);
}

test "cadence: breathing emits [[breath]] markers between sentences" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try applyCadenceTricks(
        arena,
        "Primeira sentença comprida aqui. Segunda também boa. Terceira que segue. Quarta vem aí.",
        .{ .enable_list_end_drop = false, .enable_bullet_lift = false, .enable_breathing = true },
    );
    try testing.expect(std.mem.indexOf(u8, got, "[[breath]]") != null);
    try testing.expect(std.mem.indexOf(u8, got, "<break time=\"80ms\"/>") != null);
}

test "cadence: breathing disabled by default does not insert markers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try applyCadenceTricks(
        arena,
        "Primeira. Segunda. Terceira. Quarta. Quinta.",
        .{ .enable_list_end_drop = false, .enable_bullet_lift = false, .enable_breathing = false },
    );
    try testing.expect(std.mem.indexOf(u8, got, "[[breath]]") == null);
}

test "cadence: empty input returns empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try applyCadenceTricks(arena, "", .{});
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "incremental: multiple sentences in one feed all emit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var chunker: IncrementalChunker = .{};
    defer chunker.deinit(arena);

    const got = try chunker.feed(arena, "One. Two. Three. Tail");
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("One.", got[0].text);
    try testing.expectEqualStrings("Two.", got[1].text);
    try testing.expectEqualStrings("Three.", got[2].text);

    const tail = try chunker.flush(arena);
    try testing.expectEqual(@as(usize, 1), tail.len);
    try testing.expectEqualStrings("Tail", tail[0].text);
}
