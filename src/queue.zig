// SPDX-License-Identifier: MIT OR Apache-2.0
// v0.3 queue: SQLite WAL-backed FIFO.
// v0.7 add: `engine TEXT NOT NULL DEFAULT 'say'` column, idempotent migration,
// propagated through push/list/pop and PoppedItem.
//
// Why SQLite instead of in-memory ArrayList:
//   - Survives daemon crash + reboot (was v0.2 gap)
//   - Enables `ptah queue` (read pending while worker drains)
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
    /// v1.8 — input contains W3C SSML 1.1 markup. Persisted on the row
    /// so daemon restarts don't lose the flag while items are pending.
    ssml: bool = false,
    /// v1.10.7 — per-call piper inference knobs. Sentinels match
    /// `ipc.Message`: length_scale=0.0 / noise_scale<0 / noise_w<0 means
    /// "use voice/env/built-in default".
    length_scale: f32 = 0.0,
    noise_scale: f32 = -1.0,
    noise_w: f32 = -1.0,
    /// v1.10.8 — tech-report mode toggle. Carried so the worker can pick
    /// `preproc.processTechWithPauses` over the v0.5 path.
    tech: bool = false,
    /// v1.10.8 — per-call pause overrides. 0 = use defaults from
    /// `preproc.Pause`. Worker bundles them into a `preproc.Pauses`.
    comma_pause_ms: u32 = 0,
    sentence_pause_ms: u32 = 0,
    newline_pause_ms: u32 = 0,
    /// v1.10.8 — Piper multi-speaker id; -1 = use voice config default.
    speaker_id: i32 = -1,
    /// v1.10.10 — audio post-fx profile. Daemon routes PCM through
    /// `postfx.apply` before zaudio playback when non-`.off`.
    postfx: ipc.Postfx = .off,
    text: []u8,
};

/// v1.10.2 — one row returned by `history`. Mirrors PoppedItem but
/// includes the terminal state and finish timestamp so the menubar/client
/// can render a played-history list. `lang` defaults to .auto on read
/// because we don't persist it (queue.zig has never written that column).
pub const HistoryItem = struct {
    id: u64,
    state: State,
    engine: ipc.Engine,
    voice: []const u8,
    rate: u32,
    /// Seconds since epoch (the `finished_at` column). 0 when the item is
    /// still pending/playing (HISTORY includes those too for live UI).
    finished_at: i64,
    text: []const u8,
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
    \\  engine TEXT NOT NULL DEFAULT 'say',
    \\  ssml INTEGER NOT NULL DEFAULT 0,
    \\  length_scale REAL,
    \\  noise_scale REAL,
    \\  noise_w REAL,
    \\  tech INTEGER,
    \\  comma_pause_ms INTEGER,
    \\  sentence_pause_ms INTEGER,
    \\  newline_pause_ms INTEGER,
    \\  speaker_id INTEGER,
    \\  postfx TEXT
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

        // v1.8 migration: pre-v1.8 DBs lack the `ssml` column. Same
        // probe/ADD idempotency as the engine column above.
        if (!try hasColumn(q.db, "items", "ssml")) {
            try execSimple(q.db, "ALTER TABLE items ADD COLUMN ssml INTEGER NOT NULL DEFAULT 0;");
        }

        // v1.10.7 migration: pre-v1.10.7 DBs lack the per-call piper knob
        // columns. NULL is the sentinel for "use voice/env default" so we
        // don't backfill — the worker treats NULL/missing the same as
        // ipc.Message's zero/negative sentinels.
        if (!try hasColumn(q.db, "items", "length_scale")) {
            try execSimple(q.db, "ALTER TABLE items ADD COLUMN length_scale REAL;");
        }
        if (!try hasColumn(q.db, "items", "noise_scale")) {
            try execSimple(q.db, "ALTER TABLE items ADD COLUMN noise_scale REAL;");
        }
        if (!try hasColumn(q.db, "items", "noise_w")) {
            try execSimple(q.db, "ALTER TABLE items ADD COLUMN noise_w REAL;");
        }

        // v1.10.8 migration: tech / pause-overrides / speaker_id columns.
        // NULL = unset across the board; worker treats NULL identically to
        // the ipc.Message defaults.
        if (!try hasColumn(q.db, "items", "tech")) {
            try execSimple(q.db, "ALTER TABLE items ADD COLUMN tech INTEGER;");
        }
        if (!try hasColumn(q.db, "items", "comma_pause_ms")) {
            try execSimple(q.db, "ALTER TABLE items ADD COLUMN comma_pause_ms INTEGER;");
        }
        if (!try hasColumn(q.db, "items", "sentence_pause_ms")) {
            try execSimple(q.db, "ALTER TABLE items ADD COLUMN sentence_pause_ms INTEGER;");
        }
        if (!try hasColumn(q.db, "items", "newline_pause_ms")) {
            try execSimple(q.db, "ALTER TABLE items ADD COLUMN newline_pause_ms INTEGER;");
        }
        if (!try hasColumn(q.db, "items", "speaker_id")) {
            try execSimple(q.db, "ALTER TABLE items ADD COLUMN speaker_id INTEGER;");
        }

        // v1.10.10 migration: postfx TEXT column. NULL = .off (default
        // pass-through). Worker maps NULL/unknown back to .off so a
        // bogus value can never wedge the device pump.
        if (!try hasColumn(q.db, "items", "postfx")) {
            try execSimple(q.db, "ALTER TABLE items ADD COLUMN postfx TEXT;");
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

        const sql = "INSERT INTO items(text,voice,rate,state,enqueued_at,engine,ssml,length_scale,noise_scale,noise_w,tech,comma_pause_ms,sentence_pause_ms,newline_pause_ms,speaker_id,postfx) VALUES (?,?,?,'pending',?,?,?,?,?,?,?,?,?,?,?,?);";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(q.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DbPrepare;
        defer _ = c.sqlite3_finalize(stmt);

        const engine_str = msg.engine.str();
        if (c.sqlite3_bind_text(stmt, 1, msg.text.ptr, @intCast(msg.text.len), sqlite_static) != c.SQLITE_OK) return error.DbBind;
        if (c.sqlite3_bind_text(stmt, 2, msg.voice.ptr, @intCast(msg.voice.len), sqlite_static) != c.SQLITE_OK) return error.DbBind;
        if (c.sqlite3_bind_int(stmt, 3, @intCast(msg.rate)) != c.SQLITE_OK) return error.DbBind;
        if (c.sqlite3_bind_int64(stmt, 4, nowEpoch(io)) != c.SQLITE_OK) return error.DbBind;
        if (c.sqlite3_bind_text(stmt, 5, engine_str.ptr, @intCast(engine_str.len), sqlite_static) != c.SQLITE_OK) return error.DbBind;
        if (c.sqlite3_bind_int(stmt, 6, if (msg.ssml) 1 else 0) != c.SQLITE_OK) return error.DbBind;
        // v1.10.7 — bind NULL for sentinels so the row stays neutral when
        // the caller didn't set the knob. Worker treats NULL identically to
        // the in-memory ipc.Message defaults.
        if (msg.length_scale > 0) {
            if (c.sqlite3_bind_double(stmt, 7, @floatCast(msg.length_scale)) != c.SQLITE_OK) return error.DbBind;
        } else {
            if (c.sqlite3_bind_null(stmt, 7) != c.SQLITE_OK) return error.DbBind;
        }
        if (msg.noise_scale >= 0) {
            if (c.sqlite3_bind_double(stmt, 8, @floatCast(msg.noise_scale)) != c.SQLITE_OK) return error.DbBind;
        } else {
            if (c.sqlite3_bind_null(stmt, 8) != c.SQLITE_OK) return error.DbBind;
        }
        if (msg.noise_w >= 0) {
            if (c.sqlite3_bind_double(stmt, 9, @floatCast(msg.noise_w)) != c.SQLITE_OK) return error.DbBind;
        } else {
            if (c.sqlite3_bind_null(stmt, 9) != c.SQLITE_OK) return error.DbBind;
        }
        // v1.10.8 — bind the extras. NULL when the caller left them at
        // sentinels so the column stays "unset" through queue dumps + replays.
        if (msg.tech) {
            if (c.sqlite3_bind_int(stmt, 10, 1) != c.SQLITE_OK) return error.DbBind;
        } else {
            if (c.sqlite3_bind_null(stmt, 10) != c.SQLITE_OK) return error.DbBind;
        }
        if (msg.comma_pause_ms != 0) {
            if (c.sqlite3_bind_int(stmt, 11, @intCast(msg.comma_pause_ms)) != c.SQLITE_OK) return error.DbBind;
        } else {
            if (c.sqlite3_bind_null(stmt, 11) != c.SQLITE_OK) return error.DbBind;
        }
        if (msg.sentence_pause_ms != 0) {
            if (c.sqlite3_bind_int(stmt, 12, @intCast(msg.sentence_pause_ms)) != c.SQLITE_OK) return error.DbBind;
        } else {
            if (c.sqlite3_bind_null(stmt, 12) != c.SQLITE_OK) return error.DbBind;
        }
        if (msg.newline_pause_ms != 0) {
            if (c.sqlite3_bind_int(stmt, 13, @intCast(msg.newline_pause_ms)) != c.SQLITE_OK) return error.DbBind;
        } else {
            if (c.sqlite3_bind_null(stmt, 13) != c.SQLITE_OK) return error.DbBind;
        }
        if (msg.speaker_id >= 0) {
            if (c.sqlite3_bind_int(stmt, 14, @intCast(msg.speaker_id)) != c.SQLITE_OK) return error.DbBind;
        } else {
            if (c.sqlite3_bind_null(stmt, 14) != c.SQLITE_OK) return error.DbBind;
        }
        // v1.10.10 — postfx column. NULL when the caller left it at
        // the default (.off) so default rows stay neutral.
        if (msg.postfx != .off) {
            const pfx_str = msg.postfx.str();
            if (c.sqlite3_bind_text(stmt, 15, pfx_str.ptr, @intCast(pfx_str.len), sqlite_static) != c.SQLITE_OK) return error.DbBind;
        } else {
            if (c.sqlite3_bind_null(stmt, 15) != c.SQLITE_OK) return error.DbBind;
        }
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
        const sql_sel = "SELECT id, voice, rate, text, engine, ssml, length_scale, noise_scale, noise_w, tech, comma_pause_ms, sentence_pause_ms, newline_pause_ms, speaker_id, postfx FROM items WHERE state='pending' ORDER BY id ASC LIMIT 1;";
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
        const engine = ipc.Engine.fromStr(engine_buf) orelse .kokoro;
        const ssml_flag: bool = c.sqlite3_column_int(stmt, 5) != 0;

        // v1.10.7 — read NULL-aware. column_type==NULL maps to the
        // sentinel; otherwise pull the REAL value.
        const length_scale: f32 = blk: {
            if (c.sqlite3_column_type(stmt, 6) == c.SQLITE_NULL) break :blk 0.0;
            break :blk @floatCast(c.sqlite3_column_double(stmt, 6));
        };
        const noise_scale: f32 = blk: {
            if (c.sqlite3_column_type(stmt, 7) == c.SQLITE_NULL) break :blk -1.0;
            break :blk @floatCast(c.sqlite3_column_double(stmt, 7));
        };
        const noise_w: f32 = blk: {
            if (c.sqlite3_column_type(stmt, 8) == c.SQLITE_NULL) break :blk -1.0;
            break :blk @floatCast(c.sqlite3_column_double(stmt, 8));
        };
        // v1.10.8 — extras. NULL → ipc.Message defaults.
        const tech: bool = blk: {
            if (c.sqlite3_column_type(stmt, 9) == c.SQLITE_NULL) break :blk false;
            break :blk c.sqlite3_column_int(stmt, 9) != 0;
        };
        const comma_ms: u32 = blk: {
            if (c.sqlite3_column_type(stmt, 10) == c.SQLITE_NULL) break :blk 0;
            break :blk @intCast(c.sqlite3_column_int(stmt, 10));
        };
        const sentence_ms: u32 = blk: {
            if (c.sqlite3_column_type(stmt, 11) == c.SQLITE_NULL) break :blk 0;
            break :blk @intCast(c.sqlite3_column_int(stmt, 11));
        };
        const newline_ms: u32 = blk: {
            if (c.sqlite3_column_type(stmt, 12) == c.SQLITE_NULL) break :blk 0;
            break :blk @intCast(c.sqlite3_column_int(stmt, 12));
        };
        const speaker_id: i32 = blk: {
            if (c.sqlite3_column_type(stmt, 13) == c.SQLITE_NULL) break :blk -1;
            break :blk @intCast(c.sqlite3_column_int(stmt, 13));
        };
        // v1.10.10 — postfx column. NULL → .off (default). Unknown
        // strings fall back to .off too so a corrupted/legacy value
        // can never wedge the device pump.
        const postfx_val: ipc.Postfx = blk: {
            if (c.sqlite3_column_type(stmt, 14) == c.SQLITE_NULL) break :blk .off;
            const ptr = c.sqlite3_column_text(stmt, 14);
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 14));
            if (ptr == null or len == 0) break :blk .off;
            const txt = ptr[0..len];
            break :blk ipc.Postfx.fromStr(txt) orelse .off;
        };

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

        return .{
            .id = id,
            .engine = engine,
            .voice = voice,
            .rate = rate,
            .ssml = ssml_flag,
            .length_scale = length_scale,
            .noise_scale = noise_scale,
            .noise_w = noise_w,
            .tech = tech,
            .comma_pause_ms = comma_ms,
            .sentence_pause_ms = sentence_ms,
            .newline_pause_ms = newline_ms,
            .speaker_id = speaker_id,
            .postfx = postfx_val,
            .text = text,
        };
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
                .engine = ipc.Engine.fromStr(engine_s) orelse .kokoro,
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

    /// v1.10.2 — SELECT the last `limit` rows regardless of state. Most
    /// recent first. Used by the new `HISTORY` IPC op and the `ptah
    /// history` client subcommand. Slices live in `arena` so callers can
    /// release everything by dropping the arena.
    ///
    /// We clamp `limit` at 100 to keep the worst-case response a few KB,
    /// matching the daemon's WRITE_BUF budget. The IPC layer re-applies
    /// this clamp at parse time but having it here too keeps the function
    /// safe when called from tests without IPC.
    pub fn history(q: *Queue, io: std.Io, arena: std.mem.Allocator, limit: usize) ![]HistoryItem {
        q.mu.lockUncancelable(io);
        defer q.mu.unlock(io);

        const clamped: usize = if (limit == 0) 20 else @min(limit, 100);

        // SELECT in DESC order (newest first); the client/menubar render
        // top-to-bottom. LIMIT is bound rather than substituted so the
        // statement plan cache stays warm across calls.
        const sql = "SELECT id, state, voice, rate, text, engine, COALESCE(finished_at, 0) FROM items ORDER BY id DESC LIMIT ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(q.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DbPrepare;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int64(stmt, 1, @intCast(clamped)) != c.SQLITE_OK) return error.DbBind;

        var out: std.ArrayList(HistoryItem) = .empty;
        defer out.deinit(arena);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id: u64 = @intCast(c.sqlite3_column_int64(stmt, 0));
            const state_s = try colText(arena, stmt, 1);
            const voice = try colText(arena, stmt, 2);
            const rate: u32 = @intCast(c.sqlite3_column_int(stmt, 3));
            const text = try colText(arena, stmt, 4);
            const engine_s = try colText(arena, stmt, 5);
            const finished_at: i64 = c.sqlite3_column_int64(stmt, 6);
            try out.append(arena, .{
                .id = id,
                .state = State.fromStr(state_s) orelse .done,
                .engine = ipc.Engine.fromStr(engine_s) orelse .kokoro,
                .voice = voice,
                .rate = rate,
                .finished_at = finished_at,
                .text = text,
            });
        }
        return out.toOwnedSlice(arena);
    }

    /// v1.10.2 — replay item `src_id`: INSERT a copy with the same engine /
    /// voice / rate / ssml / text but state='pending' and a fresh
    /// enqueued_at. Returns the new id, or null when no row matches.
    /// Signals the worker so it picks up the new pending item immediately.
    ///
    /// Implementation is a SELECT → INSERT pair rather than `INSERT … SELECT`
    /// so we can capture the source row first (and return null cleanly
    /// when missing). Both steps happen under `q.mu` so a concurrent
    /// clearPending can't yank the row mid-copy.
    pub fn replay(q: *Queue, io: std.Io, gpa: std.mem.Allocator, src_id: u64) !?u64 {
        q.mu.lockUncancelable(io);
        defer q.mu.unlock(io);

        // Look up source row.
        const sql_sel = "SELECT text, voice, rate, engine, ssml, length_scale, noise_scale, noise_w, tech, comma_pause_ms, sentence_pause_ms, newline_pause_ms, speaker_id, postfx FROM items WHERE id=?;";
        var sel: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(q.db, sql_sel, -1, &sel, null) != c.SQLITE_OK) return error.DbPrepare;
        defer _ = c.sqlite3_finalize(sel);
        if (c.sqlite3_bind_int64(sel, 1, @intCast(src_id)) != c.SQLITE_OK) return error.DbBind;

        const rc = c.sqlite3_step(sel);
        if (rc != c.SQLITE_ROW) return null;

        const text = try colText(gpa, sel, 0);
        defer gpa.free(text);
        const voice = try colText(gpa, sel, 1);
        defer gpa.free(voice);
        const rate: u32 = @intCast(c.sqlite3_column_int(sel, 2));
        const engine_buf = try colText(gpa, sel, 3);
        defer gpa.free(engine_buf);
        const ssml_flag: c_int = c.sqlite3_column_int(sel, 4);
        // v1.10.7 — preserve per-call knobs on replay. NULL stays NULL so a
        // replayed item with default knobs doesn't accidentally bind 0.0.
        const length_scale_null = c.sqlite3_column_type(sel, 5) == c.SQLITE_NULL;
        const length_scale_val: f64 = if (length_scale_null) 0 else c.sqlite3_column_double(sel, 5);
        const noise_scale_null = c.sqlite3_column_type(sel, 6) == c.SQLITE_NULL;
        const noise_scale_val: f64 = if (noise_scale_null) 0 else c.sqlite3_column_double(sel, 6);
        const noise_w_null = c.sqlite3_column_type(sel, 7) == c.SQLITE_NULL;
        const noise_w_val: f64 = if (noise_w_null) 0 else c.sqlite3_column_double(sel, 7);
        // v1.10.8 — extras: tech / pause overrides / speaker_id.
        const tech_null = c.sqlite3_column_type(sel, 8) == c.SQLITE_NULL;
        const tech_val: c_int = if (tech_null) 0 else c.sqlite3_column_int(sel, 8);
        const comma_null = c.sqlite3_column_type(sel, 9) == c.SQLITE_NULL;
        const comma_val: c_int = if (comma_null) 0 else c.sqlite3_column_int(sel, 9);
        const sentence_null = c.sqlite3_column_type(sel, 10) == c.SQLITE_NULL;
        const sentence_val: c_int = if (sentence_null) 0 else c.sqlite3_column_int(sel, 10);
        const newline_null = c.sqlite3_column_type(sel, 11) == c.SQLITE_NULL;
        const newline_val: c_int = if (newline_null) 0 else c.sqlite3_column_int(sel, 11);
        const speaker_null = c.sqlite3_column_type(sel, 12) == c.SQLITE_NULL;
        const speaker_val: c_int = if (speaker_null) 0 else c.sqlite3_column_int(sel, 12);
        // v1.10.10 — postfx column. NULL preserved as NULL through replay.
        const postfx_null = c.sqlite3_column_type(sel, 13) == c.SQLITE_NULL;
        const postfx_text: ?[]const u8 = blk: {
            if (postfx_null) break :blk null;
            const ptr = c.sqlite3_column_text(sel, 13);
            const len: usize = @intCast(c.sqlite3_column_bytes(sel, 13));
            if (ptr == null or len == 0) break :blk null;
            break :blk ptr[0..len];
        };

        // INSERT the copy.
        const sql_ins = "INSERT INTO items(text,voice,rate,state,enqueued_at,engine,ssml,length_scale,noise_scale,noise_w,tech,comma_pause_ms,sentence_pause_ms,newline_pause_ms,speaker_id,postfx) VALUES (?,?,?,'pending',?,?,?,?,?,?,?,?,?,?,?,?);";
        var ins: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(q.db, sql_ins, -1, &ins, null) != c.SQLITE_OK) return error.DbPrepare;
        defer _ = c.sqlite3_finalize(ins);

        if (c.sqlite3_bind_text(ins, 1, text.ptr, @intCast(text.len), sqlite_static) != c.SQLITE_OK) return error.DbBind;
        if (c.sqlite3_bind_text(ins, 2, voice.ptr, @intCast(voice.len), sqlite_static) != c.SQLITE_OK) return error.DbBind;
        if (c.sqlite3_bind_int(ins, 3, @intCast(rate)) != c.SQLITE_OK) return error.DbBind;
        if (c.sqlite3_bind_int64(ins, 4, nowEpoch(io)) != c.SQLITE_OK) return error.DbBind;
        if (c.sqlite3_bind_text(ins, 5, engine_buf.ptr, @intCast(engine_buf.len), sqlite_static) != c.SQLITE_OK) return error.DbBind;
        if (c.sqlite3_bind_int(ins, 6, ssml_flag) != c.SQLITE_OK) return error.DbBind;
        if (length_scale_null) {
            if (c.sqlite3_bind_null(ins, 7) != c.SQLITE_OK) return error.DbBind;
        } else if (c.sqlite3_bind_double(ins, 7, length_scale_val) != c.SQLITE_OK) return error.DbBind;
        if (noise_scale_null) {
            if (c.sqlite3_bind_null(ins, 8) != c.SQLITE_OK) return error.DbBind;
        } else if (c.sqlite3_bind_double(ins, 8, noise_scale_val) != c.SQLITE_OK) return error.DbBind;
        if (noise_w_null) {
            if (c.sqlite3_bind_null(ins, 9) != c.SQLITE_OK) return error.DbBind;
        } else if (c.sqlite3_bind_double(ins, 9, noise_w_val) != c.SQLITE_OK) return error.DbBind;
        if (tech_null) {
            if (c.sqlite3_bind_null(ins, 10) != c.SQLITE_OK) return error.DbBind;
        } else if (c.sqlite3_bind_int(ins, 10, tech_val) != c.SQLITE_OK) return error.DbBind;
        if (comma_null) {
            if (c.sqlite3_bind_null(ins, 11) != c.SQLITE_OK) return error.DbBind;
        } else if (c.sqlite3_bind_int(ins, 11, comma_val) != c.SQLITE_OK) return error.DbBind;
        if (sentence_null) {
            if (c.sqlite3_bind_null(ins, 12) != c.SQLITE_OK) return error.DbBind;
        } else if (c.sqlite3_bind_int(ins, 12, sentence_val) != c.SQLITE_OK) return error.DbBind;
        if (newline_null) {
            if (c.sqlite3_bind_null(ins, 13) != c.SQLITE_OK) return error.DbBind;
        } else if (c.sqlite3_bind_int(ins, 13, newline_val) != c.SQLITE_OK) return error.DbBind;
        if (speaker_null) {
            if (c.sqlite3_bind_null(ins, 14) != c.SQLITE_OK) return error.DbBind;
        } else if (c.sqlite3_bind_int(ins, 14, speaker_val) != c.SQLITE_OK) return error.DbBind;
        if (postfx_text) |pfx| {
            if (c.sqlite3_bind_text(ins, 15, pfx.ptr, @intCast(pfx.len), sqlite_static) != c.SQLITE_OK) return error.DbBind;
        } else {
            if (c.sqlite3_bind_null(ins, 15) != c.SQLITE_OK) return error.DbBind;
        }
        if (c.sqlite3_step(ins) != c.SQLITE_DONE) return error.DbStep;

        const new_id: u64 = @intCast(c.sqlite3_last_insert_rowid(q.db));
        q.cond.signal(io);
        return new_id;
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
