// SPDX-License-Identifier: MIT OR Apache-2.0
// Kokoro native engine — Zig + ONNX Runtime C API + espeak-ng, no Python.
//
// Pipeline:
//   text → espeak-ng IPA (pt-br) → vocab tokens → [0, *tokens, 0] int64
//         + style = pf_dora[len(tokens)] float[256]
//         + speed float[1]
//         → ONNX Run → waveform float32 @24kHz → PCM i16
//
// Public entry-point:
//   KokoroEngine.init(io, allocator, model_path, voice_path, espeak_data_dir) → KokoroEngine
//   engine.synth(text, speed, out_allocator) → SynthResult
//   engine.deinit()
//
// v0.1 (standalone probe): no daemon/ipc integration yet.

const std = @import("std");

// ─── C imports ────────────────────────────────────────────────────────────────

const ort = @cImport({
    @cInclude("onnxruntime_c_api.h");
});

const esp = @cImport({
    @cInclude("espeak-ng/speak_lib.h");
});

// ─── Vocab table (114 entries from hexgrad/Kokoro-82M config.json) ────────────
//
// Generated from config.json `vocab` field (sorted by id).
// Lookup: iterate codepoints of IPA string; skip unmapped.

const VocabEntry = struct { cp: u21, id: i64 };

const VOCAB: []const VocabEntry = &.{
    .{ .cp = ';', .id = 1 },
    .{ .cp = ':', .id = 2 },
    .{ .cp = ',', .id = 3 },
    .{ .cp = '.', .id = 4 },
    .{ .cp = '!', .id = 5 },
    .{ .cp = '?', .id = 6 },
    .{ .cp = 0x2014, .id = 9 }, // '—' EM DASH
    .{ .cp = 0x2026, .id = 10 }, // '…' ELLIPSIS
    .{ .cp = 0x201C, .id = 11 }, // '"' LEFT DOUBLE QUOTATION
    .{ .cp = '(', .id = 12 },
    .{ .cp = ')', .id = 13 },
    .{ .cp = 0x201D, .id = 14 }, // '"' RIGHT DOUBLE QUOTATION
    .{ .cp = 0x201E, .id = 15 }, // '„' DOUBLE LOW-9 QUOTATION
    .{ .cp = ' ', .id = 16 },
    .{ .cp = 0x0303, .id = 17 }, // '̃' COMBINING TILDE
    .{ .cp = 0x02A3, .id = 18 }, // 'ʣ'
    .{ .cp = 0x02A5, .id = 19 }, // 'ʥ'
    .{ .cp = 0x02A6, .id = 20 }, // 'ʦ'
    .{ .cp = 0x02A8, .id = 21 }, // 'ʨ'
    .{ .cp = 0x1D5D, .id = 22 }, // 'ᵝ'
    .{ .cp = 0xAB67, .id = 23 }, // 'ꭧ'
    .{ .cp = 'A', .id = 24 },
    .{ .cp = 'I', .id = 25 },
    .{ .cp = 'O', .id = 31 },
    .{ .cp = 'Q', .id = 33 },
    .{ .cp = 'S', .id = 35 },
    .{ .cp = 'T', .id = 36 },
    .{ .cp = 'W', .id = 39 },
    .{ .cp = 'Y', .id = 41 },
    .{ .cp = 0x1D4A, .id = 42 }, // 'ᵊ'
    .{ .cp = 'a', .id = 43 },
    .{ .cp = 'b', .id = 44 },
    .{ .cp = 'c', .id = 45 },
    .{ .cp = 'd', .id = 46 },
    .{ .cp = 'e', .id = 47 },
    .{ .cp = 'f', .id = 48 },
    .{ .cp = 'h', .id = 50 },
    .{ .cp = 'i', .id = 51 },
    .{ .cp = 'j', .id = 52 },
    .{ .cp = 'k', .id = 53 },
    .{ .cp = 'l', .id = 54 },
    .{ .cp = 'm', .id = 55 },
    .{ .cp = 'n', .id = 56 },
    .{ .cp = 'o', .id = 57 },
    .{ .cp = 'p', .id = 58 },
    .{ .cp = 'q', .id = 59 },
    .{ .cp = 'r', .id = 60 },
    .{ .cp = 's', .id = 61 },
    .{ .cp = 't', .id = 62 },
    .{ .cp = 'u', .id = 63 },
    .{ .cp = 'v', .id = 64 },
    .{ .cp = 'w', .id = 65 },
    .{ .cp = 'x', .id = 66 },
    .{ .cp = 'y', .id = 67 },
    .{ .cp = 'z', .id = 68 },
    .{ .cp = 0x0251, .id = 69 }, // 'ɑ'
    .{ .cp = 0x0250, .id = 70 }, // 'ɐ'
    .{ .cp = 0x0252, .id = 71 }, // 'ɒ'
    .{ .cp = 0x00E6, .id = 72 }, // 'æ'
    .{ .cp = 0x03B2, .id = 75 }, // 'β'
    .{ .cp = 0x0254, .id = 76 }, // 'ɔ'
    .{ .cp = 0x0255, .id = 77 }, // 'ɕ'
    .{ .cp = 0x00E7, .id = 78 }, // 'ç'
    .{ .cp = 0x0256, .id = 80 }, // 'ɖ'
    .{ .cp = 0x00F0, .id = 81 }, // 'ð'
    .{ .cp = 0x02A4, .id = 82 }, // 'ʤ'
    .{ .cp = 0x0259, .id = 83 }, // 'ə'
    .{ .cp = 0x025A, .id = 85 }, // 'ɚ'
    .{ .cp = 0x025B, .id = 86 }, // 'ɛ'
    .{ .cp = 0x025C, .id = 87 }, // 'ɜ'
    .{ .cp = 0x025F, .id = 90 }, // 'ɟ'
    .{ .cp = 0x0261, .id = 92 }, // 'ɡ'
    .{ .cp = 0x0265, .id = 99 }, // 'ɥ'
    .{ .cp = 0x0268, .id = 101 }, // 'ɨ'
    .{ .cp = 0x026A, .id = 102 }, // 'ɪ'
    .{ .cp = 0x029D, .id = 103 }, // 'ʝ'
    .{ .cp = 0x026F, .id = 110 }, // 'ɯ'
    .{ .cp = 0x0270, .id = 111 }, // 'ɰ'
    .{ .cp = 0x014B, .id = 112 }, // 'ŋ'
    .{ .cp = 0x0273, .id = 113 }, // 'ɳ'
    .{ .cp = 0x0272, .id = 114 }, // 'ɲ'
    .{ .cp = 0x0274, .id = 115 }, // 'ɴ'
    .{ .cp = 0x00F8, .id = 116 }, // 'ø'
    .{ .cp = 0x0278, .id = 118 }, // 'ɸ'
    .{ .cp = 0x03B8, .id = 119 }, // 'θ'
    .{ .cp = 0x0153, .id = 120 }, // 'œ'
    .{ .cp = 0x0279, .id = 123 }, // 'ɹ'
    .{ .cp = 0x027E, .id = 125 }, // 'ɾ'
    .{ .cp = 0x027B, .id = 126 }, // 'ɻ'
    .{ .cp = 0x0281, .id = 128 }, // 'ʁ'
    .{ .cp = 0x027D, .id = 129 }, // 'ɽ'
    .{ .cp = 0x0282, .id = 130 }, // 'ʂ'
    .{ .cp = 0x0283, .id = 131 }, // 'ʃ'
    .{ .cp = 0x0288, .id = 132 }, // 'ʈ'
    .{ .cp = 0x02A7, .id = 133 }, // 'ʧ'
    .{ .cp = 0x028A, .id = 135 }, // 'ʊ'
    .{ .cp = 0x028B, .id = 136 }, // 'ʋ'
    .{ .cp = 0x028C, .id = 138 }, // 'ʌ'
    .{ .cp = 0x0263, .id = 139 }, // 'ɣ'
    .{ .cp = 0x0264, .id = 140 }, // 'ɤ'
    .{ .cp = 0x03C7, .id = 142 }, // 'χ'
    .{ .cp = 0x028E, .id = 143 }, // 'ʎ'
    .{ .cp = 0x0292, .id = 147 }, // 'ʒ'
    .{ .cp = 0x0294, .id = 148 }, // 'ʔ'
    .{ .cp = 0x02C8, .id = 156 }, // 'ˈ' PRIMARY STRESS
    .{ .cp = 0x02CC, .id = 157 }, // 'ˌ' SECONDARY STRESS
    .{ .cp = 0x02D0, .id = 158 }, // 'ː' LONG
    .{ .cp = 0x02B0, .id = 162 }, // 'ʰ'
    .{ .cp = 0x02B2, .id = 164 }, // 'ʲ'
    .{ .cp = 0x2193, .id = 169 }, // '↓'
    .{ .cp = 0x2192, .id = 171 }, // '→'
    .{ .cp = 0x2197, .id = 172 }, // '↗'
    .{ .cp = 0x2198, .id = 173 }, // '↘'
    .{ .cp = 0x1D7B, .id = 177 }, // 'ᵻ'
};

fn vocabLookup(cp: u21) ?i64 {
    for (VOCAB) |entry| {
        if (entry.cp == cp) return entry.id;
    }
    return null;
}

// ─── ORT helper ───────────────────────────────────────────────────────────────

fn checkOrt(api: *const ort.OrtApi, status: ?*ort.OrtStatus) !void {
    if (status) |s| {
        const msg = api.GetErrorMessage.?(s);
        std.debug.print("[ort error] {s}\n", .{msg});
        api.ReleaseStatus.?(s);
        return error.OrtError;
    }
}

// ─── WAV writer (s16le, mono, 24kHz) ─────────────────────────────────────────
// Uses std.Io (Zig 0.16 API). Caller passes io from std.process.Init.

pub fn writeWav(io: std.Io, path: []const u8, samples: []const i16, sample_rate: u32) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
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
    std.mem.writeInt(u32, header[16..20], 16, .little);
    std.mem.writeInt(u16, header[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, header[22..24], num_channels, .little);
    std.mem.writeInt(u32, header[24..28], sample_rate, .little);
    std.mem.writeInt(u32, header[28..32], byte_rate, .little);
    std.mem.writeInt(u16, header[32..34], block_align, .little);
    std.mem.writeInt(u16, header[34..36], bits_per_sample, .little);
    @memcpy(header[36..40], "data");
    std.mem.writeInt(u32, header[40..44], data_bytes, .little);

    try file.writeStreamingAll(io, &header);
    const bytes: [*]const u8 = @ptrCast(samples.ptr);
    try file.writeStreamingAll(io, bytes[0 .. samples.len * @sizeOf(i16)]);
}

// ─── KokoroEngine ─────────────────────────────────────────────────────────────

pub const KokoroEngine = struct {
    allocator: std.mem.Allocator,
    ort_env: *ort.OrtEnv,
    ort_session: *ort.OrtSession,
    ort_mem_info: *ort.OrtMemoryInfo,
    ort_api: *const ort.OrtApi,
    voice_data: []f32, // shape (N, 256) — all rows
    voice_rows: usize,

    pub const SAMPLE_RATE: u32 = 24000;
    pub const STYLE_DIM: usize = 256;

    /// Load model + voice, init espeak-ng.
    /// Caller must call deinit() when done.
    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        model_path: [:0]const u8,
        voice_path: [:0]const u8,
        espeak_data_dir: [:0]const u8,
    ) !KokoroEngine {
        // ── espeak-ng ──────────────────────────────────────────────────────────
        const sr = esp.espeak_Initialize(
            esp.AUDIO_OUTPUT_SYNCHRONOUS,
            0,
            espeak_data_dir.ptr,
            0,
        );
        if (sr < 0) {
            std.debug.print("[kokoro] espeak_Initialize failed: {d}\n", .{sr});
            return error.EspeakInitFailed;
        }

        const voice_err = esp.espeak_SetVoiceByName("pt-br");
        if (voice_err != esp.EE_OK) {
            std.debug.print("[kokoro] espeak_SetVoiceByName(pt-br) failed: {d}\n", .{voice_err});
            return error.EspeakVoiceFailed;
        }

        // ── ONNX Runtime ───────────────────────────────────────────────────────
        // OrtGetApiBase() returns ?[*c]const OrtApiBase in Zig's C translation.
        // GetApi() returns ?[*c]const OrtApi — @ptrCast to *const OrtApi for field access.
        const api_base_raw = ort.OrtGetApiBase();
        if (api_base_raw == null) return error.OrtApiBaseNull;
        const api_base: *const ort.OrtApiBase = @ptrCast(api_base_raw.?);
        const ort_api_raw = api_base.GetApi.?(ort.ORT_API_VERSION);
        if (ort_api_raw == null) return error.OrtApiNull;
        const api: *const ort.OrtApi = @ptrCast(ort_api_raw.?);

        var env: ?*ort.OrtEnv = null;
        try checkOrt(api, api.CreateEnv.?(ort.ORT_LOGGING_LEVEL_WARNING, "ptah-kokoro", &env));

        var sess_opts: ?*ort.OrtSessionOptions = null;
        try checkOrt(api, api.CreateSessionOptions.?(&sess_opts));
        // 0 = let ORT choose thread count (uses all cores). Single-threaded (1)
        // was tried and produced RTF > 1.0; 0 matches Python's default behavior.
        try checkOrt(api, api.SetIntraOpNumThreads.?(sess_opts.?, 0));

        var session: ?*ort.OrtSession = null;
        try checkOrt(api, api.CreateSession.?(env.?, model_path.ptr, sess_opts.?, &session));
        api.ReleaseSessionOptions.?(sess_opts.?);

        var mem_info: ?*ort.OrtMemoryInfo = null;
        try checkOrt(api, api.CreateMemoryInfo.?(
            "Cpu",
            ort.OrtArenaAllocator,
            0,
            ort.OrtMemTypeDefault,
            &mem_info,
        ));

        // ── Voice data (.bin = float32, shape (N, 256)) ────────────────────────
        // voice_path is absolute ([:0]const u8). Use Dir.cwd().openFileAbsolute
        // (the Dir method, not the free function) and read positionally.
        var voice_file = try std.Io.Dir.openFileAbsolute(io, voice_path, .{});
        defer voice_file.close(io);

        const voice_stat = try voice_file.stat(io);
        const voice_size: usize = @intCast(voice_stat.size);
        const voice_bytes = try allocator.alloc(u8, voice_size);
        defer allocator.free(voice_bytes);

        // readPositionalAll reads from the file at offset 0.
        const bytes_read = try voice_file.readPositionalAll(io, voice_bytes, 0);
        if (bytes_read != voice_size) return error.VoiceReadIncomplete;

        const n_floats = voice_size / 4;
        const voice_data = try allocator.alloc(f32, n_floats);
        @memcpy(std.mem.sliceAsBytes(voice_data), voice_bytes);

        const voice_rows = n_floats / STYLE_DIM;

        return KokoroEngine{
            .allocator = allocator,
            .ort_env = env.?,
            .ort_session = session.?,
            .ort_mem_info = mem_info.?,
            .ort_api = api,
            .voice_data = voice_data,
            .voice_rows = voice_rows,
        };
    }

    pub fn deinit(self: *KokoroEngine) void {
        self.ort_api.ReleaseMemoryInfo.?(self.ort_mem_info);
        self.ort_api.ReleaseSession.?(self.ort_session);
        self.ort_api.ReleaseEnv.?(self.ort_env);
        self.allocator.free(self.voice_data);
    }

    pub const SynthResult = struct {
        pcm: []i16,
        ipa: []u8,
        tokens: []i64,
        duration_s: f64,
        infer_s: f64,
    };

    /// Phonemize `text` via espeak-ng (pt-br), tokenize, run ONNX.
    /// Returns SynthResult; all slices owned by `out_allocator`. Caller frees.
    pub fn synth(
        self: *KokoroEngine,
        text: []const u8,
        speed: f32,
        out_allocator: std.mem.Allocator,
    ) !SynthResult {
        // ── 1. Phonemize ──────────────────────────────────────────────────────
        const text_z = try out_allocator.dupeZ(u8, text);
        defer out_allocator.free(text_z);

        // Zig 0.16 ArrayList: `.empty` init, allocator passed at call site.
        var ipa_buf: std.ArrayList(u8) = .empty;
        defer ipa_buf.deinit(out_allocator);

        // espeak_TextToPhonemes may split at punctuation boundaries (e.g. commas).
        // Join chunks with a space so "olˈa" + "eʊ..." → "olˈa eʊ..." (matches Python oracle).
        const text_base = @intFromPtr(text_z.ptr);
        var textptr: ?*const anyopaque = @ptrCast(text_z.ptr);
        var first_chunk = true;
        while (textptr != null) {
            const start_off = @intFromPtr(textptr.?) - text_base;
            const phoneme_cstr = esp.espeak_TextToPhonemes(
                @ptrCast(&textptr),
                1, // UTF-8
                0x02, // IPA mode
            );
            const end_off = if (textptr) |tp| @intFromPtr(tp) - text_base else text_z.len;
            if (phoneme_cstr) |p| {
                const phoneme_slice = std.mem.sliceTo(p, 0);
                if (phoneme_slice.len == 0) continue;
                if (!first_chunk) {
                    // Add separator space between chunks (mirrors how the Python
                    // tokenizer joins espeak output across punctuation boundaries).
                    try ipa_buf.append(out_allocator, ' ');
                }
                try ipa_buf.appendSlice(out_allocator, phoneme_slice);
                first_chunk = false;
                // espeak consumes the clause terminator (,.!?;:) as a split
                // boundary and drops it from the IPA. Python's phonemizer keeps
                // it (preserve_punctuation) → tokenizes to a pause/intonation id.
                // Re-insert it by scanning the consumed source span backwards.
                const hi = @min(end_off, text_z.len);
                var pi = hi;
                while (pi > start_off) {
                    pi -= 1;
                    const b = text_z[pi];
                    if (b == ';' or b == ':' or b == ',' or b == '.' or b == '!' or b == '?') {
                        try ipa_buf.append(out_allocator, b);
                        break;
                    }
                }
            }
        }

        const ipa_owned = try out_allocator.dupe(u8, ipa_buf.items);

        // ── 2. Tokenize ───────────────────────────────────────────────────────
        var tokens: std.ArrayList(i64) = .empty;
        defer tokens.deinit(out_allocator);

        var it = std.unicode.Utf8Iterator{ .bytes = ipa_owned, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            if (vocabLookup(cp)) |id| {
                try tokens.append(out_allocator, id);
            }
        }

        const token_ids_raw = try tokens.toOwnedSlice(out_allocator);

        // ── 3. Build input_ids = [0, *tokens, 0] ─────────────────────────────
        const L = token_ids_raw.len + 2;
        const input_ids = try out_allocator.alloc(i64, L);
        defer out_allocator.free(input_ids);
        input_ids[0] = 0;
        @memcpy(input_ids[1 .. L - 1], token_ids_raw);
        input_ids[L - 1] = 0;

        // ── 4. Style row: voice[len(tokens)] ─────────────────────────────────
        const style_row = token_ids_raw.len;
        if (style_row >= self.voice_rows) {
            std.debug.print("[kokoro] style_row {d} >= voice_rows {d}\n", .{ style_row, self.voice_rows });
            return error.StyleRowOutOfRange;
        }
        var style_data: [STYLE_DIM]f32 = undefined;
        @memcpy(&style_data, self.voice_data[style_row * STYLE_DIM .. (style_row + 1) * STYLE_DIM]);

        var speed_data: [1]f32 = .{speed};

        // ── 5. ONNX Run ───────────────────────────────────────────────────────
        const api = self.ort_api;

        var ids_shape: [2]i64 = .{ 1, @intCast(L) };
        var ids_value: ?*ort.OrtValue = null;
        try checkOrt(api, api.CreateTensorWithDataAsOrtValue.?(
            self.ort_mem_info,
            @ptrCast(input_ids.ptr),
            L * @sizeOf(i64),
            &ids_shape,
            2,
            ort.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64,
            &ids_value,
        ));
        defer api.ReleaseValue.?(ids_value.?);

        var style_shape: [2]i64 = .{ 1, STYLE_DIM };
        var style_value: ?*ort.OrtValue = null;
        try checkOrt(api, api.CreateTensorWithDataAsOrtValue.?(
            self.ort_mem_info,
            @ptrCast(&style_data),
            STYLE_DIM * @sizeOf(f32),
            &style_shape,
            2,
            ort.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
            &style_value,
        ));
        defer api.ReleaseValue.?(style_value.?);

        var speed_shape: [1]i64 = .{1};
        var speed_value: ?*ort.OrtValue = null;
        try checkOrt(api, api.CreateTensorWithDataAsOrtValue.?(
            self.ort_mem_info,
            @ptrCast(&speed_data),
            @sizeOf(f32),
            &speed_shape,
            1,
            ort.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
            &speed_value,
        ));
        defer api.ReleaseValue.?(speed_value.?);

        const input_names = [_][*:0]const u8{ "input_ids", "style", "speed" };
        const output_names = [_][*:0]const u8{"waveform"};
        const input_values = [_]?*ort.OrtValue{ ids_value, style_value, speed_value };
        var output_values = [_]?*ort.OrtValue{null};

        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        const t_start_ns = @as(i64, ts.sec) * 1_000_000_000 + ts.nsec;

        try checkOrt(api, api.Run.?(
            self.ort_session,
            null,
            @ptrCast(&input_names[0]),
            @ptrCast(&input_values[0]),
            3,
            @ptrCast(&output_names[0]),
            1,
            @ptrCast(&output_values[0]),
        ));

        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        const t_end_ns = @as(i64, ts.sec) * 1_000_000_000 + ts.nsec;
        const infer_s = @as(f64, @floatFromInt(t_end_ns - t_start_ns)) / 1e9;

        defer api.ReleaseValue.?(output_values[0].?);

        // ── 6. Extract waveform ───────────────────────────────────────────────
        var shape_info: ?*ort.OrtTensorTypeAndShapeInfo = null;
        try checkOrt(api, api.GetTensorTypeAndShape.?(output_values[0].?, &shape_info));
        defer api.ReleaseTensorTypeAndShapeInfo.?(shape_info.?);

        var n_samples: usize = 0;
        try checkOrt(api, api.GetTensorShapeElementCount.?(shape_info.?, &n_samples));

        var raw_ptr: ?*anyopaque = null;
        try checkOrt(api, api.GetTensorMutableData.?(output_values[0].?, &raw_ptr));

        const float_ptr: [*]f32 = @alignCast(@ptrCast(raw_ptr.?));
        const waveform = float_ptr[0..n_samples];

        // ── 7. Convert f32 → i16 ─────────────────────────────────────────────
        const pcm = try out_allocator.alloc(i16, n_samples);
        for (waveform, 0..) |sample, i| {
            const clamped = std.math.clamp(sample, -1.0, 1.0);
            pcm[i] = @intFromFloat(clamped * 32767.0);
        }

        const duration_s = @as(f64, @floatFromInt(n_samples)) / @as(f64, @floatFromInt(SAMPLE_RATE));

        return SynthResult{
            .pcm = pcm,
            .ipa = ipa_owned,
            .tokens = token_ids_raw,
            .duration_s = duration_s,
            .infer_s = infer_s,
        };
    }
};
