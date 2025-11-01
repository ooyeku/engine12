const std = @import("std");

/// HTML escaping utilities
/// Escapes HTML entities to prevent XSS attacks
pub const Escape = struct {
    /// Escape HTML entities in a string
    /// Escapes: & < > " '
    /// Returns a newly allocated string that must be freed
    pub fn escapeHtml(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        // First pass: count how many characters need escaping
        var escaped_count: usize = 0;
        for (input) |char| {
            escaped_count += switch (char) {
                '&' => 5,  // "&amp;"
                '<' => 4,  // "&lt;"
                '>' => 4,  // "&gt;"
                '"' => 6,  // "&quot;"
                '\'' => 6, // "&#39;"
                else => 1,
            };
        }
        
        // If no escaping needed, return original
        if (escaped_count == input.len) {
            return try allocator.dupe(u8, input);
        }
        
        // Allocate output buffer
        const output = try allocator.alloc(u8, escaped_count);
        var out_index: usize = 0;
        
        // Second pass: escape characters
        for (input) |char| {
            switch (char) {
                '&' => {
                    @memcpy(output[out_index..out_index + 5], "&amp;");
                    out_index += 5;
                },
                '<' => {
                    @memcpy(output[out_index..out_index + 4], "&lt;");
                    out_index += 4;
                },
                '>' => {
                    @memcpy(output[out_index..out_index + 4], "&gt;");
                    out_index += 4;
                },
                '"' => {
                    @memcpy(output[out_index..out_index + 6], "&quot;");
                    out_index += 6;
                },
                '\'' => {
                    @memcpy(output[out_index..out_index + 6], "&#39;");
                    out_index += 6;
                },
                else => {
                    output[out_index] = char;
                    out_index += 1;
                },
            }
        }
        
        return output;
    }
    
    /// Escape HTML entities in place (for comptime strings)
    /// Returns a comptime string literal
    pub fn escapeHtmlComptime(comptime input: []const u8) []const u8 {
        // For comptime, we build the escaped string
        var result: []const u8 = "";
        var i: usize = 0;
        while (i < input.len) {
            const char = input[i];
            result = result ++ switch (char) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                '\'' => "&#39;",
                else => input[i..i+1],
            };
            i += 1;
        }
        return result;
    }
};

// Tests
test "escapeHtml basic" {
    const allocator = std.testing.allocator;
    const input = "<script>alert('xss')</script>";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    
    try std.testing.expectEqualStrings(escaped, "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;");
}

test "escapeHtml ampersand" {
    const allocator = std.testing.allocator;
    const input = "A & B";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    
    try std.testing.expectEqualStrings(escaped, "A &amp; B");
}

test "escapeHtml quotes" {
    const allocator = std.testing.allocator;
    const input = "\"hello\" 'world'";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    
    try std.testing.expectEqualStrings(escaped, "&quot;hello&quot; &#39;world&#39;");
}

test "escapeHtml no escaping needed" {
    const allocator = std.testing.allocator;
    const input = "Hello World";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    
    try std.testing.expectEqualStrings(escaped, "Hello World");
}

test "escapeHtml empty string" {
    const allocator = std.testing.allocator;
    const input = "";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    
    try std.testing.expectEqualStrings(escaped, "");
}

