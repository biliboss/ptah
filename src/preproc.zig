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
