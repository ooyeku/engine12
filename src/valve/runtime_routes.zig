const std = @import("std");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const router = @import("../router.zig");
const types = @import("../types.zig");

/// Runtime route entry stored in the registry
pub const RuntimeRoute = struct {
    /// HTTP method (GET, POST, etc.)
    method: []const u8,
    /// Route pattern (e.g., "/todos/:id")
    path_pattern: []const u8,
    /// Parsed route pattern for matching
    pattern: router.RoutePattern,
    /// Handler function pointer
    handler: *const fn (*Request) Response,
    /// Valve name that registered this route (for tracking)
    valve_name: []const u8,

    /// Clean up allocated memory
    pub fn deinit(self: *RuntimeRoute, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.path_pattern);
        var mutable_pattern = self.pattern;
        mutable_pattern.deinit(allocator);
        allocator.free(self.valve_name);
    }
};

/// Registry for runtime routes registered by valves
/// Thread-safe with mutex protection
pub const RuntimeRouteRegistry = struct {
    /// Routes stored by method+path key
    routes: std.StringHashMap(RuntimeRoute),
    /// Mutex for thread-safe access
    mutex: std.Thread.Mutex,
    /// Allocator for route storage
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new runtime route registry
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .routes = std.StringHashMap(RuntimeRoute).init(allocator),
            .mutex = .{},
            .allocator = allocator,
        };
    }

    /// Generate a key for method+path lookup
    fn makeKey(allocator: std.mem.Allocator, method: []const u8, path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ method, path });
    }

    /// Register a runtime route
    /// Returns error if route already exists or pattern is invalid
    pub fn register(
        self: *Self,
        method: []const u8,
        path: []const u8,
        handler: *const fn (*Request) Response,
        valve_name: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Parse route pattern
        var pattern = try router.RoutePattern.parse(self.allocator, path);
        errdefer pattern.deinit(self.allocator);

        // Create key
        const key = try makeKey(self.allocator, method, path);
        errdefer self.allocator.free(key);

        // Check if route already exists
        if (self.routes.contains(key)) {
            // Don't free key or pattern here - errdefer will handle both
            return error.RouteAlreadyExists;
        }

        // Duplicate strings for storage
        const method_copy = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(method_copy);

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        const valve_name_copy = try self.allocator.dupe(u8, valve_name);
        errdefer self.allocator.free(valve_name_copy);

        // Store route
        try self.routes.put(key, RuntimeRoute{
            .method = method_copy,
            .path_pattern = path_copy,
            .pattern = pattern,
            .handler = handler,
            .valve_name = valve_name_copy,
        });
    }

    /// Find a route matching the given method and path
    /// Returns the route if found, null otherwise
    /// Extracts route parameters into the request
    pub fn findRoute(
        self: *Self,
        method: []const u8,
        path: []const u8,
        request: *Request,
    ) !?*RuntimeRoute {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iterator = self.routes.iterator();
        while (iterator.next()) |*entry| {
            const route = entry.value_ptr;

            // Check method matches
            if (!std.mem.eql(u8, route.method, method)) continue;

            // Check exact path match first
            if (std.mem.eql(u8, route.path_pattern, path)) {
                return route;
            }

            // Try pattern matching
            var mutable_pattern = route.pattern;
            if (try mutable_pattern.match(request.arena.allocator(), path)) |params| {
                // Extract route parameters into request
                var param_iter = params.iterator();
                while (param_iter.next()) |*param_entry| {
                    try request.route_params.put(param_entry.key_ptr.*, param_entry.value_ptr.*);
                }
                return route;
            }
        }

        return null;
    }

    /// Unregister a route by method and path
    pub fn unregister(self: *Self, method: []const u8, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try makeKey(self.allocator, method, path);
        defer self.allocator.free(key);

        if (self.routes.fetchRemove(key)) |entry| {
            // Free the key that was stored in the map
            self.allocator.free(entry.key);
            var mutable_value = entry.value;
            mutable_value.deinit(self.allocator);
        } else {
            return error.RouteNotFound;
        }
    }

    /// Get all routes registered by a specific valve
    pub fn getValveRoutes(self: *Self, valve_name: []const u8, allocator: std.mem.Allocator) ![]RuntimeRoute {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayListUnmanaged(RuntimeRoute){};
        var iterator = self.routes.iterator();
        while (iterator.next()) |*entry| {
            if (std.mem.eql(u8, entry.value_ptr.*.valve_name, valve_name)) {
                try result.append(allocator, entry.value_ptr.*);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    /// Clean up all routes and deinitialize registry
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iterator = self.routes.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.routes.deinit();
    }
};

// Tests
test "RuntimeRouteRegistry init and deinit" {
    var registry = RuntimeRouteRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try std.testing.expectEqual(registry.routes.count(), 0);
}

test "RuntimeRouteRegistry register and find exact match" {
    var registry = RuntimeRouteRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const handler = struct {
        fn handle(_: *Request) Response {
            return Response.text("test");
        }
    }.handle;

    try registry.register("GET", "/test", &handler, "test_valve");

    // Create a minimal request for testing
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var route_params = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer route_params.deinit();

    var req = Request{
        .inner = undefined, // Not used in findRoute
        .arena = arena,
        .context = std.StringHashMap([]const u8).init(std.testing.allocator),
        .route_params = route_params,
        ._query_params = null,
    };
    defer req.context.deinit();

    const route = try registry.findRoute("GET", "/test", &req);
    try std.testing.expect(route != null);
    if (route) |r| {
        try std.testing.expectEqualStrings(r.method, "GET");
        try std.testing.expectEqualStrings(r.path_pattern, "/test");
        try std.testing.expectEqualStrings(r.valve_name, "test_valve");
    }
}

test "RuntimeRouteRegistry register and find pattern match" {
    var registry = RuntimeRouteRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const handler = struct {
        fn handle(_: *Request) Response {
            return Response.text("test");
        }
    }.handle;

    try registry.register("GET", "/todos/:id", &handler, "test_valve");

    // Create a minimal request for testing
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var route_params = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer route_params.deinit();

    var req = Request{
        .inner = undefined, // Not used in findRoute
        .arena = arena,
        .context = std.StringHashMap([]const u8).init(std.testing.allocator),
        .route_params = route_params,
        ._query_params = null,
    };
    defer req.deinit();

    const route = try registry.findRoute("GET", "/todos/123", &req);
    try std.testing.expect(route != null);
    if (route) |r| {
        try std.testing.expectEqualStrings(r.path_pattern, "/todos/:id");
        // Check that parameter was extracted
        const id = req.route_params.get("id");
        try std.testing.expect(id != null);
        if (id) |id_val| {
            try std.testing.expectEqualStrings(id_val, "123");
        }
    }
}

test "RuntimeRouteRegistry duplicate registration fails" {
    var registry = RuntimeRouteRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const handler = struct {
        fn handle(_: *Request) Response {
            return Response.text("test");
        }
    }.handle;

    try registry.register("GET", "/test", &handler, "test_valve");
    try std.testing.expectError(error.RouteAlreadyExists, registry.register("GET", "/test", &handler, "test_valve"));
}

test "RuntimeRouteRegistry unregister" {
    var registry = RuntimeRouteRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const handler = struct {
        fn handle(_: *Request) Response {
            return Response.text("test");
        }
    }.handle;

    try registry.register("GET", "/test", &handler, "test_valve");
    try std.testing.expectEqual(registry.routes.count(), 1);

    try registry.unregister("GET", "/test");
    try std.testing.expectEqual(registry.routes.count(), 0);
}
