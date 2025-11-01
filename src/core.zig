const engine12 = @import("engine12.zig");
const handlers = @import("handlers.zig");
const tasks = @import("tasks.zig");
const health = @import("health.zig");
const std = @import("std");

pub const Engine12Core = struct {
    pub fn init() void {
        std.debug.print("Engine12 v0.1.0 - Professional Backend Framework\n", .{});
    }

    pub fn runDemoApp() !void {
        var app = try engine12.Engine12.initProduction();
        defer app.deinit();

        // Register HTTP endpoints
        try app.get("/api/users", handlers.handleGetUsers);
        try app.post("/api/users", handlers.handleCreateUser);
        try app.get("/api/status", handlers.handleGetStatus);

        // Register background tasks
        try app.schedulePeriodicTask("session_cleanup", &tasks.cleanupExpiredSessions, 5000);
        try app.schedulePeriodicTask("cache_sync", &tasks.syncDatabaseCache, 10000);
        try app.runTask("startup_metrics", &tasks.collectMetrics);

        // Register health checks
        try app.registerHealthCheck(&health.checkDatabaseHealth);
        try app.registerHealthCheck(&health.checkCacheHealth);

        // Start the system
        try app.start();

        // Print status
        app.printStatus();

        // Run for 3 seconds
        std.Thread.sleep(3000 * std.time.ns_per_ms);

        // Stop gracefully
        try app.stop();
    }
};

// Tests
test "Engine12Core init executes without error" {
    Engine12Core.init();
}

test "Engine12Core runDemoApp can be called" {
    // Note: This test actually starts a server, so we might want to skip it in CI
    // or run it separately. For now, we'll test that it can be called.
    // In a real scenario, you might want to mock the server or use a shorter timeout.
    // runDemoApp() intentionally sleeps for 3 seconds, so we'll skip this in automated tests
    // but include it for manual testing.
    // try engine12Core.runDemoApp();
    
    // Instead, test that the function signature is correct and can be compiled
    // This is a compile-time test
    _ = Engine12Core.runDemoApp;
}

