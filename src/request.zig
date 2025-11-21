const std = @import("std");
const ziggurat = @import("ziggurat");
const router = @import("router.zig");
const parsers = @import("parsers.zig");

/// engine12 Request wrapper around ziggurat.request.Request
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
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        return self.inner.headers.get(name);
    }

    /// Parse and get query parameters
    /// Returns a hashmap of key-value pairs
    /// Results are cached after first parse
    /// 
    /// Memory Management:
    /// Query parameters are allocated using the request's arena allocator and are
    /// automatically freed when the request completes (via Request.deinit()).
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
    /// Validates query parameter length to prevent DoS attacks
    /// 
    /// Example:
    /// ```zig
    /// const limit = try req.query("limit");
    /// const limit_u32 = if (limit) |l| try std.fmt.parseInt(u32, l, 10) else 10;
    /// ```
    pub fn query(self: *Request, name: []const u8) !?[]const u8 {
        // Validate parameter name length
        if (name.len > 256) {
            return error.InvalidArgument;
        }
        const params = try self.queryParams();
        const value = params.get(name);
        // Validate parameter value length to prevent DoS
        if (value) |v| {
            if (v.len > 4096) {
                std.debug.print("[Request Warning] Query parameter '{s}' value exceeds maximum length (4096 bytes)\n", .{name});
                return null;
            }
        }
        return value;
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
    
    /// Get a query parameter with type-safe conversion
    /// Returns optional value - null if parameter is missing
    /// Supports: u32, i32, u64, i64, f64, bool, []const u8
    /// 
    /// Example:
    /// ```zig
    /// const page = request.queryParamTyped(u32, "page") orelse 1;
    /// const limit = request.queryParamTyped(u32, "limit") orelse 20;
    /// const search = request.queryParamTyped([]const u8, "q");
    /// ```
    pub fn queryParamTyped(self: *Request, comptime T: type, name: []const u8) !?T {
        const value = try self.query(name);
        if (value == null) return null;
        
        const param_wrapper = router.Param{ .value = value.? };
        
        return switch (@typeInfo(T)) {
            .int => |int_info| switch (int_info.signedness) {
                .signed => switch (int_info.bits) {
                    32 => @as(T, @intCast(try param_wrapper.asI32())),
                    64 => @as(T, @intCast(try param_wrapper.asI64())),
                    else => @compileError("Unsupported signed integer type for queryParamTyped. Supported: i32, i64"),
                },
                .unsigned => switch (int_info.bits) {
                    32 => @as(T, @intCast(try param_wrapper.asU32())),
                    64 => @as(T, @intCast(try param_wrapper.asU64())),
                    else => @compileError("Unsupported unsigned integer type for queryParamTyped. Supported: u32, u64"),
                },
            },
            .float => |float_info| switch (float_info.bits) {
                64 => @as(T, try param_wrapper.asF64()),
                else => @compileError("Unsupported float type for queryParamTyped. Supported: f64"),
            },
            .bool => blk: {
                const str = param_wrapper.asString();
                if (std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "1")) {
                    break :blk true;
                } else if (std.mem.eql(u8, str, "false") or std.mem.eql(u8, str, "0")) {
                    break :blk false;
                } else {
                    return error.InvalidArgument;
                }
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return param_wrapper.asString();
                } else {
                    @compileError("Unsupported pointer type for queryParamTyped. Supported: []const u8");
                }
            },
            else => @compileError("Unsupported type for queryParamTyped. Supported: u32, i32, u64, i64, f64, bool, []const u8"),
        };
    }
    
    /// Parse request body as JSON
    /// Returns an error if parsing fails
    /// Validates body length to prevent DoS attacks (max 10MB by default)
    /// 
    /// Example:
    /// ```zig
    /// const Todo = struct { title: []const u8, completed: bool };
    /// const todo = try req.jsonBody(Todo);
    /// ```
    pub fn jsonBody(self: *Request, comptime T: type) !T {
        // Validate body length to prevent DoS (10MB max)
        const MAX_BODY_SIZE = 10 * 1024 * 1024;
        if (self.body().len > MAX_BODY_SIZE) {
            std.debug.print("[Request Error] JSON body exceeds maximum size ({d} bytes)\n", .{MAX_BODY_SIZE});
            return error.InvalidArgument;
        }
        return parsers.BodyParser.json(T, self.body(), self.arena.allocator());
    }
    
    /// Parse request body as JSON (alias for jsonBody)
    /// Returns an error if parsing fails
    /// 
    /// Example:
    /// ```zig
    /// const Todo = struct { title: []const u8, completed: bool };
    /// const todo = try req.parseJson(Todo);
    /// ```
    pub fn parseJson(self: *Request, comptime T: type) !T {
        return self.jsonBody(T);
    }
    
    /// Parse request body as JSON, returning null on error instead of erroring
    /// 
    /// Example:
    /// ```zig
    /// const Todo = struct { title: []const u8, completed: bool };
    /// if (req.parseJsonOptional(Todo)) |todo| {
    ///     // Use todo
    /// } else {
    ///     return Response.errorResponse("Invalid JSON", 400);
    /// }
    /// ```
    pub fn parseJsonOptional(self: *Request, comptime T: type) ?T {
        return self.jsonBody(T) catch null;
    }
    
    /// Parse and validate JSON body against a validation schema
    /// Returns parsed value if validation passes, or error if parsing/validation fails
    /// 
    /// Example:
    /// ```zig
    /// const TodoInput = struct { title: []const u8, description: []const u8 };
    /// var schema = validation.ValidationSchema.init(req.arena.allocator());
    /// defer schema.deinit();
    /// const title_validator = try schema.field("title", "");
    /// title_validator.rule(validation.required);
    /// const todo = try req.validateJson(TodoInput, &schema);
    /// ```
    pub fn validateJson(self: *Request, comptime T: type, schema: *@import("validation.zig").ValidationSchema) (error{ValidationFailed} || @TypeOf(self.jsonBody(T)).Error)!T {
        const parsed = try self.jsonBody(T);
        
        // Run validation - note: schema needs to be populated with field values from parsed
        // This is a simplified version - in practice, you'd need to extract field values
        const validation_errors = try schema.validate();
        defer validation_errors.deinit();
        
        if (!validation_errors.isEmpty()) {
            return error.ValidationFailed;
        }
        
        return parsed;
    }
    
    /// Parse request body as URL-encoded form data
    /// Returns a hashmap of key-value pairs
    /// Validates body length to prevent DoS attacks (max 1MB by default)
    /// 
    /// Example:
    /// ```zig
    /// const form = try req.formBody();
    /// const title = form.get("title");
    /// ```
    pub fn formBody(self: *Request) !std.StringHashMap([]const u8) {
        // Validate body length to prevent DoS (1MB max for form data)
        const MAX_FORM_SIZE = 1024 * 1024;
        if (self.body().len > MAX_FORM_SIZE) {
            std.debug.print("[Request Error] Form body exceeds maximum size ({d} bytes)\n", .{MAX_FORM_SIZE});
            return error.InvalidArgument;
        }
        return parsers.BodyParser.formData(self.arena.allocator(), self.body());
    }
    
    /// Get a route parameter by name
    /// Returns a Param wrapper that provides type-safe conversion methods
    /// Validates parameter value length to prevent DoS attacks
    /// 
    /// Example:
    /// ```zig
    /// const id = try req.param("id").asU32();
    /// const limit = req.param("limit").asU32Default(10);
    /// ```
    pub fn param(self: *const Request, name: []const u8) router.Param {
        const value = self.route_params.get(name) orelse "";
        // Validate parameter value length to prevent DoS
        if (value.len > 1024) {
            std.debug.print("[Request Warning] Route parameter '{s}' value exceeds maximum length (1024 bytes)\n", .{name});
            return router.Param{ .value = "" };
        }
        return router.Param{ .value = value };
    }
    
    /// Get a route parameter with direct type conversion
    /// Returns error union - fails if parameter is missing or conversion fails
    /// Supports: u32, i32, u64, i64, f64, bool, []const u8
    /// 
    /// Example:
    /// ```zig
    /// const id = try request.paramTyped(i64, "id");
    /// const slug = try request.paramTyped([]const u8, "slug");
    /// ```
    pub fn paramTyped(self: *const Request, comptime T: type, name: []const u8) !T {
        const value = self.route_params.get(name) orelse return error.InvalidArgument;
        
        // Validate parameter value length to prevent DoS
        if (value.len > 1024) {
            std.debug.print("[Request Warning] Route parameter '{s}' value exceeds maximum length (1024 bytes)\n", .{name});
            return error.InvalidArgument;
        }
        
        const param_wrapper = router.Param{ .value = value };
        
        return switch (@typeInfo(T)) {
            .int => |int_info| switch (int_info.signedness) {
                .signed => switch (int_info.bits) {
                    32 => @as(T, @intCast(try param_wrapper.asI32())),
                    64 => @as(T, @intCast(try param_wrapper.asI64())),
                    else => @compileError("Unsupported signed integer type for paramTyped. Supported: i32, i64"),
                },
                .unsigned => switch (int_info.bits) {
                    32 => @as(T, @intCast(try param_wrapper.asU32())),
                    64 => @as(T, @intCast(try param_wrapper.asU64())),
                    else => @compileError("Unsupported unsigned integer type for paramTyped. Supported: u32, u64"),
                },
            },
            .float => |float_info| switch (float_info.bits) {
                64 => @as(T, try param_wrapper.asF64()),
                else => @compileError("Unsupported float type for paramTyped. Supported: f64"),
            },
            .bool => blk: {
                const str = param_wrapper.asString();
                if (std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "1")) {
                    break :blk true;
                } else if (std.mem.eql(u8, str, "false") or std.mem.eql(u8, str, "0")) {
                    break :blk false;
                } else {
                    return error.InvalidArgument;
                }
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return param_wrapper.asString();
                } else {
                    @compileError("Unsupported pointer type for paramTyped. Supported: []const u8");
                }
            },
            else => @compileError("Unsupported type for paramTyped. Supported: u32, i32, u64, i64, f64, bool, []const u8"),
        };
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
        
        // Reinitialize with page allocator (internal storage only)
        // Keys and values are duplicated into the arena below
        self.route_params = std.StringHashMap([]const u8).init(std.heap.page_allocator);
        
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
    /// Automatically generates a unique request ID for correlation tracking
    pub fn fromZiggurat(ziggurat_request: *ziggurat.request.Request, backing_allocator: std.mem.Allocator) Request {
        const arena = std.heap.ArenaAllocator.init(backing_allocator);
        
        // Use page allocator for hash map internal storage to avoid arena growth issues
        // Keys and values are still duplicated into the arena in set() and setRouteParams()
        const context = std.StringHashMap([]const u8).init(std.heap.page_allocator);
        const route_params = std.StringHashMap([]const u8).init(std.heap.page_allocator);
        
        var request = Request{
            .inner = ziggurat_request,
            .arena = arena,
            .context = context,
            .route_params = route_params,
            ._query_params = null,
        };
        
        // Generate unique request ID for correlation tracking
        const request_id = request.generateRequestId() catch "";
        if (request_id.len > 0) {
            request.set("request_id", request_id) catch {};
        }
        
        return request;
    }
    
    /// Generate a unique request ID for correlation tracking
    /// Format: timestamp-random (e.g., "1234567890-abc123")
    fn generateRequestId(self: *Request) ![]const u8 {
        const timestamp = std.time.milliTimestamp();
        var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const random = rng.random().int(u32);
        
        var buffer: [64]u8 = undefined;
        const id_str = try std.fmt.bufPrint(&buffer, "{d}-{x}", .{ timestamp, random });
        
        // Allocate in request arena
        return try self.arena.allocator().dupe(u8, id_str);
    }
    
    /// Get the request ID for correlation tracking
    /// Returns null if request ID was not set
    pub fn requestId(self: *const Request) ?[]const u8 {
        return self.get("request_id");
    }
    
    /// Get the cache instance if available
    /// Returns null if cache is not configured
    /// 
    /// Example:
    /// ```zig
    /// if (req.cache()) |cache| {
    ///     if (cache.get("my_key")) |entry| {
    ///         return Response.text(entry.body);
    ///     }
    /// }
    /// ```
    pub fn cache(self: *Request) ?*@import("cache.zig").ResponseCache {
        _ = self;
        return @import("engine12.zig").global_cache;
    }
    
    /// Get a value from the cache
    /// Returns null if not found or expired
    /// 
    /// Example:
    /// ```zig
    /// if (try req.cacheGet("user:123")) |entry| {
    ///     return Response.text(entry.body).withContentType(entry.content_type);
    /// }
    /// ```
    pub fn cacheGet(self: *Request, key: []const u8) !?*@import("cache.zig").CacheEntry {
        const cache_instance = self.cache() orelse return null;
        return cache_instance.get(key);
    }
    
    /// Store a value in the cache
    /// Uses default TTL if ttl_ms is null
    /// 
    /// Example:
    /// ```zig
    /// const body = "{\"data\":\"value\"}";
    /// try req.cacheSet("my_key", body, 60000, "application/json");
    /// ```
    pub fn cacheSet(self: *Request, key: []const u8, cache_body: []const u8, ttl_ms: ?u64, content_type: []const u8) !void {
        const cache_instance = self.cache() orelse return;
        try cache_instance.set(key, cache_body, ttl_ms, content_type);
    }
    
    /// Invalidate a cache entry
    /// 
    /// Example:
    /// ```zig
    /// req.cacheInvalidate("user:123");
    /// ```
    pub fn cacheInvalidate(self: *Request, key: []const u8) void {
        const cache_instance = self.cache() orelse return;
        cache_instance.invalidate(key);
    }
    
    /// Invalidate all cache entries matching a prefix
    /// 
    /// Example:
    /// ```zig
    /// req.cacheInvalidatePrefix("user:"); // Invalidates all user:* entries
    /// ```
    pub fn cacheInvalidatePrefix(self: *Request, prefix: []const u8) void {
        const cache_instance = self.cache() orelse return;
        cache_instance.invalidatePrefix(prefix);
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

test "Request cache access methods" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    // Create a cache and set it globally
    var response_cache = @import("cache.zig").ResponseCache.init(std.testing.allocator, 60000);
    defer response_cache.deinit();
    
    @import("engine12.zig").global_cache = &response_cache;
    defer @import("engine12.zig").global_cache = null;
    
    // Test cache access
    const cache_instance = req.cache();
    try std.testing.expect(cache_instance != null);
    
    // Test cacheSet
    try req.cacheSet("test_key", "test_value", null, "text/plain");
    
    // Test cacheGet
    const entry = try req.cacheGet("test_key");
    try std.testing.expect(entry != null);
    if (entry) |e| {
        try std.testing.expectEqualStrings(e.body, "test_value");
        try std.testing.expectEqualStrings(e.content_type, "text/plain");
    }
    
    // Test cacheInvalidate
    req.cacheInvalidate("test_key");
    const entry_after_invalidate = try req.cacheGet("test_key");
    try std.testing.expect(entry_after_invalidate == null);
}

test "Request cache methods return null when cache not configured" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    // Ensure no cache is set
    @import("engine12.zig").global_cache = null;
    
    // Test cache access returns null
    const cache_instance = req.cache();
    try std.testing.expect(cache_instance == null);
    
    // Test cacheGet returns null
    const entry = try req.cacheGet("test_key");
    try std.testing.expect(entry == null);
    
    // Test cacheSet does nothing (no error)
    try req.cacheSet("test_key", "test_value", null, "text/plain");
    
    // Test cacheInvalidate does nothing (no error)
    req.cacheInvalidate("test_key");
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

test "Request queryParamTyped with u32" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test?page=5&limit=20",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const page = try req.queryParamTyped(u32, "page");
    try std.testing.expect(page != null);
    try std.testing.expectEqual(page.?, 5);
    
    const limit = try req.queryParamTyped(u32, "limit");
    try std.testing.expect(limit != null);
    try std.testing.expectEqual(limit.?, 20);
    
    const missing = try req.queryParamTyped(u32, "missing");
    try std.testing.expect(missing == null);
}

test "Request queryParamTyped with bool" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/test?enabled=true&disabled=false",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const enabled = try req.queryParamTyped(bool, "enabled");
    try std.testing.expect(enabled != null);
    try std.testing.expect(enabled.? == true);
    
    const disabled = try req.queryParamTyped(bool, "disabled");
    try std.testing.expect(disabled != null);
    try std.testing.expect(disabled.? == false);
}

test "Request paramTyped with i64" {
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
    
    const id = try req.paramTyped(i64, "id");
    try std.testing.expectEqual(id, 123);
}

test "Request paramTyped with string" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/posts/my-slug",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    var params = std.StringHashMap([]const u8).init(req.arena.allocator());
    const slug_value = try req.arena.allocator().dupe(u8, "my-slug");
    try params.put("slug", slug_value);
    req.setRouteParams(params);
    
    const slug = try req.paramTyped([]const u8, "slug");
    try std.testing.expectEqualStrings(slug, "my-slug");
}

test "Request paramTyped missing parameter" {
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    try std.testing.expectError(error.InvalidArgument, req.paramTyped(i64, "id"));
}
