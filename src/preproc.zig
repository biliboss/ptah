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
    if (raw.len == 0) return arena.alloc(u8, 0);

    const after_abbrev = try expandAbbreviations(arena, raw);
    const after_numbers = try expandNumbers(arena, after_abbrev);
    const after_pauses = try insertPauses(arena, after_numbers);
    return after_pauses;
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

fn pauseMsFor(c: u8) ?u32 {
    return switch (c) {
        ',' => Pause.COMMA_MS,
        '.', '!', '?' => Pause.SENTENCE_MS,
        '\n' => Pause.NEWLINE_MS,
        else => null,
    };
}

fn isRunByte(c: u8) bool {
    return c == ',' or c == '.' or c == '!' or c == '?' or
        c == '\n' or c == ' ' or c == '\t';
}

fn insertPauses(arena: std.mem.Allocator, input: []const u8) ![]u8 {
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
                if (pauseMsFor(ch)) |p| {
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
