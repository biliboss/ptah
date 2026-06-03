// SPDX-License-Identifier: MIT OR Apache-2.0
// Language detector. v1.1.
//
// Lowercase-tokenize the input, look each token up in two tiny stopword sets
// (top ~50 Pt + top ~50 En). Score = stopword hits per language. The result
// is `pt` / `en` / `mixed` / `unknown`.
//
// Heuristic, sub-µs on M-class silicon, deterministic, no allocations beyond
// a transient lowercase buffer. Built for the v1.1 code-switch routing — the
// daemon dispatches each chunk to the matching Piper voice.
//
// Rules:
//   - Both counts zero        → unknown (caller treats as default = pt)
//   - One side ≥ 3× the other → that side wins outright
//   - Both sides ≥ 15% of all tokens → mixed
//   - Otherwise the larger side wins (ties → pt; Brazilian dev bias)

const std = @import("std");

pub const Lang = enum {
    pt,
    en,
    mixed,
    unknown,

    pub fn fromStr(s: []const u8) ?Lang {
        if (std.mem.eql(u8, s, "pt")) return .pt;
        if (std.mem.eql(u8, s, "en")) return .en;
        if (std.mem.eql(u8, s, "mixed")) return .mixed;
        if (std.mem.eql(u8, s, "unknown")) return .unknown;
        return null;
    }

    pub fn str(l: Lang) []const u8 {
        return @tagName(l);
    }
};

// Pt-BR top stopwords. Includes diacritics (é, não, são) because we keep
// UTF-8 bytes intact when lowercasing — the comparison is byte-exact.
const PT_STOPWORDS = [_][]const u8{
    "a",      "o",     "as",   "os",    "um",    "uma",   "uns",  "umas",
    "de",     "do",    "da",   "dos",   "das",   "no",    "na",   "nos",
    "nas",    "em",    "por",  "para",  "com",   "sem",   "sobre","entre",
    "e",      "ou",    "mas",  "se",    "que",   "como",  "quando","onde",
    "porque", "isso",  "isto", "aquele","aquela","aqui",  "ali",   "lá",
    "muito",  "pouco", "mais", "menos", "também","já",    "ainda", "sempre",
    "nunca",  "sim",   "não",  "é",     "são",   "foi",   "era",   "está",
    "estão",  "tem",   "ter",  "ser",   "estar", "fazer", "vai",   "vou",
    "eu",     "você",  "ele",  "ela",   "nós",   "eles",  "elas",  "meu",
    "minha",  "seu",   "sua",  "deve",  "pode",  "agora", "depois","antes",
    "então",  "assim", "bem",  "mal",   "bom",   "boa",   "todo",  "toda",
    "todos",  "todas", "ção",  "ções",
};

// En top stopwords. Function words + auxiliaries — they show up in any
// remotely English fragment.
const EN_STOPWORDS = [_][]const u8{
    "the",   "a",      "an",    "of",    "in",     "on",    "at",    "by",
    "for",   "with",   "from",  "to",    "into",   "about", "as",    "is",
    "are",   "was",    "were",  "be",    "been",   "being", "have",  "has",
    "had",   "do",     "does",  "did",   "will",   "would", "should","could",
    "can",   "may",    "might", "must",  "shall",  "and",   "or",    "but",
    "if",    "then",   "than",  "that",  "this",   "these", "those", "there",
    "here",  "what",   "when",  "where", "which",  "who",   "whom",  "how",
    "why",   "not",    "no",    "yes",   "you",    "your",  "yours", "i",
    "we",    "they",   "he",    "she",   "it",     "my",    "me",    "our",
    "their", "his",    "her",   "its",   "them",   "us",    "so",    "very",
    "just",  "also",   "only",  "any",   "all",    "some",  "most",  "many",
    "much",  "more",   "less",  "now",   "then",   "well",  "ok",    "okay",
    "yeah",  "really", "github","actions","build", "deploy","commit","merge",
};

// English-only diagnostic suffix bigrams hinted in long words. Empty for
// now — adding domain bigrams ("ing", "tion") risks tagging Pt cognates.
// Stopword frequency carries the signal.

/// Token-isolate a `[]const u8`. We treat ASCII alphanumerics + UTF-8
/// continuation bytes (≥ 0x80) as word bytes. Everything else is a boundary.
/// A token is a maximal run of word bytes.
fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// Lowercase a single ASCII byte; pass UTF-8 continuation bytes through.
/// The stopword tables are ASCII-lowercase + the handful of accented words
/// that already appear lowercase ("é", "não"). This keeps the matcher
/// O(N) in input length with no locale handling.
fn asciiLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn inSet(token: []const u8, set: []const []const u8) bool {
    // Linear scan. ~50 entries × ~5 bytes = ~250 byte compares worst case
    // per token. Comfortably sub-µs for short messages — the kind agents
    // send to TTS. A perfect-hash or sorted-binary-search optimization
    // waits until profiling proves it matters.
    for (set) |w| {
        if (token.len != w.len) continue;
        if (std.mem.eql(u8, token, w)) return true;
    }
    return false;
}

/// Stateless detector. Allocates one scratch buffer of length `text.len`
/// from `arena` for the lowercase pass and frees nothing — caller's arena
/// owns the memory. Returns the language judgement; never errors aside
/// from OOM on the arena allocation.
pub fn detect(arena: std.mem.Allocator, text: []const u8) !Lang {
    if (text.len == 0) return .unknown;

    // Lowercase ASCII into a scratch buffer; preserve non-ASCII bytes as-is.
    const lower = try arena.alloc(u8, text.len);
    for (text, 0..) |c, i| lower[i] = asciiLower(c);

    var pt_hits: u32 = 0;
    var en_hits: u32 = 0;
    var total: u32 = 0;

    var i: usize = 0;
    while (i < lower.len) {
        // Skip boundaries.
        while (i < lower.len and !isWordByte(lower[i])) : (i += 1) {}
        if (i >= lower.len) break;

        const start = i;
        while (i < lower.len and isWordByte(lower[i])) : (i += 1) {}
        const tok = lower[start..i];

        total += 1;
        // A token might score for both sides ("a", "do", "no" are stopwords
        // in both languages). That's the point of the mixed-zone math
        // downstream — small symmetric noise floor.
        if (inSet(tok, &PT_STOPWORDS)) pt_hits += 1;
        if (inSet(tok, &EN_STOPWORDS)) en_hits += 1;
    }

    if (total == 0) return .unknown;
    if (pt_hits == 0 and en_hits == 0) return .unknown;

    // Short-fragment guard. Tiny inputs ("the", "isso", "a", "Deploy
    // concluído.") need rules that don't overreact to a single hit.
    //   - Pure dominance (one side at 0) AND winning side ≥ 50 % of
    //     tokens → that side. Covers single-word stopwords ("the" →
    //     en, "isso" → pt). "Deploy concluído." → en=1/2 = 50 % BUT
    //     "deploy" is the only signal AND it's a Pt loanword; we still
    //     need the 50 % AND winning-hits ≥ majority-of-tokens check.
    //   - Below the threshold → .pt (Brazilian default bias).
    if (total < 3) {
        const half = (total + 1) / 2;
        if (en_hits == 0 and pt_hits >= half) return .pt;
        if (pt_hits == 0 and en_hits >= total) return .en;
        return .pt;
    }

    // Mixed rule needs symmetric strength: both sides ≥ 2 hits AND each
    // ≥ 25 % of total tokens. Below either floor, pick the leader. The
    // old 15 % floor + 1-hit threshold flagged Pt sentences with a
    // single English borrow as `mixed`; the new floor keeps "Vou rodar
    // o build agora mesmo" on the Pt side.
    if (pt_hits >= 2 and en_hits >= 2) {
        const total_f: f64 = @floatFromInt(total);
        const pt_ratio = @as(f64, @floatFromInt(pt_hits)) / total_f;
        const en_ratio = @as(f64, @floatFromInt(en_hits)) / total_f;
        if (pt_ratio >= 0.25 and en_ratio >= 0.25) return .mixed;
    }

    // Otherwise pick the heavier side. Tie → pt (Brazilian dev default;
    // EN-leaning users force with `--lang en`).
    if (en_hits > pt_hits) return .en;
    return .pt;
}

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;

fn runDetect(text: []const u8, expected: Lang) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try detect(arena_state.allocator(), text);
    testing.expectEqual(expected, got) catch |e| {
        std.debug.print("\ninput:    \"{s}\"\nexpected: {s}\ngot:      {s}\n", .{
            text, expected.str(), got.str(),
        });
        return e;
    };
}

test "empty string is unknown" {
    try runDetect("", .unknown);
}

test "pure Pt-BR sentence" {
    try runDetect("Olá, como você está hoje? Espero que tudo bem.", .pt);
}

test "pure English sentence" {
    try runDetect("The build is broken because the deploy step failed.", .en);
}

test "mixed Pt + En triggers mixed" {
    // Half the stopwords land in each side; the 15% floor catches it.
    try runDetect(
        "Vou fazer deploy no GitHub Actions depois que o build terminar",
        .mixed,
    );
}

test "gibberish without stopwords is unknown" {
    try runDetect("xyz qwerty zzz vvv 12345", .unknown);
}

test "single Pt stopword still scores" {
    try runDetect("isso", .pt);
}

test "single En stopword still scores" {
    try runDetect("the", .en);
}

test "Pt sentence with one English noun stays Pt" {
    // "build" is in EN_STOPWORDS; one hit shouldn't flip a Pt sentence.
    try runDetect("Vou rodar o build agora mesmo", .pt);
}

test "En sentence with one Pt borrow stays En" {
    try runDetect("The samba code is in the repo", .en);
}

test "tie defaults to pt" {
    // "a" hits both sides; nothing else does.
    try runDetect("a", .pt);
}

test "fromStr round trip" {
    try testing.expectEqual(Lang.pt, Lang.fromStr("pt").?);
    try testing.expectEqual(Lang.en, Lang.fromStr("en").?);
    try testing.expectEqual(Lang.mixed, Lang.fromStr("mixed").?);
    try testing.expectEqual(Lang.unknown, Lang.fromStr("unknown").?);
    try testing.expect(Lang.fromStr("fr") == null);
}
