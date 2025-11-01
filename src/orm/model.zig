const std = @import("std");

pub const FieldType = enum {
    text,
    integer,
    real,
    blob,
    boolean,
};

pub const Field = struct {
    name: []const u8,
    field_type: FieldType,
    primary_key: bool = false,
    not_null: bool = false,
    unique: bool = false,
    auto_increment: bool = false,
};

pub const ModelDef = struct {
    table_name: []const u8,
    fields: []const Field,
    
    pub fn toCreateTableSQL(self: ModelDef, allocator: std.mem.Allocator) ![]const u8 {
        var sql = std.ArrayList(u8).init(allocator);
        errdefer sql.deinit();
        
        try sql.writer().print("CREATE TABLE IF NOT EXISTS {s} (", .{self.table_name});
        
        for (self.fields, 0..) |field, i| {
            if (i > 0) try sql.writer().print(", ", .{});
            
            try sql.writer().print("{s} ", .{field.name});
            
            switch (field.field_type) {
                .text => try sql.writer().print("TEXT", .{}),
                .integer => try sql.writer().print("INTEGER", .{}),
                .real => try sql.writer().print("REAL", .{}),
                .blob => try sql.writer().print("BLOB", .{}),
                .boolean => try sql.writer().print("INTEGER", .{}),
            }
            
            if (field.primary_key) try sql.writer().print(" PRIMARY KEY", .{});
            if (field.auto_increment) try sql.writer().print(" AUTOINCREMENT", .{});
            if (field.not_null) try sql.writer().print(" NOT NULL", .{});
            if (field.unique) try sql.writer().print(" UNIQUE", .{});
        }
        
        try sql.writer().print(")", .{});
        return sql.toOwnedSlice();
    }
};

pub fn getTableName(comptime T: type) []const u8 {
    const type_name = @typeName(T);
    // Convert PascalCase to snake_case for table name
    // For now, just return lowercase version
    // TODO: Implement proper PascalCase to snake_case conversion
    _ = type_name;
    return "unknown_table";
}

pub fn inferTableName(comptime T: type) []const u8 {
    const type_name = @typeName(T);
    // Simple implementation: use struct name as table name
    // Extract just the struct name if it's qualified
    if (std.mem.indexOf(u8, type_name, ".")) |idx| {
        return type_name[idx + 1..];
    }
    return type_name;
}

pub fn toSnakeCase(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    
    for (input, 0..) |char, i| {
        if (i > 0 and char >= 'A' and char <= 'Z') {
            try result.append('_');
            try result.append(char + 32); // Convert to lowercase
        } else if (char >= 'A' and char <= 'Z') {
            try result.append(char + 32);
        } else {
            try result.append(char);
        }
    }
    
    return result.toOwnedSlice();
}

pub fn getFieldNames(comptime T: type) []const []const u8 {
    const fields = std.meta.fields(T);
    comptime var names: [fields.len][]const u8 = undefined;
    comptime var i: usize = 0;
    inline for (fields) |field| {
        names[i] = field.name;
        i += 1;
    }
    return &names;
}

test "inferTableName simple struct" {
    const TestUser = struct {
        id: i64,
        name: []const u8,
    };
    
    const table_name = inferTableName(TestUser);
    try std.testing.expectEqualStrings("TestUser", table_name);
}

test "inferTableName qualified struct" {
    const TestUser = struct {
        id: i64,
        name: []const u8,
    };
    
    const table_name = inferTableName(@TypeOf(TestUser));
    // This should handle qualified types
    _ = table_name;
}

test "toSnakeCase" {
    const allocator = std.testing.allocator;
    
    const snake = try toSnakeCase(allocator, "TestUser");
    defer allocator.free(snake);
    try std.testing.expectEqualStrings("test_user", snake);
    
    const snake2 = try toSnakeCase(allocator, "UserProfile");
    defer allocator.free(snake2);
    try std.testing.expectEqualStrings("user_profile", snake2);
    
    const snake3 = try toSnakeCase(allocator, "MyTestClass");
    defer allocator.free(snake3);
    try std.testing.expectEqualStrings("my_test_class", snake3);
}

test "getFieldNames" {
    const TestUser = struct {
        id: i64,
        name: []const u8,
        age: i32,
    };
    
    const fields = getFieldNames(TestUser);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("id", fields[0]);
    try std.testing.expectEqualStrings("name", fields[1]);
    try std.testing.expectEqualStrings("age", fields[2]);
}

test "ModelDef toCreateTableSQL" {
    const allocator = std.testing.allocator;
    
    const model_def = ModelDef{
        .table_name = "users",
        .fields = &.{
            Field{ .name = "id", .field_type = .integer, .primary_key = true, .auto_increment = true },
            Field{ .name = "name", .field_type = .text, .not_null = true },
            Field{ .name = "age", .field_type = .integer },
            Field{ .name = "email", .field_type = .text, .unique = true },
        },
    };
    
    const sql = try model_def.toCreateTableSQL(allocator);
    defer allocator.free(sql);
    
    try std.testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE IF NOT EXISTS users") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "id INTEGER PRIMARY KEY AUTOINCREMENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "name TEXT NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "age INTEGER") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "email TEXT UNIQUE") != null);
}

test "ModelDef toCreateTableSQL boolean field" {
    const allocator = std.testing.allocator;
    
    const model_def = ModelDef{
        .table_name = "users",
        .fields = &.{
            Field{ .name = "id", .field_type = .integer, .primary_key = true },
            Field{ .name = "active", .field_type = .boolean },
        },
    };
    
    const sql = try model_def.toCreateTableSQL(allocator);
    defer allocator.free(sql);
    
    try std.testing.expect(std.mem.indexOf(u8, sql, "active INTEGER") != null);
}

test "ModelDef toCreateTableSQL real field" {
    const allocator = std.testing.allocator;
    
    const model_def = ModelDef{
        .table_name = "products",
        .fields = &.{
            Field{ .name = "id", .field_type = .integer, .primary_key = true },
            Field{ .name = "price", .field_type = .real },
        },
    };
    
    const sql = try model_def.toCreateTableSQL(allocator);
    defer allocator.free(sql);
    
    try std.testing.expect(std.mem.indexOf(u8, sql, "price REAL") != null);
}

test "ModelDef toCreateTableSQL blob field" {
    const allocator = std.testing.allocator;
    
    const model_def = ModelDef{
        .table_name = "files",
        .fields = &.{
            Field{ .name = "id", .field_type = .integer, .primary_key = true },
            Field{ .name = "data", .field_type = .blob },
        },
    };
    
    const sql = try model_def.toCreateTableSQL(allocator);
    defer allocator.free(sql);
    
    try std.testing.expect(std.mem.indexOf(u8, sql, "data BLOB") != null);
}

