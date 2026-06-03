const std = @import("std");

// v1.0 packaging: a single host-target build (`zig build`) plus a
// universal-binary step (`zig build universal`) that fuses
// aarch64-macos + x86_64-macos with `lipo -create`.
//
// Cross-compile note: when targeting a non-host macOS arch we explicitly
// add the host SDK's lib path (libsqlite3.tbd is multi-arch). Zig 0.16
// does not auto-include the macOS SDK lib path for cross-targets, so the
// linker would fail to find `-lsqlite3`. The tbd ships stubs for both
// x86_64-macos and arm64e-macos; arm64 (Apple Silicon non-e) links it
// fine because Zig falls back to arm64e symbols for non-secure arm64.
//
// v1.3 — Cross-platform: per-target audio backend wiring.
//   macOS    → CoreAudio + AudioUnit + AudioToolbox frameworks
//   linux    → ALSA (asound) + PulseAudio runtime-linked by miniaudio
//   windows  → winmm + ole32 (best-effort, runtime untested)
//
// `configureExe` switches on `target.result.os.tag` for the audio system
// libs + miniaudio compile defines. The cross-compile SDK probe stays
// macOS-only — Linux/Windows resolve system libs via the standard zig
// search paths (or the GitHub-Actions-installed `libasound2-dev`).

fn configureExe(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    with_piper: bool,
    target: std.Build.ResolvedTarget,
) void {
    exe.root_module.linkSystemLibrary("sqlite3", .{});

    // Cross-compile fallback: point the linker at the host macOS SDK's lib
    // directory so the multi-arch libsqlite3.tbd can resolve, the
    // C compiler at the matching include dir so @cImport sqlite3.h works,
    // and the framework search path so CoreAudio + friends (added below for
    // zaudio) resolve. Zig auto-resolves these for the native target but
    // not for cross-targets.
    if (target.result.os.tag == .macos) {
        if (sdkRoot(b)) |sdk_root| {
            const sdk_lib = b.fmt("{s}/usr/lib", .{sdk_root});
            const sdk_inc = b.fmt("{s}/usr/include", .{sdk_root});
            const sdk_fw = b.fmt("{s}/System/Library/Frameworks", .{sdk_root});
            exe.root_module.addLibraryPath(.{ .cwd_relative = sdk_lib });
            exe.root_module.addSystemIncludePath(.{ .cwd_relative = sdk_inc });
            exe.root_module.addFrameworkPath(.{ .cwd_relative = sdk_fw });
        }
    }

    // v0.7: vendored zaudio (miniaudio C wrapper). Always compiled in — the
    // daemon's AudioPlayer owns one zaudio.Engine for the lifetime of the
    // process. Failure to init at runtime is non-fatal (piper path falls
    // back to WAV+afplay). Sources live under vendor/zaudio/.
    //
    // We deliberately do NOT use the upstream zaudio build.zig.zon: that
    // file invokes `linkLibC()` on a Compile step, an API removed in
    // Zig 0.16. Vendoring the .zig + .c sources keeps us on the upstream
    // SHA without forking.
    //
    // v1.3: per-target backend. miniaudio compiles all backends into the
    // same C source; the MA_NO_<BACKEND> defines flip them off so we only
    // pull link-time symbols for the platform we're building. The vendored
    // zaudio.zig is unchanged across targets — only the underlying linkage
    // and miniaudio defines change.
    exe.root_module.addIncludePath(b.path("vendor/zaudio/libs/miniaudio"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("vendor/zaudio/src/zaudio.c"),
        .flags = &.{ "-std=c99", "-fno-sanitize=undefined" },
    });

    const ma_flags: []const []const u8 = switch (target.result.os.tag) {
        .macos => &.{
            "-DMA_NO_WEBAUDIO",
            "-DMA_NO_NULL",
            "-DMA_NO_JACK",
            "-DMA_NO_DSOUND",
            "-DMA_NO_WINMM",
            "-DMA_NO_RUNTIME_LINKING",
            "-std=c99",
            "-fno-sanitize=undefined",
        },
        .linux => &.{
            // ALSA + PulseAudio enabled; PulseAudio uses runtime linking
            // (dlopen) so we don't need libpulse-dev at build time. ALSA
            // is linked statically against libasound — provided by
            // libasound2-dev on Debian / alsa-lib-devel on Fedora.
            "-DMA_NO_WEBAUDIO",
            "-DMA_NO_NULL",
            "-DMA_NO_JACK",
            "-DMA_NO_DSOUND",
            "-DMA_NO_WINMM",
            "-DMA_NO_COREAUDIO",
            "-std=c99",
            "-fno-sanitize=undefined",
        },
        .windows => &.{
            // WASAPI is the modern path; winmm kept as fallback for older
            // hosts. DSOUND off — needs DirectX SDK. No runtime linking
            // because we link ole32 statically below.
            "-DMA_NO_WEBAUDIO",
            "-DMA_NO_NULL",
            "-DMA_NO_JACK",
            "-DMA_NO_COREAUDIO",
            "-DMA_NO_ALSA",
            "-DMA_NO_PULSEAUDIO",
            "-DMA_NO_RUNTIME_LINKING",
            "-std=c99",
            "-fno-sanitize=undefined",
        },
        else => &.{
            "-DMA_NO_WEBAUDIO",
            "-DMA_NO_NULL",
            "-DMA_NO_JACK",
            "-std=c99",
            "-fno-sanitize=undefined",
        },
    };
    exe.root_module.addCSourceFile(.{
        .file = b.path("vendor/zaudio/libs/miniaudio/miniaudio.c"),
        .flags = ma_flags,
    });

    switch (target.result.os.tag) {
        .macos => {
            exe.root_module.linkFramework("CoreAudio", .{});
            exe.root_module.linkFramework("CoreFoundation", .{});
            exe.root_module.linkFramework("AudioUnit", .{});
            exe.root_module.linkFramework("AudioToolbox", .{});
        },
        .linux => {
            // ALSA is the lowest-common-denominator on Linux — every
            // pulseaudio/pipewire stack still falls back to it for direct
            // hardware access. Header is asound.h; library is libasound.so.
            // PulseAudio is runtime-linked by miniaudio (no -lpulse needed).
            // libpthread + libm are pulled in transitively via link_libc=true
            // set on the root module (see build() below).
            exe.root_module.linkSystemLibrary("asound", .{});
        },
        .windows => {
            // winmm provides waveOut* for the legacy backend; ole32 is
            // required by WASAPI for CoInitializeEx + IMMDeviceEnumerator.
            exe.root_module.linkSystemLibrary("winmm", .{});
            exe.root_module.linkSystemLibrary("ole32", .{});
        },
        else => {},
    }

    if (with_piper) {
        const libpiper_root = b.path("vendor/piper1-gpl/libpiper");
        const libpiper_dist_lib = b.path("vendor/piper1-gpl/libpiper/dist/lib");

        exe.root_module.addIncludePath(libpiper_root.path(b, "include"));
        exe.root_module.addLibraryPath(libpiper_dist_lib);
        // linkSystemLibrary("c++") auto-flips link_libcpp which also pulls libc.
        exe.root_module.linkSystemLibrary("piper", .{});
        exe.root_module.linkSystemLibrary("c++", .{});
        // libpiper.dylib pulls in libonnxruntime.1.22.0.dylib at runtime via
        // @rpath. The rpath fix below points the binary at dist/lib where both
        // dylibs live.

        // Resolve @rpath at runtime to the vendored dist/lib dir. Absolute path
        // so the binary works from any cwd during dev. v1.0 ship plan will use
        // a relative @loader_path so brew tap can relocate.
        const abs_lib_path = libpiper_dist_lib.getPath(b);
        exe.root_module.addRPath(.{ .cwd_relative = abs_lib_path });
    }
}

fn sdkRoot(b: *std.Build) ?[]const u8 {
    // Probe the two canonical macOS SDK locations (CLT first, then Xcode).
    // The first one whose usr/lib/libsqlite3.tbd opens wins. Returns null
    // when neither is present — caller falls back to Zig's default search.
    const candidates = [_][]const u8{
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
    };
    for (candidates) |root| {
        const probe = std.fmt.allocPrint(b.allocator, "{s}/usr/lib/libsqlite3.tbd", .{root}) catch continue;
        defer b.allocator.free(probe);
        const probe_z = b.allocator.dupeZ(u8, probe) catch continue;
        defer b.allocator.free(probe_z);
        const fd = std.c.open(probe_z.ptr, .{ .ACCMODE = .RDONLY });
        if (fd < 0) continue;
        _ = std.c.close(fd);
        return b.allocator.dupe(u8, root) catch null;
    }
    return null;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // v0.6: optional libpiper FFI. Default OFF so casual users don't need the
    // libpiper.dylib + onnxruntime sidekicks just to use the `say` backend.
    // Build vendor/piper1-gpl/libpiper first, then pass -Dwith-piper=true.
    const with_piper = b.option(bool, "with-piper", "Link libpiper FFI (requires vendor build, see vendor/README.md)") orelse false;

    const piper_opts = b.addOptions();
    piper_opts.addOption(bool, "enabled", with_piper);

    const mod = b.addModule("agent_tts", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // v0.7: zaudio Zig wrapper module. C sources are wired in configureExe.
    const zaudio_mod = b.addModule("zaudio", .{
        .root_source_file = b.path("vendor/zaudio/src/zaudio.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "agent-tts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // v0.3: SQLite WAL queue persists in ~/.cache/agent-tts/queue.db.
            // macOS ships libsqlite3 in the SDK sysroot; @cImport in queue.zig
            // pulls sqlite3.h from the same place. link_libc required for the
            // C header to resolve typedefs (size_t, etc).
            .link_libc = true,
            .imports = &.{
                .{ .name = "agent_tts", .module = mod },
                .{ .name = "build_options", .module = piper_opts.createModule() },
                .{ .name = "zaudio", .module = zaudio_mod },
            },
        }),
    });
    configureExe(b, exe, with_piper, target);

    b.installArtifact(exe);

    // -----------------------------------------------------------------
    // v1.0: `zig build universal` → universal Mach-O via lipo -create
    // -----------------------------------------------------------------
    // Build aarch64-macos + x86_64-macos slices independently (ReleaseFast,
    // piper OFF — we don't ship libpiper in the universal binary; users
    // who want it build from source). Then run `lipo -create -output ...`.
    //
    // Output: zig-out/bin/agent-tts-universal
    const universal_optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const universal_piper_opts = b.addOptions();
    universal_piper_opts.addOption(bool, "enabled", false);

    const arches = [_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
    };
    var slice_artifacts: [arches.len]*std.Build.Step.Compile = undefined;
    for (arches, 0..) |q, i| {
        const t = b.resolveTargetQuery(q);
        const slice_mod = b.addModule(
            b.fmt("agent_tts_{s}", .{@tagName(q.cpu_arch.?)}),
            .{ .root_source_file = b.path("src/root.zig"), .target = t },
        );
        const slice_zaudio = b.addModule(
            b.fmt("zaudio_{s}", .{@tagName(q.cpu_arch.?)}),
            .{ .root_source_file = b.path("vendor/zaudio/src/zaudio.zig"), .target = t },
        );
        const slice_exe = b.addExecutable(.{
            .name = b.fmt("agent-tts-{s}", .{@tagName(q.cpu_arch.?)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = t,
                .optimize = universal_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "agent_tts", .module = slice_mod },
                    .{ .name = "build_options", .module = universal_piper_opts.createModule() },
                    .{ .name = "zaudio", .module = slice_zaudio },
                },
            }),
        });
        configureExe(b, slice_exe, false, t);
        slice_artifacts[i] = slice_exe;
    }

    const lipo = b.addSystemCommand(&.{ "lipo", "-create", "-output" });
    const universal_out = lipo.addOutputFileArg("agent-tts-universal");
    for (slice_artifacts) |slice_exe| {
        lipo.addFileArg(slice_exe.getEmittedBin());
    }

    const universal_install = b.addInstallBinFile(universal_out, "agent-tts-universal");
    const universal_step = b.step("universal", "Build universal (arm64+x86_64) macOS binary via lipo");
    universal_step.dependOn(&universal_install.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Dedicated test target for the preprocessor (v0.5). Zig's addTest
    // only collects tests from the file you point it to, not from its
    // imports — so each test-bearing file gets its own step.
    const preproc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/preproc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_preproc_tests = b.addRunArtifact(preproc_tests);

    // v1.3 — platform dispatcher tests (pure: std + builtin only).
    const platform_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_platform_tests = b.addRunArtifact(platform_tests);

    // v1.3 — tts.zig tests (mapLinuxVoice + comptime platform dispatch
    // smoke). Pulls preproc + ipc + platform via @import; none of them
    // require sqlite/zaudio/libc beyond std defaults.
    const tts_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tts.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tts_tests = b.addRunArtifact(tts_tests);

    // v1.3 — systemd unit rendering tests. Compiles on every host because
    // the module is pure std (no Linux-only syscalls at parse time); the
    // tests only render strings, never spawn systemctl.
    const systemd_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/systemd.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_systemd_tests = b.addRunArtifact(systemd_tests);

    // v1.1: dedicated test steps for the language detector and the
    // extended IPC parser. Backward-compat parsing (v0.6 / v0.7 / v1.1)
    // and sub-µs stopword detector.
    const detect_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/detect.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_detect_tests = b.addRunArtifact(detect_tests);

    const ipc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ipc.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_ipc_tests = b.addRunArtifact(ipc_tests);

    // Benchmark executable for the preprocessor (used to populate
    // _qa/v0.5-baseline.md). Build in ReleaseFast for realistic numbers.
    const preproc_mod = b.createModule(.{
        .root_source_file = b.path("src/preproc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench_exe = b.addExecutable(.{
        .name = "bench-preproc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/bench_preproc.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "preproc", .module = preproc_mod }},
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench-preproc", "Run preproc benchmark");
    bench_step.dependOn(&run_bench.step);

    // v1.4: voice.zig stands alone (subcommand handler — no heavy imports).
    // addTest only collects tests from the entry source, so to be sure the
    // WAV sniff + slug validation tests run on every `zig build test`, point
    // a dedicated step at the file. Mirrors the preproc pattern from v0.5.
    const voice_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/voice.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_voice_tests = b.addRunArtifact(voice_tests);

    // ipc_tests already defined above for the v1.1 multilingual surface;
    // v1.4 added the `cloned` variant + test, which runs via that same step.

    // v1.7 — stream.zig stands alone (CLI handler — imports preproc + client + ipc).
    // addTest only collects tests from the entry source, so the streaming
    // integration test gets its own step.
    const stream_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stream.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_stream_tests = b.addRunArtifact(stream_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_preproc_tests.step);
    test_step.dependOn(&run_platform_tests.step);
    test_step.dependOn(&run_tts_tests.step);
    test_step.dependOn(&run_systemd_tests.step);
    test_step.dependOn(&run_detect_tests.step);
    test_step.dependOn(&run_voice_tests.step);
    test_step.dependOn(&run_ipc_tests.step);
    test_step.dependOn(&run_stream_tests.step);
}
