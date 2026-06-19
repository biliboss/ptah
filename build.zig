const std = @import("std");

// Kokoro Dora is the sole TTS engine.
// `zig build`         → builds ptah exe (links onnxruntime + espeak-ng)
// `zig build kokoro-probe` → runs the standalone Kokoro probe
// `zig build universal`    → universal macOS binary via lipo

fn configureExe(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) void {
    exe.root_module.linkSystemLibrary("sqlite3", .{});

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

    // Audio: afplay-only (zaudio/miniaudio dropped — zero vendor weight).
    // Playback is via macOS `afplay` from the daemon; see src/audio.zig.

    switch (target.result.os.tag) {
        .macos => {
            exe.root_module.linkFramework("CoreAudio", .{});
            exe.root_module.linkFramework("CoreFoundation", .{});
            exe.root_module.linkFramework("AudioUnit", .{});
            exe.root_module.linkFramework("AudioToolbox", .{});
        },
        .linux => {
            exe.root_module.linkSystemLibrary("asound", .{});
        },
        .windows => {
            exe.root_module.linkSystemLibrary("winmm", .{});
            exe.root_module.linkSystemLibrary("ole32", .{});
        },
        else => {},
    }
}

fn sdkRoot(b: *std.Build) ?[]const u8 {
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

    // ── Kokoro native engine module (shared by probe + main exe) ──────────────
    const kokoro_mod = blk: {
        const mod = b.addModule("kokoro", .{
            .root_source_file = b.path("src/kokoro.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.addIncludePath(b.path("vendor/onnxruntime/include"));
        mod.addLibraryPath(b.path("vendor/onnxruntime/lib"));
        mod.linkSystemLibrary("onnxruntime", .{});
        mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/espeak-ng/include" });
        mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/espeak-ng/lib" });
        mod.linkSystemLibrary("espeak-ng", .{});
        break :blk mod;
    };

    // ── kokoro-probe executable ────────────────────────────────────────────────
    {
        const probe_exe = b.addExecutable(.{
            .name = "kokoro-probe",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/kokoro_probe.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "kokoro", .module = kokoro_mod },
                },
            }),
        });
        const ort_lib_abs = b.path("vendor/onnxruntime/lib").getPath(b);
        probe_exe.root_module.addRPath(.{ .cwd_relative = ort_lib_abs });
        probe_exe.root_module.addRPath(.{ .cwd_relative = "/opt/homebrew/opt/espeak-ng/lib" });

        const probe_install = b.addInstallArtifact(probe_exe, .{});
        const run_probe = b.addRunArtifact(probe_exe);
        run_probe.step.dependOn(&probe_install.step);
        const probe_step = b.step("kokoro-probe", "Run Kokoro native engine probe (synth test phrase + afplay)");
        probe_step.dependOn(&run_probe.step);
    }

    const mod = b.addModule("ptah", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "ptah",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "ptah", .module = mod },
                .{ .name = "kokoro", .module = kokoro_mod },
            },
        }),
    });
    // Wire kokoro deps into the exe (onnxruntime + espeak-ng rpaths)
    exe.root_module.addIncludePath(b.path("vendor/onnxruntime/include"));
    exe.root_module.addLibraryPath(b.path("vendor/onnxruntime/lib"));
    exe.root_module.linkSystemLibrary("onnxruntime", .{});
    exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/espeak-ng/include" });
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/espeak-ng/lib" });
    exe.root_module.linkSystemLibrary("espeak-ng", .{});
    const ort_lib_abs = b.path("vendor/onnxruntime/lib").getPath(b);
    exe.root_module.addRPath(.{ .cwd_relative = ort_lib_abs });
    exe.root_module.addRPath(.{ .cwd_relative = "/opt/homebrew/opt/espeak-ng/lib" });

    configureExe(b, exe, target);
    b.installArtifact(exe);

    // ── universal binary (arm64 + x86_64) ─────────────────────────────────────
    const universal_optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const arches = [_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
    };
    var slice_artifacts: [arches.len]*std.Build.Step.Compile = undefined;
    for (arches, 0..) |q, i| {
        const t = b.resolveTargetQuery(q);
        const slice_mod = b.addModule(
            b.fmt("ptah_{s}", .{@tagName(q.cpu_arch.?)}),
            .{ .root_source_file = b.path("src/root.zig"), .target = t },
        );
        const slice_kokoro = blk: {
            const m = b.addModule(
                b.fmt("kokoro_{s}", .{@tagName(q.cpu_arch.?)}),
                .{ .root_source_file = b.path("src/kokoro.zig"), .target = t, .optimize = universal_optimize, .link_libc = true },
            );
            m.addIncludePath(b.path("vendor/onnxruntime/include"));
            m.addLibraryPath(b.path("vendor/onnxruntime/lib"));
            m.linkSystemLibrary("onnxruntime", .{});
            m.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/espeak-ng/include" });
            m.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/espeak-ng/lib" });
            m.linkSystemLibrary("espeak-ng", .{});
            break :blk m;
        };
        const slice_exe = b.addExecutable(.{
            .name = b.fmt("ptah-{s}", .{@tagName(q.cpu_arch.?)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = t,
                .optimize = universal_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "ptah", .module = slice_mod },
                    .{ .name = "kokoro", .module = slice_kokoro },
                },
            }),
        });
        slice_exe.root_module.addIncludePath(b.path("vendor/onnxruntime/include"));
        slice_exe.root_module.addLibraryPath(b.path("vendor/onnxruntime/lib"));
        slice_exe.root_module.linkSystemLibrary("onnxruntime", .{});
        slice_exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/espeak-ng/include" });
        slice_exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/espeak-ng/lib" });
        slice_exe.root_module.linkSystemLibrary("espeak-ng", .{});
        configureExe(b, slice_exe, t);
        slice_artifacts[i] = slice_exe;
    }

    const lipo = b.addSystemCommand(&.{ "lipo", "-create", "-output" });
    const universal_out = lipo.addOutputFileArg("ptah-universal");
    for (slice_artifacts) |slice_exe| {
        lipo.addFileArg(slice_exe.getEmittedBin());
    }
    const universal_install = b.addInstallBinFile(universal_out, "ptah-universal");
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

    const preproc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/preproc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_preproc_tests = b.addRunArtifact(preproc_tests);

    const platform_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_platform_tests = b.addRunArtifact(platform_tests);

    const tts_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tts.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tts_tests = b.addRunArtifact(tts_tests);

    const systemd_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/systemd.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_systemd_tests = b.addRunArtifact(systemd_tests);

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

    const ssml_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ssml.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_ssml_tests = b.addRunArtifact(ssml_tests);

    const postfx_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/postfx.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_postfx_tests = b.addRunArtifact(postfx_tests);

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
    test_step.dependOn(&run_ipc_tests.step);
    test_step.dependOn(&run_stream_tests.step);
    test_step.dependOn(&run_ssml_tests.step);
    test_step.dependOn(&run_postfx_tests.step);
}
