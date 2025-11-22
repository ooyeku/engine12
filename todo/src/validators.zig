const std = @import("std");
const E12 = @import("engine12");
const Request = E12.Request;
const validation = E12.validation;
const models = @import("models.zig");
const Todo = models.Todo;

/// Validate a Todo model instance
pub fn validateTodo(req: *Request, todo: Todo) anyerror!validation.ValidationErrors {
    var errors = validation.ValidationErrors.init(req.arena.allocator());

    // Validate title (required, max 200 chars)
    if (todo.title.len == 0) {
        try errors.add("title", "Title is required", "required");
    }
    if (todo.title.len > 200) {
        try errors.add("title", "Title must be less than 200 characters", "max_length");
    }

    // Validate description (max 1000 chars)
    if (todo.description.len > 1000) {
        try errors.add("description", "Description must be less than 1000 characters", "max_length");
    }

    // Validate priority
    const allowed_priorities = [_][]const u8{ "low", "medium", "high" };
    var priority_valid = false;
    for (allowed_priorities) |p| {
        if (std.mem.eql(u8, todo.priority, p)) {
            priority_valid = true;
            break;
        }
    }
    if (!priority_valid) {
        try errors.add("priority", "Priority must be one of: low, medium, high", "invalid");
    }

    // Validate tags (max 500 chars)
    if (todo.tags.len > 500) {
        try errors.add("tags", "Tags must be less than 500 characters", "max_length");
    }

    return errors;
}
