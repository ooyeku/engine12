const std = @import("std");
const c = @cImport({
    @cInclude("stdint.h");
    @cInclude("stdbool.h");
    @cInclude("string.h");
});
const Engine12 = @import("Engine12").Engine12;
const Request = @import("Engine12").Request;
const Response = @import("Engine12").Response;
const types = @import("Engine12").types;
const router = @import("Engine12").router;
const middleware = @import("Engine12").middleware;
const ziggurat = @import("ziggurat");

const allocator = std.heap.page_allocator;

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

fn initHandlerRegistry() void {
    if (!handler_registry_init) {
        handler_registry = std.AutoHashMap(usize, *const fn (*CRequest, *anyopaque) *CResponse).init(allocator);
        handler_registry_init = true;
    }
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
// This runs before Engine12's routing, so it can handle C API routes
fn createCRouterMiddleware(app_ptr: *CEngine12) middleware.PreRequestMiddlewareFn {
    // Store app pointer in registry keyed by Engine12 instance
    setAppPtrForEngine(&app_ptr.engine, app_ptr);

    // Create middleware function that gets app from registry
    const middlewareFn = struct {
        fn handler(req: *Request) middleware.MiddlewareResult {
            // Get app from registry - try engine-based registry first
            app_ptr_registry_mutex.lock();
            defer app_ptr_registry_mutex.unlock();

            var iterator = app_ptr_registry.iterator();
            const app_entry = iterator.next() orelse {
                // No app found in registry - let Engine12 handle it
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
                    const mw = @import("Engine12").middleware;
                    mw.storeCAPIResponse(req, resp) catch {
                        allocator.destroy(c_req);
                        return .abort;
                    };

                    allocator.destroy(c_req);

                    // Mark that we handled this request
                    req.context.put("c_api_handled", "true") catch {};
                    return .abort; // Abort to prevent Engine12 routing
                }
            }

            // No route matched - let Engine12 handle it
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
        setLastError("Invalid Engine12 instance");
        return 1; // E12_ERROR_INVALID_ARGUMENT
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid Engine12 instance");
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
        setLastError("Invalid Engine12 instance");
        return 1;
    }

    const c_app = getCEngine12(app.?) orelse {
        setLastError("Invalid Engine12 instance");
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
// Since Engine12 requires comptime paths, we register each route individually
// with a wrapper handler that dispatches to the C handler
fn registerCRoute(
    app: *CEngine12,
    method: []const u8,
    path: []const u8,
    handler_id: usize,
    user_data: *anyopaque,
) !void {
    // Build server if not already built (same as Engine12.get/post/etc)
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
        setLastError("Invalid Engine12 instance");
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
        setLastError("Invalid Engine12 instance");
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
        setLastError("Invalid Engine12 instance");
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
        setLastError("Invalid Engine12 instance");
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
        setLastError("Invalid Engine12 instance");
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
        setLastError("Invalid Engine12 instance");
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
        setLastError("Invalid Engine12 instance");
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
        setLastError("Invalid Engine12 instance");
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
        setLastError("Invalid Engine12 instance");
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
