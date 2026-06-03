// SPDX-License-Identifier: MIT OR Apache-2.0
// v0.3 queue: SQLite WAL-backed FIFO.
// v0.7 add: `engine TEXT NOT NULL DEFAULT 'say'` column, idempotent migration,
// propagated through push/list/pop and PoppedItem.
//
// Why SQLite instead of in-memory ArrayList:
//   - Survives daemon crash + reboot (was v0.2 gap)
//   - Enables `agent-tts queue` (read pending while worker drains)
//   - WAL mode = single-writer (worker) never blocks readers (queue cmd)
//
// Concurrency model:
//   - Single worker thread is the only writer of `state` transitions
//     pending → playing → done|skipped.
//   - daemon accept thread pushes new pending rows (also a writer, but
//     INSERT-only and short-lived; serialized via the SQLite file lock).
//   - QUEUE/SKIP/CLEAR ops execute on the daemon accept thread, mutate via
//     short-lived UPDATEs, and use `currently_playing` for live SIGTERM.
//
// SKIP race handling:
//   - `skipCurrent` updates state='skipped' WHERE id=playing.id AND state='playing'
//   - Then sends SIGTERM to the cached pid (best-effort; race-safe-ish because
//     pid recycling on macOS happens at multi-second timescales)
//   - Worker, after `say` exits, checks DB state of the just-played item:
//     if already 'skipped', leave it; else mark 'done'.
//   - The `currently_playing` cell is set/cleared under `mu` so a CLEAR or
//     SKIP that sees no row reports `OK\t0`.
//
// pop() blocks via std.Io.Condition when no pending rows exist. push()
// signals after INSERT.

const std = @import("std");
const ipc = @import("ipc.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

// SQLite needs a destructor hint on bind_text. SQLITE_TRANSIENT = -1 cast to
// a function pointer, which Zig refuses because of alignment. SQLITE_STATIC
// = null tells SQLite "data won't change during step" — that holds for us
// because text/voice live in either the read buffer or arena and the call
// chain (bind → step → finalize) is synchronous, single-threaded per stmt.
const sqlite_static: c.sqlite3_destructor_type = null;

pub const QueueError = error{
    DbOpen,
    DbExec,
    DbPrepare,
    DbStep,
    DbBind,
    OutOfMemory,
};

pub const State = enum {
    pending,
    playing,
    done,
    skipped,

    pub fn fromStr(s: []const u8) ?State {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "playing")) return .playing;
        if (std.mem.eql(u8, s, "done")) return .done;
        if (std.mem.eql(u8, s, "skipped")) return .skipped;
        return null;
    }

    pub fn str(s: State) []const u8 {
        return @tagName(s);
    }
};

pub const Item = struct {
    id: u64,
    state: State,
    engine: ipc.Engine,
    voice: []const u8,
    rate: u32,
    text: []const u8,
};

pub const PoppedItem = struct {
    id: u64,
    engine: ipc.Engine,
    voice: []u8,
    rate: u32,
    text: []u8,
};

const SCHEMA =
    \\CREATE TABLE IF NOT EXISTS items (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  text TEXT NOT NULL,
    \\  voice TEXT,
    \\  rate INTEGER,
    \\  state TEXT NOT NULL DEFAULT 'pending',
    \\  enqueued_at INTEGER NOT NULL,
    \\  started_at INTEGER,
    \\  finished_at INTEGER,
    \\  engine TEXT NOT NULL DEFAULT 'say'
    \\);
    \\CREATE INDEX IF NOT EXISTS items_pending_idx ON items(state, id) WHERE state IN ('pending','playing');
;

const Playing = struct {
    id: u64,
    pid: std.posix.pid_t,
};

pub const Queue = struct {
    arena: std.mem.Allocator,
    db: ?*c.sqlite3 = null,
    mu: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    closed: bool = false,
    playing: ?Playing = null,

    pub fn init(q: *Queue, db_path: []const u8) !void {
        // Need a null-terminated C string for sqlite3_open.
        var path_buf: [1024]u8 = undefined;
        if (db_path.len + 1 > path_buf.len) return error.DbOpen;
        @memcpy(path_buf[0..db_path.len], db_path);
        path_buf[db_path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_buf[0]);

        if (c.sqlite3_open(path_z, &q.db) != c.SQLITE_OK) return error.DbOpen;

        // WAL mode survives crash and lets readers (queue cmd) not block.
        try execSimple(q.db, "PRAGMA journal_mode=WAL;");
        try execSimple(q.db, "PRAGMA synchronous=NORMAL;");
        try execSimple(q.db, "PRAGMA foreign_keys=ON;");
        try execSimple(q.db, SCHEMA);

        // v0.7 migration: pre-v0.7 DBs lack the `engine` column. SQLite
        // doesn't accept `IF NOT EXISTS` inside ADD COLUMN, so probe via
        // PRAGMA table_info and ADD only when missing — idempotent across
        // multiple daemon starts.
        if (!try hasColumn(q.db, "items", "engine")) {
            try execSimple(q.db, "ALTER TABLE items ADD COLUMN engine TEXT NOT NULL DEFAULT 'say';");
        }

        // Crash recovery: any row left in 'playing' from a prior daemon run
        // belongs to a `say` that was killed by daemon death — re-queue it.
        try execSimple(q.db, "UPDATE items SET state='pending', started_at=NULL WHERE state='playing';");
    }

    pub fn deinit(q: *Queue) void {
        if (q.db) |db| {
            _ = c.sqlite3_close(db);
            q.db = null;
        }
    }

    // INSERT a new pending item. Returns its rowid. Wakes worker via cond.
    pub fn push(q: *Queue, io: std.Io, msg: ipc.Message) !u64 {
        try q.mu.lock(io);
        defer q.mu.unlock(io);

        const sql = "INSERT INTO items(text,voice,rate,state,enqueued_at,engine) VALUES (?,?,?,'pending',?,?);";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(q.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DbPrepare;
        defer _ = c.sqlite3_finalize(stmt);

        const engine_str = msg.engine.str();
        if (c.sqlite3_bind_text(stmt, 1, msg.text.ptr, @intCast(msg.text.len), sqlite_static) != c.SQLITE_OK) return error.DbBind;
        if (c.sqlite3_bind_text(stmt, 2, msg.voice.ptr, @intCast(msg.voice.len), sqlite_static) != c.SQLITE_OK) return error.DbBind;
        if (c.sqlite3_bind_int(stmt, 3, @intCast(msg.rate)) != c.SQLITE_OK) return error.DbBind;
        if (c.sqlite3_bind_int64(stmt, 4, nowEpoch(io)) != c.SQLITE_OK) return error.DbBind;
        if (c.sqlite3_bind_text(stmt, 5, engine_str.ptr, @intCast(engine_str.len), sqlite_static) != c.SQLITE_OK) return error.DbBind;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;

        const id: u64 = @intCast(c.sqlite3_last_insert_rowid(q.db));
        q.cond.signal(io);
        return id;
    }

    // Block until a pending row is available (or `closed`). Atomically flip it
    // to 'playing' and return the data. Caller owns `voice`/`text` buffers
    // (allocated from the daemon worker's GPA).
    pub fn pop(q: *Queue, io: std.Io, gpa: std.mem.Allocator) ?PoppedItem {
        q.mu.lockUncancelable(io);
        defer q.mu.unlock(io);

        while (true) {
            if (q.closed) return null;
            if (q.tryClaimNext(io, gpa)) |item| return item;
            q.cond.waitUncancelable(io, &q.mu);
        }
    }

    // Returns next pending row marked 'playing'. Must be called under `mu`.
    fn tryClaimNext(q: *Queue, io: std.Io, gpa: std.mem.Allocator) ?PoppedItem {
        const sql_sel = "SELECT id, voice, rate, text, engine FROM items WHERE state='pending' ORDER BY id ASC LIMIT 1;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(q.db, sql_sel, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);

        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_ROW) return null;

        const id: u64 = @intCast(c.sqlite3_column_int64(stmt, 0));
        const voice = colText(gpa, stmt, 1) catch return null;
        const rate: u32 = @intCast(c.sqlite3_column_int(stmt, 2));
        const text = colText(gpa, stmt, 3) catch {
            gpa.free(voice);
            return null;
        };
        // engine column is NOT NULL DEFAULT 'say' — but be defensive about
        // older rows that may have been inserted before the migration ran
        // in a corner case (shouldn't happen in practice since the ALTER
        // backfills with the default).
        const engine_buf = colText(gpa, stmt, 4) catch {
            gpa.free(voice);
            gpa.free(text);
            return null;
        };
        defer gpa.free(engine_buf);
        const engine = ipc.Engine.fromStr(engine_buf) orelse .say;

        const sql_upd = "UPDATE items SET state='playing', started_at=? WHERE id=?;";
        var ustmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(q.db, sql_upd, -1, &ustmt, null) != c.SQLITE_OK) {
            gpa.free(voice);
            gpa.free(text);
            return null;
        }
        defer _ = c.sqlite3_finalize(ustmt);
        _ = c.sqlite3_bind_int64(ustmt, 1, nowEpoch(io));
        _ = c.sqlite3_bind_int64(ustmt, 2, @intCast(id));
        if (c.sqlite3_step(ustmt) != c.SQLITE_DONE) {
            gpa.free(voice);
            gpa.free(text);
            return null;
        }

        return .{ .id = id, .engine = engine, .voice = voice, .rate = rate, .text = text };
    }

    // Worker calls after `say` finishes. If row is still 'playing', mark done.
    // If skipCurrent already flipped it to 'skipped', leave it.
    pub fn finishPlaying(q: *Queue, io: std.Io, id: u64) void {
        q.mu.lockUncancelable(io);
        defer q.mu.unlock(io);

        q.playing = null;

        const sql = "UPDATE items SET state='done', finished_at=? WHERE id=? AND state='playing';";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(q.db, sql, -1, &stmt, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, nowEpoch(io));
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(id));
        _ = c.sqlite3_step(stmt);
    }

    // Worker registers its child PID so SKIP can SIGTERM it.
    pub fn setPlaying(q: *Queue, io: std.Io, id: u64, pid: std.posix.pid_t) void {
        q.mu.lockUncancelable(io);
        defer q.mu.unlock(io);
        q.playing = .{ .id = id, .pid = pid };
    }

    // List pending + playing rows (snapshot). Allocates from `arena` so the
    // daemon's per-request arena owns the strings; safe to return raw slices.
    pub fn list(q: *Queue, io: std.Io, arena: std.mem.Allocator) ![]Item {
        q.mu.lockUncancelable(io);
        defer q.mu.unlock(io);

        const sql = "SELECT id, state, voice, rate, text, engine FROM items WHERE state IN ('pending','playing') ORDER BY id ASC;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(q.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DbPrepare;
        defer _ = c.sqlite3_finalize(stmt);

        var out: std.ArrayList(Item) = .empty;
        defer out.deinit(arena);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id: u64 = @intCast(c.sqlite3_column_int64(stmt, 0));
            const state_s = try colText(arena, stmt, 1);
            const voice = try colText(arena, stmt, 2);
            const rate: u32 = @intCast(c.sqlite3_column_int(stmt, 3));
            const text = try colText(arena, stmt, 4);
            const engine_s = try colText(arena, stmt, 5);
            try out.append(arena, .{
                .id = id,
                .state = State.fromStr(state_s) orelse .pending,
                .engine = ipc.Engine.fromStr(engine_s) orelse .say,
                .voice = voice,
                .rate = rate,
                .text = text,
            });
        }
        return out.toOwnedSlice(arena);
    }

    // Mark current playing as skipped + SIGTERM the child. Returns the id
    // that was skipped, or 0 if nothing is currently playing.
    pub fn skipCurrent(q: *Queue, io: std.Io) u64 {
        q.mu.lockUncancelable(io);
        defer q.mu.unlock(io);

        const p = q.playing orelse return 0;

        const sql = "UPDATE items SET state='skipped', finished_at=? WHERE id=? AND state='playing';";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(q.db, sql, -1, &stmt, null) != c.SQLITE_OK) return 0;
        _ = c.sqlite3_bind_int64(stmt, 1, nowEpoch(io));
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(p.id));
        const rc = c.sqlite3_step(stmt);
        _ = c.sqlite3_finalize(stmt);
        if (rc != c.SQLITE_DONE) return 0;

        // SIGTERM the `say` child. Worker's wait() will return Term.signal;
        // its finishPlaying() will see state='skipped' and not overwrite it.
        std.posix.kill(p.pid, .TERM) catch {};
        return p.id;
    }

    // Mark all pending as skipped. Does NOT touch the currently playing item
    // (use `skipCurrent` for that). Returns count affected.
    pub fn clearPending(q: *Queue, io: std.Io) u64 {
        q.mu.lockUncancelable(io);
        defer q.mu.unlock(io);

        const sql = "UPDATE items SET state='skipped', finished_at=? WHERE state='pending';";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(q.db, sql, -1, &stmt, null) != c.SQLITE_OK) return 0;
        _ = c.sqlite3_bind_int64(stmt, 1, nowEpoch(io));
        const rc = c.sqlite3_step(stmt);
        _ = c.sqlite3_finalize(stmt);
        if (rc != c.SQLITE_DONE) return 0;
        return @intCast(c.sqlite3_changes64(q.db));
    }

    pub fn close(q: *Queue, io: std.Io) void {
        q.mu.lockUncancelable(io);
        defer q.mu.unlock(io);
        q.closed = true;
        q.cond.broadcast(io);
    }

    pub fn pending(q: *Queue, io: std.Io) u64 {
        q.mu.lockUncancelable(io);
        defer q.mu.unlock(io);

        const sql = "SELECT COUNT(*) FROM items WHERE state='pending';";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(q.db, sql, -1, &stmt, null) != c.SQLITE_OK) return 0;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }
};

// ---- helpers ----

fn execSimple(db: ?*c.sqlite3, sql: [*c]const u8) !void {
    var err: [*c]u8 = null;
    if (c.sqlite3_exec(db, sql, null, null, &err) != c.SQLITE_OK) {
        if (err != null) c.sqlite3_free(err);
        return error.DbExec;
    }
}

fn colText(allocator: std.mem.Allocator, stmt: ?*c.sqlite3_stmt, col: c_int) ![]u8 {
    const ptr = c.sqlite3_column_text(stmt, col);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    const out = try allocator.alloc(u8, len);
    if (len > 0) @memcpy(out, ptr[0..len]);
    return out;
}

fn nowEpoch(io: std.Io) i64 {
    return std.Io.Clock.now(.real, io).toSeconds();
}

// Idempotent column probe via PRAGMA table_info. Returns true when `column`
// is present on `table`. PRAGMA outputs rows of (cid, name, type, notnull,
// dflt_value, pk); we scan the `name` column. Single-threaded call at boot.
fn hasColumn(db: ?*c.sqlite3, table: []const u8, column: []const u8) !bool {
    // PRAGMA arguments can't be bound; format the table name in. Safe here
    // because `table` is a code-defined literal, not user input.
    var buf: [256]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&buf, "PRAGMA table_info({s});", .{table}) catch return error.DbPrepare;

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const name_ptr = c.sqlite3_column_text(stmt, 1);
        const name_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        if (name_ptr == null or name_len == 0) continue;
        const name = name_ptr[0..name_len];
        if (std.mem.eql(u8, name, column)) return true;
    }
    return false;
}
