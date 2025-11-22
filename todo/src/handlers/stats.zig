const std = @import("std");
const E12 = @import("engine12");
const Request = E12.Request;
const Response = E12.Response;
const HandlerCtx = E12.HandlerCtx;
const utils = @import("../utils.zig");
const getStats = utils.getStats;
const database = @import("../database.zig");
const getORM = database.getORM;

const allocator = std.heap.page_allocator;

/// Handle get stats endpoint
/// Returns statistics about the user's todos
pub fn handleGetStats(request: *Request) Response {
    // Initialize HandlerCtx with authentication and ORM required
    var ctx = HandlerCtx.init(request, .{
        .require_auth = true,
        .require_orm = true,
        .get_orm = getORM,
    }) catch |err| {
        return switch (err) {
            error.AuthenticationRequired => Response.errorResponse("Authentication required", 401),
            error.DatabaseNotInitialized => Response.serverError("Database not initialized"),
            else => Response.serverError("Internal error"),
        };
    };

    const user = ctx.user.?; // Safe because require_auth = true

    // Check cache first (include user_id in cache key)
    const cache_key = ctx.cacheKey("todos:stats:{d}") catch {
        return ctx.serverError("Failed to create cache key");
    };

    if (ctx.cacheGet(cache_key) catch null) |entry| {
        return Response.text(entry.body)
            .withContentType(entry.content_type)
            .withHeader("X-Cache", "HIT");
    }

    const orm = ctx.orm() catch {
        return ctx.serverError("Database not initialized");
    };

    const stats = getStats(orm, user.id) catch {
        return ctx.serverError("Failed to fetch stats");
    };

    // Create JSON response manually since we're not using ModelStats anymore
    const json = std.fmt.allocPrint(allocator,
        \\{{"total":{d},"completed":{d},"pending":{d},"completed_percentage":{d:.2},"overdue":{d}}}
    , .{ stats.total, stats.completed, stats.pending, stats.completed_percentage, stats.overdue }) catch {
        return ctx.serverError("Failed to serialize stats");
    };
    defer allocator.free(json);

    // Cache stats for 10 seconds
    ctx.cacheSet(cache_key, json, 10000, "application/json");

    return Response.json(json).withHeader("X-Cache", "MISS");
}

