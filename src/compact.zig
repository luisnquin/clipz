const std = @import("std");
const Db = @import("db.zig").Db;
const Config = @import("config.zig").Config;

pub fn run(allocator: std.mem.Allocator, cfg: *const Config) !void {
    const db = try Db.open(allocator, cfg.db_path);
    defer db.close();
    try db.compact();
}
