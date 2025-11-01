const std = @import("std");
const ziggurat = @import("ziggurat");
const router = @import("router.zig");
const parsers = @import("parsers.zig");

/// Engine12 Request wrapper around ziggurat.request.Request
/// Provides a clean API that abstracts ziggurat implementation details
/// Each request gets its own arena allocator for memory-safe temporary allocations
pub const Request = struct {
    /// Internal pointer to ziggurat request (not exposed)
    inner: *ziggurat.request.Request,
    
    /// Arena allocator for this request - automatically freed when request completes
    /// Use this for all temporary allocations (query params, route params, parsed body, etc.)
    arena: std.heap.ArenaAllocator,
    
    /// Request context for storing per-request data (e.g., user_id, request_id)
    context: std.StringHashMap([]const u8),
    
    /// Route parameters extracted from URL path (e.g., from "/todos/:id")
    route_params: std.StringHashMap([]const u8),
    
    /// Parsed query parameters (lazy-loaded)
    _query_params: ?std.StringHashMap([]const u8) = null,

    /// Get the request path (without query string)
    pub fn path(self: *const Request) []const u8 {
        const full_path = self.inner.path;
        const query_start = std.mem.indexOfScalar(u8, full_path, '?') orelse return full_path;
        return full_path[0..query_start];
    }
    
    /// Get the full request path including query string
    pub fn fullPath(self: *const Request) []const u8 {
        return self.inner.path;
    }

    /// Get the HTTP method as a string
    pub fn method(self: *const Request) []const u8 {
        return @tagName(self.inner.method);
    }

    /// Get the request body
    pub fn body(self: *const Request) []const u8 {
        return self.inner.body;
    }

    /// Get the arena allocator for this request
    /// All allocations using this allocator are automatically freed when the request completes
    /// 
    /// Example:
    /// ```zig
    /// const query = try self.allocator().dupe(u8, "some string");
    /// // query will be automatically freed when request completes
    /// ```
    pub fn allocator(self: *Request) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Get a header value by name (returns null if not found)
    pub fn header(self: *const Request, _: []const u8) ?[]const u8 {
        // ziggurat may not expose headers directly, so we'll need to check
        // For now, return null as a placeholder
        _ = self;
        return null;
    }

    /// Parse and get query parameters
    /// Returns a hashmap of key-value pairs
    /// Results are cached after first parse
    /// 
    /// Example:
    /// ```zig
    /// const params = try req.queryParams();
    /// const limit = params.get("limit");
    /// ```
    pub fn queryParams(self: *Request) !std.StringHashMap([]const u8) {
        if (self._query_params) |*params| {
            return params.*;
        }
        
        const params = try parsers.QueryParser.parse(self.arena.allocator(), self.inner.path);
        self._query_params = params;
        return params;
    }
    
    /// Get a query parameter by name
    /// Returns null if not found
    /// 
    /// Example:
    /// ```zig
    /// const limit = try req.query("limit");
    /// const limit_u32 = if (limit) |l| try std.fmt.parseInt(u32, l, 10) else 10;
    /// ```
    pub fn query(self: *Request, name: []const u8) !?[]const u8 {
        const params = try self.queryParams();
        return params.get(name);
    }
    
    /// Get a query parameter as a Param wrapper (for type-safe conversion)
    /// 
    /// Example:
    /// ```zig
    /// const limit = try req.queryParam("limit").asU32Default(10);
    /// ```
    pub fn queryParam(self: *Request, name: []const u8) !router.Param {
        const value = (try self.query(name)) orelse "";
        return router.Param{ .value = value };
    }
    
    /// Parse request body as JSON
    /// Returns an error if parsing fails
    /// 
    /// Example:
    /// ```zig
    /// const Todo = struct { title: []const u8, completed: bool };
    /// const todo = try req.jsonBody(Todo);
    /// ```
    pub fn jsonBody(self: *Request, comptime T: type) !T {
        return parsers.BodyParser.json(T, self.body(), self.arena.allocator());
    }
    
    /// Parse request body as URL-encoded form data
    /// Returns a hashmap of key-value pairs
    /// 
    /// Example:
    /// ```zig
    /// const form = try req.formBody();
    /// const title = form.get("title");
    /// ```
    pub fn formBody(self: *Request) !std.StringHashMap([]const u8) {
        return parsers.BodyParser.formData(self.arena.allocator(), self.body());
    }
    
    /// Get a route parameter by name
    /// Returns a Param wrapper that provides type-safe conversion methods
    /// 
    /// Example:
    /// ```zig
    /// const id = try req.param("id").asU32();
    /// const limit = req.param("limit").asU32Default(10);
    /// ```
    pub fn param(self: *const Request, name: []const u8) router.Param {
        const value = self.route_params.get(name) orelse "";
        return router.Param{ .value = value };
    }
    
    /// Store a value in the request context
    /// The key will be duplicated in the request arena
    /// Example: req.set("user_id", "123")
    pub fn set(self: *Request, key: []const u8, value: []const u8) !void {
        const key_dup = try self.arena.allocator().dupe(u8, key);
        const value_dup = try self.arena.allocator().dupe(u8, value);
        try self.context.put(key_dup, value_dup);
    }
    
    /// Get a value from the request context
    /// Returns null if key not found
    /// Example: const user_id = req.get("user_id");
    pub fn get(self: *const Request, key: []const u8) ?[]const u8 {
        return self.context.get(key);
    }
    
    /// Set route parameters (internal use - called by router)
    /// Duplicates all param keys and values into the request's arena allocator
    pub fn setRouteParams(self: *Request, params: std.StringHashMap([]const u8)) !void {
        // Clear existing params
        self.route_params.deinit();
        
        // Reinitialize with the request's arena allocator
        self.route_params = std.StringHashMap([]const u8).init(self.arena.allocator());
        
        // Duplicate all keys and values into the request's arena
        var it = params.iterator();
        while (it.next()) |entry| {
            const key_dup = try self.arena.allocator().dupe(u8, entry.key_ptr.*);
            const value_dup = try self.arena.allocator().dupe(u8, entry.value_ptr.*);
            try self.route_params.put(key_dup, value_dup);
        }
    }

    /// Create a Request wrapper from a ziggurat request with a new arena allocator
    /// The arena is initialized with the provided backing allocator
    /// Caller must ensure cleanup happens (typically done automatically by wrapHandler)
    pub fn fromZiggurat(ziggurat_request: *ziggurat.request.Request, backing_allocator: std.mem.Allocator) Request {
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        const context = std.StringHashMap([]const u8).init(arena.allocator());
        const route_params = std.StringHashMap([]const u8).init(arena.allocator());
        
        return Request{
            .inner = ziggurat_request,
            .arena = arena,
            .context = context,
            .route_params = route_params,
            ._query_params = null,
        };
    }
    
    /// Clean up the request arena and all associated allocations
    /// This should be called automatically when the request completes
    pub fn deinit(self: *Request) void {
        self.context.deinit();
        self.route_params.deinit();
        if (self._query_params) |*params| {
            params.deinit();
        }
        self.arena.deinit();
    }
};

// Tests
test "Request path access" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    try std.testing.expectEqualStrings(req.path(), "/api/test");
}

test "Request method access" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test",
        .method = .POST,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    try std.testing.expectEqualStrings(req.method(), "POST");
}

test "Request body access" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test",
        .method = .POST,
        .body = "{\"test\":\"data\"}",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    try std.testing.expectEqualStrings(req.body(), "{\"test\":\"data\"}");
}

test "Request allocator provides arena" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const allocator = req.allocator();
    const data = try allocator.dupe(u8, "test string");
    // Memory will be freed when req.deinit() is called
    try std.testing.expectEqualStrings(data, "test string");
}

test "Request context set and get" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    try req.set("user_id", "12345");
    const user_id = req.get("user_id");
    try std.testing.expect(user_id != null);
    try std.testing.expectEqualStrings(user_id.?, "12345");
    
    const missing = req.get("nonexistent");
    try std.testing.expect(missing == null);
}

test "Request arena automatically cleans up allocations" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test",
        .method = .GET,
        .body = "",
    };
    
    // Use a test allocator to detect leaks
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    {
        var req = Request.fromZiggurat(&ziggurat_req, gpa.allocator());
        const allocator = req.allocator();
        
        // Allocate multiple strings
        _ = try allocator.dupe(u8, "test1");
        _ = try allocator.dupe(u8, "test2");
        _ = try allocator.dupe(u8, "test3");
        
        // Set context values
        try req.set("key1", "value1");
        try req.set("key2", "value2");
        
        // All allocations should be freed when deinit is called
        req.deinit();
    }
    
    // Check for leaks
    try std.testing.expect(gpa.deinit() == .ok);
}

test "Request param extraction" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos/123",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    // Manually set route params (normally done by router)
    var params = std.StringHashMap([]const u8).init(req.arena.allocator());
    const id_value = try req.arena.allocator().dupe(u8, "123");
    try params.put("id", id_value);
    req.setRouteParams(params);
    
    const id = try req.param("id").asU32();
    try std.testing.expectEqual(id, 123);
    
    const missing = req.param("nonexistent").asString();
    try std.testing.expectEqualStrings(missing, "");
}

test "Request query parsing" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos?limit=10&offset=20",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const limit = try req.query("limit");
    try std.testing.expect(limit != null);
    try std.testing.expectEqualStrings(limit.?, "10");
    
    const offset = try req.query("offset");
    try std.testing.expect(offset != null);
    try std.testing.expectEqualStrings(offset.?, "20");
    
    // Path should exclude query string
    try std.testing.expectEqualStrings(req.path(), "/api/todos");
}

test "Request form body parsing" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos",
        .method = .POST,
        .body = "title=Hello&completed=true",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const form = try req.formBody();
    const title = form.get("title");
    try std.testing.expect(title != null);
    try std.testing.expectEqualStrings(title.?, "Hello");
    
    const completed = form.get("completed");
    try std.testing.expect(completed != null);
    try std.testing.expectEqualStrings(completed.?, "true");
}
