const std = @import("std");
pub const Database = @import("database.zig").Database;
const QueryResult = @import("row.zig").QueryResult;
const QueryBuilder = @import("query_builder.zig").QueryBuilder;
const model = @import("model.zig");
const MigrationRunner = @import("migration_runner.zig").MigrationRunner;
const Migration = @import("migration.zig").Migration;

// Re-export utility modules
pub const SqlEscape = @import("sql_escape.zig").SqlEscape;
pub const Schema = @import("schema.zig").Schema;
pub const DatabaseSingleton = @import("singleton.zig").DatabaseSingleton;

pub const ORM = struct {
    db: Database,
    allocator: std.mem.Allocator,

    pub fn init(db: Database, allocator: std.mem.Allocator) ORM {
        return ORM{
            .db = db,
            .allocator = allocator,
        };
    }

    /// Initialize ORM and return a heap-allocated pointer
    /// This is recommended for handler usage where you need to pass pointers
    ///
    /// Example:
    /// ```zig
    /// const orm = try ORM.initPtr(db, allocator);
    /// defer orm.deinitPtr(allocator);
    /// ```
    pub fn initPtr(db: Database, allocator: std.mem.Allocator) !*ORM {
        const orm = try allocator.create(ORM);
        orm.* = ORM.init(db, allocator);
        return orm;
    }

    /// Deinitialize and free a heap-allocated ORM instance
    /// Call this after initPtr() when you're done with the ORM
    ///
    /// Example:
    /// ```zig
    /// const orm = try ORM.initPtr(db, allocator);
    /// defer orm.deinitPtr(allocator);
    /// ```
    pub fn deinitPtr(self: *ORM, allocator: std.mem.Allocator) void {
        self.close();
        allocator.destroy(self);
    }

    pub fn initWithPool(pool: *Database.ConnectionPool, allocator: std.mem.Allocator) !ORM {
        _ = pool;
        _ = allocator;
        return error.NotImplemented;
    }

    pub fn create(self: *ORM, comptime T: type, instance: T) !void {
        const table_name = model.inferTableName(T);
        var fields = std.ArrayListUnmanaged([]const u8){};
        defer fields.deinit(self.allocator);

        var values = std.ArrayListUnmanaged([]const u8){};

        inline for (std.meta.fields(T)) |field| {
            const is_id_field = comptime std.mem.eql(u8, field.name, "id");
            if (is_id_field) {
                const id_value = @field(instance, field.name);
                if (id_value != 0) {
                    try fields.append(self.allocator, field.name);
                    const value_str = try self.valueToString(id_value);
                    try values.append(self.allocator, value_str);
                }
            } else {
                const value = @field(instance, field.name);
                const field_type = @TypeOf(value);

                // Check if field is optional and null
                const is_optional_null = switch (@typeInfo(field_type)) {
                    .optional => value == null,
                    else => false,
                };

                // Skip optional fields that are null (don't include in INSERT)
                if (!is_optional_null) {
                    try fields.append(self.allocator, field.name);
                    const value_str = try self.valueToString(value);
                    try values.append(self.allocator, value_str);
                }
            }
        }

        defer {
            for (values.items) |item| {
                self.allocator.free(item);
            }
            values.deinit(self.allocator);
        }

        // Validate that we have at least one field to insert
        if (fields.items.len == 0) {
            std.debug.print("[ORM Error] create() failed for table '{s}'\n", .{table_name});
            std.debug.print("  Reason: No fields to insert (all fields are null or id is 0)\n", .{});
            return error.InvalidArgument;
        }

        const fields_str = try std.mem.join(self.allocator, ", ", fields.items);
        defer self.allocator.free(fields_str);

        const values_str = try std.mem.join(self.allocator, ", ", values.items);
        defer self.allocator.free(values_str);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO {s} ({s}) VALUES ({s})",
            .{ table_name, fields_str, values_str },
        );
        defer self.allocator.free(sql);

        self.db.execute(sql) catch |err| {
            std.debug.print("[ORM Error] create() failed for table '{s}'\n", .{table_name});
            std.debug.print("  SQL: {s}\n", .{sql});
            std.debug.print("  Fields: ", .{});
            for (fields.items, 0..) |field, i| {
                if (i > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{field});
            }
            std.debug.print("\n", .{});
            std.debug.print("  Error: {}\n", .{err});
            return err;
        };
    }

    pub fn find(self: *ORM, comptime T: type, id: i64) !?T {
        const table_name = model.inferTableName(T);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT * FROM {s} WHERE id = {d}",
            .{ table_name, id },
        );
        defer self.allocator.free(sql);

        var result = self.db.query(sql) catch |err| {
            std.debug.print("[ORM Error] find() failed for table '{s}'\n", .{table_name});
            std.debug.print("  SQL: {s}\n", .{sql});
            std.debug.print("  ID: {d}\n", .{id});
            std.debug.print("  Error: {}\n", .{err});
            return err;
        };
        defer result.deinit();

        var list = try result.toArrayList(T);
        defer {
            for (list.items) |item| {
                inline for (std.meta.fields(T)) |field| {
                    const field_type = @TypeOf(@field(item, field.name));
                    if (@typeInfo(field_type) == .pointer) {
                        const ptr_info = @typeInfo(field_type).pointer;
                        if (ptr_info.size == .slice and ptr_info.child == u8) {
                            self.allocator.free(@field(item, field.name));
                        }
                    } else if (@typeInfo(field_type) == .optional) {
                        const opt_info = @typeInfo(field_type).optional;
                        if (@typeInfo(opt_info.child) == .pointer) {
                            const ptr_info = @typeInfo(opt_info.child).pointer;
                            if (ptr_info.size == .slice and ptr_info.child == u8) {
                                if (@field(item, field.name)) |val| {
                                    self.allocator.free(val);
                                }
                            }
                        }
                    }
                }
            }
            list.deinit(self.allocator);
        }

        if (list.items.len > 0) {
            const item = list.items[0];
            // Copy all fields dynamically, duplicating string slices
            // Initialize struct - all fields will be set in the loop below
            // Using undefined is safe here because all fields are explicitly initialized
            var return_value: T = undefined;
            inline for (std.meta.fields(T)) |field| {
                const field_type = @TypeOf(@field(item, field.name));
                if (@typeInfo(field_type) == .pointer) {
                    const ptr_info = @typeInfo(field_type).pointer;
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        @field(return_value, field.name) = try self.allocator.dupe(u8, @field(item, field.name));
                    } else {
                        @field(return_value, field.name) = @field(item, field.name);
                    }
                } else if (@typeInfo(field_type) == .optional) {
                    const opt_info = @typeInfo(field_type).optional;
                    if (@typeInfo(opt_info.child) == .pointer) {
                        const ptr_info = @typeInfo(opt_info.child).pointer;
                        if (ptr_info.size == .slice and ptr_info.child == u8) {
                            if (@field(item, field.name)) |val| {
                                @field(return_value, field.name) = try self.allocator.dupe(u8, val);
                            } else {
                                @field(return_value, field.name) = null;
                            }
                        } else {
                            @field(return_value, field.name) = @field(item, field.name);
                        }
                    } else {
                        @field(return_value, field.name) = @field(item, field.name);
                    }
                } else {
                    @field(return_value, field.name) = @field(item, field.name);
                }
            }
            return return_value;
        }

        return null;
    }

    pub fn findAll(self: *ORM, comptime T: type) !std.ArrayListUnmanaged(T) {
        const table_name = model.inferTableName(T);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT * FROM {s}",
            .{table_name},
        );
        defer self.allocator.free(sql);

        var query_result = self.db.query(sql) catch |err| {
            std.debug.print("[ORM Error] findAll() failed for table '{s}'\n", .{table_name});
            std.debug.print("  SQL: {s}\n", .{sql});
            std.debug.print("  Error: {}\n", .{err});
            return err;
        };
        defer query_result.deinit();

        const result = query_result.toArrayList(T) catch |err| {
            // Wrap deserialization errors with context
            const field_count = std.meta.fields(T).len;
            const column_count = query_result.columnCount();

            // Provide detailed error message for debugging
            std.debug.print("ORM findAll() error for table '{s}'\n", .{table_name});
            std.debug.print("  SQL: {s}\n", .{sql});
            std.debug.print("  Expected {d} fields, got {d} columns\n", .{ field_count, column_count });
            std.debug.print("  Error: {}\n", .{err});

            return err;
        };

        return result;
    }

    pub fn where(self: *ORM, comptime T: type, condition: []const u8) !std.ArrayListUnmanaged(T) {
        const table_name = model.inferTableName(T);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT * FROM {s} WHERE {s}",
            .{ table_name, condition },
        );
        defer self.allocator.free(sql);

        var query_result = self.db.query(sql) catch |err| {
            std.debug.print("[ORM Error] where() failed for table '{s}'\n", .{table_name});
            std.debug.print("  SQL: {s}\n", .{sql});
            std.debug.print("  Condition: {s}\n", .{condition});
            std.debug.print("  Error: {}\n", .{err});
            return err;
        };
        defer query_result.deinit();

        const result = query_result.toArrayList(T) catch |err| {
            // Wrap deserialization errors with context
            const field_count = std.meta.fields(T).len;
            const column_count = query_result.columnCount();

            // Provide detailed error message for debugging
            std.debug.print("ORM where() error for table '{s}'\n", .{table_name});
            std.debug.print("  SQL: {s}\n", .{sql});
            std.debug.print("  Expected {d} fields, got {d} columns\n", .{ field_count, column_count });
            std.debug.print("  Error: {}\n", .{err});

            return err;
        };

        return result;
    }

    pub fn update(self: *ORM, comptime T: type, instance: T) !void {
        const table_name = model.inferTableName(T);
        var updates = std.ArrayListUnmanaged([]const u8){};
        defer {
            for (updates.items) |item| {
                self.allocator.free(item);
            }
            updates.deinit(self.allocator);
        }

        var id_value: i64 = 0;

        inline for (std.meta.fields(T)) |field| {
            if (comptime std.mem.eql(u8, field.name, "id")) {
                id_value = @field(instance, field.name);
                continue;
            }

            const value = @field(instance, field.name);
            const field_type = @TypeOf(value);

            // Check if field is optional and null
            const is_optional_null = switch (@typeInfo(field_type)) {
                .optional => value == null,
                else => false,
            };

            // Skip optional fields that are null (don't update them)
            if (!is_optional_null) {
                const value_str = try self.valueToString(value);
                defer self.allocator.free(value_str);
                const update_str = try std.fmt.allocPrint(
                    self.allocator,
                    "{s} = {s}",
                    .{ field.name, value_str },
                );
                try updates.append(self.allocator, update_str);
            }
        }

        // Validate that we have at least one field to update
        if (updates.items.len == 0) {
            std.debug.print("[ORM Error] update() failed for table '{s}'\n", .{table_name});
            std.debug.print("  Reason: No fields to update (all fields are null)\n", .{});
            std.debug.print("  ID: {d}\n", .{id_value});
            return error.InvalidArgument;
        }

        // Validate that id is valid
        if (id_value == 0) {
            std.debug.print("[ORM Error] update() failed for table '{s}'\n", .{table_name});
            std.debug.print("  Reason: Invalid ID (id must be non-zero)\n", .{});
            return error.InvalidArgument;
        }

        const updates_str = try std.mem.join(self.allocator, ", ", updates.items);
        defer self.allocator.free(updates_str);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE {s} SET {s} WHERE id = {d}",
            .{ table_name, updates_str, id_value },
        );
        defer self.allocator.free(sql);

        self.db.execute(sql) catch |err| {
            std.debug.print("[ORM Error] update() failed for table '{s}'\n", .{table_name});
            std.debug.print("  SQL: {s}\n", .{sql});
            std.debug.print("  ID: {d}\n", .{id_value});
            std.debug.print("  Fields updated: ", .{});
            for (updates.items, 0..) |update_str, i| {
                if (i > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{update_str});
            }
            std.debug.print("\n", .{});
            std.debug.print("  Error: {}\n", .{err});
            return err;
        };
    }

    pub fn delete(self: *ORM, comptime T: type, id: i64) !void {
        const table_name = model.inferTableName(T);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "DELETE FROM {s} WHERE id = {d}",
            .{ table_name, id },
        );
        defer self.allocator.free(sql);

        try self.db.execute(sql);
    }

    pub fn query(self: *ORM, sql: []const u8) !QueryResult {
        return try self.db.query(sql);
    }

    pub fn execute(self: *ORM, sql: []const u8) !void {
        try self.db.execute(sql);
    }

    pub fn transaction(self: *ORM, comptime T: type, callback: fn (*Database.Transaction) anyerror!T) !T {
        var trans = try self.db.beginTransaction();
        defer trans.deinit();

        const result = callback(&trans) catch |err| {
            trans.rollback() catch {};
            return err;
        };

        try trans.commit();
        return result;
    }

    pub fn runMigrations(self: *ORM, migrations: []const Migration) !void {
        var runner = MigrationRunner.init(&self.db, self.allocator);
        try runner.runMigrations(migrations);
    }

    pub fn getMigrationVersion(self: *ORM) !?u32 {
        var runner = MigrationRunner.init(&self.db, self.allocator);
        return try runner.getCurrentVersion();
    }

    pub fn migrate(self: *ORM, migrations: []const Migration) !void {
        try self.runMigrations(migrations);
    }

    pub fn close(self: *ORM) void {
        self.db.close();
    }

    fn valueToString(self: *ORM, value: anytype) ![]const u8 {
        const T = @TypeOf(value);

        return switch (@typeInfo(T)) {
            .int => try std.fmt.allocPrint(self.allocator, "{d}", .{value}),
            .float => try std.fmt.allocPrint(self.allocator, "{d}", .{value}),
            .bool => try std.fmt.allocPrint(self.allocator, "{d}", .{@intFromBool(value)}),
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    // Escape single quotes in string
                    var escaped = std.ArrayListUnmanaged(u8){};
                    defer escaped.deinit(self.allocator);
                    try escaped.append(self.allocator, '\'');
                    for (value) |char| {
                        if (char == '\'') {
                            try escaped.append(self.allocator, '\'');
                            try escaped.append(self.allocator, '\'');
                        } else {
                            try escaped.append(self.allocator, char);
                        }
                    }
                    try escaped.append(self.allocator, '\'');
                    return escaped.toOwnedSlice(self.allocator);
                } else {
                    @compileError("ORM error: Unsupported pointer type '" ++ @typeName(T) ++ "'. " ++
                        "Only slice pointers ([]const u8, []u8) are supported. " ++
                        "For other pointer types, dereference or convert to supported type first.");
                }
            },
            .@"enum" => {
                const enum_value = @intFromEnum(value);
                return try std.fmt.allocPrint(self.allocator, "{d}", .{enum_value});
            },
            .optional => {
                if (value) |inner_value| {
                    return try self.valueToString(inner_value);
                } else {
                    return try self.allocator.dupe(u8, "NULL");
                }
            },
            else => @compileError("ORM error: Unsupported type '" ++ @typeName(T) ++ "' in valueToString(). " ++
                "Supported types: integers, floats, bools, strings ([]const u8), and enums. " ++
                "For enums, use @intFromEnum() to convert if needed. " ++
                "For complex types, consider serializing to JSON first."),
        };
    }
};

// Re-export for convenience
pub const DatabaseType = Database;
pub const QueryBuilderType = QueryBuilder;
pub const QueryResultType = QueryResult;

test "ORM create" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []const u8,
        age: i32,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    var orm = ORM.init(db, allocator);

    const user = User{
        .id = 0,
        .name = "Alice",
        .age = 25,
    };

    try orm.create(User, user);
}

test "ORM find" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO User (name) VALUES ('Alice')");

    var orm = ORM.init(db, allocator);

    const user = try orm.find(User, 1);
    defer if (user) |u| allocator.free(u.name);

    try std.testing.expect(user != null);
    try std.testing.expectEqualStrings("Alice", user.?.name);
}

test "ORM find non-existent" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT)");

    var orm = ORM.init(db, allocator);

    const user = try orm.find(User, 999);
    try std.testing.expect(user == null);
}

test "ORM findAll" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO User (name) VALUES ('Alice')");
    try db.execute("INSERT INTO User (name) VALUES ('Bob')");

    var orm = ORM.init(db, allocator);

    var users = try orm.findAll(User);
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

test "ORM findAll empty" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT)");

    var orm = ORM.init(db, allocator);

    var users = try orm.findAll(User);
    defer users.deinit();

    try std.testing.expectEqual(@as(usize, 0), users.items.len);
}

test "ORM where" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []u8,
        age: i32,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");
    try db.execute("INSERT INTO User (name, age) VALUES ('Alice', 25)");
    try db.execute("INSERT INTO User (name, age) VALUES ('Bob', 30)");
    try db.execute("INSERT INTO User (name, age) VALUES ('Charlie', 25)");

    var orm = ORM.init(db, allocator);

    var users = try orm.where(User, "age = 25");
    defer {
        for (users.items) |user| {
            allocator.free(user.name);
        }
        users.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), users.items.len);
}

test "ORM update" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []const u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO User (name) VALUES ('Alice')");

    var orm = ORM.init(db, allocator);

    const updated_user = User{
        .id = 1,
        .name = "Bob",
    };

    try orm.update(User, updated_user);

    const user = try orm.find(User, 1);
    defer if (user) |u| allocator.free(u.name);

    try std.testing.expect(user != null);
    try std.testing.expectEqualStrings("Bob", user.?.name);
}

test "ORM delete" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO User (name) VALUES ('Alice')");
    try db.execute("INSERT INTO User (name) VALUES ('Bob')");

    var orm = ORM.init(db, allocator);

    try orm.delete(User, 1);

    var users = try orm.findAll(User);
    defer {
        for (users.items) |user| {
            allocator.free(user.name);
        }
        users.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), users.items.len);
    try std.testing.expectEqualStrings("Bob", users.items[0].name);
}

test "ORM create with auto-increment id" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []const u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)");

    var orm = ORM.init(db, allocator);

    const user1 = User{ .id = 0, .name = "Alice" };
    const user2 = User{ .id = 0, .name = "Bob" };

    try orm.create(User, user1);
    try orm.create(User, user2);

    var users = try orm.findAll(User);
    defer {
        for (users.items) |user| {
            allocator.free(user.name);
        }
        users.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), users.items.len);
    try std.testing.expect(users.items[0].id > 0);
    try std.testing.expect(users.items[1].id > 0);
    try std.testing.expect(users.items[0].id != users.items[1].id);
}

test "ORM valueToString with integer" {
    const allocator = std.testing.allocator;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var orm = ORM.init(db, allocator);

    const value = try orm.valueToString(@as(i32, 42));
    defer allocator.free(value);
    try std.testing.expectEqualStrings("42", value);
}

test "ORM valueToString with float" {
    const allocator = std.testing.allocator;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var orm = ORM.init(db, allocator);

    const value = try orm.valueToString(@as(f64, 3.14));
    defer allocator.free(value);
    try std.testing.expect(std.mem.indexOf(u8, value, "3") != null);
}

test "ORM valueToString with boolean" {
    const allocator = std.testing.allocator;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var orm = ORM.init(db, allocator);

    const value_true = try orm.valueToString(true);
    defer allocator.free(value_true);
    try std.testing.expectEqualStrings("1", value_true);

    const value_false = try orm.valueToString(false);
    defer allocator.free(value_false);
    try std.testing.expectEqualStrings("0", value_false);
}

test "ORM valueToString with string" {
    const allocator = std.testing.allocator;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var orm = ORM.init(db, allocator);

    const value = try orm.valueToString("Alice");
    defer allocator.free(value);
    try std.testing.expectEqualStrings("'Alice'", value);
}

test "ORM valueToString with string containing quotes" {
    const allocator = std.testing.allocator;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var orm = ORM.init(db, allocator);

    const value = try orm.valueToString("O'Reilly");
    defer allocator.free(value);
    try std.testing.expect(std.mem.indexOf(u8, value, "O''Reilly") != null);
}

test "ORM valueToString with optional" {
    const allocator = std.testing.allocator;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var orm = ORM.init(db, allocator);

    const value_some = try orm.valueToString(@as(?i32, 42));
    defer allocator.free(value_some);
    try std.testing.expectEqualStrings("42", value_some);

    const value_none = try orm.valueToString(@as(?i32, null));
    defer allocator.free(value_none);
    try std.testing.expectEqualStrings("NULL", value_none);
}

test "ORM query and execute" {
    const allocator = std.testing.allocator;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var orm = ORM.init(db, allocator);

    try orm.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try orm.execute("INSERT INTO users (name) VALUES ('Alice')");

    var result = try orm.query("SELECT * FROM users");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 2), result.columnCount());
}

test "ORM close" {
    const allocator = std.testing.allocator;

    const db = try Database.open(":memory:", allocator);
    var orm = ORM.init(db, allocator);

    orm.close();
}

test "ORM transaction success" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []const u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT)");

    var orm = ORM.init(db, allocator);

    const result = try orm.transaction(void, struct {
        fn callback(trans: *Database.Transaction) !void {
            try trans.execute("INSERT INTO User (name) VALUES ('Alice')");
            try trans.execute("INSERT INTO User (name) VALUES ('Bob')");
        }
    }.callback);

    _ = result;

    var users = try orm.findAll(User);
    defer {
        for (users.items) |user| {
            allocator.free(user.name);
        }
        users.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), users.items.len);
}

test "ORM transaction rollback on error" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT)");

    var orm = ORM.init(db, allocator);

    _ = orm.transaction(void, struct {
        fn callback(trans: *Database.Transaction) !void {
            try trans.execute("INSERT INTO User (name) VALUES ('Alice')");
            return error.TestError;
        }
    }.callback) catch |err| {
        try std.testing.expectEqual(error.TestError, err);
    };

    var users = try orm.findAll(User);
    defer users.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), users.items.len);
}

test "ORM transaction with return value" {
    const allocator = std.testing.allocator;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value INTEGER)");

    var orm = ORM.init(db, allocator);

    const result = try orm.transaction(i64, struct {
        fn callback(trans: *Database.Transaction) !i64 {
            try trans.execute("INSERT INTO test (value) VALUES (42)");
            return 42;
        }
    }.callback);

    try std.testing.expectEqual(@as(i64, 42), result);
}

test "ORM runMigrations" {
    const allocator = std.testing.allocator;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var orm = ORM.init(db, allocator);

    const migrations = [_]Migration{
        Migration.init(1, "create_users", "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);", "DROP TABLE users;"),
    };

    try orm.runMigrations(&migrations);

    const version = try orm.getMigrationVersion();
    try std.testing.expect(version != null);
    try std.testing.expectEqual(@as(u32, 1), version.?);
}

test "ORM initPtr and deinitPtr" {
    const allocator = std.testing.allocator;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var orm = try ORM.initPtr(db, allocator);
    defer orm.deinitPtr(allocator);

    try std.testing.expect(orm.db.c_db != null);
}

test "ORM findAll with column mismatch error" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []u8,
        age: i32,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    // Create table with more columns than struct fields
    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, email TEXT)");

    var orm = ORM.init(db, allocator);

    const result = orm.findAll(User);
    try std.testing.expectError(error.ColumnMismatch, result);
    if (result) |users| {
        defer {
            for (users.items) |user| {
                allocator.free(user.name);
            }
            users.deinit();
        }
    }
}

test "ORM where with column mismatch error" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    // Create table with more columns than struct fields
    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    var orm = ORM.init(db, allocator);

    const result = orm.where(User, "id = 1");
    try std.testing.expectError(error.ColumnMismatch, result);
    if (result) |users| {
        defer {
            for (users.items) |user| {
                allocator.free(user.name);
            }
            users.deinit();
        }
    }
}

test "ORM findAll with table not found" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var orm = ORM.init(db, allocator);

    const result = orm.findAll(User);
    try std.testing.expectError(error.QueryFailed, result);
}

test "ORM create with empty fields should error" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        description: ?[]const u8 = null,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, description TEXT)");

    var orm = ORM.init(db, allocator);

    const user = User{
        .id = 0,
        .description = null,
    };

    const result = orm.create(User, user);
    try std.testing.expectError(error.InvalidArgument, result);
}

test "ORM update with empty fields should error" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        description: ?[]const u8 = null,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, description TEXT)");
    try db.execute("INSERT INTO User (id, description) VALUES (1, 'test')");

    var orm = ORM.init(db, allocator);

    const user = User{
        .id = 1,
        .description = null,
    };

    const result = orm.update(User, user);
    try std.testing.expectError(error.InvalidArgument, result);
}

test "ORM update with id 0 should error" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []const u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT)");

    var orm = ORM.init(db, allocator);

    const user = User{
        .id = 0,
        .name = "Alice",
    };

    const result = orm.update(User, user);
    try std.testing.expectError(error.InvalidArgument, result);
}
