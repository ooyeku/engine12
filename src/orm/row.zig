const std = @import("std");
const c = @cImport({
    @cInclude("e12_orm.h");
});

pub const Row = struct {
    c_row: *c.E12Row,

    pub fn getText(self: Row, col_index: i32) ?[]const u8 {
        const text_ptr = c.e12_row_get_text(self.c_row, col_index);
        if (text_ptr == null) return null;
        return std.mem.sliceTo(text_ptr, 0);
    }

    pub fn getInt64(self: Row, col_index: i32) i64 {
        return c.e12_row_get_int64(self.c_row, col_index);
    }

    pub fn getDouble(self: Row, col_index: i32) f64 {
        return c.e12_row_get_double(self.c_row, col_index);
    }

    pub fn isNull(self: Row, col_index: i32) bool {
        return c.e12_row_is_null(self.c_row, col_index);
    }

    pub fn getTextAlloc(self: Row, allocator: std.mem.Allocator, col_index: i32) !?[]u8 {
        const text = self.getText(col_index) orelse return null;
        return try allocator.dupe(u8, text);
    }
};

pub const QueryResult = struct {
    c_result: *c.E12Result,
    allocator: std.mem.Allocator,
    column_count: i32,

    pub fn init(c_result: *c.E12Result, allocator: std.mem.Allocator) QueryResult {
        return QueryResult{
            .c_result = c_result,
            .allocator = allocator,
            .column_count = c.e12_result_column_count(c_result),
        };
    }

    pub fn columnCount(self: QueryResult) i32 {
        return self.column_count;
    }

    pub fn columnName(self: QueryResult, col_index: i32) ?[]const u8 {
        const name_ptr = c.e12_result_column_name(self.c_result, col_index);
        if (name_ptr == null) return null;
        return std.mem.sliceTo(name_ptr, 0);
    }

    pub fn nextRow(self: *QueryResult) ?Row {
        var c_row: ?*c.E12Row = null;
        if (c.e12_result_next_row(self.c_result, &c_row)) {
            if (c_row) |row| {
                return Row{ .c_row = row };
            }
        }
        return null;
    }

    pub fn deinit(self: *QueryResult) void {
        c.e12_result_free(self.c_result);
    }

    pub fn toArrayList(self: *QueryResult, comptime T: type) !std.ArrayListUnmanaged(T) {
        var list = std.ArrayListUnmanaged(T){};
        errdefer list.deinit(self.allocator);

        while (self.nextRow()) |row| {
            const item = try self.rowToStruct(T, row);
            try list.append(self.allocator, item);
        }

        return list;
    }

    fn rowToStruct(self: *QueryResult, comptime T: type, row: Row) !T {
        var instance: T = undefined;

        var col_idx: i32 = 0;
        inline for (std.meta.fields(T)) |field| {
            if (col_idx >= self.column_count) break;

            const field_type = @TypeOf(@field(instance, field.name));

            if (row.isNull(col_idx)) {
                const is_optional = @typeInfo(field_type) == .optional;
                if (is_optional) {
                    @field(instance, field.name) = null;
                } else {
                    // For non-optional fields, set to default value
                    @field(instance, field.name) = @as(field_type, switch (@typeInfo(field_type)) {
                        .int => 0,
                        .float => 0.0,
                        .bool => false,
                        else => return error.InvalidData, // Can't handle null for this type
                    });
                }
            } else {
                switch (@typeInfo(field_type)) {
                    .int => {
                        @field(instance, field.name) = @as(field_type, @intCast(row.getInt64(col_idx)));
                    },
                    .float => {
                        @field(instance, field.name) = @as(field_type, @floatCast(row.getDouble(col_idx)));
                    },
                    .bool => {
                        @field(instance, field.name) = row.getInt64(col_idx) != 0;
                    },
                    .pointer => |ptr_info| {
                        if (ptr_info.size == .slice and ptr_info.child == u8) {
                            const text = row.getText(col_idx) orelse return error.InvalidData;
                            @field(instance, field.name) = try self.allocator.dupe(u8, text);
                        } else {
                            @compileError("Unsupported pointer type for field: " ++ field.name);
                        }
                    },
                    .optional => |opt_info| {
                        const inner_type = opt_info.child;
                        switch (@typeInfo(inner_type)) {
                            .int => {
                                @field(instance, field.name) = @as(inner_type, @intCast(row.getInt64(col_idx)));
                            },
                            .float => {
                                @field(instance, field.name) = @as(inner_type, @floatCast(row.getDouble(col_idx)));
                            },
                            .bool => {
                                @field(instance, field.name) = row.getInt64(col_idx) != 0;
                            },
                            .pointer => |ptr_info| {
                                if (ptr_info.size == .slice and ptr_info.child == u8) {
                                    const text = row.getText(col_idx) orelse return error.InvalidData;
                                    @field(instance, field.name) = try self.allocator.dupe(u8, text);
                                } else {
                                    @compileError("Unsupported optional pointer type");
                                }
                            },
                            else => @compileError("Unsupported optional type"),
                        }
                    },
                    else => @compileError("Unsupported field type: " ++ @typeName(field_type)),
                }
            }

            col_idx += 1;
        }

        return instance;
    }
};

test "Row getText" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");

    var result = try db.query("SELECT * FROM users");
    defer result.deinit();

    const row = result.nextRow() orelse return error.NoRow;
    const name = row.getText(1);
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("Alice", name.?);
}

test "Row getInt64" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, age INTEGER)");
    try db.execute("INSERT INTO users (age) VALUES (25)");

    var result = try db.query("SELECT * FROM users");
    defer result.deinit();

    const row = result.nextRow() orelse return error.NoRow;
    const id = row.getInt64(0);
    const age = row.getInt64(1);
    try std.testing.expect(id > 0);
    try std.testing.expectEqual(@as(i64, 25), age);
}

test "Row getDouble" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE products (id INTEGER PRIMARY KEY, price REAL)");
    try db.execute("INSERT INTO products (price) VALUES (19.99)");

    var result = try db.query("SELECT * FROM products");
    defer result.deinit();

    const row = result.nextRow() orelse return error.NoRow;
    const price = row.getDouble(1);
    try std.testing.expectApproxEqAbs(@as(f64, 19.99), price, 0.01);
}

test "Row isNull" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");
    try db.execute("INSERT INTO users (name, age) VALUES (NULL, 25)");

    var result = try db.query("SELECT * FROM users");
    defer result.deinit();

    const row = result.nextRow() orelse return error.NoRow;
    try std.testing.expect(row.isNull(1));
    try std.testing.expect(!row.isNull(2));
}

test "Row getTextAlloc" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");

    var result = try db.query("SELECT * FROM users");
    defer result.deinit();

    const row = result.nextRow() orelse return error.NoRow;
    const name = try row.getTextAlloc(allocator, 1);
    defer if (name) |n| allocator.free(n);

    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("Alice", name.?);
}

test "QueryResult columnCount" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    var result = try db.query("SELECT * FROM users");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 3), result.columnCount());
}

test "QueryResult columnName" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

    var result = try db.query("SELECT id, name FROM users");
    defer result.deinit();

    try std.testing.expectEqualStrings("id", result.columnName(0).?);
    try std.testing.expectEqualStrings("name", result.columnName(1).?);
    try std.testing.expect(result.columnName(2) == null);
}

test "QueryResult nextRow multiple rows" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES ('Bob')");
    try db.execute("INSERT INTO users (name) VALUES ('Charlie')");

    var result = try db.query("SELECT * FROM users ORDER BY id");
    defer result.deinit();

    var count: u32 = 0;
    while (result.nextRow()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 3), count);
}

test "QueryResult toArrayList" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const User = struct {
        id: i64,
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES ('Bob')");

    var result = try db.query("SELECT * FROM users ORDER BY id");
    defer result.deinit();

    var users = try result.toArrayList(User);
    defer {
        for (users.items) |user| {
            allocator.free(user.name);
        }
        users.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), users.items.len);
    try std.testing.expectEqualStrings("Alice", users.items[0].name);
    try std.testing.expectEqualStrings("Bob", users.items[1].name);
}

test "QueryResult toArrayList with optional fields" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const User = struct {
        id: i64,
        name: ?[]u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES (NULL)");

    var result = try db.query("SELECT * FROM users ORDER BY id");
    defer result.deinit();

    var users = try result.toArrayList(User);
    defer {
        for (users.items) |user| {
            if (user.name) |n| allocator.free(n);
        }
        users.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), users.items.len);
    try std.testing.expect(users.items[0].name != null);
    try std.testing.expect(users.items[1].name == null);
}

test "QueryResult toArrayList with boolean" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const User = struct {
        id: i64,
        active: bool,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, active INTEGER)");
    try db.execute("INSERT INTO users (active) VALUES (1)");
    try db.execute("INSERT INTO users (active) VALUES (0)");

    var result = try db.query("SELECT * FROM users ORDER BY id");
    defer result.deinit();

    var users = try result.toArrayList(User);
    defer users.deinit();

    try std.testing.expectEqual(@as(usize, 2), users.items.len);
    try std.testing.expect(users.items[0].active == true);
    try std.testing.expect(users.items[1].active == false);
}
