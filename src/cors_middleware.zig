const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware = @import("middleware.zig");

/// CORS configuration options
pub const CorsConfig = struct {
    /// Allowed origins (use "*" for all origins, or specific origins)
    allowed_origins: []const []const u8 = &[_][]const u8{"*"},
    
    /// Allowed HTTP methods
    allowed_methods: []const []const u8 = &[_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS" },
    
    /// Allowed headers
    allowed_headers: []const []const u8 = &[_][]const u8{"Content-Type", "Authorization"},
    
    /// Max age for preflight cache (in seconds)
    max_age: u32 = 3600,
    
    /// Allow credentials (cookies, authorization headers)
    allow_credentials: bool = false,
    
    /// Exposed headers (headers that can be accessed by JavaScript)
    exposed_headers: []const []const u8 = &[_][]const u8{},
};

/// Global CORS config storage (thread-safe)
var global_cors_config: ?CorsConfig = null;
var global_cors_config_mutex: std.Thread.Mutex = .{};

/// CORS middleware for handling Cross-Origin Resource Sharing
/// Uses request context to store CORS info, which is then processed in executeResponse
pub const CorsMiddleware = struct {
    config: CorsConfig,
    
    /// Initialize CORS middleware with configuration
    /// 
    /// Example:
    /// ```zig
    /// const cors = CorsMiddleware.init(.{
    ///     .allowed_origins = &[_][]const u8{"http://localhost:3000"},
    ///     .allowed_methods = &[_][]const u8{"GET", "POST"},
    ///     .max_age = 3600,
    /// });
    /// try chain.addPreRequest(&cors.preflightMwFn());
    /// // CORS headers are added automatically in executeResponse
    /// ```
    pub fn init(config: CorsConfig) CorsMiddleware {
        return CorsMiddleware{ .config = config };
    }
    
    /// Set the global CORS config (must be called before using middleware)
    pub fn setGlobalConfig(self: *const CorsMiddleware) void {
        global_cors_config_mutex.lock();
        defer global_cors_config_mutex.unlock();
        global_cors_config = self.config;
    }
    
    /// Pre-request middleware to handle OPTIONS preflight requests and store config
    fn preflightMiddleware(req: *Request) middleware.MiddlewareResult {
        // Get config from global storage
        global_cors_config_mutex.lock();
        const config = global_cors_config orelse {
            global_cors_config_mutex.unlock();
            return .proceed; // No CORS config set
        };
        global_cors_config_mutex.unlock();
        // Store config in request context (as JSON string for simplicity)
        // We'll serialize the key config values
        const origin = req.header("Origin") orelse {
            return .proceed; // No origin header, not a CORS request
        };
        
        // Check if origin is allowed
        if (!isOriginAllowed(&config, origin)) {
            return .proceed; // Origin not allowed
        }
        
        // Store origin in context for response middleware
        req.set("cors_origin", origin) catch {};
        
        // Handle OPTIONS preflight requests
        if (std.mem.eql(u8, req.method(), "OPTIONS")) {
            // Get requested method and headers
            const requested_method = req.header("Access-Control-Request-Method") orelse "";
            const requested_headers = req.header("Access-Control-Request-Headers") orelse "";
            
            // Check if method and headers are allowed
            const method_allowed = isMethodAllowed(&config, requested_method);
            const headers_allowed = areHeadersAllowed(&config, requested_headers);
            
            if (method_allowed and headers_allowed) {
                // Store preflight info in context
                req.set("cors_preflight", "true") catch {};
                
                // Store config values in context
                var methods_buf: [256]u8 = undefined;
                var methods_fba = std.heap.FixedBufferAllocator.init(&methods_buf);
                var methods_list = std.ArrayListUnmanaged(u8){};
                defer methods_list.deinit(methods_fba.allocator());
                for (config.allowed_methods, 0..) |method, i| {
                    if (i > 0) {
                        methods_list.appendSlice(methods_fba.allocator(), ", ") catch break;
                    }
                    methods_list.appendSlice(methods_fba.allocator(), method) catch break;
                }
                req.set("cors_allowed_methods", methods_list.items) catch {};
                
                var headers_buf: [256]u8 = undefined;
                var headers_fba = std.heap.FixedBufferAllocator.init(&headers_buf);
                var headers_list = std.ArrayListUnmanaged(u8){};
                defer headers_list.deinit(headers_fba.allocator());
                for (config.allowed_headers, 0..) |header, i| {
                    if (i > 0) {
                        headers_list.appendSlice(headers_fba.allocator(), ", ") catch break;
                    }
                    headers_list.appendSlice(headers_fba.allocator(), header) catch break;
                }
                req.set("cors_allowed_headers", headers_list.items) catch {};
                
                var max_age_buf: [32]u8 = undefined;
                const max_age_str = std.fmt.bufPrint(&max_age_buf, "{d}", .{config.max_age}) catch "3600";
                req.set("cors_max_age", max_age_str) catch {};
                
                if (config.allow_credentials) {
                    req.set("cors_allow_credentials", "true") catch {};
                }
                
                if (config.exposed_headers.len > 0) {
                    var exposed_buf: [256]u8 = undefined;
                    var exposed_fba = std.heap.FixedBufferAllocator.init(&exposed_buf);
                    var exposed_list = std.ArrayListUnmanaged(u8){};
                    defer exposed_list.deinit(exposed_fba.allocator());
                    for (config.exposed_headers, 0..) |header, i| {
                        if (i > 0) {
                            exposed_list.appendSlice(exposed_fba.allocator(), ", ") catch break;
                        }
                        exposed_list.appendSlice(exposed_fba.allocator(), header) catch break;
                    }
                    req.set("cors_exposed_headers", exposed_list.items) catch {};
                }
            }
        } else {
            // Regular request - store config for response headers
            if (config.allow_credentials) {
                req.set("cors_allow_credentials", "true") catch {};
            }
            if (config.exposed_headers.len > 0) {
                var exposed_buf: [256]u8 = undefined;
                var exposed_fba = std.heap.FixedBufferAllocator.init(&exposed_buf);
                var exposed_list = std.ArrayListUnmanaged(u8){};
                defer exposed_list.deinit(exposed_fba.allocator());
                for (config.exposed_headers, 0..) |header, i| {
                    if (i > 0) {
                        exposed_list.appendSlice(exposed_fba.allocator(), ", ") catch break;
                    }
                    exposed_list.appendSlice(exposed_fba.allocator(), header) catch break;
                }
                req.set("cors_exposed_headers", exposed_list.items) catch {};
            }
        }
        
        return .proceed;
    }
    
    /// Check if origin is allowed
    fn isOriginAllowed(config: *const CorsConfig, origin: []const u8) bool {
        for (config.allowed_origins) |allowed| {
            if (std.mem.eql(u8, allowed, "*")) {
                return true;
            }
            if (std.mem.eql(u8, allowed, origin)) {
                return true;
            }
        }
        return false;
    }
    
    /// Check if method is allowed
    fn isMethodAllowed(config: *const CorsConfig, method: []const u8) bool {
        for (config.allowed_methods) |allowed| {
            if (std.mem.eql(u8, allowed, method)) {
                return true;
            }
        }
        return false;
    }
    
    /// Check if headers are allowed
    fn areHeadersAllowed(config: *const CorsConfig, headers_str: []const u8) bool {
        if (headers_str.len == 0) return true;
        
        var headers = std.mem.splitSequence(u8, headers_str, ",");
        while (headers.next()) |header| {
            const trimmed = std.mem.trim(u8, header, " \t");
            var found = false;
            for (config.allowed_headers) |allowed| {
                if (std.mem.eql(u8, std.mem.trim(u8, allowed, " \t"), trimmed)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                return false;
            }
        }
        return true;
    }
    
    /// Create pre-request middleware function pointer
    pub fn preflightMwFn(_: *const CorsMiddleware) middleware.PreRequestMiddlewareFn {
        const Self = @This();
        return struct {
            fn mw(req: *Request) middleware.MiddlewareResult {
                return Self.preflightMiddleware(req);
            }
        }.mw;
    }
};

// Tests
test "CorsMiddleware init" {
    const cors = CorsMiddleware.init(.{
        .allowed_origins = &[_][]const u8{"http://localhost:3000"},
        .allowed_methods = &[_][]const u8{"GET", "POST"},
        .max_age = 3600,
    });
    try std.testing.expectEqualStrings(cors.config.allowed_origins[0], "http://localhost:3000");
    try std.testing.expectEqual(cors.config.max_age, 3600);
}

test "CorsMiddleware isOriginAllowed" {
    var cors = CorsMiddleware.init(.{
        .allowed_origins = &[_][]const u8{"http://localhost:3000", "https://example.com"},
    });
    
    try std.testing.expect(cors.isOriginAllowed("http://localhost:3000"));
    try std.testing.expect(cors.isOriginAllowed("https://example.com"));
    try std.testing.expect(!cors.isOriginAllowed("http://evil.com"));
}

test "CorsMiddleware isOriginAllowed wildcard" {
    var cors = CorsMiddleware.init(.{
        .allowed_origins = &[_][]const u8{"*"},
    });
    
    try std.testing.expect(cors.isOriginAllowed("http://localhost:3000"));
    try std.testing.expect(cors.isOriginAllowed("https://example.com"));
}

test "CorsMiddleware isMethodAllowed" {
    var cors = CorsMiddleware.init(.{
        .allowed_methods = &[_][]const u8{"GET", "POST"},
    });
    
    try std.testing.expect(cors.isMethodAllowed("GET"));
    try std.testing.expect(cors.isMethodAllowed("POST"));
    try std.testing.expect(!cors.isMethodAllowed("DELETE"));
}

test "CorsMiddleware areHeadersAllowed" {
    var cors = CorsMiddleware.init(.{
        .allowed_headers = &[_][]const u8{"Content-Type", "Authorization"},
    });
    
    try std.testing.expect(cors.areHeadersAllowed("Content-Type"));
    try std.testing.expect(cors.areHeadersAllowed("Content-Type, Authorization"));
    try std.testing.expect(!cors.areHeadersAllowed("X-Custom-Header"));
}

