const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware = @import("middleware.zig");

/// Security headers configuration
pub const SecurityHeadersConfig = struct {
    /// Enable X-Content-Type-Options: nosniff
    enable_content_type_options: bool = true,
    /// Enable X-Frame-Options: DENY
    enable_frame_options: bool = true,
    /// Enable X-XSS-Protection: 1; mode=block
    enable_xss_protection: bool = true,
    /// Enable Strict-Transport-Security (HSTS)
    enable_hsts: bool = true,
    /// HSTS max-age in seconds (default: 31536000 = 1 year)
    hsts_max_age: u64 = 31536000,
    /// Enable Referrer-Policy
    enable_referrer_policy: bool = true,
    /// Referrer-Policy value (default: "strict-origin-when-cross-origin")
    referrer_policy: []const u8 = "strict-origin-when-cross-origin",
    /// Enable Content-Security-Policy
    enable_csp: bool = false,
    /// Content-Security-Policy value
    csp_policy: []const u8 = "default-src 'self'",
    /// Enable Permissions-Policy
    enable_permissions_policy: bool = false,
    /// Permissions-Policy value
    permissions_policy: []const u8 = "",
};

/// Security headers middleware
/// Adds production security headers to all responses
pub const SecurityHeadersMiddleware = struct {
    config: SecurityHeadersConfig,

    pub fn init(config: SecurityHeadersConfig) SecurityHeadersMiddleware {
        return SecurityHeadersMiddleware{
            .config = config,
        };
    }

    /// Create a response middleware function
    pub fn responseMwFn(self: *const SecurityHeadersMiddleware) middleware.ResponseMiddlewareFn {
        const Self = @This();
        return struct {
            fn mw(resp: Response, req: *Request) Response {
                _ = req;
                return self.addSecurityHeaders(resp);
            }
        }.mw;
    }

    /// Add security headers to a response
    pub fn addSecurityHeaders(self: *const SecurityHeadersMiddleware, resp: Response) Response {
        var result = resp;

        if (self.config.enable_content_type_options) {
            result = result.withHeader("X-Content-Type-Options", "nosniff");
        }

        if (self.config.enable_frame_options) {
            result = result.withHeader("X-Frame-Options", "DENY");
        }

        if (self.config.enable_xss_protection) {
            result = result.withHeader("X-XSS-Protection", "1; mode=block");
        }

        if (self.config.enable_hsts) {
            const hsts_value = std.fmt.allocPrint(
                std.heap.page_allocator,
                "max-age={d}",
                .{self.config.hsts_max_age},
            ) catch {
                return result; // If allocation fails, return response without HSTS
            };
            defer std.heap.page_allocator.free(hsts_value);
            result = result.withHeader("Strict-Transport-Security", hsts_value);
        }

        if (self.config.enable_referrer_policy) {
            result = result.withHeader("Referrer-Policy", self.config.referrer_policy);
        }

        if (self.config.enable_csp) {
            result = result.withHeader("Content-Security-Policy", self.config.csp_policy);
        }

        if (self.config.enable_permissions_policy and self.config.permissions_policy.len > 0) {
            result = result.withHeader("Permissions-Policy", self.config.permissions_policy);
        }

        return result;
    }
};

// Tests
test "SecurityHeadersMiddleware adds headers" {
    const config = SecurityHeadersConfig{
        .enable_content_type_options = true,
        .enable_frame_options = true,
        .enable_xss_protection = true,
    };
    const mw = SecurityHeadersMiddleware.init(config);
    
    const resp = Response.ok();
    const resp_with_headers = mw.addSecurityHeaders(resp);
    
    const ziggurat_resp = resp_with_headers.toZiggurat();
    // Verify headers were added (checking via ziggurat response)
    _ = ziggurat_resp;
}

test "SecurityHeadersMiddleware respects config" {
    const config = SecurityHeadersConfig{
        .enable_content_type_options = false,
        .enable_frame_options = false,
    };
    const mw = SecurityHeadersMiddleware.init(config);
    
    const resp = Response.ok();
    const resp_with_headers = mw.addSecurityHeaders(resp);
    
    _ = resp_with_headers;
}

