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
const MigrationRegistry = E12.orm.MigrationRegistryType;
const Logger = E12.Logger;
const LogLevel = E12.LogLevel;
const ResponseCache = E12.ResponseCache;
const error_handler = E12.error_handler;
const ErrorResponse = error_handler.ErrorResponse;
const cors_middleware = E12.cors_middleware;
const request_id_middleware = E12.request_id_middleware;
const pagination = E12.pagination;

const allocator = std.heap.page_allocator;

// ============================================================================
// TODO MODEL & DATABASE
// ============================================================================

const Todo = struct {
    id: i64,
    title: []u8,
    description: []u8,
    completed: bool,
    priority: []u8,
    due_date: ?i64,
    tags: []u8,
    created_at: i64,
    updated_at: i64,
};

// Model wrappers for Todo
const TodoModel = E12.orm.Model(Todo);
const TodoModelORM = E12.orm.ModelWithORM(Todo);
const TodoStatsModel = E12.orm.ModelStats(Todo, TodoStats);

// Input struct for JSON parsing (matches what parseTodoFromJson returned)
const TodoInput = struct {
    title: ?[]const u8,
    description: ?[]const u8,
    completed: ?bool,
    priority: ?[]const u8,
    due_date: ?i64,
    tags: ?[]const u8,
};

var global_db: ?Database = null;
var global_orm: ?ORM = null;
var db_mutex: std.Thread.Mutex = .{};
var global_logger: ?*Logger = null;
var logger_mutex: std.Thread.Mutex = .{};
var global_cache: ?*ResponseCache = null;
var cache_mutex: std.Thread.Mutex = .{};

fn getLogger() ?*Logger {
    logger_mutex.lock();
    defer logger_mutex.unlock();
    return global_logger;
}

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

    // Initialize ORM first (needed for migrations)
    global_orm = ORM.init(global_db.?, allocator);

    // Use MigrationRegistry to manage migrations
    var registry = MigrationRegistry.init(allocator);
    defer registry.deinit();

    // Add migrations to registry
    try registry.add(E12.orm.MigrationType.init(1, "create_todos",
        \\CREATE TABLE IF NOT EXISTS Todo (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  title TEXT NOT NULL,
        \\  description TEXT NOT NULL,
        \\  completed INTEGER NOT NULL DEFAULT 0,
        \\  created_at INTEGER NOT NULL,
        \\  updated_at INTEGER NOT NULL
        \\)
    , "DROP TABLE IF EXISTS Todo"));

    try registry.add(E12.orm.MigrationType.init(2, "add_priority", "ALTER TABLE Todo ADD COLUMN priority TEXT NOT NULL DEFAULT 'medium'", "ALTER TABLE Todo DROP COLUMN priority"));

    try registry.add(E12.orm.MigrationType.init(3, "add_due_date", "ALTER TABLE Todo ADD COLUMN due_date INTEGER", "-- Cannot automatically reverse ALTER TABLE ADD COLUMN"));

    try registry.add(E12.orm.MigrationType.init(4, "add_tags", "ALTER TABLE Todo ADD COLUMN tags TEXT NOT NULL DEFAULT ''", "ALTER TABLE Todo DROP COLUMN tags"));

    // Run migrations using the registry
    try global_orm.?.runMigrationsFromRegistry(&registry);
}

const TodoStats = struct {
    total: u32,
    completed: u32,
    pending: u32,
    completed_percentage: f32,
    overdue: u32,
};

fn createTodo(orm: *ORM, title: []const u8, description: []const u8, priority: []const u8, due_date: ?i64, tags: []const u8) !Todo {
    const now = std.time.milliTimestamp();
    const title_copy = try allocator.dupe(u8, title);
    errdefer allocator.free(title_copy);
    const desc_copy = try allocator.dupe(u8, description);
    errdefer allocator.free(desc_copy);
    const priority_copy = try allocator.dupe(u8, priority);
    errdefer allocator.free(priority_copy);
    const tags_copy = try allocator.dupe(u8, tags);
    errdefer allocator.free(tags_copy);

    const todo = Todo{
        .id = 0,
        .title = title_copy,
        .description = desc_copy,
        .completed = false,
        .priority = priority_copy,
        .due_date = due_date,
        .tags = tags_copy,
        .created_at = now,
        .updated_at = now,
    };

    try orm.create(Todo, todo);

    // Get the last insert row ID
    const last_id = orm.db.lastInsertRowId() catch {
        // Fallback: query for the most recently created todo
        var all_todos_result = try orm.findAllManaged(Todo);
        defer all_todos_result.deinit();

        if (all_todos_result.isEmpty()) {
            return error.FailedToCreateTodo;
        }

        // Find the todo with the highest ID
        var max_id: i64 = 0;
        var found_todo: ?Todo = null;
        for (all_todos_result.getItems()) |t| {
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
                .priority = try allocator.dupe(u8, t.priority),
                .due_date = t.due_date,
                .tags = try allocator.dupe(u8, t.tags),
                .created_at = t.created_at,
                .updated_at = t.updated_at,
            };
        }

        return error.FailedToCreateTodo;
    };

    // Fetch the created todo by ID using managed result
    var find_result = try orm.findManaged(Todo, last_id);
    if (find_result) |*result| {
        defer result.deinit();
        if (result.first()) |t| {
            return Todo{
                .id = t.id,
                .title = try allocator.dupe(u8, t.title),
                .description = try allocator.dupe(u8, t.description),
                .completed = t.completed,
                .priority = try allocator.dupe(u8, t.priority),
                .due_date = t.due_date,
                .tags = try allocator.dupe(u8, t.tags),
                .created_at = t.created_at,
                .updated_at = t.updated_at,
            };
        }
    }

    return error.FailedToCreateTodo;
}

fn findTodoById(orm: *ORM, id: i64) !?Todo {
    // Use ModelWithORM for automatic memory management
    var model = TodoModelORM.init(orm);
    return try model.find(id);
}

fn getAllTodos(orm: *ORM) !std.ArrayListUnmanaged(Todo) {
    // Use ModelWithORM for automatic memory management
    var model = TodoModelORM.init(orm);
    return try model.findAll();
}

fn updateTodo(orm: *ORM, id: i64, updates: struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    completed: ?bool = null,
    priority: ?[]const u8 = null,
    due_date: ?i64 = null,
    tags: ?[]const u8 = null,
}) !?Todo {
    // Use ModelWithORM to find existing record
    var model = TodoModelORM.init(orm);
    const existing = try model.find(id);
    if (existing == null) return null;

    var todo = existing.?;
    defer {
        allocator.free(todo.title);
        allocator.free(todo.description);
        allocator.free(todo.priority);
        allocator.free(todo.tags);
    }

    // Merge updates into existing todo
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

    if (updates.priority) |priority| {
        allocator.free(todo.priority);
        todo.priority = try allocator.dupe(u8, priority);
    }

    if (updates.due_date) |due_date| {
        todo.due_date = due_date;
    }

    if (updates.tags) |tags| {
        allocator.free(todo.tags);
        todo.tags = try allocator.dupe(u8, tags);
    }

    todo.updated_at = std.time.milliTimestamp();

    // Use ModelWithORM.update which handles memory management
    return try model.update(id, todo);
}

fn deleteTodo(orm: *ORM, id: i64) !bool {
    // Use ModelWithORM for automatic memory management
    var model = TodoModelORM.init(orm);
    return try model.delete(id);
}

fn getStats(orm: *ORM) !TodoStats {
    // Use ModelStats.calculate for automatic data fetching
    var stats_model = TodoStatsModel.init(orm);
    return try stats_model.calculate(struct {
        fn calc(items: []const Todo, alloc: std.mem.Allocator) anyerror!TodoStats {
            _ = alloc;
            var total: u32 = 0;
            var completed: u32 = 0;
            var overdue: u32 = 0;
            const now = std.time.milliTimestamp();

            for (items) |todo| {
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
    }.calc);
}

// JSON utilities are now provided by Model abstraction
// Use TodoModel.toJson(), TodoModel.toResponse(), etc.

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
        .title = "Todo List",
        .subtitle = "Enter your todos here",
        .title_placeholder = "Enter todo title...",
        .description_placeholder = "Enter description (optional)...",
        .add_button_text = "Add Todo",
        .filter_all = "All",
        .filter_pending = "Pending",
        .filter_completed = "Completed",
        .empty_state_message = "No todos yet. Add one above to get started!",
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
    // Check cache first
    const cache_key = "todos:all";
    if (request.cacheGet(cache_key) catch null) |entry| {
        return Response.text(entry.body)
            .withContentType(entry.content_type)
            .withHeader("X-Cache", "HIT");
    }

    const orm = getORM() catch {
        return Response.serverError("Database not initialized");
    };

    // Use ModelWithORM directly for cleaner code
    var model = TodoModelORM.init(orm);
    var todos = model.findAll() catch {
        return Response.serverError("Failed to fetch todos");
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

    // Use Model to create response
    const response = TodoModel.toResponseList(todos, allocator);

    // Cache the result for 30 seconds - need to serialize for cache
    const json = TodoModel.toJsonList(todos, allocator) catch {
        return response;
    };
    defer allocator.free(json);
    request.cacheSet(cache_key, json, 30000, "application/json") catch {};

    return response.withHeader("X-Cache", "MISS");
}

fn handleGetTodo(request: *Request) Response {
    const id = request.paramTyped(i64, "id") catch {
        return Response.errorResponse("Invalid ID", 400);
    };

    const orm = getORM() catch {
        return Response.serverError("Database not initialized");
    };

    // Use ModelWithORM directly
    var model = TodoModelORM.init(orm);
    const todo = model.find(id) catch {
        return Response.serverError("Failed to fetch todo");
    };

    const found = todo orelse {
        return Response.notFound("Todo not found");
    };
    defer {
        allocator.free(found.title);
        allocator.free(found.description);
        allocator.free(found.priority);
        allocator.free(found.tags);
    }

    return TodoModel.toResponse(found, allocator)
        .withHeader("Cache-Control", "no-cache, no-store, must-revalidate")
        .withHeader("Pragma", "no-cache")
        .withHeader("Expires", "0");
}

fn handleCreateTodo(request: *Request) Response {
    const parsed = request.jsonBody(TodoInput) catch {
        return Response.errorResponse("Invalid JSON", 400);
    };
    // Note: parsed strings are allocated with request.arena.allocator()
    // They will be automatically freed when the request ends, so no manual cleanup needed

    // Use validation framework
    var schema = validation.ValidationSchema.init(request.arena.allocator());
    defer schema.deinit();

    // Validate title (required, max 200 chars)
    const title_for_validation = parsed.title orelse "";
    const title_validator = schema.field("title", title_for_validation) catch {
        return Response.serverError("Validation error");
    };
    title_validator.rule(validation.required) catch {
        return Response.serverError("Validation error");
    };
    title_validator.maxLength(200) catch {
        return Response.serverError("Validation error");
    };

    // Validate description if provided (max 1000 chars)
    if (parsed.description) |desc| {
        if (desc.len > 0) {
            const desc_validator = schema.field("description", desc) catch {
                return Response.serverError("Validation error");
            };
            desc_validator.maxLength(1000) catch {
                return Response.serverError("Validation error");
            };
        }
    }

    // Validate priority if provided
    if (parsed.priority) |priority| {
        const priority_validator = schema.field("priority", priority) catch {
            return Response.serverError("Validation error");
        };
        const allowed_priorities = [_][]const u8{ "low", "medium", "high" };
        priority_validator.oneOf(&allowed_priorities) catch {
            return Response.serverError("Validation error");
        };
    }

    // Validate tags if provided (max 500 chars)
    if (parsed.tags) |tags| {
        const tags_validator = schema.field("tags", tags) catch {
            return Response.serverError("Validation error");
        };
        tags_validator.maxLength(500) catch {
            return Response.serverError("Validation error");
        };
    }

    // Run validation
    var validation_errors = schema.validate() catch {
        return Response.serverError("Validation error");
    };
    defer validation_errors.deinit();

    if (!validation_errors.isEmpty()) {
        return Response.validationError(&validation_errors);
    }

    const orm = getORM() catch {
        return Response.serverError("Database not initialized");
    };

    const title_value = parsed.title orelse return Response.errorResponse("Title is required", 400);
    const description_value = parsed.description orelse "";
    const priority_value = parsed.priority orelse "medium";
    const tags_value = parsed.tags orelse "";

    // Use ModelWithORM directly for cleaner code
    var model = TodoModelORM.init(orm);
    const now = std.time.milliTimestamp();

    // Copy strings from request arena to persistent allocator for database storage
    const title_copy = allocator.dupe(u8, title_value) catch {
        return Response.serverError("Failed to allocate memory");
    };
    errdefer allocator.free(title_copy);
    const desc_copy = allocator.dupe(u8, description_value) catch {
        allocator.free(title_copy);
        return Response.serverError("Failed to allocate memory");
    };
    errdefer allocator.free(desc_copy);
    const priority_copy = allocator.dupe(u8, priority_value) catch {
        allocator.free(title_copy);
        allocator.free(desc_copy);
        return Response.serverError("Failed to allocate memory");
    };
    errdefer allocator.free(priority_copy);
    const tags_copy = allocator.dupe(u8, tags_value) catch {
        allocator.free(title_copy);
        allocator.free(desc_copy);
        allocator.free(priority_copy);
        return Response.serverError("Failed to allocate memory");
    };
    errdefer allocator.free(tags_copy);

    const new_todo = Todo{
        .id = 0,
        .title = title_copy,
        .description = desc_copy,
        .completed = false,
        .priority = priority_copy,
        .due_date = parsed.due_date,
        .tags = tags_copy,
        .created_at = now,
        .updated_at = now,
    };

    const todo = model.create(new_todo) catch {
        allocator.free(title_copy);
        allocator.free(desc_copy);
        allocator.free(priority_copy);
        allocator.free(tags_copy);
        return Response.serverError("Failed to create todo");
    };

    // Free the original string copies - model.create() makes its own copies
    allocator.free(title_copy);
    allocator.free(desc_copy);
    allocator.free(priority_copy);
    allocator.free(tags_copy);

    defer {
        allocator.free(todo.title);
        allocator.free(todo.description);
        allocator.free(todo.priority);
        allocator.free(todo.tags);
    }

    // Invalidate cache when todos change
    request.cacheInvalidate("todos:all");
    request.cacheInvalidate("todos:stats");

    return TodoModel.toResponse(todo, allocator);
}

fn handleUpdateTodo(request: *Request) Response {
    const id = request.paramTyped(i64, "id") catch {
        return Response.errorResponse("Invalid ID", 400);
    };

    const parsed = request.jsonBody(TodoInput) catch {
        return Response.errorResponse("Invalid JSON", 400);
    };
    // Note: parsed strings are allocated with request.arena.allocator()
    // They will be automatically freed when the request ends, so no manual cleanup needed

    // Use validation framework
    var schema = validation.ValidationSchema.init(request.arena.allocator());
    defer schema.deinit();

    // Validate title if provided
    if (parsed.title) |title| {
        if (title.len > 0) {
            const title_validator = schema.field("title", title) catch {
                return Response.serverError("Validation error");
            };
            title_validator.maxLength(200) catch {
                return Response.serverError("Validation error");
            };
        }
    }

    // Validate description if provided
    if (parsed.description) |desc| {
        if (desc.len > 0) {
            const desc_validator = schema.field("description", desc) catch {
                return Response.serverError("Validation error");
            };
            desc_validator.maxLength(1000) catch {
                return Response.serverError("Validation error");
            };
        }
    }

    // Validate priority if provided
    if (parsed.priority) |priority| {
        const priority_validator = schema.field("priority", priority) catch {
            return Response.serverError("Validation error");
        };
        const allowed_priorities = [_][]const u8{ "low", "medium", "high" };
        priority_validator.oneOf(&allowed_priorities) catch {
            return Response.serverError("Validation error");
        };
    }

    // Validate tags if provided (max 500 chars)
    if (parsed.tags) |tags| {
        const tags_validator = schema.field("tags", tags) catch {
            return Response.serverError("Validation error");
        };
        tags_validator.maxLength(500) catch {
            return Response.serverError("Validation error");
        };
    }

    // Run validation
    var validation_errors = schema.validate() catch {
        return Response.serverError("Validation error");
    };
    defer validation_errors.deinit();

    if (!validation_errors.isEmpty()) {
        return Response.validationError(&validation_errors);
    }

    const orm = getORM() catch {
        return Response.serverError("Database not initialized");
    };

    const updates = updateTodo(orm, id, .{
        .title = parsed.title,
        .description = parsed.description,
        .completed = parsed.completed,
        .priority = parsed.priority,
        .due_date = parsed.due_date,
        .tags = parsed.tags,
    }) catch {
        return Response.serverError("Failed to update todo");
    };

    const todo = updates orelse {
        return Response.notFound("Todo not found");
    };
    defer {
        allocator.free(todo.title);
        allocator.free(todo.description);
        allocator.free(todo.priority);
        allocator.free(todo.tags);
    }

    // Invalidate cache when todos change
    request.cacheInvalidate("todos:all");
    request.cacheInvalidate("todos:stats");
    // Also invalidate specific todo cache if we had one
    const todo_cache_key = std.fmt.allocPrint(request.arena.allocator(), "todo:{d}", .{id}) catch {
        // If allocation fails, just skip individual cache invalidation
        return TodoModel.toResponse(todo, allocator);
    };
    request.cacheInvalidate(todo_cache_key);

    return TodoModel.toResponse(todo, allocator);
}

fn handleDeleteTodo(request: *Request) Response {
    const id = request.paramTyped(i64, "id") catch {
        return Response.errorResponse("Invalid ID", 400);
    };

    const orm = getORM() catch {
        return Response.serverError("Database not initialized");
    };

    // Use ModelWithORM directly
    var model = TodoModelORM.init(orm);
    const deleted = model.delete(id) catch {
        return Response.serverError("Failed to delete todo");
    };

    if (deleted) {
        // Invalidate cache when todos change
        request.cacheInvalidate("todos:all");
        request.cacheInvalidate("todos:stats");
        const todo_cache_key = std.fmt.allocPrint(request.arena.allocator(), "todo:{d}", .{id}) catch {
            // If allocation fails, just skip individual cache invalidation
            return Response.json("{\"success\":true}");
        };
        request.cacheInvalidate(todo_cache_key);

        return Response.json("{\"success\":true}");
    } else {
        return Response.notFound("Todo not found");
    }
}

fn handleSearchTodos(request: *Request) Response {
    // NOTE: QueryBuilder Limitation
    // The Engine12 QueryBuilder doesn't currently support OR conditions in WHERE clauses.
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

    const search_query = request.queryParamTyped([]const u8, "q") catch {
        return Response.errorResponse("Invalid query parameter", 400);
    } orelse {
        return Response.errorResponse("Missing query parameter", 400);
    };

    const orm = getORM() catch {
        return Response.serverError("Database not initialized");
    };

    // Use ORM's escapeLike method for safe SQL LIKE pattern escaping
    const escaped_query = orm.escapeLike(search_query, request.arena.allocator()) catch {
        return Response.serverError("Failed to escape query");
    };

    // Build search query - search in title, description, and tags
    const search_pattern = std.fmt.allocPrint(request.arena.allocator(), "%{s}%", .{escaped_query}) catch {
        return Response.serverError("Failed to format search query");
    };
    const sql = std.fmt.allocPrint(request.arena.allocator(),
        \\SELECT * FROM Todo WHERE 
        \\  title LIKE '{s}' OR 
        \\  description LIKE '{s}' OR 
        \\  tags LIKE '{s}'
        \\ORDER BY created_at DESC
    , .{ search_pattern, search_pattern, search_pattern }) catch {
        return Response.serverError("Failed to build search query");
    };

    var result = orm.db.query(sql) catch {
        return Response.serverError("Failed to search todos");
    };
    defer result.deinit();

    var todos = result.toArrayList(Todo) catch {
        return Response.serverError("Failed to parse search results");
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

fn handleMetrics(request: *Request) Response {
    _ = request;
    // Access global metrics collector
    const metrics_collector = E12.engine12.global_metrics;

    if (metrics_collector) |mc| {
        const prometheus_output = mc.getPrometheusMetrics() catch {
            return Response.serverError("Failed to generate metrics");
        };
        defer std.heap.page_allocator.free(prometheus_output);

        var resp = Response.text(prometheus_output);
        resp = resp.withContentType("text/plain; version=0.0.4");
        return resp;
    }

    // Fallback if metrics collector not available
    return Response.json("{\"metrics\":{\"uptime_ms\":0,\"requests_total\":0}}");
}

fn handleGetStats(request: *Request) Response {
    // Check cache first (shorter TTL for dynamic data)
    const cache_key = "todos:stats";
    if (request.cacheGet(cache_key) catch null) |entry| {
        return Response.text(entry.body)
            .withContentType(entry.content_type)
            .withHeader("X-Cache", "HIT");
    }
    const orm = getORM() catch {
        return Response.serverError("Database not initialized");
    };

    const stats = getStats(orm) catch {
        return Response.serverError("Failed to fetch stats");
    };

    // Use ModelStats to create response
    var stats_model = TodoStatsModel.init(orm);
    const response = stats_model.toResponse(stats, allocator);

    // Cache stats for 10 seconds - need to serialize for cache
    const json = stats_model.toJson(stats, allocator) catch {
        return response;
    };
    defer allocator.free(json);
    request.cacheSet(cache_key, json, 10000, "application/json") catch {};

    return response.withHeader("X-Cache", "MISS");
}

// ============================================================================
// MIDDLEWARE
// ============================================================================

fn customErrorHandler(req: *Request, err: ErrorResponse, alloc: std.mem.Allocator) Response {
    // Log error using structured logger
    if (getLogger()) |logger| {
        const log_level: LogLevel = switch (err.error_type) {
            .validation_error, .bad_request => .warn,
            .authentication_error, .authorization_error => .warn,
            .not_found => .info,
            .rate_limit_exceeded => .warn,
            .request_too_large => .warn,
            .timeout => .warn,
            .internal_error, .unknown => LogLevel.err,
        };

        const entry_opt = logger.log(log_level, err.message) catch null;
        if (entry_opt) |entry| {
            _ = entry.field("error_code", err.code) catch {};
            _ = entry.field("error_type", @tagName(err.error_type)) catch {};
            if (err.details) |details| {
                _ = entry.field("details", details) catch {};
            }
            // Include request ID if available
            if (req.get("request_id")) |request_id| {
                _ = entry.field("request_id", request_id) catch {};
            }
            entry.log();
        }
    }

    // Create JSON error response
    const json = err.toJson(alloc) catch {
        return Response.serverError("Failed to serialize error");
    };
    defer alloc.free(json);

    // Determine status code
    const status_code: u16 = switch (err.error_type) {
        .validation_error, .bad_request => 400,
        .authentication_error => 401,
        .authorization_error => 403,
        .not_found => 404,
        .rate_limit_exceeded => 429,
        .request_too_large => 413,
        .timeout => 408,
        .internal_error, .unknown => 500,
    };

    var resp = Response.json(json).withStatus(status_code);

    // Add request ID to response headers if available
    if (req.get("request_id")) |request_id| {
        resp = resp.withHeader("X-Request-ID", request_id);
    }

    return resp;
}

fn bodySizeLimitMiddleware(req: *Request) middleware_chain.MiddlewareResult {
    const MAX_BODY_SIZE: usize = 10 * 1024; // 10KB

    const body = req.body();
    if (body.len > MAX_BODY_SIZE) {
        // Set context flag
        req.set("body_size_exceeded", "true") catch {};

        // Abort request
        return .abort;
    }

    return .proceed;
}

fn csrfMiddleware(req: *Request) middleware_chain.MiddlewareResult {
    const method = req.method();

    // Skip CSRF check for safe methods
    if (std.mem.eql(u8, method, "GET") or
        std.mem.eql(u8, method, "HEAD") or
        std.mem.eql(u8, method, "OPTIONS"))
    {
        return .proceed;
    }

    // For POST/PUT/DELETE, check for CSRF token
    // Simplified implementation - in production, validate token against session
    // For demo purposes, we'll allow requests without CSRF token
    // In production, uncomment the code below to enforce CSRF protection
    const csrf_token = req.header("X-CSRF-Token");

    if (csrf_token == null or csrf_token.?.len == 0) {
        // Missing CSRF token - for demo app, we'll allow it
        // Uncomment below for strict CSRF protection:
        // req.set("csrf_error", "true") catch {};
        // return .abort;
    }

    // In a full implementation, we would validate the token here
    // A real implementation would compare against a session-stored token

    return .proceed;
}

fn requestTrackingMiddleware(req: *Request) middleware_chain.MiddlewareResult {
    // Store request start time in context
    const start_time = std.time.milliTimestamp();
    const start_time_str = std.fmt.allocPrint(req.arena.allocator(), "{d}", .{start_time}) catch {
        // If allocation fails, just proceed without tracking
        return .proceed;
    };
    req.set("request_start_time", start_time_str) catch {};

    return .proceed;
}

fn loggingMiddleware(req: *Request) middleware_chain.MiddlewareResult {
    if (getLogger()) |logger| {
        const entry = logger.fromRequest(req, .info, "Request received") catch {
            // If logging fails, just proceed
            return .proceed;
        };

        // Add request timing if available
        if (req.get("request_start_time")) |start_time_str| {
            _ = entry.field("start_time", start_time_str) catch {};
        }

        // Add request ID if available
        if (req.get("request_id")) |request_id| {
            _ = entry.field("request_id", request_id) catch {};
        }

        entry.log();
    }
    return .proceed;
}

// CORS middleware is now handled by the built-in CorsMiddleware
// This function is kept for backward compatibility but is replaced in createApp()
fn corsMiddleware(resp: Response) Response {
    return resp;
}

// ============================================================================
// BACKGROUND TASKS
// ============================================================================

const DAY_IN_MS: i64 = 24 * 60 * 60 * 1000;
const SEVEN_DAYS_MS: i64 = 7 * DAY_IN_MS;

fn cleanupOldCompletedTodos() void {
    const logger = getLogger();
    const orm = getORM() catch {
        if (logger) |l| {
            const entry = l.logError("Failed to get ORM for cleanup task") catch return;
            entry.log();
        }
        return;
    };
    const now = std.time.milliTimestamp();

    var cleaned: u32 = 0;

    var all_todos = getAllTodos(orm) catch {
        if (logger) |l| {
            const entry = l.logError("Failed to get todos for cleanup") catch return;
            entry.log();
        }
        return;
    };
    defer {
        for (all_todos.items) |todo| {
            allocator.free(todo.title);
            allocator.free(todo.description);
            allocator.free(todo.priority);
            allocator.free(todo.tags);
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
        if (logger) |l| {
            const entry = l.info("Cleaned up old completed todos") catch return;
            _ = entry.fieldInt("count", cleaned) catch return;
            entry.log();
        }
    }
}

fn checkOverdueTodos() void {
    const logger = getLogger();
    const orm = getORM() catch {
        if (logger) |l| {
            const entry = l.logError("Failed to get ORM for overdue check") catch return;
            entry.log();
        }
        return;
    };
    const now = std.time.milliTimestamp();

    var overdue_count: u32 = 0;

    var all_todos = getAllTodos(orm) catch {
        if (logger) |l| {
            const entry = l.logError("Failed to get todos for overdue check") catch return;
            entry.log();
        }
        return;
    };
    defer {
        for (all_todos.items) |todo| {
            allocator.free(todo.title);
            allocator.free(todo.description);
            allocator.free(todo.priority);
            allocator.free(todo.tags);
        }
        all_todos.deinit(allocator);
    }

    for (all_todos.items) |todo| {
        if (!todo.completed) {
            if (todo.due_date) |due_date| {
                if (due_date < now) {
                    overdue_count += 1;
                    if (logger) |l| {
                        const entry = l.warn("Overdue todo found") catch return;
                        _ = entry.field("title", todo.title) catch return;
                        _ = entry.fieldInt("due_date", due_date) catch return;
                        _ = entry.fieldInt("now", now) catch return;
                        entry.log();
                    }
                }
            }
        }
    }

    if (overdue_count > 0) {
        if (logger) |l| {
            const entry = l.info("Found overdue todos") catch return;
            _ = entry.fieldInt("count", overdue_count) catch return;
            entry.log();
        }
    }
}

fn generateStatistics() void {
    const orm = getORM() catch return;
    _ = getStats(orm) catch {};
}

fn validateStoreHealth() void {
    const logger = getLogger();
    const orm = getORM() catch {
        if (logger) |l| {
            const entry = l.logError("Failed to get ORM for health validation") catch return;
            entry.log();
        }
        return;
    };
    const stats = getStats(orm) catch {
        if (logger) |l| {
            const entry = l.logError("Failed to get stats for health validation") catch return;
            entry.log();
        }
        return;
    };

    // Database doesn't have capacity limits, but we can warn if there are many todos
    if (stats.total > 10000) {
        if (logger) |l| {
            const entry = l.warn("Todo count very high") catch return;
            _ = entry.fieldInt("count", stats.total) catch return;
            _ = entry.fieldInt("threshold", 10000) catch return;
            entry.log();
        }
    } else if (stats.total > 5000) {
        if (logger) |l| {
            const entry = l.warn("Todo count getting high") catch return;
            _ = entry.fieldInt("count", stats.total) catch return;
            _ = entry.fieldInt("threshold", 5000) catch return;
            entry.log();
        }
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

    // Store logger globally for background tasks
    logger_mutex.lock();
    global_logger = &app.logger;
    logger_mutex.unlock();

    // Initialize cache with 60 second default TTL
    // Allocate on heap so it persists beyond createApp() scope
    const response_cache = try allocator.create(ResponseCache);
    response_cache.* = ResponseCache.init(allocator, 60000);
    app.setCache(response_cache);

    // Store cache globally for potential background task usage
    cache_mutex.lock();
    global_cache = response_cache;
    cache_mutex.unlock();

    // Middleware
    // Order matters: body size limit -> CSRF -> CORS -> request ID -> request tracking -> logging
    try app.usePreRequest(&bodySizeLimitMiddleware);
    try app.usePreRequest(&csrfMiddleware);

    // CORS middleware
    var cors = cors_middleware.CorsMiddleware.init(.{
        .allowed_origins = &[_][]const u8{"*"}, // Allow all origins for demo
        .allowed_methods = &[_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS" },
        .allowed_headers = &[_][]const u8{ "Content-Type", "Authorization", "X-CSRF-Token" },
        .max_age = 3600,
        .allow_credentials = false,
    });
    cors.setGlobalConfig(); // Set global config before using middleware
    const cors_mw_fn = cors.preflightMwFn();
    try app.usePreRequest(cors_mw_fn);

    // Request ID middleware (ensures request IDs are exposed via headers)
    const req_id_mw = request_id_middleware.RequestIdMiddleware.init(.{});
    const req_id_mw_fn = req_id_mw.preRequestMwFn();
    try app.usePreRequest(req_id_mw_fn);

    try app.usePreRequest(&requestTrackingMiddleware);
    try app.usePreRequest(&loggingMiddleware);

    // Custom error handler
    app.useErrorHandler(customErrorHandler);

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

    // Metrics endpoint
    try app.get("/metrics", handleMetrics);

    // Static file serving - register AFTER root route so it doesn't override it
    // Serve static files except for index.html which we'll handle with template
    try app.serveStatic("/css", "todo/frontend/css");
    try app.serveStatic("/js", "todo/frontend/js");

    // API routes
    // Note: Route groups require comptime evaluation, so we register routes directly
    // Route groups are demonstrated in the codebase but require comptime usage
    try app.get("/api/todos", handleGetTodos);
    try app.get("/api/todos/search", handleSearchTodos);
    try app.get("/api/todos/stats", handleGetStats);
    try app.get("/api/todos/:id", handleGetTodo);
    try app.post("/api/todos", handleCreateTodo);
    try app.put("/api/todos/:id", handleUpdateTodo);
    try app.delete("/api/todos/:id", handleDeleteTodo);

    // Background tasks
    try app.schedulePeriodicTask("cleanup_old_todos", &cleanupOldCompletedTodos, 3600000);
    try app.schedulePeriodicTask("check_overdue_todos", &checkOverdueTodos, 3600000); // Every hour
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

    if (getLogger()) |logger| {
        const entry = logger.info("Server started - Press Ctrl+C to stop") catch return;
        entry.log();
    }

    while (true) {
        std.Thread.sleep(1000 * std.time.ns_per_ms);
    }
}
