const std = @import("std");
const Request = @import("request.zig").Request;

/// Route parameter extracted from URL path
/// Provides type-safe conversion methods
pub const Param = struct {
    value: []const u8,
    
    /// Convert parameter to u32
    /// Returns error if conversion fails
    /// 
    /// Example:
    /// ```zig
    /// const id = try req.param("id").asU32();
    /// ```
    pub fn asU32(self: Param) !u32 {
        return std.fmt.parseInt(u32, self.value, 10);
    }
    
    /// Convert parameter to u32 with default value
    /// Returns default if conversion fails
    /// 
    /// Example:
    /// ```zig
    /// const limit = req.param("limit").asU32Default(10);
    /// ```
    pub fn asU32Default(self: Param, default: u32) u32 {
        return std.fmt.parseInt(u32, self.value, 10) catch default;
    }
    
    /// Convert parameter to i32
    pub fn asI32(self: Param) !i32 {
        return std.fmt.parseInt(i32, self.value, 10);
    }
    
    /// Convert parameter to i32 with default value
    pub fn asI32Default(self: Param, default: i32) i32 {
        return std.fmt.parseInt(i32, self.value, 10) catch default;
    }
    
    /// Convert parameter to u64
    pub fn asU64(self: Param) !u64 {
        return std.fmt.parseInt(u64, self.value, 10);
    }
    
    /// Convert parameter to f64
    pub fn asF64(self: Param) !f64 {
        return std.fmt.parseFloat(f64, self.value);
    }
    
    /// Get parameter as string slice
    pub fn asString(self: Param) []const u8 {
        return self.value;
    }
};

/// Route pattern parser and matcher
/// Handles route patterns like "/todos/:id" and extracts parameters
pub const RoutePattern = struct {
    /// Original pattern string (e.g., "/todos/:id")
    pattern: []const u8,
    
    /// Segments of the pattern
    segments: []const Segment,
    
    /// Parameter names in order of appearance
    param_names: []const []const u8,
    
    const Segment = union(enum) {
        literal: []const u8,  // Static path segment
        parameter: []const u8, // Parameter name (without ':')
    };
    
    /// Parse a route pattern into segments
    /// 
    /// Examples:
    /// - "/todos/:id" -> [{literal: "/todos"}, {parameter: "id"}]
    /// - "/api/users/:userId/posts/:postId" -> multiple segments
    /// 
    /// Returns error if pattern is invalid
    pub fn parse(allocator: std.mem.Allocator, pattern: []const u8) !RoutePattern {
        var segments = std.ArrayListUnmanaged(Segment){};
        var param_names = std.ArrayListUnmanaged([]const u8){};
        
        var remaining = pattern;
        
        // Handle leading slash
        if (remaining.len > 0 and remaining[0] == '/') {
            remaining = remaining[1..];
        }
        
        while (remaining.len > 0) {
            // Find next segment (separated by '/')
            const slash_pos = std.mem.indexOfScalar(u8, remaining, '/') orelse remaining.len;
            const segment_str = remaining[0..slash_pos];
            
            if (segment_str.len > 0) {
                if (segment_str[0] == ':') {
                    // Parameter segment
                    const param_name = segment_str[1..];
                    if (param_name.len == 0) {
                        return error.InvalidPattern;
                    }
                    
                    const param_name_dup = try allocator.dupe(u8, param_name);
                    try segments.append(allocator, Segment{ .parameter = param_name_dup });
                    try param_names.append(allocator, param_name_dup);
                } else {
                    // Literal segment
                    const literal_dup = try allocator.dupe(u8, segment_str);
                    try segments.append(allocator, Segment{ .literal = literal_dup });
                }
            }
            
            // Move to next segment
            if (slash_pos < remaining.len) {
                remaining = remaining[slash_pos + 1..];
            } else {
                break;
            }
        }
        
        return RoutePattern{
            .pattern = pattern,
            .segments = try segments.toOwnedSlice(allocator),
            .param_names = try param_names.toOwnedSlice(allocator),
        };
    }
    
    /// Match a request path against this pattern
    /// Returns extracted parameters if match succeeds, null otherwise
    /// 
    /// Example:
    /// Pattern: "/todos/:id"
    /// Path: "/todos/123"
    /// Returns: {"id": "123"}
    pub fn match(self: *const RoutePattern, allocator: std.mem.Allocator, path: []const u8) !?std.StringHashMap([]const u8) {
        var params = std.StringHashMap([]const u8).init(allocator);
        
        var remaining_path = path;
        
        // Handle leading slash
        if (remaining_path.len > 0 and remaining_path[0] == '/') {
            remaining_path = remaining_path[1..];
        }
        
        var segment_idx: usize = 0;
        
        while (remaining_path.len > 0 and segment_idx < self.segments.len) {
            const segment = self.segments[segment_idx];
            
            // Find next segment in path
            const slash_pos = std.mem.indexOfScalar(u8, remaining_path, '/') orelse remaining_path.len;
            const path_segment = remaining_path[0..slash_pos];
            
            switch (segment) {
                .literal => |literal| {
                    // Must match exactly
                    if (!std.mem.eql(u8, path_segment, literal)) {
                        return null;
                    }
                },
                .parameter => |param_name| {
                    // Capture parameter value
                    const param_value = try allocator.dupe(u8, path_segment);
                    try params.put(param_name, param_value);
                },
            }
            
            // Move to next segment
            if (slash_pos < remaining_path.len) {
                remaining_path = remaining_path[slash_pos + 1..];
            } else {
                remaining_path = "";
            }
            
            segment_idx += 1;
        }
        
        // All segments must be matched
        if (segment_idx != self.segments.len or remaining_path.len > 0) {
            return null;
        }
        
        return params;
    }
    
    /// Clean up allocated memory
    pub fn deinit(self: *RoutePattern, allocator: std.mem.Allocator) void {
        for (self.segments) |segment| {
            switch (segment) {
                .literal => |literal| allocator.free(literal),
                .parameter => |param| allocator.free(param),
            }
        }
        allocator.free(self.segments);
        allocator.free(self.param_names);
    }
};

// Tests
test "RoutePattern parse simple literal" {
    const allocator = std.testing.allocator;
    var pattern = try RoutePattern.parse(allocator, "/todos");
    defer pattern.deinit(allocator);
    
    try std.testing.expectEqual(pattern.segments.len, 1);
    try std.testing.expectEqual(pattern.segments[0], RoutePattern.Segment{ .literal = "todos" });
    try std.testing.expectEqualStrings(pattern.segments[0].literal, "todos");
}

test "RoutePattern parse with parameter" {
    const allocator = std.testing.allocator;
    var pattern = try RoutePattern.parse(allocator, "/todos/:id");
    defer pattern.deinit(allocator);
    
    try std.testing.expectEqual(pattern.segments.len, 2);
    try std.testing.expectEqualStrings(pattern.segments[0].literal, "todos");
    try std.testing.expectEqualStrings(pattern.segments[1].parameter, "id");
    try std.testing.expectEqual(pattern.param_names.len, 1);
    try std.testing.expectEqualStrings(pattern.param_names[0], "id");
}

test "RoutePattern parse multiple parameters" {
    const allocator = std.testing.allocator;
    var pattern = try RoutePattern.parse(allocator, "/api/users/:userId/posts/:postId");
    defer pattern.deinit(allocator);
    
    try std.testing.expectEqual(pattern.segments.len, 4);
    try std.testing.expectEqual(pattern.param_names.len, 2);
}

test "RoutePattern match literal path" {
    const allocator = std.testing.allocator;
    var pattern = try RoutePattern.parse(allocator, "/todos");
    defer pattern.deinit(allocator);
    
    const params = try pattern.match(allocator, "/todos");
    try std.testing.expect(params != null);
    if (params) |p| {
        defer p.deinit();
        try std.testing.expect(p.count() == 0);
    }
}

test "RoutePattern match with parameter" {
    const allocator = std.testing.allocator;
    var pattern = try RoutePattern.parse(allocator, "/todos/:id");
    defer pattern.deinit(allocator);
    
    const params = try pattern.match(allocator, "/todos/123");
    try std.testing.expect(params != null);
    if (params) |p| {
        defer p.deinit();
        try std.testing.expect(p.count() == 1);
        const id = p.get("id").?;
        try std.testing.expectEqualStrings(id, "123");
    }
}

test "RoutePattern match multiple parameters" {
    const allocator = std.testing.allocator;
    var pattern = try RoutePattern.parse(allocator, "/api/users/:userId/posts/:postId");
    defer pattern.deinit(allocator);
    
    const params = try pattern.match(allocator, "/api/users/123/posts/456");
    try std.testing.expect(params != null);
    if (params) |p| {
        defer p.deinit();
        try std.testing.expect(p.count() == 2);
        try std.testing.expectEqualStrings(p.get("userId").?, "123");
        try std.testing.expectEqualStrings(p.get("postId").?, "456");
    }
}

test "RoutePattern match fails on wrong path" {
    const allocator = std.testing.allocator;
    var pattern = try RoutePattern.parse(allocator, "/todos/:id");
    defer pattern.deinit(allocator);
    
    const params = try pattern.match(allocator, "/users/123");
    try std.testing.expect(params == null);
}

test "Param asU32" {
    const param = Param{ .value = "123" };
    const id = try param.asU32();
    try std.testing.expectEqual(id, 123);
}

test "Param asU32Default" {
    const param = Param{ .value = "123" };
    const id = param.asU32Default(0);
    try std.testing.expectEqual(id, 123);
    
    const invalid = Param{ .value = "abc" };
    const default_id = invalid.asU32Default(999);
    try std.testing.expectEqual(default_id, 999);
}

test "Param asString" {
    const param = Param{ .value = "hello" };
    try std.testing.expectEqualStrings(param.asString(), "hello");
}

