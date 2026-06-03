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
    // char32_t on every platform agent-tts targets.
    @cDefine("char32_t", "uint32_t");
    @cInclude("piper.h");
});

pub const Error = error{
    CreateFailed,
    SynthesizeStartFailed,
    SynthesizeNextFailed,
    WriteFailed,
};

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
        const text_z = arena.dupeZ(u8, text) catch return Error.SynthesizeStartFailed;
        defer arena.free(text_z);

        var opts: c.piper_synthesize_options = c.piper_default_synthesize_options(self.handle);

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
