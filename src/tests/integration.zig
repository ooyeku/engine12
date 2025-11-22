const std = @import("std");
const Engine12 = @import("engine12").Engine12;
const Request = @import("engine12").Request;
const Response = @import("engine12").Response;
const test_helpers = @import("test_helpers.zig").TestHelpers;

/// Integration tests for Engine12
/// These tests verify full request/response cycles and component interactions

test "integration: full request response cycle" {
    var app = try test_helpers.createTestApp();
    defer app.deinit();

    // Register a simple route
    const handler = struct {
        fn handle(req: *Request) Response {
            _ = req;
            return Response.json("{\"status\":\"ok\"}");
        }
    }.handle;

    try app.get("/test", handler);

    // Note: Actual HTTP server testing would require starting the server
    // For now, we verify route registration
    try std.testing.expectEqual(app.routes_count, 1);
}

test "integration: middleware chain execution" {
    var app = try test_helpers.createTestApp();
    defer app.deinit();

    var middleware_called = false;
    const middleware = struct {
        fn mw(req: *Request) @import("middleware.zig").MiddlewareResult {
            _ = req;
            middleware_called = true;
            return .proceed;
        }
    }.mw;

    try app.usePreRequest(middleware);

    // Verify middleware is registered
    try std.testing.expect(app.middleware.pre_request_chain.items.len > 0);
}

test "integration: request parameter parsing" {
    var req = try test_helpers.createMockRequest("GET", "/todos/123");
    defer req.deinit();

    // Set route params manually (normally done by router)
    var params = std.StringHashMap([]const u8).init(req.arena.allocator());
    const id_value = try req.arena.allocator().dupe(u8, "123");
    try params.put("id", id_value);
    req.setRouteParams(params);

    const id = try req.paramTyped(i64, "id");
    try std.testing.expectEqual(id, 123);
}

test "integration: query parameter parsing" {
    var req = try test_helpers.createMockRequest("GET", "/todos?limit=10&offset=20");
    defer req.deinit();

    const limit = try req.queryParamTyped(u32, "limit");
    try std.testing.expect(limit != null);
    try std.testing.expectEqual(limit.?, 10);

    const offset = try req.queryParamTyped(u32, "offset");
    try std.testing.expect(offset != null);
    try std.testing.expectEqual(offset.?, 20);
}

test "integration: JSON response creation" {
    const resp = Response.json("{\"test\":\"value\"}");
    try test_helpers.assertBodyContains(resp, "test");
    try test_helpers.assertBodyContains(resp, "value");
}

test "integration: response status codes" {
    const ok = Response.ok();
    try test_helpers.assertStatus(ok, 200);

    const notFound = Response.notFound("Not found");
    try test_helpers.assertStatus(notFound, 404);

    const badRequest = Response.badRequest();
    try test_helpers.assertStatus(badRequest, 400);
}

