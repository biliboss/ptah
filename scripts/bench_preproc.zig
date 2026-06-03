// SPDX-License-Identifier: MIT OR Apache-2.0
// Benchmark for src/preproc.zig — measures wall time of `process` over
// realistic Pt-BR sentences. Used to populate _qa/v0.5-baseline.md.
//
// Usage:
//   zig run scripts/bench_preproc.zig -O ReleaseFast --dep preproc \
//     -Mroot=scripts/bench_preproc.zig -Mpreproc=src/preproc.zig
//
// Or via the bundled run step (see build.zig: `bench-preproc`).

const std = @import("std");
const preproc = @import("preproc");

inline fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Case = struct {
    name: []const u8,
    input: []const u8,
};

const CASES = [_]Case{
    .{
        .name = "short greeting",
        .input = "Olá, mundo.",
    },
    .{
        .name = "Sr. Silva 25 anos",
        .input = "Sr. Silva tem 25 anos, certo?",
    },
    .{
        .name = "Av. Paulista nº 1578",
        .input = "Av. Paulista, nº 1578.",
    },
    .{
        .name = "ano 2026",
        .input = "Estamos em 2026 e devemos R$ 1234 ao Dr. João.",
    },
    .{
        .name = "long mixed paragraph",
        .input =
            "O Sr. Mauricio enviou 3 mensagens hoje. cf. minha agenda, " ++
            "temos reunião às 14h. R$ 500 já pagos, faltam R$ 250. " ++
            "Confirma vs. cancelar etc. obrigado!",
    },
};

const ITERATIONS: usize = 1000;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    std.debug.print("# preproc benchmark — {d} iterations per case\n\n", .{ITERATIONS});
    std.debug.print("| case | input bytes | median µs | mean µs | output |\n", .{});
    std.debug.print("|------|------------:|----------:|--------:|--------|\n", .{});

    var times = try alloc.alloc(u64, ITERATIONS);
    defer alloc.free(times);

    for (CASES) |c| {
        // Capture one rendered output for the report (using a fresh
        // arena so we can free it cleanly).
        var sample_arena = std.heap.ArenaAllocator.init(alloc);
        defer sample_arena.deinit();
        const sample_out = try preproc.process(sample_arena.allocator(), c.input);

        // Benchmark loop: each iter uses its own arena so we measure
        // the real per-call cost (allocation + transform).
        for (0..ITERATIONS) |i| {
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const t0 = nowNs();
            const result = try preproc.process(arena, c.input);
            const t1 = nowNs();
            std.mem.doNotOptimizeAway(result);
            times[i] = t1 - t0;
        }

        std.mem.sort(u64, times, {}, std.sort.asc(u64));
        const median_ns = times[ITERATIONS / 2];
        var sum: u128 = 0;
        for (times) |t| sum += t;
        const mean_ns: u64 = @intCast(sum / ITERATIONS);

        const median_us = @as(f64, @floatFromInt(median_ns)) / 1000.0;
        const mean_us = @as(f64, @floatFromInt(mean_ns)) / 1000.0;

        std.debug.print(
            "| {s} | {d} | {d:.2} | {d:.2} | `{s}` |\n",
            .{ c.name, c.input.len, median_us, mean_us, sample_out },
        );
    }
}
