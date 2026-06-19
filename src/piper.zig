// SPDX-License-Identifier: GPL-3.0-or-later
// Links libpiper (GPL-3.0); see /LICENSE for the dual-license boundary.
// PiperEngine — Zig wrapper around libpiper (OHF-Voice/piper1-gpl) via @cImport.
//
// v0.6 scope: prove the FFI works. Init loads voice + ONNX runtime + espeak-ng,
// synthToWav synthesizes a sentence and writes a PCM s16le WAV to disk.
//
// Lifecycle: Ghostty-style. PiperEngine.init takes the cold cost (voice model
// load, espeak-ng data parse). synthToWav reuses the loaded model — that's the
// whole point of the daemon-resident pattern in v0.7.
//
// Memory: arena-friendly — synthToWav uses a stack PCM buffer that grows via
// ArrayList(i16). No allocations survive synthToWav.

const std = @import("std");
const ssml_mod = @import("ssml.zig");

// piper.h pulls <uchar.h> which exposes char32_t in C++ but not all C compilers
// in C mode. Zig's translate-c sometimes fails to wire it; inject a shim so the
// public API translates cleanly. The actual type is uint_least32_t per the C++
// standard, which matches what libpiper.dylib emits.
const c = @cImport({
    @cDefine("__STDC_UTF_32__", "1");
    @cInclude("stdint.h");
    @cInclude("stddef.h");
    @cInclude("stdbool.h");
    // Define char32_t before piper.h sees it. uint32_t is ABI-compatible with
    // char32_t on every platform ptah targets.
    @cDefine("char32_t", "uint32_t");
    @cInclude("piper.h");
});

pub const Error = error{
    CreateFailed,
    SynthesizeStartFailed,
    SynthesizeNextFailed,
    WriteFailed,
    /// v1.8 — propagated when arena allocation inside `synthLangSSML`
    /// fails (token list traversal owns its own scratch).
    OutOfMemory,
};

/// v1.10.7 — getenv + parseFloat helper. Returns null when the env var is
/// missing OR fails to parse. Used by `synthToSamplesTuned` to honour
/// daemon-wide `PTAH_PIPER_*` overrides when the per-call sentinel
/// says "unset".
fn envFloat(name: [*:0]const u8) ?f32 {
    const stdlib = @cImport({
        @cInclude("stdlib.h");
    });
    const ptr = stdlib.getenv(name);
    if (ptr == null) return null;
    const s = std.mem.span(ptr);
    if (s.len == 0) return null;
    return std.fmt.parseFloat(f32, s) catch null;
}

pub const PiperEngine = struct {
    handle: *c.piper_synthesizer,
    voice_path: []const u8,
    espeak_data_path: []const u8,
    allocator: std.mem.Allocator,
    /// Cached sample rate (Hz). Voice config (`.onnx.json`) drives this; we
    /// populate it from the first synth chunk and keep it for v0.7's bench /
    /// zaudio init path. Faber-medium = 22050.
    cached_sample_rate: u32 = 22050,

    /// Load voice model from `voice_path` (path to .onnx file; .onnx.json
    /// must sit next to it). `espeak_data_path` points at the espeak-ng-data
    /// directory shipped with libpiper. Both paths are duped so the caller
    /// can free their copies.
    pub fn init(
        allocator: std.mem.Allocator,
        voice_path: []const u8,
        espeak_data_path: []const u8,
    ) Error!PiperEngine {
        // C requires null-terminated. Use temporary buffers via the allocator.
        const voice_z = allocator.dupeZ(u8, voice_path) catch return Error.CreateFailed;
        errdefer allocator.free(voice_z);
        const espeak_z = allocator.dupeZ(u8, espeak_data_path) catch return Error.CreateFailed;
        errdefer allocator.free(espeak_z);

        // config_path = NULL → libpiper appends ".json" to voice_path
        const handle = c.piper_create(voice_z.ptr, null, espeak_z.ptr) orelse {
            return Error.CreateFailed;
        };
        errdefer c.piper_free(handle);

        return .{
            .handle = handle,
            .voice_path = voice_z,
            .espeak_data_path = espeak_z,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PiperEngine) void {
        c.piper_free(self.handle);
        // dupeZ returns a slice with sentinel; free as slice
        self.allocator.free(@as([:0]u8, @ptrCast(@constCast(self.voice_path))));
        self.allocator.free(@as([:0]u8, @ptrCast(@constCast(self.espeak_data_path))));
    }

    /// Synthesize `text` into a 16-bit PCM mono WAV at `out_wav_path`.
    /// Sample rate is read from the first chunk returned by libpiper.
    pub fn synthToWav(
        self: *PiperEngine,
        io: std.Io,
        text: []const u8,
        out_wav_path: []const u8,
    ) !void {
        const samples = try self.synthToSamples(self.allocator, text);
        defer self.allocator.free(samples);

        try writeWav(io, out_wav_path, samples, self.cached_sample_rate);
    }

    /// Synthesize `text` into a heap-owned `[]i16` of PCM samples (mono,
    /// host-endian). Caller owns the returned slice and must free it via
    /// the same allocator. Sample rate available via `sampleRate()` after
    /// the call returns — libpiper publishes the rate on the first chunk
    /// and we cache it on `self.cached_sample_rate`.
    ///
    /// `arena` is the allocator used for the output. For v0.7 the daemon
    /// passes a per-utterance ArenaAllocator so memory is recycled cleanly.
    pub fn synthToSamples(
        self: *PiperEngine,
        arena: std.mem.Allocator,
        text: []const u8,
    ) Error![]i16 {
        return self.synthToSamplesScaled(arena, text, 1.0);
    }

    /// v1.8 — synth with an explicit `length_scale` multiplier (1.0 =
    /// default). 0.5 doubles speed; 2.0 halves it. Used by the SSML
    /// `<prosody rate>` walker to widen / shrink phoneme duration per
    /// chunk without rebuilding the synthesizer.
    ///
    /// v1.10.7 — thin shim over `synthToSamplesTuned` so existing call
    /// sites (SSML walker) keep their signature while the per-call knob
    /// path goes through one funnel. Passing `-1` for noise_scale/noise_w
    /// leaves them at the env-or-voice default.
    pub fn synthToSamplesScaled(
        self: *PiperEngine,
        arena: std.mem.Allocator,
        text: []const u8,
        length_scale: f32,
    ) Error![]i16 {
        return self.synthToSamplesTuned(arena, text, length_scale, -1.0, -1.0);
    }

    /// v1.10.7 — synth with all three Piper inference knobs explicit.
    /// Each `< 0` (or `length_scale == 0`) falls through to:
    ///   1. `PTAH_PIPER_LENGTH_SCALE` / `PTAH_PIPER_NOISE_SCALE`
    ///      / `PTAH_PIPER_NOISE_W` environment variables (parsed as
    ///      f32 once per call), then
    ///   2. libpiper's default (`piper_default_synthesize_options`).
    ///
    /// This precedence keeps the daemon-level env var workflow intact
    /// while letting any single ENQUEUE message override per call.
    pub fn synthToSamplesTuned(
        self: *PiperEngine,
        arena: std.mem.Allocator,
        text: []const u8,
        length_scale: f32,
        noise_scale: f32,
        noise_w: f32,
    ) Error![]i16 {
        return self.synthToSamplesTunedSpeaker(arena, text, length_scale, noise_scale, noise_w, -1);
    }

    /// v1.10.8 — synth with all four piper knobs explicit, including the
    /// multi-speaker selector. `speaker_id < 0` keeps the voice config
    /// default (single-speaker voices like Faber always use 0). Multi-
    /// speaker ONNX models (some VCTK exports) honour the integer index.
    pub fn synthToSamplesTunedSpeaker(
        self: *PiperEngine,
        arena: std.mem.Allocator,
        text: []const u8,
        length_scale: f32,
        noise_scale: f32,
        noise_w: f32,
        speaker_id: i32,
    ) Error![]i16 {
        const text_z = arena.dupeZ(u8, text) catch return Error.SynthesizeStartFailed;
        defer arena.free(text_z);

        var opts: c.piper_synthesize_options = c.piper_default_synthesize_options(self.handle);

        // Resolve length_scale: per-call > env > libpiper default.
        const ls = blk: {
            if (length_scale > 0) break :blk length_scale;
            if (envFloat("PTAH_PIPER_LENGTH_SCALE")) |v| break :blk v;
            break :blk @as(f32, -1.0); // sentinel meaning "don't override"
        };
        if (ls > 0) opts.length_scale = ls;

        const ns = blk: {
            if (noise_scale >= 0) break :blk noise_scale;
            if (envFloat("PTAH_PIPER_NOISE_SCALE")) |v| break :blk v;
            break :blk @as(f32, -1.0);
        };
        if (ns >= 0) opts.noise_scale = ns;

        const nw = blk: {
            if (noise_w >= 0) break :blk noise_w;
            if (envFloat("PTAH_PIPER_NOISE_W")) |v| break :blk v;
            break :blk @as(f32, -1.0);
        };
        // libpiper names the field `noise_w_scale`; the public API + docs
        // call it `noise_w`. We expose `noise_w` everywhere user-facing and
        // map to the C struct here.
        if (nw >= 0) opts.noise_w_scale = nw;

        // v1.10.8 — speaker_id override. The C struct field exists on every
        // piper build; setting it to a negative value would crash espeak-
        // ng's lookup, so we only assign when the caller passes ≥ 0.
        if (speaker_id >= 0) opts.speaker_id = @intCast(speaker_id);

        const rc_start = c.piper_synthesize_start(self.handle, text_z.ptr, &opts);
        if (rc_start != c.PIPER_OK) return Error.SynthesizeStartFailed;

        var samples: std.ArrayList(i16) = .empty;
        defer samples.deinit(arena);

        var chunk: c.piper_audio_chunk = std.mem.zeroes(c.piper_audio_chunk);

        while (true) {
            const rc = c.piper_synthesize_next(self.handle, &chunk);
            if (rc != c.PIPER_OK and rc != c.PIPER_DONE) {
                return Error.SynthesizeNextFailed;
            }

            if (chunk.sample_rate > 0) self.cached_sample_rate = @intCast(chunk.sample_rate);

            if (chunk.num_samples > 0 and chunk.samples != null) {
                samples.ensureUnusedCapacity(arena, chunk.num_samples) catch return Error.SynthesizeNextFailed;
                const src = chunk.samples[0..chunk.num_samples];
                for (src) |f| {
                    // libpiper emits floats in [-1, 1]. Clamp+scale to s16.
                    const clamped = std.math.clamp(f, -1.0, 1.0);
                    const scaled: i16 = @intFromFloat(clamped * 32767.0);
                    samples.appendAssumeCapacity(scaled);
                }
            }

            if (rc == c.PIPER_DONE) break;
            if (chunk.is_last) break;
        }

        return samples.toOwnedSlice(arena) catch return Error.SynthesizeNextFailed;
    }

    /// Cached sample rate from the most recent synth (or the voice default
    /// 22050 for faber-medium if nothing synthesized yet).
    pub fn sampleRate(self: *const PiperEngine) u32 {
        return self.cached_sample_rate;
    }
};

// ─── v1.1: MultiPiperEngine ──────────────────────────────────────────────
//
// Holds two PiperEngines — one Pt (Faber by default), one En (Amy by default)
// — and routes synth per chunk via `synthLang`. The En slot is optional:
// if it fails to load (no `en_US-amy-medium.onnx` on disk yet), the engine
// stays nullable and `synthLang(.en)` falls back to the Pt voice. v1.1
// ships the code paths even if the user hasn't run `scripts/fetch-voice-en.sh`
// yet.
//
// Lifetime: caller owns the storage; deinit cascades to both child engines.
// Memory: each child engine carries its own ONNX graph + espeak data —
// expect ~180 MB RSS with both loaded (Pt 90 MB + En 90 MB).
pub const MultiPiperEngine = struct {
    /// Per-chunk routing tag the worker passes to `synthLang`. Kept as a
    /// pub type so call sites (daemon.zig) can construct it explicitly
    /// instead of relying on inferred anonymous enums — Zig 0.16 treats
    /// every anonymous enum literal as a distinct type, which breaks the
    /// call signature.
    pub const Route = enum { pt, en };

    pt: PiperEngine,
    en: ?PiperEngine,
    allocator: std.mem.Allocator,

    /// Boot both voices. `pt_voice_path` must point at a working voice
    /// (failure is fatal — Pt is the default and can't be skipped).
    /// `en_voice_path` is optional; pass null to disable En routing
    /// entirely. Returns the multi-engine on success.
    pub fn initMulti(
        allocator: std.mem.Allocator,
        pt_voice_path: []const u8,
        en_voice_path: ?[]const u8,
        espeak_data_path: []const u8,
    ) Error!MultiPiperEngine {
        var pt_engine = try PiperEngine.init(allocator, pt_voice_path, espeak_data_path);
        errdefer pt_engine.deinit();

        var en_engine: ?PiperEngine = null;
        if (en_voice_path) |path| {
            en_engine = PiperEngine.init(allocator, path, espeak_data_path) catch null;
        }

        return .{
            .pt = pt_engine,
            .en = en_engine,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MultiPiperEngine) void {
        self.pt.deinit();
        if (self.en) |*en| en.deinit();
        self.en = null;
    }

    /// Synthesize `text` using the engine matching `lang`. `.pt` always
    /// routes to the Pt voice. `.en` routes to the En voice when loaded;
    /// otherwise falls back to Pt (with a one-line warn on stderr —
    /// callers swallow it). Any other value (`.auto`, `.mixed`,
    /// `.unknown`) routes to Pt as the safe default.
    pub fn synthLang(
        self: *MultiPiperEngine,
        arena: std.mem.Allocator,
        text: []const u8,
        lang: Route,
    ) Error![]i16 {
        return switch (lang) {
            .pt => self.pt.synthToSamples(arena, text),
            .en => if (self.en) |*en| en.synthToSamples(arena, text)
            else self.pt.synthToSamples(arena, text),
        };
    }

    /// v1.10.7 — synth with explicit per-call Piper inference knobs.
    /// Sentinel rules (any `< 0`, plus `length_scale == 0`) fall through
    /// to `PTAH_PIPER_*` env vars and then libpiper defaults. Worker
    /// passes the values straight off the popped queue row so a single
    /// ENQUEUE message can A/B different voices without restart.
    pub fn synthLangTuned(
        self: *MultiPiperEngine,
        arena: std.mem.Allocator,
        text: []const u8,
        lang: Route,
        length_scale: f32,
        noise_scale: f32,
        noise_w: f32,
    ) Error![]i16 {
        return self.synthLangTunedSpeaker(arena, text, lang, length_scale, noise_scale, noise_w, -1);
    }

    /// v1.10.8 — synth with explicit per-call Piper inference knobs AND
    /// a multi-speaker selector. `speaker_id < 0` keeps the voice config
    /// default. Faber/Amy are single-speaker so the field is a no-op for
    /// them; multi-speaker VCTK exports vary the timbre by integer index.
    pub fn synthLangTunedSpeaker(
        self: *MultiPiperEngine,
        arena: std.mem.Allocator,
        text: []const u8,
        lang: Route,
        length_scale: f32,
        noise_scale: f32,
        noise_w: f32,
        speaker_id: i32,
    ) Error![]i16 {
        return switch (lang) {
            .pt => self.pt.synthToSamplesTunedSpeaker(arena, text, length_scale, noise_scale, noise_w, speaker_id),
            .en => if (self.en) |*en|
                en.synthToSamplesTunedSpeaker(arena, text, length_scale, noise_scale, noise_w, speaker_id)
            else
                self.pt.synthToSamplesTunedSpeaker(arena, text, length_scale, noise_scale, noise_w, speaker_id),
        };
    }

    /// True iff the En voice loaded successfully. Used by the daemon to
    /// log the boot state and by the worker to decide whether to bother
    /// detecting English at all.
    pub fn hasEn(self: *const MultiPiperEngine) bool {
        return self.en != null;
    }

    /// Sample rate of the Pt engine. Faber-medium = 22050; Amy-medium =
    /// 22050 — same. zaudio resamples to device rate either way, so a
    /// single value works for the daemon's playback path. If we ever
    /// pair voices with different rates, surface this per-chunk instead.
    pub fn sampleRate(self: *const MultiPiperEngine) u32 {
        return self.pt.sampleRate();
    }

    /// v1.8 — walk an SSML token stream and emit a single concatenated
    /// PCM buffer. `<prosody rate>` adjusts `length_scale` for the
    /// duration of the scope; `<break>` inserts silence frames; text and
    /// unknown tags route through the standard synth path. `<say-as>` and
    /// `<emphasis>` are passed through as plain text in v1.8 — the Piper
    /// ONNX has no equivalent prosody knob beyond rate, so we honour what
    /// we can and skip the rest (documented in motor.md).
    ///
    /// `route` selects Pt / En. Output sample rate is the engine's
    /// cached rate (Faber/Amy both 22050). Caller owns the returned
    /// slice (`arena` allocation).
    pub fn synthLangSSML(
        self: *MultiPiperEngine,
        arena: std.mem.Allocator,
        tokens: []const ssml_mod.Token,
        route: Route,
    ) Error![]i16 {
        var out: std.ArrayList(i16) = .empty;
        try out.ensureTotalCapacity(arena, 0);

        // Active scope state. v1.8: single-level prosody — nested
        // `<prosody>` collapses to the inner scope until close, then
        // restores to outer. Implemented as a depth-1 stack since two
        // levels cover every agent output we've seen; deeper nesting
        // logs and ignores.
        var prosody_rate: f32 = 1.0;
        var prosody_depth: u32 = 0;
        var saved_rate: f32 = 1.0;

        // v1.10.12 — suppress body text inside <sub> and <phoneme>. The
        // alias / IPA passthrough already represents the spoken form; the
        // body text is the displayed form and must NOT also reach the
        // phonemizer (that would duplicate the brand name in the audio).
        var sub_depth: u32 = 0;
        var phoneme_depth: u32 = 0;

        // Accumulate text fragments and flush at scope boundaries / breaks.
        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(arena);

        for (tokens) |tok| {
            switch (tok) {
                .text => |t| {
                    // Drop body text inside <sub>…</sub> and <phoneme>…</phoneme>
                    // — the open handler already emitted the spoken form.
                    if (sub_depth == 0 and phoneme_depth == 0) {
                        try pending.appendSlice(arena, t);
                    }
                },
                .emphasis_open, .emphasis_close => {}, // best-effort: no Piper knob
                .sayas_open, .sayas_close => {},
                // v1.10.12 — `<phoneme alphabet="ipa" ph="X">body</phoneme>`.
                // libpiper's espeak-ng frontend accepts `[[X]]` Kirshenbaum-
                // style IPA brackets in the input text. We splice the bracket
                // form into the pending stream and suppress the body until
                // close. Worst case (espeak-ng doesn't recognise the IPA),
                // the bracketed form is treated as literal characters — not
                // ideal but no worse than dropping the tag.
                .phoneme_open => |p| {
                    if (p.ph.len > 0) {
                        try pending.append(arena, '[');
                        try pending.append(arena, '[');
                        try pending.appendSlice(arena, p.ph);
                        try pending.append(arena, ']');
                        try pending.append(arena, ']');
                    }
                    phoneme_depth += 1;
                },
                .phoneme_close => {
                    if (phoneme_depth > 0) phoneme_depth -= 1;
                },
                // v1.10.12 — `<sub alias="A">body</sub>`: emit alias, drop body.
                .sub_open => |s| {
                    try pending.appendSlice(arena, s.alias);
                    sub_depth += 1;
                },
                .sub_close => {
                    if (sub_depth > 0) sub_depth -= 1;
                },
                .@"break" => |b| {
                    // Flush pending text before inserting silence.
                    if (pending.items.len > 0) {
                        try self.appendSynth(arena, &out, pending.items, route, 1.0 / prosody_rate);
                        pending.clearRetainingCapacity();
                    }
                    if (b.ms > 0) {
                        const sr = self.sampleRate();
                        const num: usize = (@as(usize, sr) * b.ms) / 1000;
                        try out.appendNTimes(arena, 0, num);
                    }
                },
                .prosody_open => |p| {
                    if (pending.items.len > 0) {
                        try self.appendSynth(arena, &out, pending.items, route, 1.0 / prosody_rate);
                        pending.clearRetainingCapacity();
                    }
                    if (prosody_depth == 0) saved_rate = prosody_rate;
                    prosody_depth += 1;
                    if (p.rate) |r| prosody_rate = r;
                },
                .prosody_close => {
                    if (pending.items.len > 0) {
                        try self.appendSynth(arena, &out, pending.items, route, 1.0 / prosody_rate);
                        pending.clearRetainingCapacity();
                    }
                    if (prosody_depth > 0) prosody_depth -= 1;
                    if (prosody_depth == 0) prosody_rate = saved_rate;
                },
            }
        }
        if (pending.items.len > 0) {
            try self.appendSynth(arena, &out, pending.items, route, 1.0 / prosody_rate);
        }

        return out.toOwnedSlice(arena);
    }

    fn appendSynth(
        self: *MultiPiperEngine,
        arena: std.mem.Allocator,
        out: *std.ArrayList(i16),
        text: []const u8,
        route: Route,
        length_scale: f32,
    ) Error!void {
        // Skip whitespace-only fragments — Piper will start espeak-ng on
        // a blank string and emit a no-op chunk, but the empty C string
        // confuses the espeak-ng tokenizer in some voice configs.
        var has_text = false;
        for (text) |ch| if (!(ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r')) {
            has_text = true;
            break;
        };
        if (!has_text) return;

        const samples = switch (route) {
            .pt => try self.pt.synthToSamplesScaled(arena, text, length_scale),
            .en => if (self.en) |*en|
                try en.synthToSamplesScaled(arena, text, length_scale)
            else
                try self.pt.synthToSamplesScaled(arena, text, length_scale),
        };
        out.appendSlice(arena, samples) catch return Error.SynthesizeNextFailed;
    }
};

/// Minimal RIFF/WAVE writer — 16-bit PCM mono.
fn writeWav(io: std.Io, path: []const u8, samples: []const i16, sample_rate: u32) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    const num_channels: u16 = 1;
    const bits_per_sample: u16 = 16;
    const byte_rate: u32 = sample_rate * num_channels * (bits_per_sample / 8);
    const block_align: u16 = num_channels * (bits_per_sample / 8);
    const data_bytes: u32 = @intCast(samples.len * @sizeOf(i16));
    const riff_size: u32 = 36 + data_bytes;

    var header: [44]u8 = undefined;
    @memcpy(header[0..4], "RIFF");
    std.mem.writeInt(u32, header[4..8], riff_size, .little);
    @memcpy(header[8..12], "WAVE");
    @memcpy(header[12..16], "fmt ");
    std.mem.writeInt(u32, header[16..20], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, header[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, header[22..24], num_channels, .little);
    std.mem.writeInt(u32, header[24..28], sample_rate, .little);
    std.mem.writeInt(u32, header[28..32], byte_rate, .little);
    std.mem.writeInt(u16, header[32..34], block_align, .little);
    std.mem.writeInt(u16, header[34..36], bits_per_sample, .little);
    @memcpy(header[36..40], "data");
    std.mem.writeInt(u32, header[40..44], data_bytes, .little);

    try file.writeStreamingAll(io, &header);

    // i16 little-endian payload. On macOS arm64 (target), host is little-endian,
    // so a direct byte cast is safe. If we ever cross-compile to BE, fix here.
    const bytes: [*]const u8 = @ptrCast(samples.ptr);
    try file.writeStreamingAll(io, bytes[0 .. samples.len * @sizeOf(i16)]);
}
