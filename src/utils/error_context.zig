const std = @import("std");

/// Error context information for debugging
/// Captures file, line, function, and optionally stack trace
pub const ErrorContext = struct {
    /// Source file where error occurred
    file: []const u8,
    /// Line number where error occurred
    line: u32,
    /// Function name where error occurred
    function: []const u8,
    /// Stack trace (only in development mode)
    stack_trace: ?[]const u8 = null,

    /// Create error context from current location
    pub fn here() ErrorContext {
        return ErrorContext{
            .file = @src().file,
            .line = @src().line,
            .function = @src().fn_name,
            .stack_trace = null,
        };
    }

    /// Format error context as string
    pub fn format(self: ErrorContext, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.writer(allocator).print("{s}:{d} in {s}", .{ self.file, self.line, self.function });
        
        if (self.stack_trace) |trace| {
            try buffer.writer(allocator).print("\nStack trace:\n{s}", .{trace});
        }

        return try buffer.toOwnedSlice(allocator);
    }

    /// Format error context as JSON (for API responses)
    pub fn toJson(self: ErrorContext, allocator: std.mem.Allocator, include_stack: bool) ![]const u8 {
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(allocator);

        try buffer.writer(allocator).print(
            "{{\"file\":\"{s}\",\"line\":{d},\"function\":\"{s}\"",
            .{ self.file, self.line, self.function },
        );

        if (include_stack) {
            if (self.stack_trace) |trace| {
            // Escape JSON string
            var escaped = std.ArrayListUnmanaged(u8){};
            defer escaped.deinit(allocator);
            for (trace) |byte| {
                switch (byte) {
                    '\n' => try escaped.appendSlice(allocator, "\\n"),
                    '\r' => try escaped.appendSlice(allocator, "\\r"),
                    '\t' => try escaped.appendSlice(allocator, "\\t"),
                    '"' => try escaped.appendSlice(allocator, "\\\""),
                    '\\' => try escaped.appendSlice(allocator, "\\\\"),
                    else => try escaped.append(allocator, byte),
                }
            }
            try buffer.writer(allocator).print(",\"stack_trace\":\"{s}\"", .{escaped.items});
            }
        }

        try buffer.writer(allocator).print("}}", .{});

        return try buffer.toOwnedSlice(allocator);
    }
};

/// Capture error context with optional stack trace
/// Stack traces are only captured in debug builds for performance
pub fn captureErrorContext(allocator: std.mem.Allocator, include_stack: bool) !ErrorContext {
    const ctx = ErrorContext.here();
    
    // In debug builds, we can capture stack traces
    // For now, we'll leave stack_trace as null since Zig's stack trace API is limited
    // Future: Use @errorReturnTrace() or similar when available
    
    _ = allocator;
    _ = include_stack;
    
    return ctx;
}

// Tests
test "ErrorContext here captures location" {
    const ctx = ErrorContext.here();
    try std.testing.expect(ctx.file.len > 0);
    try std.testing.expect(ctx.line > 0);
    try std.testing.expect(ctx.function.len > 0);
}

test "ErrorContext format" {
    const ctx = ErrorContext{
        .file = "test.zig",
        .line = 42,
        .function = "testFunction",
        .stack_trace = null,
    };
    
    const formatted = try ctx.format(std.testing.allocator);
    defer std.testing.allocator.free(formatted);
    
    try std.testing.expect(std.mem.indexOf(u8, formatted, "test.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "testFunction") != null);
}

test "ErrorContext toJson" {
    const ctx = ErrorContext{
        .file = "test.zig",
        .line = 42,
        .function = "testFunction",
        .stack_trace = null,
    };
    
    const json = try ctx.toJson(std.testing.allocator, false);
    defer std.testing.allocator.free(json);
    
    try std.testing.expect(std.mem.indexOf(u8, json, "\"file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"line\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"function\"") != null);
}

