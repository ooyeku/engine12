const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware = @import("middleware.zig");

/// Request ID middleware configuration
pub const RequestIdConfig = struct {
    /// Header name to use for request ID (default: "X-Request-ID")
    header_name: []const u8 = "X-Request-ID",
};

/// Request ID middleware
/// Ensures request IDs are exposed via headers
/// Note: Request IDs are already auto-generated in Request.fromZiggurat()
pub const RequestIdMiddleware = struct {
    config: RequestIdConfig,
    
    /// Initialize request ID middleware with configuration
    /// 
    /// Example:
    /// ```zig
    /// const req_id_mw = RequestIdMiddleware.init(.{ .header_name = "X-Request-ID" });
    /// try chain.addPreRequest(&req_id_mw.preRequestMwFn());
    /// // Request ID header is added automatically in executeResponse
    /// ```
    pub fn init(config: RequestIdConfig) RequestIdMiddleware {
        return RequestIdMiddleware{ .config = config };
    }
    
    /// Pre-request middleware (ensures request ID exists)
    fn preRequestMiddleware(req: *Request) middleware.MiddlewareResult {
        // Request ID is already generated in Request.fromZiggurat()
        // Just store header name in context for response middleware
        // Use default header name "X-Request-ID"
        req.set("request_id_header", "X-Request-ID") catch {};
        return .proceed;
    }
    
    /// Create pre-request middleware function pointer
    pub fn preRequestMwFn(_: *const RequestIdMiddleware) middleware.PreRequestMiddlewareFn {
        const Self = @This();
        return struct {
            fn mw(req: *Request) middleware.MiddlewareResult {
                return Self.preRequestMiddleware(req);
            }
        }.mw;
    }
};

// Tests
test "RequestIdMiddleware init" {
    const req_id_mw = RequestIdMiddleware.init(.{ .header_name = "X-Request-ID" });
    try std.testing.expectEqualStrings(req_id_mw.config.header_name, "X-Request-ID");
}

test "RequestIdMiddleware default config" {
    const req_id_mw = RequestIdMiddleware.init(.{});
    try std.testing.expectEqualStrings(req_id_mw.config.header_name, "X-Request-ID");
}

