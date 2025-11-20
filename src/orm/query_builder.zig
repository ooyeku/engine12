const std = @import("std");

pub const QueryBuilder = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8,
    select_fields: std.ArrayListUnmanaged([]const u8),
    where_clauses: std.ArrayListUnmanaged(WhereClause),
    limit_val: ?usize = null,
    offset_val: ?usize = null,
    order_by_field: ?[]const u8 = null,
    order_ascending: bool = true,
    join_clauses: std.ArrayListUnmanaged(JoinClause),
    
    pub const WhereClause = struct {
        field: []const u8,
        operator: []const u8,
        value: []const u8,
    };
    
    pub const JoinClause = struct {
        join_type: []const u8,
        table: []const u8,
        on: []const u8,
    };
    
    pub fn init(allocator: std.mem.Allocator, table_name: []const u8) QueryBuilder {
        return QueryBuilder{
            .allocator = allocator,
            .table_name = table_name,
            .select_fields = .{},
            .where_clauses = .{},
            .join_clauses = .{},
        };
    }
    
    pub fn deinit(self: *QueryBuilder) void {
        self.select_fields.deinit(self.allocator);
        self.where_clauses.deinit(self.allocator);
        self.join_clauses.deinit(self.allocator);
    }
    
    pub fn select(self: *QueryBuilder, fields: []const []const u8) *QueryBuilder {
        for (fields) |field| {
            self.select_fields.append(self.allocator, field) catch {};
        }
        return self;
    }
    
    pub fn where(self: *QueryBuilder, field: []const u8, operator: []const u8, value: []const u8) *QueryBuilder {
        self.where_clauses.append(self.allocator, .{
            .field = field,
            .operator = operator,
            .value = value,
        }) catch {};
        return self;
    }
    
    pub fn whereEq(self: *QueryBuilder, field: []const u8, value: []const u8) *QueryBuilder {
        return self.where(field, "=", value);
    }
    
    pub fn whereNe(self: *QueryBuilder, field: []const u8, value: []const u8) *QueryBuilder {
        return self.where(field, "!=", value);
    }
    
    pub fn whereGt(self: *QueryBuilder, field: []const u8, value: []const u8) *QueryBuilder {
        return self.where(field, ">", value);
    }
    
    pub fn whereLt(self: *QueryBuilder, field: []const u8, value: []const u8) *QueryBuilder {
        return self.where(field, "<", value);
    }
    
    pub fn whereGte(self: *QueryBuilder, field: []const u8, value: []const u8) *QueryBuilder {
        return self.where(field, ">=", value);
    }
    
    pub fn whereLte(self: *QueryBuilder, field: []const u8, value: []const u8) *QueryBuilder {
        return self.where(field, "<=", value);
    }
    
    pub fn limit(self: *QueryBuilder, count: usize) *QueryBuilder {
        self.limit_val = count;
        return self;
    }
    
    pub fn offset(self: *QueryBuilder, count: usize) *QueryBuilder {
        self.offset_val = count;
        return self;
    }
    
    pub fn orderBy(self: *QueryBuilder, field: []const u8, ascending: bool) *QueryBuilder {
        self.order_by_field = field;
        self.order_ascending = ascending;
        return self;
    }
    
    pub fn join(self: *QueryBuilder, join_type: []const u8, table: []const u8, on: []const u8) *QueryBuilder {
        self.join_clauses.append(self.allocator, .{
            .join_type = join_type,
            .table = table,
            .on = on,
        }) catch {};
        return self;
    }
    
    pub fn build(self: *QueryBuilder) ![]const u8 {
        var sql = std.ArrayListUnmanaged(u8){};
        errdefer sql.deinit(self.allocator);
        
        // SELECT clause
        try sql.writer(self.allocator).print("SELECT ", .{});
        if (self.select_fields.items.len > 0) {
            for (self.select_fields.items, 0..) |field, i| {
                if (i > 0) try sql.writer(self.allocator).print(", ", .{});
                try sql.writer(self.allocator).print("{s}", .{field});
            }
        } else {
            try sql.writer(self.allocator).print("*", .{});
        }
        
        // FROM clause
        try sql.writer(self.allocator).print(" FROM {s}", .{self.table_name});
        
        // JOIN clauses
        for (self.join_clauses.items) |join_clause| {
            try sql.writer(self.allocator).print(" {s} JOIN {s} ON {s}", .{ join_clause.join_type, join_clause.table, join_clause.on });
        }
        
        // WHERE clause
        if (self.where_clauses.items.len > 0) {
            try sql.writer(self.allocator).print(" WHERE ", .{});
            for (self.where_clauses.items, 0..) |clause, i| {
                if (i > 0) try sql.writer(self.allocator).print(" AND ", .{});
                // Escape single quotes in value
                var escaped_value = std.ArrayListUnmanaged(u8){};
                defer escaped_value.deinit(self.allocator);
                for (clause.value) |char| {
                    if (char == '\'') {
                        try escaped_value.append(self.allocator, '\'');
                        try escaped_value.append(self.allocator, '\'');
                    } else {
                        try escaped_value.append(self.allocator, char);
                    }
                }
                try sql.writer(self.allocator).print("{s} {s} '{s}'", .{ clause.field, clause.operator, escaped_value.items });
            }
        }
        
        // ORDER BY clause
        if (self.order_by_field) |field| {
            try sql.writer(self.allocator).print(" ORDER BY {s}", .{field});
            if (!self.order_ascending) try sql.writer(self.allocator).print(" DESC", .{});
        }
        
        // LIMIT clause
        if (self.limit_val) |limit_val| {
            try sql.writer(self.allocator).print(" LIMIT {d}", .{limit_val});
        }
        
        // OFFSET clause
        if (self.offset_val) |offset_val| {
            try sql.writer(self.allocator).print(" OFFSET {d}", .{offset_val});
        }
        
        return sql.toOwnedSlice(self.allocator);
    }
};

test "QueryBuilder basic SELECT" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();
    
    const sql = try builder.build();
    defer allocator.free(sql);
    
    try std.testing.expectEqualStrings("SELECT * FROM users", sql);
}

test "QueryBuilder SELECT with fields" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();
    
    const sql = try builder.select(&.{ "id", "name" }).build();
    defer allocator.free(sql);
    
    try std.testing.expectEqualStrings("SELECT id, name FROM users", sql);
}

test "QueryBuilder WHERE clause" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();
    
    const sql = try builder.whereEq("name", "Alice").build();
    defer allocator.free(sql);
    
    try std.testing.expectEqualStrings("SELECT * FROM users WHERE name = 'Alice'", sql);
}

test "QueryBuilder multiple WHERE clauses" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();
    
    const sql = try builder.whereEq("name", "Alice").whereGt("age", "18").build();
    defer allocator.free(sql);
    
    try std.testing.expect(std.mem.indexOf(u8, sql, "name = 'Alice'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "age > '18'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, " AND ") != null);
}

test "QueryBuilder WHERE with special characters" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();
    
    const sql = try builder.whereEq("name", "O'Reilly").build();
    defer allocator.free(sql);
    
    try std.testing.expect(std.mem.indexOf(u8, sql, "O''Reilly") != null);
}

test "QueryBuilder ORDER BY" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();
    
    const sql = try builder.orderBy("name", true).build();
    defer allocator.free(sql);
    
    try std.testing.expectEqualStrings("SELECT * FROM users ORDER BY name", sql);
}

test "QueryBuilder ORDER BY DESC" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();
    
    const sql = try builder.orderBy("name", false).build();
    defer allocator.free(sql);
    
    try std.testing.expectEqualStrings("SELECT * FROM users ORDER BY name DESC", sql);
}

test "QueryBuilder LIMIT" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();
    
    const sql = try builder.limit(10).build();
    defer allocator.free(sql);
    
    try std.testing.expectEqualStrings("SELECT * FROM users LIMIT 10", sql);
}

test "QueryBuilder OFFSET" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();
    
    const sql = try builder.offset(20).build();
    defer allocator.free(sql);
    
    try std.testing.expectEqualStrings("SELECT * FROM users OFFSET 20", sql);
}

test "QueryBuilder LIMIT and OFFSET" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();
    
    const sql = try builder.limit(10).offset(20).build();
    defer allocator.free(sql);
    
    try std.testing.expect(std.mem.indexOf(u8, sql, "LIMIT 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "OFFSET 20") != null);
}

test "QueryBuilder JOIN" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();
    
    const sql = try builder.join("INNER", "posts", "users.id = posts.user_id").build();
    defer allocator.free(sql);
    
    try std.testing.expect(std.mem.indexOf(u8, sql, "INNER JOIN posts ON users.id = posts.user_id") != null);
}

test "QueryBuilder complex query" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();
    
    const sql = try builder
        .select(&.{ "id", "name" })
        .whereEq("active", "1")
        .orderBy("name", true)
        .limit(10)
        .offset(0)
        .build();
    defer allocator.free(sql);
    
    try std.testing.expect(std.mem.indexOf(u8, sql, "SELECT id, name FROM users") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "WHERE active = '1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ORDER BY name") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "LIMIT 10") != null);
}

test "QueryBuilder whereGt whereLt whereGte whereLte" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();
    
    const sql1 = try builder.whereGt("age", "18").build();
    defer allocator.free(sql1);
    try std.testing.expect(std.mem.indexOf(u8, sql1, "age > '18'") != null);
    
    builder.deinit();
    var builder2 = QueryBuilder.init(allocator, "users");
    defer builder2.deinit();
    
    const sql2 = try builder2.whereLt("age", "65").build();
    defer allocator.free(sql2);
    try std.testing.expect(std.mem.indexOf(u8, sql2, "age < '65'") != null);
    
    builder2.deinit();
    var builder3 = QueryBuilder.init(allocator, "users");
    defer builder3.deinit();
    
    const sql3 = try builder3.whereGte("age", "18").build();
    defer allocator.free(sql3);
    try std.testing.expect(std.mem.indexOf(u8, sql3, "age >= '18'") != null);
    
    builder3.deinit();
    var builder4 = QueryBuilder.init(allocator, "users");
    defer builder4.deinit();
    
    const sql4 = try builder4.whereLte("age", "65").build();
    defer allocator.free(sql4);
    try std.testing.expect(std.mem.indexOf(u8, sql4, "age <= '65'") != null);
}

test "QueryBuilder whereNe" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();
    
    const sql = try builder.whereNe("name", "Alice").build();
    defer allocator.free(sql);
    
    try std.testing.expect(std.mem.indexOf(u8, sql, "name != 'Alice'") != null);
}
