const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

/// Error types that can occur during request processing
pub const ErrorType = enum {
    validation_error,
    authentication_error,
    authorization_error,
    not_found,
    bad_request,
    internal_error,
    rate_limit_exceeded,
    request_too_large,
    timeout,
    unknown,
};

/// Structured error response
pub const ErrorResponse = struct {
    error_type: ErrorType,
    message: []const u8,
    code: []const u8,
    details: ?[]const u8,
    timestamp: i64,
    
    /// Convert error response to JSON
    pub fn toJson(self: *const ErrorResponse, allocator: std.mem.Allocator) ![]const u8 {
        var json = std.ArrayListUnmanaged(u8){};
        const writer = json.writer(allocator);
        
        try writer.print(
            "{{\"error\":{{\"type\":\"{s}\",\"message\":\"{s}\",\"code\":\"{s}\",\"timestamp\":{d}",
            .{ @tagName(self.error_type), self.message, self.code, self.timestamp },
        );
        
        if (self.details) |details| {
            try writer.print(",\"details\":\"{s}\"", .{details});
        }
        
        try writer.print("}}}}", .{});
        
        return json.toOwnedSlice(allocator);
    }
    
    /// Create a validation error response
    pub fn validation(message: []const u8, details: ?[]const u8) ErrorResponse {
        return ErrorResponse{
            .error_type = .validation_error,
            .message = message,
            .code = "VALIDATION_ERROR",
            .details = details,
            .timestamp = std.time.milliTimestamp(),
        };
    }
    
    /// Create an authentication error response
    pub fn authentication(message: []const u8) ErrorResponse {
        return ErrorResponse{
            .error_type = .authentication_error,
            .message = message,
            .code = "AUTHENTICATION_ERROR",
            .details = null,
            .timestamp = std.time.milliTimestamp(),
        };
    }
    
    /// Create an authorization error response
    pub fn authorization(message: []const u8) ErrorResponse {
        return ErrorResponse{
            .error_type = .authorization_error,
            .message = message,
            .code = "AUTHORIZATION_ERROR",
            .details = null,
            .timestamp = std.time.milliTimestamp(),
        };
    }
    
    /// Create a not found error response
    pub fn notFound(message: []const u8) ErrorResponse {
        return ErrorResponse{
            .error_type = .not_found,
            .message = message,
            .code = "NOT_FOUND",
            .details = null,
            .timestamp = std.time.milliTimestamp(),
        };
    }
    
    /// Create a bad request error response
    pub fn badRequest(message: []const u8, details: ?[]const u8) ErrorResponse {
        return ErrorResponse{
            .error_type = .bad_request,
            .message = message,
            .code = "BAD_REQUEST",
            .details = details,
            .timestamp = std.time.milliTimestamp(),
        };
    }
    
    /// Create an internal error response
    pub fn internal(message: []const u8, details: ?[]const u8) ErrorResponse {
        return ErrorResponse{
            .error_type = .internal_error,
            .message = message,
            .code = "INTERNAL_ERROR",
            .details = details,
            .timestamp = std.time.milliTimestamp(),
        };
    }
    
    /// Create a rate limit error response
    pub fn rateLimit(message: []const u8) ErrorResponse {
        return ErrorResponse{
            .error_type = .rate_limit_exceeded,
            .message = message,
            .code = "RATE_LIMIT_EXCEEDED",
            .details = null,
            .timestamp = std.time.milliTimestamp(),
        };
    }
    
    /// Create a request too large error response
    pub fn requestTooLarge(message: []const u8) ErrorResponse {
        return ErrorResponse{
            .error_type = .request_too_large,
            .message = message,
            .code = "REQUEST_TOO_LARGE",
            .details = null,
            .timestamp = std.time.milliTimestamp(),
        };
    }
    
    /// Create a timeout error response
    pub fn timeout(message: []const u8) ErrorResponse {
        return ErrorResponse{
            .error_type = .timeout,
            .message = message,
            .code = "TIMEOUT",
            .details = null,
            .timestamp = std.time.milliTimestamp(),
        };
    }
    
    /// Convert error response to HTTP response
    pub fn toHttpResponse(self: *const ErrorResponse, allocator: std.mem.Allocator) !Response {
        const json = try self.toJson(allocator);
        defer allocator.free(json);
        
        const status_code: u16 = switch (self.error_type) {
            .validation_error, .bad_request => 400,
            .authentication_error => 401,
            .authorization_error => 403,
            .not_found => 404,
            .rate_limit_exceeded => 429,
            .request_too_large => 413,
            .timeout => 408,
            .internal_error, .unknown => 500,
        };
        
        var resp = Response.json(json);
        resp = resp.withStatus(status_code);
        return resp;
    }
};

/// Global error handler function type
pub const ErrorHandler = *const fn (*Request, ErrorResponse, std.mem.Allocator) Response;

/// Default error handler
pub fn defaultErrorHandler(req: *Request, err: ErrorResponse, allocator: std.mem.Allocator) Response {
    _ = req;
    const json = err.toJson(allocator) catch {
        return Response.internalError().json("{\"error\":\"Failed to serialize error\"}");
    };
    defer allocator.free(json);
    
    const status_code: u16 = switch (err.error_type) {
        .validation_error, .bad_request => 400,
        .authentication_error => 401,
        .authorization_error => 403,
        .not_found => 404,
        .rate_limit_exceeded => 429,
        .request_too_large => 413,
        .timeout => 408,
        .internal_error, .unknown => 500,
    };
    
    var resp = Response.json(json);
    resp = resp.withStatus(status_code);
    return resp;
}

/// Error handler registry
pub const ErrorHandlerRegistry = struct {
    handler: ?ErrorHandler = null,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ErrorHandlerRegistry {
        return ErrorHandlerRegistry{
            .handler = null,
            .allocator = allocator,
        };
    }
    
    /// Register a custom error handler
    pub fn register(self: *ErrorHandlerRegistry, handler_fn: ErrorHandler) void {
        self.handler = handler_fn;
    }
    
    /// Handle an error using the registered handler or default
    pub fn handle(self: *const ErrorHandlerRegistry, req: *Request, err: ErrorResponse) Response {
        if (self.handler) |handler_fn| {
            return handler_fn(req, err, self.allocator);
        }
        return defaultErrorHandler(req, err, self.allocator);
    }
};

// Tests
test "ErrorResponse validation" {
    const err = ErrorResponse.validation("Validation failed", "Field 'name' is required");
    try std.testing.expectEqual(err.error_type, ErrorType.validation_error);
    try std.testing.expectEqualStrings(err.code, "VALIDATION_ERROR");
}

test "ErrorResponse toJson" {
    const err = ErrorResponse.badRequest("Invalid input", null);
    const json = try err.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    
    try std.testing.expect(std.mem.indexOf(u8, json, "BAD_REQUEST") != null);
}

test "ErrorHandlerRegistry default handler" {
    var registry = ErrorHandlerRegistry.init(std.testing.allocator);
    const err = ErrorResponse.notFound("Resource not found");
    
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/test",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const resp = registry.handle(&req, err);
    _ = resp;
}

