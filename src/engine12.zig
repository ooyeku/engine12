const std = @import("std");
const vigil = @import("vigil");
const ziggurat = @import("ziggurat");
const types = @import("types.zig");
const handlers = @import("handlers.zig");
const fileserver = @import("fileserver.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const router = @import("router.zig");
const middleware_chain = @import("middleware.zig");
const route_group = @import("route_group.zig");
const error_handler = @import("error_handler.zig");
const metrics = @import("metrics.zig");
const rate_limit = @import("rate_limit.zig");
const cache = @import("cache.zig");
const dev_tools = @import("dev_tools.zig");
const valve_registry_mod = @import("valve/registry.zig");
const valve_mod = @import("valve/valve.zig");

const allocator = std.heap.page_allocator;

/// Generate a unique request ID
/// Uses a stack buffer to format, then allocates directly into the provided allocator
/// This avoids double allocation and memory leaks
fn generateRequestId(alloc: std.mem.Allocator) ![]const u8 {
    const timestamp = std.time.milliTimestamp();
    const random = @as(u64, @intCast(std.time.nanoTimestamp())) % 1000000;
    var buffer: [64]u8 = undefined;
    const id_str = std.fmt.bufPrint(&buffer, "req_{d}_{d}", .{ timestamp, random }) catch {
        // Fallback if bufPrint somehow fails (shouldn't happen)
        return alloc.dupe(u8, "req_unknown");
    };
    return alloc.dupe(u8, id_str);
}

/// Global middleware pointer (thread-local for thread safety)
/// This is set when routes are registered and accessed at runtime
///
/// Thread Safety:
/// - This pointer is set once per route registration and read-only during request handling
/// - Each request handler runs in its own thread context
/// - No mutex needed as the pointer itself is immutable after initialization
var global_middleware: ?*const middleware_chain.MiddlewareChain = null;

/// Global metrics collector pointer
/// This is set when routes are registered and accessed at runtime
///
/// Thread Safety:
/// - Metrics operations use internal thread-safe mechanisms
/// - Multiple threads can safely increment counters concurrently
pub var global_metrics: ?*metrics.MetricsCollector = null;

/// Global rate limiter pointer
/// This is set when routes are registered and accessed at runtime
///
/// Thread Safety:
/// - Rate limiter uses internal mutex for thread-safe access
/// - Multiple threads can safely check rate limits concurrently
pub var global_rate_limiter: ?*rate_limit.RateLimiter = null;

/// Global cache pointer
/// This is set when routes are registered and accessed at runtime
///
/// Thread Safety:
/// - Cache uses internal mutex for thread-safe access
/// - Multiple threads can safely read/write cache entries concurrently
pub var global_cache: ?*cache.ResponseCache = null;

/// Global error handler registry pointer
/// This is set when Engine12 is initialized and accessed at runtime
///
/// Thread Safety:
/// - Error handler registry is read-only after initialization
/// - No mutex needed as handlers are immutable function pointers
pub var global_error_handler: ?*error_handler.ErrorHandlerRegistry = null;

/// Wrap an Engine12 handler to work with ziggurat
/// Creates an arena allocator for each request and automatically cleans it up
/// If route_pattern is provided, extracts route parameters from the request path
/// Executes middleware chain before and after handler
fn wrapHandler(comptime handler_fn: types.HttpHandler, comptime route_pattern: ?[]const u8) fn (*ziggurat.request.Request) ziggurat.response.Response {
    return struct {
        const handler = handler_fn;
        const pattern = route_pattern;

        fn wrapper(ziggurat_request: *ziggurat.request.Request) ziggurat.response.Response {
            // Access middleware from global (set when route is registered)
            const mw_chain = global_middleware orelse {
                // No middleware, proceed directly
                var engine12_request = Request.fromZiggurat(ziggurat_request, allocator);
                defer engine12_request.deinit();
                const engine12_response = handler(&engine12_request);
                return engine12_response.toZiggurat();
            };

            // Access metrics collector from global
            const metrics_collector = global_metrics;

            // Start timing
            const route_pattern_str = if (pattern) |p| p else ziggurat_request.path;
            var timing = metrics.RequestTiming.start(route_pattern_str);

            // Create request with arena allocator
            // Using page_allocator as backing for performance
            // The arena is warmed up inside fromZiggurat to prevent panics
            var engine12_request = Request.fromZiggurat(ziggurat_request, allocator);

            // Generate request ID directly into the request's arena allocator
            // This avoids double allocation and memory leaks
            const request_id = generateRequestId(engine12_request.arena.allocator()) catch "unknown";
            engine12_request.set("request_id", request_id) catch {};

            // Ensure cleanup happens even if handler panics
            defer engine12_request.deinit();

            // Execute pre-request middleware chain
            if (mw_chain.executePreRequest(&engine12_request)) |abort_response| {
                // Record error metrics
                if (metrics_collector) |mc| {
                    mc.incrementError();
                    timing.finish(mc) catch {};
                }
                return abort_response.toZiggurat();
            }

            // If route has parameters, extract them
            if (pattern) |pattern_str| {
                if (std.mem.indexOf(u8, pattern_str, ":") != null) {
                    // This route has parameters - parse and extract
                    var route_pattern_parsed = router.RoutePattern.parse(allocator, pattern_str) catch {
                        // If parsing fails, continue without params
                        const engine12_response = handler(&engine12_request);
                        var final_response = mw_chain.executeResponse(engine12_response, &engine12_request);
                        // Record timing
                        if (metrics_collector) |mc| {
                            timing.finish(mc) catch {};
                        }
                        return final_response.toZiggurat();
                    };
                    defer route_pattern_parsed.deinit(allocator);

                    // Match against request path
                    if (route_pattern_parsed.match(engine12_request.arena.allocator(), ziggurat_request.path) catch null) |params| {
                        engine12_request.setRouteParams(params) catch |err| {
                            // If setting params fails, log and continue without params
                            std.debug.print("Failed to set route params: {}\n", .{err});
                        };
                    }
                }
            }

            // Call the Engine12 handler
            // Error handler registry is available via global_error_handler if handlers need it
            var engine12_response = handler(&engine12_request);

            // Execute response middleware chain (pass request for cache headers)
            engine12_response = mw_chain.executeResponse(engine12_response, &engine12_request);

            // Record timing and metrics
            if (metrics_collector) |mc| {
                timing.finish(mc) catch {};
            }

            // Convert Engine12 response to ziggurat response
            // Note: Response data must be copied to persistent allocator before arena is freed
            return engine12_response.toZiggurat();
        }
    }.wrapper;
}

pub const Engine12 = struct {
    const MAX_ROUTES = 5000;
    const MAX_WORKERS = 16;
    const MAX_HEALTH_CHECKS = 8;
    const MAX_STATIC_ROUTES = 4;

    allocator: std.mem.Allocator,
    profile: types.ServerProfile,
    is_running: bool = false,
    request_count: u64 = 0,
    start_time: i64 = 0,

    // HTTP Server - store routes for tracking, but register immediately
    http_routes: [MAX_ROUTES]?types.Route = [_]?types.Route{null} ** MAX_ROUTES,
    routes_count: usize = 0,
    custom_root_handler: bool = false, // Track if custom root handler is registered
    server_builder: ?ziggurat.ServerBuilder = null,
    server_built: bool = false,
    built_server: ?ziggurat.Server = null,

    // Static File Serving
    static_routes: [MAX_STATIC_ROUTES]?fileserver.FileServer = [_]?fileserver.FileServer{null} ** MAX_STATIC_ROUTES,
    static_routes_count: usize = 0,
    static_root_mounted: bool = false, // Track if static files are mounted at "/"

    // Supervision
    background_workers: [MAX_WORKERS]?types.BackgroundWorker = [_]?types.BackgroundWorker{null} ** MAX_WORKERS,
    workers_count: usize = 0,

    // Health & Monitoring
    health_checks: [MAX_HEALTH_CHECKS]?types.HealthCheckFn = [_]?types.HealthCheckFn{null} ** MAX_HEALTH_CHECKS,
    health_checks_count: usize = 0,

    // Middleware Chain
    middleware: middleware_chain.MiddlewareChain,

    // Error Handler
    error_handler_registry: error_handler.ErrorHandlerRegistry,

    // Metrics Collector
    metrics_collector: metrics.MetricsCollector,

    // Logger
    logger: dev_tools.Logger,

    // Valve Registry
    valve_registry: ?valve_registry_mod.ValveRegistry = null,

    // Lifecycle
    supervisor: ?*anyopaque = null,
    http_server: ?*anyopaque = null,

    pub fn initWithProfile(profile: types.ServerProfile) !Engine12 {
        const app = Engine12{
            .allocator = allocator,
            .profile = profile,
            .middleware = middleware_chain.MiddlewareChain{},
            .error_handler_registry = error_handler.ErrorHandlerRegistry.init(allocator),
            .metrics_collector = metrics.MetricsCollector.init(allocator),
            .logger = dev_tools.Logger.fromEnvironment(allocator, profile.environment),
        };
        return app;
    }

    /// Initialize Engine12 for development
    pub fn initDevelopment() !Engine12 {
        return Engine12.initWithProfile(types.ServerProfile_Development);
    }

    /// Initialize Engine12 for production
    pub fn initProduction() !Engine12 {
        return Engine12.initWithProfile(types.ServerProfile_Production);
    }

    /// Initialize Engine12 for testing
    pub fn initTesting() !Engine12 {
        return Engine12.initWithProfile(types.ServerProfile_Testing);
    }

    /// Clean up server resources
    pub fn deinit(self: *Engine12) void {
        self.is_running = false;

        // Cleanup valve registry
        if (self.valve_registry) |*registry| {
            registry.deinit();
            self.valve_registry = null;
        }
    }

    /// Register a valve with this Engine12 instance
    /// Valves provide isolated services that integrate with Engine12 runtime
    ///
    /// Example:
    /// ```zig
    /// var auth_valve = AuthValve.init(...);
    /// try app.registerValve(&auth_valve.valve);
    /// ```
    pub fn registerValve(self: *Engine12, valve_ptr: *valve_mod.Valve) !void {
        // Initialize registry if needed
        if (self.valve_registry == null) {
            self.valve_registry = valve_registry_mod.ValveRegistry.init(self.allocator);
        }

        // Register valve
        if (self.valve_registry) |*registry| {
            try registry.register(valve_ptr, self);
        }
    }

    /// Unregister a valve by name
    ///
    /// Example:
    /// ```zig
    /// try app.unregisterValve("auth");
    /// ```
    pub fn unregisterValve(self: *Engine12, name: []const u8) !void {
        if (self.valve_registry) |*registry| {
            try registry.unregister(name);
        } else {
            return valve_mod.ValveError.ValveNotFound;
        }
    }

    /// Get the valve registry instance
    /// Returns null if no valves are registered
    pub fn getValveRegistry(self: *Engine12) ?*valve_registry_mod.ValveRegistry {
        if (self.valve_registry) |*registry| {
            return registry;
        }
        return null;
    }

    /// Register a GET endpoint
    /// Handler can be passed directly (function) or as a pointer (*const fn)
    /// Supports route parameters with :param syntax (e.g., "/todos/:id")
    pub fn get(self: *Engine12, comptime path_pattern: []const u8, handler: anytype) !void {
        const handler_fn: types.HttpHandler = handler;

        if (self.routes_count >= MAX_ROUTES) {
            return error.TooManyRoutes;
        }
        if (self.server_built) {
            return error.ServerAlreadyBuilt;
        }

        // Track if this is a custom root handler BEFORE building server
        if (std.mem.eql(u8, path_pattern, "/")) {
            self.custom_root_handler = true;
        }

        // Build server if not already built
        if (self.built_server == null) {
            var builder = ziggurat.ServerBuilder.init(self.allocator);
            var server = try builder
                .host("127.0.0.1")
                .port(8080)
                .readTimeout(5000)
                .writeTimeout(5000)
                .build();

            // Register default routes (skip "/" if static files will be served at root or custom handler registered)
            global_middleware = &self.middleware;
            global_metrics = &self.metrics_collector;
            if (!self.static_root_mounted and !self.custom_root_handler) {
                try server.get("/", wrapHandler(handlers.handleDefaultRoot, "/"));
            }
            try server.get("/health", wrapHandler(handlers.handleHealthEndpoint, "/health"));
            try server.get("/metrics", wrapHandler(handlers.handleMetricsEndpoint, "/metrics"));

            self.built_server = server;
            self.http_server = @ptrCast(&server);
        }

        // Wrap the Engine12 handler to work with ziggurat
        // path_pattern is comptime-known, so it can be captured in the wrapper
        // Set global middleware before registering so wrapper can access it
        global_middleware = &self.middleware;
        global_metrics = &self.metrics_collector;

        const wrapped_handler = wrapHandler(handler_fn, path_pattern);

        // Register immediately - wrapped handler is comptime-known
        if (self.built_server) |*server| {
            try server.get(path_pattern, wrapped_handler);
        }

        // Store route info after registration
        self.http_routes[self.routes_count] = types.Route{
            .path = path_pattern,
            .method = "GET",
            .handler_ptr = &handler,
        };
        self.routes_count += 1;
    }

    /// Register a POST endpoint
    /// Handler can be passed directly (function) or as a pointer (*const fn)
    /// Supports route parameters with :param syntax (e.g., "/todos/:id")
    pub fn post(self: *Engine12, comptime path_pattern: []const u8, handler: anytype) !void {
        const handler_fn: types.HttpHandler = handler;

        if (self.routes_count >= MAX_ROUTES) {
            return error.TooManyRoutes;
        }
        if (self.server_built) {
            return error.ServerAlreadyBuilt;
        }

        // Build server if not already built
        if (self.built_server == null) {
            var builder = ziggurat.ServerBuilder.init(self.allocator);
            var server = try builder
                .host("127.0.0.1")
                .port(8080)
                .readTimeout(5000)
                .writeTimeout(5000)
                .build();

            // Register default routes (skip "/" if static files will be served at root or custom handler registered)
            global_middleware = &self.middleware;
            global_metrics = &self.metrics_collector;
            if (!self.static_root_mounted and !self.custom_root_handler) {
                try server.get("/", wrapHandler(handlers.handleDefaultRoot, "/"));
            }
            try server.get("/health", wrapHandler(handlers.handleHealthEndpoint, "/health"));
            try server.get("/metrics", wrapHandler(handlers.handleMetricsEndpoint, "/metrics"));

            self.built_server = server;
            self.http_server = @ptrCast(&server);
        }

        // Wrap the Engine12 handler to work with ziggurat
        const wrapped_handler = wrapHandler(handler_fn, path_pattern);

        if (self.built_server) |*server| {
            try server.post(path_pattern, wrapped_handler);
        }

        self.http_routes[self.routes_count] = types.Route{
            .path = path_pattern,
            .method = "POST",
            .handler_ptr = &handler,
        };
        self.routes_count += 1;
    }

    /// Register a PUT endpoint
    /// Handler can be passed directly (function) or as a pointer (*const fn)
    /// Supports route parameters with :param syntax (e.g., "/todos/:id")
    pub fn put(self: *Engine12, comptime path_pattern: []const u8, handler: anytype) !void {
        const handler_fn: types.HttpHandler = handler;
        if (self.routes_count >= MAX_ROUTES) {
            return error.TooManyRoutes;
        }
        if (self.server_built) {
            return error.ServerAlreadyBuilt;
        }

        if (self.built_server == null) {
            var builder = ziggurat.ServerBuilder.init(self.allocator);
            var server = try builder
                .host("127.0.0.1")
                .port(8080)
                .readTimeout(5000)
                .writeTimeout(5000)
                .build();

            // Register default routes (skip "/" if static files will be served at root or custom handler registered)
            global_middleware = &self.middleware;
            global_metrics = &self.metrics_collector;
            if (!self.static_root_mounted and !self.custom_root_handler) {
                try server.get("/", wrapHandler(handlers.handleDefaultRoot, "/"));
            }
            try server.get("/health", wrapHandler(handlers.handleHealthEndpoint, "/health"));
            try server.get("/metrics", wrapHandler(handlers.handleMetricsEndpoint, "/metrics"));

            self.built_server = server;
            self.http_server = @ptrCast(&server);
        }

        // Wrap the Engine12 handler to work with ziggurat
        const wrapped_handler = wrapHandler(handler_fn, path_pattern);

        if (self.built_server) |*server| {
            try server.put(path_pattern, wrapped_handler);
        }

        self.http_routes[self.routes_count] = types.Route{
            .path = path_pattern,
            .method = "PUT",
            .handler_ptr = &handler,
        };
        self.routes_count += 1;
    }

    /// Register a DELETE endpoint
    /// Handler can be passed directly (function) or as a pointer (*const fn)
    /// Supports route parameters with :param syntax (e.g., "/todos/:id")
    pub fn delete(self: *Engine12, comptime path_pattern: []const u8, handler: anytype) !void {
        const handler_fn: types.HttpHandler = handler;
        if (self.routes_count >= MAX_ROUTES) {
            return error.TooManyRoutes;
        }
        if (self.server_built) {
            return error.ServerAlreadyBuilt;
        }

        if (self.built_server == null) {
            var builder = ziggurat.ServerBuilder.init(self.allocator);
            var server = try builder
                .host("127.0.0.1")
                .port(8080)
                .readTimeout(5000)
                .writeTimeout(5000)
                .build();

            // Register default routes (skip "/" if static files will be served at root or custom handler registered)
            global_middleware = &self.middleware;
            global_metrics = &self.metrics_collector;
            if (!self.static_root_mounted and !self.custom_root_handler) {
                try server.get("/", wrapHandler(handlers.handleDefaultRoot, "/"));
            }
            try server.get("/health", wrapHandler(handlers.handleHealthEndpoint, "/health"));
            try server.get("/metrics", wrapHandler(handlers.handleMetricsEndpoint, "/metrics"));

            self.built_server = server;
            self.http_server = @ptrCast(&server);
        }

        // Wrap the Engine12 handler to work with ziggurat
        const wrapped_handler = wrapHandler(handler_fn, path_pattern);

        if (self.built_server) |*server| {
            try server.delete(path_pattern, wrapped_handler);
        }

        self.http_routes[self.routes_count] = types.Route{
            .path = path_pattern,
            .method = "DELETE",
            .handler_ptr = &handler,
        };
        self.routes_count += 1;
    }

    /// Create a route group with a prefix and optional shared middleware
    ///
    /// Example:
    /// ```zig
    /// var api = app.group("/api");
    /// api.usePreRequest(authMiddleware);
    /// api.get("/todos", handleTodos);  // Registers at /api/todos
    /// ```
    pub fn group(self: *Engine12, prefix: []const u8) route_group.RouteGroup {
        // Create wrapper functions that cast engine_ptr back to Engine12
        const get_wrapper = struct {
            fn wrap(ptr: *anyopaque, comptime path: []const u8, handler: anytype) !void {
                const engine = @as(*Engine12, @ptrCast(ptr));
                try engine.get(path, handler);
            }
        }.wrap;

        const post_wrapper = struct {
            fn wrap(ptr: *anyopaque, comptime path: []const u8, handler: anytype) !void {
                const engine = @as(*Engine12, @ptrCast(ptr));
                try engine.post(path, handler);
            }
        }.wrap;

        const put_wrapper = struct {
            fn wrap(ptr: *anyopaque, comptime path: []const u8, handler: anytype) !void {
                const engine = @as(*Engine12, @ptrCast(ptr));
                try engine.put(path, handler);
            }
        }.wrap;

        const delete_wrapper = struct {
            fn wrap(ptr: *anyopaque, comptime path: []const u8, handler: anytype) !void {
                const engine = @as(*Engine12, @ptrCast(ptr));
                try engine.delete(path, handler);
            }
        }.wrap;

        return route_group.RouteGroup{
            .engine_ptr = @as(*anyopaque, @ptrCast(self)),
            .prefix = prefix,
            .middleware = middleware_chain.MiddlewareChain{},
            .register_get = get_wrapper,
            .register_post = post_wrapper,
            .register_put = put_wrapper,
            .register_delete = delete_wrapper,
        };
    }

    /// Register a custom error handler
    ///
    /// Example:
    /// ```zig
    /// app.useErrorHandler(customErrorHandler);
    /// ```
    pub fn useErrorHandler(self: *Engine12, handler: error_handler.ErrorHandler) void {
        self.error_handler_registry.register(handler);
    }

    /// Set a global rate limiter for all routes
    pub fn setRateLimiter(self: *Engine12, limiter: *rate_limit.RateLimiter) void {
        _ = self;
        global_rate_limiter = limiter;
    }

    /// Set a global response cache for all routes
    pub fn setCache(self: *Engine12, response_cache: *cache.ResponseCache) void {
        _ = self;
        global_cache = response_cache;
    }

    /// Get the global response cache instance
    /// Returns null if cache is not configured
    pub fn getCache(self: *Engine12) ?*cache.ResponseCache {
        _ = self;
        return global_cache;
    }

    /// Add a pre-request middleware to the chain
    /// Middleware are executed in the order they are added
    /// Middleware can short-circuit by returning .abort
    ///
    /// Example:
    /// ```zig
    /// app.usePreRequest(authMiddleware);
    /// app.usePreRequest(loggingMiddleware);
    /// ```
    pub fn usePreRequest(self: *Engine12, middleware: middleware_chain.PreRequestMiddlewareFn) !void {
        try self.middleware.addPreRequest(middleware);
    }

    /// Add a response middleware to the chain
    /// Middleware are executed in the order they are added
    ///
    /// Example:
    /// ```zig
    /// app.useResponse(corsMiddleware);
    /// app.useResponse(loggingMiddleware);
    /// ```
    pub fn useResponse(self: *Engine12, middleware: middleware_chain.ResponseMiddlewareFn) !void {
        try self.middleware.addResponse(middleware);
    }

    /// Register static file serving from a directory
    pub fn serveStatic(self: *Engine12, mount_path: []const u8, directory: []const u8) !void {
        if (self.static_routes_count >= MAX_STATIC_ROUTES) {
            return error.TooManyStaticRoutes;
        }
        if (self.server_built) {
            return error.ServerAlreadyBuilt;
        }

        const file_server = fileserver.FileServer.init(self.allocator, mount_path, directory);

        // Track if static files are mounted at root
        if (std.mem.eql(u8, mount_path, "/")) {
            self.static_root_mounted = true;
        }

        // Store a copy of the FileServer
        self.static_routes[self.static_routes_count] = file_server;
        self.static_routes_count += 1;

        // Build server if not already built
        if (self.built_server == null) {
            var builder = ziggurat.ServerBuilder.init(self.allocator);
            var server = try builder
                .host("127.0.0.1")
                .port(8080)
                .readTimeout(5000)
                .writeTimeout(5000)
                .build();

            // Register default routes (but skip "/" if we're mounting static files at root or custom handler registered)
            if (!std.mem.eql(u8, mount_path, "/") and !self.custom_root_handler) {
                try server.get("/", wrapHandler(handlers.handleDefaultRoot, "/"));
            }
            try server.get("/health", wrapHandler(handlers.handleHealthEndpoint, "/health"));
            try server.get("/metrics", wrapHandler(handlers.handleMetricsEndpoint, "/metrics"));

            self.built_server = server;
            self.http_server = @ptrCast(&server);
        }

        // Register static file handler immediately - create individual wrapper per route
        const static_index = static_file_registry_count;
        static_file_registry[static_index] = file_server;
        static_file_registry_count += 1;

        if (self.built_server) |*server| {
            // Store the mount path for this registry entry
            static_mount_paths[static_index] = mount_path;

            // For root mount, register "/" and also register common frontend paths
            if (std.mem.eql(u8, mount_path, "/")) {
                // Override the default root handler if it was already registered
                // Create inline wrappers that look up the FileServer by mount path at runtime
                const root_wrapper = struct {
                    fn handler(request: *ziggurat.request.Request) ziggurat.response.Response {
                        _ = request;
                        // Find FileServer for "/" mount
                        var i: usize = 0;
                        while (i < static_file_registry_count) {
                            if (static_file_registry[i]) |*fs| {
                                if (std.mem.eql(u8, static_mount_paths[i], "/")) {
                                    return fs.serveFile("/").toZiggurat();
                                }
                            }
                            i += 1;
                        }
                        return Response.text("Static file server not found").toZiggurat();
                    }
                }.handler;

                // Register root handler - this will override any previous "/" handler
                try server.get("/", root_wrapper);

                const css_wrapper = struct {
                    fn handler(request: *ziggurat.request.Request) ziggurat.response.Response {
                        _ = request;
                        var i: usize = 0;
                        while (i < static_file_registry_count) {
                            if (static_file_registry[i]) |*fs| {
                                if (std.mem.eql(u8, static_mount_paths[i], "/")) {
                                    return fs.serveFile("/css/styles.css").toZiggurat();
                                }
                            }
                            i += 1;
                        }
                        return Response.text("Static file server not found").toZiggurat();
                    }
                }.handler;

                const js_wrapper = struct {
                    fn handler(request: *ziggurat.request.Request) ziggurat.response.Response {
                        _ = request;
                        var i: usize = 0;
                        while (i < static_file_registry_count) {
                            if (static_file_registry[i]) |*fs| {
                                if (std.mem.eql(u8, static_mount_paths[i], "/")) {
                                    return fs.serveFile("/js/app.js").toZiggurat();
                                }
                            }
                            i += 1;
                        }
                        return Response.text("Static file server not found").toZiggurat();
                    }
                }.handler;

                try server.get("/css/styles.css", css_wrapper);
                try server.get("/js/app.js", js_wrapper);
            } else {
                // For non-root mounts, register a handler that extracts the full path from the request
                // This allows serving files like /css/styles.css, /js/app.js, etc.
                const wrapper = struct {
                    fn handler(request: *ziggurat.request.Request) ziggurat.response.Response {
                        // Get the full request path (e.g., "/css/styles.css")
                        const request_path = request.path;

                        // Find FileServer by matching mount path prefix in registry
                        var i: usize = 0;
                        while (i < static_file_registry_count) {
                            if (static_file_registry[i]) |*fs| {
                                const registry_mount = static_mount_paths[i];
                                // Check if request path starts with the mount path
                                if (std.mem.startsWith(u8, request_path, registry_mount)) {
                                    // Serve the file using the full request path
                                    return fs.serveFile(request_path).toZiggurat();
                                }
                            }
                            i += 1;
                        }
                        return Response.text("Static file server not found").toZiggurat();
                    }
                }.handler;

                // Register the base mount path handler
                // The wrapper handler checks request.path dynamically to handle all subpaths
                // This avoids segfault from passing runtime-allocated strings to ziggurat
                try server.get(mount_path, wrapper);

                // Register common subpaths explicitly for better matching
                // These are comptime strings so they're safe to pass to ziggurat
                if (std.mem.eql(u8, mount_path, "/css")) {
                    try server.get("/css/styles.css", wrapper);
                } else if (std.mem.eql(u8, mount_path, "/js")) {
                    try server.get("/js/app.js", wrapper);
                }
            }
        }
    }

    /// Register a background task that runs once
    pub fn runTask(self: *Engine12, name: []const u8, task: types.BackgroundTask) !void {
        if (self.workers_count >= MAX_WORKERS) {
            return error.TooManyWorkers;
        }
        self.background_workers[self.workers_count] = types.BackgroundWorker{
            .name = name,
            .task = task,
            .interval_ms = null,
        };
        self.workers_count += 1;
    }

    /// Register a background task that runs periodically
    pub fn schedulePeriodicTask(self: *Engine12, name: []const u8, task: types.BackgroundTask, interval_ms: u32) !void {
        if (self.workers_count >= MAX_WORKERS) {
            return error.TooManyWorkers;
        }
        self.background_workers[self.workers_count] = types.BackgroundWorker{
            .name = name,
            .task = task,
            .interval_ms = interval_ms,
        };
        self.workers_count += 1;
    }

    /// Register a health check function
    pub fn registerHealthCheck(self: *Engine12, check: types.HealthCheckFn) !void {
        if (self.health_checks_count >= MAX_HEALTH_CHECKS) {
            return error.TooManyHealthChecks;
        }
        self.health_checks[self.health_checks_count] = check;
        self.health_checks_count += 1;
    }

    /// Get overall system health status
    pub fn getSystemHealth(self: *Engine12) types.HealthStatus {
        var overall_status: types.HealthStatus = .healthy;
        var i: usize = 0;
        while (i < self.health_checks_count) {
            if (self.health_checks[i]) |check| {
                const status = check();
                if (status == .unhealthy) {
                    return .unhealthy;
                }
                if (status == .degraded and overall_status == .healthy) {
                    overall_status = .degraded;
                }
            }
            i += 1;
        }
        return overall_status;
    }

    /// Get uptime in milliseconds
    pub fn getUptimeMs(self: *Engine12) i64 {
        if (self.start_time == 0) return 0;
        return std.time.milliTimestamp() - self.start_time;
    }

    /// Get total request count
    pub fn getRequestCount(self: *Engine12) u64 {
        return self.request_count;
    }

    /// Start the entire system (HTTP server + background tasks)
    pub fn start(self: *Engine12) !void {
        self.start_time = std.time.milliTimestamp();
        self.is_running = true;

        try self.startHttpServer();
        try self.startBackgroundTasks();

        // Call onAppStart for all registered valves
        if (self.valve_registry) |*registry| {
            registry.onAppStart() catch |err| {
                std.debug.print("[Valve] Error during valve onAppStart: {}\n", .{err});
            };
        }
    }

    /// Stop the entire system gracefully
    pub fn stop(self: *Engine12) !void {
        std.debug.print("\n[System] Initiating graceful shutdown...\n", .{});

        // Call onAppStop for all registered valves
        if (self.valve_registry) |*registry| {
            registry.onAppStop();
        }

        try self.stopHttpServer();
        try self.stopBackgroundTasks();

        self.is_running = false;
        const uptime = self.getUptimeMs();
        std.debug.print("[System] Shutdown complete. Uptime: {d}ms\n", .{uptime});
    }

    fn startHttpServer(self: *Engine12) !void {
        // Mark server as built - no more routes can be registered
        self.server_built = true;

        // Start the server in a background thread (ziggurat's start() is blocking)
        if (self.built_server) |*server| {
            const ServerThread = struct {
                server_ptr: *ziggurat.Server,
                fn run(ctx: @This()) void {
                    ctx.server_ptr.start() catch |err| {
                        std.debug.print("[HTTP] Server error: {}\n", .{err});
                    };
                }
            };

            var thread = try std.Thread.spawn(.{}, ServerThread.run, .{ServerThread{ .server_ptr = server }});
            thread.detach();
            return;
        }

        return error.ServerNotBuilt;
    }

    fn stopHttpServer(self: *Engine12) !void {
        if (self.http_server != null) {
            std.debug.print("[HTTP] Server shutdown\n", .{});
        }
    }

    fn startBackgroundTasks(self: *Engine12) !void {
        var supervisor = vigil.supervisor(self.allocator);

        var i: usize = 0;
        while (i < self.workers_count) {
            if (self.background_workers[i]) |worker| {
                _ = supervisor.child(worker.name, worker.task) catch |err| {
                    std.debug.print("[ERROR] Failed to start task '{s}': {any}\n", .{ worker.name, err });
                };
            }
            i += 1;
        }

        var sup = supervisor.build();
        self.supervisor = @ptrCast(&sup);

        try sup.start();
    }

    fn stopBackgroundTasks(self: *Engine12) !void {
        if (self.supervisor != null) {
            std.debug.print("[Tasks] Stopping all background tasks...\n", .{});
        }
    }

    /// Print streamlined server status
    pub fn printStatus(self: *Engine12) void {
        std.debug.print("\nServer ready\n", .{});
        std.debug.print("  Status: {s} | Health: {s} | Routes: {d} | Tasks: {d}\n", .{
            if (self.is_running) "RUNNING" else "STOPPED",
            @tagName(self.getSystemHealth()),
            self.routes_count,
            self.workers_count,
        });
        std.debug.print("\nFrontend: http://127.0.0.1:8080/\n", .{});
        std.debug.print("API: http://127.0.0.1:8080/api/todos\n\n", .{});
    }
};

// Test helper functions
fn testDummyHandler(_: *ziggurat.request.Request) ziggurat.response.Response {
    return ziggurat.response.Response.json("{}");
}

fn testDummyTask() void {}

fn testDummyHealthCheck() types.HealthStatus {
    return .healthy;
}

fn testDummyDegradedCheck() types.HealthStatus {
    return .degraded;
}

fn testDummyUnhealthyCheck() types.HealthStatus {
    return .unhealthy;
}

fn testDummyPreRequestMiddleware(_: *ziggurat.request.Request) bool {
    return true;
}

fn testDummyResponseMiddleware(_: ziggurat.response.Response) ziggurat.response.Response {
    return ziggurat.response.Response.json("{}");
}

// Tests
test "Engine12 initWithProfile" {
    const profile = types.ServerProfile_Development;
    var app = try Engine12.initWithProfile(profile);
    defer app.deinit();
    try std.testing.expectEqual(app.profile.environment, types.Environment.development);
    try std.testing.expect(app.is_running == false);
    try std.testing.expectEqual(app.routes_count, 0);
}

test "Engine12 initDevelopment" {
    var app = try Engine12.initDevelopment();
    defer app.deinit();
    try std.testing.expectEqual(app.profile.environment, types.Environment.development);
}

test "Engine12 initProduction" {
    var app = try Engine12.initProduction();
    defer app.deinit();
    try std.testing.expectEqual(app.profile.environment, types.Environment.production);
}

test "Engine12 initTesting" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try std.testing.expectEqual(app.profile.environment, types.Environment.staging);
}

test "Engine12 get request registration" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try app.get("/test", &testDummyHandler);
    try std.testing.expectEqual(app.routes_count, 1);
    try std.testing.expect(app.http_routes[0] != null);
    if (app.http_routes[0]) |route| {
        try std.testing.expectEqualStrings(route.path, "/test");
    }
}

test "Engine12 post request registration" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try app.post("/test", &testDummyHandler);
    try std.testing.expectEqual(app.routes_count, 1);
}

test "Engine12 put request registration" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try app.put("/test", &testDummyHandler);
    try std.testing.expectEqual(app.routes_count, 1);
}

test "Engine12 delete request registration" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try app.delete("/test", &testDummyHandler);
    try std.testing.expectEqual(app.routes_count, 1);
}

test "Engine12 get request registration fails when max routes exceeded" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    // Fill up all routes
    var i: usize = 0;
    while (i < Engine12.MAX_ROUTES) : (i += 1) {
        try app.get("/test", &testDummyHandler);
    }
    // Should fail on next registration
    try std.testing.expectError(error.TooManyRoutes, app.get("/test", &testDummyHandler));
}

test "Engine12 runTask registration" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try app.runTask("test_task", &testDummyTask);
    try std.testing.expectEqual(app.workers_count, 1);
    try std.testing.expect(app.background_workers[0] != null);
    if (app.background_workers[0]) |worker| {
        try std.testing.expectEqualStrings(worker.name, "test_task");
        try std.testing.expect(worker.interval_ms == null);
    }
}

test "Engine12 schedulePeriodicTask registration" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try app.schedulePeriodicTask("periodic_task", &testDummyTask, 1000);
    try std.testing.expectEqual(app.workers_count, 1);
    try std.testing.expect(app.background_workers[0] != null);
    if (app.background_workers[0]) |worker| {
        try std.testing.expectEqualStrings(worker.name, "periodic_task");
        try std.testing.expect(worker.interval_ms != null);
        try std.testing.expectEqual(worker.interval_ms.?, 1000);
    }
}

test "Engine12 runTask fails when max workers exceeded" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    // Fill up all workers
    var i: usize = 0;
    while (i < Engine12.MAX_WORKERS) : (i += 1) {
        try app.runTask("task", &testDummyTask);
    }
    // Should fail on next registration
    try std.testing.expectError(error.TooManyWorkers, app.runTask("task", &testDummyTask));
}

test "Engine12 registerHealthCheck" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try app.registerHealthCheck(&testDummyHealthCheck);
    try std.testing.expectEqual(app.health_checks_count, 1);
    try std.testing.expect(app.health_checks[0] != null);
}

test "Engine12 registerHealthCheck fails when max checks exceeded" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    // Fill up all health checks
    var i: usize = 0;
    while (i < Engine12.MAX_HEALTH_CHECKS) : (i += 1) {
        try app.registerHealthCheck(&testDummyHealthCheck);
    }
    // Should fail on next registration
    try std.testing.expectError(error.TooManyHealthChecks, app.registerHealthCheck(&testDummyHealthCheck));
}

test "Engine12 getSystemHealth returns healthy when no checks" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try std.testing.expectEqual(app.getSystemHealth(), types.HealthStatus.healthy);
}

test "Engine12 getSystemHealth returns healthy when all checks pass" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try app.registerHealthCheck(&testDummyHealthCheck);
    try std.testing.expectEqual(app.getSystemHealth(), types.HealthStatus.healthy);
}

test "Engine12 getSystemHealth returns degraded when one check degraded" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try app.registerHealthCheck(&testDummyHealthCheck);
    try app.registerHealthCheck(&testDummyDegradedCheck);
    try std.testing.expectEqual(app.getSystemHealth(), types.HealthStatus.degraded);
}

test "Engine12 getSystemHealth returns unhealthy when one check unhealthy" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try app.registerHealthCheck(&testDummyHealthCheck);
    try app.registerHealthCheck(&testDummyUnhealthyCheck);
    try std.testing.expectEqual(app.getSystemHealth(), types.HealthStatus.unhealthy);
}

test "Engine12 getUptimeMs returns 0 when not started" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try std.testing.expectEqual(app.getUptimeMs(), 0);
}

test "Engine12 getRequestCount returns 0 initially" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try std.testing.expectEqual(app.getRequestCount(), 0);
}

test "Engine12 deinit sets is_running to false" {
    var app = try Engine12.initTesting();
    app.is_running = true;
    app.deinit();
    try std.testing.expect(app.is_running == false);
}

test "Engine12 usePreRequestMiddleware sets middleware" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    app.usePreRequestMiddleware(&testDummyPreRequestMiddleware);
    try std.testing.expect(app.pre_request_middleware != null);
}

test "Engine12 useResponseMiddleware sets middleware" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    app.useResponseMiddleware(&testDummyResponseMiddleware);
    try std.testing.expect(app.response_middleware != null);
}

test "Engine12 registerValve" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    const TestValve = struct {
        valve: valve_mod.Valve,
        init_called: bool = false,

        pub fn initFn(v: *valve_mod.Valve, ctx: *valve_registry_mod.context.ValveContext) !void {
            const Self = @This();
            const offset = @offsetOf(Self, "valve");
            const addr = @intFromPtr(v) - offset;
            const self = @as(*Self, @ptrFromInt(addr));
            self.init_called = true;
            _ = ctx;
        }

        pub fn deinitFn(v: *valve_mod.Valve) void {
            _ = v;
        }
    };

    var test_valve = TestValve{
        .valve = valve_mod.Valve{
            .metadata = valve_mod.ValveMetadata{
                .name = "test",
                .version = "1.0.0",
                .description = "Test",
                .author = "Test",
                .required_capabilities = &[_]valve_mod.ValveCapability{},
            },
            .init = &TestValve.initFn,
            .deinit = &TestValve.deinitFn,
        },
    };

    try app.registerValve(&test_valve.valve);
    try std.testing.expect(test_valve.init_called);
    try std.testing.expect(app.valve_registry != null);
}

test "Engine12 valve lifecycle hooks" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var on_start_called = false;
    var on_stop_called = false;

    const TestValve = struct {
        valve: valve_mod.Valve,
        on_start_called: *bool,
        on_stop_called: *bool,

        pub fn initFn(_: *valve_mod.Valve, _: *valve_registry_mod.context.ValveContext) !void {}
        pub fn deinitFn(_: *valve_mod.Valve) void {}

        pub fn onStartFn(v: *valve_mod.Valve, _: *valve_registry_mod.context.ValveContext) !void {
            const Self = @This();
            const offset = @offsetOf(Self, "valve");
            const addr = @intFromPtr(v) - offset;
            const self = @as(*Self, @ptrFromInt(addr));
            self.on_start_called.* = true;
        }

        pub fn onStopFn(v: *valve_mod.Valve, _: *valve_registry_mod.context.ValveContext) void {
            const Self = @This();
            const offset = @offsetOf(Self, "valve");
            const addr = @intFromPtr(v) - offset;
            const self = @as(*Self, @ptrFromInt(addr));
            self.on_stop_called.* = true;
        }
    };

    var test_valve = TestValve{
        .valve = valve_mod.Valve{
            .metadata = valve_mod.ValveMetadata{
                .name = "lifecycle_test",
                .version = "1.0.0",
                .description = "Test",
                .author = "Test",
                .required_capabilities = &[_]valve_mod.ValveCapability{},
            },
            .init = &TestValve.initFn,
            .deinit = &TestValve.deinitFn,
            .onAppStart = &TestValve.onStartFn,
            .onAppStop = &TestValve.onStopFn,
        },
        .on_start_called = &on_start_called,
        .on_stop_called = &on_stop_called,
    };

    try app.registerValve(&test_valve.valve);

    // Simulate app start
    try app.start();
    try std.testing.expect(on_start_called);

    // Simulate app stop
    try app.stop();
    try std.testing.expect(on_stop_called);
}

// Static file registry for runtime dispatch
var static_file_registry: [4]?fileserver.FileServer = [_]?fileserver.FileServer{null} ** 4;
var static_file_registry_count: usize = 0;
var static_mount_paths: [4][]const u8 = [1][]const u8{""} ** 4;

// Create a static file wrapper function that captures mount path and route path at comptime
fn createStaticFileWrapperForPath(comptime mount_path: []const u8, comptime route_path: []const u8) fn (*ziggurat.request.Request) ziggurat.response.Response {
    // Return a function that uses the captured values at comptime
    return struct {
        const mount = mount_path;
        const route = route_path;

        fn wrapper(request: *ziggurat.request.Request) ziggurat.response.Response {
            _ = request;

            // Find the FileServer in the registry by matching mount_path
            // This is runtime, but the wrapper function itself is comptime
            var i: usize = 0;
            while (i < static_file_registry_count) {
                if (static_file_registry[i]) |*fs| {
                    if (std.mem.eql(u8, static_mount_paths[i], mount)) {
                        // Use the route path that was registered (e.g., "/css/styles.css")
                        // This path is known at comptime when the route is registered
                        return fs.serveFile(route).toZiggurat();
                    }
                }
                i += 1;
            }
            return Response.text("Static file server not found").toZiggurat();
        }
    }.wrapper;
}

// Catch-all static file handler that matches any path and finds the right FileServer
fn staticFileHandler(request: *ziggurat.request.Request) ziggurat.response.Response {
    _ = request;
    // Try to find a matching FileServer based on registry
    // For now, try the first available one (typically root)
    var i: usize = 0;
    while (i < static_file_registry_count) {
        if (static_file_registry[i]) |*fs| {
            // Return the FileServer's serveFile result for root
            return fs.serveFile("/").toZiggurat();
        }
        i += 1;
    }
    return Response.text("Static file server not found").toZiggurat();
}
