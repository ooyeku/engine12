const std = @import("std");
const E12 = @import("Engine12");
const Request = E12.Request;
const Response = E12.Response;
const validation = E12.validation;
const middleware_chain = E12.middleware;
const rate_limit = E12.rate_limit;
const cache = E12.cache;
const templates = E12.templates;
const Database = E12.orm.Database;
const ORM = E12.orm.ORM;

const allocator = std.heap.page_allocator;

// ============================================================================
// TODO MODEL & DATABASE
// ============================================================================

const Todo = struct {
    id: i64,
    title: []u8,
    description: []u8,
    completed: bool,
    created_at: i64,
    updated_at: i64,
};

var global_db: ?Database = null;
var global_orm: ?ORM = null;
var db_mutex: std.Thread.Mutex = .{};

fn getORM() !*ORM {
    db_mutex.lock();
    defer db_mutex.unlock();

    if (global_orm) |*orm| {
        return orm;
    }

    return error.DatabaseNotInitialized;
}

fn initDatabase() !void {
    db_mutex.lock();
    defer db_mutex.unlock();

    if (global_db != null) {
        return; // Already initialized
    }

    // Open database file
    const db_path = "todo.db";
    global_db = try Database.open(db_path, allocator);

    // Create table if it doesn't exist
    try global_db.?.execute(
        \\CREATE TABLE IF NOT EXISTS Todo (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  title TEXT NOT NULL,
        \\  description TEXT NOT NULL,
        \\  completed INTEGER NOT NULL DEFAULT 0,
        \\  created_at INTEGER NOT NULL,
        \\  updated_at INTEGER NOT NULL
        \\)
    );

    // Initialize ORM
    global_orm = ORM.init(global_db.?, allocator);
}

const TodoStats = struct {
    total: u32,
    completed: u32,
    pending: u32,
    completed_percentage: f32,
};

fn createTodo(orm: *ORM, title: []const u8, description: []const u8) !Todo {
    const now = std.time.milliTimestamp();
    const title_copy = try allocator.dupe(u8, title);
    errdefer allocator.free(title_copy);
    const desc_copy = try allocator.dupe(u8, description);
    errdefer allocator.free(desc_copy);

    const todo = Todo{
        .id = 0,
        .title = title_copy,
        .description = desc_copy,
        .completed = false,
        .created_at = now,
        .updated_at = now,
    };

    try orm.create(Todo, todo);

    // Get the last insert row ID
    const last_id = orm.db.lastInsertRowId() catch {
        // Fallback: query for the most recently created todo
        var all_todos = try orm.findAll(Todo);
        defer {
            for (all_todos.items) |t| {
                allocator.free(t.title);
                allocator.free(t.description);
            }
            all_todos.deinit(allocator);
        }

        if (all_todos.items.len == 0) {
            return error.FailedToCreateTodo;
        }

        // Find the todo with the highest ID
        var max_id: i64 = 0;
        var found_todo: ?Todo = null;
        for (all_todos.items) |t| {
            if (t.id > max_id) {
                max_id = t.id;
                found_todo = t;
            }
        }

        if (found_todo) |t| {
            return Todo{
                .id = t.id,
                .title = try allocator.dupe(u8, t.title),
                .description = try allocator.dupe(u8, t.description),
                .completed = t.completed,
                .created_at = t.created_at,
                .updated_at = t.updated_at,
            };
        }

        return error.FailedToCreateTodo;
    };

    // Fetch the created todo by ID
    const created = try orm.find(Todo, last_id);
    if (created) |t| {
        defer {
            allocator.free(t.title);
            allocator.free(t.description);
        }
        return Todo{
            .id = t.id,
            .title = try allocator.dupe(u8, t.title),
            .description = try allocator.dupe(u8, t.description),
            .completed = t.completed,
            .created_at = t.created_at,
            .updated_at = t.updated_at,
        };
    }

    return error.FailedToCreateTodo;
}

fn findTodoById(orm: *ORM, id: i64) !?Todo {
    const todo = try orm.find(Todo, id);
    return todo;
}

fn getAllTodos(orm: *ORM) !std.ArrayListUnmanaged(Todo) {
    return try orm.findAll(Todo);
}

fn updateTodo(orm: *ORM, id: i64, updates: struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    completed: ?bool = null,
}) !?Todo {
    const existing = try orm.find(Todo, id);
    if (existing == null) return null;

    var todo = existing.?;
    defer {
        allocator.free(todo.title);
        allocator.free(todo.description);
    }

    // Update fields
    if (updates.title) |title| {
        allocator.free(todo.title);
        todo.title = try allocator.dupe(u8, title);
    }

    if (updates.description) |desc| {
        allocator.free(todo.description);
        todo.description = try allocator.dupe(u8, desc);
    }

    if (updates.completed) |completed| {
        todo.completed = completed;
    }

    todo.updated_at = std.time.milliTimestamp();

    // Update in database
    try orm.update(Todo, todo);

    // Return a copy with allocated strings
    return Todo{
        .id = todo.id,
        .title = try allocator.dupe(u8, todo.title),
        .description = try allocator.dupe(u8, todo.description),
        .completed = todo.completed,
        .created_at = todo.created_at,
        .updated_at = todo.updated_at,
    };
}

fn deleteTodo(orm: *ORM, id: i64) !bool {
    const existing = try orm.find(Todo, id);
    if (existing == null) return false;

    defer {
        allocator.free(existing.?.title);
        allocator.free(existing.?.description);
    }

    try orm.delete(Todo, id);
    return true;
}

fn getStats(orm: *ORM) !TodoStats {
    var all_todos = try orm.findAll(Todo);
    defer {
        for (all_todos.items) |t| {
            allocator.free(t.title);
            allocator.free(t.description);
        }
        all_todos.deinit(allocator);
    }

    var total: u32 = 0;
    var completed: u32 = 0;

    for (all_todos.items) |todo| {
        total += 1;
        if (todo.completed) {
            completed += 1;
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
    };
}

// ============================================================================
// JSON UTILITIES
// ============================================================================

fn formatTodoJson(todo: Todo, alloc: std.mem.Allocator) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(alloc);

    try list.writer(alloc).print(
        \\{{"id":{},"title":"{s}","description":"{s}","completed":{},"created_at":{},"updated_at":{}}}
    , .{ todo.id, todo.title, todo.description, todo.completed, todo.created_at, todo.updated_at });

    return list.toOwnedSlice(alloc);
}

fn formatTodoListJson(todos: std.ArrayListUnmanaged(Todo), alloc: std.mem.Allocator) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(alloc);

    try list.writer(alloc).print("[", .{});

    for (todos.items, 0..) |todo, i| {
        if (i > 0) {
            try list.writer(alloc).print(",", .{});
        }
        const todo_json = try formatTodoJson(todo, alloc);
        defer alloc.free(todo_json);
        try list.writer(alloc).print("{s}", .{todo_json});
    }

    try list.writer(alloc).print("]", .{});
    return list.toOwnedSlice(alloc);
}

fn formatStatsJson(stats: TodoStats, alloc: std.mem.Allocator) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(alloc);

    try list.writer(alloc).print(
        \\{{"total":{},"completed":{},"pending":{},"completed_percentage":{d:.2}}}
    , .{ stats.total, stats.completed, stats.pending, stats.completed_percentage });

    return list.toOwnedSlice(alloc);
}

fn parseTodoFromJson(json_str: []const u8, alloc: std.mem.Allocator) !struct {
    title: []const u8,
    description: []const u8,
    completed: ?bool,
} {
    var title: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var completed: ?bool = null;

    var i: usize = 0;
    while (i < json_str.len) {
        if (std.mem.indexOf(u8, json_str[i..], "\"title\"") != null) {
            const title_start = std.mem.indexOf(u8, json_str[i..], "\"title\"") orelse break;
            const colon = std.mem.indexOf(u8, json_str[i + title_start ..], ":") orelse break;
            const quote_start = std.mem.indexOf(u8, json_str[i + title_start + colon ..], "\"") orelse break;
            const val_start = i + title_start + colon + quote_start + 1;
            const quote_end = std.mem.indexOf(u8, json_str[val_start..], "\"") orelse break;
            title = try alloc.dupe(u8, json_str[val_start .. val_start + quote_end]);
            i = val_start + quote_end;
        } else if (std.mem.indexOf(u8, json_str[i..], "\"description\"") != null) {
            const desc_start = std.mem.indexOf(u8, json_str[i..], "\"description\"") orelse break;
            const colon = std.mem.indexOf(u8, json_str[i + desc_start ..], ":") orelse break;
            const quote_start = std.mem.indexOf(u8, json_str[i + desc_start + colon ..], "\"") orelse break;
            const val_start = i + desc_start + colon + quote_start + 1;
            const quote_end = std.mem.indexOf(u8, json_str[val_start..], "\"") orelse break;
            description = try alloc.dupe(u8, json_str[val_start .. val_start + quote_end]);
            i = val_start + quote_end;
        } else if (std.mem.indexOf(u8, json_str[i..], "\"completed\"") != null) {
            const comp_start = std.mem.indexOf(u8, json_str[i..], "\"completed\"") orelse break;
            const colon = std.mem.indexOf(u8, json_str[i + comp_start ..], ":") orelse break;
            const val_start = i + comp_start + colon + 1;
            if (std.mem.startsWith(u8, json_str[val_start..], "true")) {
                completed = true;
                i = val_start + 4;
            } else if (std.mem.startsWith(u8, json_str[val_start..], "false")) {
                completed = false;
                i = val_start + 5;
            } else {
                break;
            }
        } else {
            i += 1;
        }
    }

    return .{
        .title = title orelse "",
        .description = description orelse "",
        .completed = completed,
    };
}

fn handleIndex(request: *Request) Response {
    _ = request;

    // Compile template at comptime - embed template content directly
    // Template is in the same directory structure (todo/src/templates/)
    const template_content = @embedFile("templates/index.zt.html");
    const IndexTemplate = templates.Template.compile(template_content);

    // Define context type
    const IndexContext = struct {
        title: []const u8,
        subtitle: []const u8,
        title_placeholder: []const u8,
        description_placeholder: []const u8,
        add_button_text: []const u8,
        filter_all: []const u8,
        filter_pending: []const u8,
        filter_completed: []const u8,
        empty_state_message: []const u8,
    };

    // Create context
    const context = IndexContext{
        .title = "Engine12 TODO",
        .subtitle = "A beautiful, minimal task manager",
        .title_placeholder = "Enter task title...",
        .description_placeholder = "Enter description (optional)...",
        .add_button_text = "Add Task",
        .filter_all = "All",
        .filter_pending = "Pending",
        .filter_completed = "Completed",
        .empty_state_message = "No tasks yet. Add one above to get started!",
    };

    // Render template - use page allocator for persistent memory
    // Response.html() expects memory that persists beyond the request
    const html = IndexTemplate.render(IndexContext, context, allocator) catch {
        return Response.text("Internal server error: template rendering failed").withStatus(500);
    };

    return Response.html(html)
        .withHeader("Cache-Control", "no-cache, no-store, must-revalidate")
        .withHeader("Pragma", "no-cache")
        .withHeader("Expires", "0");
}

// ============================================================================
// REQUEST HANDLERS
// ============================================================================

fn handleGetTodos(request: *Request) Response {
    _ = request;
    const orm = getORM() catch {
        return Response.json("{\"error\":\"Database not initialized\"}").withStatus(500);
    };

    var todos = getAllTodos(orm) catch {
        return Response.json("{\"error\":\"Failed to fetch todos\"}").withStatus(500);
    };
    defer {
        for (todos.items) |todo| {
            allocator.free(todo.title);
            allocator.free(todo.description);
        }
        todos.deinit(allocator);
    }

    const json = formatTodoListJson(todos, allocator) catch {
        return Response.json("{\"error\":\"Failed to format todos\"}").withStatus(500);
    };
    defer allocator.free(json);
    return Response.json(json)
        .withHeader("Cache-Control", "no-cache, no-store, must-revalidate")
        .withHeader("Pragma", "no-cache")
        .withHeader("Expires", "0");
}

fn handleGetTodo(request: *Request) Response {
    const id = request.param("id").asI64() catch {
        return Response.json("{\"error\":\"Invalid ID\"}").withStatus(400);
    };

    const orm = getORM() catch {
        return Response.json("{\"error\":\"Database not initialized\"}").withStatus(500);
    };

    const todo = findTodoById(orm, id) catch {
        return Response.json("{\"error\":\"Failed to fetch todo\"}").withStatus(500);
    };

    const found = todo orelse {
        return Response.json("{\"error\":\"Todo not found\"}").withStatus(404);
    };
    defer {
        allocator.free(found.title);
        allocator.free(found.description);
    }

    const json = formatTodoJson(found, allocator) catch {
        return Response.json("{\"error\":\"Failed to format todo\"}").withStatus(500);
    };
    defer allocator.free(json);
    return Response.json(json)
        .withHeader("Cache-Control", "no-cache, no-store, must-revalidate")
        .withHeader("Pragma", "no-cache")
        .withHeader("Expires", "0");
}

fn handleCreateTodo(request: *Request) Response {
    const parsed = parseTodoFromJson(request.body(), allocator) catch {
        return Response.json("{\"error\":\"Invalid JSON\"}");
    };
    defer {
        if (parsed.title.len > 0) allocator.free(parsed.title);
        if (parsed.description.len > 0) allocator.free(parsed.description);
    }

    // Use validation framework
    var schema = validation.ValidationSchema.init(request.arena.allocator());
    defer schema.deinit();

    // Validate title (required, max 200 chars)
    const title_validator = schema.field("title", parsed.title) catch {
        return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
    };
    title_validator.rule(validation.required) catch {
        return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
    };

    const titleMaxLength = struct {
        fn validate(value: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
            _ = alloc;
            if (value.len > 200) {
                return "Title must be 200 characters or less";
            }
            return null;
        }
    };
    title_validator.rule(titleMaxLength.validate) catch {
        return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
    };

    // Validate description if provided (max 1000 chars)
    if (parsed.description.len > 0) {
        const desc_validator = schema.field("description", parsed.description) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
        const descMaxLength = struct {
            fn validate(value: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
                _ = alloc;
                if (value.len > 1000) {
                    return "Description must be 1000 characters or less";
                }
                return null;
            }
        };
        desc_validator.rule(descMaxLength.validate) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
    }

    // Run validation
    var validation_errors = schema.validate() catch {
        return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
    };
    defer validation_errors.deinit();

    if (!validation_errors.isEmpty()) {
        const error_json = validation_errors.toJson() catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
        defer allocator.free(error_json);
        return Response.json(error_json).withStatus(400);
    }

    const orm = getORM() catch {
        return Response.json("{\"error\":\"Database not initialized\"}").withStatus(500);
    };

    const todo = createTodo(orm, parsed.title, parsed.description) catch {
        return Response.json("{\"error\":\"Failed to create todo\"}").withStatus(500);
    };
    defer {
        allocator.free(todo.title);
        allocator.free(todo.description);
    }

    const json = formatTodoJson(todo, allocator) catch {
        return Response.json("{\"error\":\"Failed to format todo\"}").withStatus(500);
    };
    defer allocator.free(json);
    return Response.json(json);
}

fn handleUpdateTodo(request: *Request) Response {
    const id = request.param("id").asI64() catch {
        return Response.json("{\"error\":\"Invalid ID\"}").withStatus(400);
    };

    const parsed = parseTodoFromJson(request.body(), allocator) catch {
        return Response.json("{\"error\":\"Invalid JSON\"}");
    };

    defer {
        if (parsed.title.len > 0) allocator.free(parsed.title);
        if (parsed.description.len > 0) allocator.free(parsed.description);
    }

    // Use validation framework
    var schema = validation.ValidationSchema.init(request.arena.allocator());
    defer schema.deinit();

    // Validate title if provided
    if (parsed.title.len > 0) {
        const title_validator = schema.field("title", parsed.title) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
        const titleMaxLength = struct {
            fn validate(value: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
                _ = alloc;
                if (value.len > 200) {
                    return "Title must be 200 characters or less";
                }
                return null;
            }
        };
        title_validator.rule(titleMaxLength.validate) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
    }

    // Validate description if provided
    if (parsed.description.len > 0) {
        const desc_validator = schema.field("description", parsed.description) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
        const descMaxLength = struct {
            fn validate(value: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
                _ = alloc;
                if (value.len > 1000) {
                    return "Description must be 1000 characters or less";
                }
                return null;
            }
        };
        desc_validator.rule(descMaxLength.validate) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
    }

    // Run validation
    var validation_errors = schema.validate() catch {
        return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
    };
    defer validation_errors.deinit();

    if (!validation_errors.isEmpty()) {
        const error_json = validation_errors.toJson() catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
        defer allocator.free(error_json);
        return Response.json(error_json).withStatus(400);
    }

    const orm = getORM() catch {
        return Response.json("{\"error\":\"Database not initialized\"}").withStatus(500);
    };

    const updates = updateTodo(orm, id, .{
        .title = if (parsed.title.len > 0) parsed.title else null,
        .description = if (parsed.description.len > 0) parsed.description else null,
        .completed = parsed.completed,
    }) catch {
        return Response.json("{\"error\":\"Failed to update todo\"}").withStatus(500);
    };

    const todo = updates orelse {
        return Response.json("{\"error\":\"Todo not found\"}").withStatus(404);
    };
    defer {
        allocator.free(todo.title);
        allocator.free(todo.description);
    }

    const json = formatTodoJson(todo, allocator) catch {
        return Response.json("{\"error\":\"Failed to format todo\"}").withStatus(500);
    };
    defer allocator.free(json);
    return Response.json(json);
}

fn handleDeleteTodo(request: *Request) Response {
    const id = request.param("id").asI64() catch {
        return Response.json("{\"error\":\"Invalid ID\"}").withStatus(400);
    };

    const orm = getORM() catch {
        return Response.json("{\"error\":\"Database not initialized\"}").withStatus(500);
    };

    const deleted = deleteTodo(orm, id) catch {
        return Response.json("{\"error\":\"Failed to delete todo\"}").withStatus(500);
    };

    if (deleted) {
        return Response.json("{\"success\":true}");
    } else {
        return Response.json("{\"error\":\"Todo not found\"}").withStatus(404);
    }
}

fn handleGetStats(request: *Request) Response {
    _ = request;
    const orm = getORM() catch {
        return Response.json("{\"error\":\"Database not initialized\"}").withStatus(500);
    };

    const stats = getStats(orm) catch {
        return Response.json("{\"error\":\"Failed to fetch stats\"}").withStatus(500);
    };

    const json = formatStatsJson(stats, allocator) catch {
        return Response.json("{\"error\":\"Failed to format stats\"}").withStatus(500);
    };
    defer allocator.free(json);
    return Response.json(json)
        .withHeader("Cache-Control", "no-cache, no-store, must-revalidate")
        .withHeader("Pragma", "no-cache")
        .withHeader("Expires", "0");
}

// ============================================================================
// MIDDLEWARE
// ============================================================================

fn loggingMiddleware(req: *Request) middleware_chain.MiddlewareResult {
    const method = req.method();
    const path = req.path();
    const timestamp = std.time.milliTimestamp();
    std.debug.print("[{d}] {s} {s}\n", .{ timestamp, method, path });
    return .proceed;
}

fn corsMiddleware(resp: Response) Response {
    return resp;
}

// ============================================================================
// BACKGROUND TASKS
// ============================================================================

const DAY_IN_MS: i64 = 24 * 60 * 60 * 1000;
const SEVEN_DAYS_MS: i64 = 7 * DAY_IN_MS;

fn cleanupOldCompletedTodos() void {
    const orm = getORM() catch return;
    const now = std.time.milliTimestamp();

    var cleaned: u32 = 0;

    var all_todos = getAllTodos(orm) catch return;
    defer {
        for (all_todos.items) |todo| {
            allocator.free(todo.title);
            allocator.free(todo.description);
        }
        all_todos.deinit(allocator);
    }

    for (all_todos.items) |todo| {
        if (todo.completed and (now - todo.updated_at) > SEVEN_DAYS_MS) {
            _ = deleteTodo(orm, todo.id) catch continue;
            cleaned += 1;
        }
    }

    if (cleaned > 0) {
        std.debug.print("[Task] Cleaned up {d} old completed todos\n", .{cleaned});
    }
}

fn generateStatistics() void {
    const orm = getORM() catch return;
    _ = getStats(orm) catch {};
}

fn validateStoreHealth() void {
    const orm = getORM() catch return;
    const stats = getStats(orm) catch return;

    // Database doesn't have capacity limits, but we can warn if there are many todos
    if (stats.total > 10000) {
        std.debug.print("[Task] WARNING: Todo count at {d} - very high!\n", .{stats.total});
    } else if (stats.total > 5000) {
        std.debug.print("[Task] WARNING: Todo count at {d} - getting high\n", .{stats.total});
    }
}

// ============================================================================
// HEALTH CHECKS
// ============================================================================

fn checkTodoStoreHealth() E12.HealthStatus {
    const orm = getORM() catch return .unhealthy;
    const stats = getStats(orm) catch return .unhealthy;

    // Database doesn't have capacity limits, but we can check if there are too many todos
    if (stats.total > 10000) {
        return .degraded;
    }

    return .healthy;
}

fn checkSystemPerformance() E12.HealthStatus {
    return .healthy;
}

// ============================================================================
// APP SETUP
// ============================================================================

pub fn createApp() !E12.Engine12 {
    // Initialize database
    try initDatabase();

    var app = try E12.Engine12.initProduction();

    // Middleware
    try app.usePreRequest(&loggingMiddleware);
    try app.useResponse(&corsMiddleware);

    // Rate limiting for API endpoints
    var api_rate_limiter = rate_limit.RateLimiter.init(allocator, rate_limit.RateLimitConfig{
        .max_requests = 100,
        .window_ms = 60000, // 1 minute
    });

    try api_rate_limiter.setRouteConfig("/api/todos", rate_limit.RateLimitConfig{
        .max_requests = 50,
        .window_ms = 60000,
    });

    app.setRateLimiter(&api_rate_limiter);

    // Root route - serve templated index page (register BEFORE static files)
    try app.get("/", handleIndex);

    // Static file serving - register AFTER root route so it doesn't override it
    // Serve static files except for index.html which we'll handle with template
    try app.serveStatic("/css", "todo/frontend/css");
    try app.serveStatic("/js", "todo/frontend/js");

    // API routes
    try app.get("/api/todos", handleGetTodos);
    try app.get("/api/todos/stats", handleGetStats);
    try app.get("/api/todos/:id", handleGetTodo);
    try app.post("/api/todos", handleCreateTodo);
    try app.put("/api/todos/:id", handleUpdateTodo);
    try app.delete("/api/todos/:id", handleDeleteTodo);

    // Background tasks
    try app.schedulePeriodicTask("cleanup_old_todos", &cleanupOldCompletedTodos, 3600000);
    try app.schedulePeriodicTask("generate_stats", &generateStatistics, 300000);
    try app.schedulePeriodicTask("validate_store_health", &validateStoreHealth, 600000);

    // Health checks
    try app.registerHealthCheck(&checkTodoStoreHealth);
    try app.registerHealthCheck(&checkSystemPerformance);

    return app;
}

pub fn run() !void {
    var app = try createApp();
    defer app.deinit();

    try app.start();
    app.printStatus();

    std.debug.print("Press Ctrl+C to stop\n", .{});

    while (true) {
        std.Thread.sleep(1000 * std.time.ns_per_ms);
    }
}
