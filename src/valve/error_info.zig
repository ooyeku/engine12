const std = @import("std");

/// Phase in valve lifecycle where an error occurred
pub const ValveErrorPhase = enum {
    /// Error during valve initialization (init callback)
    init,
    /// Error during app start (onAppStart callback)
    start,
    /// Error during app stop (onAppStop callback)
    stop,
    /// Error during runtime operation
    runtime,
};

/// Structured error information for valves
/// Provides detailed error context for debugging and monitoring
pub const ValveErrorInfo = struct {
    /// Phase where the error occurred
    phase: ValveErrorPhase,
    /// Error type name (e.g., "OutOfMemory", "FileNotFound")
    error_type: []const u8,
    /// Human-readable error message
    message: []const u8,
    /// Unix timestamp in milliseconds when error occurred
    timestamp: i64,

    /// Clean up allocated memory
    pub fn deinit(self: *ValveErrorInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.error_type);
        allocator.free(self.message);
    }

    /// Create a new error info instance
    /// Allocates strings for error_type and message
    pub fn create(
        allocator: std.mem.Allocator,
        phase: ValveErrorPhase,
        error_type: []const u8,
        message: []const u8,
    ) !ValveErrorInfo {
        const error_type_copy = try allocator.dupe(u8, error_type);
        errdefer allocator.free(error_type_copy);

        const message_copy = try allocator.dupe(u8, message);
        errdefer allocator.free(message_copy);

        const timestamp = std.time.milliTimestamp();

        return ValveErrorInfo{
            .phase = phase,
            .error_type = error_type_copy,
            .message = message_copy,
            .timestamp = timestamp,
        };
    }

    /// Format error info as a string
    /// Returns a formatted string suitable for logging
    pub fn format(self: *const ValveErrorInfo, allocator: std.mem.Allocator) ![]const u8 {
        const phase_str = switch (self.phase) {
            .init => "init",
            .start => "onAppStart",
            .stop => "onAppStop",
            .runtime => "runtime",
        };

        return std.fmt.allocPrint(
            allocator,
            "{s}: {s} ({s})",
            .{ phase_str, self.message, self.error_type },
        );
    }
};

// Tests
test "ValveErrorInfo create and deinit" {
    const allocator = std.testing.allocator;

    var error_info = try ValveErrorInfo.create(
        allocator,
        .init,
        "OutOfMemory",
        "Failed to allocate memory",
    );
    defer error_info.deinit(allocator);

    try std.testing.expectEqual(error_info.phase, .init);
    try std.testing.expectEqualStrings(error_info.error_type, "OutOfMemory");
    try std.testing.expectEqualStrings(error_info.message, "Failed to allocate memory");
    try std.testing.expect(error_info.timestamp > 0);
}

test "ValveErrorInfo format" {
    const allocator = std.testing.allocator;

    var error_info = try ValveErrorInfo.create(
        allocator,
        .start,
        "DatabaseError",
        "Connection failed",
    );
    defer error_info.deinit(allocator);

    const formatted = try error_info.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "onAppStart") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Connection failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "DatabaseError") != null);
}
