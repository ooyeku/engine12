const std = @import("std");
const Database = @import("database.zig").Database;
const QueryResult = @import("row.zig").QueryResult;

/// Information about a database column
pub const ColumnInfo = struct {
    /// Column name
    name: []const u8,
    /// Column type (TEXT, INTEGER, etc.)
    type: []const u8,
    /// Whether the column is NOT NULL
    not_null: bool,
    /// Default value (if any)
    default_value: ?[]const u8,
    /// Whether this is a primary key
    primary_key: bool,
};

/// Database schema introspection utilities
/// Provides functions to inspect database schema structure
pub const Schema = struct {
    /// Check if a column exists in a table
    /// 
    /// Example:
    /// ```zig
    /// const exists = try Schema.columnExists(&db, "Todo", "priority");
    /// if (!exists) {
    ///     try db.execute("ALTER TABLE Todo ADD COLUMN priority TEXT");
    /// }
    /// ```
    pub fn columnExists(db: *Database, table: []const u8, column: []const u8) !bool {
        const sql = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "PRAGMA table_info({s})",
            .{table},
        );
        defer std.heap.page_allocator.free(sql);

        var result = try db.query(sql);
        defer result.deinit();

        while (result.nextRow()) |row| {
            // PRAGMA table_info returns: cid, name, type, notnull, dflt_value, pk
            // Column name is at index 1
            if (row.getText(1)) |col_name| {
                if (std.mem.eql(u8, col_name, column)) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Get all columns for a table
    /// Returns an array of ColumnInfo structs
    /// 
    /// Example:
    /// ```zig
    /// const columns = try Schema.getColumns(&db, "Todo", allocator);
    /// defer {
    ///     for (columns) |col| {
    ///         allocator.free(col.name);
    ///         allocator.free(col.type);
    ///         if (col.default_value) |dv| allocator.free(dv);
    ///     }
    ///     allocator.free(columns);
    /// }
    /// ```
    pub fn getColumns(db: *Database, table: []const u8, allocator: std.mem.Allocator) ![]ColumnInfo {
        const sql = try std.fmt.allocPrint(
            allocator,
            "PRAGMA table_info({s})",
            .{table},
        );
        defer allocator.free(sql);

        var result = try db.query(sql);
        defer result.deinit();

        var columns = std.ArrayListUnmanaged(ColumnInfo){};
        defer columns.deinit(allocator);

        while (result.nextRow()) |row| {
            // PRAGMA table_info returns: cid, name, type, notnull, dflt_value, pk
            const name = row.getText(1) orelse continue;
            const type_str = row.getText(2) orelse continue;
            const notnull = row.getInt64(3) orelse 0;
            const default_val = row.getText(4);
            const pk = row.getInt64(5) orelse 0;

            const name_copy = try allocator.dupe(u8, name);
            errdefer allocator.free(name_copy);
            const type_copy = try allocator.dupe(u8, type_str);
            errdefer allocator.free(type_copy);
            const default_copy = if (default_val) |dv| try allocator.dupe(u8, dv) else null;
            errdefer if (default_copy) |dv| allocator.free(dv);

            try columns.append(allocator, ColumnInfo{
                .name = name_copy,
                .type = type_copy,
                .not_null = (notnull != 0),
                .default_value = default_copy,
                .primary_key = (pk != 0),
            });
        }

        return columns.toOwnedSlice(allocator);
    }

    /// Check if a table exists in the database
    /// 
    /// Example:
    /// ```zig
    /// const exists = try Schema.tableExists(&db, "Todo");
    /// if (!exists) {
    ///     try db.execute("CREATE TABLE Todo ...");
    /// }
    /// ```
    pub fn tableExists(db: *Database, table: []const u8) !bool {
        const sql = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='{s}'",
            .{table},
        );
        defer std.heap.page_allocator.free(sql);

        var result = try db.query(sql);
        defer result.deinit();

        return (result.nextRow() != null);
    }
};

// Tests
test "Schema.tableExists" {
    const allocator = std.testing.allocator;
    const test_db_path = ":memory:";
    
    var db = try Database.open(test_db_path, allocator);
    defer db.close();
    
    // Create a test table
    try db.execute("CREATE TABLE test_table (id INTEGER PRIMARY KEY, name TEXT)");
    
    // Test table exists
    const exists = try Schema.tableExists(&db, "test_table");
    try std.testing.expect(exists);
    
    // Test non-existent table
    const not_exists = try Schema.tableExists(&db, "nonexistent");
    try std.testing.expect(!not_exists);
}

test "Schema.columnExists" {
    const allocator = std.testing.allocator;
    const test_db_path = ":memory:";
    
    var db = try Database.open(test_db_path, allocator);
    defer db.close();
    
    // Create a test table
    try db.execute("CREATE TABLE test_table (id INTEGER PRIMARY KEY, name TEXT)");
    
    // Test column exists
    const id_exists = try Schema.columnExists(&db, "test_table", "id");
    try std.testing.expect(id_exists);
    
    const name_exists = try Schema.columnExists(&db, "test_table", "name");
    try std.testing.expect(name_exists);
    
    // Test non-existent column
    const not_exists = try Schema.columnExists(&db, "test_table", "nonexistent");
    try std.testing.expect(!not_exists);
}

test "Schema.getColumns" {
    const allocator = std.testing.allocator;
    const test_db_path = ":memory:";
    
    var db = try Database.open(test_db_path, allocator);
    defer db.close();
    
    // Create a test table
    try db.execute("CREATE TABLE test_table (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT 'default')");
    
    const columns = try Schema.getColumns(&db, "test_table", allocator);
    defer {
        for (columns) |col| {
            allocator.free(col.name);
            allocator.free(col.type);
            if (col.default_value) |dv| allocator.free(dv);
        }
        allocator.free(columns);
    }
    
    try std.testing.expect(columns.len == 2);
    
    // Find id column
    var found_id = false;
    var found_name = false;
    for (columns) |col| {
        if (std.mem.eql(u8, col.name, "id")) {
            found_id = true;
            try std.testing.expect(col.primary_key);
            try std.testing.expect(std.mem.eql(u8, col.type, "INTEGER"));
        } else if (std.mem.eql(u8, col.name, "name")) {
            found_name = true;
            try std.testing.expect(col.not_null);
            try std.testing.expect(std.mem.eql(u8, col.type, "TEXT"));
            try std.testing.expect(col.default_value != null);
        }
    }
    
    try std.testing.expect(found_id);
    try std.testing.expect(found_name);
}

