const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const Environment = enum {
    development,
    staging,
    production,
};

pub const HealthStatus = enum {
    healthy,
    degraded,
    unhealthy,
};

pub const ServerProfile = struct {
    environment: Environment,
    enable_request_logging: bool,
    enable_metrics: bool,
    enable_health_checks: bool,
    graceful_shutdown_timeout_ms: u32,
    max_concurrent_tasks: u32,
};

pub const ServerProfile_Development = ServerProfile{
    .environment = .development,
    .enable_request_logging = true,
    .enable_metrics = false,
    .enable_health_checks = true,
    .graceful_shutdown_timeout_ms = 5000,
    .max_concurrent_tasks = 4,
};

pub const ServerProfile_Production = ServerProfile{
    .environment = .production,
    .enable_request_logging = true,
    .enable_metrics = true,
    .enable_health_checks = true,
    .graceful_shutdown_timeout_ms = 30000,
    .max_concurrent_tasks = 16,
};

pub const ServerProfile_Testing = ServerProfile{
    .environment = .staging,
    .enable_request_logging = false,
    .enable_metrics = false,
    .enable_health_checks = true,
    .graceful_shutdown_timeout_ms = 2000,
    .max_concurrent_tasks = 2,
};

// HTTP Handler type - uses engine12 Request/Response types
pub const HttpHandler = fn (*Request) Response;

// Background task type
pub const BackgroundTask = *const fn () void;

// Health check function type
pub const HealthCheckFn = *const fn () HealthStatus;

// Pre-request middleware
pub const PreRequestMiddleware = fn (*Request) bool;

// Response transformer middleware
pub const ResponseTransformMiddleware = fn (Response) Response;

// WebSocket handler type
pub const WebSocketHandler = *const fn (*@import("websocket/connection.zig").WebSocketConnection) void;

// Internal route and task storage
pub const Route = struct {
    path: []const u8,
    method: []const u8, // "GET", "POST", "PUT", "DELETE"
    // Note: handler is stored as a pointer for tracking, but registration happens immediately
    handler_ptr: *const HttpHandler,
};

pub const BackgroundWorker = struct {
    name: []const u8,
    task: BackgroundTask,
    interval_ms: ?u32,
};

// WebSocket route storage
pub const WebSocketRoute = struct {
    path: []const u8,
    handler_ptr: *const WebSocketHandler,
};

// Hot reload error types
// Note: These errors are defined here for documentation purposes
// Actual error definitions are in the hot_reload module files
// HotReloadNotEnabled - Hot reload operation attempted when disabled
// TemplateReloadFailed - Failed to reload template
// FileWatchFailed - Failed to watch file

// Tests
test "Environment enum values" {
    try std.testing.expectEqual(Environment.development, .development);
    try std.testing.expectEqual(Environment.staging, .staging);
    try std.testing.expectEqual(Environment.production, .production);
}

test "HealthStatus enum values" {
    try std.testing.expectEqual(HealthStatus.healthy, .healthy);
    try std.testing.expectEqual(HealthStatus.degraded, .degraded);
    try std.testing.expectEqual(HealthStatus.unhealthy, .unhealthy);
}

test "ServerProfile_Development defaults" {
    const profile = ServerProfile_Development;
    try std.testing.expectEqual(profile.environment, Environment.development);
    try std.testing.expect(profile.enable_request_logging == true);
    try std.testing.expect(profile.enable_metrics == false);
    try std.testing.expect(profile.enable_health_checks == true);
    try std.testing.expectEqual(profile.graceful_shutdown_timeout_ms, 5000);
    try std.testing.expectEqual(profile.max_concurrent_tasks, 4);
}

test "ServerProfile_Production defaults" {
    const profile = ServerProfile_Production;
    try std.testing.expectEqual(profile.environment, Environment.production);
    try std.testing.expect(profile.enable_request_logging == true);
    try std.testing.expect(profile.enable_metrics == true);
    try std.testing.expect(profile.enable_health_checks == true);
    try std.testing.expectEqual(profile.graceful_shutdown_timeout_ms, 30000);
    try std.testing.expectEqual(profile.max_concurrent_tasks, 16);
}

test "ServerProfile_Testing defaults" {
    const profile = ServerProfile_Testing;
    try std.testing.expectEqual(profile.environment, Environment.staging);
    try std.testing.expect(profile.enable_request_logging == false);
    try std.testing.expect(profile.enable_metrics == false);
    try std.testing.expect(profile.enable_health_checks == true);
    try std.testing.expectEqual(profile.graceful_shutdown_timeout_ms, 2000);
    try std.testing.expectEqual(profile.max_concurrent_tasks, 2);
}

fn dummyHandler(_: *Request) Response {
    return Response.ok();
}

test "Route struct creation" {
    const route = Route{
        .path = "/test",
        .method = "GET",
        .handler_ptr = &dummyHandler,
    };
    try std.testing.expectEqualStrings(route.path, "/test");
    try std.testing.expectEqualStrings(route.method, "GET");
}

test "BackgroundWorker struct creation with interval" {
    const worker = BackgroundWorker{
        .name = "test_task",
        .task = dummyTaskForTest,
        .interval_ms = 1000,
    };
    try std.testing.expectEqualStrings(worker.name, "test_task");
    try std.testing.expect(worker.interval_ms != null);
    try std.testing.expectEqual(worker.interval_ms.?, 1000);
}

test "BackgroundWorker struct creation without interval" {
    const worker = BackgroundWorker{
        .name = "one_time_task",
        .task = dummyTaskForTest,
        .interval_ms = null,
    };
    try std.testing.expectEqualStrings(worker.name, "one_time_task");
    try std.testing.expect(worker.interval_ms == null);
}

fn dummyTaskForTest() void {}
