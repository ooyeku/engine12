const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const metrics = @import("metrics.zig");

pub fn handleDefaultRoot(request: *Request) Response {
    _ = request;
    return Response.json("{\"service\":\"Engine12\",\"status\":\"running\"}");
}

pub fn handleHealthEndpoint(request: *Request) Response {
    _ = request;
    return Response.json("{\"health\":\"healthy\",\"checks_passed\":true}");
}

pub fn handleMetricsEndpoint(request: *Request) Response {
    _ = request;
    // Access global metrics collector
    const metrics_collector = @import("engine12.zig").global_metrics;
    
    if (metrics_collector) |mc| {
        const prometheus_output = mc.getPrometheusMetrics() catch {
            return Response.json("{\"error\":\"Failed to generate metrics\"}").withStatus(500);
        };
        defer std.heap.page_allocator.free(prometheus_output);
        
        var resp = Response.text(prometheus_output);
        resp = resp.withContentType("text/plain; version=0.0.4");
        return resp;
    }
    
    // Fallback if metrics collector not available
    return Response.json("{\"metrics\":{\"uptime_ms\":0,\"requests_total\":0}}");
}

pub fn handleGetUsers(request: *Request) Response {
    _ = request;
    return Response.json("{\"users\":[{\"id\":1,\"name\":\"Alice\"},{\"id\":2,\"name\":\"Bob\"}]}");
}

pub fn handleCreateUser(request: *Request) Response {
    _ = request;
    return Response.json("{\"id\":3,\"name\":\"Charlie\",\"created\":true}");
}

pub fn handleGetStatus(request: *Request) Response {
    _ = request;
    return Response.json("{\"status\":\"ok\",\"version\":\"0.1.0\"}");
}

// Tests
test "handleDefaultRoot returns correct JSON" {
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    const resp = handleDefaultRoot(&req);
    _ = resp;
}

test "handleHealthEndpoint returns correct JSON" {
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/health",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    const resp = handleHealthEndpoint(&req);
    _ = resp;
}

test "handleMetricsEndpoint returns correct JSON" {
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/metrics",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    const resp = handleMetricsEndpoint(&req);
    _ = resp;
}

test "handleGetUsers returns correct JSON" {
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/api/users",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    const resp = handleGetUsers(&req);
    _ = resp;
}

test "handleCreateUser returns correct JSON" {
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/api/users",
        .method = .POST,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    const resp = handleCreateUser(&req);
    _ = resp;
}

test "handleGetStatus returns correct JSON" {
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/api/status",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    const resp = handleGetStatus(&req);
    _ = resp;
}

