const std = @import("std");
const Request = @import("request.zig").Request;

/// Query parameter parsing utilities
pub const QueryParser = struct {
    /// Parse query string from URL path
    /// Returns a hashmap of key-value pairs
    /// 
    /// Example:
    /// Path: "/api/todos?limit=10&offset=20"
    /// Returns: {"limit": "10", "offset": "20"}
    pub fn parse(allocator: std.mem.Allocator, path: []const u8) !std.StringHashMap([]const u8) {
        var params = std.StringHashMap([]const u8).init(allocator);
        
        // Find query string separator
        const query_start = std.mem.indexOfScalar(u8, path, '?') orelse return params;
        const query_string = path[query_start + 1..];
        
        // Parse key=value pairs separated by &
        var remaining = query_string;
        while (remaining.len > 0) {
            // Find next & or end of string
            const amp_pos = std.mem.indexOfScalar(u8, remaining, '&') orelse remaining.len;
            const pair = remaining[0..amp_pos];
            
            if (pair.len > 0) {
                // Find = separator
                const eq_pos = std.mem.indexOfScalar(u8, pair, '=') orelse {
                    // No = found, treat as key with empty value
                    const key = try percentDecode(allocator, pair);
                    try params.put(key, "");
                    remaining = if (amp_pos < remaining.len) remaining[amp_pos + 1..] else "";
                    continue;
                };
                
                const key_raw = pair[0..eq_pos];
                const value_raw = if (eq_pos + 1 < pair.len) pair[eq_pos + 1..] else "";
                
                const key = try percentDecode(allocator, key_raw);
                const value = try percentDecode(allocator, value_raw);
                
                try params.put(key, value);
            }
            
            // Move to next pair
            remaining = if (amp_pos < remaining.len) remaining[amp_pos + 1..] else "";
        }
        
        return params;
    }
    
    /// Percent-decode a URL-encoded string
    /// Example: "hello%20world" -> "hello world"
    fn percentDecode(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        
        var i: usize = 0;
        while (i < encoded.len) {
            if (encoded[i] == '%' and i + 2 < encoded.len) {
                // Decode hex sequence
                const hex_str = encoded[i + 1..i + 3];
                const byte = std.fmt.parseInt(u8, hex_str, 16) catch {
                    // Invalid hex, treat as literal
                    try result.append(allocator, '%');
                    i += 1;
                    continue;
                };
                try result.append(allocator, byte);
                i += 3;
            } else if (encoded[i] == '+') {
                // + is encoded space
                try result.append(allocator, ' ');
                i += 1;
            } else {
                try result.append(allocator, encoded[i]);
                i += 1;
            }
        }
        
        return result.toOwnedSlice(allocator);
    }
};

/// Body parsing utilities
pub const BodyParser = struct {
    /// Parse JSON body into a struct
    /// Returns an error if parsing fails
    /// 
    /// Example:
    /// ```zig
    /// const Todo = struct { title: []const u8, completed: bool };
    /// const todo = try BodyParser.json(Todo, req.body(), req.allocator());
    /// ```
    pub fn json(comptime T: type, body: []const u8, allocator: std.mem.Allocator) !T {
        // Simple JSON parser for common cases
        // For production, consider using a proper JSON library
        _ = allocator;
        return parseJsonStruct(T, body);
    }
    
    /// Parse JSON body into a struct, returning null on error
    pub fn jsonOptional(comptime T: type, body: []const u8, allocator: std.mem.Allocator) ?T {
        return json(T, body, allocator) catch null;
    }
    
    /// Simple JSON struct parser (basic implementation)
    fn parseJsonStruct(comptime T: type, body: []const u8) !T {
        // This is a placeholder - for a full implementation, use a proper JSON parser
        // For now, just validate it's valid JSON-like structure
        _ = body;
        
        // TODO: Implement proper JSON parsing
        // T is used in the return type
        return error.NotImplemented;
    }
    
    /// Parse URL-encoded form data
    /// Returns a hashmap of key-value pairs
    /// 
    /// Example:
    /// Body: "title=Hello&completed=true"
    /// Returns: {"title": "Hello", "completed": "true"}
    pub fn formData(allocator: std.mem.Allocator, body: []const u8) !std.StringHashMap([]const u8) {
        var params = std.StringHashMap([]const u8).init(allocator);
        
        var remaining = body;
        while (remaining.len > 0) {
            // Find next & or end of string
            const amp_pos = std.mem.indexOfScalar(u8, remaining, '&') orelse remaining.len;
            const pair = remaining[0..amp_pos];
            
            if (pair.len > 0) {
                // Find = separator
                const eq_pos = std.mem.indexOfScalar(u8, pair, '=') orelse {
                    // No = found, treat as key with empty value
                    const key = try QueryParser.percentDecode(allocator, pair);
                    try params.put(key, "");
                    remaining = if (amp_pos < remaining.len) remaining[amp_pos + 1..] else "";
                    continue;
                };
                
                const key_raw = pair[0..eq_pos];
                const value_raw = if (eq_pos + 1 < pair.len) pair[eq_pos + 1..] else "";
                
                const key = try QueryParser.percentDecode(allocator, key_raw);
                const value = try QueryParser.percentDecode(allocator, value_raw);
                
                try params.put(key, value);
            }
            
            // Move to next pair
            remaining = if (amp_pos < remaining.len) remaining[amp_pos + 1..] else "";
        }
        
        return params;
    }
};

// Tests
test "QueryParser parse simple query" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/todos?limit=10&offset=20");
    defer params.deinit();
    
    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("limit").?, "10");
    try std.testing.expectEqualStrings(params.get("offset").?, "20");
}

test "QueryParser parse empty query" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/todos");
    defer params.deinit();
    
    try std.testing.expect(params.count() == 0);
}

test "QueryParser parse URL encoded" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/search?q=hello%20world&tag=test");
    defer params.deinit();
    
    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("q").?, "hello world");
    try std.testing.expectEqualStrings(params.get("tag").?, "test");
}

test "BodyParser formData" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "title=Hello&completed=true");
    defer params.deinit();
    
    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("title").?, "Hello");
    try std.testing.expectEqualStrings(params.get("completed").?, "true");
}

