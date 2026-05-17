const std = @import("std");
const c = @cImport(@cInclude("sqlite3.h"));
const preview = @import("preview.zig");

const global_io = std.Options.debug_io;

pub const Error = error{ Open, Exec, Prepare, Bind, Step, NotFound };

const SQLITE_STATIC: c.sqlite3_destructor_type = null;
const SQLITE_TRANSIENT: c.sqlite3_destructor_type = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

fn ensureDir(path: []const u8) void {
    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.createDirPath(.cwd(), global_io, parent) catch {};
    }
}

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Db {
        ensureDir(path);

        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(
            path_z,
            &handle,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
            null,
        );
        if (rc != c.SQLITE_OK or handle == null) return Error.Open;

        const db = Db{ .handle = handle.? };
        try db.initSchema();
        return db;
    }

    pub fn close(self: *const Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    fn exec(self: *const Db, sql: [*:0]const u8) !void {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql, null, null, &errmsg);
        if (errmsg != null) c.sqlite3_free(errmsg);
        if (rc != c.SQLITE_OK) return Error.Exec;
    }

    fn initSchema(self: *const Db) !void {
        try self.exec("PRAGMA journal_mode=WAL");
        try self.exec("PRAGMA synchronous=NORMAL");
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS items (
            \\    id         INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    data       BLOB    NOT NULL,
            \\    created_at INTEGER NOT NULL,
            \\    expires_at INTEGER,
            \\    size       INTEGER NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_created_at ON items(created_at DESC);
            \\CREATE INDEX IF NOT EXISTS idx_expires_at ON items(expires_at)
            \\    WHERE expires_at IS NOT NULL;
        );
    }

    pub fn purgeExpired(self: *const Db) !void {
        try self.exec("DELETE FROM items WHERE expires_at IS NOT NULL AND expires_at < unixepoch()");
    }

    pub fn store(
        self: *const Db,
        allocator: std.mem.Allocator,
        data: []const u8,
        expires_at: ?i64,
        max_items: u64,
        max_dedupe: u64,
    ) !i64 {
        try self.purgeExpired();
        try self.deleteDupe(allocator, data, max_dedupe);

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(
            self.handle,
            "INSERT INTO items (data, created_at, expires_at, size) VALUES (?, unixepoch(), ?, ?)",
            -1,
            &stmt,
            null,
        );
        if (rc != c.SQLITE_OK) return Error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);

        rc = c.sqlite3_bind_blob(stmt, 1, data.ptr, @intCast(data.len), SQLITE_STATIC);
        if (rc != c.SQLITE_OK) return Error.Bind;

        if (expires_at) |exp| {
            rc = c.sqlite3_bind_int64(stmt, 2, exp);
        } else {
            rc = c.sqlite3_bind_null(stmt, 2);
        }
        if (rc != c.SQLITE_OK) return Error.Bind;

        rc = c.sqlite3_bind_int64(stmt, 3, @intCast(data.len));
        if (rc != c.SQLITE_OK) return Error.Bind;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.Step;

        const id = c.sqlite3_last_insert_rowid(self.handle);
        try self.trimToMax(max_items);
        return id;
    }

    fn deleteDupe(self: *const Db, allocator: std.mem.Allocator, data: []const u8, max_dedupe: u64) !void {
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(
            self.handle,
            "SELECT id, data FROM items ORDER BY created_at DESC LIMIT ?",
            -1,
            &stmt,
            null,
        );
        if (rc != c.SQLITE_OK) return Error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);

        rc = c.sqlite3_bind_int64(stmt, 1, @intCast(max_dedupe));
        if (rc != c.SQLITE_OK) return Error.Bind;

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id = c.sqlite3_column_int64(stmt, 0);
            const blob_ptr = c.sqlite3_column_blob(stmt, 1);
            const blob_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
            if (blob_ptr == null) continue;
            const row_data: []const u8 = @as([*]const u8, @ptrCast(blob_ptr))[0..blob_len];
            if (std.mem.eql(u8, row_data, data)) {
                try self.deleteById(allocator, id);
                return;
            }
        }
    }

    fn trimToMax(self: *const Db, max_items: u64) !void {
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(
            self.handle,
            "DELETE FROM items WHERE id IN (SELECT id FROM items ORDER BY created_at DESC LIMIT -1 OFFSET ?)",
            -1,
            &stmt,
            null,
        );
        if (rc != c.SQLITE_OK) return Error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);

        rc = c.sqlite3_bind_int64(stmt, 1, @intCast(max_items));
        if (rc != c.SQLITE_OK) return Error.Bind;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.Step;
    }

    pub fn list(self: *const Db, allocator: std.mem.Allocator, preview_width: u64) !void {
        try self.purgeExpired();

        var write_buf: [65536]u8 = undefined;
        var writer = std.Io.File.writer(.stdout(), global_io, &write_buf);

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.handle,
            "SELECT id, data FROM items ORDER BY created_at DESC, id DESC",
            -1,
            &stmt,
            null,
        );
        if (rc != c.SQLITE_OK) return Error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id = c.sqlite3_column_int64(stmt, 0);
            const blob_ptr = c.sqlite3_column_blob(stmt, 1);
            const blob_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
            if (blob_ptr == null) continue;
            const data: []const u8 = @as([*]const u8, @ptrCast(blob_ptr))[0..blob_len];

            const line = try preview.generate(allocator, id, data, preview_width);
            defer allocator.free(line);
            try writer.interface.writeAll(line);
            try writer.interface.writeAll("\n");
        }

        try writer.interface.flush();
    }

    pub fn decodeToStdout(self: *const Db, allocator: std.mem.Allocator, id: i64) !void {
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(
            self.handle,
            "SELECT data FROM items WHERE id = ?",
            -1,
            &stmt,
            null,
        );
        if (rc != c.SQLITE_OK) return Error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);

        rc = c.sqlite3_bind_int64(stmt, 1, id);
        if (rc != c.SQLITE_OK) return Error.Bind;

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return Error.NotFound;

        const blob_ptr = c.sqlite3_column_blob(stmt, 0);
        const blob_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        if (blob_ptr == null) return Error.NotFound;

        const data: []const u8 = @as([*]const u8, @ptrCast(blob_ptr))[0..blob_len];
        const copy = try allocator.dupe(u8, data);
        defer allocator.free(copy);

        try std.Io.File.writeStreamingAll(.stdout(), global_io, copy);
    }

    pub fn deleteById(self: *const Db, allocator: std.mem.Allocator, id: i64) !void {
        _ = allocator;
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(
            self.handle,
            "DELETE FROM items WHERE id = ?",
            -1,
            &stmt,
            null,
        );
        if (rc != c.SQLITE_OK) return Error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);

        rc = c.sqlite3_bind_int64(stmt, 1, id);
        if (rc != c.SQLITE_OK) return Error.Bind;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.Step;
    }

    pub fn deleteByQuery(self: *const Db, query: []const u8) !void {
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(
            self.handle,
            "DELETE FROM items WHERE instr(data, ?) > 0",
            -1,
            &stmt,
            null,
        );
        if (rc != c.SQLITE_OK) return Error.Prepare;
        defer _ = c.sqlite3_finalize(stmt);

        rc = c.sqlite3_bind_blob(stmt, 1, query.ptr, @intCast(query.len), SQLITE_STATIC);
        if (rc != c.SQLITE_OK) return Error.Bind;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return Error.Step;
    }

    pub fn wipe(self: *const Db) !void {
        try self.exec("DELETE FROM items");
        try self.exec("VACUUM");
    }

    pub fn compact(self: *const Db) !void {
        try self.exec("VACUUM");
    }

    pub fn cleanup(self: *const Db) !void {
        try self.purgeExpired();
    }

    pub fn deleteMostRecent(self: *const Db) !void {
        try self.exec(
            "DELETE FROM items WHERE id = (SELECT id FROM items ORDER BY created_at DESC, id DESC LIMIT 1)",
        );
    }
};
