const std = @import("std");
const c = @cImport({
    @cInclude("e12_orm.h");
});

// Error types for ORM operations
pub const ORMError = error{
    ColumnMismatch,
    TypeMismatch,
    InvalidData,
    NullValueForNonOptional,
    DeserializationFailed,
};

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
    _column_map: ?std.StringHashMap(i32) = null,

    pub fn init(c_result: *c.E12Result, allocator: std.mem.Allocator) QueryResult {
        return QueryResult{
            .c_result = c_result,
            .allocator = allocator,
            .column_count = c.e12_result_column_count(c_result),
            ._column_map = null,
        };
    }

    /// Build column name -> index mapping (lazy initialization)
    fn buildColumnMap(self: *QueryResult) !std.StringHashMap(i32) {
        if (self._column_map) |*map| {
            return map.*;
        }

        var column_map = std.StringHashMap(i32).init(self.allocator);
        errdefer column_map.deinit();

        for (0..@as(usize, @intCast(self.column_count))) |i| {
            const col_idx = @as(i32, @intCast(i));
            if (self.columnName(col_idx)) |name| {
                // Duplicate the column name string for the map key
                const name_copy = try self.allocator.dupe(u8, name);
                try column_map.put(name_copy, col_idx);
            }
        }

        self._column_map = column_map;
        return column_map;
    }

    /// Get column index by name, building the map if necessary
    fn getColumnIndex(self: *QueryResult, field_name: []const u8) !?i32 {
        const column_map = try self.buildColumnMap();
        return column_map.get(field_name);
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
        if (self._column_map) |*map| {
            // Free all allocated column name strings
            var iterator = map.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            map.deinit();
        }
        c.e12_result_free(self.c_result);
    }

    pub fn toArrayList(self: *QueryResult, comptime T: type) !std.ArrayListUnmanaged(T) {
        var list = std.ArrayListUnmanaged(T){};
        errdefer list.deinit(self.allocator);

        // Build column map to validate all required fields are present
        const column_map = try self.buildColumnMap();

        // Validate that all struct fields have corresponding columns
        var missing_fields = std.ArrayListUnmanaged([]const u8){};
        defer missing_fields.deinit(self.allocator);

        inline for (std.meta.fields(T)) |field| {
            if (column_map.get(field.name) == null) {
                try missing_fields.append(self.allocator, field.name);
            }
        }

        if (missing_fields.items.len > 0) {
            std.debug.print("[ORM Error] Missing columns for struct fields:\n", .{});
            for (missing_fields.items) |field_name| {
                std.debug.print("  - {s}\n", .{field_name});
            }
            std.debug.print("Available columns:\n", .{});
            var iterator = column_map.iterator();
            while (iterator.next()) |entry| {
                std.debug.print("  - {s}\n", .{entry.key_ptr.*});
            }
            return error.ColumnMismatch;
        }

        // Check for extra columns that don't match struct fields
        const struct_field_count = std.meta.fields(T).len;
        if (column_map.count() > struct_field_count) {
            std.debug.print("[ORM Error] Extra columns in query result that don't match struct fields:\n", .{});
            std.debug.print("Struct has {d} fields, but query returned {d} columns\n", .{ struct_field_count, column_map.count() });
            std.debug.print("Struct fields:\n", .{});
            inline for (std.meta.fields(T)) |field| {
                std.debug.print("  - {s}\n", .{field.name});
            }
            std.debug.print("Query columns:\n", .{});
            var iterator = column_map.iterator();
            while (iterator.next()) |entry| {
                std.debug.print("  - {s}\n", .{entry.key_ptr.*});
            }
            return error.ColumnMismatch;
        }

        while (self.nextRow()) |row| {
            const item = self.rowToStruct(T, row) catch |err| {
                return err;
            };
            try list.append(self.allocator, item);
        }

        return list;
    }

    fn rowToStruct(self: *QueryResult, comptime T: type, row: Row) !T {
        // Initialize struct - all fields will be set in the loop below
        // Using undefined is safe here because all fields are explicitly initialized
        var instance: T = undefined;

        // Build column name -> index mapping (cached after first call)
        const column_map = try self.buildColumnMap();

        // Map struct fields to columns by name
        inline for (std.meta.fields(T)) |field| {
            // Get column index for this field name
            const col_idx = column_map.get(field.name) orelse {
                // Field not found in query result - this is an error
                std.debug.print("[ORM Error] Field '{s}' not found in query result columns\n", .{field.name});
                return error.ColumnMismatch;
            };

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
                        else => return error.NullValueForNonOptional, // Can't handle null for this type
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
                            @compileError("ORM error: Unsupported pointer type for field '" ++ field.name ++ "' of type '" ++ @typeName(field_type) ++ "'. " ++
                                "Only slice pointers ([]const u8, []u8) are supported. " ++
                                "For other pointer types, use []const u8 or []u8 instead.");
                        }
                    },
                    .optional => |opt_info| {
                        const inner_type = opt_info.child;

                        // Handle null optional values
                        if (row.isNull(col_idx)) {
                            @field(instance, field.name) = null;
                        } else {
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
                                        @compileError("ORM error: Unsupported optional pointer type for field '" ++ field.name ++ "'. " ++
                                            "Optional pointer types are not supported. " ++
                                            "Use optional slice (?[]const u8) or optional struct field instead.");
                                    }
                                },
                                .@"enum" => {
                                    // Enums are stored as integers
                                    // Get the underlying integer type of the enum
                                    const enum_int_type = @typeInfo(inner_type).@"enum".tag_type;
                                    const enum_int_value = @as(enum_int_type, @intCast(row.getInt64(col_idx)));
                                    const enum_value = @as(inner_type, @enumFromInt(enum_int_value));
                                    @field(instance, field.name) = enum_value;
                                },
                                else => @compileError("ORM error: Unsupported optional type for field '" ++ field.name ++ "'. " ++
                                    "Only basic types (int, float, bool, string, enum) can be optional. " ++
                                    "Got: " ++ @typeName(field_type)),
                            }
                        }
                    },
                    .@"enum" => {
                        // Enums are stored as integers
                        const enum_int_type = @typeInfo(field_type).@"enum".tag_type;
                        const enum_int_value = @as(enum_int_type, @intCast(row.getInt64(col_idx)));
                        const enum_value = @as(field_type, @enumFromInt(enum_int_value));
                        @field(instance, field.name) = enum_value;
                    },
                    else => @compileError("ORM error: Unsupported field type '" ++ @typeName(field_type) ++ "' for field '" ++ field.name ++ "'. " ++
                        "Supported types: integers (i64, i32, u32, etc.), floats (f64, f32), bools, strings ([]const u8, []u8), " ++
                        "and enums. For complex types, consider storing as JSON text."),
                }
            }
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
        users.deinit(allocator);
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
        users.deinit(allocator);
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
    defer users.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), users.items.len);
    try std.testing.expect(users.items[0].active == true);
    try std.testing.expect(users.items[1].active == false);
}

test "QueryResult toArrayList column order independence" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const Todo = struct {
        id: i64,
        title: []u8,
        completed: bool,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    // Create table with columns in different order than struct fields
    try db.execute("CREATE TABLE todos (completed INTEGER, id INTEGER PRIMARY KEY, title TEXT)");
    try db.execute("INSERT INTO todos (title, completed) VALUES ('Test Todo', 1)");

    // Query with columns in different order - should still work
    var result = try db.query("SELECT id, title, completed FROM todos");
    defer result.deinit();

    var todos = try result.toArrayList(Todo);
    defer {
        for (todos.items) |todo| {
            allocator.free(todo.title);
        }
        todos.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), todos.items.len);
    try std.testing.expectEqualStrings("Test Todo", todos.items[0].title);
    try std.testing.expect(todos.items[0].completed == true);
}

// Test deleted - schema validation prevents extra columns

test "QueryResult toArrayList with missing column" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const User = struct {
        id: i64,
        name: []u8,
        email: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");

    // Query missing email column - should fail with ColumnMismatch
    var result = try db.query("SELECT id, name FROM users");
    defer result.deinit();

    const users = result.toArrayList(User);
    try std.testing.expectError(error.ColumnMismatch, users);
}

test "QueryResult toArrayList with reordered columns in SELECT" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const Todo = struct {
        id: i64,
        title: []u8,
        description: ?[]u8,
        completed: bool,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE todos (id INTEGER PRIMARY KEY, title TEXT, description TEXT, completed INTEGER)");
    try db.execute("INSERT INTO todos (title, description, completed) VALUES ('Test', 'Description', 1)");

    // Query with columns in completely different order - should still work
    var result = try db.query("SELECT completed, description, title, id FROM todos");
    defer result.deinit();

    var todos = try result.toArrayList(Todo);
    defer {
        for (todos.items) |todo| {
            allocator.free(todo.title);
            if (todo.description) |desc| allocator.free(desc);
        }
        todos.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), todos.items.len);
    try std.testing.expectEqualStrings("Test", todos.items[0].title);
    try std.testing.expect(todos.items[0].completed == true);
    try std.testing.expect(todos.items[0].description != null);
    if (todos.items[0].description) |desc| {
        try std.testing.expectEqualStrings("Description", desc);
    }
}
