const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

/// Route information for introspection
pub const RouteInfo = struct {
    method: []const u8,
    path: []const u8,
    handler_name: []const u8 = "unknown",
    
    pub fn init(allocator: std.mem.Allocator, method: []const u8, path: []const u8, handler_name: []const u8) !RouteInfo {
        const method_copy = try allocator.dupe(u8, method);
        const path_copy = try allocator.dupe(u8, path);
        const handler_copy = try allocator.dupe(u8, handler_name);
        
        return RouteInfo{
            .method = method_copy,
            .path = path_copy,
            .handler_name = handler_copy,
        };
    }
    
    pub fn deinit(self: *RouteInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.path);
        allocator.free(self.handler_name);
    }
};

/// Registry for tracking registered routes
pub const RouteRegistry = struct {
    routes: std.ArrayListUnmanaged(RouteInfo),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) RouteRegistry {
        return RouteRegistry{
            .routes = std.ArrayListUnmanaged(RouteInfo){},
            .allocator = allocator,
        };
    }
    
    /// Register a route
    pub fn register(self: *RouteRegistry, method: []const u8, path: []const u8, handler_name: []const u8) !void {
        const route_info = try RouteInfo.init(self.allocator, method, path, handler_name);
        try self.routes.append(self.allocator, route_info);
    }
    
    /// Get all registered routes
    pub fn getAll(self: *const RouteRegistry) []const RouteInfo {
        return self.routes.items;
    }
    
    /// Get routes matching a method
    pub fn getByMethod(self: *const RouteRegistry, method: []const u8, matches: *std.ArrayListUnmanaged(RouteInfo)) !void {
        for (self.routes.items) |route| {
            if (std.mem.eql(u8, route.method, method)) {
                try matches.append(self.allocator, route);
            }
        }
    }
    
    /// Format routes as JSON for API introspection
    pub fn toJson(self: *const RouteRegistry, allocator: std.mem.Allocator) ![]const u8 {
        var output = std.ArrayListUnmanaged(u8){};
        const writer = output.writer(allocator);
        
        try writer.print("{{\"routes\":[", .{});
        for (self.routes.items, 0..) |route, i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print(
                "{{\"method\":\"{s}\",\"path\":\"{s}\",\"handler\":\"{s}\"}}",
                .{ route.method, route.path, route.handler_name },
            );
        }
        try writer.print("]}}", .{});
        
        return output.toOwnedSlice(allocator);
    }
    
    pub fn deinit(self: *RouteRegistry) void {
        for (self.routes.items) |*route| {
            route.deinit(self.allocator);
        }
        self.routes.deinit(self.allocator);
    }
};

/// Log level for structured logging
pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,
};

/// Structured log entry
pub const LogEntry = struct {
    level: LogLevel,
    message: []const u8,
    timestamp: i64,
    fields: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, level: LogLevel, message: []const u8) !LogEntry {
        const message_copy = try allocator.dupe(u8, message);
        return LogEntry{
            .level = level,
            .message = message_copy,
            .timestamp = std.time.milliTimestamp(),
            .fields = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }
    
    /// Add a field to the log entry
    pub fn addField(self: *LogEntry, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.fields.put(key_copy, value_copy);
    }
    
    /// Format log entry as JSON
    pub fn toJson(self: *const LogEntry, allocator: std.mem.Allocator) ![]const u8 {
        var output = std.ArrayListUnmanaged(u8){};
        const writer = output.writer(allocator);
        
        try writer.print(
            "{{\"level\":\"{s}\",\"message\":\"{s}\",\"timestamp\":{d}",
            .{ @tagName(self.level), self.message, self.timestamp },
        );
        
        if (self.fields.count() > 0) {
            try writer.print(",\"fields\":{{", .{});
            var iterator = self.fields.iterator();
            var first = true;
            while (iterator.next()) |entry| {
                if (!first) try writer.print(",", .{});
                first = false;
                try writer.print("\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
            try writer.print("}}", .{});
        }
        
        try writer.print("}}", .{});
        return output.toOwnedSlice(allocator);
    }
    
    pub fn deinit(self: *LogEntry) void {
        self.allocator.free(self.message);
        var iterator = self.fields.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.fields.deinit();
    }
};

/// Structured logger
pub const Logger = struct {
    allocator: std.mem.Allocator,
    min_level: LogLevel,
    
    pub fn init(allocator: std.mem.Allocator, min_level: LogLevel) Logger {
        return Logger{
            .allocator = allocator,
            .min_level = min_level,
        };
    }
    
    /// Log a message at the specified level
    pub fn log(self: *Logger, level: LogLevel, message: []const u8) !LogEntry {
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) {
            // Below minimum level, return empty entry
            return LogEntry{
                .level = level,
                .message = "",
                .timestamp = std.time.milliTimestamp(),
                .fields = std.StringHashMap([]const u8).init(self.allocator),
                .allocator = self.allocator,
            };
        }
        
        return try LogEntry.init(self.allocator, level, message);
    }
    
    /// Log debug message
    pub fn debug(self: *Logger, message: []const u8) !LogEntry {
        return self.log(.debug, message);
    }
    
    /// Log info message
    pub fn info(self: *Logger, message: []const u8) !LogEntry {
        return self.log(.info, message);
    }
    
    /// Log warning message
    pub fn warn(self: *Logger, message: []const u8) !LogEntry {
        return self.log(.warn, message);
    }
    
    /// Log error message
    pub fn logError(self: *Logger, message: []const u8) !LogEntry {
        return self.log(.err, message);
    }
    
    /// Format and print log entry
    pub fn print(self: *Logger, entry: *LogEntry) void {
        const json = entry.toJson(self.allocator) catch return;
        defer self.allocator.free(json);
        std.debug.print("{s}\n", .{json});
    }
};

// Tests
test "RouteRegistry register and getAll" {
    var registry = RouteRegistry.init(std.testing.allocator);
    defer registry.deinit();
    
    try registry.register("GET", "/api/todos", "handleGetTodos");
    try registry.register("POST", "/api/todos", "handleCreateTodo");
    
    const routes = registry.getAll();
    try std.testing.expectEqual(routes.len, 2);
    try std.testing.expectEqualStrings(routes[0].method, "GET");
    try std.testing.expectEqualStrings(routes[0].path, "/api/todos");
}

test "LogEntry init and toJson" {
    var entry = try LogEntry.init(std.testing.allocator, .info, "Test message");
    defer entry.deinit();
    
    try entry.addField("user_id", "123");
    try entry.addField("action", "login");
    
    const json = try entry.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    
    try std.testing.expect(std.mem.indexOf(u8, json, "info") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Test message") != null);
}

test "Logger log levels" {
    var logger = Logger.init(std.testing.allocator, .info);
    
    var debug_entry = try logger.debug("Debug message");
    defer debug_entry.deinit();
    try std.testing.expectEqual(debug_entry.message.len, 0); // Below min level
    
    var info_entry = try logger.info("Info message");
    defer info_entry.deinit();
    try std.testing.expectEqualStrings(info_entry.message, "Info message");
}

