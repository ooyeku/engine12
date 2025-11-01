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

fn getCEngine12(handle: *CEngine12Handle) *CEngine12 {
    initHandleStorage();
    handle_storage_mutex.lock();
    defer handle_storage_mutex.unlock();
    return handle_storage.get(handle).?;
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

    pub fn deinit(self: *CRequest) void {
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
                    c_req.* = CRequest{ .request = req };

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
        const c_app = getCEngine12(handle);
        c_app.deinit();
        removeCEngine12(handle);
        const u8_ptr: *u8 = @ptrCast(handle);
        allocator.destroy(u8_ptr);
    }
}

export fn e12_start(app: ?*CEngine12Handle) c_int {
    clearLastError();

    if (app == null) {
        setLastError("Invalid Engine12 instance");
        return 1; // E12_ERROR_INVALID_ARGUMENT
    }

    const c_app = getCEngine12(app.?);
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

    const c_app = getCEngine12(app.?);
    c_app.engine.stop() catch |err| {
        setLastError(@errorName(err));
        return 99; // E12_ERROR_UNKNOWN
    };

    return 0;
}

export fn e12_is_running(app: ?*CEngine12Handle) bool {
    if (app == null) return false;
    const c_app = getCEngine12(app.?);
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
                    c_req.* = CRequest{ .request = &req };

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

    const c_app = getCEngine12(app.?);
    const path_slice = std.mem.span(path);
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

    const c_app = getCEngine12(app.?);
    const path_slice = std.mem.span(path);
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

    const c_app = getCEngine12(app.?);
    const path_slice = std.mem.span(path);
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

    const c_app = getCEngine12(app.?);
    const path_slice = std.mem.span(path);
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
    const request_ptr = req.?.request;
    const path = request_ptr.path();
    // Need to ensure string is null-terminated and persists
    const path_copy = allocator.dupeZ(u8, path) catch return null;
    return path_copy.ptr;
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

export fn e12_request_param(req: ?*CRequest, name: [*c]const u8) [*c]const u8 {
    if (req == null or name == null) return null;
    const name_slice = std.mem.span(name);
    const request_ptr = req.?.request;
    const value = request_ptr.route_params.get(name_slice) orelse return null;
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
    return value.ptr;
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
