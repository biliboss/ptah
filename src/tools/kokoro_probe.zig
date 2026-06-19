// SPDX-License-Identifier: MIT OR Apache-2.0
// Standalone probe for the Kokoro native engine.
//
// Usage:
//   zig build kokoro-probe   (from repo root)
//   ./zig-out/bin/kokoro-probe
//
// Defaults: model=<cwd>/assets/kokoro-v1.0.onnx, voice=<cwd>/assets/pf_dora.bin
// Override via env: KOKORO_MODEL, KOKORO_VOICE, ESPEAK_DATA_PATH
//
// Synthesizes "Olá, eu sou a Dora." and plays it via afplay.

const std = @import("std");
const kokoro = @import("kokoro");

const TEST_PHRASE = "Olá, eu sou a Dora.";
const SPEED: f32 = 1.15;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const gpa = init.gpa;

    // Resolve paths: env-overridable, fallback to cwd-relative defaults.
    // Use init.environ_map (Zig 0.16 env access).
    const env_map = init.environ_map;

    // Get cwd to construct default asset paths.
    var cwd_buf: [4096]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
    const cwd_slice = std.mem.sliceTo(cwd_ptr, 0);

    const model_path: [:0]const u8 = if (env_map.get("KOKORO_MODEL")) |p|
        try arena.dupeZ(u8, p)
    else
        try std.fmt.allocPrintSentinel(arena, "{s}/assets/kokoro-v1.0.onnx", .{cwd_slice}, 0);

    const voice_path: [:0]const u8 = if (env_map.get("KOKORO_VOICE")) |p|
        try arena.dupeZ(u8, p)
    else
        try std.fmt.allocPrintSentinel(arena, "{s}/assets/pf_dora.bin", .{cwd_slice}, 0);

    // espeak-ng data dir: ESPEAK_DATA_PATH must be parent of espeak-ng-data/
    const espeak_dir: [:0]const u8 = if (env_map.get("ESPEAK_DATA_PATH")) |p|
        try arena.dupeZ(u8, p)
    else
        "/opt/homebrew/opt/espeak-ng/share";

    std.debug.print("[kokoro-probe] model:  {s}\n", .{model_path});
    std.debug.print("[kokoro-probe] voice:  {s}\n", .{voice_path});
    std.debug.print("[kokoro-probe] espeak: {s}\n", .{espeak_dir});
    std.debug.print("[kokoro-probe] phrase: {s}\n", .{TEST_PHRASE});
    std.debug.print("[kokoro-probe] speed:  {d}\n\n", .{SPEED});

    var engine = try kokoro.KokoroEngine.init(io, gpa, model_path, voice_path, espeak_dir);
    defer engine.deinit();

    std.debug.print("[kokoro-probe] engine initialized — running inference...\n", .{});

    const result = try engine.synth(TEST_PHRASE, SPEED, gpa);
    defer {
        gpa.free(result.pcm);
        gpa.free(result.ipa);
        gpa.free(result.tokens);
    }

    const rtf = result.infer_s / result.duration_s;

    std.debug.print("\n=== KOKORO PROBE RESULTS ===\n", .{});
    std.debug.print("IPA:       {s}\n", .{result.ipa});
    std.debug.print("tokens:    {any}\n", .{result.tokens});
    std.debug.print("len(tok):  {d}\n", .{result.tokens.len});
    std.debug.print("samples:   {d}\n", .{result.pcm.len});
    std.debug.print("duration:  {d:.3}s\n", .{result.duration_s});
    std.debug.print("infer:     {d:.3}s\n", .{result.infer_s});
    std.debug.print("RTF:       {d:.3}\n", .{rtf});

    // Write WAV to /tmp/kokoro_probe.wav
    const wav_path = "/tmp/kokoro_probe.wav";
    try kokoro.writeWav(io, wav_path, result.pcm, kokoro.KokoroEngine.SAMPLE_RATE);
    std.debug.print("WAV:       {s}\n", .{wav_path});

    // Non-silent validation
    var max_abs: u32 = 0;
    for (result.pcm) |s| {
        const a: u32 = @abs(@as(i32, s));
        if (a > max_abs) max_abs = a;
    }
    std.debug.print("max|smp|:  {d}\n", .{max_abs});

    if (max_abs < 100) {
        std.debug.print("ERROR: audio is silent (max |sample| = {d})\n", .{max_abs});
        std.process.exit(1);
    }

    if (rtf >= 1.0) {
        std.debug.print("WARNING: RTF {d:.3} >= 1.0\n", .{rtf});
    }

    // Play via afplay (macOS)
    std.debug.print("\nPlaying via afplay...\n", .{});
    // Zig 0.16: std.process.spawn(io, .{.argv=...}) → child.wait(io)
    var child = try std.process.spawn(io, .{
        .argv = &.{ "afplay", wav_path },
    });
    _ = try child.wait(io);

    std.debug.print("[kokoro-probe] done.\n", .{});
}
