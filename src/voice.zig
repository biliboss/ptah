// SPDX-License-Identifier: MIT OR Apache-2.0
// Voice management — `agent-tts voice clone` + `voice list` subcommands (v1.4).
//
// Cloned voices live under ~/.cache/agent-tts/voices/<slug>/ with two files
// produced by the Python sidecar (`scripts/voice_clone.py`):
//   - embedding.npz   — XTTS-v2 speaker embedding (numpy archive)
//   - metadata.json   — slug, created_at, sample sample-rate + duration
//
// The Zig binary owns the surface (arg parse, WAV sniff, validation, FS layout).
// XTTS-v2 itself runs in a Python sidecar — see scripts/setup-voice-clone.sh.
// This relaxes the "only Zig" constraint *only* for cloning; faber + say stay
// pure Zig FFI / system spawn paths.

const std = @import("std");

const MIN_SAMPLE_SECONDS: f64 = 20.0;
const MAX_SAMPLE_SECONDS: f64 = 120.0;
const MAX_SLUG_LEN: usize = 32;

pub const HELP =
    \\agent-tts voice — manage cloned voices (v1.4+)
    \\
    \\Usage:
    \\  agent-tts voice clone --sample <wav> --name <slug>
    \\      Clone a voice from a 20-120s WAV. Slug must be [a-z0-9-]+, 1-32 chars.
    \\      Writes ~/.cache/agent-tts/voices/<slug>/{embedding.npz,metadata.json}.
    \\      Requires the Python sidecar — run scripts/setup-voice-clone.sh once.
    \\
    \\  agent-tts voice list
    \\      List installed voices (faber + every cloned voice on disk).
    \\
    \\Once installed, use with:
    \\  agent-tts --voice <slug> "Olá mundo"
    \\
;

pub const Error = error{
    InvalidArgs,
    SampleNotFound,
    SampleNotWav,
    SampleTooShort,
    SampleTooLong,
    InvalidSlug,
    SidecarSpawnFailed,
    SidecarExitNonZero,
    SidecarMissing,
};

/// Top-level dispatch for `agent-tts voice <subcommand> ...`.
pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    args: []const []const u8,
) !void {
    if (args.len < 3) {
        std.debug.print("{s}", .{HELP});
        std.process.exit(2);
    }
    const sub = args[2];
    if (std.mem.eql(u8, sub, "clone")) {
        return cmdClone(arena, io, home, args);
    }
    if (std.mem.eql(u8, sub, "list")) {
        return cmdList(arena, io, home);
    }
    if (std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "--help")) {
        std.debug.print("{s}", .{HELP});
        return;
    }
    std.debug.print("error: unknown voice subcommand '{s}'\n", .{sub});
    std.debug.print("{s}", .{HELP});
    std.process.exit(2);
}

/// `agent-tts voice clone --sample <wav> --name <slug>`. Validates inputs +
/// delegates to scripts/voice_clone.py to produce embedding.npz/metadata.json.
pub fn cmdClone(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    args: []const []const u8,
) !void {
    var sample_path: ?[]const u8 = null;
    var name: ?[]const u8 = null;

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--sample")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --sample needs value\n", .{});
                std.process.exit(2);
            }
            sample_path = args[i];
        } else if (std.mem.eql(u8, a, "--name")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --name needs value\n", .{});
                std.process.exit(2);
            }
            name = args[i];
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{HELP});
            return;
        } else {
            std.debug.print("error: unknown flag '{s}'\n", .{a});
            std.process.exit(2);
        }
    }

    if (sample_path == null or name == null) {
        std.debug.print("error: --sample and --name are required\n\n", .{});
        std.debug.print("{s}", .{HELP});
        std.process.exit(2);
    }

    // Validate slug eagerly — saves a wasted FS poke if the user typed a path.
    if (!validateSlug(name.?)) {
        std.debug.print(
            "error: invalid name '{s}' — must match [a-z0-9-]+, 1-{d} chars\n",
            .{ name.?, MAX_SLUG_LEN },
        );
        std.process.exit(2);
    }

    // Sniff the WAV header before paying the Python startup cost. Error
    // messages were already printed by sniffWav — translate the typed error
    // into a clean exit so the user never sees a Zig stack trace.
    const info = sniffWav(io, sample_path.?) catch |e| switch (e) {
        Error.SampleNotFound, Error.SampleNotWav => std.process.exit(2),
        else => return e,
    };
    const duration_s = info.durationSeconds();
    if (duration_s < MIN_SAMPLE_SECONDS) {
        std.debug.print(
            "error: sample too short ({d:.1}s) — need at least {d:.0}s of clean speech\n",
            .{ duration_s, MIN_SAMPLE_SECONDS },
        );
        std.process.exit(2);
    }
    if (duration_s > MAX_SAMPLE_SECONDS) {
        std.debug.print(
            "error: sample too long ({d:.1}s) — max {d:.0}s; trim with `ffmpeg -t {d:.0}`\n",
            .{ duration_s, MAX_SAMPLE_SECONDS, MAX_SAMPLE_SECONDS },
        );
        std.process.exit(2);
    }

    const voice_dir = try std.fmt.allocPrint(
        arena,
        "{s}/.cache/agent-tts/voices/{s}",
        .{ home, name.? },
    );
    std.Io.Dir.cwd().createDirPath(io, voice_dir) catch |e| {
        std.debug.print("error: cannot create {s}: {s}\n", .{ voice_dir, @errorName(e) });
        std.process.exit(1);
    };

    const embedding_path = try std.fmt.allocPrint(arena, "{s}/embedding.npz", .{voice_dir});
    const metadata_path = try std.fmt.allocPrint(arena, "{s}/metadata.json", .{voice_dir});

    std.debug.print(
        "[voice clone] slug={s} sample={s} duration={d:.1}s rate={d}Hz\n",
        .{ name.?, sample_path.?, duration_s, info.sample_rate },
    );

    // Sidecar invocation. We do NOT mandate `uv` — try it first because the
    // setup script uses it, fall back to plain `python3` if uv isn't on PATH.
    // The script handles its own dependency resolution.
    try invokeSidecar(arena, io, home, &.{
        "scripts/voice_clone.py",
        "--sample",
        sample_path.?,
        "--out",
        embedding_path,
    });

    // Metadata is written by Zig (not the Python sidecar) — that way a partial
    // sidecar success still leaves us with a structured record + we don't have
    // to round-trip a clock through Python.
    try writeMetadata(io, metadata_path, name.?, sample_path.?, info, duration_s);

    std.debug.print(
        "[voice clone] OK — embedded at {s}\n[voice clone] use: agent-tts --voice {s} \"Olá\"\n",
        .{ embedding_path, name.? },
    );
}

/// `agent-tts voice list` — print faber + each cloned voice with a one-line
/// summary. Format mirrors `agent-tts queue` for visual consistency.
pub fn cmdList(arena: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    var w = &stdout.interface;

    try w.writeAll("  slug                  engine   duration   rate     notes\n");
    try w.writeAll("  faber                 piper    -          22050Hz  bundled neural Pt-BR (~91ms warm)\n");
    try w.writeAll("  Luciana               say      -          22050Hz  macOS system voice (default for --engine say)\n");

    const voices_dir = try std.fmt.allocPrint(arena, "{s}/.cache/agent-tts/voices", .{home});
    var dir = std.Io.Dir.cwd().openDir(io, voices_dir, .{ .iterate = true }) catch {
        // No voices dir = nothing cloned yet. faber+say still listed above.
        try w.writeAll("  (no cloned voices — run `agent-tts voice clone --sample X.wav --name Y`)\n");
        try w.flush();
        return;
    };
    defer dir.close(io);

    var count: u32 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        // Validate the directory looks like a cloned voice (has metadata.json).
        const meta_path = try std.fmt.allocPrint(
            arena,
            "{s}/{s}/metadata.json",
            .{ voices_dir, entry.name },
        );
        const meta = readVoiceMetadata(arena, io, meta_path) catch null;
        if (meta == null) continue;
        const m = meta.?;
        // v1.6: show duration + sample-rate parsed from metadata.json. Falls
        // back to dashes if the values are missing — older v1.4 voices that
        // were written before the duration field landed still render cleanly.
        var dur_buf: [16]u8 = undefined;
        const dur_str: []const u8 = if (m.duration_seconds > 0)
            std.fmt.bufPrint(&dur_buf, "{d:.1}s", .{m.duration_seconds}) catch "-"
        else
            "-";
        var rate_buf: [16]u8 = undefined;
        const rate_str: []const u8 = if (m.sample_rate > 0)
            std.fmt.bufPrint(&rate_buf, "{d}Hz", .{m.sample_rate}) catch "-"
        else
            "-";
        try w.print("  {s:<22}cloned   {s:<11}{s:<9}XTTS-v2 sidecar\n", .{
            entry.name,
            dur_str,
            rate_str,
        });
        count += 1;
    }
    if (count == 0) {
        try w.writeAll("  (no cloned voices — run `agent-tts voice clone --sample X.wav --name Y`)\n");
    }
    try w.flush();
}

/// Parsed subset of a voice's metadata.json — only what `voice list` needs.
/// Tiny hand-rolled extractor instead of pulling std.json so the format
/// stays forgiving (extra/unknown fields, trailing whitespace) without
/// adding allocator round-trips per voice.
pub const VoiceMetadata = struct {
    duration_seconds: f64 = 0,
    sample_rate: u32 = 0,
};

fn readVoiceMetadata(arena: std.mem.Allocator, io: std.Io, path: []const u8) !VoiceMetadata {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    // metadata.json is ~200 bytes — small enough to slurp whole. 8 KB ceiling
    // protects against a truncated read returning forever-zero.
    var content = std.array_list.Aligned(u8, null).empty;
    defer content.deinit(arena);
    var tmp: [256]u8 = undefined;
    var total: usize = 0;
    while (total < 8192) {
        const n = reader.interface.readSliceShort(&tmp) catch break;
        if (n == 0) break;
        try content.appendSlice(arena, tmp[0..n]);
        total += n;
    }
    return parseVoiceMetadata(content.items);
}

/// Pulls duration + sample-rate out of metadata.json without a full JSON
/// parser. Both keys are emitted by writeMetadata above so the format is
/// stable; we only need to be robust to whitespace + key ordering.
pub fn parseVoiceMetadata(json: []const u8) VoiceMetadata {
    var out: VoiceMetadata = .{};
    if (findNumberAfter(json, "\"duration_seconds\"")) |v| out.duration_seconds = v;
    if (findNumberAfter(json, "\"sample_rate\"")) |v| out.sample_rate = @intFromFloat(v);
    return out;
}

fn findNumberAfter(haystack: []const u8, needle: []const u8) ?f64 {
    const idx = std.mem.indexOf(u8, haystack, needle) orelse return null;
    var i = idx + needle.len;
    // Skip the colon + whitespace between key and value.
    while (i < haystack.len and (haystack[i] == ' ' or haystack[i] == ':' or haystack[i] == '\t')) {
        i += 1;
    }
    const start = i;
    while (i < haystack.len) {
        const ch = haystack[i];
        const is_num = (ch >= '0' and ch <= '9') or ch == '.' or ch == '-' or ch == '+' or ch == 'e' or ch == 'E';
        if (!is_num) break;
        i += 1;
    }
    if (i == start) return null;
    return std.fmt.parseFloat(f64, haystack[start..i]) catch null;
}

/// Slug rule: `[a-z0-9-]+`, 1-32 chars. Mirrors the Python sidecar's parse —
/// keep both in sync to avoid "looked valid to Zig, rejected by Python".
pub fn validateSlug(s: []const u8) bool {
    if (s.len == 0 or s.len > MAX_SLUG_LEN) return false;
    for (s) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-';
        if (!ok) return false;
    }
    return true;
}

pub const WavInfo = struct {
    sample_rate: u32,
    channels: u16,
    bits_per_sample: u16,
    data_bytes: u32,

    pub fn durationSeconds(self: WavInfo) f64 {
        const bytes_per_sample = @as(u32, self.bits_per_sample / 8);
        const block = @as(u32, self.channels) * bytes_per_sample;
        if (block == 0 or self.sample_rate == 0) return 0;
        const frames = @as(f64, @floatFromInt(self.data_bytes)) / @as(f64, @floatFromInt(block));
        return frames / @as(f64, @floatFromInt(self.sample_rate));
    }
};

/// Minimal RIFF/WAVE header sniff. Validates magic + reads sample-rate,
/// channels, bits-per-sample, data-chunk size. Does NOT decode audio.
pub fn sniffWav(io: std.Io, path: []const u8) !WavInfo {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.print("error: sample not found: {s}\n", .{path});
            return Error.SampleNotFound;
        },
        else => return e,
    };
    defer file.close(io);

    // RIFF header (12 bytes) + fmt chunk (24 bytes for PCM) + data chunk header (8 bytes).
    // For non-PCM WAVs there can be extra chunks before `data`; we walk them.
    var hdr: [12]u8 = undefined;
    var read_buf: [1024]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    try reader.interface.readSliceAll(hdr[0..]);
    if (!std.mem.eql(u8, hdr[0..4], "RIFF") or !std.mem.eql(u8, hdr[8..12], "WAVE")) {
        std.debug.print("error: not a RIFF/WAVE file: {s}\n", .{path});
        return Error.SampleNotWav;
    }

    var info: WavInfo = .{ .sample_rate = 0, .channels = 0, .bits_per_sample = 0, .data_bytes = 0 };
    var have_fmt = false;
    var have_data = false;
    while (!(have_fmt and have_data)) {
        var chunk_hdr: [8]u8 = undefined;
        reader.interface.readSliceAll(chunk_hdr[0..]) catch return Error.SampleNotWav;
        const chunk_size = std.mem.readInt(u32, chunk_hdr[4..8], .little);
        if (std.mem.eql(u8, chunk_hdr[0..4], "fmt ")) {
            if (chunk_size < 16) return Error.SampleNotWav;
            var fmt_buf: [16]u8 = undefined;
            try reader.interface.readSliceAll(fmt_buf[0..]);
            info.channels = std.mem.readInt(u16, fmt_buf[2..4], .little);
            info.sample_rate = std.mem.readInt(u32, fmt_buf[4..8], .little);
            info.bits_per_sample = std.mem.readInt(u16, fmt_buf[14..16], .little);
            // Skip any extra fmt bytes (fact chunks etc.).
            if (chunk_size > 16) {
                const skip = chunk_size - 16;
                var skip_buf: [256]u8 = undefined;
                var left: u32 = skip;
                while (left > 0) {
                    const n = @min(left, @as(u32, skip_buf.len));
                    try reader.interface.readSliceAll(skip_buf[0..n]);
                    left -= n;
                }
            }
            have_fmt = true;
        } else if (std.mem.eql(u8, chunk_hdr[0..4], "data")) {
            info.data_bytes = chunk_size;
            have_data = true;
            // Don't read the audio body — we only need the size.
            break;
        } else {
            // Skip unknown chunk.
            var skip_buf: [256]u8 = undefined;
            var left: u32 = chunk_size;
            while (left > 0) {
                const n = @min(left, @as(u32, skip_buf.len));
                try reader.interface.readSliceAll(skip_buf[0..n]);
                left -= n;
            }
        }
    }

    if (info.sample_rate == 0 or info.channels == 0 or info.bits_per_sample == 0) {
        return Error.SampleNotWav;
    }
    return info;
}

fn writeMetadata(
    io: std.Io,
    path: []const u8,
    slug: []const u8,
    sample_path: []const u8,
    info: WavInfo,
    duration_s: f64,
) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &buf,
        \\{{
        \\  "slug": "{s}",
        \\  "sample_path": "{s}",
        \\  "sample_rate": {d},
        \\  "channels": {d},
        \\  "duration_seconds": {d:.2},
        \\  "engine": "cloned",
        \\  "model": "xtts-v2",
        \\  "version": 1
        \\}}
        \\
    ,
        .{ slug, sample_path, info.sample_rate, info.channels, duration_s },
    );
    try file.writeStreamingAll(io, json);
}

fn invokeSidecar(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    script_args: []const []const u8,
) !void {
    _ = home;
    // Resolve script path relative to cwd. Caller is responsible for cwd ==
    // repo root for now (v1.4 ships from source). When we bundle, we'll
    // resolve relative to the binary's location.
    const argv = try buildArgv(arena, script_args);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| {
        std.debug.print(
            "error: cannot spawn Python sidecar ({s}). Run scripts/setup-voice-clone.sh first.\n",
            .{@errorName(e)},
        );
        return Error.SidecarSpawnFailed;
    };
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("error: sidecar exited with code {d}\n", .{code});
                return Error.SidecarExitNonZero;
            }
        },
        else => {
            std.debug.print("error: sidecar terminated abnormally\n", .{});
            return Error.SidecarExitNonZero;
        },
    }
}

fn buildArgv(arena: std.mem.Allocator, script_args: []const []const u8) ![][]const u8 {
    // Preference order (v1.6):
    //   1. `.venv-voice/bin/python` — produced by setup-voice-clone.sh. This
    //      is the "boring" path: deterministic interpreter, all deps already
    //      resolved (incl. transformers<5 + torchcodec pins that uv-run would
    //      re-discover the hard way).
    //   2. `uv run --with TTS` — kept as a convenience for users who skipped
    //      setup. Slower cold start and may hit version pins coqui-tts didn't
    //      declare, but works for the happy path.
    //   3. `python3` — last resort; assumes the user manages their own env.
    if (venvPythonExists()) |venv_py| {
        const argv = try arena.alloc([]const u8, script_args.len + 1);
        argv[0] = venv_py;
        for (script_args, 0..) |a, i| argv[i + 1] = a;
        return argv;
    }
    const uv_exists = lookPath("uv");
    if (uv_exists) {
        const argv = try arena.alloc([]const u8, script_args.len + 4);
        argv[0] = "uv";
        argv[1] = "run";
        argv[2] = "--with";
        argv[3] = "TTS";
        for (script_args, 0..) |a, i| argv[i + 4] = a;
        return argv;
    }
    const argv = try arena.alloc([]const u8, script_args.len + 1);
    argv[0] = "python3";
    for (script_args, 0..) |a, i| argv[i + 1] = a;
    return argv;
}

/// Returns the venv python path if `.venv-voice/bin/python` exists in cwd,
/// `null` otherwise. We do this with `std.c.access` (cheaper than openat +
/// close and we don't need a handle). The returned slice points at static
/// storage — safe because we copy via std.mem.copyForwards in the caller.
fn venvPythonExists() ?[]const u8 {
    const path = ".venv-voice/bin/python";
    const z = std.fmt.bufPrintZ(@constCast(&venv_buf), "{s}", .{path}) catch return null;
    if (std.c.access(z.ptr, std.c.F_OK) == 0) return path;
    return null;
}

var venv_buf: [64]u8 = undefined;

fn lookPath(name: []const u8) bool {
    // Tiny PATH walk — enough for "is uv on PATH?". We do not need full
    // execvp semantics here.
    const c = @cImport({
        @cInclude("stdlib.h");
    });
    const env_ptr = c.getenv("PATH");
    if (env_ptr == null) return false;
    const path_env = std.mem.span(env_ptr);
    var it = std.mem.splitScalar(u8, path_env, ':');
    var buf: [4096]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        const fd = std.c.open(full.ptr, .{ .ACCMODE = .RDONLY });
        if (fd >= 0) {
            _ = std.c.close(fd);
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "validateSlug accepts canonical names" {
    try std.testing.expect(validateSlug("gabriel"));
    try std.testing.expect(validateSlug("a"));
    try std.testing.expect(validateSlug("voice-1"));
    try std.testing.expect(validateSlug("123"));
    try std.testing.expect(validateSlug("abc-def-ghi"));
}

test "validateSlug rejects empty and oversize" {
    try std.testing.expect(!validateSlug(""));
    var long: [33]u8 = undefined;
    @memset(&long, 'a');
    try std.testing.expect(!validateSlug(&long));
}

test "validateSlug rejects illegal chars" {
    try std.testing.expect(!validateSlug("Gabriel"));
    try std.testing.expect(!validateSlug("voice_1"));
    try std.testing.expect(!validateSlug("voice.1"));
    try std.testing.expect(!validateSlug("voice 1"));
    try std.testing.expect(!validateSlug("../etc"));
    try std.testing.expect(!validateSlug("voice/sub"));
}

test "WavInfo.durationSeconds computes mono s16 22050" {
    // 22050 Hz * 30s * 2 bytes/sample = 1_323_000 bytes
    const info: WavInfo = .{
        .sample_rate = 22050,
        .channels = 1,
        .bits_per_sample = 16,
        .data_bytes = 1_323_000,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), info.durationSeconds(), 0.001);
}

test "WavInfo.durationSeconds computes stereo 44.1k" {
    // 44100 * 10s * 2ch * 2 bytes = 1_764_000 bytes
    const info: WavInfo = .{
        .sample_rate = 44100,
        .channels = 2,
        .bits_per_sample = 16,
        .data_bytes = 1_764_000,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), info.durationSeconds(), 0.001);
}

test "WavInfo.durationSeconds safe on zero block" {
    const info: WavInfo = .{ .sample_rate = 0, .channels = 0, .bits_per_sample = 0, .data_bytes = 0 };
    try std.testing.expectEqual(@as(f64, 0), info.durationSeconds());
}

test "HELP text mentions clone + list" {
    try std.testing.expect(std.mem.indexOf(u8, HELP, "voice clone") != null);
    try std.testing.expect(std.mem.indexOf(u8, HELP, "voice list") != null);
    try std.testing.expect(std.mem.indexOf(u8, HELP, "--sample") != null);
    try std.testing.expect(std.mem.indexOf(u8, HELP, "--name") != null);
}

test "parseVoiceMetadata extracts duration + rate" {
    const j =
        \\{
        \\  "slug": "gabriel",
        \\  "sample_rate": 22050,
        \\  "channels": 1,
        \\  "duration_seconds": 28.30,
        \\  "engine": "cloned"
        \\}
    ;
    const m = parseVoiceMetadata(j);
    try std.testing.expectApproxEqAbs(@as(f64, 28.30), m.duration_seconds, 0.01);
    try std.testing.expectEqual(@as(u32, 22050), m.sample_rate);
}

test "parseVoiceMetadata is tolerant of key order + whitespace" {
    const j =
        \\{"duration_seconds":15.5,"sample_rate":  44100}
    ;
    const m = parseVoiceMetadata(j);
    try std.testing.expectApproxEqAbs(@as(f64, 15.5), m.duration_seconds, 0.01);
    try std.testing.expectEqual(@as(u32, 44100), m.sample_rate);
}

test "parseVoiceMetadata returns zeros on missing keys" {
    const m = parseVoiceMetadata("{\"slug\": \"x\"}");
    try std.testing.expectEqual(@as(f64, 0), m.duration_seconds);
    try std.testing.expectEqual(@as(u32, 0), m.sample_rate);
}
