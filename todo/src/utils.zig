const std = @import("std");
const E12 = @import("engine12");
const ORM = E12.orm.ORM;
const models = @import("models.zig");
const Todo = models.Todo;
const TodoStats = models.TodoStats;

const allocator = std.heap.page_allocator;

/// Get all todos for a user
pub fn getAllTodos(orm: *ORM, user_id: i64) !std.ArrayListUnmanaged(Todo) {
    // Filter todos by user_id using raw SQL
    // IMPORTANT: Column order must match Todo struct field order:
    // id, user_id, title, description, completed, priority, due_date, tags, created_at, updated_at
    const sql = try std.fmt.allocPrint(orm.allocator, "SELECT id, user_id, title, description, completed, priority, due_date, tags, created_at, updated_at FROM todos WHERE user_id = {d}", .{user_id});
    defer orm.allocator.free(sql);

    var query_result = try orm.db.query(sql);
    defer query_result.deinit();

    return try query_result.toArrayList(Todo);
}

/// Get statistics for a user's todos
pub fn getStats(orm: *ORM, user_id: i64) !TodoStats {
    // Get all todos for user
    var todos = try getAllTodos(orm, user_id);
    defer {
        for (todos.items) |todo| {
            allocator.free(todo.title);
            allocator.free(todo.description);
            allocator.free(todo.priority);
            allocator.free(todo.tags);
        }
        todos.deinit(allocator);
    }

    var total: u32 = 0;
    var completed: u32 = 0;
    var overdue: u32 = 0;
    const now = std.time.milliTimestamp();

    for (todos.items) |todo| {
        total += 1;
        if (todo.completed) {
            completed += 1;
        } else if (todo.due_date) |due_date| {
            if (due_date < now) {
                overdue += 1;
            }
        }
    }

    const pending = total - completed;
    const completed_percentage = if (total > 0)
        (@as(f32, @floatFromInt(completed)) / @as(f32, @floatFromInt(total))) * 100.0
    else
        0.0;

    return TodoStats{
        .total = total,
        .completed = completed,
        .pending = pending,
        .completed_percentage = completed_percentage,
        .overdue = overdue,
    };
}
