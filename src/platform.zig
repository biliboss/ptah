// SPDX-License-Identifier: MIT OR Apache-2.0
// Central platform dispatcher — v1.3.
//
// Callers in `tts.zig`, `audio.zig`, `main.zig` switch on `Platform` at
// comptime so dead branches drop out of the binary on the host target.
// Runtime branches don't pay off here: the host OS is fixed at compile
// time and the call sites are hot (per-utterance, per-boot).
//
// Honest scope: macOS is the only platform with end-to-end runtime
// validation (v1.0 ship). Linux paths compile + run on `ubuntu-latest`
// in CI (see `.github/workflows/ci.yml`). Windows paths compile only —
// runtime untested until somebody asks.

const std = @import("std");
const builtin = @import("builtin");

pub const Platform = enum {
    macos,
    linux,
    windows,

    pub fn str(self: Platform) []const u8 {
        return switch (self) {
            .macos => "macos",
            .linux => "linux",
            .windows => "windows",
        };
    }
};

/// Resolve the platform at comptime from the active build target.
/// `builtin.target.os.tag` is the source of truth — same value the linker
/// sees. Unknown OS tags fall through to a compile error rather than a
/// runtime-only failure: better to fail the build than ship a binary that
/// silently does the wrong thing.
pub fn current() Platform {
    return switch (builtin.target.os.tag) {
        .macos => .macos,
        .linux => .linux,
        .windows => .windows,
        else => @compileError("ptah: unsupported target OS '" ++ @tagName(builtin.target.os.tag) ++ "'"),
    };
}

test "current matches builtin os tag" {
    const p = current();
    switch (builtin.target.os.tag) {
        .macos => try std.testing.expectEqual(Platform.macos, p),
        .linux => try std.testing.expectEqual(Platform.linux, p),
        .windows => try std.testing.expectEqual(Platform.windows, p),
        else => unreachable,
    }
}

test "str round-trips" {
    try std.testing.expectEqualStrings("macos", Platform.macos.str());
    try std.testing.expectEqualStrings("linux", Platform.linux.str());
    try std.testing.expectEqualStrings("windows", Platform.windows.str());
}
