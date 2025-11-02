const std = @import("std");
const Database = @import("database.zig").Database;
const Migration = @import("migration.zig").Migration;

pub const MigrationRunner = struct {
    db: *Database,
    allocator: std.mem.Allocator,

    pub fn init(db: *Database, allocator: std.mem.Allocator) MigrationRunner {
        return MigrationRunner{
            .db = db,
            .allocator = allocator,
        };
    }

    pub fn createMigrationsTable(self: *MigrationRunner) !void {
        const sql =
            \\CREATE TABLE IF NOT EXISTS schema_migrations (
            \\  version INTEGER PRIMARY KEY,
            \\  name TEXT NOT NULL,
            \\  applied_at INTEGER NOT NULL
            \\);
        ;
        try self.db.execute(sql);
    }

    pub fn getCurrentVersion(self: *MigrationRunner) !?u32 {
        try self.createMigrationsTable();

        var result = try self.db.query("SELECT MAX(version) FROM schema_migrations");
        defer result.deinit();

        if (result.nextRow()) |row| {
            if (row.is_null(0)) {
                return null;
            }
            return @as(u32, @intCast(row.getInt64(0)));
        }

        return null;
    }

    pub fn isApplied(self: *MigrationRunner, version: u32) !bool {
        try self.createMigrationsTable();

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT COUNT(*) FROM schema_migrations WHERE version = {d}",
            .{version},
        );
        defer self.allocator.free(sql);

        var result = try self.db.query(sql);
        defer result.deinit();

        if (result.nextRow()) |row| {
            return row.getInt64(0) > 0;
        }

        return false;
    }

    pub fn runMigrations(self: *MigrationRunner, migrations: []const Migration) !void {
        try self.createMigrationsTable();

        const current_version = try self.getCurrentVersion();

        for (migrations) |migration| {
            // Skip if already applied
            if (current_version) |cv| {
                if (migration.version <= cv) {
                    continue;
                }
            }

            // Check for duplicate
            if (try self.isApplied(migration.version)) {
                return error.DuplicateMigrationVersion;
            }

            // Run migration in transaction
            var trans = try self.db.beginTransaction();
            defer trans.deinit();

            trans.execute(migration.up) catch |err| {
                trans.rollback() catch {};
                return err;
            };

            const timestamp = std.time.timestamp();
            // Escape single quotes in migration name
            var escaped_name = std.ArrayListUnmanaged(u8){};
            defer escaped_name.deinit(self.allocator);
            try escaped_name.ensureTotalCapacity(self.allocator, migration.name.len * 2);
            for (migration.name) |char| {
                if (char == '\'') {
                    try escaped_name.append(self.allocator, '\'');
                    try escaped_name.append(self.allocator, '\'');
                } else {
                    try escaped_name.append(self.allocator, char);
                }
            }

            const insert_sql = try std.fmt.allocPrint(
                self.allocator,
                "INSERT INTO schema_migrations (version, name, applied_at) VALUES ({d}, '{s}', {d})",
                .{ migration.version, escaped_name.items, timestamp },
            );
            defer self.allocator.free(insert_sql);

            trans.execute(insert_sql) catch |err| {
                trans.rollback() catch {};
                return err;
            };

            trans.commit() catch |err| {
                trans.rollback() catch {};
                return err;
            };
        }
    }

    pub fn rollbackMigration(self: *MigrationRunner, version: u32, migrations: []const Migration) !void {
        try self.createMigrationsTable();

        // Find migration
        var migration: ?Migration = null;
        for (migrations) |m| {
            if (m.version == version) {
                migration = m;
                break;
            }
        }

        if (migration == null) {
            return error.MigrationNotFound;
        }

        // Check if applied
        if (!try self.isApplied(version)) {
            return error.MigrationNotApplied;
        }

        const m = migration.?;

        // Run rollback in transaction
        var trans = try self.db.beginTransaction();
        defer trans.deinit();

        trans.execute(m.down) catch |err| {
            trans.rollback() catch {};
            return err;
        };

        const delete_sql = try std.fmt.allocPrint(
            self.allocator,
            "DELETE FROM schema_migrations WHERE version = {d}",
            .{version},
        );
        defer self.allocator.free(delete_sql);

        trans.execute(delete_sql) catch |err| {
            trans.rollback() catch {};
            return err;
        };

        trans.commit() catch |err| {
            trans.rollback() catch {};
            return err;
        };
    }

    pub const Error = error{
        DuplicateMigrationVersion,
        MigrationNotFound,
        MigrationNotApplied,
    };
};

test "MigrationRunner create migrations table" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var runner = MigrationRunner.init(&db, allocator);
    try runner.createMigrationsTable();

    var result = try db.query("SELECT COUNT(*) FROM schema_migrations");
    defer result.deinit();

    if (result.nextRow()) |row| {
        const count = row.getInt64(0);
        try std.testing.expectEqual(@as(i64, 0), count);
    }
}

test "MigrationRunner getCurrentVersion empty" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var runner = MigrationRunner.init(&db, allocator);
    const version = try runner.getCurrentVersion();
    try std.testing.expect(version == null);
}

test "MigrationRunner runMigrations" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var runner = MigrationRunner.init(&db, allocator);

    const migrations = [_]Migration{
        Migration.init(1, "create_users", "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);", "DROP TABLE users;"),
    };

    try runner.runMigrations(&migrations);

    var result = try db.query("SELECT COUNT(*) FROM users");
    defer result.deinit();

    if (result.nextRow()) |row| {
        const count = row.getInt64(0);
        try std.testing.expectEqual(@as(i64, 0), count);
    }

    const version = try runner.getCurrentVersion();
    try std.testing.expect(version != null);
    try std.testing.expectEqual(@as(u32, 1), version.?);
}

test "MigrationRunner runMigrations multiple" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var runner = MigrationRunner.init(&db, allocator);

    const migrations = [_]Migration{
        Migration.init(1, "create_users", "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);", "DROP TABLE users;"),
        Migration.init(2, "add_email", "ALTER TABLE users ADD COLUMN email TEXT;", "ALTER TABLE users DROP COLUMN email;"),
    };

    try runner.runMigrations(&migrations);

    const version = try runner.getCurrentVersion();
    try std.testing.expect(version != null);
    try std.testing.expectEqual(@as(u32, 2), version.?);

    var result = try db.query("SELECT COUNT(*) FROM users");
    defer result.deinit();
    if (result.nextRow()) |row| {
        try std.testing.expectEqual(@as(i64, 0), row.getInt64(0));
    }
}

test "MigrationRunner rollbackMigration" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var runner = MigrationRunner.init(&db, allocator);

    const migrations = [_]Migration{
        Migration.init(1, "create_users", "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);", "DROP TABLE users;"),
    };

    try runner.runMigrations(&migrations);
    try runner.rollbackMigration(1, &migrations);

    const version = try runner.getCurrentVersion();
    try std.testing.expect(version == null);
}

