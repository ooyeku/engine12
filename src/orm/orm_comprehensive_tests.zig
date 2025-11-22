const std = @import("std");
const Database = @import("database.zig").Database;
const ORM = @import("orm.zig").ORM;

// Comprehensive test suite for ORM methods
// This file validates all ORM operations work correctly

test "ORM create - basic insert" {
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

    // Verify the insert worked
    var result = try orm.query("SELECT * FROM User");
    defer result.deinit();
    try std.testing.expect(result.columnCount() == 3);

    const row = result.nextRow();
    try std.testing.expect(row != null);
    try std.testing.expectEqualStrings("Alice", row.?.getText(1).?);
    try std.testing.expectEqual(@as(i64, 25), row.?.getInt64(2));
}

test "ORM create - with auto-increment id" {
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
        users.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), users.items.len);
    try std.testing.expect(users.items[0].id > 0);
    try std.testing.expect(users.items[1].id > 0);
    try std.testing.expect(users.items[0].id != users.items[1].id);
}

test "ORM create - with optional fields (null values skipped)" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []const u8,
        description: ?[]const u8 = null,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT, description TEXT)");

    var orm = ORM.init(db, allocator);

    const user = User{
        .id = 0,
        .name = "Alice",
        .description = null,
    };

    try orm.create(User, user);

    // Verify only name was inserted (description should be NULL in DB)
    var result = try orm.query("SELECT name, description FROM User");
    defer result.deinit();

    const row = result.nextRow();
    try std.testing.expect(row != null);
    try std.testing.expectEqualStrings("Alice", row.?.getText(0).?);
    try std.testing.expect(row.?.isNull(1));
}

test "ORM create - with enum field" {
    const allocator = std.testing.allocator;

    const Status = enum { pending, active, completed };
    const User = struct {
        id: i64,
        name: []const u8,
        status: Status,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT, status INTEGER)");

    var orm = ORM.init(db, allocator);

    const user = User{
        .id = 0,
        .name = "Alice",
        .status = .active,
    };

    try orm.create(User, user);

    // Verify enum was stored as integer
    var result = try orm.query("SELECT status FROM User");
    defer result.deinit();

    const row = result.nextRow();
    try std.testing.expect(row != null);
    const status_int = row.?.getInt64(0);
    try std.testing.expect(status_int == @intFromEnum(Status.active));
}

test "ORM find - existing record" {
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
    try std.testing.expectEqual(@as(i64, 1), user.?.id);
}

test "ORM find - non-existent record" {
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

test "ORM findAll - multiple records" {
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
    try db.execute("INSERT INTO User (name) VALUES ('Charlie')");

    var orm = ORM.init(db, allocator);

    var users = try orm.findAll(User);
    defer {
        for (users.items) |user| {
            allocator.free(user.name);
        }
        users.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 3), users.items.len);
    try std.testing.expectEqualStrings("Alice", users.items[0].name);
    try std.testing.expectEqualStrings("Bob", users.items[1].name);
    try std.testing.expectEqualStrings("Charlie", users.items[2].name);
}

test "ORM findAll - empty table" {
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
    defer users.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), users.items.len);
}

test "ORM findAll - with enum field" {
    const allocator = std.testing.allocator;

    const Status = enum { pending, active, completed };
    const User = struct {
        id: i64,
        name: []u8,
        status: Status,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT, status INTEGER)");
    try db.execute("INSERT INTO User (name, status) VALUES ('Alice', 1)");
    try db.execute("INSERT INTO User (name, status) VALUES ('Bob', 2)");

    var orm = ORM.init(db, allocator);

    var users = try orm.findAll(User);
    defer {
        for (users.items) |user| {
            allocator.free(user.name);
        }
        users.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), users.items.len);
    try std.testing.expect(users.items[0].status == Status.active);
    try std.testing.expect(users.items[1].status == Status.completed);
}

test "ORM findAll - with optional fields" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []u8,
        description: ?[]u8 = null,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT, description TEXT)");
    try db.execute("INSERT INTO User (name, description) VALUES ('Alice', 'Test')");
    try db.execute("INSERT INTO User (name, description) VALUES ('Bob', NULL)");

    var orm = ORM.init(db, allocator);

    var users = try orm.findAll(User);
    defer {
        for (users.items) |user| {
            allocator.free(user.name);
            if (user.description) |desc| allocator.free(desc);
        }
        users.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), users.items.len);
    try std.testing.expect(users.items[0].description != null);
    try std.testing.expect(users.items[1].description == null);
}

test "ORM where - simple condition" {
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
        users.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), users.items.len);
    try std.testing.expectEqualStrings("Alice", users.items[0].name);
    try std.testing.expectEqualStrings("Charlie", users.items[1].name);
}

test "ORM where - empty result" {
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

    var users = try orm.where(User, "id = 999");
    defer {
        for (users.items) |user| {
            allocator.free(user.name);
        }
        users.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 0), users.items.len);
}

test "ORM update - basic update" {
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

test "ORM update - with optional fields (null skipped)" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []const u8,
        description: ?[]const u8 = null,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT, description TEXT)");
    try db.execute("INSERT INTO User (name, description) VALUES ('Alice', 'Original')");

    var orm = ORM.init(db, allocator);

    const updated_user = User{
        .id = 1,
        .name = "Bob",
        .description = null, // This should be skipped in UPDATE
    };

    try orm.update(User, updated_user);

    // Verify name was updated but description remains unchanged
    var result = try orm.query("SELECT name, description FROM User WHERE id = 1");
    defer result.deinit();

    const row = result.nextRow();
    try std.testing.expect(row != null);
    try std.testing.expectEqualStrings("Bob", row.?.getText(0).?);
    try std.testing.expectEqualStrings("Original", row.?.getText(1).?);
}

test "ORM update - with enum field" {
    const allocator = std.testing.allocator;

    const Status = enum { pending, active, completed };
    const User = struct {
        id: i64,
        name: []const u8,
        status: Status,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT, status INTEGER)");
    try db.execute("INSERT INTO User (name, status) VALUES ('Alice', 0)");

    var orm = ORM.init(db, allocator);

    const updated_user = User{
        .id = 1,
        .name = "Alice",
        .status = .completed,
    };

    try orm.update(User, updated_user);

    const user = try orm.find(User, 1);
    defer if (user) |u| allocator.free(u.name);

    try std.testing.expect(user != null);
    try std.testing.expect(user.?.status == Status.completed);
}

test "ORM delete - basic delete" {
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
        users.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), users.items.len);
    try std.testing.expectEqualStrings("Bob", users.items[0].name);
}

test "ORM delete - non-existent record" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT)");

    var orm = ORM.init(db, allocator);

    // Deleting non-existent record should not error
    try orm.delete(User, 999);

    var users = try orm.findAll(User);
    defer {
        for (users.items) |user| {
            allocator.free(user.name);
        }
        users.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 0), users.items.len);
}

test "ORM full CRUD cycle" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []const u8,
        age: i32,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE User (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, age INTEGER)");

    var orm = ORM.init(db, allocator);

    // Create
    const user1 = User{ .id = 0, .name = "Alice", .age = 25 };
    try orm.create(User, user1);

    // Read
    var users = try orm.findAll(User);
    defer {
        for (users.items) |user| {
            allocator.free(user.name);
        }
        users.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), users.items.len);
    const id = users.items[0].id;

    // Update
    const updated = User{ .id = id, .name = "Bob", .age = 30 };
    try orm.update(User, updated);

    // Verify update
    const found = try orm.find(User, id);
    defer if (found) |u| allocator.free(u.name);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("Bob", found.?.name);
    try std.testing.expectEqual(@as(i32, 30), found.?.age);

    // Delete
    try orm.delete(User, id);

    // Verify delete
    var final_users = try orm.findAll(User);
    defer {
        for (final_users.items) |user| {
            allocator.free(user.name);
        }
        final_users.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), final_users.items.len);
}

test "ORM findAll - column count mismatch detection" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    // Create table with more columns than struct fields (use lowercase to match getTableName)
    try db.execute("CREATE TABLE user (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    var orm = ORM.init(db, allocator);

    const result = orm.findAll(User);
    try std.testing.expectError(error.ColumnMismatch, result);
}

test "ORM where - column count mismatch detection" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    // Create table with more columns than struct fields (use lowercase to match getTableName)
    try db.execute("CREATE TABLE user (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    var orm = ORM.init(db, allocator);

    const result = orm.where(User, "id = 1");
    try std.testing.expectError(error.ColumnMismatch, result);
}

test "ORM findAll - table not found error" {
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

test "ORM where - table not found error" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var orm = ORM.init(db, allocator);

    const result = orm.where(User, "id = 1");
    try std.testing.expectError(error.QueryFailed, result);
}
