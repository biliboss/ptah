// SPDX-License-Identifier: MIT OR Apache-2.0
// `agent-tts stream` — incremental stdin → daemon sentence pipe (v1.7).
//
// Reads stdin in small chunks, feeds bytes into `preproc.IncrementalChunker`,
// forwards each completed sentence to the running daemon via the same
// `client.enqueueLine` helper the MCP server already uses.
//
// Why this exists. Today `agent-tts "text"` enqueues a single complete
// utterance. For a Claude Code reply being streamed token-by-token, that
// blocks audio until the assistant finishes thinking — the streaming
// advantage of the LLM is lost at the voice layer.
//
// Wire shape:
//   $ agent-tts stream [--engine X] [--voice V] [--rate R]
//   < bytes from stdin until EOF
//   > stderr: one diagnostic per chunk emitted ("[stream] enqueued id=N ...")
//   > exit 0 on EOF after flush, exit 2 on usage error, exit 1 on daemon error
//
// Pt-BR preprocessor (`preproc.process`) still runs per chunk on the daemon
// side — abbreviations + cardinals + `[[slnc]]` pauses. The streaming path
// is upstream of that, just splitting raw input into sentence-shaped enqueue
// messages.
//
// Read granularity: a small fixed read buffer (4 KB) is enough — the
// chunker amortizes input scanning, and stdin from an LLM rarely ships
// more than a token per kernel write anyway. Larger buffers would just
// keep more bytes in the chunker before the next read returns.

const std = @import("std");
const preproc = @import("preproc.zig");
const client = @import("client.zig");
const ipc = @import("ipc.zig");

const READ_BUF = 4 * 1024;

/// Entry point invoked from main when args[1] == "stream". `args` is the
/// full argv slice (args[0] = binary name, args[1] = "stream", rest =
/// optional flags).
pub fn run(arena: std.mem.Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    var engine: ipc.Engine = .piper;
    var voice_arg: ?[]const u8 = null;
    var rate: u32 = client.DEFAULT_RATE;

    var i: usize = 2; // skip args[0]=binary, args[1]="stream"
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--engine")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --engine needs value (say|piper)\n", .{});
                std.process.exit(2);
            }
            engine = ipc.Engine.fromStr(args[i]) orelse {
                std.debug.print("error: --engine invalid (got '{s}')\n", .{args[i]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--voice")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --voice needs value\n", .{});
                std.process.exit(2);
            }
            voice_arg = args[i];
        } else if (std.mem.eql(u8, a, "--rate")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --rate needs value\n", .{});
                std.process.exit(2);
            }
            rate = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("error: --rate invalid (got '{s}')\n", .{args[i]});
                std.process.exit(2);
            };
        } else {
            std.debug.print("error: unknown arg '{s}' (stream takes only --engine/--voice/--rate)\n", .{a});
            std.process.exit(2);
        }
    }

    const voice: []const u8 = voice_arg orelse switch (engine) {
        .say => client.DEFAULT_VOICE,
        .piper => "faber",
        .cloned => "",
    };

    var chunker: preproc.IncrementalChunker = .{};
    defer chunker.deinit(arena);

    var read_buf: [READ_BUF]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &read_buf);
    const r = &stdin.interface;

    var n_chunks: u32 = 0;
    // We use `readSliceShort` (returns 0 on EOF, no error) instead of the
    // delimiter helpers because an LLM stream pushes partial tokens that
    // rarely line up with '\n'. The chunker owns the sentence-boundary
    // detection; the reader only needs to keep pulling bytes.
    var byte_scratch: [READ_BUF]u8 = undefined;
    while (true) {
        const n = try r.readSliceShort(byte_scratch[0..]);
        if (n == 0) break;
        const emitted = try chunker.feed(arena, byte_scratch[0..n]);
        for (emitted) |chunk| {
            try forwardChunk(arena, io, home, engine, voice, rate, chunk.text);
            n_chunks += 1;
        }
    }

    // Final flush: emit any remainder (no trailing terminator from stdin).
    const tail = try chunker.flush(arena);
    for (tail) |chunk| {
        try forwardChunk(arena, io, home, engine, voice, rate, chunk.text);
        n_chunks += 1;
    }

    std.debug.print("[stream] EOF — {d} chunk(s) enqueued\n", .{n_chunks});
}

fn forwardChunk(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    engine: ipc.Engine,
    voice: []const u8,
    rate: u32,
    text: []const u8,
) !void {
    const id_str = client.enqueueLine(arena, io, home, engine, voice, rate, text) catch |e| switch (e) {
        error.DaemonUnreachable => {
            std.debug.print(
                "error: cannot reach daemon. start with: agent-tts daemon\n",
                .{},
            );
            std.process.exit(1);
        },
        error.DaemonError => {
            std.debug.print("error: daemon error on chunk '{s}'\n", .{text});
            std.process.exit(1);
        },
        error.UnexpectedResponse => {
            std.debug.print("error: daemon unexpected response on chunk '{s}'\n", .{text});
            std.process.exit(1);
        },
        else => return e,
    };
    std.debug.print("[stream] enqueued id={s} text='{s}'\n", .{ id_str, text });
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------
//
// The CLI path is hard to test without spawning a process + daemon. We
// cover the boundary detection in `preproc.IncrementalChunker` (own tests)
// and the wire forwarding in `client.enqueueLine` (own tests). What we
// test here is that the chunker integration drains a multi-sentence
// input into the expected list of chunks — same logic the runtime path
// exercises.

const testing = std.testing;

test "stream integration: feeds drain into expected chunks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var chunker: preproc.IncrementalChunker = .{};
    defer chunker.deinit(arena);

    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(arena);

    const feeds = [_][]const u8{
        "Hello. Wor",
        "ld. ",
        "Mais uma frase aqui.",
    };
    for (feeds) |f| {
        const got = try chunker.feed(arena, f);
        for (got) |c| try all.append(arena, c.text);
    }
    const tail = try chunker.flush(arena);
    for (tail) |c| try all.append(arena, c.text);

    try testing.expectEqual(@as(usize, 3), all.items.len);
    try testing.expectEqualStrings("Hello.", all.items[0]);
    try testing.expectEqualStrings("World.", all.items[1]);
    try testing.expectEqualStrings("Mais uma frase aqui.", all.items[2]);
}
