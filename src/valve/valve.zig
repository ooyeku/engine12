const std = @import("std");
const context = @import("context.zig");

/// Valve-specific errors
pub const ValveError = error{
    CapabilityRequired,
    ValveNotFound,
    ValveAlreadyRegistered,
    InvalidMethod,
};

/// Capabilities that a valve can request
/// Each capability grants access to specific Engine12 features
pub const ValveCapability = enum {
    /// Register HTTP routes (GET, POST, PUT, DELETE, PATCH)
    routes,
    /// Register middleware (pre-request and response)
    middleware,
    /// Register background tasks (periodic and one-time)
    background_tasks,
    /// Register health check functions
    health_checks,
    /// Serve static files from directories
    static_files,
    /// Handle WebSocket connections (future)
    websockets,
    /// Access ORM/database operations
    database_access,
    /// Access response cache
    cache_access,
    /// Access metrics collector
    metrics_access,
};

/// Metadata describing a valve
/// Required for valve registration and capability management
pub const ValveMetadata = struct {
    /// Unique name identifying the valve
    name: []const u8,
    /// Version string (e.g., "1.0.0")
    version: []const u8,
    /// Human-readable description
    description: []const u8,
    /// Author/developer name
    author: []const u8,
    /// List of capabilities this valve requires
    required_capabilities: []const ValveCapability,
};

/// Valve interface that all valves must implement
/// Provides lifecycle hooks and initialization
/// Note: Function pointers are stored as *const fn to allow runtime mutability
pub const Valve = struct {
    /// Metadata describing this valve
    metadata: ValveMetadata,

    /// Initialize the valve with a context
    /// Called once when valve is registered
    /// Valves should register routes, middleware, etc. here
    init: *const fn (*Valve, *context.ValveContext) anyerror!void,

    /// Cleanup resources when valve is unregistered
    /// Called when valve is removed from registry
    deinit: *const fn (*Valve) void,

    /// Optional: Called when app starts
    /// Can be used for initialization that depends on app being started
    onAppStart: ?*const fn (*Valve, *context.ValveContext) anyerror!void = null,

    /// Optional: Called when app stops
    /// Can be used for graceful shutdown
    onAppStop: ?*const fn (*Valve, *context.ValveContext) void = null,
};

// Tests
test "ValveCapability enum values" {
    try std.testing.expectEqual(ValveCapability.routes, .routes);
    try std.testing.expectEqual(ValveCapability.middleware, .middleware);
    try std.testing.expectEqual(ValveCapability.background_tasks, .background_tasks);
    try std.testing.expectEqual(ValveCapability.health_checks, .health_checks);
    try std.testing.expectEqual(ValveCapability.static_files, .static_files);
    try std.testing.expectEqual(ValveCapability.websockets, .websockets);
    try std.testing.expectEqual(ValveCapability.database_access, .database_access);
    try std.testing.expectEqual(ValveCapability.cache_access, .cache_access);
    try std.testing.expectEqual(ValveCapability.metrics_access, .metrics_access);
}

test "ValveMetadata creation" {
    const metadata = ValveMetadata{
        .name = "test_valve",
        .version = "1.0.0",
        .description = "Test valve",
        .author = "Test Author",
        .required_capabilities = &[_]ValveCapability{ .routes, .middleware },
    };

    try std.testing.expectEqualStrings(metadata.name, "test_valve");
    try std.testing.expectEqualStrings(metadata.version, "1.0.0");
    try std.testing.expectEqualStrings(metadata.description, "Test valve");
    try std.testing.expectEqualStrings(metadata.author, "Test Author");
    try std.testing.expectEqual(metadata.required_capabilities.len, 2);
    try std.testing.expectEqual(metadata.required_capabilities[0], .routes);
    try std.testing.expectEqual(metadata.required_capabilities[1], .middleware);
}
