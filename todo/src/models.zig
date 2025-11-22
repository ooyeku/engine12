const std = @import("std");
const E12 = @import("engine12");

/// Todo model representing a todo item
pub const Todo = struct {
    id: i64,
    user_id: i64,
    title: []u8,
    description: []u8,
    completed: bool,
    priority: []u8,
    due_date: ?i64,
    tags: []u8,
    created_at: i64,
    updated_at: i64,
};

/// Input struct for JSON parsing (matches what parseTodoFromJson returned)
pub const TodoInput = struct {
    title: ?[]const u8,
    description: ?[]const u8,
    completed: ?bool,
    priority: ?[]const u8,
    due_date: ?i64,
    tags: ?[]const u8,
};

/// Statistics for todos
pub const TodoStats = struct {
    total: u32,
    completed: u32,
    pending: u32,
    completed_percentage: f32,
    overdue: u32,
};

// Model wrappers for Todo
pub const TodoModel = E12.orm.Model(Todo);
pub const TodoModelORM = E12.orm.ModelWithORM(Todo);
pub const TodoStatsModel = E12.orm.ModelStats(Todo, TodoStats);
