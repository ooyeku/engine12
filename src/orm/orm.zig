const std = @import("std");
pub const Database = @import("database.zig").Database;
const QueryResult = @import("row.zig").QueryResult;
const QueryBuilder = @import("query_builder.zig").QueryBuilder;
const model = @import("model.zig");

pub const ORM = struct {
    db: Database,
    allocator: std.mem.Allocator,

    pub fn init(db: Database, allocator: std.mem.Allocator) ORM {
        return ORM{
            .db = db,
            .allocator = allocator,
        };
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
                try fields.append(self.allocator, field.name);

                const value = @field(instance, field.name);
                const value_str = try self.valueToString(value);
                try values.append(self.allocator, value_str);
            }
        }

        defer {
            for (values.items) |item| {
                self.allocator.free(item);
            }
            values.deinit(self.allocator);
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

        try self.db.execute(sql);
    }

    pub fn find(self: *ORM, comptime T: type, id: i64) !?T {
        const table_name = model.inferTableName(T);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT * FROM {s} WHERE id = {d}",
            .{ table_name, id },
        );
        defer self.allocator.free(sql);

        var result = try self.db.query(sql);
        defer result.deinit();

        var list = try result.toArrayList(T);
        defer {
            for (list.items) |item| {
                self.allocator.free(item.title);
                self.allocator.free(item.description);
            }
            list.deinit(self.allocator);
        }

        if (list.items.len > 0) {
            const item = list.items[0];
            return T{
                .id = item.id,
                .title = try self.allocator.dupe(u8, item.title),
                .description = try self.allocator.dupe(u8, item.description),
                .completed = item.completed,
                .created_at = item.created_at,
                .updated_at = item.updated_at,
            };
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

        var query_result = try self.db.query(sql);
        defer query_result.deinit();

        return try query_result.toArrayList(T);
    }

    pub fn where(self: *ORM, comptime T: type, condition: []const u8) !std.ArrayListUnmanaged(T) {
        const table_name = model.inferTableName(T);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT * FROM {s} WHERE {s}",
            .{ table_name, condition },
        );
        defer self.allocator.free(sql);

        var query_result = try self.db.query(sql);
        defer query_result.deinit();

        return try query_result.toArrayList(T);
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
            const value_str = try self.valueToString(value);
            defer self.allocator.free(value_str);
            const update_str = try std.fmt.allocPrint(
                self.allocator,
                "{s} = {s}",
                .{ field.name, value_str },
            );
            try updates.append(self.allocator, update_str);
        }

        const updates_str = try std.mem.join(self.allocator, ", ", updates.items);
        defer self.allocator.free(updates_str);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE {s} SET {s} WHERE id = {d}",
            .{ table_name, updates_str, id_value },
        );
        defer self.allocator.free(sql);

        try self.db.execute(sql);
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
                    @compileError("Unsupported pointer type");
                }
            },
            .optional => {
                if (value) |inner_value| {
                    return try self.valueToString(inner_value);
                } else {
                    return try self.allocator.dupe(u8, "NULL");
                }
            },
            else => @compileError("Unsupported type: " ++ @typeName(T)),
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
