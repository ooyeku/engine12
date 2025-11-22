const std = @import("std");
const Migration = @import("migration.zig").Migration;
const MigrationRegistry = @import("migration.zig").MigrationRegistry;

/// Discover migrations from a migrations directory
/// First attempts to use migrations/init.zig convention (if path is provided as comptime)
/// Falls back to scanning the directory for numbered migration files
///
/// Example:
/// ```zig
/// var registry = try discoverMigrations(allocator, "src/migrations");
/// defer registry.deinit();
/// try orm.runMigrationsFromRegistry(&registry);
/// ```
pub fn discoverMigrations(
    allocator: std.mem.Allocator,
    migrations_dir: []const u8,
) !MigrationRegistry {
    var registry = MigrationRegistry.init(allocator);

    // Try to open the migrations directory
    var dir = std.fs.cwd().openDir(migrations_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("[Engine12] Warning: Could not open migrations directory '{s}': {}\n", .{ migrations_dir, err });
        return registry; // Return empty registry gracefully
    };
    defer dir.close();

    var iterator = dir.iterate();
    const MigrationFileInfo = struct {
        version: u32,
        name: []const u8,
        path: []const u8,
    };
    var migration_files = try std.ArrayList(MigrationFileInfo).initCapacity(allocator, 10);
    defer {
        for (migration_files.items) |item| {
            allocator.free(item.name);
            allocator.free(item.path);
        }
        migration_files.deinit(allocator);
    }

    // First, check for init.zig (convention-based approach)
    const init_path = try std.fmt.allocPrint(allocator, "{s}/init.zig", .{migrations_dir});
    defer allocator.free(init_path);

    const init_file_result = std.fs.cwd().openFile(init_path, .{});
    if (init_file_result) |init_file| {
        init_file.close();
        // If init.zig exists, we expect the user to import it manually
        // This function focuses on directory scanning
        std.debug.print("[Engine12] Info: migrations/init.zig found. For comptime imports, use @import(\"migrations/init.zig\") directly.\n", .{});
    } else |err| {
        if (err != error.FileNotFound) {
            std.debug.print("[Engine12] Warning: Could not read migrations/init.zig: {}\n", .{err});
        }
        // Fall through to directory scanning
    }

    // Scan directory for numbered migration files: {number}_{name}.zig
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;

        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".zig")) continue;
        if (std.mem.eql(u8, name, "init.zig")) continue; // Skip init.zig

        // Parse filename: {number}_{name}.zig
        const underscore_pos = std.mem.indexOfScalar(u8, name, '_') orelse {
            std.debug.print("[Engine12] Warning: Skipping migration file '{s}' (doesn't match pattern: number_name.zig)\n", .{name});
            continue;
        };

        // Extract version number
        const version_str = name[0..underscore_pos];
        const version = std.fmt.parseInt(u32, version_str, 10) catch {
            std.debug.print("[Engine12] Warning: Skipping migration file '{s}' (invalid version number)\n", .{name});
            continue;
        };

        // Extract migration name (remove .zig extension)
        const name_start = underscore_pos + 1;
        const name_end = name.len - 4; // Remove .zig
        const migration_name = try allocator.dupe(u8, name[name_start..name_end]);
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ migrations_dir, name });

        try migration_files.append(allocator, .{
            .version = version,
            .name = migration_name,
            .path = full_path,
        });
    }

    // Sort by version
    std.mem.sort(MigrationFileInfo, migration_files.items, {}, struct {
        fn lessThan(_: void, a: MigrationFileInfo, b: MigrationFileInfo) bool {
            return a.version < b.version;
        }
    }.lessThan);

    // Parse each migration file
    for (migration_files.items) |file_info| {
        const migration = parseMigrationFile(allocator, file_info.path, file_info.version, file_info.name) catch |err| {
            std.debug.print("[Engine12] Warning: Failed to parse migration file '{s}': {}\n", .{ file_info.path, err });
            continue; // Skip this migration but continue with others
        };

        try registry.add(migration);
    }

    return registry;
}

/// Parse a migration file to extract up and down SQL
/// Expected format:
/// ```zig
/// pub const migration = Migration.init(
///     version,
///     "name",
///     "UP SQL HERE",
///     "DOWN SQL HERE"
/// );
/// ```
fn parseMigrationFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    version: u32,
    name: []const u8,
) !Migration {
    const content = try std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024); // 10KB max
    defer allocator.free(content);

    // Simple parser: look for Migration.init(version, "name", "up_sql", "down_sql")
    // This is a basic parser - for more complex cases, users should use init.zig

    const init_start = std.mem.indexOf(u8, content, "Migration.init") orelse {
        return error.InvalidMigrationFormat;
    };

    var pos = init_start + "Migration.init".len;

    // Skip whitespace and opening parenthesis
    while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n' or content[pos] == '(')) {
        pos += 1;
    }

    // Skip version (we already have it)
    while (pos < content.len and (content[pos] == '0' or content[pos] == '1' or content[pos] == '2' or content[pos] == '3' or content[pos] == '4' or content[pos] == '5' or content[pos] == '6' or content[pos] == '7' or content[pos] == '8' or content[pos] == '9')) {
        pos += 1;
    }

    // Skip comma and whitespace
    while (pos < content.len and (content[pos] == ',' or content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n')) {
        pos += 1;
    }

    // Extract name (string literal) - we already have the name parameter, so just skip it
    if (pos >= content.len or content[pos] != '"') {
        return error.InvalidMigrationFormat;
    }
    pos += 1; // Skip opening quote
    while (pos < content.len and content[pos] != '"') {
        if (content[pos] == '\\') pos += 1; // Skip escaped characters
        pos += 1;
    }
    pos += 1; // Skip closing quote

    // Skip comma and whitespace
    while (pos < content.len and (content[pos] == ',' or content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n')) {
        pos += 1;
    }

    // Extract up SQL (string literal or raw string)
    var up_sql: []const u8 = undefined;
    if (pos < content.len and content[pos] == '"') {
        // Regular string
        pos += 1;
        const up_start = pos;
        while (pos < content.len and content[pos] != '"') {
            if (content[pos] == '\\') pos += 1;
            pos += 1;
        }
        up_sql = content[up_start..pos];
        pos += 1;
    } else if (pos < content.len and std.mem.startsWith(u8, content[pos..], "\\\\")) {
        // Raw string: \\SQL HERE\\
        pos += 2; // Skip \\
        const up_start = pos;
        while (pos < content.len - 1 and !std.mem.startsWith(u8, content[pos..], "\\\\")) {
            pos += 1;
        }
        up_sql = content[up_start..pos];
        pos += 2; // Skip closing \\
    } else {
        return error.InvalidMigrationFormat;
    }

    // Skip comma and whitespace
    while (pos < content.len and (content[pos] == ',' or content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n')) {
        pos += 1;
    }

    // Extract down SQL (same as up)
    var down_sql: []const u8 = undefined;
    if (pos < content.len and content[pos] == '"') {
        pos += 1;
        const down_start = pos;
        while (pos < content.len and content[pos] != '"') {
            if (content[pos] == '\\') pos += 1;
            pos += 1;
        }
        down_sql = content[down_start..pos];
        pos += 1;
    } else if (pos < content.len and std.mem.startsWith(u8, content[pos..], "\\\\")) {
        pos += 2;
        const down_start = pos;
        while (pos < content.len - 1 and !std.mem.startsWith(u8, content[pos..], "\\\\")) {
            pos += 1;
        }
        down_sql = content[down_start..pos];
        pos += 2;
    } else {
        return error.InvalidMigrationFormat;
    }

    // Allocate copies of SQL strings
    const up_copy = try allocator.dupe(u8, up_sql);
    const down_copy = try allocator.dupe(u8, down_sql);

    return Migration.init(version, name, up_copy, down_copy);
}

test "discoverMigrations with empty directory" {
    const allocator = std.testing.allocator;
    const test_dir = "test_migrations_empty";

    // Create empty directory
    std.fs.cwd().makeDir(test_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var registry = try discoverMigrations(allocator, test_dir);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.getMigrations().len);
}

test "discoverMigrations with numbered files" {
    const allocator = std.testing.allocator;
    const test_dir = "test_migrations_numbered";

    // Create test directory
    std.fs.cwd().makeDir(test_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.fs.cwd().deleteTree(test_dir) catch {};
            try std.fs.cwd().makeDir(test_dir);
        }
    };
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create test migration files
    const file1_content =
        \\pub const migration = Migration.init(
        \\    1,
        \\    "create_users",
        \\    "CREATE TABLE users (id INTEGER PRIMARY KEY);",
        \\    "DROP TABLE users;"
        \\);
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/1_create_users.zig", .{test_dir}), .data = file1_content });

    const file2_content =
        \\pub const migration = Migration.init(
        \\    2,
        \\    "add_email",
        \\    "ALTER TABLE users ADD COLUMN email TEXT;",
        \\    "ALTER TABLE users DROP COLUMN email;"
        \\);
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/2_add_email.zig", .{test_dir}), .data = file2_content });

    var registry = try discoverMigrations(allocator, test_dir);
    defer registry.deinit();

    const migrations = registry.getMigrations();
    try std.testing.expectEqual(@as(usize, 2), migrations.len);
    try std.testing.expectEqual(@as(u32, 1), migrations[0].version);
    try std.testing.expectEqual(@as(u32, 2), migrations[1].version);
    try std.testing.expectEqualStrings("create_users", migrations[0].name);
    try std.testing.expectEqualStrings("add_email", migrations[1].name);
}

test "discoverMigrations with non-existent directory" {
    const allocator = std.testing.allocator;

    var registry = try discoverMigrations(allocator, "non_existent_migrations_dir_12345");
    defer registry.deinit();

    // Should return empty registry gracefully
    try std.testing.expectEqual(@as(usize, 0), registry.getMigrations().len);
}
