const std = @import("std");
const E12 = @import("Engine12");
const Request = E12.Request;
const Response = E12.Response;
const validation = E12.validation;
const middleware_chain = E12.middleware;
const rate_limit = E12.rate_limit;
const cache = E12.cache;
const templates = E12.templates;

const allocator = std.heap.page_allocator;

// ============================================================================
// TODO MODEL & STORE
// ============================================================================

const Todo = struct {
    id: u32,
    title: []const u8,
    description: []const u8,
    completed: bool,
    created_at: i64,
    updated_at: i64,
};

const TodoStats = struct {
    total: u32,
    completed: u32,
    pending: u32,
    completed_percentage: f32,
};

const TodoStore = struct {
    const MAX_TODOS = 1000;

    todos: [MAX_TODOS]?Todo = [_]?Todo{null} ** MAX_TODOS,
    next_id: u32 = 1,
    mutex: std.Thread.Mutex = .{},

    pub fn create(self: *TodoStore, alloc: std.mem.Allocator, title: []const u8, description: []const u8) !Todo {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.next_id > MAX_TODOS) {
            return error.StoreFull;
        }

        const now = std.time.milliTimestamp();
        const title_copy = try alloc.dupe(u8, title);
        const desc_copy = try alloc.dupe(u8, description);

        const todo = Todo{
            .id = self.next_id,
            .title = title_copy,
            .description = desc_copy,
            .completed = false,
            .created_at = now,
            .updated_at = now,
        };

        self.todos[self.next_id - 1] = todo;
        self.next_id += 1;
        return todo;
    }

    pub fn findById(self: *TodoStore, id: u32) ?*Todo {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (id == 0 or id >= self.next_id) return null;
        const idx = id - 1;
        if (self.todos[idx]) |*todo| {
            return todo;
        }
        return null;
    }

    pub fn getAll(self: *TodoStore) []const ?Todo {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.todos[0..self.next_id];
    }

    pub fn update(self: *TodoStore, alloc: std.mem.Allocator, id: u32, updates: struct {
        title: ?[]const u8 = null,
        description: ?[]const u8 = null,
        completed: ?bool = null,
    }) !?*Todo {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (id == 0 or id >= self.next_id) return null;
        const idx = id - 1;
        if (self.todos[idx]) |*todo| {
            if (updates.title) |title| {
                alloc.free(todo.title);
                todo.title = try alloc.dupe(u8, title);
            }

            if (updates.description) |desc| {
                alloc.free(todo.description);
                todo.description = try alloc.dupe(u8, desc);
            }

            if (updates.completed) |completed| {
                todo.completed = completed;
            }

            todo.updated_at = std.time.milliTimestamp();
            return todo;
        }
        return null;
    }

    pub fn delete(self: *TodoStore, id: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (id == 0 or id >= self.next_id) return false;
        const idx = id - 1;
        if (self.todos[idx]) |todo| {
            allocator.free(todo.title);
            allocator.free(todo.description);
            self.todos[idx] = null;
            return true;
        }
        return false;
    }

    pub fn getStats(self: *TodoStore) TodoStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var total: u32 = 0;
        var completed: u32 = 0;

        for (self.todos[0..self.next_id]) |maybe_todo| {
            if (maybe_todo) |todo| {
                total += 1;
                if (todo.completed) {
                    completed += 1;
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
        };
    }

    pub fn getCapacityPercentage(self: *TodoStore) f32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        return (@as(f32, @floatFromInt(self.next_id - 1)) / @as(f32, @floatFromInt(MAX_TODOS))) * 100.0;
    }
};

var global_store = TodoStore{};

fn getStore() *TodoStore {
    return &global_store;
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

fn formatTodoListJson(todos: []const ?Todo, alloc: std.mem.Allocator) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(alloc);

    try list.writer(alloc).print("[", .{});

    var first = true;
    for (todos) |maybe_todo| {
        if (maybe_todo) |todo| {
            if (!first) {
                try list.writer(alloc).print(",", .{});
            }
            const todo_json = formatTodoJson(todo, alloc) catch continue;
            defer alloc.free(todo_json);
            try list.writer(alloc).print("{s}", .{todo_json});
            first = false;
        }
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

    return Response.html(html);
}

// ============================================================================
// REQUEST HANDLERS
// ============================================================================

fn handleGetTodos(request: *Request) Response {
    _ = request;
    const store = getStore();
    const todos = store.getAll();

    const json = formatTodoListJson(todos, allocator) catch {
        return Response.json("{\"error\":\"Failed to format todos\"}");
    };
    return Response.json(json);
}

fn handleGetTodo(request: *Request) Response {
    const id = request.param("id").asU32() catch {
        return Response.json("{\"error\":\"Invalid ID\"}");
    };

    const store = getStore();
    const todo = store.findById(id) orelse {
        return Response.json("{\"error\":\"Todo not found\"}");
    };

    const json = formatTodoJson(todo.*, allocator) catch {
        return Response.json("{\"error\":\"Failed to format todo\"}");
    };
    return Response.json(json);
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

    const store = getStore();
    const todo = store.create(allocator, parsed.title, parsed.description) catch |err| {
        const err_msg = switch (err) {
            error.StoreFull => "{\"error\":\"Store is full\"}",
            else => "{\"error\":\"Failed to create todo\"}",
        };
        return Response.json(err_msg);
    };

    const json = formatTodoJson(todo, allocator) catch {
        return Response.json("{\"error\":\"Failed to format todo\"}");
    };
    return Response.json(json);
}

fn handleUpdateTodo(request: *Request) Response {
    const id = request.param("id").asU32() catch {
        return Response.json("{\"error\":\"Invalid ID\"}");
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

    const store = getStore();
    const updates = store.update(allocator, id, .{
        .title = if (parsed.title.len > 0) parsed.title else null,
        .description = if (parsed.description.len > 0) parsed.description else null,
        .completed = parsed.completed,
    }) catch {
        return Response.json("{\"error\":\"Failed to update todo\"}");
    };

    const todo = updates orelse {
        return Response.json("{\"error\":\"Todo not found\"}");
    };

    const json = formatTodoJson(todo.*, allocator) catch {
        return Response.json("{\"error\":\"Failed to format todo\"}");
    };
    return Response.json(json);
}

fn handleDeleteTodo(request: *Request) Response {
    const id = request.param("id").asU32() catch {
        return Response.json("{\"error\":\"Invalid ID\"}");
    };

    const store = getStore();
    const deleted = store.delete(id);

    if (deleted) {
        return Response.json("{\"success\":true}");
    } else {
        return Response.json("{\"error\":\"Todo not found\"}");
    }
}

fn handleGetStats(request: *Request) Response {
    _ = request;
    const store = getStore();
    const stats = store.getStats();

    const json = formatStatsJson(stats, allocator) catch {
        return Response.json("{\"error\":\"Failed to format stats\"}");
    };
    return Response.json(json);
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
    const store = getStore();
    const now = std.time.milliTimestamp();

    var cleaned: u32 = 0;

    var i: u32 = 0;
    while (i < store.next_id) : (i += 1) {
        if (store.todos[i]) |todo| {
            if (todo.completed and (now - todo.updated_at) > SEVEN_DAYS_MS) {
                _ = store.delete(todo.id);
                cleaned += 1;
            }
        }
    }

    if (cleaned > 0) {
        std.debug.print("[Task] Cleaned up {d} old completed todos\n", .{cleaned});
    }
}

fn generateStatistics() void {
    _ = getStore().getStats();
}

fn validateStoreHealth() void {
    const store = getStore();
    const capacity = store.getCapacityPercentage();

    if (capacity > 95.0) {
        std.debug.print("[Task] WARNING: Store capacity at {d:.2}% - critically high!\n", .{capacity});
    } else if (capacity > 80.0) {
        std.debug.print("[Task] WARNING: Store capacity at {d:.2}% - approaching limit\n", .{capacity});
    }
}

// ============================================================================
// HEALTH CHECKS
// ============================================================================

fn checkTodoStoreHealth() E12.HealthStatus {
    const store = getStore();
    const capacity = store.getCapacityPercentage();

    if (capacity > 95.0) {
        return .unhealthy;
    } else if (capacity > 80.0) {
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

    // Response caching for GET endpoints
    var response_cache = cache.ResponseCache.init(allocator, 300000); // 5 minute default TTL
    app.setCache(&response_cache);
    const cacheMw = cache.createCachingMiddleware(&response_cache, "/api/todos", null);
    try app.usePreRequest(cacheMw);

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
