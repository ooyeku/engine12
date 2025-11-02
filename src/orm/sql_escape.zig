const std = @import("std");

/// SQL injection prevention utilities
/// Provides safe escaping for SQL strings, LIKE patterns, and identifiers
/// Currently supports SQLite dialect (can be extended for other databases)
pub const SqlEscape = struct {
    /// Escape a string for safe use in SQL queries
    /// SQLite escapes single quotes by doubling them: ' becomes ''
    /// 
    /// Example:
    /// ```zig
    /// const user_input = "O'Brien";
    /// const safe = try SqlEscape.escapeString(allocator, user_input);
    /// defer allocator.free(safe);
    /// // safe == "O''Brien"
    /// ```
    pub fn escapeString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        defer result.deinit(allocator);
        
        // Pre-allocate approximate capacity (worst case: all quotes)
        try result.ensureTotalCapacity(allocator, input.len * 2);
        
        for (input) |char| {
            if (char == '\'') {
                // SQLite escapes by doubling single quotes
                try result.append(allocator, '\'');
                try result.append(allocator, '\'');
            } else {
                try result.append(allocator, char);
            }
        }
        
        return result.toOwnedSlice(allocator);
    }

    /// Escape a string for safe use in SQL LIKE patterns
    /// Escapes both single quotes and LIKE wildcards (% and _)
    /// 
    /// Example:
    /// ```zig
    /// const user_input = "test%_data";
    /// const safe = try SqlEscape.escapeLikePattern(allocator, user_input);
    /// defer allocator.free(safe);
    /// // safe == "test\\%\\_data"
    /// ```
    pub fn escapeLikePattern(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        defer result.deinit(allocator);
        
        // Pre-allocate approximate capacity
        try result.ensureTotalCapacity(allocator, input.len * 3);
        
        for (input) |char| {
            switch (char) {
                '\'' => {
                    // SQLite escapes by doubling single quotes
                    try result.append(allocator, '\'');
                    try result.append(allocator, '\'');
                },
                '%' => {
                    // Escape LIKE wildcard
                    try result.append(allocator, '\\');
                    try result.append(allocator, '%');
                },
                '_' => {
                    // Escape LIKE wildcard
                    try result.append(allocator, '\\');
                    try result.append(allocator, '_');
                },
                '\\' => {
                    // Escape backslash itself
                    try result.append(allocator, '\\');
                    try result.append(allocator, '\\');
                },
                else => {
                    try result.append(allocator, char);
                },
            }
        }
        
        return result.toOwnedSlice(allocator);
    }

    /// Escape a SQL identifier (table name, column name) for safe use
    /// SQLite uses double quotes for identifiers
    /// 
    /// Example:
    /// ```zig
    /// const table_name = "my-table";
    /// const safe = try SqlEscape.escapeIdentifier(allocator, table_name);
    /// defer allocator.free(safe);
    /// // safe == "\"my-table\""
    /// ```
    pub fn escapeIdentifier(allocator: std.mem.Allocator, identifier: []const u8) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        defer result.deinit(allocator);
        
        // Pre-allocate capacity for quotes and potential doubling
        try result.ensureTotalCapacity(allocator, identifier.len * 2 + 2);
        
        // Opening quote
        try result.append(allocator, '"');
        
        for (identifier) |char| {
            if (char == '"') {
                // SQLite escapes double quotes by doubling them
                try result.append(allocator, '"');
                try result.append(allocator, '"');
            } else {
                try result.append(allocator, char);
            }
        }
        
        // Closing quote
        try result.append(allocator, '"');
        
        return result.toOwnedSlice(allocator);
    }
};

// Tests
test "SqlEscape.escapeString basic" {
    const allocator = std.testing.allocator;
    const input = "hello";
    const escaped = try SqlEscape.escapeString(allocator, input);
    defer allocator.free(escaped);
    
    try std.testing.expectEqualStrings("hello", escaped);
}

test "SqlEscape.escapeString with quotes" {
    const allocator = std.testing.allocator;
    const input = "O'Brien";
    const escaped = try SqlEscape.escapeString(allocator, input);
    defer allocator.free(escaped);
    
    try std.testing.expectEqualStrings("O''Brien", escaped);
}

test "SqlEscape.escapeString multiple quotes" {
    const allocator = std.testing.allocator;
    const input = "test'string'here";
    const escaped = try SqlEscape.escapeString(allocator, input);
    defer allocator.free(escaped);
    
    try std.testing.expectEqualStrings("test''string''here", escaped);
}

test "SqlEscape.escapeLikePattern basic" {
    const allocator = std.testing.allocator;
    const input = "test";
    const escaped = try SqlEscape.escapeLikePattern(allocator, input);
    defer allocator.free(escaped);
    
    try std.testing.expectEqualStrings("test", escaped);
}

test "SqlEscape.escapeLikePattern with wildcards" {
    const allocator = std.testing.allocator;
    const input = "test%_data";
    const escaped = try SqlEscape.escapeLikePattern(allocator, input);
    defer allocator.free(escaped);
    
    try std.testing.expectEqualStrings("test\\%\\_data", escaped);
}

test "SqlEscape.escapeLikePattern with quotes and wildcards" {
    const allocator = std.testing.allocator;
    const input = "test'%_data";
    const escaped = try SqlEscape.escapeLikePattern(allocator, input);
    defer allocator.free(escaped);
    
    try std.testing.expectEqualStrings("test''\\%\\_data", escaped);
}

test "SqlEscape.escapeIdentifier basic" {
    const allocator = std.testing.allocator;
    const input = "mytable";
    const escaped = try SqlEscape.escapeIdentifier(allocator, input);
    defer allocator.free(escaped);
    
    try std.testing.expectEqualStrings("\"mytable\"", escaped);
}

test "SqlEscape.escapeIdentifier with special chars" {
    const allocator = std.testing.allocator;
    const input = "my-table";
    const escaped = try SqlEscape.escapeIdentifier(allocator, input);
    defer allocator.free(escaped);
    
    try std.testing.expectEqualStrings("\"my-table\"", escaped);
}

test "SqlEscape.escapeIdentifier with quotes" {
    const allocator = std.testing.allocator;
    const input = "my\"table";
    const escaped = try SqlEscape.escapeIdentifier(allocator, input);
    defer allocator.free(escaped);
    
    try std.testing.expectEqualStrings("\"my\"\"table\"", escaped);
}

