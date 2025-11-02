const std = @import("std");
const Database = @import("database.zig").Database;

pub const Migration = struct {
    version: u32,
    name: []const u8,
    up: []const u8,
    down: []const u8,

    pub fn init(version: u32, name: []const u8, up: []const u8, down: []const u8) Migration {
        return Migration{
            .version = version,
            .name = name,
            .up = up,
            .down = down,
        };
    }
};

pub const MigrationRegistry = struct {
    migrations: std.ArrayListUnmanaged(Migration),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MigrationRegistry {
        return MigrationRegistry{
            .migrations = std.ArrayListUnmanaged(Migration){},
            .allocator = allocator,
        };
    }

    pub fn add(self: *MigrationRegistry, migration: Migration) !void {
        // Check for duplicate versions
        for (self.migrations.items) |m| {
            if (m.version == migration.version) {
                return error.DuplicateMigrationVersion;
            }
        }

        try self.migrations.append(self.allocator, migration);

        // Sort by version
        std.mem.sort(Migration, self.migrations.items, {}, struct {
            fn lessThan(_: void, a: Migration, b: Migration) bool {
                return a.version < b.version;
            }
        }.lessThan);
    }

    pub fn getMigrations(self: *MigrationRegistry) []Migration {
        return self.migrations.items;
    }

    pub fn deinit(self: *MigrationRegistry) void {
        self.migrations.deinit(self.allocator);
    }
};

pub const MigrationBuilder = struct {
    version: u32,
    name: []const u8,
    up_sql: std.ArrayListUnmanaged(u8),
    down_sql: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn init(version: u32, name: []const u8, allocator: std.mem.Allocator) MigrationBuilder {
        return MigrationBuilder{
            .version = version,
            .name = name,
            .up_sql = std.ArrayListUnmanaged(u8){},
            .down_sql = std.ArrayListUnmanaged(u8){},
            .allocator = allocator,
        };
    }

    pub fn up(self: *MigrationBuilder, sql: []const u8) !void {
        try self.up_sql.appendSlice(self.allocator, sql);
        try self.up_sql.append(self.allocator, '\n');
    }

    pub fn down(self: *MigrationBuilder, sql: []const u8) !void {
        try self.down_sql.appendSlice(self.allocator, sql);
        try self.down_sql.append(self.allocator, '\n');
    }

    pub fn createTable(self: *MigrationBuilder, table_name: []const u8, columns: []const struct { name: []const u8, type: []const u8, constraints: []const u8 }) !void {
        try self.up_sql.writer(self.allocator).print("CREATE TABLE {s} (", .{table_name});
        for (columns, 0..) |col, i| {
            if (i > 0) {
                try self.up_sql.append(self.allocator, ',');
            }
            try self.up_sql.writer(self.allocator).print(" {s} {s}", .{ col.name, col.type });
            if (col.constraints.len > 0) {
                try self.up_sql.append(self.allocator, ' ');
                try self.up_sql.appendSlice(self.allocator, col.constraints);
            }
        }
        try self.up_sql.append(self.allocator, ' ');
        try self.up_sql.append(self.allocator, ')');
        try self.up_sql.append(self.allocator, ';');
        try self.up_sql.append(self.allocator, '\n');

        try self.down_sql.writer(self.allocator).print("DROP TABLE IF EXISTS {s};", .{table_name});
        try self.down_sql.append(self.allocator, '\n');
    }

    pub fn dropTable(self: *MigrationBuilder, table_name: []const u8) !void {
        try self.up_sql.writer(self.allocator).print("DROP TABLE IF EXISTS {s};", .{table_name});
        try self.up_sql.append(self.allocator, '\n');

        try self.down_sql.writer(self.allocator).print("-- Table {s} dropped, cannot recreate automatically", .{table_name});
        try self.down_sql.append(self.allocator, '\n');
    }

    pub fn alterTable(self: *MigrationBuilder, table_name: []const u8, alter_sql: []const u8) !void {
        try self.up_sql.writer(self.allocator).print("ALTER TABLE {s} {s};", .{ table_name, alter_sql });
        try self.up_sql.append(self.allocator, '\n');

        try self.down_sql.writer(self.allocator).print("-- ALTER TABLE {s} {s} cannot be automatically reversed", .{ table_name, alter_sql });
        try self.down_sql.append(self.allocator, '\n');
    }

    pub fn build(self: *MigrationBuilder) !Migration {
        const up_sql = try self.up_sql.toOwnedSlice(self.allocator);
        const down_sql = try self.down_sql.toOwnedSlice(self.allocator);

        return Migration{
            .version = self.version,
            .name = self.name,
            .up = up_sql,
            .down = down_sql,
        };
    }

    pub fn deinit(self: *MigrationBuilder) void {
        self.up_sql.deinit(self.allocator);
        self.down_sql.deinit(self.allocator);
    }
};

test "Migration init" {
    const migration = Migration.init(1, "create_users", "CREATE TABLE users (id INTEGER PRIMARY KEY);", "DROP TABLE users;");
    try std.testing.expectEqual(@as(u32, 1), migration.version);
    try std.testing.expectEqualStrings("create_users", migration.name);
}

test "MigrationRegistry add and sort" {
    const allocator = std.testing.allocator;
    var registry = MigrationRegistry.init(allocator);
    defer registry.deinit();

    try registry.add(Migration.init(2, "add_email", "ALTER TABLE users ADD COLUMN email TEXT;", "ALTER TABLE users DROP COLUMN email;"));
    try registry.add(Migration.init(1, "create_users", "CREATE TABLE users (id INTEGER PRIMARY KEY);", "DROP TABLE users;"));

    const migrations = registry.getMigrations();
    try std.testing.expectEqual(@as(usize, 2), migrations.len);
    try std.testing.expectEqual(@as(u32, 1), migrations[0].version);
    try std.testing.expectEqual(@as(u32, 2), migrations[1].version);
}

test "MigrationRegistry duplicate version" {
    const allocator = std.testing.allocator;
    var registry = MigrationRegistry.init(allocator);
    defer registry.deinit();

    try registry.add(Migration.init(1, "create_users", "CREATE TABLE users (id INTEGER PRIMARY KEY);", "DROP TABLE users;"));
    try std.testing.expectError(error.DuplicateMigrationVersion, registry.add(Migration.init(1, "create_posts", "CREATE TABLE posts (id INTEGER PRIMARY KEY);", "DROP TABLE posts;")));
}

test "MigrationBuilder createTable" {
    const allocator = std.testing.allocator;
    var builder = MigrationBuilder.init(1, "create_users", allocator);
    defer builder.deinit();

    try builder.createTable("users", &.{
        .{ .name = "id", .type = "INTEGER", .constraints = "PRIMARY KEY" },
        .{ .name = "name", .type = "TEXT", .constraints = "NOT NULL" },
    });

    const migration = try builder.build();
    defer allocator.free(migration.up);
    defer allocator.free(migration.down);

    try std.testing.expect(std.mem.indexOf(u8, migration.up, "CREATE TABLE users") != null);
    try std.testing.expect(std.mem.indexOf(u8, migration.down, "DROP TABLE") != null);
}

