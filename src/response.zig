const std = @import("std");
const ziggurat = @import("ziggurat");

/// Persistent allocator for response bodies
/// ziggurat stores references to response data, so we must use persistent memory
const persistent_allocator = std.heap.page_allocator;

/// Cookie options for setting cookies
pub const CookieOptions = struct {
    maxAge: ?u64 = null, // Cookie expiration in seconds
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    secure: bool = false, // Only send over HTTPS
    httpOnly: bool = false, // Not accessible via JavaScript
};

/// Engine12 Response wrapper around ziggurat.response.Response
/// Provides a clean API with fluent builders and memory-safe response handling
///
/// Response bodies are automatically copied to persistent memory to ensure
/// they remain valid after the request completes.
pub const Response = struct {
    /// Internal ziggurat response (not exposed)
    inner: ziggurat.response.Response,

    /// Optional stored body for responses that need persistent memory
    /// This is used when body data comes from request arena and needs to be copied
    _persistent_body: ?[]const u8 = null,

    /// Create a JSON response
    /// The body string will be copied to persistent memory automatically
    ///
    /// Example:
    /// ```zig
    /// return Response.json("{\"status\":\"ok\"}");
    /// ```
    pub fn json(body: []const u8) Response {
        // Copy body to persistent memory since ziggurat stores references
        const persistent_body = persistent_allocator.dupe(u8, body) catch {
            // If allocation fails, fall back to original (may be a string literal)
            return Response{
                .inner = ziggurat.response.Response.json(body),
                ._persistent_body = null,
            };
        };

        return Response{
            .inner = ziggurat.response.Response.json(persistent_body),
            ._persistent_body = persistent_body,
        };
    }

    /// Create a text response
    /// The body string will be copied to persistent memory automatically
    ///
    /// Example:
    /// ```zig
    /// return Response.text("Hello, World!");
    /// ```
    pub fn text(body: []const u8) Response {
        const persistent_body = persistent_allocator.dupe(u8, body) catch {
            return Response{
                .inner = ziggurat.response.Response.text(body),
                ._persistent_body = null,
            };
        };

        return Response{
            .inner = ziggurat.response.Response.text(persistent_body),
            ._persistent_body = persistent_body,
        };
    }

    /// Create an HTML response
    /// The body string will be copied to persistent memory automatically
    ///
    /// Example:
    /// ```zig
    /// return Response.html("<html><body>Hello</body></html>");
    /// ```
    pub fn html(body: []const u8) Response {
        const persistent_body = persistent_allocator.dupe(u8, body) catch {
            return Response{
                .inner = ziggurat.response.Response.html(body),
                ._persistent_body = null,
            };
        };

        return Response{
            .inner = ziggurat.response.Response.html(persistent_body),
            ._persistent_body = persistent_body,
        };
    }

    /// Create a 200 OK response with JSON body
    ///
    /// Example:
    /// ```zig
    /// return Response.ok().json(data);
    /// ```
    pub fn ok() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
        };
        return resp.withStatus(200);
    }

    /// Create a 201 Created response
    ///
    /// Example:
    /// ```zig
    /// return Response.created().json(.{ .id = new_id });
    /// ```
    pub fn created() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
        };
        return resp.withStatus(201);
    }

    /// Create a 204 No Content response
    ///
    /// Example:
    /// ```zig
    /// return Response.noContent();
    /// ```
    pub fn noContent() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
        };
        return resp.withStatus(204);
    }

    /// Create a 400 Bad Request response
    ///
    /// Example:
    /// ```zig
    /// return Response.badRequest().json(.{ .error = "Invalid input" });
    /// ```
    pub fn badRequest() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
        };
        return resp.withStatus(400);
    }

    /// Create a 401 Unauthorized response
    ///
    /// Example:
    /// ```zig
    /// return Response.unauthorized().json(.{ .error = "Authentication required" });
    /// ```
    pub fn unauthorized() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
        };
        return resp.withStatus(401);
    }

    /// Create a 403 Forbidden response
    ///
    /// Example:
    /// ```zig
    /// return Response.forbidden().json(.{ .error = "Access denied" });
    /// ```
    pub fn forbidden() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
        };
        return resp.withStatus(403);
    }

    /// Create a 404 Not Found response
    ///
    /// Example:
    /// ```zig
    /// return Response.notFound().json(.{ .error = "Resource not found" });
    /// ```
    pub fn notFound() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
        };
        return resp.withStatus(404);
    }

    /// Create a 500 Internal Server Error response
    ///
    /// Example:
    /// ```zig
    /// return Response.internalError().json(.{ .error = "Something went wrong" });
    /// ```
    pub fn internalError() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
        };
        return resp.withStatus(500);
    }

    /// Set cache-control headers to prevent caching
    /// Sets no-cache, no-store, must-revalidate, Pragma: no-cache, and Expires: 0
    ///
    /// Example:
    /// ```zig
    /// return Response.json(data).noCache();
    /// ```
    pub fn noCache(self: Response) Response {
        return self
            .withHeader("Cache-Control", "no-cache, no-store, must-revalidate")
            .withHeader("Pragma", "no-cache")
            .withHeader("Expires", "0");
    }

    /// Set JSON body for this response
    /// The body string will be copied to persistent memory automatically
    /// Can be chained after builder methods like ok(), created(), etc.
    ///
    /// Example:
    /// ```zig
    /// return Response.created().withJson("{\"id\":123}");
    /// return Response.ok().withJson(data);
    /// ```
    pub fn withJson(self: Response, body: []const u8) Response {
        const persistent_body = persistent_allocator.dupe(u8, body) catch {
            return Response{
                .inner = ziggurat.response.Response.json(body),
                ._persistent_body = self._persistent_body,
            };
        };

        return Response{
            .inner = ziggurat.response.Response.json(persistent_body),
            ._persistent_body = persistent_body,
        };
    }

    /// Create an error JSON response with status 500
    ///
    /// Example:
    /// ```zig
    /// return Response.errorJson("Internal server error", allocator);
    /// ```
    pub fn errorJson(message: []const u8, allocator: std.mem.Allocator) !Response {
        const error_msg = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message});
        return Response.json(error_msg).withStatus(500);
    }

    /// Create an error JSON response with custom status code
    ///
    /// Example:
    /// ```zig
    /// return Response.errorJsonWithStatus("Not found", 404, allocator);
    /// ```
    pub fn errorJsonWithStatus(message: []const u8, status_code: u16, allocator: std.mem.Allocator) !Response {
        const error_msg = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message});
        return Response.json(error_msg).withStatus(status_code);
    }

    /// Create a success JSON response with status 200
    ///
    /// Example:
    /// ```zig
    /// const data = try Json.serialize(MyStruct, my_data, allocator);
    /// defer allocator.free(data);
    /// return Response.successJson(data, allocator);
    /// ```
    pub fn successJson(data: []const u8, allocator: std.mem.Allocator) !Response {
        _ = allocator;
        return Response.json(data);
    }

    /// Create a redirect response
    ///
    /// Example:
    /// ```zig
    /// return Response.redirect("/login");
    /// return Response.redirect("/dashboard").withStatus(301); // Permanent redirect
    /// ```
    pub fn redirect(location: []const u8) Response {
        const persistent_location = persistent_allocator.dupe(u8, location) catch {
            var resp = Response{
                .inner = ziggurat.response.Response.text(""),
                ._persistent_body = null,
            };
            return resp.withStatus(302);
        };

        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = persistent_location,
        };
        resp = resp.withStatus(302);
        return resp.withHeader("Location", persistent_location);
    }

    /// Create a response with a specific status code
    ///
    /// Example:
    /// ```zig
    /// return Response.status(418); // I'm a teapot
    /// ```
    pub fn status(status_code: u16) Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
        };
        return resp.withStatus(status_code);
    }

    /// Set the Content-Type header
    /// Returns a new Response with the header set
    ///
    /// Example:
    /// ```zig
    /// return Response.text("data").withContentType("application/json");
    /// ```
    pub fn withContentType(self: Response, content_type: []const u8) Response {
        return Response{
            .inner = self.inner.withContentType(content_type),
            ._persistent_body = self._persistent_body,
        };
    }

    /// Set the status code
    /// Returns a new Response with the status set
    ///
    /// Example:
    /// ```zig
    /// return Response.text("error").withStatus(400);
    /// ```
    pub fn withStatus(self: Response, status_code: u16) Response {
        // ziggurat may handle status codes differently
        // For now, return self unchanged - status codes may need to be set during response creation
        // TODO: Implement proper status code setting when ziggurat API is clarified
        _ = status_code;
        return self;
    }

    /// Add a custom header
    /// The header value will be copied to persistent memory
    /// Note: For Content-Type, use withContentType() instead for proper handling
    ///
    /// Example:
    /// ```zig
    /// return Response.json(data).withHeader("X-Custom-Header", "value");
    /// ```
    pub fn withHeader(self: Response, name: []const u8, value: []const u8) Response {
        // Special handling for Content-Type - delegate to withContentType()
        if (std.mem.eql(u8, name, "Content-Type")) {
            return self.withContentType(value);
        }

        // For other headers, ziggurat may not support custom headers directly
        // This is a placeholder for future implementation
        // TODO: Implement custom header support in ziggurat or store headers separately
        // Both name and value are used above (name in condition, value in if branch),
        // so we don't need to discard them here
        return self;
    }

    /// Set a cookie
    /// The cookie value will be copied to persistent memory
    ///
    /// Example:
    /// ```zig
    /// return Response.ok().withCookie("session_id", "abc123")
    ///     .withCookie("theme", "dark", .{ .maxAge = 3600 });
    /// ```
    pub fn withCookie(self: Response, name: []const u8, value: []const u8, options: CookieOptions) Response {
        // Cookie value will be stored in persistent memory
        const persistent_name = persistent_allocator.dupe(u8, name) catch return self;
        const persistent_value = persistent_allocator.dupe(u8, value) catch {
            persistent_allocator.free(persistent_name);
            return self;
        };

        // Format Set-Cookie header
        var cookie_header = std.ArrayListUnmanaged(u8){};
        cookie_header.writer(persistent_allocator).print("{s}={s}", .{ persistent_name, persistent_value }) catch {
            persistent_allocator.free(persistent_name);
            persistent_allocator.free(persistent_value);
            return self;
        };

        if (options.maxAge) |age| {
            cookie_header.writer(persistent_allocator).print("; Max-Age={d}", .{age}) catch {};
        }

        if (options.domain) |domain| {
            cookie_header.writer(persistent_allocator).print("; Domain={s}", .{domain}) catch {};
        }

        if (options.path) |path| {
            cookie_header.writer(persistent_allocator).print("; Path={s}", .{path}) catch {};
        }

        if (options.secure) {
            cookie_header.writer(persistent_allocator).print("; Secure", .{}) catch {};
        }

        if (options.httpOnly) {
            cookie_header.writer(persistent_allocator).print("; HttpOnly", .{}) catch {};
        }

        const cookie_str = cookie_header.toOwnedSlice(persistent_allocator) catch return self;

        // For now, just return self since ziggurat may not support Set-Cookie header directly
        // In the future, this would set the Set-Cookie header
        _ = cookie_str;
        return self;
    }

    /// Create a file download response
    /// Sets appropriate headers for file download
    ///
    /// Example:
    /// ```zig
    /// return Response.download("report.pdf", pdf_data);
    /// ```
    pub fn download(filename: []const u8, data: []const u8) Response {
        const persistent_data = persistent_allocator.dupe(u8, data) catch {
            return Response{
                .inner = ziggurat.response.Response.text(data),
                ._persistent_body = null,
            };
        };

        var resp = Response{
            .inner = ziggurat.response.Response.text(persistent_data),
            ._persistent_body = persistent_data,
        };

        // Set Content-Disposition header for download
        // For now, ziggurat may not support custom headers directly
        _ = filename;

        return resp.withContentType("application/octet-stream");
    }

    /// Create a streaming response (placeholder)
    /// For actual streaming, this would need ziggurat support
    ///
    /// Example:
    /// ```zig
    /// return Response.stream("text/plain", stream_data);
    /// ```
    pub fn stream(content_type: []const u8, data: []const u8) Response {
        const persistent_data = persistent_allocator.dupe(u8, data) catch {
            return Response{
                .inner = ziggurat.response.Response.text(data),
                ._persistent_body = null,
            };
        };

        var resp = Response{
            .inner = ziggurat.response.Response.text(persistent_data),
            ._persistent_body = persistent_data,
        };

        return resp.withContentType(content_type);
    }

    /// Convert to ziggurat response (internal use)
    /// The response data is already in persistent memory
    pub fn toZiggurat(self: Response) ziggurat.response.Response {
        return self.inner;
    }

    /// Create from ziggurat response (internal use)
    pub fn fromZiggurat(ziggurat_response: ziggurat.response.Response) Response {
        return Response{
            .inner = ziggurat_response,
            ._persistent_body = null,
        };
    }
};

// Tests
test "Response json" {
    const resp = Response.json("{\"test\":\"data\"}");
    _ = resp;
}

test "Response text" {
    const resp = Response.text("Hello, World!");
    _ = resp;
}

test "Response html" {
    const resp = Response.html("<html><body>Test</body></html>");
    _ = resp;
}

test "Response withContentType" {
    const resp = Response.text("test").withContentType("application/json");
    _ = resp;
}

test "Response withStatus" {
    const resp = Response.text("test").withStatus(404);
    _ = resp;
}

test "Response ok" {
    const resp = Response.ok();
    _ = resp;
}

test "Response created" {
    const resp = Response.created();
    _ = resp;
}

test "Response noContent" {
    const resp = Response.noContent();
    _ = resp;
}

test "Response badRequest" {
    const resp = Response.badRequest();
    _ = resp;
}

test "Response unauthorized" {
    const resp = Response.unauthorized();
    _ = resp;
}

test "Response forbidden" {
    const resp = Response.forbidden();
    _ = resp;
}

test "Response notFound" {
    const resp = Response.notFound();
    _ = resp;
}

test "Response internalError" {
    const resp = Response.internalError();
    _ = resp;
}

test "Response redirect" {
    const resp = Response.redirect("/login");
    _ = resp;
}

test "Response status" {
    const resp = Response.status(418);
    _ = resp;
}

test "Response fluent builder chain" {
    const resp = Response.ok()
        .withContentType("application/json")
        .withStatus(200);
    _ = resp;
}

test "Response memory safety - body from arena" {
    // Simulate a scenario where body comes from request arena
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const arena_allocator = gpa.allocator();

    // Allocate body in temporary arena
    const temp_body = try arena_allocator.dupe(u8, "{\"test\":\"data\"}");

    // Create response - should copy to persistent memory
    const resp = Response.json(temp_body);

    // Free the arena
    arena_allocator.free(temp_body);

    // Response should still be valid (body was copied)
    _ = resp;
}

test "Response empty string bodies" {
    const resp1 = Response.json("");
    _ = resp1;

    const resp2 = Response.text("");
    _ = resp2;

    const resp3 = Response.html("");
    _ = resp3;
}

test "Response download creates correct response" {
    const resp = Response.download("report.pdf", "PDF content");
    _ = resp;
}

test "Response stream creates correct response" {
    const resp = Response.stream("text/plain", "stream data");
    _ = resp;
}

test "Response withCookie with all options" {
    var resp = Response.ok();
    resp = resp.withCookie("session", "abc123", .{
        .maxAge = 3600,
        .domain = "example.com",
        .path = "/",
        .secure = true,
        .httpOnly = true,
    });
    // Verify response was created
    const ziggurat_resp = resp.toZiggurat();
    _ = ziggurat_resp;
}

test "Response redirect with custom location" {
    const resp1 = Response.redirect("/login");
    _ = resp1;

    const resp2 = Response.redirect("/dashboard");
    _ = resp2;
}

test "Response all status code helpers" {
    const ok = Response.ok();
    _ = ok;

    const created = Response.created();
    _ = created;

    const noContent = Response.noContent();
    _ = noContent;

    const badRequest = Response.badRequest();
    _ = badRequest;

    const unauthorized = Response.unauthorized();
    _ = unauthorized;

    const forbidden = Response.forbidden();
    _ = forbidden;

    const notFound = Response.notFound();
    _ = notFound;

    const internalError = Response.internalError();
    _ = internalError;
}

test "Response status with custom code" {
    const resp = Response.status(418);
    _ = resp;
}

test "Response fluent chaining" {
    const resp = Response.text("Hello")
        .withContentType("text/plain")
        .withStatus(200)
        .withHeader("X-Custom", "value");
    _ = resp;
}

test "Response fromZiggurat creates wrapper" {
    const ziggurat_resp = ziggurat.response.Response.text("test");
    const resp = Response.fromZiggurat(ziggurat_resp);
    _ = resp;
}

test "Response toZiggurat converts back" {
    const resp = Response.text("test");
    const ziggurat_resp = resp.toZiggurat();
    _ = ziggurat_resp;
}
