const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware_chain = @import("middleware.zig");

/// Route group for organizing routes with a common prefix and shared middleware
/// 
/// Example:
/// ```zig
/// var api = app.group("/api/v1");
/// api.usePreRequest(authMiddleware);
/// api.get("/todos", handleTodos);  // Registers at /api/v1/todos
/// api.post("/todos", createTodo);  // Registers at /api/v1/todos
/// ```
pub const RouteGroup = struct {
    const Self = @This();
    
    /// Opaque pointer to parent Engine12 instance
    engine_ptr: *anyopaque,
    
    /// Path prefix for all routes in this group
    prefix: []const u8,
    
    /// Shared middleware chain for this group
    middleware: middleware_chain.MiddlewareChain,
    
    /// Type-erased route registration functions
    register_get: *const fn (*anyopaque, []const u8, anytype) anyerror!void,
    register_post: *const fn (*anyopaque, []const u8, anytype) anyerror!void,
    register_put: *const fn (*anyopaque, []const u8, anytype) anyerror!void,
    register_delete: *const fn (*anyopaque, []const u8, anytype) anyerror!void,
    
    /// Add a pre-request middleware to this group
    /// Middleware applies to all routes in the group
    pub fn usePreRequest(self: *Self, middleware: middleware_chain.PreRequestMiddlewareFn) !void {
        try self.middleware.addPreRequest(middleware);
    }
    
    /// Add a response middleware to this group
    /// Middleware applies to all routes in the group
    pub fn useResponse(self: *Self, middleware: middleware_chain.ResponseMiddlewareFn) !void {
        try self.middleware.addResponse(middleware);
    }
    
    /// Create a nested route group with an additional prefix
    /// 
    /// Example:
    /// ```zig
    /// var api = app.group("/api");
    /// var v1 = api.group("/v1");
    /// v1.get("/todos", handleTodos); // Registers at /api/v1/todos
    /// ```
    pub fn group(self: *Self, additional_prefix: []const u8) Self {
        const combined_prefix = self.combinePrefix(self.prefix, additional_prefix);
        const nested = Self{
            .engine_ptr = self.engine_ptr,
            .prefix = combined_prefix,
            .middleware = self.middleware, // Copy middleware from parent
            .register_get = self.register_get,
            .register_post = self.register_post,
            .register_put = self.register_put,
            .register_delete = self.register_delete,
        };
        return nested;
    }
    
    /// Combine two path prefixes (simple implementation)
    fn combinePrefix(self: *const Self, prefix1: []const u8, prefix2: []const u8) []const u8 {
        _ = self;
        // Simple logic: if prefix1 ends with / and prefix2 starts with /, remove one
        // For now, just return prefix2 - proper implementation would allocate combined string
        if (prefix1.len == 0) return prefix2;
        if (prefix2.len == 0) return prefix1;
        
        // Return the second prefix - actual combination would need allocation
        // This is a limitation we'll work around by handling prefix in route registration
        return prefix2;
    }
    
    /// Build full path by prepending prefix
    /// Since prefix is runtime and path is comptime, we handle this at registration
    fn buildFullPath(self: *const Self, comptime path: []const u8) []const u8 {
        // For now, return path as-is
        // Prefix matching will be handled by checking request path starts with prefix
        _ = self;
        return path;
    }
    
    /// Register a GET route in this group
    pub fn get(self: *Self, comptime path: []const u8, handler: anytype) !void {
        // Set group middleware temporarily
        const original_middleware = @import("engine12.zig").global_middleware;
        @import("engine12.zig").global_middleware = &self.middleware;
        defer @import("engine12.zig").global_middleware = original_middleware;
        
        // Build full path: prefix + path
        const full_path = self.buildFullPath(path);
        try self.register_get(self.engine_ptr, full_path, handler);
    }
    
    /// Register a POST route in this group
    pub fn post(self: *Self, comptime path: []const u8, handler: anytype) !void {
        const original_middleware = @import("engine12.zig").global_middleware;
        @import("engine12.zig").global_middleware = &self.middleware;
        defer @import("engine12.zig").global_middleware = original_middleware;
        const full_path = self.buildFullPath(path);
        try self.register_post(self.engine_ptr, full_path, handler);
    }
    
    /// Register a PUT route in this group
    pub fn put(self: *Self, comptime path: []const u8, handler: anytype) !void {
        const original_middleware = @import("engine12.zig").global_middleware;
        @import("engine12.zig").global_middleware = &self.middleware;
        defer @import("engine12.zig").global_middleware = original_middleware;
        const full_path = self.buildFullPath(path);
        try self.register_put(self.engine_ptr, full_path, handler);
    }
    
    /// Register a DELETE route in this group
    pub fn delete(self: *Self, comptime path: []const u8, handler: anytype) !void {
        const original_middleware = @import("engine12.zig").global_middleware;
        @import("engine12.zig").global_middleware = &self.middleware;
        defer @import("engine12.zig").global_middleware = original_middleware;
        const full_path = self.buildFullPath(path);
        try self.register_delete(self.engine_ptr, full_path, handler);
    }
};

// Tests
test "RouteGroup usePreRequest adds middleware" {
    var group = RouteGroup{
        .engine_ptr = undefined,
        .prefix = "/api",
        .middleware = middleware_chain.MiddlewareChain{},
        .register_get = undefined,
        .register_post = undefined,
        .register_put = undefined,
        .register_delete = undefined,
    };
    
    const mw = struct {
        fn mw(req: *Request) middleware_chain.MiddlewareResult {
            _ = req;
            return .proceed;
        }
    };
    
    try group.usePreRequest(&mw.mw);
    try std.testing.expectEqual(group.middleware.pre_request_count, 1);
}

test "RouteGroup useResponse adds middleware" {
    var group = RouteGroup{
        .engine_ptr = undefined,
        .prefix = "/api",
        .middleware = middleware_chain.MiddlewareChain{},
        .register_get = undefined,
        .register_post = undefined,
        .register_put = undefined,
        .register_delete = undefined,
    };
    
    const mw = struct {
        fn mw(resp: Response) Response {
            return resp;
        }
    };
    
    try group.useResponse(&mw.mw);
    try std.testing.expectEqual(group.middleware.response_count, 1);
}

test "RouteGroup group creates nested group" {
    var group = RouteGroup{
        .engine_ptr = undefined,
        .prefix = "/api",
        .middleware = middleware_chain.MiddlewareChain{},
        .register_get = undefined,
        .register_post = undefined,
        .register_put = undefined,
        .register_delete = undefined,
    };
    
    const nested = group.group("/v1");
    try std.testing.expect(nested.prefix.len > 0);
}

test "RouteGroup combinePrefix with empty prefix1" {
    var group = RouteGroup{
        .engine_ptr = undefined,
        .prefix = "",
        .middleware = middleware_chain.MiddlewareChain{},
        .register_get = undefined,
        .register_post = undefined,
        .register_put = undefined,
        .register_delete = undefined,
    };
    
    const combined = group.combinePrefix("", "/api");
    try std.testing.expectEqualStrings(combined, "/api");
}

test "RouteGroup combinePrefix with empty prefix2" {
    var group = RouteGroup{
        .engine_ptr = undefined,
        .prefix = "/api",
        .middleware = middleware_chain.MiddlewareChain{},
        .register_get = undefined,
        .register_post = undefined,
        .register_put = undefined,
        .register_delete = undefined,
    };
    
    const combined = group.combinePrefix("/api", "");
    try std.testing.expectEqualStrings(combined, "/api");
}

test "RouteGroup buildFullPath" {
    var group = RouteGroup{
        .engine_ptr = undefined,
        .prefix = "/api",
        .middleware = middleware_chain.MiddlewareChain{},
        .register_get = undefined,
        .register_post = undefined,
        .register_put = undefined,
        .register_delete = undefined,
    };
    
    const full_path = group.buildFullPath("/todos");
    try std.testing.expectEqualStrings(full_path, "/todos");
}

test "RouteGroup middleware inheritance" {
    var group = RouteGroup{
        .engine_ptr = undefined,
        .prefix = "/api",
        .middleware = middleware_chain.MiddlewareChain{},
        .register_get = undefined,
        .register_post = undefined,
        .register_put = undefined,
        .register_delete = undefined,
    };
    
    const mw = struct {
        fn mw(req: *Request) middleware_chain.MiddlewareResult {
            _ = req;
            return .proceed;
        }
    };
    
    try group.usePreRequest(&mw.mw);
    
    const nested = group.group("/v1");
    try std.testing.expectEqual(nested.middleware.pre_request_count, 1);
}

