const std = @import("std");
const E12 = @import("engine12");
const Request = E12.Request;
const Response = E12.Response;
const HandlerCtx = E12.HandlerCtx;
const models = @import("../models.zig");
const Todo = models.Todo;
const TodoModel = models.TodoModel;
const database = @import("../database.zig");
const getORM = database.getORM;

const allocator = std.heap.page_allocator;

/// Handle search todos endpoint
/// Searches todos by title, description, and tags
pub fn handleSearchTodos(request: *Request) Response {
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

    // Parse search query parameter
    const search_query = ctx.query([]const u8, "q") catch {
        return ctx.badRequest("Missing or invalid query parameter 'q'");
    };

    const orm = ctx.orm() catch {
        return ctx.serverError("Database not initialized");
    };
    const user = ctx.user.?; // Safe because require_auth = true

    // NOTE: QueryBuilder Limitation
    // The engine12 QueryBuilder doesn't currently support OR conditions in WHERE clauses.
    // For this search functionality that needs to search across multiple columns (title, description, tags)
    // with OR conditions, we use raw SQL instead.
    //
    // Example of QueryBuilder usage for simpler queries (without OR):
    // ```zig
    // var query = QueryBuilder.init(orm.db, "Todo");
    // query.where("completed", "=", "0");
    // query.orderBy("created_at", "DESC");
    // query.limit(10);
    // const result = query.execute();
    // ```
    //
    // For OR conditions or complex queries, raw SQL is the current approach.

    // Use ORM's escapeLike method for safe SQL LIKE pattern escaping
    const escaped_query = orm.escapeLike(search_query, request.arena.allocator()) catch {
        return ctx.serverError("Failed to escape query");
    };

    // Build search query - search in title, description, and tags, filtered by user_id
    const search_pattern = std.fmt.allocPrint(request.arena.allocator(), "%{s}%", .{escaped_query}) catch {
        return ctx.serverError("Failed to format search query");
    };
    const sql = std.fmt.allocPrint(request.arena.allocator(),
        \\SELECT id, user_id, title, description, completed, priority, due_date, tags, created_at, updated_at FROM todos WHERE 
        \\  user_id = {d} AND (
        \\    title LIKE '{s}' OR 
        \\    description LIKE '{s}' OR 
        \\    tags LIKE '{s}'
        \\  )
        \\ORDER BY created_at DESC
    , .{ user.id, search_pattern, search_pattern, search_pattern }) catch {
        return ctx.serverError("Failed to build search query");
    };

    var result = orm.db.query(sql) catch {
        return ctx.serverError("Failed to search todos");
    };
    defer result.deinit();

    var todos = result.toArrayList(Todo) catch {
        return ctx.serverError("Failed to parse search results");
    };
    defer {
        for (todos.items) |todo| {
            allocator.free(todo.title);
            allocator.free(todo.description);
            allocator.free(todo.priority);
            allocator.free(todo.tags);
        }
        todos.deinit(allocator);
    }

    return TodoModel.toResponseList(todos, allocator)
        .withHeader("Cache-Control", "no-cache, no-store, must-revalidate")
        .withHeader("Pragma", "no-cache")
        .withHeader("Expires", "0");
}

