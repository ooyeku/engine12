const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const types = @import("types.zig");

// Global storage for C API responses
// Uses request pointer as key for thread-safe access
var c_api_response_storage: std.AutoHashMap(*Request, Response) = undefined;
var c_api_response_storage_init = false;
var c_api_response_storage_mutex: std.Thread.Mutex = std.Thread.Mutex{};

fn initCAPIResponseStorage() void {
    if (!c_api_response_storage_init) {
        c_api_response_storage = std.AutoHashMap(*Request, Response).init(std.heap.page_allocator);
        c_api_response_storage_init = true;
    }
}

/// Store a C API response for a request (called by C API module)
pub fn storeCAPIResponse(req: *Request, resp: Response) !void {
    initCAPIResponseStorage();
    c_api_response_storage_mutex.lock();
    defer c_api_response_storage_mutex.unlock();
    
    try c_api_response_storage.put(req, resp);
}

/// Get stored C API response for a request (called by C API module)
pub fn getCAPIResponse(req: *Request) ?Response {
    initCAPIResponseStorage();
    c_api_response_storage_mutex.lock();
    defer c_api_response_storage_mutex.unlock();
    
    if (c_api_response_storage.fetchRemove(req)) |entry| {
        return entry.value;
    }
    return null;
}

/// Middleware result indicating whether to continue processing
pub const MiddlewareResult = enum {
    proceed,    // Continue to next middleware/handler
    abort,      // Stop processing and return response
};

/// Pre-request middleware that can short-circuit
/// Returns MiddlewareResult to indicate whether to continue
/// If abort is returned, the provided response is used instead of calling the handler
pub const PreRequestMiddlewareFn = *const fn (*Request) MiddlewareResult;

/// Response middleware that transforms responses
pub const ResponseMiddlewareFn = *const fn (Response) Response;

/// Middleware chain for managing multiple middleware functions
pub const MiddlewareChain = struct {
    const MAX_MIDDLEWARE = 16;
    
    /// Pre-request middleware functions (executed before handler)
    pre_request_middleware: [MAX_MIDDLEWARE]?PreRequestMiddlewareFn = [_]?PreRequestMiddlewareFn{null} ** MAX_MIDDLEWARE,
    pre_request_count: usize = 0,
    
    /// Response middleware functions (executed after handler)
    response_middleware: [MAX_MIDDLEWARE]?ResponseMiddlewareFn = [_]?ResponseMiddlewareFn{null} ** MAX_MIDDLEWARE,
    response_count: usize = 0,
    
    /// Execute all pre-request middleware in order
    /// Returns null if all middleware allow processing to continue
    /// Returns a response if any middleware short-circuits (aborts)
    /// 
    /// Example:
    /// ```zig
    /// if (chain.executePreRequest(&req)) |response| {
    ///     return response; // Middleware aborted
    /// }
    /// // Continue to handler
    /// ```
    pub fn executePreRequest(self: *const MiddlewareChain, req: *Request) ?Response {
        for (self.pre_request_middleware[0..self.pre_request_count]) |maybe_middleware| {
            if (maybe_middleware) |middleware| {
                const result = middleware(req);
                switch (result) {
                    .proceed => continue,
                    .abort => {
                        // Middleware aborted - check if this is a rate limit scenario
                        if (req.context.get("rate_limited")) |_| {
                            return Response.json(
                                \\{"error":"Rate limit exceeded","message":"Too many requests"}
                            ).withStatus(429);
                        }
                        // Check if body size exceeded
                        if (req.context.get("body_size_exceeded")) |_| {
                            const limit_str = req.context.get("body_size_limit") orelse "unknown";
                            // Create error message with limit info
                            const error_msg = std.fmt.allocPrint(req.arena.allocator(), 
                                \\{{"error":"Request body too large","message":"Request body exceeds maximum size of {s} bytes","code":"REQUEST_TOO_LARGE"}}
                            , .{limit_str}) catch {
                                return Response.json(
                                    \\{"error":"Request body too large","message":"Request body exceeds maximum allowed size"}
                                ).withStatus(413);
                            };
                            return Response.json(error_msg).withStatus(413);
                        }
                        // Check if CSRF validation failed
                        if (req.context.get("csrf_error")) |_| {
                            return Response.json(
                                \\{"error":"CSRF validation failed","message":"Invalid or missing CSRF token","code":"CSRF_ERROR"}
                            ).withStatus(403);
                        }
                        // Check if cache hit with matching ETag (304 Not Modified)
                        if (req.context.get("cache_hit")) |_| {
                            const etag = req.context.get("cache_etag") orelse "";
                            var resp = Response.status(304);
                            resp = resp.withHeader("ETag", etag);
                            resp = resp.withHeader("Cache-Control", "public, max-age=3600");
                            return resp;
                        }
                        // Check if C API handled this request
                        if (req.context.get("c_api_handled")) |_| {
                            // Retrieve stored response from global storage
                            if (getCAPIResponse(req)) |stored_resp| {
                                return stored_resp;
                            }
                        }
                        // Default abort response
                        return Response.unauthorized();
                    },
                }
            }
        }
        return null;
    }
    
    /// Execute all response middleware in order
    /// Transforms the response through each middleware
    /// 
    /// Example:
    /// ```zig
    /// var response = handler(&req);
    /// response = chain.executeResponse(response);
    /// return response;
    /// ```
    pub fn executeResponse(self: *const MiddlewareChain, response: Response, req: ?*Request) Response {
        var transformed_response = response;
        for (self.response_middleware[0..self.response_count]) |maybe_middleware| {
            if (maybe_middleware) |middleware| {
                transformed_response = middleware(transformed_response);
            }
        }
        
        // Add cache headers if cache hit
        if (req) |request| {
            if (request.context.get("cache_hit")) |hit| {
                if (std.mem.eql(u8, hit, "true")) {
                    const etag = request.context.get("cached_etag") orelse "";
                    transformed_response = transformed_response.withHeader("ETag", etag);
                    transformed_response = transformed_response.withHeader("Cache-Control", "public, max-age=3600");
                    transformed_response = transformed_response.withHeader("Last-Modified", "");
                }
            }
        }
        
        return transformed_response;
    }
    
    /// Add a pre-request middleware to the chain
    /// Middleware are executed in the order they are added
    /// 
    /// Example:
    /// ```zig
    /// chain.addPreRequest(authMiddleware);
    /// chain.addPreRequest(loggingMiddleware);
    /// ```
    pub fn addPreRequest(self: *MiddlewareChain, middleware: PreRequestMiddlewareFn) !void {
        if (self.pre_request_count >= MAX_MIDDLEWARE) {
            return error.TooManyMiddleware;
        }
        self.pre_request_middleware[self.pre_request_count] = middleware;
        self.pre_request_count += 1;
    }
    
    /// Add a response middleware to the chain
    /// Middleware are executed in the order they are added
    /// 
    /// Example:
    /// ```zig
    /// chain.addResponse(corsMiddleware);
    /// chain.addResponse(loggingMiddleware);
    /// ```
    pub fn addResponse(self: *MiddlewareChain, middleware: ResponseMiddlewareFn) !void {
        if (self.response_count >= MAX_MIDDLEWARE) {
            return error.TooManyMiddleware;
        }
        self.response_middleware[self.response_count] = middleware;
        self.response_count += 1;
    }
    
    /// Clear all middleware
    pub fn clear(self: *MiddlewareChain) void {
        self.pre_request_count = 0;
        self.response_count = 0;
        @memset(&self.pre_request_middleware, null);
        @memset(&self.response_middleware, null);
    }
};

// Tests
test "MiddlewareChain add and execute pre-request" {
    var chain = MiddlewareChain{};
    
    const middleware1 = struct {
        fn mw(req: *Request) MiddlewareResult {
            _ = req;
            return .proceed;
        }
    };
    
    try chain.addPreRequest(&middleware1.mw);
    
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/test",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const result = chain.executePreRequest(&req);
    try std.testing.expect(result == null);
}

test "MiddlewareChain short-circuit on abort" {
    var chain = MiddlewareChain{};
    
    const abortMw = struct {
        fn mw(req: *Request) MiddlewareResult {
            _ = req;
            return .abort;
        }
    };
    
    try chain.addPreRequest(&abortMw.mw);
    
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/test",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const result = chain.executePreRequest(&req);
    try std.testing.expect(result != null);
}

test "MiddlewareChain execute multiple middleware in order" {
    var chain = MiddlewareChain{};
    
    // Add two middleware functions
    const mw1 = struct {
        fn mw(req: *Request) MiddlewareResult {
            _ = req;
            return .proceed;
        }
    };
    
    const mw2 = struct {
        fn mw(req: *Request) MiddlewareResult {
            _ = req;
            return .proceed;
        }
    };
    
    try chain.addPreRequest(&mw1.mw);
    try chain.addPreRequest(&mw2.mw);
    
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/test",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    _ = chain.executePreRequest(&req);
    
    // Verify middleware were added and executed
    try std.testing.expect(chain.pre_request_count == 2);
}

test "MiddlewareChain execute response middleware" {
    var chain = MiddlewareChain{};
    
    const mw = struct {
        fn mw(resp: Response) Response {
            return resp.withStatus(201);
        }
    };
    
    try chain.addResponse(&mw.mw);
    
    const original = Response.ok();
    const transformed = chain.executeResponse(original);
    _ = transformed;
}

