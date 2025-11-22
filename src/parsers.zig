const std = @import("std");
const Request = @import("request.zig").Request;
const Json = @import("json.zig").Json;

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
        const query_string = path[query_start + 1 ..];

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
                    remaining = if (amp_pos < remaining.len) remaining[amp_pos + 1 ..] else "";
                    continue;
                };

                const key_raw = pair[0..eq_pos];
                const value_raw = if (eq_pos + 1 < pair.len) pair[eq_pos + 1 ..] else "";

                const key = try percentDecode(allocator, key_raw);
                const value = try percentDecode(allocator, value_raw);

                const gop = try params.getOrPut(key);
                if (gop.found_existing) {
                    allocator.free(key);
                    allocator.free(gop.value_ptr.*);
                    gop.value_ptr.* = value;
                } else {
                    gop.value_ptr.* = value;
                }
            }

            // Move to next pair
            remaining = if (amp_pos < remaining.len) remaining[amp_pos + 1 ..] else "";
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
                const hex_str = encoded[i + 1 .. i + 3];
                const byte = std.fmt.parseInt(u8, hex_str, 16) catch {
                    // Invalid hex - include context in error
                    std.debug.print("[Parser Error] Invalid percent encoding in query parameter\n", .{});
                    std.debug.print("  Input: {s}\n", .{encoded});
                    std.debug.print("  Position: {d}, Invalid hex sequence: {s}\n", .{ i, hex_str });
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
    /// Uses engine12's Json module for type-safe deserialization
    ///
    /// Example:
    /// ```zig
    /// const Todo = struct { title: []const u8, completed: bool };
    /// const todo = try BodyParser.json(Todo, req.body(), req.arena.allocator());
    /// ```
    pub fn json(comptime T: type, body: []const u8, allocator: std.mem.Allocator) !T {
        return Json.deserialize(T, body, allocator);
    }

    /// Parse JSON body into a struct, returning null on error
    pub fn jsonOptional(comptime T: type, body: []const u8, allocator: std.mem.Allocator) ?T {
        return json(T, body, allocator) catch null;
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
                    remaining = if (amp_pos < remaining.len) remaining[amp_pos + 1 ..] else "";
                    continue;
                };

                const key_raw = pair[0..eq_pos];
                const value_raw = if (eq_pos + 1 < pair.len) pair[eq_pos + 1 ..] else "";

                const key = try QueryParser.percentDecode(allocator, key_raw);
                const value = try QueryParser.percentDecode(allocator, value_raw);

                const gop = try params.getOrPut(key);
                if (gop.found_existing) {
                    allocator.free(key);
                    allocator.free(gop.value_ptr.*);
                    gop.value_ptr.* = value;
                } else {
                    gop.value_ptr.* = value;
                }
            }

            // Move to next pair
            remaining = if (amp_pos < remaining.len) remaining[amp_pos + 1 ..] else "";
        }

        return params;
    }
};

// Helper for tests to cleanup params
fn freeParams(allocator: std.mem.Allocator, params: *std.StringHashMap([]const u8)) void {
    var iter = params.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    params.deinit();
}

// Tests
test "QueryParser parse simple query" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/todos?limit=10&offset=20");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("limit").?, "10");
    try std.testing.expectEqualStrings(params.get("offset").?, "20");
}

test "QueryParser parse empty query" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/todos");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 0);
}

test "QueryParser parse URL encoded" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/search?q=hello%20world&tag=test");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("q").?, "hello world");
    try std.testing.expectEqualStrings(params.get("tag").?, "test");
}

test "BodyParser formData" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "title=Hello&completed=true");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("title").?, "Hello");
    try std.testing.expectEqualStrings(params.get("completed").?, "true");
}

test "QueryParser parse with single parameter" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=value");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "value");
}

test "QueryParser parse with no equals sign" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?keyonly");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("keyonly").?, "");
}

test "QueryParser parse with multiple equals signs" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=value=extra");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    // Should take everything after first = as value
    try std.testing.expectEqualStrings(params.get("key").?, "value=extra");
}

test "QueryParser parse with special characters" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?q=hello%20world&tag=test%2Bvalue%26more");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("q").?, "hello world");
    try std.testing.expectEqualStrings(params.get("tag").?, "test+value&more");
}

test "QueryParser parse with percent encoding edge cases" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=%41%42%43");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "ABC");
}

test "QueryParser parse with invalid percent encoding" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=%XX");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    // Invalid hex should be treated as literal
    try std.testing.expect(std.mem.indexOf(u8, params.get("key").?, "%") != null);
}

test "QueryParser parse with incomplete percent encoding" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=%4");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    // Incomplete encoding should be treated as literal
    try std.testing.expect(std.mem.indexOf(u8, params.get("key").?, "%") != null);
}

test "QueryParser parse with plus sign encoding" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?q=hello+world");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("q").?, "hello world");
}

test "QueryParser parse with empty query string" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 0);
}

test "QueryParser parse with ampersand only" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?&");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 0);
}

test "QueryParser parse with duplicate keys" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=value1&key=value2");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    // Last value wins
    try std.testing.expectEqualStrings(params.get("key").?, "value2");
}

test "BodyParser formData with empty values" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "key1=&key2=value&key3=");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 3);
    try std.testing.expectEqualStrings(params.get("key1").?, "");
    try std.testing.expectEqualStrings(params.get("key2").?, "value");
    try std.testing.expectEqualStrings(params.get("key3").?, "");
}

test "BodyParser formData with URL encoded values" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "name=John%20Doe&email=test%40example.com");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("name").?, "John Doe");
    try std.testing.expectEqualStrings(params.get("email").?, "test@example.com");
}

test "BodyParser formData with no equals sign" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "keyonly");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("keyonly").?, "");
}

test "BodyParser formData with duplicate keys" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "key=value1&key=value2");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    // Last value wins
    try std.testing.expectEqualStrings(params.get("key").?, "value2");
}

test "BodyParser formData with plus sign encoding" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "name=John+Doe");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("name").?, "John Doe");
}

test "BodyParser formData with special characters" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "msg=hello%26world%3Dtest");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("msg").?, "hello&world=test");
}

test "BodyParser formData with empty body" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 0);
}

test "QueryParser parse with many parameters" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?a=1&b=2&c=3&d=4&e=5");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 5);
    try std.testing.expectEqualStrings(params.get("a").?, "1");
    try std.testing.expectEqualStrings(params.get("b").?, "2");
    try std.testing.expectEqualStrings(params.get("c").?, "3");
    try std.testing.expectEqualStrings(params.get("d").?, "4");
    try std.testing.expectEqualStrings(params.get("e").?, "5");
}

test "QueryParser parse with mixed encoding" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?normal=value&encoded=hello%20world&plus=test+value");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 3);
    try std.testing.expectEqualStrings(params.get("normal").?, "value");
    try std.testing.expectEqualStrings(params.get("encoded").?, "hello world");
    try std.testing.expectEqualStrings(params.get("plus").?, "test value");
}
