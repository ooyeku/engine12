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
    
    /// Get a query parameter by name (optional only, throws on parse error)
    /// Returns optional only - throws if query parameter parsing fails
    /// 
    /// Example:
    /// ```zig
    /// const status = req.queryOptional("status"); // ?[]const u8
    /// if (status) |s| {
    ///     // Use status
    /// }
    /// ```
    pub fn queryOptional(self: *Request, name: []const u8) ?[]const u8 {
        const params = self.queryParams() catch return null;
        return params.get(name);
    }
    
    /// Get a query parameter by name (strict - fails if missing)
    /// Returns error union - fails if parameter is missing or parsing fails
    /// 
    /// Example:
    /// ```zig
    /// const limit = try req.queryStrict("limit"); // ![]const u8
    /// ```
    pub fn queryStrict(self: *Request, name: []const u8) (error{QueryParameterMissing} || std.mem.Allocator.Error)![]const u8 {
        const params = try self.queryParams();
        return params.get(name) orelse error.QueryParameterMissing;
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

test "Request path with query string extraction" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos?limit=10&offset=20&sort=asc",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    try std.testing.expectEqualStrings(req.path(), "/api/todos");
    try std.testing.expectEqualStrings(req.fullPath(), "/api/todos?limit=10&offset=20&sort=asc");
}

test "Request path without query string" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    try std.testing.expectEqualStrings(req.path(), "/api/todos");
    try std.testing.expectEqualStrings(req.fullPath(), "/api/todos");
}

test "Request empty path" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    try std.testing.expectEqualStrings(req.path(), "");
    try std.testing.expectEqualStrings(req.method(), "GET");
}

test "Request query parsing with empty values" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test?key1=&key2=value&key3=",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const key1 = try req.query("key1");
    try std.testing.expect(key1 != null);
    try std.testing.expectEqualStrings(key1.?, "");
    
    const key2 = try req.query("key2");
    try std.testing.expect(key2 != null);
    try std.testing.expectEqualStrings(key2.?, "value");
    
    const key3 = try req.query("key3");
    try std.testing.expect(key3 != null);
    try std.testing.expectEqualStrings(key3.?, "");
}

test "Request query parsing with missing parameter" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test?key1=value1",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const missing = try req.query("nonexistent");
    try std.testing.expect(missing == null);
}

test "Request query parsing with URL encoded values" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test?q=hello%20world&tag=test%2Bvalue",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const q = try req.query("q");
    try std.testing.expect(q != null);
    try std.testing.expectEqualStrings(q.?, "hello world");
    
    const tag = try req.query("tag");
    try std.testing.expect(tag != null);
    try std.testing.expectEqualStrings(tag.?, "test+value");
}

test "Request queryParam with default value" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test?limit=50",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const limit = try req.queryParam("limit");
    const limit_u32 = limit.asU32Default(10);
    try std.testing.expectEqual(limit_u32, 50);
    
    const missing_limit = try req.queryParam("nonexistent");
    const default_limit = missing_limit.asU32Default(10);
    try std.testing.expectEqual(default_limit, 10);
}

test "Request queryParams caching" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test?key=value",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const params1 = try req.queryParams();
    const params2 = try req.queryParams();
    
    // Should return same map (cached)
    try std.testing.expectEqual(params1.count(), params2.count());
    try std.testing.expectEqualStrings(params1.get("key").?, params2.get("key").?);
}

test "Request form body parsing with empty values" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test",
        .method = .POST,
        .body = "key1=&key2=value&key3=",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const form = try req.formBody();
    const key1 = form.get("key1");
    try std.testing.expect(key1 != null);
    try std.testing.expectEqualStrings(key1.?, "");
    
    const key2 = form.get("key2");
    try std.testing.expect(key2 != null);
    try std.testing.expectEqualStrings(key2.?, "value");
}

test "Request form body parsing with URL encoded values" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test",
        .method = .POST,
        .body = "name=John%20Doe&email=test%40example.com",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const form = try req.formBody();
    const name = form.get("name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings(name.?, "John Doe");
    
    const email = form.get("email");
    try std.testing.expect(email != null);
    try std.testing.expectEqualStrings(email.?, "test@example.com");
}

test "Request empty form body" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test",
        .method = .POST,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const form = try req.formBody();
    try std.testing.expectEqual(form.count(), 0);
}

test "Request param with empty value" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos/",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    var params = std.StringHashMap([]const u8).init(req.arena.allocator());
    const empty_value = try req.arena.allocator().dupe(u8, "");
    try params.put("id", empty_value);
    req.setRouteParams(params);
    
    const id = req.param("id").asString();
    try std.testing.expectEqualStrings(id, "");
}

test "Request param with missing parameter" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const missing = req.param("nonexistent").asString();
    try std.testing.expectEqualStrings(missing, "");
}

test "Request param type conversions" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos/123",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    var params = std.StringHashMap([]const u8).init(req.arena.allocator());
    const id_value = try req.arena.allocator().dupe(u8, "123");
    try params.put("id", id_value);
    req.setRouteParams(params);
    
    const id_u32 = try req.param("id").asU32();
    try std.testing.expectEqual(id_u32, 123);
    
    const id_i32 = try req.param("id").asI32();
    try std.testing.expectEqual(id_i32, 123);
    
    const id_u64 = try req.param("id").asU64();
    try std.testing.expectEqual(id_u64, 123);
}

test "Request param invalid number conversion" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos/abc",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    var params = std.StringHashMap([]const u8).init(req.arena.allocator());
    const id_value = try req.arena.allocator().dupe(u8, "abc");
    try params.put("id", id_value);
    req.setRouteParams(params);
    
    const id_u32 = req.param("id").asU32Default(999);
    try std.testing.expectEqual(id_u32, 999);
    
    const id_i32 = req.param("id").asI32Default(-1);
    try std.testing.expectEqual(id_i32, -1);
}

test "Request param negative number" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos/-5",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    var params = std.StringHashMap([]const u8).init(req.arena.allocator());
    const id_value = try req.arena.allocator().dupe(u8, "-5");
    try params.put("id", id_value);
    req.setRouteParams(params);
    
    const id_i32 = try req.param("id").asI32();
    try std.testing.expectEqual(id_i32, -5);
    
    // u32 should fail on negative
    const id_u32 = req.param("id").asU32Default(0);
    try std.testing.expectEqual(id_u32, 0);
}

test "Request param float conversion" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos/3.14",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    var params = std.StringHashMap([]const u8).init(req.arena.allocator());
    const value = try req.arena.allocator().dupe(u8, "3.14");
    try params.put("value", value);
    req.setRouteParams(params);
    
    const float_value = try req.param("value").asF64();
    try std.testing.expect(float_value > 3.13 and float_value < 3.15);
}

test "Request setRouteParams replaces existing params" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos/123",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    var params1 = std.StringHashMap([]const u8).init(req.arena.allocator());
    const id1 = try req.arena.allocator().dupe(u8, "123");
    try params1.put("id", id1);
    req.setRouteParams(params1);
    
    var params2 = std.StringHashMap([]const u8).init(req.arena.allocator());
    const id2 = try req.arena.allocator().dupe(u8, "456");
    try params2.put("id", id2);
    req.setRouteParams(params2);
    
    const id = req.param("id").asString();
    try std.testing.expectEqualStrings(id, "456");
}

test "Request context multiple values" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    try req.set("user_id", "12345");
    try req.set("role", "admin");
    try req.set("session_id", "abc123");
    
    try std.testing.expectEqualStrings(req.get("user_id").?, "12345");
    try std.testing.expectEqualStrings(req.get("role").?, "admin");
    try std.testing.expectEqualStrings(req.get("session_id").?, "abc123");
    
    const missing = req.get("nonexistent");
    try std.testing.expect(missing == null);
}

test "Request context overwrite value" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    try req.set("key", "value1");
    try std.testing.expectEqualStrings(req.get("key").?, "value1");
    
    try req.set("key", "value2");
    try std.testing.expectEqualStrings(req.get("key").?, "value2");
}

test "Request empty body" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test",
        .method = .POST,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    try std.testing.expectEqualStrings(req.body(), "");
}

test "Request all HTTP methods" {
    const methods = [_]ziggurat.request.Method{ .GET, .POST, .PUT, .DELETE, .PATCH, .HEAD, .OPTIONS };
    
    for (methods) |method| {
        var ziggurat_req = ziggurat.request.Request{
            .path = "/api/test",
            .method = method,
            .body = "",
        };
        var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
        defer req.deinit();
        
        const method_str = req.method();
        try std.testing.expect(method_str.len > 0);
    }
}
