const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware_chain = @import("middleware.zig");

/// Request body size limit configuration
pub const BodySizeLimit = struct {
    /// Maximum body size in bytes
    max_bytes: u64,
    
    /// Custom error message when limit is exceeded
    error_message: []const u8 = "Request body too large",
};

/// Default body size limits
pub const DefaultLimits = struct {
    /// Default limit for JSON requests (1MB)
    pub const json: u64 = 1024 * 1024;
    
    /// Default limit for form data (10MB)
    pub const form_data: u64 = 10 * 1024 * 1024;
    
    /// Default limit for file uploads (50MB)
    pub const file_upload: u64 = 50 * 1024 * 1024;
    
    /// Default limit for general requests (5MB)
    pub const general: u64 = 5 * 1024 * 1024;
};

/// Create a body size limit middleware
/// Checks request body size before processing
/// Returns .abort if body exceeds limit
pub fn createBodySizeLimitMiddleware(limit: BodySizeLimit) middleware_chain.PreRequestMiddlewareFn {
    return struct {
        fn mw(req: *Request) middleware_chain.MiddlewareResult {
            const body = req.body();
            
            if (body.len > limit.max_bytes) {
                // Mark request as having exceeded body size limit
                req.context.put("body_size_exceeded", "true") catch {};
                const limit_str = std.fmt.allocPrint(req.arena.allocator(), "{d}", .{limit.max_bytes}) catch "unknown";
                req.context.put("body_size_limit", limit_str) catch {};
                return .abort;
            }
            
            return .proceed;
        }
    }.mw;
}

/// Create a body size limit middleware with default limits based on content type
pub fn createContentTypeBodySizeLimitMiddleware() middleware_chain.PreRequestMiddlewareFn {
    return struct {
        fn mw(req: *Request) middleware_chain.MiddlewareResult {
            const body = req.body();
            const content_type = req.header("Content-Type") orelse "";
            
            var limit: u64 = DefaultLimits.general;
            
            // Check content type and set appropriate limit
            if (std.mem.indexOf(u8, content_type, "application/json") != null) {
                limit = DefaultLimits.json;
            } else if (std.mem.indexOf(u8, content_type, "multipart/form-data") != null) {
                limit = DefaultLimits.file_upload;
            } else if (std.mem.indexOf(u8, content_type, "application/x-www-form-urlencoded") != null) {
                limit = DefaultLimits.form_data;
            }
            
            if (body.len > limit) {
                req.context.put("body_size_exceeded", "true") catch {};
                const limit_str = std.fmt.allocPrint(req.arena.allocator(), "{d}", .{limit}) catch "unknown";
                req.context.put("body_size_limit", limit_str) catch {};
                return .abort;
            }
            
            return .proceed;
        }
    }.mw;
}

// Tests
test "createBodySizeLimitMiddleware allows requests within limit" {
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/test",
        .method = .POST,
        .body = "small body",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const mw = createBodySizeLimitMiddleware(BodySizeLimit{
        .max_bytes = 1000,
    });
    
    const result = mw(&req);
    try std.testing.expectEqual(result, .proceed);
}

test "createBodySizeLimitMiddleware rejects requests exceeding limit" {
    var large_body = std.ArrayList(u8).init(std.testing.allocator);
    defer large_body.deinit();
    try large_body.writer().print("{s}", .{"x"} ** 2000); // Create 2000 byte body
    
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/test",
        .method = .POST,
        .body = large_body.items,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const mw = createBodySizeLimitMiddleware(BodySizeLimit{
        .max_bytes = 1000,
    });
    
    const result = mw(&req);
    try std.testing.expectEqual(result, .abort);
    
    // Verify context was set
    try std.testing.expect(req.context.get("body_size_exceeded") != null);
}

test "createContentTypeBodySizeLimitMiddleware sets appropriate limits" {
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/test",
        .method = .POST,
        .body = "small",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const mw = createContentTypeBodySizeLimitMiddleware();
    const result = mw(&req);
    try std.testing.expectEqual(result, .proceed);
}

