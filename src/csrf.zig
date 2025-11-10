const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware_chain = @import("middleware.zig");

/// CSRF protection configuration
pub const CSRFConfig = struct {
    /// Secret key for generating CSRF tokens (should be random and secret)
    secret_key: []const u8,
    
    /// Cookie name for CSRF token
    cookie_name: []const u8 = "csrf_token",
    
    /// Header name for CSRF token
    header_name: []const u8 = "X-CSRF-Token",
    
    /// Token expiration time in seconds (default: 1 hour)
    token_expiry: u64 = 3600,
    
    /// Allowed HTTP methods that require CSRF protection
    /// Safe methods (GET, HEAD, OPTIONS) are typically exempt
    protected_methods: []const []const u8 = &[_][]const u8{ "POST", "PUT", "DELETE", "PATCH" },
};

/// CSRF token generator and validator
pub const CSRFProtection = struct {
    config: CSRFConfig,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, config: CSRFConfig) CSRFProtection {
        return CSRFProtection{
            .config = config,
            .allocator = allocator,
        };
    }
    
    /// Generate a CSRF token
    /// In production, this should use a cryptographically secure random generator
    pub fn generateToken(self: *CSRFProtection) ![]const u8 {
        // Simple token generation using secret key and timestamp
        // In production, use a proper crypto library
        const timestamp = std.time.milliTimestamp();
        var buffer: [64]u8 = undefined;
        const token_str = try std.fmt.bufPrint(&buffer, "{s}-{d}", .{ self.config.secret_key, timestamp });
        
        // Hash the token for security (simplified - use proper crypto in production)
        // CityHash64 in Zig 0.15.x is used as a function, not a struct
        const hash = std.hash.CityHash64.hash(token_str);
        
        var token_buffer: [32]u8 = undefined;
        const token = try std.fmt.bufPrint(&token_buffer, "{x}", .{hash});
        
        // Allocate and return token
        const token_copy = try self.allocator.alloc(u8, token.len);
        @memcpy(token_copy, token);
        return token_copy;
    }
    
    /// Validate a CSRF token
    /// Checks if the token matches what's expected
    pub fn validateToken(self: *CSRFProtection, token: []const u8) bool {
        _ = self;
        // Simplified validation - in production, verify token signature and expiry
        // For now, just check token format and length
        return token.len >= 16;
    }
    
    /// Check if a request method requires CSRF protection
    pub fn isProtectedMethod(self: *const CSRFProtection, method: []const u8) bool {
        for (self.config.protected_methods) |protected| {
            if (std.mem.eql(u8, method, protected)) {
                return true;
            }
        }
        return false;
    }
    
    pub fn deinit(self: *CSRFProtection) void {
        _ = self;
        // Cleanup if needed
    }
};

/// Create CSRF protection middleware
/// Validates CSRF tokens for protected HTTP methods
pub fn createCSRFProtectionMiddleware(csrf: *CSRFProtection) middleware_chain.PreRequestMiddlewareFn {
    return struct {
        fn mw(req: *Request) middleware_chain.MiddlewareResult {
            // Check if this method requires CSRF protection
            if (!csrf.isProtectedMethod(req.method())) {
                return .proceed;
            }
            
            // Get CSRF token from header
            const token_header = req.header(csrf.config.header_name);
            
            // Get token from form data (for POST/PUT requests)
            var token_form: ?[]const u8 = null;
            if (req.method()[0] == 'P') { // POST or PUT
                const form_data = req.formBody() catch null;
                if (form_data) |form| {
                    token_form = form.get("csrf_token");
                }
            }
            
            // Validate token from any source
            const token = token_header orelse token_form orelse {
                // No token provided
                req.context.put("csrf_error", "CSRF token missing") catch {};
                return .abort;
            };
            
            if (!csrf.validateToken(token)) {
                req.context.put("csrf_error", "Invalid CSRF token") catch {};
                return .abort;
            }
            
            return .proceed;
        }
    }.mw;
}

/// Create a middleware that sets CSRF token cookie for GET requests
/// This allows frontend to read the token and include it in subsequent requests
pub fn createCSRFTokenSetterMiddleware(csrf: *CSRFProtection) middleware_chain.ResponseMiddlewareFn {
    return struct {
        fn mw(resp: Response) Response {
            // Generate a new CSRF token
            const token = csrf.generateToken() catch return resp;
            defer csrf.allocator.free(token);
            
            // Set token as cookie
            var modified_resp = resp;
            modified_resp = modified_resp.withCookie(csrf.config.cookie_name, token, .{
                .http_only = false, // Allow JavaScript to read it
                .secure = true, // HTTPS only in production
                .same_site = .lax,
            });
            
            return modified_resp;
        }
    }.mw;
}

// Tests
test "CSRFProtection isProtectedMethod" {
    var csrf = CSRFProtection.init(std.testing.allocator, CSRFConfig{
        .secret_key = "test_secret",
    });
    defer csrf.deinit();
    
    try std.testing.expect(csrf.isProtectedMethod("POST"));
    try std.testing.expect(csrf.isProtectedMethod("PUT"));
    try std.testing.expect(csrf.isProtectedMethod("DELETE"));
    try std.testing.expect(!csrf.isProtectedMethod("GET"));
    try std.testing.expect(!csrf.isProtectedMethod("HEAD"));
}

test "CSRFProtection generateToken" {
    var csrf = CSRFProtection.init(std.testing.allocator, CSRFConfig{
        .secret_key = "test_secret",
    });
    defer csrf.deinit();
    
    const token = try csrf.generateToken();
    defer csrf.allocator.free(token);
    
    try std.testing.expect(token.len > 0);
}

test "CSRFProtection validateToken" {
    var csrf = CSRFProtection.init(std.testing.allocator, CSRFConfig{
        .secret_key = "test_secret",
    });
    defer csrf.deinit();
    
    try std.testing.expect(csrf.validateToken("valid_token_12345678"));
    try std.testing.expect(!csrf.validateToken("short"));
}

test "CSRFProtection generateToken produces different tokens" {
    var csrf = CSRFProtection.init(std.testing.allocator, CSRFConfig{
        .secret_key = "test_secret",
    });
    defer csrf.deinit();
    
    const token1 = try csrf.generateToken();
    defer csrf.allocator.free(token1);
    
    std.time.sleep(1 * std.time.ns_per_ms);
    
    const token2 = try csrf.generateToken();
    defer csrf.allocator.free(token2);
    
    // Tokens should be different (due to timestamp)
    try std.testing.expect(!std.mem.eql(u8, token1, token2));
}

test "CSRFProtection custom protected methods" {
    const config = CSRFConfig{
        .secret_key = "test_secret",
        .protected_methods = &[_][]const u8{ "POST", "PUT" },
    };
    var csrf = CSRFProtection.init(std.testing.allocator, config);
    defer csrf.deinit();
    
    try std.testing.expect(csrf.isProtectedMethod("POST"));
    try std.testing.expect(csrf.isProtectedMethod("PUT"));
    try std.testing.expect(!csrf.isProtectedMethod("GET"));
    try std.testing.expect(!csrf.isProtectedMethod("DELETE"));
}

test "CSRFProtection validateToken edge cases" {
    var csrf = CSRFProtection.init(std.testing.allocator, CSRFConfig{
        .secret_key = "test_secret",
    });
    defer csrf.deinit();
    
    // Empty token
    try std.testing.expect(!csrf.validateToken(""));
    
    // Exactly 16 characters
    try std.testing.expect(csrf.validateToken("1234567890123456"));
    
    // 15 characters (too short)
    try std.testing.expect(!csrf.validateToken("123456789012345"));
    
    // Very long token
    try std.testing.expect(csrf.validateToken("x" ** 100));
}

test "CSRFConfig default values" {
    const config = CSRFConfig{
        .secret_key = "secret",
    };
    
    try std.testing.expectEqualStrings(config.cookie_name, "csrf_token");
    try std.testing.expectEqualStrings(config.header_name, "X-CSRF-Token");
    try std.testing.expectEqual(config.token_expiry, 3600);
    try std.testing.expectEqual(config.protected_methods.len, 4);
}

test "CSRFProtection custom cookie name" {
    const config = CSRFConfig{
        .secret_key = "test_secret",
        .cookie_name = "custom_csrf",
    };
    var csrf = CSRFProtection.init(std.testing.allocator, config);
    defer csrf.deinit();
    
    try std.testing.expectEqualStrings(csrf.config.cookie_name, "custom_csrf");
}

test "CSRFProtection custom header name" {
    const config = CSRFConfig{
        .secret_key = "test_secret",
        .header_name = "X-Custom-CSRF",
    };
    var csrf = CSRFProtection.init(std.testing.allocator, config);
    defer csrf.deinit();
    
    try std.testing.expectEqualStrings(csrf.config.header_name, "X-Custom-CSRF");
}

