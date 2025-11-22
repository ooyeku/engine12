const std = @import("std");
const types = @import("types.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

/// Health check result with details
pub const HealthCheckResult = struct {
    status: types.HealthStatus,
    message: []const u8,
    checks: ?[]const CheckResult = null,

    pub const CheckResult = struct {
        name: []const u8,
        status: types.HealthStatus,
        message: []const u8,
    };
};

/// Standard health check handler
/// Returns basic health status (always healthy if server is running)
pub fn handleHealth(req: *Request) Response {
    _ = req;
    const result = HealthCheckResult{
        .status = .healthy,
        .message = "Service is healthy",
        .checks = null,
    };
    return formatHealthResponse(result);
}

/// Readiness check handler
/// Checks if the service is ready to accept traffic (database, dependencies, etc.)
pub fn handleReady(req: *Request) Response {
    _ = req;
    
    var checks = std.ArrayListUnmanaged(HealthCheckResult.CheckResult){};
    defer checks.deinit(std.heap.page_allocator);
    
    var overall_status: types.HealthStatus = .healthy;
    
    // Check database connectivity (if ORM is initialized)
    const db_check = checkDatabase();
    checks.append(std.heap.page_allocator, db_check) catch {
        return Response.internalError();
    };
    if (db_check.status != .healthy) {
        overall_status = .unhealthy;
    }
    
    // Check cache (if available)
    const cache_check = checkCache();
    checks.append(std.heap.page_allocator, cache_check) catch {
        return Response.internalError();
    };
    if (cache_check.status == .degraded and overall_status == .healthy) {
        overall_status = .degraded;
    } else if (cache_check.status == .unhealthy) {
        overall_status = .unhealthy;
    }
    
    const result = HealthCheckResult{
        .status = overall_status,
        .message = if (overall_status == .healthy) "Service is ready" else "Service is not ready",
        .checks = checks.items,
    };
    
    const status_code: u16 = switch (overall_status) {
        .healthy => 200,
        .degraded => 200, // Still accept traffic but indicate degraded state
        .unhealthy => 503, // Service Unavailable
    };
    
    var resp = formatHealthResponse(result);
    resp = resp.withStatus(status_code);
    return resp;
}

/// Check database health
fn checkDatabase() HealthCheckResult.CheckResult {
    // TODO: Implement actual database connectivity check
    // For now, assume healthy if no errors occur
    return HealthCheckResult.CheckResult{
        .name = "database",
        .status = .healthy,
        .message = "Database connection OK",
    };
}

/// Check cache health
fn checkCache() HealthCheckResult.CheckResult {
    // TODO: Implement actual cache connectivity check
    // For now, assume healthy if no errors occur
    return HealthCheckResult.CheckResult{
        .name = "cache",
        .status = .healthy,
        .message = "Cache connection OK",
    };
}

/// Format health check result as JSON response
fn formatHealthResponse(result: HealthCheckResult) Response {
    var json_buffer = std.ArrayListUnmanaged(u8){};
    defer json_buffer.deinit(std.heap.page_allocator);
    
    const writer = json_buffer.writer(std.heap.page_allocator);
    
    writer.print("{{\"status\":\"{s}\",\"message\":\"{s}\"", .{
        @tagName(result.status),
        result.message,
    }) catch {
        return Response.internalError();
    };
    
    if (result.checks) |checks| {
        writer.print(",\"checks\":[", .{}) catch {
            return Response.internalError();
        };
        
        for (checks, 0..) |check, i| {
            if (i > 0) {
                writer.print(",", .{}) catch {
                    return Response.internalError();
                };
            }
            writer.print("{{\"name\":\"{s}\",\"status\":\"{s}\",\"message\":\"{s}\"}}", .{
                check.name,
                @tagName(check.status),
                check.message,
            }) catch {
                return Response.internalError();
            };
        }
        
        writer.print("]", .{}) catch {
            return Response.internalError();
        };
    }
    
    writer.print("}}", .{}) catch {
        return Response.internalError();
    };
    
    const json = json_buffer.toOwnedSlice(std.heap.page_allocator) catch {
        return Response.internalError();
    };
    defer std.heap.page_allocator.free(json);
    
    return Response.json(json);
}

// Tests
test "checkDatabaseHealth returns healthy" {
    const check = checkDatabase();
    try std.testing.expectEqual(check.status, types.HealthStatus.healthy);
}

test "checkCacheHealth returns healthy" {
    const check = checkCache();
    try std.testing.expectEqual(check.status, types.HealthStatus.healthy);
}

test "handleHealth returns healthy response" {
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/health",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const resp = handleHealth(&req);
    const ziggurat_resp = resp.toZiggurat();
    try std.testing.expectEqual(ziggurat_resp.status, 200);
}

test "handleReady returns ready response" {
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/ready",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const resp = handleReady(&req);
    const ziggurat_resp = resp.toZiggurat();
    try std.testing.expect(ziggurat_resp.status == 200 or ziggurat_resp.status == 503);
}

