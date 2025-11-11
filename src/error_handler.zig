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
    /// Request ID for correlation tracking
    request_id: ?[]const u8 = null,
    /// Request path that caused the error
    path: ?[]const u8 = null,
    /// HTTP method that caused the error
    method: ?[]const u8 = null,
    
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
        
        if (self.request_id) |req_id| {
            try writer.print(",\"request_id\":\"{s}\"", .{req_id});
        }
        
        if (self.path) |p| {
            try writer.print(",\"path\":\"{s}\"", .{p});
        }
        
        if (self.method) |m| {
            try writer.print(",\"method\":\"{s}\"", .{m});
        }
        
        try writer.print("}}}}", .{});
        
        return json.toOwnedSlice(allocator);
    }
    
    /// Create an error response from a request context
    /// Automatically includes request ID, path, and method
    pub fn fromRequest(req: *Request, error_type: ErrorType, message: []const u8, code: []const u8, details: ?[]const u8) ErrorResponse {
        return ErrorResponse{
            .error_type = error_type,
            .message = message,
            .code = code,
            .details = details,
            .timestamp = std.time.milliTimestamp(),
            .request_id = req.requestId(),
            .path = req.path(),
            .method = req.method(),
        };
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

test "ErrorResponse all error types" {
    const validation = ErrorResponse.validation("Validation failed", "Details");
    try std.testing.expectEqual(validation.error_type, ErrorType.validation_error);
    
    const auth = ErrorResponse.authentication("Auth failed");
    try std.testing.expectEqual(auth.error_type, ErrorType.authentication_error);
    
    const authz = ErrorResponse.authorization("Not authorized");
    try std.testing.expectEqual(authz.error_type, ErrorType.authorization_error);
    
    const notFound = ErrorResponse.notFound("Not found");
    try std.testing.expectEqual(notFound.error_type, ErrorType.not_found);
    
    const badReq = ErrorResponse.badRequest("Bad request", "Details");
    try std.testing.expectEqual(badReq.error_type, ErrorType.bad_request);
    
    const internal = ErrorResponse.internal("Internal error", "Details");
    try std.testing.expectEqual(internal.error_type, ErrorType.internal_error);
    
    const rateLimit = ErrorResponse.rateLimit("Rate limited");
    try std.testing.expectEqual(rateLimit.error_type, ErrorType.rate_limit_exceeded);
    
    const tooLarge = ErrorResponse.requestTooLarge("Too large");
    try std.testing.expectEqual(tooLarge.error_type, ErrorType.request_too_large);
    
    const timeout = ErrorResponse.timeout("Timeout");
    try std.testing.expectEqual(timeout.error_type, ErrorType.timeout);
}

test "ErrorResponse toJson includes all fields" {
    const err = ErrorResponse.validation("Test message", "Test details");
    const json = try err.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    
    try std.testing.expect(std.mem.indexOf(u8, json, "validation_error") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Test message") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "VALIDATION_ERROR") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Test details") != null);
}

test "ErrorResponse toJson without details" {
    const err = ErrorResponse.notFound("Not found");
    const json = try err.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    
    try std.testing.expect(std.mem.indexOf(u8, json, "not_found") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Not found") != null);
    // Should not include details field when null
}

test "ErrorResponse toHttpResponse maps error types correctly" {
    const allocator = std.testing.allocator;
    
    const validation = ErrorResponse.validation("Test", null);
    const resp1 = try validation.toHttpResponse(allocator);
    _ = resp1;
    
    const auth = ErrorResponse.authentication("Test");
    const resp2 = try auth.toHttpResponse(allocator);
    _ = resp2;
    
    const authz = ErrorResponse.authorization("Test");
    const resp3 = try authz.toHttpResponse(allocator);
    _ = resp3;
    
    const notFound = ErrorResponse.notFound("Test");
    const resp4 = try notFound.toHttpResponse(allocator);
    _ = resp4;
    
    const rateLimit = ErrorResponse.rateLimit("Test");
    const resp5 = try rateLimit.toHttpResponse(allocator);
    _ = resp5;
    
    const tooLarge = ErrorResponse.requestTooLarge("Test");
    const resp6 = try tooLarge.toHttpResponse(allocator);
    _ = resp6;
    
    const timeout = ErrorResponse.timeout("Test");
    const resp7 = try timeout.toHttpResponse(allocator);
    _ = resp7;
    
    const internal = ErrorResponse.internal("Test", null);
    const resp8 = try internal.toHttpResponse(allocator);
    _ = resp8;
}

test "ErrorHandlerRegistry register custom handler" {
    var registry = ErrorHandlerRegistry.init(std.testing.allocator);
    
    const custom_handler = struct {
        fn handler(req: *Request, err: ErrorResponse, allocator: std.mem.Allocator) Response {
            _ = req;
            _ = err;
            _ = allocator;
            return Response.text("Custom error");
        }
    }.handler;
    
    registry.register(custom_handler);
    
    const err = ErrorResponse.notFound("Test");
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

test "ErrorResponse timestamp is set" {
    const err = ErrorResponse.validation("Test", null);
    try std.testing.expect(err.timestamp > 0);
    
    // Timestamp should be recent (within last second)
    const now = std.time.milliTimestamp();
    try std.testing.expect(err.timestamp <= now);
    try std.testing.expect(err.timestamp >= now - 1000);
}

test "ErrorResponse error codes are correct" {
    try std.testing.expectEqualStrings(ErrorResponse.validation("", null).code, "VALIDATION_ERROR");
    try std.testing.expectEqualStrings(ErrorResponse.authentication("").code, "AUTHENTICATION_ERROR");
    try std.testing.expectEqualStrings(ErrorResponse.authorization("").code, "AUTHORIZATION_ERROR");
    try std.testing.expectEqualStrings(ErrorResponse.notFound("").code, "NOT_FOUND");
    try std.testing.expectEqualStrings(ErrorResponse.badRequest("", null).code, "BAD_REQUEST");
    try std.testing.expectEqualStrings(ErrorResponse.internal("", null).code, "INTERNAL_ERROR");
    try std.testing.expectEqualStrings(ErrorResponse.rateLimit("").code, "RATE_LIMIT_EXCEEDED");
    try std.testing.expectEqualStrings(ErrorResponse.requestTooLarge("").code, "REQUEST_TOO_LARGE");
    try std.testing.expectEqualStrings(ErrorResponse.timeout("").code, "TIMEOUT");
}

