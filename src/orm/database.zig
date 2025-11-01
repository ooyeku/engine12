const std = @import("std");
const c = @cImport({
    @cInclude("e12_orm.h");
});
const QueryResult = @import("row.zig").QueryResult;

pub const Database = struct {
    c_db: *c.E12Database,
    allocator: std.mem.Allocator,

    pub fn open(path: []const u8, allocator: std.mem.Allocator) !Database {
        const c_path = try allocator.dupeZ(u8, path);
        defer allocator.free(c_path);

        var c_db: ?*c.E12Database = null;
        const err = c.e12_db_open(c_path, &c_db);

        if (err != c.E12_ORM_OK) {
            _ = c.e12_orm_get_last_error(); // Ignore error message for now
            return switch (err) {
                c.E12_ORM_ERROR_OPEN_FAILED => error.DatabaseOpenFailed,
                c.E12_ORM_ERROR_INVALID_ARGUMENT => error.InvalidArgument,
                else => error.DatabaseError,
            };
        }

        return Database{
            .c_db = c_db.?,
            .allocator = allocator,
        };
    }

    pub fn close(self: *Database) void {
        c.e12_db_close(self.c_db);
    }

    pub fn execute(self: *Database, sql: []const u8) !void {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        const err = c.e12_db_execute(self.c_db, c_sql, null);

        if (err != c.E12_ORM_OK) {
            _ = c.e12_orm_get_last_error(); // Ignore error message for now
            return switch (err) {
                c.E12_ORM_ERROR_QUERY_FAILED => error.QueryFailed,
                c.E12_ORM_ERROR_INVALID_ARGUMENT => error.InvalidArgument,
                else => error.DatabaseError,
            };
        }
    }

    pub fn executeWithRowsAffected(self: *Database, sql: []const u8) !i64 {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var rows_affected: i64 = 0;
        const err = c.e12_db_execute(self.c_db, c_sql, &rows_affected);

        if (err != c.E12_ORM_OK) {
            _ = c.e12_orm_get_last_error(); // Ignore error message for now
            return switch (err) {
                c.E12_ORM_ERROR_QUERY_FAILED => error.QueryFailed,
                c.E12_ORM_ERROR_INVALID_ARGUMENT => error.InvalidArgument,
                else => error.DatabaseError,
            };
        }

        return rows_affected;
    }

    pub fn query(self: *Database, sql: []const u8) !QueryResult {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var c_result: ?*c.E12Result = null;
        const err = c.e12_db_query(self.c_db, c_sql, &c_result);

        if (err != c.E12_ORM_OK) {
            _ = c.e12_orm_get_last_error(); // Ignore error message for now
            return switch (err) {
                c.E12_ORM_ERROR_QUERY_FAILED => error.QueryFailed,
                c.E12_ORM_ERROR_INVALID_ARGUMENT => error.InvalidArgument,
                else => error.DatabaseError,
            };
        }

        return QueryResult.init(c_result.?, self.allocator);
    }

    pub fn lastInsertRowId(self: *Database) !i64 {
        var result = try self.query("SELECT last_insert_rowid()");
        defer result.deinit();

        if (result.nextRow()) |row| {
            return row.getInt64(0);
        }

        return error.NoResult;
    }

    pub const Error = error{
        DatabaseOpenFailed,
        QueryFailed,
        InvalidArgument,
        DatabaseError,
        NoResult,
    };
};

test "Database open and close" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();
    try std.testing.expect(db.c_db != null);
}

test "Database execute CREATE TABLE" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)");
}

test "Database execute INSERT" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES ('Bob')");
}

test "Database executeWithRowsAffected" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    const rows1 = try db.executeWithRowsAffected("INSERT INTO users (name) VALUES ('Alice')");
    try std.testing.expectEqual(@as(i64, 1), rows1);

    const rows2 = try db.executeWithRowsAffected("INSERT INTO users (name) VALUES ('Bob')");
    try std.testing.expectEqual(@as(i64, 1), rows2);

    const rows3 = try db.executeWithRowsAffected("UPDATE users SET name = 'Charlie' WHERE id = 1");
    try std.testing.expectEqual(@as(i64, 1), rows3);
}

test "Database query SELECT" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES ('Bob')");

    var result = try db.query("SELECT * FROM users");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 2), result.columnCount());
    try std.testing.expectEqualStrings("id", result.columnName(0).?);
    try std.testing.expectEqualStrings("name", result.columnName(1).?);
}

test "Database execute invalid SQL" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try std.testing.expectError(error.QueryFailed, db.execute("INVALID SQL STATEMENT"));
}

test "Database query empty result" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

    var result = try db.query("SELECT * FROM users WHERE id = 999");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 2), result.columnCount());
    try std.testing.expect(result.nextRow() == null);
}

test "Database multiple queries" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES ('Bob')");

    var result1 = try db.query("SELECT COUNT(*) FROM users");
    defer result1.deinit();

    var result2 = try db.query("SELECT * FROM users ORDER BY id");
    defer result2.deinit();

    try std.testing.expect(result1.columnCount() > 0);
    try std.testing.expect(result2.columnCount() > 0);
}
