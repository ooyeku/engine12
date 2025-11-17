const std = @import("std");
const engine12 = @import("../engine12.zig");
const Engine12 = engine12.Engine12;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const types = @import("../types.zig");
const middleware_chain = @import("../middleware.zig");
const cache = @import("../cache.zig");
const metrics = @import("../metrics.zig");
const orm = @import("../orm/orm.zig");
const valve = @import("valve.zig");
const ValveCapability = valve.ValveCapability;

/// Controlled access to Engine12 runtime for valves
/// Provides capability-checked methods for interacting with Engine12
pub const ValveContext = struct {
    /// Reference to Engine12 instance
    app: *Engine12,
    /// Allocator for valve use
    allocator: std.mem.Allocator,
    /// Granted capabilities for this valve
    capabilities: std.ArrayListUnmanaged(ValveCapability),
    /// Name of the owning valve
    valve_name: []const u8,

    const Self = @This();

    /// Check if valve has a specific capability
    pub fn hasCapability(self: *const Self, cap: ValveCapability) bool {
        for (self.capabilities.items) |c| {
            if (c == cap) return true;
        }
        return false;
    }

    /// Register an HTTP route
    /// Requires `.routes` capability
    ///
    /// Example:
    /// ```zig
    /// try ctx.registerRoute("GET", "/api/users", handleUsers);
    /// ```
    pub fn registerRoute(
        self: *Self,
        method: []const u8,
        path: []const u8,
        handler: types.HttpHandler,
    ) !void {
        if (!self.hasCapability(.routes)) {
            return valve.ValveError.CapabilityRequired;
        }

        // For runtime paths, we need to use a different approach
        // Since Engine12 methods require comptime paths, we'll use a workaround:
        // Store the handler in a registry and use a generic wrapper
        // For now, return an error indicating runtime paths aren't fully supported
        // Valves should use comptime paths when possible
        _ = method;
        _ = path;
        _ = handler;
        return valve.ValveError.InvalidMethod; // TODO: Implement runtime route registration
    }

    /// Register pre-request middleware
    /// Requires `.middleware` capability
    ///
    /// Example:
    /// ```zig
    /// try ctx.registerMiddleware(&authMiddleware);
    /// ```
    pub fn registerMiddleware(
        self: *Self,
        mw: middleware_chain.PreRequestMiddlewareFn,
    ) !void {
        if (!self.hasCapability(.middleware)) {
            return valve.ValveError.CapabilityRequired;
        }
        try self.app.usePreRequest(mw);
    }

    /// Register response middleware
    /// Requires `.middleware` capability
    ///
    /// Example:
    /// ```zig
    /// try ctx.registerResponseMiddleware(&corsMiddleware);
    /// ```
    pub fn registerResponseMiddleware(
        self: *Self,
        mw: middleware_chain.ResponseMiddlewareFn,
    ) !void {
        if (!self.hasCapability(.middleware)) {
            return valve.ValveError.CapabilityRequired;
        }
        try self.app.useResponse(mw);
    }

    /// Register a background task
    /// Requires `.background_tasks` capability
    ///
    /// Example:
    /// ```zig
    /// try ctx.registerTask("cleanup", cleanupTask, null); // One-time
    /// try ctx.registerTask("periodic", periodicTask, 60000); // Every 60s
    /// ```
    pub fn registerTask(
        self: *Self,
        name: []const u8,
        task: types.BackgroundTask,
        interval_ms: ?u32,
    ) !void {
        if (!self.hasCapability(.background_tasks)) {
            return valve.ValveError.CapabilityRequired;
        }

        if (interval_ms) |interval| {
            try self.app.schedulePeriodicTask(name, task, interval);
        } else {
            try self.app.runTask(name, task);
        }
    }

    /// Register a health check function
    /// Requires `.health_checks` capability
    ///
    /// Example:
    /// ```zig
    /// try ctx.registerHealthCheck(&checkDatabase);
    /// ```
    pub fn registerHealthCheck(
        self: *Self,
        check: types.HealthCheckFn,
    ) !void {
        if (!self.hasCapability(.health_checks)) {
            return valve.ValveError.CapabilityRequired;
        }
        try self.app.registerHealthCheck(check);
    }

    /// Serve static files from a directory
    /// Requires `.static_files` capability
    ///
    /// Example:
    /// ```zig
    /// try ctx.serveStatic("/static", "./public");
    /// ```
    pub fn serveStatic(
        self: *Self,
        mount_path: []const u8,
        directory: []const u8,
    ) !void {
        if (!self.hasCapability(.static_files)) {
            return valve.ValveError.CapabilityRequired;
        }
        try self.app.serveStatic(mount_path, directory);
    }

    /// Get ORM instance
    /// Requires `.database_access` capability
    /// Note: Returns null if ORM is not initialized
    ///
    /// Example:
    /// ```zig
    /// if (try ctx.getORM()) |orm| {
    ///     const todos = try orm.findAll(Todo);
    /// }
    /// ```
    pub fn getORM(self: *Self) !?*orm.ORM {
        if (!self.hasCapability(.database_access)) {
            return valve.ValveError.CapabilityRequired;
        }
        // Note: ORM access typically requires app-level initialization
        // This is a placeholder - actual implementation depends on how apps manage ORM
        _ = self.app;
        return null;
    }

    /// Get cache instance
    /// Requires `.cache_access` capability
    /// Returns null if cache is not configured
    ///
    /// Example:
    /// ```zig
    /// if (ctx.getCache()) |cache| {
    ///     try cache.set("key", "value", 60000);
    /// }
    /// ```
    pub fn getCache(self: *Self) ?*cache.ResponseCache {
        if (!self.hasCapability(.cache_access)) {
            return null;
        }
        return self.app.getCache();
    }

    /// Get metrics collector
    /// Requires `.metrics_access` capability
    /// Returns null if metrics are not enabled
    ///
    /// Example:
    /// ```zig
    /// if (ctx.getMetrics()) |metrics| {
    ///     metrics.incrementCounter("requests");
    /// }
    /// ```
    pub fn getMetrics(self: *Self) ?*metrics.MetricsCollector {
        if (!self.hasCapability(.metrics_access)) {
            return null;
        }
        // Access metrics collector from Engine12
        return &self.app.metrics_collector;
    }

    /// Cleanup context resources
    pub fn deinit(self: *Self) void {
        self.capabilities.deinit(self.allocator);
    }
};

// Tests
test "ValveContext hasCapability" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var capabilities = std.ArrayList(ValveCapability).init(std.testing.allocator);
    defer capabilities.deinit();
    try capabilities.append(.routes);
    try capabilities.append(.middleware);

    var ctx = ValveContext{
        .app = &app,
        .allocator = std.testing.allocator,
        .capabilities = capabilities,
        .valve_name = "test",
    };

    try std.testing.expect(ctx.hasCapability(.routes));
    try std.testing.expect(ctx.hasCapability(.middleware));
    try std.testing.expect(!ctx.hasCapability(.database_access));
}

test "ValveContext registerRoute requires capability" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var capabilities = std.ArrayList(ValveCapability).init(std.testing.allocator);
    defer capabilities.deinit();

    var ctx = ValveContext{
        .app = &app,
        .allocator = std.testing.allocator,
        .capabilities = capabilities,
        .valve_name = "test",
    };

    const dummyHandler = struct {
        fn handler(_: *Request) Response {
            return Response.json("{}");
        }
    }.handler;

    // Should fail without .routes capability
    try std.testing.expectError(valve.ValveError.CapabilityRequired, ctx.registerRoute("GET", "/test", dummyHandler));
}

test "ValveContext registerRoute with capability" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var capabilities = std.ArrayList(ValveCapability).init(std.testing.allocator);
    defer capabilities.deinit();
    try capabilities.append(.routes);

    var ctx = ValveContext{
        .app = &app,
        .allocator = std.testing.allocator,
        .capabilities = capabilities,
        .valve_name = "test",
    };

    const dummyHandler = struct {
        fn handler(_: *Request) Response {
            return Response.json("{}");
        }
    }.handler;

    // Should succeed with .routes capability
    try ctx.registerRoute("GET", "/test", dummyHandler);
    try std.testing.expectEqual(app.routes_count, 1);
}

test "ValveContext registerMiddleware requires capability" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var capabilities = std.ArrayList(ValveCapability).init(std.testing.allocator);
    defer capabilities.deinit();

    var ctx = ValveContext{
        .app = &app,
        .allocator = std.testing.allocator,
        .capabilities = capabilities,
        .valve_name = "test",
    };

    const dummyMw = struct {
        fn mw(_: *Request) middleware_chain.MiddlewareResult {
            return .proceed;
        }
    }.mw;

    // Should fail without .middleware capability
    try std.testing.expectError(valve.ValveError.CapabilityRequired, ctx.registerMiddleware(&dummyMw));
}

test "ValveContext registerTask requires capability" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var capabilities = std.ArrayList(ValveCapability).init(std.testing.allocator);
    defer capabilities.deinit();

    var ctx = ValveContext{
        .app = &app,
        .allocator = std.testing.allocator,
        .capabilities = capabilities,
        .valve_name = "test",
    };

    const dummyTask = struct {
        fn task() void {}
    }.task;

    // Should fail without .background_tasks capability
    try std.testing.expectError(valve.ValveError.CapabilityRequired, ctx.registerTask("test", &dummyTask, null));
}

test "ValveContext getCache requires capability" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var capabilities = std.ArrayList(ValveCapability).init(std.testing.allocator);
    defer capabilities.deinit();

    var ctx = ValveContext{
        .app = &app,
        .allocator = std.testing.allocator,
        .capabilities = capabilities,
        .valve_name = "test",
    };

    // Should return null without .cache_access capability
    try std.testing.expect(ctx.getCache() == null);
}
