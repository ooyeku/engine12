const std = @import("std");
const c = @cImport({
    @cInclude("stdint.h");
    @cInclude("stdbool.h");
    @cInclude("string.h");
});
const Engine12 = @import("engine12").Engine12;
const Request = @import("engine12").Request;
const Response = @import("engine12").Response;
const types = @import("engine12").types;
const router = @import("engine12").router;
const middleware = @import("engine12").middleware;
const ziggurat = @import("ziggurat");
const cache = @import("engine12").cache;
const metrics = @import("engine12").metrics;
const rate_limit = @import("engine12").rate_limit;
const csrf = @import("engine12").csrf;
const cors_middleware = @import("engine12").cors_middleware;
const body_size_limit = @import("engine12").body_size_limit;
const json_module = @import("engine12").json;
const validation = @import("engine12").validation;
const valve_mod = @import("engine12").valve;
const valve_context = @import("engine12").ValveContext;
const valve_registry_type = @import("engine12").ValveRegistry;
const RegistryError = @import("engine12").RegistryError;
const error_handler = @import("engine12").error_handler;

const allocator = std.heap.page_allocator;

// C API types matching engine12.h
pub const E12ValveCapability = enum(c_int) {
    routes = 0,
    middleware = 1,
    background_tasks = 2,
    health_checks = 3,
    static_files = 4,
    websockets = 5,
    database_access = 6,
    cache_access = 7,
    metrics_access = 8,
};

pub const E12ValveMetadata = extern struct {
    name: [*c]const u8,
    version: [*c]const u8,
    description: [*c]const u8, // NULL if not provided
    capabilities: [*c]const E12ValveCapability,
    capabilities_count: c_uint,
};

pub const E12ValveInitFn = *const fn (*CValveContext, *anyopaque) c_int;
pub const E12ValveDeinitFn = *const fn (*anyopaque) void;
pub const E12ValveOnAppStartFn = ?*const fn (*CValveContext, *anyopaque) c_int;
pub const E12ValveOnAppStopFn = ?*const fn (*CValveContext, *anyopaque) void;

// Function pointers in extern structs - store as *anyopaque and cast when needed
pub const E12Valve = extern struct {
    metadata: E12ValveMetadata,
    init: *anyopaque, // E12ValveInitFn cast to *anyopaque
    deinit: *anyopaque, // E12ValveDeinitFn cast to *anyopaque
    onAppStart: ?*anyopaque, // E12ValveOnAppStartFn cast to *anyopaque, NULL if not provided
    onAppStop: ?*anyopaque, // E12ValveOnAppStopFn cast to *anyopaque, NULL if not provided
    user_data: *anyopaque,
};

// Error handling
var last_error_buf: [256]u8 = undefined;
var last_error: ?[]const u8 = null;

fn setLastError(err: []const u8) void {
    const copy_len = @min(err.len, last_error_buf.len - 1);
    @memcpy(last_error_buf[0..copy_len], err[0..copy_len]);
    last_error_buf[copy_len] = 0;
    last_error = last_error_buf[0..copy_len];
}

fn clearLastError() void {
    last_error = null;
}

// Handler registry for C API function pointers
// Since we can't pass function pointers directly in exported C functions,
// we store them and pass an ID
var handler_registry: std.AutoHashMap(usize, *const fn (*CRequest, *anyopaque) *CResponse) = undefined;
var handler_registry_init = false;
var handler_registry_mutex: std.Thread.Mutex = std.Thread.Mutex{};
var handler_counter: usize = 0;

// Route handler data registry for C API valve routes
// Stores handler_id and user_data for wrapper functions
// Keyed by method+path for lookup
const RouteHandlerData = struct {
    handler_id: usize,
    user_data: *anyopaque,
};
var route_handler_data_registry: std.StringHashMap(RouteHandlerData) = undefined;
var route_handler_data_init = false;
var route_handler_data_mutex: std.Thread.Mutex = std.Thread.Mutex{};

fn initHandlerRegistry() void {
    if (!handler_registry_init) {
        handler_registry = std.AutoHashMap(usize, *const fn (*CRequest, *anyopaque) *CResponse).init(allocator);
        handler_registry_init = true;
    }
}

fn initRouteHandlerDataRegistry() void {
    if (!route_handler_data_init) {
        route_handler_data_registry = std.StringHashMap(RouteHandlerData).init(allocator);
        route_handler_data_init = true;
    }
}

fn registerRouteHandlerData(method: []const u8, path: []const u8, handler_id: usize, user_data: *anyopaque) !void {
    initRouteHandlerDataRegistry();
    route_handler_data_mutex.lock();
    defer route_handler_data_mutex.unlock();
    const key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ method, path });
    route_handler_data_registry.put(key, RouteHandlerData{
        .handler_id = handler_id,
        .user_data = user_data,
    }) catch {};
}

fn getRouteHandlerData(method: []const u8, path: []const u8) ?RouteHandlerData {
    initRouteHandlerDataRegistry();
    route_handler_data_mutex.lock();
    defer route_handler_data_mutex.unlock();
    const key = std.fmt.allocPrint(allocator, "{s}:{s}", .{ method, path }) catch return null;
    defer allocator.free(key);
    return route_handler_data_registry.get(key);
}

// Single wrapper handler for all C API valve routes
// Looks up handler data by method+path at runtime
fn cValveRouteWrapper(req: *Request) Response {
    const method = req.method();
    const path = req.path();

    const data = getRouteHandlerData(method, path) orelse {
        return Response.status(500);
    };

    const c_req = allocator.create(CRequest) catch {
        return Response.status(500);
    };
    c_req.* = CRequest{
        .request = req,
        .persistent_path = null,
    };

    const handler_fn = getHandler(data.handler_id) orelse {
        allocator.destroy(c_req);
        return Response.status(500);
    };

    const c_resp = handler_fn(c_req, data.user_data);
    const resp = c_resp.response;
    allocator.destroy(c_req);
    return resp;
}

fn registerHandler(handler: *const fn (*CRequest, *anyopaque) *CResponse) usize {
    initHandlerRegistry();
    handler_registry_mutex.lock();
    defer handler_registry_mutex.unlock();
    handler_counter += 1;
    handler_registry.put(handler_counter, handler) catch {};
    return handler_counter;
}

fn getHandler(id: usize) ?*const fn (*CRequest, *anyopaque) *CResponse {
    initHandlerRegistry();
    handler_registry_mutex.lock();
    defer handler_registry_mutex.unlock();
    return handler_registry.get(id);
}

// C API type definitions matching engine12.h
pub const E12MiddlewareResult = enum(c_int) {
    E12_MIDDLEWARE_PROCEED = 0,
    E12_MIDDLEWARE_ABORT = 1,
};

pub const E12HealthStatus = enum(c_int) {
    E12_HEALTH_HEALTHY = 0,
    E12_HEALTH_DEGRADED = 1,
    E12_HEALTH_UNHEALTHY = 2,
};

// C function pointer types
pub const E12PreRequestMiddlewareFn = *const fn (*CRequest, *anyopaque) E12MiddlewareResult;
pub const E12ResponseMiddlewareFn = *const fn (*CResponse, *anyopaque) *CResponse;
pub const E12BackgroundTaskFn = *const fn (*anyopaque) void;
pub const E12HealthCheckFn = *const fn (*anyopaque) E12HealthStatus;

// Route entry for runtime dispatch
const RouteEntry = struct {
    method: []const u8,
    path_pattern: []const u8,
    handler_id: usize, // ID in handler registry instead of function pointer
    user_data: *anyopaque,
    pattern: router.RoutePattern,
};

// C wrapper types - use opaque pointers for C exports
pub const CEngine12 = struct {
    engine: Engine12,
    routes: std.ArrayListUnmanaged(RouteEntry) = .{},
    catch_all_registered: bool = false,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CEngine12) void {
        for (self.routes.items) |*entry| {
            entry.pattern.deinit(self.allocator);
            self.allocator.free(entry.path_pattern);
            self.allocator.free(entry.method);
        }
        self.routes.deinit(self.allocator);
        self.engine.deinit();

        // Clean up handler registry entries for this app's handlers
        // Note: We can't easily track which handlers belong to which app,
        // so we just clear unused handlers periodically or leave them
        // (they're just function pointers, no memory leak)

        allocator.destroy(self);
    }
};

// Extern-compatible opaque handle for C API
pub const CEngine12Handle = opaque {
    // Note: Opaque types cannot have fields in Zig
    // We'll use a global hash map to store handles
};

// Global storage for C handles
var handle_storage: std.AutoHashMap(*CEngine12Handle, *CEngine12) = undefined;
var handle_storage_init = false;
var handle_storage_mutex: std.Thread.Mutex = std.Thread.Mutex{};

fn initHandleStorage() void {
    if (!handle_storage_init) {
        handle_storage = std.AutoHashMap(*CEngine12Handle, *CEngine12).init(allocator);
        handle_storage_init = true;
    }
}

fn getCEngine12(handle: *CEngine12Handle) ?*CEngine12 {
    initHandleStorage();
    handle_storage_mutex.lock();
    defer handle_storage_mutex.unlock();
    return handle_storage.get(handle);
}

fn storeCEngine12(handle: *CEngine12Handle, impl: *CEngine12) void {
    initHandleStorage();
    handle_storage_mutex.lock();
    defer handle_storage_mutex.unlock();
    handle_storage.put(handle, impl) catch {};
}

fn removeCEngine12(handle: *CEngine12Handle) void {
    initHandleStorage();
    handle_storage_mutex.lock();
    defer handle_storage_mutex.unlock();
    _ = handle_storage.remove(handle);
}

pub const CRequest = struct {
    request: *Request, // Store pointer instead of copying
    persistent_path: ?[]const u8, // Cached path in persistent memory

    pub fn deinit(self: *CRequest) void {
        // Free persistent path if it was allocated
        if (self.persistent_path) |path| {
            allocator.free(path);
        }
        // Don't deinit request - it's owned by the caller
        allocator.destroy(self);
    }
};

pub const CResponse = struct {
    response: Response,
    persistent_body: ?[]const u8,

    pub fn deinit(self: *CResponse) void {
        if (self.persistent_body) |body| {
            allocator.free(body);
        }
        allocator.destroy(self);
    }
};

// Global storage for C API responses (inline to avoid module conflicts)
// Uses request pointer as key for thread-safe access
var c_api_response_storage: std.AutoHashMap(*Request, Response) = undefined;
var c_api_response_storage_init = false;
var c_api_response_storage_mutex: std.Thread.Mutex = std.Thread.Mutex{};

fn initCAPIResponseStorage() void {
    if (!c_api_response_storage_init) {
        c_api_response_storage = std.AutoHashMap(*Request, Response).init(allocator);
        c_api_response_storage_init = true;
    }
}

fn storeCAPIResponse(req: *Request, resp: Response) !void {
    initCAPIResponseStorage();
    c_api_response_storage_mutex.lock();
    defer c_api_response_storage_mutex.unlock();

    try c_api_response_storage.put(req, resp);
}

pub fn getCAPIResponse(req: *Request) ?Response {
    initCAPIResponseStorage();
    c_api_response_storage_mutex.lock();
    defer c_api_response_storage_mutex.unlock();

    if (c_api_response_storage.fetchRemove(req)) |entry| {
        return entry.value;
    }
    return null;
}

// Global storage for C API app instances keyed by request
// This allows middleware to access the app instance without capturing
var c_api_app_registry: std.AutoHashMap(*Request, *CEngine12) = undefined;
var c_api_app_registry_init = false;
var c_api_app_registry_mutex: std.Thread.Mutex = std.Thread.Mutex{};

fn initAppRegistry() void {
    if (!c_api_app_registry_init) {
        c_api_app_registry = std.AutoHashMap(*Request, *CEngine12).init(allocator);
        c_api_app_registry_init = true;
    }
}

fn getAppForRequest(req: *Request) ?*CEngine12 {
    initAppRegistry();
    c_api_app_registry_mutex.lock();
    defer c_api_app_registry_mutex.unlock();
    return c_api_app_registry.get(req);
}

fn setAppForRequest(req: *Request, app: *CEngine12) void {
    initAppRegistry();
    c_api_app_registry_mutex.lock();
    defer c_api_app_registry_mutex.unlock();
    c_api_app_registry.put(req, app) catch {};
}

// Global error handler registry
const ErrorHandlerEntry = struct {
    handler: *const fn (c_int, *anyopaque) ?*CResponse,
    user_data: *anyopaque,
};

var error_handler_registry: std.AutoHashMap(usize, ErrorHandlerEntry) = undefined;
var error_handler_registry_init = false;
var error_handler_registry_mutex: std.Thread.Mutex = std.Thread.Mutex{};

fn initErrorHandlerRegistry() void {
    if (!error_handler_registry_init) {
        error_handler_registry = std.AutoHashMap(usize, ErrorHandlerEntry).init(allocator);
        error_handler_registry_init = true;
    }
}

fn removeAppForRequest(req: *Request) void {
    initAppRegistry();
    c_api_app_registry_mutex.lock();
    defer c_api_app_registry_mutex.unlock();
    _ = c_api_app_registry.remove(req);
}

// Global storage for app pointers keyed by Engine12 instance
// This allows middleware to access the app instance
var app_ptr_registry: std.AutoHashMap(*Engine12, *CEngine12) = undefined;
var app_ptr_registry_init = false;
var app_ptr_registry_mutex: std.Thread.Mutex = std.Thread.Mutex{};

fn initAppPtrRegistry() void {
    if (!app_ptr_registry_init) {
        app_ptr_registry = std.AutoHashMap(*Engine12, *CEngine12).init(allocator);
        app_ptr_registry_init = true;
    }
}

fn getAppPtrForEngine(engine: *Engine12) ?*CEngine12 {
    initAppPtrRegistry();
    app_ptr_registry_mutex.lock();
    defer app_ptr_registry_mutex.unlock();
    return app_ptr_registry.get(engine);
}

fn setAppPtrForEngine(engine: *Engine12, app: *CEngine12) void {
    initAppPtrRegistry();
    app_ptr_registry_mutex.lock();
    defer app_ptr_registry_mutex.unlock();
    app_ptr_registry.put(engine, app) catch {};
}

// Global variable to store app pointer during middleware registration
// This is set temporarily when registering routes and cleared afterwards
var current_app_ptr: ?*CEngine12 = null;
var current_app_ptr_mutex: std.Thread.Mutex = std.Thread.Mutex{};

// Pre-request middleware wrapper that sets app_ptr in request context
fn createAppPtrWrapper() middleware.PreRequestMiddlewareFn {
    return struct {
        fn wrapper(req: *Request) middleware.MiddlewareResult {
            // Get app from registry - iterate through all registered apps
            // In practice, there should be one C API app instance
            app_ptr_registry_mutex.lock();
            defer app_ptr_registry_mutex.unlock();

            var iterator = app_ptr_registry.iterator();
            if (iterator.next()) |entry| {
                // Store first matching app pointer
                const app_ptr_str = std.fmt.allocPrint(req.arena.allocator(), "{d}", .{@intFromPtr(entry.value_ptr.*)}) catch return .proceed;
                req.set("c_api_app_ptr", app_ptr_str) catch {};
                setAppForRequest(req, entry.value_ptr.*);
            }
            return .proceed; // Continue to router middleware
        }
    }.wrapper;
}

// Pre-request middleware that intercepts requests and routes them to C handlers
// This runs before engine12's routing, so it can handle C API routes
fn createCRouterMiddleware(app_ptr: *CEngine12) middleware.PreRequestMiddlewareFn {
    // Store app pointer in registry keyed by engine12 instance
    setAppPtrForEngine(&app_ptr.engine, app_ptr);

    // Create middleware function that gets app from registry
    const middlewareFn = struct {
        fn handler(req: *Request) middleware.MiddlewareResult {
            // Get app from registry - try engine-based registry first
            app_ptr_registry_mutex.lock();
            defer app_ptr_registry_mutex.unlock();

            var iterator = app_ptr_registry.iterator();
            const app_entry = iterator.next() orelse {
                // No app found in registry - let engine12 handle it
                return .proceed;
            };
            const c_app = app_entry.value_ptr.*;

            const method_str = req.method();
            const path = req.path();

            // Try to match route
            for (c_app.routes.items) |entry| {
                if (!std.mem.eql(u8, entry.method, method_str)) continue;

                // Try to match pattern - check direct path match first for performance
                var matched = false;
                if (std.mem.eql(u8, path, entry.path_pattern)) {
                    matched = true;
                } else {
                    matched = (entry.pattern.match(req.arena.allocator(), path) catch null) != null;
                }

                if (matched) {
                    // Extract params if pattern matched
                    if (entry.pattern.match(req.arena.allocator(), path) catch null) |params| {
                        req.setRouteParams(params) catch {};
                    }

                    // Create C request wrapper - store pointer to req
                    const c_req = allocator.create(CRequest) catch {
                        req.context.put("c_api_error", "Failed to create C request wrapper") catch {};
                        return .abort;
                    };
                    c_req.* = CRequest{
                        .request = req,
                        .persistent_path = null,
                    };

                    // Call C handler
                    const handler_fn = getHandler(entry.handler_id) orelse {
                        allocator.destroy(c_req);
                        req.context.put("c_api_error", "Handler not found") catch {};
                        return .abort;
                    };
                    const c_resp = handler_fn(c_req, entry.user_data);
                    const resp = c_resp.response;

                    // Store response in global storage (thread-safe)
                    const mw = @import("engine12").middleware;
                    mw.storeCAPIResponse(req, resp) catch {
                        allocator.destroy(c_req);
                        return .abort;
                    };

                    allocator.destroy(c_req);

                    // Mark that we handled this request
                    req.context.put("c_api_handled", "true") catch {};
                    return .abort; // Abort to prevent engine12 routing
                }
            }

            // No route matched - let engine12 handle it
            return .proceed;
        }
    };

    return middlewareFn.handler;
}

// Export functions - use opaque handles for C compatibility
export fn e12_init(env: c_int, out_app: **CEngine12Handle) c_int {
    clearLastError();

    const environment = switch (env) {
        0 => types.Environment.development,
        1 => types.Environment.staging,
        2 => types.Environment.production,
        else => {
            setLastError("Invalid environment");
            return 1; // E12_ERROR_INVALID_ARGUMENT
        },
    };

    const profile = switch (environment) {
        .development => types.ServerProfile_Development,
        .staging => types.ServerProfile_Testing,
        .production => types.ServerProfile_Production,
    };

    const engine = Engine12.initWithProfile(profile) catch |err| {
        setLastError(@errorName(err));
        return 4; // E12_ERROR_ALLOCATION_FAILED
    };

    const c_app = allocator.create(CEngine12) catch {
        setLastError("Allocation failed");
        return 4; // E12_ERROR_ALLOCATION_FAILED
    };

    c_app.* = CEngine12{
        .engine = engine,
        .routes = .{},
        .catch_all_registered = false,
        .allocator = allocator,
    };

    const handle = allocator.create(u8) catch {
        setLastError("Allocation failed");
        return 4; // E12_ERROR_ALLOCATION_FAILED
    };

    storeCEngine12(@ptrCast(handle), c_app);
    out_app.* = @ptrCast(handle);
    return 0; // E12_OK
}

export fn e12_free(app: ?*CEngine12Handle) void {
    if (app) |handle| {
        if (getCEngine12(handle)) |c_app| {
            c_app.deinit();
            removeCEngine12(handle);
            const u8_ptr: *u8 = @ptrCast(handle);
            allocator.destroy(u8_ptr);
        }
    }
}

export fn e12_start(app: ?*CEngine12Handle) c_int {
    clearLastError();

    if (app == null) {
        setLastError("Invalid engine12 instance");
        return 1; // E12_ERROR_INVALID_ARGUMENT
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1; // E12_ERROR_INVALID_ARGUMENT
    };

    c_app.engine.start() catch |err| {
        setLastError(@errorName(err));
        return 5; // E12_ERROR_SERVER_START_FAILED
    };

    return 0; // E12_OK
}

export fn e12_stop(app: ?*CEngine12Handle) c_int {
    clearLastError();

    if (app == null) {
        setLastError("Invalid engine12 instance");
        return 1;
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1;
    };

    c_app.engine.stop() catch |err| {
        setLastError(@errorName(err));
        return 99; // E12_ERROR_UNKNOWN
    };

    return 0;
}

export fn e12_is_running(app: ?*CEngine12Handle) bool {
    if (app == null) return false;
    const c_app = getCEngine12(app.?) orelse return false;
    return c_app.engine.is_running;
}

// Helper to register a route with runtime path
// Since engine12 requires comptime paths, we register each route individually
// with a wrapper handler that dispatches to the C handler
fn registerCRoute(
    app: *CEngine12,
    method: []const u8,
    path: []const u8,
    handler_id: usize,
    user_data: *anyopaque,
) !void {
    // Build server if not already built (same as engine12.get/post/etc)
    if (app.engine.built_server == null) {
        var builder = ziggurat.ServerBuilder.init(app.allocator);
        var server = try builder
            .host("127.0.0.1")
            .port(8080)
            .readTimeout(5000)
            .writeTimeout(5000)
            .build();

        app.engine.built_server = server;
        app.engine.http_server = @ptrCast(&server);
    }

    // Parse route pattern first
    const pattern = router.RoutePattern.parse(app.allocator, path) catch {
        return error.InvalidPath;
    };

    // Store route entry
    const method_copy = try app.allocator.dupe(u8, method);
    const path_copy = try app.allocator.dupe(u8, path);

    try app.routes.append(app.allocator, .{
        .method = method_copy,
        .path_pattern = path_copy,
        .handler_id = handler_id,
        .user_data = user_data,
        .pattern = pattern,
    });

    // Register route with ziggurat server using a wrapper handler
    // This wrapper executes middleware and calls the C handler
    const wrapped_handler = struct {
        fn handler(ziggurat_req: *ziggurat.request.Request) ziggurat.response.Response {
            // Get app from registry
            app_ptr_registry_mutex.lock();
            defer app_ptr_registry_mutex.unlock();

            var iterator = app_ptr_registry.iterator();
            const app_entry = iterator.next() orelse {
                return Response.text("App not found").withStatus(500).toZiggurat();
            };
            const app_ptr = app_entry.value_ptr.*;

            var req = Request.fromZiggurat(ziggurat_req, allocator);
            defer req.deinit(); // Always deinit req at the end

            // Execute middleware chain
            if (app_ptr.engine.middleware.executePreRequest(&req)) |abort_resp| {
                return abort_resp.toZiggurat();
            }

            // Find matching route entry
            const method_str = @tagName(ziggurat_req.method);
            const path_str = ziggurat_req.path;

            for (app_ptr.routes.items) |entry| {
                if (!std.mem.eql(u8, entry.method, method_str)) continue;
                if (std.mem.eql(u8, path_str, entry.path_pattern) or
                    (entry.pattern.match(req.arena.allocator(), path_str) catch null) != null)
                {
                    // Create C request wrapper - store pointer to req
                    const c_req = allocator.create(CRequest) catch {
                        return Response.text("Internal error").withStatus(500).toZiggurat();
                    };
                    c_req.* = CRequest{
                        .request = &req,
                        .persistent_path = null,
                    };

                    // Call C handler
                    const handler_fn = getHandler(entry.handler_id) orelse {
                        allocator.destroy(c_req);
                        return Response.text("Handler not found").withStatus(500).toZiggurat();
                    };
                    const c_resp = handler_fn(c_req, entry.user_data);

                    // Copy the Response - ensure it's fully copied before any cleanup
                    const resp = c_resp.response;

                    // Free the CRequest wrapper - req will be deinitialized by defer
                    allocator.destroy(c_req);

                    // Convert to ziggurat response and return
                    // Note: c_resp is owned by Python, so we don't free it here
                    return resp.toZiggurat();
                }
            }

            return Response.text("Not Found").withStatus(404).toZiggurat();
        }
    }.handler;

    // Register with ziggurat server
    if (app.engine.built_server) |*server| {
        if (std.mem.eql(u8, method, "GET")) {
            try server.get(path, wrapped_handler);
        } else if (std.mem.eql(u8, method, "POST")) {
            try server.post(path, wrapped_handler);
        } else if (std.mem.eql(u8, method, "PUT")) {
            try server.put(path, wrapped_handler);
        } else if (std.mem.eql(u8, method, "DELETE")) {
            try server.delete(path, wrapped_handler);
        } else if (std.mem.eql(u8, method, "PATCH")) {
            // PATCH is not directly supported by ziggurat Server
            // Route is still registered in engine12's route table
            // Use POST as fallback for ziggurat registration
            try server.post(path, wrapped_handler);
        }
    }

    // Store app pointer in registry for middleware access
    setAppPtrForEngine(&app.engine, app);
}

export fn e12_get(
    app: ?*CEngine12Handle,
    path: [*c]const u8,
    handler: ?*const fn (*CRequest, *anyopaque) *CResponse,
    user_data: *anyopaque,
) c_int {
    clearLastError();

    if (app == null or path == null or handler == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1;
    };
    const path_slice = std.mem.span(path);
    if (path_slice.len == 0) {
        setLastError("Path must not be empty");
        return 1;
    }
    const handler_id = registerHandler(handler.?);

    registerCRoute(c_app, "GET", path_slice, handler_id, user_data) catch |err| {
        setLastError(@errorName(err));
        return 2;
    };

    return 0;
}

export fn e12_post(
    app: ?*CEngine12Handle,
    path: [*c]const u8,
    handler: ?*const fn (*CRequest, *anyopaque) *CResponse,
    user_data: *anyopaque,
) c_int {
    clearLastError();

    if (app == null or path == null or handler == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1;
    };
    const path_slice = std.mem.span(path);
    if (path_slice.len == 0) {
        setLastError("Path must not be empty");
        return 1;
    }
    const handler_id = registerHandler(handler.?);

    registerCRoute(c_app, "POST", path_slice, handler_id, user_data) catch |err| {
        setLastError(@errorName(err));
        return 2;
    };

    return 0;
}

export fn e12_put(
    app: ?*CEngine12Handle,
    path: [*c]const u8,
    handler: ?*const fn (*CRequest, *anyopaque) *CResponse,
    user_data: *anyopaque,
) c_int {
    clearLastError();

    if (app == null or path == null or handler == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1;
    };
    const path_slice = std.mem.span(path);
    if (path_slice.len == 0) {
        setLastError("Path must not be empty");
        return 1;
    }
    const handler_id = registerHandler(handler.?);

    registerCRoute(c_app, "PUT", path_slice, handler_id, user_data) catch |err| {
        setLastError(@errorName(err));
        return 2;
    };

    return 0;
}

export fn e12_delete(
    app: ?*CEngine12Handle,
    path: [*c]const u8,
    handler: ?*const fn (*CRequest, *anyopaque) *CResponse,
    user_data: *anyopaque,
) c_int {
    clearLastError();

    if (app == null or path == null or handler == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1;
    };
    const path_slice = std.mem.span(path);
    if (path_slice.len == 0) {
        setLastError("Path must not be empty");
        return 1;
    }
    const handler_id = registerHandler(handler.?);

    registerCRoute(c_app, "DELETE", path_slice, handler_id, user_data) catch |err| {
        setLastError(@errorName(err));
        return 2;
    };

    return 0;
}

export fn e12_patch(
    app: ?*CEngine12Handle,
    path: [*c]const u8,
    handler: ?*const fn (*CRequest, *anyopaque) *CResponse,
    user_data: *anyopaque,
) c_int {
    clearLastError();

    if (app == null or path == null or handler == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1;
    };
    const path_slice = std.mem.span(path);
    if (path_slice.len == 0) {
        setLastError("Path must not be empty");
        return 1;
    }
    const handler_id = registerHandler(handler.?);

    registerCRoute(c_app, "PATCH", path_slice, handler_id, user_data) catch |err| {
        setLastError(@errorName(err));
        return 2;
    };

    return 0;
}

// Request API
export fn e12_request_path(req: ?*CRequest) [*c]const u8 {
    if (req == null) return null;
    const c_req = req.?;

    // If path is already cached in persistent memory, return it
    if (c_req.persistent_path) |persistent_path| {
        return persistent_path.ptr;
    }

    // Get path from request (may be a slice without query string)
    const request_ptr = c_req.request;
    const path = request_ptr.path();

    // Duplicate path to persistent memory (null-terminated for C API)
    // This ensures the pointer remains valid after request deinitialization
    const persistent_path = allocator.dupeZ(u8, path) catch return null;
    c_req.persistent_path = persistent_path;

    return persistent_path.ptr;
}

export fn e12_request_method(req: ?*CRequest) c_int {
    if (req == null) return 0;
    const request_ptr = req.?.request;
    const method = request_ptr.method();
    return if (std.mem.eql(u8, method, "GET")) 0 else if (std.mem.eql(u8, method, "POST")) 1 else if (std.mem.eql(u8, method, "PUT")) 2 else if (std.mem.eql(u8, method, "DELETE")) 3 else 0;
}

export fn e12_request_body(req: ?*CRequest) [*c]const u8 {
    if (req == null) return null;
    const request_ptr = req.?.request;
    const body = request_ptr.body();
    return body.ptr;
}

export fn e12_request_body_len(req: ?*CRequest) usize {
    if (req == null) return 0;
    const request_ptr = req.?.request;
    const body = request_ptr.body();
    return body.len;
}

export fn e12_request_header(req: ?*CRequest, name: [*c]const u8) [*c]const u8 {
    if (req == null or name == null) return null;
    const name_slice = std.mem.span(name);
    const request_ptr = req.?.request;
    const value = request_ptr.header(name_slice) orelse return null;
    // Header value is owned by request, valid for request lifetime
    return value.ptr;
}

export fn e12_request_param(req: ?*CRequest, name: [*c]const u8) [*c]const u8 {
    if (req == null or name == null) return null;
    const name_slice = std.mem.span(name);
    const request_ptr = req.?.request;
    const value = request_ptr.route_params.get(name_slice) orelse return null;
    // Route param value is owned by request's arena, valid for request lifetime
    return value.ptr;
}

export fn e12_request_query(req: ?*CRequest, name: [*c]const u8) [*c]const u8 {
    if (req == null or name == null) return null;
    const name_slice = std.mem.span(name);
    const request_ptr = req.?.request;
    const value = request_ptr.query(name_slice) catch return null;
    return if (value) |v| v.ptr else null;
}

export fn e12_request_set(req: ?*CRequest, key: [*c]const u8, value: [*c]const u8) c_int {
    clearLastError();

    if (req == null or key == null or value == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const key_slice = std.mem.span(key);
    const value_slice = std.mem.span(value);
    const request_ptr = req.?.request;
    request_ptr.set(key_slice, value_slice) catch |err| {
        setLastError(@errorName(err));
        return 1;
    };

    return 0;
}

export fn e12_request_get(req: ?*CRequest, key: [*c]const u8) [*c]const u8 {
    if (req == null or key == null) return null;
    const key_slice = std.mem.span(key);
    const request_ptr = req.?.request;
    const value = request_ptr.get(key_slice) orelse return null;
    // Context value is owned by request's arena, valid for request lifetime
    return value.ptr;
}

// Middleware registry entry
const MiddlewareEntry = struct {
    pre_request_fn: ?E12PreRequestMiddlewareFn,
    response_fn: ?E12ResponseMiddlewareFn,
    user_data: *anyopaque,
};

// Middleware registry using array for efficient lookup by ID
// Note: Limited to 16 entries due to switch statement limitations
// This can be expanded by adding more cases to the switch statements
const MAX_MIDDLEWARE_ENTRIES = 16;
var middleware_entries: [MAX_MIDDLEWARE_ENTRIES]?MiddlewareEntry = [_]?MiddlewareEntry{null} ** MAX_MIDDLEWARE_ENTRIES;
var middleware_registry_mutex: std.Thread.Mutex = std.Thread.Mutex{};
var middleware_next_id: usize = 0;

// Task registry entry for C API background tasks
const TaskRegistryEntry = struct {
    task_fn: E12BackgroundTaskFn,
    user_data: *anyopaque,
};

// Task registry using array for efficient lookup by ID
const MAX_TASK_ENTRIES = 32;
var task_registry: [MAX_TASK_ENTRIES]?TaskRegistryEntry = [_]?TaskRegistryEntry{null} ** MAX_TASK_ENTRIES;
var task_registry_next_id: usize = 0;
var task_registry_mutex: std.Thread.Mutex = std.Thread.Mutex{};

// Health check registry entry for C API health checks
const HealthCheckRegistryEntry = struct {
    check_fn: E12HealthCheckFn,
    user_data: *anyopaque,
};

// Health check registry using array for efficient lookup by ID
const MAX_HEALTH_CHECK_ENTRIES = 16;
var health_check_registry: [MAX_HEALTH_CHECK_ENTRIES]?HealthCheckRegistryEntry = [_]?HealthCheckRegistryEntry{null} ** MAX_HEALTH_CHECK_ENTRIES;
var health_check_registry_next_id: usize = 0;
var health_check_registry_mutex: std.Thread.Mutex = std.Thread.Mutex{};

// Comptime function to generate task wrapper functions for each possible ID
fn makeTaskWrapper(comptime id: usize) types.BackgroundTask {
    return struct {
        fn wrapper() void {
            task_registry_mutex.lock();
            defer task_registry_mutex.unlock();
            if (task_registry[id]) |entry| {
                entry.task_fn(entry.user_data);
            }
        }
    }.wrapper;
}

// Runtime dispatch to the correct comptime-generated wrapper
fn getTaskWrapper(id: usize) types.BackgroundTask {
    return switch (id) {
        0 => makeTaskWrapper(0),
        1 => makeTaskWrapper(1),
        2 => makeTaskWrapper(2),
        3 => makeTaskWrapper(3),
        4 => makeTaskWrapper(4),
        5 => makeTaskWrapper(5),
        6 => makeTaskWrapper(6),
        7 => makeTaskWrapper(7),
        8 => makeTaskWrapper(8),
        9 => makeTaskWrapper(9),
        10 => makeTaskWrapper(10),
        11 => makeTaskWrapper(11),
        12 => makeTaskWrapper(12),
        13 => makeTaskWrapper(13),
        14 => makeTaskWrapper(14),
        15 => makeTaskWrapper(15),
        16 => makeTaskWrapper(16),
        17 => makeTaskWrapper(17),
        18 => makeTaskWrapper(18),
        19 => makeTaskWrapper(19),
        20 => makeTaskWrapper(20),
        21 => makeTaskWrapper(21),
        22 => makeTaskWrapper(22),
        23 => makeTaskWrapper(23),
        24 => makeTaskWrapper(24),
        25 => makeTaskWrapper(25),
        26 => makeTaskWrapper(26),
        27 => makeTaskWrapper(27),
        28 => makeTaskWrapper(28),
        29 => makeTaskWrapper(29),
        30 => makeTaskWrapper(30),
        31 => makeTaskWrapper(31),
        else => makeTaskWrapper(0), // Fallback
    };
}

// Comptime function to generate health check wrapper functions for each possible ID
fn makeHealthCheckWrapper(comptime id: usize) types.HealthCheckFn {
    return struct {
        fn wrapper() types.HealthStatus {
            health_check_registry_mutex.lock();
            defer health_check_registry_mutex.unlock();
            if (health_check_registry[id]) |entry| {
                const result = entry.check_fn(entry.user_data);
                return switch (result) {
                    .E12_HEALTH_HEALTHY => .healthy,
                    .E12_HEALTH_DEGRADED => .degraded,
                    .E12_HEALTH_UNHEALTHY => .unhealthy,
                };
            }
            return .unhealthy;
        }
    }.wrapper;
}

// Runtime dispatch to the correct comptime-generated wrapper
fn getHealthCheckWrapper(id: usize) types.HealthCheckFn {
    return switch (id) {
        0 => makeHealthCheckWrapper(0),
        1 => makeHealthCheckWrapper(1),
        2 => makeHealthCheckWrapper(2),
        3 => makeHealthCheckWrapper(3),
        4 => makeHealthCheckWrapper(4),
        5 => makeHealthCheckWrapper(5),
        6 => makeHealthCheckWrapper(6),
        7 => makeHealthCheckWrapper(7),
        8 => makeHealthCheckWrapper(8),
        9 => makeHealthCheckWrapper(9),
        10 => makeHealthCheckWrapper(10),
        11 => makeHealthCheckWrapper(11),
        12 => makeHealthCheckWrapper(12),
        13 => makeHealthCheckWrapper(13),
        14 => makeHealthCheckWrapper(14),
        15 => makeHealthCheckWrapper(15),
        else => makeHealthCheckWrapper(0), // Fallback
    };
}

fn registerPreRequestMiddleware(middleware_fn: E12PreRequestMiddlewareFn, user_data: *anyopaque) !usize {
    middleware_registry_mutex.lock();
    defer middleware_registry_mutex.unlock();

    if (middleware_next_id >= MAX_MIDDLEWARE_ENTRIES) {
        return error.TooManyMiddleware;
    }

    const id = middleware_next_id;
    middleware_next_id += 1;

    middleware_entries[id] = .{
        .pre_request_fn = middleware_fn,
        .response_fn = null,
        .user_data = user_data,
    };

    return id;
}

fn registerResponseMiddleware(middleware_fn: E12ResponseMiddlewareFn, user_data: *anyopaque) !usize {
    middleware_registry_mutex.lock();
    defer middleware_registry_mutex.unlock();

    if (middleware_next_id >= MAX_MIDDLEWARE_ENTRIES) {
        return error.TooManyMiddleware;
    }

    const id = middleware_next_id;
    middleware_next_id += 1;

    middleware_entries[id] = .{
        .pre_request_fn = null,
        .response_fn = middleware_fn,
        .user_data = user_data,
    };

    return id;
}

fn getMiddlewareEntry(id: usize) ?MiddlewareEntry {
    middleware_registry_mutex.lock();
    defer middleware_registry_mutex.unlock();

    if (id >= MAX_MIDDLEWARE_ENTRIES) return null;
    return middleware_entries[id];
}

// Create unique wrapper functions for each middleware by generating them with the ID baked in
// Using comptime allows us to create unique functions for each ID
fn makePreRequestWrapper(comptime id: usize) middleware.PreRequestMiddlewareFn {
    return struct {
        fn mw(req: *Request) middleware.MiddlewareResult {
            const entry = getMiddlewareEntry(id) orelse return .abort;
            const mw_fn = entry.pre_request_fn orelse return .abort;

            const c_req = allocator.create(CRequest) catch return .abort;
            c_req.* = CRequest{
                .request = req,
                .persistent_path = null,
            };
            defer allocator.destroy(c_req);

            const result = mw_fn(c_req, entry.user_data);
            return switch (result) {
                .E12_MIDDLEWARE_PROCEED => .proceed,
                .E12_MIDDLEWARE_ABORT => .abort,
            };
        }
    }.mw;
}

fn makeResponseWrapper(comptime id: usize) middleware.ResponseMiddlewareFn {
    return struct {
        fn mw(resp: Response) Response {
            const entry = getMiddlewareEntry(id) orelse return resp;
            const mw_fn = entry.response_fn orelse return resp;

            const c_resp = allocator.create(CResponse) catch return resp;
            c_resp.* = CResponse{
                .response = resp,
                .persistent_body = null,
            };

            const result = mw_fn(c_resp, entry.user_data);
            const new_resp = result.response;
            allocator.destroy(c_resp);
            return new_resp;
        }
    }.mw;
}

// Middleware API
export fn e12_use_pre_request(
    app: ?*CEngine12Handle,
    middleware_fn: ?E12PreRequestMiddlewareFn,
    user_data: *anyopaque,
) c_int {
    clearLastError();

    if (app == null or middleware_fn == null) {
        setLastError("Invalid arguments");
        return 1; // E12_ERROR_INVALID_ARGUMENT
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1; // E12_ERROR_INVALID_ARGUMENT
    };

    // Register middleware with user_data
    const middleware_id = registerPreRequestMiddleware(middleware_fn.?, user_data) catch |err| {
        setLastError(@errorName(err));
        return 99; // E12_ERROR_UNKNOWN
    };

    // Create wrapper using a switch to select the right wrapper function
    // This is a workaround since we can't create functions dynamically
    // Note: This limits us to 16 middleware entries (0-15)
    // For more entries, we'd need to expand the switch or use a different approach
    const wrapper = switch (middleware_id) {
        0 => makePreRequestWrapper(0),
        1 => makePreRequestWrapper(1),
        2 => makePreRequestWrapper(2),
        3 => makePreRequestWrapper(3),
        4 => makePreRequestWrapper(4),
        5 => makePreRequestWrapper(5),
        6 => makePreRequestWrapper(6),
        7 => makePreRequestWrapper(7),
        8 => makePreRequestWrapper(8),
        9 => makePreRequestWrapper(9),
        10 => makePreRequestWrapper(10),
        11 => makePreRequestWrapper(11),
        12 => makePreRequestWrapper(12),
        13 => makePreRequestWrapper(13),
        14 => makePreRequestWrapper(14),
        15 => makePreRequestWrapper(15),
        else => {
            setLastError("Too many middleware registered (max 16)");
            return 2; // E12_ERROR_TOO_MANY_ROUTES
        },
    };

    c_app.engine.middleware.addPreRequest(wrapper) catch |err| {
        setLastError(@errorName(err));
        return 99; // E12_ERROR_UNKNOWN
    };

    return 0; // E12_OK
}

export fn e12_use_response(
    app: ?*CEngine12Handle,
    middleware_fn: ?E12ResponseMiddlewareFn,
    user_data: *anyopaque,
) c_int {
    clearLastError();

    if (app == null or middleware_fn == null) {
        setLastError("Invalid arguments");
        return 1; // E12_ERROR_INVALID_ARGUMENT
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1; // E12_ERROR_INVALID_ARGUMENT
    };

    // Register middleware with user_data
    const middleware_id = registerResponseMiddleware(middleware_fn.?, user_data) catch |err| {
        setLastError(@errorName(err));
        return 99; // E12_ERROR_UNKNOWN
    };

    // Create wrapper using a switch to select the right wrapper function
    // Note: This limits us to 16 middleware entries (0-15)
    const wrapper = switch (middleware_id) {
        0 => makeResponseWrapper(0),
        1 => makeResponseWrapper(1),
        2 => makeResponseWrapper(2),
        3 => makeResponseWrapper(3),
        4 => makeResponseWrapper(4),
        5 => makeResponseWrapper(5),
        6 => makeResponseWrapper(6),
        7 => makeResponseWrapper(7),
        8 => makeResponseWrapper(8),
        9 => makeResponseWrapper(9),
        10 => makeResponseWrapper(10),
        11 => makeResponseWrapper(11),
        12 => makeResponseWrapper(12),
        13 => makeResponseWrapper(13),
        14 => makeResponseWrapper(14),
        15 => makeResponseWrapper(15),
        else => {
            setLastError("Too many middleware registered (max 16)");
            return 2; // E12_ERROR_TOO_MANY_ROUTES
        },
    };

    c_app.engine.middleware.addResponse(wrapper) catch |err| {
        setLastError(@errorName(err));
        return 99; // E12_ERROR_UNKNOWN
    };

    return 0; // E12_OK
}

// Static File Serving
export fn e12_serve_static(
    app: ?*CEngine12Handle,
    mount_path: [*c]const u8,
    directory: [*c]const u8,
) c_int {
    clearLastError();

    if (app == null or mount_path == null or directory == null) {
        setLastError("Invalid arguments");
        return 1; // E12_ERROR_INVALID_ARGUMENT
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1; // E12_ERROR_INVALID_ARGUMENT
    };

    const mount_path_slice = std.mem.span(mount_path);
    const directory_slice = std.mem.span(directory);

    // Validate inputs
    if (mount_path_slice.len == 0 or directory_slice.len == 0) {
        setLastError("Mount path and directory must not be empty");
        return 1; // E12_ERROR_INVALID_ARGUMENT
    }

    // Validate mount path starts with /
    if (mount_path_slice[0] != '/') {
        setLastError("Mount path must start with '/'");
        return 6; // E12_ERROR_INVALID_PATH
    }

    c_app.engine.serveStatic(mount_path_slice, directory_slice) catch |err| {
        setLastError(@errorName(err));
        return switch (err) {
            error.TooManyStaticRoutes => 2,
            error.ServerAlreadyBuilt => 3,
            else => 99,
        };
    };

    return 0; // E12_OK
}

// Background Tasks
export fn e12_register_task(
    app: ?*CEngine12Handle,
    name: [*c]const u8,
    task: ?E12BackgroundTaskFn,
    interval_ms: c_uint,
    user_data: *anyopaque,
) c_int {
    clearLastError();

    if (app == null or name == null or task == null) {
        setLastError("Invalid arguments");
        return 1; // E12_ERROR_INVALID_ARGUMENT
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1; // E12_ERROR_INVALID_ARGUMENT
    };

    const name_slice = std.mem.span(name);
    if (name_slice.len == 0) {
        setLastError("Task name must not be empty");
        return 1; // E12_ERROR_INVALID_ARGUMENT
    }

    // Register task callback and user_data in registry
    task_registry_mutex.lock();

    if (task_registry_next_id >= MAX_TASK_ENTRIES) {
        task_registry_mutex.unlock();
        setLastError("Too many tasks");
        return 2;
    }

    const task_id = task_registry_next_id;
    task_registry_next_id += 1;

    task_registry[task_id] = .{
        .task_fn = task.?,
        .user_data = user_data,
    };

    task_registry_mutex.unlock();

    // Get the comptime-generated wrapper function for this ID
    const wrapper_fn = getTaskWrapper(task_id);

    if (interval_ms == 0) {
        c_app.engine.runTask(name_slice, wrapper_fn) catch |err| {
            setLastError(@errorName(err));
            return switch (err) {
                error.TooManyWorkers => 2,
            };
        };
    } else {
        c_app.engine.schedulePeriodicTask(name_slice, wrapper_fn, interval_ms) catch |err| {
            setLastError(@errorName(err));
            return switch (err) {
                error.TooManyWorkers => 2,
            };
        };
    }

    return 0; // E12_OK
}

// Health Checks
export fn e12_register_health_check(
    app: ?*CEngine12Handle,
    check: ?E12HealthCheckFn,
    user_data: *anyopaque,
) c_int {
    clearLastError();

    if (app == null or check == null) {
        setLastError("Invalid arguments");
        return 1; // E12_ERROR_INVALID_ARGUMENT
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1; // E12_ERROR_INVALID_ARGUMENT
    };

    // Register health check callback and user_data in registry
    health_check_registry_mutex.lock();
    defer health_check_registry_mutex.unlock();

    if (health_check_registry_next_id >= MAX_HEALTH_CHECK_ENTRIES) {
        setLastError("Too many health checks");
        return 2;
    }

    const check_id = health_check_registry_next_id;
    health_check_registry_next_id += 1;

    health_check_registry[check_id] = .{
        .check_fn = check.?,
        .user_data = user_data,
    };

    // Get the comptime-generated wrapper function for this ID
    const wrapper_fn = getHealthCheckWrapper(check_id);

    c_app.engine.registerHealthCheck(wrapper_fn) catch |err| {
        setLastError(@errorName(err));
        return switch (err) {
            error.TooManyHealthChecks => 2,
        };
    };

    return 0; // E12_OK
}

// Response API
export fn e12_response_json(body: [*c]const u8) ?*CResponse {
    if (body == null) return null;

    const body_slice = std.mem.span(body);
    const persistent_body = allocator.dupe(u8, body_slice) catch return null;

    const resp = allocator.create(CResponse) catch {
        allocator.free(persistent_body);
        return null;
    };

    resp.* = CResponse{
        .response = Response.json(persistent_body),
        .persistent_body = persistent_body,
    };

    return resp;
}

export fn e12_response_text(body: [*c]const u8) ?*CResponse {
    if (body == null) return null;

    const body_slice = std.mem.span(body);
    const persistent_body = allocator.dupe(u8, body_slice) catch return null;

    const resp = allocator.create(CResponse) catch {
        allocator.free(persistent_body);
        return null;
    };

    resp.* = CResponse{
        .response = Response.text(persistent_body),
        .persistent_body = persistent_body,
    };

    return resp;
}

export fn e12_response_html(body: [*c]const u8) ?*CResponse {
    if (body == null) return null;

    const body_slice = std.mem.span(body);
    const persistent_body = allocator.dupe(u8, body_slice) catch return null;

    const resp = allocator.create(CResponse) catch {
        allocator.free(persistent_body);
        return null;
    };

    resp.* = CResponse{
        .response = Response.html(persistent_body),
        .persistent_body = persistent_body,
    };

    return resp;
}

export fn e12_response_status(status_code: c_ushort) ?*CResponse {
    const resp = allocator.create(CResponse) catch return null;

    resp.* = CResponse{
        .response = Response.status(status_code),
        .persistent_body = null,
    };

    return resp;
}

export fn e12_response_redirect(location: [*c]const u8) ?*CResponse {
    if (location == null) return null;

    const location_slice = std.mem.span(location);
    const persistent_location = allocator.dupe(u8, location_slice) catch return null;

    const resp = allocator.create(CResponse) catch {
        allocator.free(persistent_location);
        return null;
    };

    resp.* = CResponse{
        .response = Response.redirect(persistent_location),
        .persistent_body = persistent_location,
    };

    return resp;
}

export fn e12_response_with_status(resp: ?*CResponse, status_code: c_ushort) ?*CResponse {
    if (resp == null) return null;

    resp.?.response = resp.?.response.withStatus(status_code);
    return resp;
}

export fn e12_response_with_content_type(resp: ?*CResponse, content_type: [*c]const u8) ?*CResponse {
    if (resp == null or content_type == null) return null;

    const content_type_slice = std.mem.span(content_type);
    resp.?.response = resp.?.response.withContentType(content_type_slice);
    return resp;
}

export fn e12_response_with_header(resp: ?*CResponse, name: [*c]const u8, value: [*c]const u8) ?*CResponse {
    if (resp == null or name == null or value == null) return null;

    const name_slice = std.mem.span(name);
    const value_slice = std.mem.span(value);
    resp.?.response = resp.?.response.withHeader(name_slice, value_slice);
    return resp;
}

export fn e12_response_free(resp: ?*CResponse) void {
    if (resp) |c_resp| {
        c_resp.deinit();
    }
}

export fn e12_get_last_error() [*c]const u8 {
    return if (last_error) |err| err.ptr else null;
}

// ============================================================================
// Cache API
// ============================================================================

pub const CCache = struct {
    cache: cache.ResponseCache,
};

export fn e12_cache_init(default_ttl_ms: c_ulonglong, out_cache: [*c]?*anyopaque) c_int {
    clearLastError();

    if (out_cache == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const c_cache = allocator.create(CCache) catch {
        setLastError("Allocation failed");
        return 4;
    };

    c_cache.* = CCache{
        .cache = cache.ResponseCache.init(allocator, default_ttl_ms),
    };

    out_cache.* = @ptrCast(c_cache);
    return 0;
}

export fn e12_cache_free(cache_ptr: ?*CCache) void {
    if (cache_ptr) |c_cache| {
        // Cleanup cache entries
        var iterator = c_cache.cache.entries.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        c_cache.cache.entries.deinit();
        allocator.destroy(c_cache);
    }
}

export fn e12_cache_get(cache_ptr: ?*CCache, key: [*c]const u8, out_body: [*c][*c]const u8, out_body_len: [*c]usize) bool {
    if (cache_ptr == null or key == null or out_body == null or out_body_len == null) return false;

    const key_slice = std.mem.span(key);
    const entry = cache_ptr.?.cache.get(key_slice) orelse return false;

    out_body.* = entry.body.ptr;
    out_body_len.* = entry.body.len;
    return true;
}

export fn e12_cache_set(cache_ptr: ?*CCache, key: [*c]const u8, body: [*c]const u8, ttl_ms: c_ulonglong, content_type: [*c]const u8) c_int {
    clearLastError();

    if (cache_ptr == null or key == null or body == null or content_type == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const key_slice = std.mem.span(key);
    const body_slice = std.mem.span(body);
    const content_type_slice = std.mem.span(content_type);

    cache_ptr.?.cache.set(key_slice, body_slice, if (ttl_ms == 0) null else ttl_ms, content_type_slice) catch |err| {
        setLastError(@errorName(err));
        return 99;
    };

    return 0;
}

export fn e12_cache_invalidate(cache_ptr: ?*CCache, key: [*c]const u8) void {
    if (cache_ptr == null or key == null) return;
    const key_slice = std.mem.span(key);
    cache_ptr.?.cache.invalidate(key_slice);
}

export fn e12_cache_invalidate_prefix(cache_ptr: ?*CCache, prefix: [*c]const u8) void {
    if (cache_ptr == null or prefix == null) return;
    const prefix_slice = std.mem.span(prefix);
    cache_ptr.?.cache.invalidatePrefix(prefix_slice);
}

export fn e12_cache_cleanup(cache_ptr: ?*CCache) void {
    if (cache_ptr == null) return;
    cache_ptr.?.cache.cleanup();
}

export fn e12_set_cache(app: ?*CEngine12Handle, cache_ptr: ?*CCache) void {
    if (app == null or cache_ptr == null) return;
    const c_app = getCEngine12(app.?) orelse return;
    c_app.engine.setCache(@ptrCast(&cache_ptr.?.cache));
}

export fn e12_request_cache(req: ?*CRequest) ?*CCache {
    if (req == null) return null;
    const request_ptr = req.?.request;
    const cache_ptr = request_ptr.cache() orelse return null;

    // Create wrapper
    const c_cache = allocator.create(CCache) catch return null;
    // Note: This is a bit of a hack - we're storing a pointer to the cache
    // The cache is owned by Engine12, so we don't free it here
    c_cache.* = CCache{ .cache = cache_ptr.* };
    return @ptrCast(c_cache);
}

export fn e12_request_cache_get(req: ?*CRequest, key: [*c]const u8, out_body: [*c][*c]const u8, out_body_len: [*c]usize) bool {
    if (req == null or key == null or out_body == null or out_body_len == null) return false;
    const request_ptr = req.?.request;
    const entry = request_ptr.cacheGet(std.mem.span(key)) catch return false;
    const entry_ptr = entry orelse return false;
    out_body.* = entry_ptr.body.ptr;
    out_body_len.* = entry_ptr.body.len;
    return true;
}

export fn e12_request_cache_set(req: ?*CRequest, key: [*c]const u8, body: [*c]const u8, ttl_ms: c_ulonglong, content_type: [*c]const u8) c_int {
    clearLastError();

    if (req == null or key == null or body == null or content_type == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const request_ptr = req.?.request;
    request_ptr.cacheSet(
        std.mem.span(key),
        std.mem.span(body),
        if (ttl_ms == 0) null else ttl_ms,
        std.mem.span(content_type),
    ) catch |err| {
        setLastError(@errorName(err));
        return 99;
    };

    return 0;
}

// ============================================================================
// Metrics API
// ============================================================================

export fn e12_get_metrics(app: ?*CEngine12Handle) ?*anyopaque {
    if (app == null) return null;
    const c_app = getCEngine12(app.?) orelse return null;
    return @ptrCast(&c_app.engine.metrics_collector);
}

export fn e12_metrics_increment_counter(metrics_ptr: ?*anyopaque, name: [*c]const u8) void {
    if (metrics_ptr == null or name == null) return;
    const m = @as(*metrics.MetricsCollector, @ptrCast(@alignCast(metrics_ptr.?)));
    const name_slice = std.mem.span(name);
    // Use route timing with 0 duration to increment counter
    // Or create a custom metric
    _ = name_slice;
    m.incrementRequest();
}

export fn e12_metrics_record_timing(metrics_ptr: ?*anyopaque, name: [*c]const u8, duration_ms: c_ulonglong) void {
    if (metrics_ptr == null or name == null) return;
    const m = @as(*metrics.MetricsCollector, @ptrCast(@alignCast(metrics_ptr.?)));
    const name_slice = std.mem.span(name);
    m.recordRouteTiming(name_slice, duration_ms) catch {};
}

export fn e12_metrics_get_counter(metrics_ptr: ?*anyopaque, name: [*c]const u8) c_ulonglong {
    if (metrics_ptr == null or name == null) return 0;
    const m = @as(*metrics.MetricsCollector, @ptrCast(@alignCast(metrics_ptr.?)));
    const name_slice = std.mem.span(name);
    // Check if it's a known counter
    if (std.mem.eql(u8, name_slice, "requests")) {
        return m.request_count;
    } else if (std.mem.eql(u8, name_slice, "errors")) {
        return m.error_count;
    }
    // Try to get from route timings
    const timing = m.route_timings.get(name_slice);
    return if (timing) |t| t.count else 0;
}

export fn e12_request_increment_counter(req: ?*CRequest, name: [*c]const u8) void {
    if (req == null or name == null) return;
    const request_ptr = req.?.request;
    // Access metrics via app registry
    const c_app = getAppForRequest(request_ptr) orelse return;
    const m = &c_app.engine.metrics_collector;
    const name_slice = std.mem.span(name);
    if (std.mem.eql(u8, name_slice, "requests")) {
        m.incrementRequest();
    } else if (std.mem.eql(u8, name_slice, "errors")) {
        m.incrementError();
    }
}

// ============================================================================
// Rate Limiting
// ============================================================================

pub const CRateLimiter = struct {
    limiter: rate_limit.RateLimiter,
};

export fn e12_rate_limiter_init(max_requests: c_uint, window_ms: c_ulonglong, out_limiter: [*c]?*anyopaque) c_int {
    clearLastError();

    if (out_limiter == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const c_limiter = allocator.create(CRateLimiter) catch {
        setLastError("Allocation failed");
        return 4;
    };

    c_limiter.* = CRateLimiter{
        .limiter = rate_limit.RateLimiter.init(allocator, rate_limit.RateLimitConfig{
            .max_requests = max_requests,
            .window_ms = window_ms,
        }),
    };

    out_limiter.* = @ptrCast(c_limiter);
    return 0;
}

export fn e12_rate_limiter_free(limiter_ptr: ?*anyopaque) void {
    if (limiter_ptr) |ptr| {
        const c_limiter = @as(*CRateLimiter, @ptrCast(@alignCast(ptr)));
        c_limiter.limiter.deinit();
        allocator.destroy(c_limiter);
    }
}

export fn e12_set_rate_limiter(app: ?*CEngine12Handle, limiter_ptr: ?*anyopaque) void {
    if (app == null or limiter_ptr == null) return;
    const c_app = getCEngine12(app.?) orelse return;
    const c_limiter = @as(*CRateLimiter, @ptrCast(@alignCast(limiter_ptr.?)));
    c_app.engine.setRateLimiter(@ptrCast(&c_limiter.limiter));
}

export fn e12_request_rate_limit_check(req: ?*CRequest, key: [*c]const u8) bool {
    if (req == null or key == null) return false;
    const request_ptr = req.?.request;
    // Access rate limiter via global
    const limiter = @import("engine12").engine12.global_rate_limiter orelse return false;
    const key_slice = std.mem.span(key);
    // RateLimiter.check takes Request and route, so we need to use the request
    const result = limiter.check(request_ptr, key_slice) catch return false;
    return result == null; // null means allowed, non-null means rate limited
}

// ============================================================================
// Security Features
// ============================================================================

var csrf_protection: ?csrf.CSRFProtection = null;

export fn e12_csrf_init(secret: [*c]const u8) c_int {
    clearLastError();

    if (secret == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const secret_slice = std.mem.span(secret);
    const secret_dup = allocator.dupe(u8, secret_slice) catch {
        setLastError("Allocation failed");
        return 4;
    };

    csrf_protection = csrf.CSRFProtection.init(allocator, csrf.CSRFConfig{
        .secret_key = secret_dup,
    });

    return 0;
}

export fn e12_csrf_middleware(app: ?*CEngine12Handle) c_int {
    clearLastError();

    if (app == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    if (csrf_protection == null) {
        setLastError("CSRF not initialized");
        return 1;
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1;
    };

    const mw = csrf.createCSRFProtectionMiddleware(&csrf_protection.?);

    c_app.engine.usePreRequest(mw) catch {
        setLastError("Failed to register CSRF middleware");
        return 99;
    };

    return 0;
}

export fn e12_request_csrf_token(req: ?*CRequest) [*c]const u8 {
    if (req == null) return null;
    const request_ptr = req.?.request;
    const token = request_ptr.get("csrf_token") orelse return null;
    return token.ptr;
}

var cors_config: ?struct {
    allowed_origins: []const u8,
    allowed_methods: []const u8,
    allowed_headers: []const u8,
} = null;

export fn e12_cors_configure(app: ?*CEngine12Handle, allowed_origins: [*c]const u8, allowed_methods: [*c]const u8, allowed_headers: [*c]const u8) c_int {
    clearLastError();

    if (app == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const origins = if (allowed_origins) |o| std.mem.span(o) else "*";
    const methods = if (allowed_methods) |m| std.mem.span(m) else "*";
    const headers = if (allowed_headers) |h| std.mem.span(h) else "*";

    cors_config = .{
        .allowed_origins = allocator.dupe(u8, origins) catch {
            setLastError("Allocation failed");
            return 4;
        },
        .allowed_methods = allocator.dupe(u8, methods) catch {
            setLastError("Allocation failed");
            return 4;
        },
        .allowed_headers = allocator.dupe(u8, headers) catch {
            setLastError("Allocation failed");
            return 4;
        },
    };

    return 0;
}

export fn e12_cors_middleware(app: ?*CEngine12Handle) c_int {
    clearLastError();

    if (app == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1;
    };

    // CORS middleware is already built-in and automatically registered
    // This function is a no-op for compatibility
    _ = c_app;
    return 0;
}

export fn e12_set_body_size_limit(app: ?*CEngine12Handle, max_size_bytes: usize) void {
    if (app == null) return;
    const c_app = getCEngine12(app.?) orelse return;
    const limit_val = body_size_limit.BodySizeLimit{
        .max_bytes = max_size_bytes,
    };
    const mw = body_size_limit.createBodySizeLimitMiddleware(limit_val);
    c_app.engine.usePreRequest(mw) catch {};
}

// ============================================================================
// Request Enhancements
// ============================================================================

export fn e12_request_id(req: ?*CRequest) [*c]const u8 {
    if (req == null) return null;
    const request_ptr = req.?.request;
    const id = request_ptr.get("request_id") orelse return null;
    return id.ptr;
}

// JSON parsing - simplified implementation
pub const CJson = struct {
    data: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
};

export fn e12_request_json(req: ?*CRequest, out_json: [*c]?*anyopaque) c_int {
    clearLastError();

    if (req == null or out_json == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const request_ptr = req.?.request;
    const body = request_ptr.body();

    return e12_json_parse(body.ptr, out_json);
}

export fn e12_json_parse(json_str: [*c]const u8, out_json: [*c]?*anyopaque) c_int {
    clearLastError();

    if (json_str == null or out_json == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    _ = std.mem.span(json_str);

    // Simple JSON parsing - just parse as a flat map for now
    const c_json = allocator.create(CJson) catch {
        setLastError("Allocation failed");
        return 4;
    };

    c_json.* = CJson{
        .data = std.StringHashMap([]const u8).init(allocator),
        .allocator = allocator,
    };

    // Parse JSON string (simplified - just extract key-value pairs)
    // For a full implementation, use json_module.Json.deserialize
    // This is a placeholder
    out_json.* = @ptrCast(c_json);
    return 0;
}

export fn e12_json_get_string(json_ptr: ?*anyopaque, field: [*c]const u8) [*c]const u8 {
    if (json_ptr == null or field == null) return null;
    const c_json = @as(*CJson, @ptrCast(@alignCast(json_ptr.?)));
    const field_slice = std.mem.span(field);
    const value = c_json.data.get(field_slice) orelse return null;
    return value.ptr;
}

export fn e12_json_get_int(json_ptr: ?*anyopaque, field: [*c]const u8, out_value: [*c]c_longlong) bool {
    if (json_ptr == null or field == null or out_value == null) return false;
    const c_json = @as(*CJson, @ptrCast(@alignCast(json_ptr.?)));
    const field_slice = std.mem.span(field);
    const value_str = c_json.data.get(field_slice) orelse return false;
    const value = std.fmt.parseInt(i64, value_str, 10) catch return false;
    out_value.* = value;
    return true;
}

export fn e12_json_get_double(json_ptr: ?*anyopaque, field: [*c]const u8, out_value: [*c]f64) bool {
    if (json_ptr == null or field == null or out_value == null) return false;
    const c_json = @as(*CJson, @ptrCast(@alignCast(json_ptr.?)));
    const field_slice = std.mem.span(field);
    const value_str = c_json.data.get(field_slice) orelse return false;
    const value = std.fmt.parseFloat(f64, value_str) catch return false;
    out_value.* = value;
    return true;
}

export fn e12_json_get_bool(json_ptr: ?*anyopaque, field: [*c]const u8, out_value: [*c]bool) bool {
    if (json_ptr == null or field == null or out_value == null) return false;
    const c_json = @as(*CJson, @ptrCast(@alignCast(json_ptr.?)));
    const field_slice = std.mem.span(field);
    const value_str = c_json.data.get(field_slice) orelse return false;
    if (std.mem.eql(u8, value_str, "true")) {
        out_value.* = true;
        return true;
    } else if (std.mem.eql(u8, value_str, "false")) {
        out_value.* = false;
        return true;
    }
    return false;
}

export fn e12_json_free(json_ptr: ?*anyopaque) void {
    if (json_ptr) |ptr| {
        const c_json = @as(*CJson, @ptrCast(@alignCast(ptr)));
        var iterator = c_json.data.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        c_json.data.deinit();
        allocator.destroy(c_json);
    }
}

export fn e12_validate_string(value: [*c]const u8, min_len: usize, max_len: usize) bool {
    if (value == null) return false;
    const value_slice = std.mem.span(value);
    if (min_len > 0 and value_slice.len < min_len) return false;
    if (max_len > 0 and value_slice.len > max_len) return false;
    return true;
}

export fn e12_validate_int(value: c_longlong, min_value: c_longlong, max_value: c_longlong) bool {
    return value >= min_value and value <= max_value;
}

export fn e12_validate_email(email: [*c]const u8) bool {
    if (email == null) return false;
    const email_slice = std.mem.span(email);
    // Use validation.email() rule
    return validation.email(email_slice, allocator) == null;
}

export fn e12_validate_url(url: [*c]const u8) bool {
    if (url == null) return false;
    const url_slice = std.mem.span(url);
    // Simple URL validation - check for http:// or https://
    if (url_slice.len < 7) return false;
    return std.mem.startsWith(u8, url_slice, "http://") or std.mem.startsWith(u8, url_slice, "https://");
}

export fn e12_request_query_int(req: ?*CRequest, name: [*c]const u8, out_value: [*c]c_longlong) bool {
    if (req == null or name == null or out_value == null) return false;
    const request_ptr = req.?.request;
    const value_str = request_ptr.query(std.mem.span(name)) catch return false;
    const value = value_str orelse return false;
    const parsed = std.fmt.parseInt(i64, value, 10) catch return false;
    out_value.* = parsed;
    return true;
}

export fn e12_request_query_double(req: ?*CRequest, name: [*c]const u8, out_value: [*c]f64) bool {
    if (req == null or name == null or out_value == null) return false;
    const request_ptr = req.?.request;
    const value_str = request_ptr.query(std.mem.span(name)) catch return false;
    const value = value_str orelse return false;
    const parsed = std.fmt.parseFloat(f64, value) catch return false;
    out_value.* = parsed;
    return true;
}

export fn e12_request_param_int(req: ?*CRequest, name: [*c]const u8, out_value: [*c]c_longlong) bool {
    if (req == null or name == null or out_value == null) return false;
    const request_ptr = req.?.request;
    const value_str = request_ptr.route_params.get(std.mem.span(name)) orelse return false;
    const parsed = std.fmt.parseInt(i64, value_str, 10) catch return false;
    out_value.* = parsed;
    return true;
}

export fn e12_request_param_double(req: ?*CRequest, name: [*c]const u8, out_value: [*c]f64) bool {
    if (req == null or name == null or out_value == null) return false;
    const request_ptr = req.?.request;
    const value_str = request_ptr.route_params.get(std.mem.span(name)) orelse return false;
    const parsed = std.fmt.parseFloat(f64, value_str) catch return false;
    out_value.* = parsed;
    return true;
}

// ============================================================================
// Error Handling
// ============================================================================

export fn e12_register_error_handler(app: ?*CEngine12Handle, handler: ?*const fn (c_int, *anyopaque) ?*CResponse, user_data: *anyopaque) c_int {
    clearLastError();

    if (app == null or handler == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1;
    };

    // Store handler in app-specific registry
    initErrorHandlerRegistry();
    const app_ptr = @intFromPtr(c_app);
    error_handler_registry_mutex.lock();
    defer error_handler_registry_mutex.unlock();
    error_handler_registry.put(app_ptr, .{
        .handler = handler.?,
        .user_data = user_data,
    }) catch {};

    const handler_wrapper = struct {
        fn wrap(req: *Request, err: error_handler.ErrorResponse, alloc: std.mem.Allocator) Response {
            // Get app from request registry
            const app_for_req = getAppForRequest(req) orelse {
                return err.toHttpResponse(alloc) catch Response.status(500);
            };
            const app_ptr_val = @intFromPtr(app_for_req);
            initErrorHandlerRegistry();
            error_handler_registry_mutex.lock();
            defer error_handler_registry_mutex.unlock();
            const entry = error_handler_registry.get(app_ptr_val) orelse {
                return err.toHttpResponse(alloc) catch Response.status(500);
            };

            // Convert error response to error code
            const error_code: c_int = switch (err.error_type) {
                .validation_error, .bad_request => 1,
                .authentication_error => 1,
                .authorization_error => 1,
                .not_found => 1,
                .rate_limit_exceeded => 1,
                .request_too_large => 1,
                .timeout => 1,
                .internal_error, .unknown => 99,
            };

            // Call C handler
            const c_resp = entry.handler(error_code, entry.user_data);
            if (c_resp) |resp| {
                return resp.response;
            }
            // Fallback to default error response
            return err.toHttpResponse(alloc) catch Response.status(500);
        }
    }.wrap;

    c_app.engine.useErrorHandler(handler_wrapper);

    return 0;
}

// ============================================================================
// Health Status
// ============================================================================

export fn e12_get_system_health(app: ?*CEngine12Handle) c_int {
    if (app == null) return 2; // E12_HEALTH_UNHEALTHY
    const c_app = getCEngine12(app.?) orelse return 2;
    const health = c_app.engine.getSystemHealth();
    return switch (health) {
        .healthy => 0,
        .degraded => 1,
        .unhealthy => 2,
    };
}

// ============================================================================
// Valve System
// ============================================================================

pub const CValveContext = struct {
    context: *valve_context,
};

pub const CValve = struct {
    valve: valve_mod.Valve,
    c_user_data: *anyopaque,
    c_init_fn: *const fn (*CValveContext, *anyopaque) c_int,
    c_deinit_fn: *const fn (*anyopaque) void,
    c_on_app_start_fn: ?*const fn (*CValveContext, *anyopaque) c_int,
    c_on_app_stop_fn: ?*const fn (*CValveContext, *anyopaque) void,
};

// Map valve pointers to CValve data
var valve_map: std.AutoHashMap(*valve_mod.Valve, *CValve) = undefined;
var valve_map_init = false;
var valve_map_mutex: std.Thread.Mutex = std.Thread.Mutex{};

fn initValveMap() void {
    if (!valve_map_init) {
        valve_map = std.AutoHashMap(*valve_mod.Valve, *CValve).init(allocator);
        valve_map_init = true;
    }
}

fn convertCapability(cap: E12ValveCapability) valve_mod.ValveCapability {
    return switch (@intFromEnum(cap)) {
        0 => .routes,
        1 => .middleware,
        2 => .background_tasks,
        3 => .health_checks,
        4 => .static_files,
        5 => .websockets,
        6 => .database_access,
        7 => .cache_access,
        8 => .metrics_access,
        else => .routes,
    };
}

export fn e12_register_valve(app: ?*CEngine12Handle, valve_ptr: [*c]const E12Valve) c_int {
    clearLastError();

    if (app == null or valve_ptr == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1;
    };

    const c_valve = valve_ptr.*;

    // Validate metadata
    if (c_valve.metadata.name == null or c_valve.metadata.version == null) {
        setLastError("Invalid valve metadata");
        return 1;
    }

    // Convert capabilities
    var capabilities = std.ArrayListUnmanaged(valve_mod.ValveCapability){};
    defer capabilities.deinit(allocator);

    var i: usize = 0;
    while (i < c_valve.metadata.capabilities_count) : (i += 1) {
        const cap = c_valve.metadata.capabilities[i];
        capabilities.append(allocator, convertCapability(cap)) catch {
            setLastError("Failed to allocate capabilities");
            return 4;
        };
    }

    // Create C valve wrapper
    const zig_valve = allocator.create(CValve) catch {
        setLastError("Allocation failed");
        return 4;
    };

    zig_valve.* = CValve{
        .valve = valve_mod.Valve{
            .metadata = valve_mod.ValveMetadata{
                .name = std.mem.span(c_valve.metadata.name),
                .version = std.mem.span(c_valve.metadata.version),
                .description = if (c_valve.metadata.description != null) std.mem.span(c_valve.metadata.description.?) else "",
                .author = "", // C API doesn't provide author field
                .required_capabilities = capabilities.toOwnedSlice(allocator) catch {
                    setLastError("Failed to allocate capabilities slice");
                    return 4;
                },
            },
            .init = valveInitWrapper,
            .deinit = valveDeinitWrapper,
            .onAppStart = if (c_valve.onAppStart) |_| valveOnAppStartWrapper else null,
            .onAppStop = if (c_valve.onAppStop) |_| valveOnAppStopWrapper else null,
        },
        .c_user_data = c_valve.user_data,
        .c_init_fn = @as(E12ValveInitFn, @ptrCast(@alignCast(c_valve.init))),
        .c_deinit_fn = @as(E12ValveDeinitFn, @ptrCast(@alignCast(c_valve.deinit))),
        .c_on_app_start_fn = if (c_valve.onAppStart) |ptr| @as(E12ValveOnAppStartFn, @ptrCast(@alignCast(ptr))) else null,
        .c_on_app_stop_fn = if (c_valve.onAppStop) |ptr| @as(E12ValveOnAppStopFn, @ptrCast(@alignCast(ptr))) else null,
    };

    // Store valve in map
    initValveMap();
    valve_map_mutex.lock();
    defer valve_map_mutex.unlock();
    valve_map.put(&zig_valve.valve, zig_valve) catch {
        setLastError("Failed to store valve");
        return 99;
    };

    // Register valve
    c_app.engine.registerValve(&zig_valve.valve) catch |err| {
        _ = valve_map.remove(&zig_valve.valve);
        setLastError(@errorName(err));
        return switch (err) {
            valve_mod.ValveError.ValveAlreadyRegistered => 9,
            RegistryError.TooManyValves => 10,
            valve_mod.ValveError.CapabilityRequired => 11,
            else => 99,
        };
    };

    return 0;
}

fn valveInitWrapper(v: *valve_mod.Valve, ctx: *valve_context) !void {
    initValveMap();
    valve_map_mutex.lock();
    defer valve_map_mutex.unlock();
    const c_valve = valve_map.get(v) orelse return error.UnknownError;

    const c_ctx = allocator.create(CValveContext) catch return error.OutOfMemory;
    defer allocator.destroy(c_ctx);
    c_ctx.* = CValveContext{ .context = ctx };
    const result = c_valve.c_init_fn(c_ctx, c_valve.c_user_data);
    if (result != 0) {
        return error.UnknownError;
    }
}

fn valveDeinitWrapper(v: *valve_mod.Valve) void {
    initValveMap();
    valve_map_mutex.lock();
    defer valve_map_mutex.unlock();
    const c_valve = valve_map.get(v) orelse return;
    c_valve.c_deinit_fn(c_valve.c_user_data);
    _ = valve_map.remove(v);
}

fn valveOnAppStartWrapper(v: *valve_mod.Valve, ctx: *valve_context) !void {
    initValveMap();
    valve_map_mutex.lock();
    defer valve_map_mutex.unlock();
    const c_valve = valve_map.get(v) orelse return error.UnknownError;

    if (c_valve.c_on_app_start_fn) |fn_ptr| {
        const c_ctx = allocator.create(CValveContext) catch return error.OutOfMemory;
        defer allocator.destroy(c_ctx);
        c_ctx.* = CValveContext{ .context = ctx };
        const result = fn_ptr(c_ctx, c_valve.c_user_data);
        if (result != 0) {
            return error.UnknownError;
        }
    }
}

fn valveOnAppStopWrapper(v: *valve_mod.Valve, ctx: *valve_context) void {
    initValveMap();
    valve_map_mutex.lock();
    defer valve_map_mutex.unlock();
    const c_valve = valve_map.get(v) orelse return;

    if (c_valve.c_on_app_stop_fn) |fn_ptr| {
        const c_ctx = allocator.create(CValveContext) catch return;
        defer allocator.destroy(c_ctx);
        c_ctx.* = CValveContext{ .context = ctx };
        fn_ptr(c_ctx, c_valve.c_user_data);
    }
}

export fn e12_unregister_valve(app: ?*CEngine12Handle, name: [*c]const u8) c_int {
    clearLastError();

    if (app == null or name == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1;
    };

    const name_slice = std.mem.span(name);
    c_app.engine.unregisterValve(name_slice) catch |err| {
        setLastError(@errorName(err));
        return switch (err) {
            valve_mod.ValveError.ValveNotFound => 8,
            else => 99,
        };
    };

    return 0;
}

export fn e12_get_valve_names(app: ?*CEngine12Handle, out_names: [*c][*c][*c]u8, out_count: [*c]usize) c_int {
    clearLastError();

    if (app == null or out_names == null or out_count == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid engine12 instance");
        return 1;
    };

    const registry = c_app.engine.getValveRegistry() orelse {
        out_names.* = null;
        out_count.* = 0;
        return 0;
    };

    const names = registry.getValveNames(allocator) catch {
        setLastError("Failed to get valve names");
        return 99;
    };
    defer allocator.free(names);

    if (names.len == 0) {
        out_names.* = null;
        out_count.* = 0;
        return 0;
    }

    // Allocate array of C string pointers
    const c_names = allocator.alloc([*c]u8, names.len) catch {
        setLastError("Allocation failed");
        return 4;
    };

    // Duplicate each name string
    for (names, 0..) |name, i| {
        const duped = allocator.dupeZ(u8, name) catch {
            // Free already allocated strings
            var j: usize = 0;
            while (j < i) : (j += 1) {
                var len: usize = 0;
                while (c_names[j][len] != 0) : (len += 1) {}
                allocator.free(c_names[j][0..len :0]);
            }
            allocator.free(c_names);
            setLastError("Allocation failed");
            return 4;
        };
        c_names[i] = duped.ptr;
    }

    out_names.* = c_names.ptr;
    out_count.* = names.len;
    return 0;
}

export fn e12_free_valve_names(names: [*c][*c]u8, count: usize) void {
    if (names == null) return;
    // Free each string (they are null-terminated, find length)
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (names[i]) |str| {
            var len: usize = 0;
            while (str[len] != 0) : (len += 1) {}
            allocator.free(str[0..len :0]);
        }
    }
    // Free the array
    allocator.free(names[0..count]);
}

// Valve Context API

export fn e12_valve_context_register_route(ctx: ?*CValveContext, method: [*c]const u8, path: [*c]const u8, handler: ?*const fn (*CRequest, *anyopaque) *CResponse, user_data: *anyopaque) c_int {
    clearLastError();

    if (ctx == null or method == null or path == null or handler == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const handler_id = registerHandler(handler.?);
    const method_slice = std.mem.span(method);
    const path_slice = std.mem.span(path);

    // Register handler data keyed by method+path
    registerRouteHandlerData(method_slice, path_slice, handler_id, user_data) catch |err| {
        setLastError(@errorName(err));
        return 99;
    };

    // Use the single wrapper function that looks up handler data by method+path
    const wrapper_handler = cValveRouteWrapper;

    ctx.?.context.registerRoute(method_slice, path_slice, wrapper_handler) catch |err| {
        setLastError(@errorName(err));
        return switch (err) {
            valve_mod.ValveError.CapabilityRequired => 7,
            valve_mod.ValveError.InvalidMethod => 1,
            else => 99,
        };
    };

    return 0;
}

export fn e12_valve_context_register_middleware(ctx: ?*CValveContext, middleware_fn: ?E12PreRequestMiddlewareFn, user_data: *anyopaque) c_int {
    clearLastError();

    if (ctx == null or middleware_fn == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const middleware_id = registerPreRequestMiddleware(middleware_fn.?, user_data) catch {
        setLastError("Failed to register middleware");
        return 99;
    };

    const wrapper = switch (middleware_id) {
        0 => makePreRequestWrapper(0),
        1 => makePreRequestWrapper(1),
        2 => makePreRequestWrapper(2),
        3 => makePreRequestWrapper(3),
        4 => makePreRequestWrapper(4),
        5 => makePreRequestWrapper(5),
        6 => makePreRequestWrapper(6),
        7 => makePreRequestWrapper(7),
        8 => makePreRequestWrapper(8),
        9 => makePreRequestWrapper(9),
        10 => makePreRequestWrapper(10),
        11 => makePreRequestWrapper(11),
        12 => makePreRequestWrapper(12),
        13 => makePreRequestWrapper(13),
        14 => makePreRequestWrapper(14),
        15 => makePreRequestWrapper(15),
        else => {
            setLastError("Too many middleware");
            return 2;
        },
    };

    ctx.?.context.registerMiddleware(wrapper) catch |err| {
        setLastError(@errorName(err));
        return switch (err) {
            valve_mod.ValveError.CapabilityRequired => 7,
            else => 99,
        };
    };

    return 0;
}

export fn e12_valve_context_register_response_middleware(ctx: ?*CValveContext, middleware_fn: ?E12ResponseMiddlewareFn, user_data: *anyopaque) c_int {
    clearLastError();

    if (ctx == null or middleware_fn == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const middleware_id = registerResponseMiddleware(middleware_fn.?, user_data) catch {
        setLastError("Failed to register middleware");
        return 99;
    };

    const wrapper = switch (middleware_id) {
        0 => makeResponseWrapper(0),
        1 => makeResponseWrapper(1),
        2 => makeResponseWrapper(2),
        3 => makeResponseWrapper(3),
        4 => makeResponseWrapper(4),
        5 => makeResponseWrapper(5),
        6 => makeResponseWrapper(6),
        7 => makeResponseWrapper(7),
        8 => makeResponseWrapper(8),
        9 => makeResponseWrapper(9),
        10 => makeResponseWrapper(10),
        11 => makeResponseWrapper(11),
        12 => makeResponseWrapper(12),
        13 => makeResponseWrapper(13),
        14 => makeResponseWrapper(14),
        15 => makeResponseWrapper(15),
        else => {
            setLastError("Too many middleware");
            return 2;
        },
    };

    ctx.?.context.registerResponseMiddleware(wrapper) catch |err| {
        setLastError(@errorName(err));
        return switch (err) {
            valve_mod.ValveError.CapabilityRequired => 7,
            else => 99,
        };
    };

    return 0;
}

export fn e12_valve_context_register_task(ctx: ?*CValveContext, name: [*c]const u8, task: ?E12BackgroundTaskFn, interval_ms: c_uint, user_data: *anyopaque) c_int {
    clearLastError();

    if (ctx == null or name == null or task == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const name_slice = std.mem.span(name);
    const task_id = registerTaskWrapper(task.?, user_data);

    const wrapper_fn = getTaskWrapper(task_id);

    ctx.?.context.registerTask(name_slice, wrapper_fn, if (interval_ms == 0) null else interval_ms) catch |err| {
        setLastError(@errorName(err));
        return switch (err) {
            valve_mod.ValveError.CapabilityRequired => 7,
            else => 99,
        };
    };

    return 0;
}

fn registerTaskWrapper(task_fn: E12BackgroundTaskFn, user_data: *anyopaque) usize {
    task_registry_mutex.lock();
    defer task_registry_mutex.unlock();

    if (task_registry_next_id >= MAX_TASK_ENTRIES) {
        return 0; // Fallback
    }

    const task_id = task_registry_next_id;
    task_registry_next_id += 1;

    // Store function pointer directly in registry
    task_registry[task_id] = .{
        .task_fn = task_fn,
        .user_data = user_data,
    };

    return task_id;
}

export fn e12_valve_context_register_health_check(ctx: ?*CValveContext, check: ?E12HealthCheckFn, user_data: *anyopaque) c_int {
    clearLastError();

    if (ctx == null or check == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const check_id = registerHealthCheckWrapper(check.?, user_data);
    const wrapper_fn = getHealthCheckWrapper(check_id);

    ctx.?.context.registerHealthCheck(wrapper_fn) catch |err| {
        setLastError(@errorName(err));
        return switch (err) {
            valve_mod.ValveError.CapabilityRequired => 7,
            else => 99,
        };
    };

    return 0;
}

fn registerHealthCheckWrapper(check_fn: E12HealthCheckFn, user_data: *anyopaque) usize {
    health_check_registry_mutex.lock();
    defer health_check_registry_mutex.unlock();

    if (health_check_registry_next_id >= MAX_HEALTH_CHECK_ENTRIES) {
        return 0;
    }

    const check_id = health_check_registry_next_id;
    health_check_registry_next_id += 1;

    // Store function pointer directly in registry
    health_check_registry[check_id] = .{
        .check_fn = check_fn,
        .user_data = user_data,
    };

    return check_id;
}

export fn e12_valve_context_serve_static(ctx: ?*CValveContext, mount_path: [*c]const u8, directory: [*c]const u8) c_int {
    clearLastError();

    if (ctx == null or mount_path == null or directory == null) {
        setLastError("Invalid arguments");
        return 1;
    }

    const mount_path_slice = std.mem.span(mount_path);
    const directory_slice = std.mem.span(directory);

    ctx.?.context.serveStatic(mount_path_slice, directory_slice) catch |err| {
        setLastError(@errorName(err));
        return switch (err) {
            valve_mod.ValveError.CapabilityRequired => 7,
            else => 99,
        };
    };

    return 0;
}

export fn e12_valve_context_get_cache(ctx: ?*CValveContext) ?*CCache {
    if (ctx == null) return null;
    const cache_ptr = ctx.?.context.getCache() orelse return null;

    const c_cache = allocator.create(CCache) catch return null;
    c_cache.* = CCache{ .cache = cache_ptr.* };
    return @ptrCast(c_cache);
}

export fn e12_valve_context_get_metrics(ctx: ?*CValveContext) ?*anyopaque {
    if (ctx == null) return null;
    const metrics_ptr = ctx.?.context.getMetrics() orelse return null;
    return @ptrCast(metrics_ptr);
}
