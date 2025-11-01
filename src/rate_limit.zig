const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware_chain = @import("middleware.zig");

/// Rate limit configuration
pub const RateLimitConfig = struct {
    /// Maximum number of requests allowed
    max_requests: u64,
    
    /// Time window in milliseconds
    window_ms: u64,
    
    /// Message to return when rate limit is exceeded
    message: []const u8 = "Rate limit exceeded",
};

/// Rate limit entry for tracking requests
pub const RateLimitEntry = struct {
    count: u64 = 0,
    reset_at: i64,
    
    pub fn init(window_ms: u64) RateLimitEntry {
        return RateLimitEntry{
            .count = 0,
            .reset_at = std.time.milliTimestamp() + @as(i64, @intCast(window_ms)),
        };
    }
    
    pub fn isExpired(self: *const RateLimitEntry) bool {
        return std.time.milliTimestamp() >= self.reset_at;
    }
    
    pub fn reset(self: *RateLimitEntry, window_ms: u64) void {
        self.count = 0;
        self.reset_at = std.time.milliTimestamp() + @as(i64, @intCast(window_ms));
    }
};

/// Rate limiter for tracking requests per IP and per route
pub const RateLimiter = struct {
    /// Per-IP rate limits
    ip_limits: std.StringHashMap(RateLimitEntry),
    
    /// Per-route rate limits
    route_limits: std.StringHashMap(RateLimitEntry),
    
    /// Global rate limit config
    global_config: RateLimitConfig,
    
    /// Route-specific configs
    route_configs: std.StringHashMap(RateLimitConfig),
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, global_config: RateLimitConfig) RateLimiter {
        return RateLimiter{
            .ip_limits = std.StringHashMap(RateLimitEntry).init(allocator),
            .route_limits = std.StringHashMap(RateLimitEntry).init(allocator),
            .global_config = global_config,
            .route_configs = std.StringHashMap(RateLimitConfig).init(allocator),
            .allocator = allocator,
        };
    }
    
    /// Set rate limit config for a specific route
    pub fn setRouteConfig(self: *RateLimiter, route: []const u8, config: RateLimitConfig) !void {
        try self.route_configs.put(route, config);
    }
    
    /// Get client IP from request
    fn getClientIP(self: *const RateLimiter, req: *Request) []const u8 {
        _ = self;
        // Try to get IP from X-Forwarded-For header (for proxies)
        if (req.header("X-Forwarded-For")) |xff| {
            // Take first IP from comma-separated list
            const comma_pos = std.mem.indexOfScalar(u8, xff, ',') orelse xff.len;
            return xff[0..comma_pos];
        }
        
        // Try X-Real-IP header
        if (req.header("X-Real-IP")) |real_ip| {
            return real_ip;
        }
        
        // Fallback: use a default (in production, this should come from connection)
        return "unknown";
    }
    
    /// Check if request should be rate limited
    /// Returns null if allowed, or an error response if rate limited
    pub fn check(self: *RateLimiter, req: *Request, route: []const u8) !?Response {
        const config = self.route_configs.get(route) orelse self.global_config;
        const client_ip = self.getClientIP(req);
        
        // Check per-IP limit
        var ip_entry = self.ip_limits.getPtr(client_ip);
        if (ip_entry) |entry| {
            if (entry.isExpired()) {
                entry.reset(config.window_ms);
            }
            entry.count += 1;
            if (entry.count > config.max_requests) {
                return Response.status(429).json(
                    \\{"error":"Rate limit exceeded","message":"Too many requests"}
                );
            }
        } else {
            const new_entry = RateLimitEntry.init(config.window_ms);
            try self.ip_limits.put(client_ip, new_entry);
            ip_entry = self.ip_limits.getPtr(client_ip).?;
            ip_entry.count = 1;
        }
        
        // Check per-route limit (optional, can be more restrictive)
        var route_entry = self.route_limits.getPtr(route);
        if (route_entry) |entry| {
            if (entry.isExpired()) {
                entry.reset(config.window_ms);
            }
            entry.count += 1;
            if (entry.count > config.max_requests) {
                return Response.status(429).json(
                    \\{"error":"Rate limit exceeded","message":"Too many requests for this route"}
                );
            }
        } else {
            const new_entry = RateLimitEntry.init(config.window_ms);
            try self.route_limits.put(route, new_entry);
            route_entry = self.route_limits.getPtr(route).?;
            route_entry.count = 1;
        }
        
        return null;
    }
    
    /// Clean up expired entries periodically
    pub fn cleanup(self: *RateLimiter) void {
        // Clean up expired IP entries
        var ip_iterator = self.ip_limits.iterator();
        var keys_to_remove = std.ArrayListUnmanaged([]const u8){};
        while (ip_iterator.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                keys_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (keys_to_remove.items) |key| {
            _ = self.ip_limits.remove(key);
        }
        keys_to_remove.deinit(self.allocator);
        
        // Clean up expired route entries
        var route_iterator = self.route_limits.iterator();
        keys_to_remove = std.ArrayListUnmanaged([]const u8){};
        while (route_iterator.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                keys_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (keys_to_remove.items) |key| {
            _ = self.route_limits.remove(key);
        }
        keys_to_remove.deinit(self.allocator);
    }
    
    pub fn deinit(self: *RateLimiter) void {
        self.ip_limits.deinit();
        self.route_limits.deinit();
        self.route_configs.deinit();
    }
};

/// Create a rate limiting middleware function
/// Returns a middleware function that checks rate limits before proceeding
/// Uses a global rate limiter (similar to middleware pattern)
pub fn createRateLimitMiddleware(limiter: *RateLimiter, route: []const u8) middleware_chain.PreRequestMiddlewareFn {
    _ = limiter;
    _ = route;
    // Store route and limiter in a way accessible at runtime
    // Use a thread-local variable pattern similar to middleware
    return struct {
        fn mw(req: *Request) middleware_chain.MiddlewareResult {
            // Access global rate limiter
            const global_limiter = @import("engine12.zig").global_rate_limiter orelse return .proceed;
            
            // Get route from request path
            const route_path = req.path();
            
            // Check rate limit
            if (global_limiter.check(req, route_path) catch null) |_| {
                // Rate limit exceeded - mark in context and abort
                req.context.put("rate_limited", "true") catch {};
                return .abort;
            }
            return .proceed;
        }
    }.mw;
}

// Tests
test "RateLimiter check allows requests within limit" {
    var limiter = RateLimiter.init(std.testing.allocator, RateLimitConfig{
        .max_requests = 10,
        .window_ms = 1000,
    });
    defer limiter.deinit();
    
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/test",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    // First request should be allowed
    const result = try limiter.check(&req, "/test");
    try std.testing.expect(result == null);
}

test "RateLimitEntry init and expiration" {
    var entry = RateLimitEntry.init(1000);
    try std.testing.expectEqual(entry.count, 0);
    try std.testing.expect(!entry.isExpired());
}

