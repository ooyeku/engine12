# Building a Custom Valve

This guide walks through building a custom valve for Engine12, demonstrating the complete process from design to deployment.

## Overview

We'll build a "Metrics Valve" that:
- Tracks API request metrics
- Exposes metrics via HTTP endpoints
- Runs periodic cleanup tasks
- Provides health checks

## Step 1: Define the Valve Structure

Create `src/valves/metrics_valve.zig`:

```zig
const std = @import("std");
const E12 = @import("Engine12");

const MetricsValve = struct {
    valve: E12.Valve,
    request_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    error_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .valve = E12.Valve{
                .metadata = E12.ValveMetadata{
                    .name = "metrics",
                    .version = "1.0.0",
                    .description = "Request metrics tracking valve",
                    .author = "Your Name",
                    .required_capabilities = &[_]E12.ValveCapability{
                        .routes,
                        .middleware,
                        .background_tasks,
                        .health_checks,
                    },
                },
                .init = &Self.initValve,
                .deinit = &Self.deinitValve,
                .onAppStart = &Self.onStart,
                .onAppStop = &Self.onStop,
            },
            .allocator = allocator,
        };
    }

    pub fn initValve(v: *E12.Valve, ctx: *E12.ValveContext) !void {
        const self = @as(*Self, @ptrFromInt(@intFromPtr(v) - @offsetOf(Self, "valve")));
        
        // Note: Route registration through ctx.registerRoute() is not yet implemented
        // Routes must be registered directly on the app using app.get(), app.post(), etc.
        // For this example, routes would need to be registered manually after valve registration:
        // try app.get("/metrics/stats", Self.handleStats);
        // try app.get("/metrics/reset", Self.handleReset);
        
        // Register middleware to track requests
        try ctx.registerMiddleware(&Self.trackRequest);
        
        // Register periodic cleanup task (every 5 minutes)
        try ctx.registerTask("metrics_cleanup", Self.cleanupTask, 300000);
        
        // Register health check
        try ctx.registerHealthCheck(&Self.healthCheck);
        
        _ = self;
    }

    pub fn deinitValve(v: *E12.Valve) void {
        _ = v;
        // Cleanup if needed
    }

    pub fn onStart(v: *E12.Valve, ctx: *E12.ValveContext) !void {
        _ = v;
        _ = ctx;
        std.debug.print("[Metrics] Valve started\n", .{});
    }

    pub fn onStop(v: *E12.Valve, ctx: *E12.ValveContext) void {
        _ = v;
        _ = ctx;
        std.debug.print("[Metrics] Valve stopped\n", .{});
    }

    fn trackRequest(req: *E12.Request) E12.middleware.MiddlewareResult {
        const self = Self.getInstance(req);
        _ = self.request_count.fetchAdd(1, .monotonic);
        return .proceed;
    }

    fn handleStats(req: *E12.Request) E12.Response {
        const self = Self.getInstance(req);
        const requests = self.request_count.load(.monotonic);
        const errors = self.error_count.load(.monotonic);
        
        const json = std.fmt.allocPrint(
            req.arena.allocator(),
            "{{\"requests\":{},\"errors\":{}}}",
            .{ requests, errors }
        ) catch {
            return E12.Response.serverError("Failed to format metrics");
        };
        
        return E12.Response.json(json);
    }

    fn handleReset(req: *E12.Request) E12.Response {
        const self = Self.getInstance(req);
        self.request_count.store(0, .monotonic);
        self.error_count.store(0, .monotonic);
        return E12.Response.json("{\"status\":\"reset\"}");
    }

    fn cleanupTask() void {
        std.debug.print("[Metrics] Running cleanup\n", .{});
    }

    fn healthCheck() E12.types.HealthStatus {
        return .healthy;
    }

    // Helper to get instance from request context
    fn getInstance(req: *E12.Request) *Self {
        // In a real implementation, store self pointer in request context
        // For this example, we'll use a global (not thread-safe in production)
        _ = req;
        // This is simplified - in production, use request context to store valve instance
        return undefined; // Would need proper instance management
    }
};
```

## Step 2: Register the Valve

In your `main.zig`:

```zig
const std = @import("std");
const E12 = @import("Engine12");
const MetricsValve = @import("valves/metrics_valve.zig").MetricsValve;

const allocator = std.heap.page_allocator;

pub fn main() !void {
    var app = try E12.Engine12.initProduction();
    defer app.deinit();

    // Register metrics valve
    var metrics_valve = MetricsValve.init(allocator);
    try app.registerValve(&metrics_valve.valve);

    // Note: Route registration through valve context is not yet implemented
    // Register valve routes manually after valve registration:
    // try app.get("/metrics/stats", MetricsValve.handleStats);
    // try app.get("/metrics/reset", MetricsValve.handleReset);

    // Register your routes
    try app.get("/", handleRoot);

    try app.start();
    app.printStatus();
    
    // Keep server running
    std.Thread.sleep(std.time.ns_per_min * 60);
}

fn handleRoot(req: *E12.Request) E12.Response {
    _ = req;
    return E12.Response.text("Hello, World!");
}
```

## Step 3: Testing Your Valve

Create a test file `src/valves/metrics_valve_test.zig`:

```zig
const std = @import("std");
const E12 = @import("Engine12");
const MetricsValve = @import("metrics_valve.zig").MetricsValve;

test "MetricsValve registration" {
    var app = try E12.Engine12.initTesting();
    defer app.deinit();

    var metrics_valve = MetricsValve.init(std.testing.allocator);
    try app.registerValve(&metrics_valve.valve);

    // Verify valve is registered
    const registry = app.getValveRegistry();
    try std.testing.expect(registry != null);
    
    if (registry) |reg| {
        const ctx = reg.getContext("metrics");
        try std.testing.expect(ctx != null);
    }
}

test "MetricsValve lifecycle hooks" {
    var app = try E12.Engine12.initTesting();
    defer app.deinit();

    var metrics_valve = MetricsValve.init(std.testing.allocator);
    try app.registerValve(&metrics_valve.valve);

    // Test app start hook
    try app.start();
    
    // Test app stop hook
    try app.stop();
}
```

## Step 4: Packaging for Reuse

To make your valve reusable across projects:

1. **Create a separate package**: Structure your valve as a standalone Zig package
2. **Export public API**: Export only the necessary types and functions
3. **Document dependencies**: List required Engine12 capabilities
4. **Version your valve**: Use semantic versioning in metadata

Example package structure:

```
metrics-valve/
├── build.zig
├── build.zig.zon
├── src/
│   └── metrics_valve.zig
└── README.md
```

## Step 5: Best Practices

1. **Minimal Capabilities**: Only request capabilities you actually use
2. **Error Handling**: Always handle capability errors gracefully
3. **Resource Cleanup**: Implement proper cleanup in `deinit`
4. **Thread Safety**: Use atomic operations for shared state
5. **Documentation**: Document your valve's purpose and usage

## Advanced: Accessing Engine12 Resources

If your valve needs database access:

```zig
pub fn initValve(v: *E12.Valve, ctx: *E12.ValveContext) !void {
    // Check for database capability
    if (ctx.hasCapability(.database_access)) {
        if (try ctx.getORM()) |orm| {
            // Use ORM
            // Note: This is just an example - actual ORM usage would happen in route handlers
            // const todos = try orm.findAll(Todo);
            _ = orm;
        }
    }
    _ = v;
}
```

If your valve needs cache access:

```zig
pub fn initValve(v: *E12.Valve, ctx: *E12.ValveContext) !void {
    if (ctx.hasCapability(.cache_access)) {
        if (ctx.getCache()) |cache| {
            // Use cache
            try cache.set("key", "value", 60000);
        }
    }
}
```

## Troubleshooting

### Capability Errors

If you get `error.CapabilityRequired`:
- Check that your valve's metadata includes the required capability
- Verify the capability is spelled correctly
- Ensure you're checking capabilities before use

### Lifecycle Issues

If lifecycle hooks aren't called:
- Ensure `onAppStart`/`onAppStop` are not null
- Verify valve is registered before `app.start()` is called
- Check that `app.start()` and `app.stop()` are actually called

### Memory Management

- Use the allocator from `ValveContext` for valve-specific allocations
- Free resources in `deinit`
- Be careful with global state - prefer request context for per-request data

## Next Steps

- Explore the builtin valves in `src/valve/builtin/` (e.g., `BasicAuthValve`)
- Read the [API Reference](../api-reference.md#valve-system) for complete documentation
- Check the [Architecture Guide](../architecture.md#valve-system-architecture) for design details

