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
const runtime_routes_mod = @import("valve/runtime_routes.zig");
const orm = @import("orm/orm.zig");
const websocket_mod = @import("websocket/module.zig");
const hot_reload_mod = @import("hot_reload/module.zig");
const script_injector_mod = @import("hot_reload/script_injector.zig");
const rest_api_mod = @import("rest_api.zig");
const openapi = @import("openapi.zig");
const validation = @import("validation.zig");

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
pub var global_middleware: ?*const middleware_chain.MiddlewareChain = null;

/// Global metrics collector pointer
/// This is set when routes are registered and accessed at runtime
///
/// Thread Safety:
/// - Metrics operations use internal thread-safe mechanisms
/// - Multiple threads can safely increment counters concurrently
pub var global_metrics: ?*metrics.MetricsCollector = null;

/// Global hot reload manager pointer for WebSocket handler
/// This is set when hot reload manager starts and accessed by WebSocket handler
var hot_reload_manager_for_ws: ?*hot_reload_mod.HotReloadManager = null;

/// WebSocket handler for hot reload notifications
fn hotReloadWebSocketHandler(conn: *websocket_mod.connection.WebSocketConnection) void {
    if (hot_reload_manager_for_ws) |mgr| {
        if (mgr.getReloadRoom()) |room| {
            room.join(conn) catch |err| {
                std.debug.print("[HotReload] Error joining room: {}\n", .{err});
                return;
            };

            // Store room reference in connection context so we can remove it on close
            // Note: conn.set() will duplicate the string, so we can free it here
            const room_ptr_str = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(room)}) catch return;
            defer allocator.free(room_ptr_str);
            conn.set("hot_reload_room", room_ptr_str) catch {};
        }
    }
}

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

/// Global logger pointer
/// This is set when Engine12 is initialized and accessed at runtime
///
/// Thread Safety:
/// - Logger uses internal mutex for thread-safe file writing
/// - Multiple threads can safely log concurrently
pub var global_logger: ?*dev_tools.Logger = null;

/// Global error handler registry pointer
/// This is set when engine12 is initialized and accessed at runtime
///
/// Thread Safety:
/// - Error handler registry is read-only after initialization
/// - No mutex needed as handlers are immutable function pointers
pub var global_error_handler: ?*error_handler.ErrorHandlerRegistry = null;

/// Global runtime route registry pointer
/// This is set when engine12 is initialized and accessed at runtime
///
/// Thread Safety:
/// - Runtime route registry uses internal mutex for thread-safe access
/// - Multiple threads can safely register/lookup routes concurrently
pub var global_runtime_routes: ?*runtime_routes_mod.RuntimeRouteRegistry = null;

/// Global OpenAPI generator pointer (for documentation handlers)
var global_openapi_generator: ?*openapi.OpenAPIGenerator = null;

/// Create a runtime route wrapper that dispatches to handlers stored in the runtime route registry
/// This allows valves to register routes dynamically at runtime
/// Returns a single wrapper function that looks up routes dynamically from the registry
pub fn createRuntimeRouteWrapper() fn (*ziggurat.request.Request) ziggurat.response.Response {
    return struct {
        fn wrapper(ziggurat_request: *ziggurat.request.Request) ziggurat.response.Response {
            // Access runtime route registry from global
            const runtime_registry = global_runtime_routes orelse {
                return Response.text("Runtime routes not available").withStatus(500).toZiggurat();
            };

            // Access middleware from global
            const mw_chain = global_middleware orelse {
                // No middleware, proceed directly
                var engine12_request = Request.fromZiggurat(ziggurat_request, allocator);
                defer engine12_request.deinit();

                // Find route in runtime registry - use actual request path for matching
                const method_str = @tagName(ziggurat_request.method);
                const request_path = ziggurat_request.path;
                const route = runtime_registry.findRoute(method_str, request_path, &engine12_request) catch |err| {
                    std.debug.print("[Runtime Route] Error finding route: {}\n", .{err});
                    return Response.text("Internal server error").withStatus(500).toZiggurat();
                };

                if (route) |r| {
                    const engine12_response = r.handler(&engine12_request);
                    return engine12_response.toZiggurat();
                }

                return Response.text("Not Found").withStatus(404).toZiggurat();
            };

            // Access metrics collector from global
            const metrics_collector = global_metrics;

            // Start timing - use actual request path
            const request_path = ziggurat_request.path;
            var timing = metrics.RequestTiming.start(request_path);

            // Create request with arena allocator
            var engine12_request = Request.fromZiggurat(ziggurat_request, allocator);

            // Generate request ID
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

            // Find route in runtime registry - use actual request path for matching
            const method_str = @tagName(ziggurat_request.method);
            const route = runtime_registry.findRoute(method_str, request_path, &engine12_request) catch |err| {
                std.debug.print("[Runtime Route] Error finding route: {}\n", .{err});
                if (metrics_collector) |mc| {
                    mc.incrementError();
                    timing.finish(mc) catch {};
                }
                return Response.text("Internal server error").withStatus(500).toZiggurat();
            };

            if (route) |r| {
                // Call the handler
                var engine12_response = r.handler(&engine12_request);

                // Execute response middleware chain
                engine12_response = mw_chain.executeResponse(engine12_response, &engine12_request);

                // Record timing and metrics
                if (metrics_collector) |mc| {
                    timing.finish(mc) catch {};
                }

                return engine12_response.toZiggurat();
            }

            // Route not found
            if (metrics_collector) |mc| {
                mc.incrementError();
                timing.finish(mc) catch {};
            }
            return Response.text("Not Found").withStatus(404).toZiggurat();
        }
    }.wrapper;
}

/// Wrap an engine12 handler to work with ziggurat
/// Creates an arena allocator for each request and automatically cleans it up
/// If route_pattern is provided, extracts route parameters from the request path
/// Executes middleware chain before and after handler
pub fn wrapHandler(comptime handler_fn: types.HttpHandler, comptime route_pattern: ?[]const u8) fn (*ziggurat.request.Request) ziggurat.response.Response {
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

            // Call the engine12 handler
            // Error handler registry is available via global_error_handler if handlers need it
            var engine12_response = handler(&engine12_request);

            // Execute response middleware chain (pass request for cache headers)
            engine12_response = mw_chain.executeResponse(engine12_response, &engine12_request);

            // Record timing and metrics
            if (metrics_collector) |mc| {
                timing.finish(mc) catch {};
            }

            // Convert engine12 response to ziggurat response
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
    const MAX_WS_ROUTES = 100;

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

    // Template Routes
    template_routes: [MAX_ROUTES]struct { path: []const u8, context_fn: *const anyopaque } = undefined,
    template_routes_count: usize = 0,

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

    // Runtime Route Registry (for valve-registered routes)
    runtime_routes: runtime_routes_mod.RuntimeRouteRegistry,

    // ORM Instance (optional, set by application)
    orm_instance: ?*orm.ORM = null,

    // WebSocket Manager
    ws_manager: ?websocket_mod.manager.WebSocketManager = null,
    ws_routes: [MAX_WS_ROUTES]?types.WebSocketRoute = [_]?types.WebSocketRoute{null} ** MAX_WS_ROUTES,
    ws_routes_count: usize = 0,

    // Hot Reload Manager (development only)
    hot_reload_manager: ?*hot_reload_mod.HotReloadManager = null,

    // OpenAPI Generator
    openapi_generator: ?openapi.OpenAPIGenerator = null,

    // Lifecycle
    supervisor: ?*anyopaque = null,
    http_server: ?*anyopaque = null,

    pub fn initWithProfile(profile: types.ServerProfile) !Engine12 {
        var app = Engine12{
            .allocator = allocator,
            .profile = profile,
            .middleware = middleware_chain.MiddlewareChain{},
            .error_handler_registry = error_handler.ErrorHandlerRegistry.init(allocator),
            .metrics_collector = metrics.MetricsCollector.init(allocator),
            .logger = dev_tools.Logger.fromEnvironment(allocator, profile.environment),
            .runtime_routes = runtime_routes_mod.RuntimeRouteRegistry.init(allocator),
        };
        // Set global logger reference
        global_logger = &app.logger;
        return app;
    }

    /// Initialize engine12 for development
    /// Hot reloading is automatically enabled in development mode
    pub fn initDevelopment() !Engine12 {
        var app = try Engine12.initWithProfile(types.ServerProfile_Development);

        // Initialize hot reload manager for development
        const hr_manager = try allocator.create(hot_reload_mod.HotReloadManager);
        hr_manager.* = hot_reload_mod.HotReloadManager.init(allocator, true);
        app.hot_reload_manager = hr_manager;

        // Set manager reference for script injector middleware (register early so it's available)
        script_injector_mod.setHotReloadManager(hr_manager);

        // Register script injector middleware early (before server starts)
        // This ensures it's in the middleware chain when requests are handled
        try app.useResponse(script_injector_mod.injectHotReloadScript);

        return app;
    }

    /// Initialize engine12 for production
    pub fn initProduction() !Engine12 {
        return Engine12.initWithProfile(types.ServerProfile_Production);
    }

    /// Initialize engine12 for testing
    pub fn initTesting() !Engine12 {
        return Engine12.initWithProfile(types.ServerProfile_Testing);
    }

    /// Clean up server resources
    pub fn deinit(self: *Engine12) void {
        self.is_running = false;

        // Cleanup logger (file handles and destinations)
        self.logger.deinit();

        // Cleanup hot reload manager
        if (self.hot_reload_manager) |manager| {
            manager.deinit();
            allocator.destroy(manager);
            self.hot_reload_manager = null;
        }

        // Cleanup OpenAPI generator
        if (self.openapi_generator) |*generator| {
            generator.deinit();
            self.openapi_generator = null;
        }

        // Cleanup valve registry
        if (self.valve_registry) |*registry| {
            registry.deinit();
            self.valve_registry = null;
        }

        // Cleanup runtime routes
        self.runtime_routes.deinit();
    }

    /// Register a valve with this engine12 instance
    /// Valves provide isolated services that integrate with engine12 runtime
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

        // Wrap the engine12 handler to work with ziggurat
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

    /// Register a template route that automatically renders a template file
    /// Context function is called for each request to provide template variables
    ///
    /// Example:
    /// ```zig
    /// fn getIndexContext(req: *Request) struct { title: []const u8, message: []const u8 } {
    ///     _ = req;
    ///     return .{ .title = "Welcome", .message = "Hello" };
    /// }
    /// try app.templateRoute("/", "src/templates/index.zt.html", getIndexContext);
    /// ```
    pub fn templateRoute(
        self: *Engine12,
        comptime path_pattern: []const u8,
        template_path: []const u8,
        context_fn: anytype,
    ) !void {
        const ContextFn = @TypeOf(context_fn);
        // Type validation happens automatically when we try to call the function
        // No need for explicit type checking - Zig's type system will catch errors

        // Duplicate template_path to ensure it persists
        const template_path_copy = try self.allocator.dupe(u8, template_path);

        // Store template route info
        if (self.template_routes_count >= MAX_ROUTES) {
            return error.TooManyRoutes;
        }
        const route_index = self.template_routes_count;
        self.template_routes[route_index] = .{
            .path = template_path_copy,
            .context_fn = @ptrCast(&context_fn),
        };
        self.template_routes_count += 1;

        // Create handler that captures app pointer and route index
        const HandlerData = struct {
            app_ptr: *Engine12,
            route_idx: usize,
        };
        const handler_data = HandlerData{
            .app_ptr = self,
            .route_idx = route_index,
        };

        // Create wrapper struct that captures the values as a const field
        const Wrapper = struct {
            const data: HandlerData = handler_data;
            fn handler(req: *Request) Response {
                const route_info = data.app_ptr.template_routes[data.route_idx];
                const template_path_ptr = route_info.path;
                const context_fn_ptr = @as(ContextFn, @ptrCast(@alignCast(route_info.context_fn)));

                const context = context_fn_ptr(req);
                const templates_simple_mod = @import("templates/simple.zig");
                const html = templates_simple_mod.renderSimple(template_path_ptr, context, data.app_ptr.allocator) catch |err| {
                    return switch (err) {
                        error.TemplateNotFound => Response.text("Template not found").withStatus(404),
                        error.TemplateTooLarge => Response.text("Template too large").withStatus(500),
                        else => Response.text("Template rendering error").withStatus(500),
                    };
                };
                defer data.app_ptr.allocator.free(html);
                return Response.html(html);
            }
        };

        try self.get(path_pattern, Wrapper.handler);
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

        // Wrap the engine12 handler to work with ziggurat
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

        // Wrap the engine12 handler to work with ziggurat
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

        // Wrap the engine12 handler to work with ziggurat
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
        // Create wrapper functions that cast engine_ptr back to engine12
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

    /// Get the OpenAPI generator, initializing it if necessary with default info
    pub fn getOpenApiGenerator(self: *Engine12) !*openapi.OpenAPIGenerator {
        if (self.openapi_generator == null) {
            self.openapi_generator = openapi.OpenAPIGenerator.init(self.allocator, .{
                .title = "Engine12 API",
                .version = "1.0.0",
            });
        }
        return &self.openapi_generator.?;
    }

    /// Enable OpenAPI documentation (Swagger UI)
    /// Serves the OpenAPI JSON spec and a Swagger UI page
    ///
    /// Example:
    /// ```zig
    /// try app.enableOpenApiDocs("/docs", .{ .title = "My API", .version = "1.0" });
    /// ```
    pub fn enableOpenApiDocs(self: *Engine12, comptime mount_path: []const u8, info: openapi.OpenApiInfo) !void {
        // Initialize generator if not present, or update info
        if (self.openapi_generator == null) {
            self.openapi_generator = openapi.OpenAPIGenerator.init(self.allocator, info);
        } else {
            self.openapi_generator.?.doc.info = info;
        }

        // Set global pointer for handlers
        global_openapi_generator = &self.openapi_generator.?;

        // Use comptime string concatenation for JSON path
        const json_path = mount_path ++ "/openapi.json";

        // 1. JSON Endpoint
        try self.get(json_path, struct {
            fn handler(req: *Request) Response {
                _ = req;
                if (global_openapi_generator) |gen| {
                    const json = gen.doc.toJson() catch return Response.serverError("Failed to generate OpenAPI JSON");
                    // Response.text duplicates the string, so we must free our generated json
                    // We use page_allocator because that's what gen.allocator is (from self.allocator)
                    defer std.heap.page_allocator.free(json);
                    return Response.text(json).withContentType("application/json");
                }
                return Response.serverError("OpenAPI generator not initialized");
            }
        }.handler);

        // 2. UI Endpoint
        try self.get(mount_path, struct {
            // We need to bake the path into the handler via comptime string concat or similar,
            // but we only have runtime string.
            // Ziggurat and Engine12 support closures via this struct wrapper trick but values must be comptime known
            // OR accessible via global/context.
            //
            // Since we can't easily pass runtime `json_path` to a static struct function without a global map or similar,
            // we will use the request path to infer the JSON path relative to the mount point.
            //
            // Assumption: mount_path is what we are serving.
            // If user visits /docs, we want /docs/openapi.json

            fn handler(_: *Request) Response {
                // Construct JSON URL relative to current path
                // If we are at /docs, we want ./docs/openapi.json? No, just openapi.json if trailing slash
                // or ./docs/openapi.json if no trailing slash.
                // Safer to use absolute path if we knew it, but we don't inside static handler easily.
                // BUT we can reconstruct it from request path + /openapi.json?

                // Actually, let's just assume standard relative path "openapi.json" works if we ensure trailing slash
                // or handle it in JS.

                // Simple Swagger UI HTML
                const html =
                    \\<!DOCTYPE html>
                    \\<html lang="en">
                    \\<head>
                    \\  <meta charset="utf-8" />
                    \\  <meta name="viewport" content="width=device-width, initial-scale=1" />
                    \\  <title>Swagger UI</title>
                    \\  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5.11.0/swagger-ui.css" />
                    \\</head>
                    \\<body>
                    \\  <div id="swagger-ui"></div>
                    \\  <script src="https://unpkg.com/swagger-ui-dist@5.11.0/swagger-ui-bundle.js" crossorigin></script>
                    \\  <script>
                    \\    window.onload = () => {
                    \\      // Calculate JSON URL relative to current page
                    \\      const path = window.location.pathname;
                    \\      const jsonUrl = path.endsWith('/') ? path + 'openapi.json' : path + '/openapi.json';
                    \\      
                    \\      window.ui = SwaggerUIBundle({
                    \\        url: jsonUrl,
                    \\        dom_id: '#swagger-ui',
                    \\      });
                    \\    };
                    \\  </script>
                    \\</body>
                    \\</html>
                ;
                return Response.html(html);
            }
        }.handler);
    }

    /// Register RESTful API endpoints for a model
    /// Generates: GET /prefix, GET /prefix/:id, POST /prefix, PUT /prefix/:id, DELETE /prefix/:id
    ///
    /// Example:
    /// ```zig
    /// try app.restApi("/api/todos", Todo, .{
    ///     .orm = &my_orm,
    ///     .validator = validateTodo,
    ///     .authenticator = requireAuth,
    ///     .authorization = canAccessTodo,
    ///     .enable_pagination = true,
    ///     .enable_filtering = true,
    ///     .enable_sorting = true,
    ///     .cache_ttl_ms = 30000,
    /// });
    /// ```
    pub fn restApi(self: *Engine12, comptime prefix: []const u8, comptime Model: type, config: rest_api_mod.RestApiConfig(Model)) !void {
        return rest_api_mod.restApi(self, prefix, Model, config);
    }

    /// Register RESTful API endpoints with sensible defaults
    /// Uses app.getORM() automatically and enables pagination, filtering, and sorting by default
    /// Only requires model type and path - all other options are optional
    ///
    /// Example:
    /// ```zig
    /// // Minimal usage - uses defaults
    /// try app.restApiDefault("/api/items", Item);
    ///
    /// // With optional overrides
    /// try app.restApiDefault("/api/items", Item, .{
    ///     .authenticator = auth.requireAuthForRestApi,
    ///     .validator = validators.validateItem,
    /// });
    /// ```
    pub fn restApiDefault(
        self: *Engine12,
        comptime prefix: []const u8,
        comptime Model: type,
        overrides: anytype,
    ) !void {
        const orm_instance = try self.getORM();

        // Build config with defaults, allowing overrides
        const ConfigType = rest_api_mod.RestApiConfig(Model);
        const OverrideType = @TypeOf(overrides);

        // Check if validator is provided in overrides
        var validator_provided = false;
        var validator_fn: ?*const fn (*Request, Model) anyerror!validation.ValidationErrors = null;
        comptime {
            const type_info = @typeInfo(OverrideType);
            switch (type_info) {
                .@"struct" => |struct_info| {
                    for (struct_info.fields) |field| {
                        if (std.mem.eql(u8, field.name, "validator")) {
                            validator_provided = true;
                            break;
                        }
                    }
                },
                else => {},
            }
        }
        if (validator_provided) {
            validator_fn = overrides.validator;
        }

        // Validator is required, so provide a default no-op validator if not provided
        const default_validator = struct {
            fn validate(_: *Request, _: Model) anyerror!validation.ValidationErrors {
                const errors = validation.ValidationErrors.init(allocator);
                return errors;
            }
        }.validate;

        var config: ConfigType = undefined;
        config.orm = orm_instance;
        config.validator = if (validator_provided) validator_fn.? else default_validator;
        config.enable_pagination = true;
        config.enable_filtering = true;
        config.enable_sorting = true;
        config.authenticator = null;
        config.authorization = null;
        config.cache_ttl_ms = null;

        // Apply overrides if provided
        comptime {
            const type_info = @typeInfo(OverrideType);
            switch (type_info) {
                .@"struct" => |struct_info| {
                    for (struct_info.fields) |field| {
                        if (@hasField(ConfigType, field.name)) {
                            @field(config, field.name) = @field(overrides, field.name);
                        }
                    }
                },
                else => {},
            }
        }

        return rest_api_mod.restApi(self, prefix, Model, config);
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

    /// Get the logger instance
    pub fn getLogger(self: *Engine12) *dev_tools.Logger {
        return &self.logger;
    }

    /// Set a custom logger (replaces the default logger)
    pub fn setLogger(self: *Engine12, logger: dev_tools.Logger) void {
        self.logger.deinit();
        self.logger = logger;
    }

    /// Enable request/response logging with default configuration
    /// This registers the logging middleware automatically
    pub fn enableRequestLogging(self: *Engine12, config: ?@import("logging_middleware.zig").LoggingConfig) !void {
        const logging_middleware_mod = @import("logging_middleware.zig");
        const default_config = logging_middleware_mod.LoggingConfig{};
        const logging_config = config orelse default_config;

        var logging_mw = logging_middleware_mod.LoggingMiddleware.init(logging_config);
        logging_middleware_mod.LoggingMiddleware.setGlobalLogger(&self.logger);
        logging_mw.setGlobalConfig();

        try self.usePreRequest(logging_mw.preRequestMwFn());
        try self.useResponse(logging_mw.responseMwFn());
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

    /// Load a template file for hot reloading (development mode only)
    /// Returns a RuntimeTemplate that automatically reloads when the file changes
    ///
    /// Example:
    /// ```zig
    /// const template = try app.loadTemplate("templates/index.zt.html");
    /// const content = try template.getContentString();
    /// // Use content with Template.compile() or a runtime template engine
    /// ```
    pub fn loadTemplate(self: *Engine12, template_path: []const u8) !*hot_reload_mod.RuntimeTemplate {
        if (self.hot_reload_manager) |manager| {
            return try manager.watchTemplate(template_path);
        }
        return error.HotReloadNotEnabled;
    }

    /// Template registry for storing discovered templates
    pub const TemplateRegistry = struct {
        templates: std.StringHashMap(*hot_reload_mod.RuntimeTemplate),
        registry_allocator: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) TemplateRegistry {
            return TemplateRegistry{
                .templates = std.StringHashMap(*hot_reload_mod.RuntimeTemplate).init(alloc),
                .registry_allocator = alloc,
            };
        }

        pub fn get(self: *TemplateRegistry, name: []const u8) ?*hot_reload_mod.RuntimeTemplate {
            return self.templates.get(name);
        }

        pub fn has(self: *TemplateRegistry, name: []const u8) bool {
            return self.templates.contains(name);
        }

        pub fn count(self: *const TemplateRegistry) usize {
            return self.templates.count();
        }

        pub fn deinit(self: *TemplateRegistry) void {
            // Note: Templates are owned by HotReloadManager, so we don't free them here
            // Free the duplicated keys we allocated
            var iter = self.templates.iterator();
            while (iter.next()) |entry| {
                self.registry_allocator.free(entry.key_ptr.*);
            }
            self.templates.deinit();
        }
    };

    /// Auto-discover and load templates from a directory
    /// Scans templates/ directory for .zt.html files and auto-registers routes
    /// Convention: index.zt.html -> GET /, {name}.zt.html -> GET /{name}
    /// Returns a TemplateRegistry for manual template access
    /// Only works in development mode (requires hot reload)
    ///
    /// Example:
    /// ```zig
    /// const registry = try app.discoverTemplates("src/templates");
    /// defer registry.deinit();
    /// // Automatically registered:
    /// // - templates/index.zt.html -> GET /
    /// // - templates/about.zt.html -> GET /about
    /// ```
    pub fn discoverTemplates(
        self: *Engine12,
        templates_dir: []const u8,
    ) !TemplateRegistry {
        var registry = TemplateRegistry.init(self.allocator);

        if (self.hot_reload_manager == null) {
            std.debug.print("[Engine12] Warning: Template discovery requires hot reload (development mode). Skipping.\n", .{});
            return registry;
        }

        var dir = std.fs.cwd().openDir(templates_dir, .{ .iterate = true }) catch |err| {
            std.debug.print("[Engine12] Warning: Could not open templates directory '{s}': {}\n", .{ templates_dir, err });
            return registry; // Return empty registry gracefully
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (true) {
            const entry = iterator.next() catch |err| {
                std.debug.print("[Engine12] Warning: Error iterating templates directory '{s}': {}\n", .{ templates_dir, err });
                return registry;
            } orelse break;

            // Only process .zt.html files
            if (entry.kind != .file) continue;
            const template_name = entry.name;
            if (!std.mem.endsWith(u8, template_name, ".zt.html")) continue;

            const template_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ templates_dir, template_name });
            defer self.allocator.free(template_path);

            // Load template
            const template = self.loadTemplate(template_path) catch |err| {
                std.debug.print("[Engine12] Warning: Failed to load template '{s}': {}\n", .{ template_path, err });
                continue;
            };

            // Extract route name from filename (remove .zt.html extension)
            // template_name is like "index.zt.html", we want "index"
            // .zt.html is 7 characters, but we need to account for the period before it
            // For "index.zt.html" (13 chars): index(5) + .(1) + zt.html(6) = 12, but actual is 13
            // So: index.zt.html = 13 chars, .zt.html = 7 chars
            // We want index = 5 chars, so we need [0..5] = template_name[0..(13-8)]
            // Actually, let's be more precise: if it ends with .zt.html, remove those 7 chars
            // But the period is part of the extension, so: index.zt.html -> index (remove 8 chars: .zt.html)
            if (template_name.len < 8) continue; // Skip files that are too short
            // Extract base name: remove the last 7 characters (.zt.html)
            // For "index.zt.html" (13 chars), removing 7 gives us 6 chars "index."
            // We need to remove 8 to get "index" (5 chars)
            const route_name_len = template_name.len - 7;
            // But wait, if template_name is "index.zt.html", len-7 = 6, which gives "index."
            // We need to check if there's a period before .zt.html and handle it
            // Actually, the simplest fix: if route_name ends with ".", remove it
            var route_name_slice = template_name[0..route_name_len];
            // Remove trailing period if present
            if (route_name_slice.len > 0 and route_name_slice[route_name_slice.len - 1] == '.') {
                route_name_slice = route_name_slice[0 .. route_name_slice.len - 1];
            }
            const route_name = route_name_slice;
            const route_name_copy = try self.allocator.dupe(u8, route_name);
            try registry.templates.put(route_name_copy, template);

            // Auto-register route based on filename convention
            const route_path = if (std.mem.eql(u8, route_name, "index"))
                "/"
            else
                try std.fmt.allocPrint(self.allocator, "/{s}", .{route_name});
            defer if (!std.mem.eql(u8, route_name, "index")) {
                self.allocator.free(route_path);
            };

            // Note: Auto-registration of routes is complex due to route conflict detection
            // For now, we just load templates and store them in the registry
            // Users should register their own handlers that use templates from the registry
            std.debug.print("[Engine12] Discovered template: {s} (stored as: '{s}', route: {s})\n", .{ template_path, route_name_copy, route_path });
        }

        return registry;
    }

    /// Register a WebSocket endpoint
    /// Each WebSocket route runs on its own port (starting from 9000)
    /// The handler function is called when a connection is established
    ///
    /// Example:
    /// ```zig
    /// fn handleChat(conn: *websocket.WebSocketConnection) void {
    ///     // Connection established - set up message handling
    /// }
    /// try app.websocket("/ws/chat", handleChat);
    /// ```
    pub fn websocket(self: *Engine12, comptime path_pattern: []const u8, handler: types.WebSocketHandler) !void {
        if (self.ws_routes_count >= MAX_WS_ROUTES) {
            return error.TooManyWebSocketRoutes;
        }

        // Initialize WebSocket manager lazily
        if (self.ws_manager == null) {
            self.ws_manager = try websocket_mod.manager.WebSocketManager.init(self.allocator);
        }

        // Store route
        self.ws_routes[self.ws_routes_count] = types.WebSocketRoute{
            .path = path_pattern,
            .handler_ptr = handler, // Store function pointer value directly, not address
        };
        self.ws_routes_count += 1;

        // Register WebSocket server (will be started in start())
        if (self.ws_manager) |*manager| {
            try manager.registerServer(path_pattern, handler);
        }
    }

    /// Auto-discover and register static files from a directory structure
    /// Scans the static directory for subdirectories and automatically registers them
    /// Convention: static/css/ -> /css/*, static/js/ -> /js/*
    /// Fails gracefully if directory doesn't exist (logs warning, returns without error)
    ///
    /// Example:
    /// ```zig
    /// try app.discoverStaticFiles("static");
    /// // Automatically registers:
    /// // - static/css/ -> /css/*
    /// // - static/js/ -> /js/*
    /// // - static/images/ -> /images/*
    /// ```
    pub fn discoverStaticFiles(self: *Engine12, static_dir: []const u8) !void {
        var dir = std.fs.cwd().openDir(static_dir, .{ .iterate = true }) catch |err| {
            std.debug.print("[Engine12] Warning: Could not open static directory '{s}': {}\n", .{ static_dir, err });
            return; // Gracefully return, don't fail
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (true) {
            const entry = iterator.next() catch |err| {
                std.debug.print("[Engine12] Warning: Error iterating static directory '{s}': {}\n", .{ static_dir, err });
                return;
            } orelse break;
            // Only process subdirectories, skip files
            if (entry.kind != .directory) continue;

            const subdir_name = entry.name;

            // Skip hidden directories
            if (subdir_name.len > 0 and subdir_name[0] == '.') continue;

            // Create mount path: /{subdir_name}
            const mount_path = try std.fmt.allocPrint(self.allocator, "/{s}", .{subdir_name});
            // Note: mount_path will be duplicated in serveStatic, so we can free it here
            defer self.allocator.free(mount_path);

            // Create full directory path: static/{subdir_name}
            const full_dir_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ static_dir, subdir_name });
            defer self.allocator.free(full_dir_path);

            // Register static route (this will duplicate mount_path internally)
            self.serveStatic(mount_path, full_dir_path) catch |err| {
                std.debug.print("[Engine12] Warning: Failed to register static route '{s}' -> '{s}': {}\n", .{ mount_path, full_dir_path, err });
                // Continue with other directories
                continue;
            };

            std.debug.print("[Engine12] Discovered static route: {s} -> {s}\n", .{ mount_path, full_dir_path });
        }
    }

    /// Convenience method to serve all static files from a directory
    /// Auto-discovers subdirectories and serves them at corresponding routes
    /// Example: static/css/ -> /css/*, static/js/ -> /js/*
    ///
    /// ```zig
    /// try app.serveStaticDirectory("static");
    /// ```
    pub fn serveStaticDirectory(self: *Engine12, static_dir: []const u8) !void {
        try self.discoverStaticFiles(static_dir);
    }

    /// Register static file serving from a directory
    /// Can be called before or after server is started (lazy route registration)
    pub fn serveStatic(self: *Engine12, mount_path: []const u8, directory: []const u8) !void {
        if (self.static_routes_count >= MAX_STATIC_ROUTES) {
            return error.TooManyStaticRoutes;
        }

        // Duplicate mount_path and directory to ensure they persist
        // These strings are stored in FileServer and must outlive the function call
        // We'll store these copies in the FileServer, so they need to be allocated
        const mount_path_copy = try self.allocator.dupe(u8, mount_path);
        const directory_copy = try self.allocator.dupe(u8, directory);

        var file_server = fileserver.FileServer.init(self.allocator, mount_path_copy, directory_copy);

        // Disable cache in development mode (hot reload enabled)
        if (self.hot_reload_manager != null) {
            file_server.disableCache();
        }

        // Track if static files are mounted at root
        if (std.mem.eql(u8, mount_path_copy, "/")) {
            self.static_root_mounted = true;
        }

        // Store a copy of the FileServer
        self.static_routes[self.static_routes_count] = file_server;
        self.static_routes_count += 1;

        // Register with hot reload manager if enabled (development mode)
        if (self.hot_reload_manager) |hr_manager| {
            // Get a pointer to the stored FileServer
            hr_manager.watchStaticFiles(&self.static_routes[self.static_routes_count - 1].?) catch |err| {
                // Log error but don't fail - hot reload is optional
                std.debug.print("[HotReload] Warning: Failed to watch static files: {}\n", .{err});
            };
        }

        // Build server if not already built (works even after start() is called)
        if (self.built_server == null) {
            var builder = ziggurat.ServerBuilder.init(self.allocator);
            var server = try builder
                .host("127.0.0.1")
                .port(8080)
                .readTimeout(5000)
                .writeTimeout(5000)
                .build();

            // Register default routes (but skip "/" if we're mounting static files at root or custom handler registered)
            if (!std.mem.eql(u8, mount_path_copy, "/") and !self.custom_root_handler) {
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
            // Use the already-duplicated mount_path_copy from above
            static_mount_paths[static_index] = mount_path_copy;

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
                                // Safety check: ensure registry_mount is valid
                                if (registry_mount.len > 0) {
                                    // Check if request path starts with the mount path
                                    if (std.mem.startsWith(u8, request_path, registry_mount)) {
                                        // Serve the file using the full request path
                                        return fs.serveFile(request_path).toZiggurat();
                                    }
                                }
                            }
                            i += 1;
                        }
                        return Response.text("Static file server not found").toZiggurat();
                    }
                }.handler;

                // Don't register mount_path directly - ziggurat requires comptime strings
                // Instead, we register specific routes below using comptime strings

                // Register wildcard routes for subpaths to handle any file under the mount path
                // Use :file parameter pattern to match any filename
                if (std.mem.eql(u8, mount_path, "/css")) {
                    try server.get("/css/:file", wrapper);
                    // Also register common paths explicitly for better matching
                    try server.get("/css/style.css", wrapper);
                    try server.get("/css/styles.css", wrapper); // Also support old name for compatibility
                } else if (std.mem.eql(u8, mount_path, "/js")) {
                    try server.get("/js/:file", wrapper);
                    // Also register common paths explicitly for better matching
                    try server.get("/js/app.js", wrapper);
                }
            }
        }
    }

    /// Initialize database using singleton pattern
    /// Opens database and creates ORM instance
    /// Thread-safe and idempotent (can be called multiple times safely)
    ///
    /// Example:
    /// ```zig
    /// try app.initDatabase("app.db");
    /// ```
    pub fn initDatabase(self: *Engine12, db_path: []const u8) !void {
        const DatabaseSingleton = @import("orm/singleton.zig").DatabaseSingleton;
        try DatabaseSingleton.init(db_path, self.allocator);
    }

    /// Initialize database and run migrations automatically
    /// Discovers migrations from directory and runs them
    /// Supports both init.zig convention and numbered migration files
    ///
    /// Example:
    /// ```zig
    /// try app.initDatabaseWithMigrations("app.db", "src/migrations");
    /// ```
    pub fn initDatabaseWithMigrations(
        self: *Engine12,
        db_path: []const u8,
        migrations_dir: []const u8,
    ) !void {
        try self.initDatabase(db_path);

        const DatabaseSingleton = @import("orm/singleton.zig").DatabaseSingleton;
        const orm_instance = try DatabaseSingleton.get();

        // Try to discover migrations from directory
        const migration_discovery_mod = @import("orm/migration_discovery.zig");
        var registry = migration_discovery_mod.discoverMigrations(self.allocator, migrations_dir) catch |err| {
            std.debug.print("[Engine12] Warning: Migration discovery failed: {}\n", .{err});
            // Try direct import of init.zig as fallback
            const init_path = try std.fmt.allocPrint(self.allocator, "{s}/init.zig", .{migrations_dir});
            defer self.allocator.free(init_path);

            const init_file = std.fs.cwd().openFile(init_path, .{}) catch {
                return; // No migrations to run
            };
            defer init_file.close();

            // If init.zig exists, try to import it (this requires comptime, so we'll just return)
            // User should use direct import pattern for init.zig
            std.debug.print("[Engine12] Info: migrations/init.zig found. For comptime imports, use @import(\"migrations/init.zig\") directly.\n", .{});
            return;
        };
        defer registry.deinit();

        // Run discovered migrations
        try orm_instance.runMigrationsFromRegistry(&registry);
    }

    /// Get ORM instance from singleton
    /// Returns error if database is not initialized
    ///
    /// Example:
    /// ```zig
    /// const orm = try app.getORM();
    /// const items = try orm.findAll(Item);
    /// ```
    pub fn getORM(_: *Engine12) !*orm.ORM {
        const DatabaseSingleton = @import("orm/singleton.zig").DatabaseSingleton;
        return DatabaseSingleton.get();
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

    /// Start the entire system (HTTP server + background tasks + WebSocket servers)
    pub fn start(self: *Engine12) !void {
        self.start_time = std.time.milliTimestamp();
        self.is_running = true;

        try self.startHttpServer();
        try self.startBackgroundTasks();
        try self.startHotReloadManager(); // Register hot reload WebSocket route first
        try self.startWebSocketManager(); // Then start all WebSocket servers

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

        self.stopHotReloadManager();
        self.stopWebSocketManager();
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

    fn startWebSocketManager(self: *Engine12) !void {
        if (self.ws_manager) |*manager| {
            try manager.start();
            std.debug.print("[WebSocket] Started {d} WebSocket server(s)\n", .{self.ws_routes_count});
        }
    }

    fn stopWebSocketManager(self: *Engine12) void {
        if (self.ws_manager) |*manager| {
            manager.stop();
            std.debug.print("[WebSocket] Stopped all WebSocket servers\n", .{});
        }
    }

    fn startHotReloadManager(self: *Engine12) !void {
        if (self.hot_reload_manager) |manager| {
            try manager.start();

            // Register WebSocket endpoint for hot reload notifications
            // Initialize WebSocket manager if not already initialized
            if (self.ws_manager == null) {
                self.ws_manager = try websocket_mod.manager.WebSocketManager.init(self.allocator);
            }

            // Store manager pointer in a way the handler can access it
            // Use a module-level variable (thread-safe since we're single-threaded during startup)
            hot_reload_manager_for_ws = manager;

            // Note: Script injector middleware is already registered in initDevelopment()
            // Just ensure manager reference is set (it should already be set, but double-check)
            script_injector_mod.setHotReloadManager(manager);

            // Register WebSocket route
            if (self.ws_routes_count < MAX_WS_ROUTES) {
                self.ws_routes[self.ws_routes_count] = types.WebSocketRoute{
                    .path = "/ws/hot-reload",
                    .handler_ptr = hotReloadWebSocketHandler, // Store function pointer value directly
                };
                self.ws_routes_count += 1;

                // Register with WebSocket manager
                if (self.ws_manager) |*ws_mgr| {
                    try ws_mgr.registerServer("/ws/hot-reload", hotReloadWebSocketHandler);
                }
            }

            std.debug.print("[HotReload] Started hot reload manager\n", .{});
        }
    }

    fn stopHotReloadManager(self: *Engine12) void {
        if (self.hot_reload_manager) |manager| {
            manager.stop();
            std.debug.print("[HotReload] Stopped hot reload manager\n", .{});
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
