const std = @import("std");
const E12 = @import("engine12");
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
const BasicAuthValve = E12.BasicAuthValve;
const RuntimeTemplate = E12.RuntimeTemplate;
const LoggingMiddleware = E12.LoggingMiddleware;
const LoggingConfig = E12.LoggingConfig;
const restApi = E12.restApi;
const RestApiConfig = E12.RestApiConfig;
const AuthUser = E12.AuthUser;
const HandlerCtx = E12.HandlerCtx;
const HandlerCtxError = E12.HandlerCtxError;

const allocator = std.heap.page_allocator;

// ============================================================================
// TODO MODEL & DATABASE
// ============================================================================

const Todo = struct {
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
var global_index_template: ?*RuntimeTemplate = null;
var db_mutex: std.Thread.Mutex = .{};
var global_app: ?*E12.Engine12 = null;
var global_cache: ?*ResponseCache = null;
var cache_mutex: std.Thread.Mutex = .{};

fn getLogger() ?*Logger {
    if (global_app) |app| {
        return app.getLogger();
    }
    return null;
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
        \\CREATE TABLE IF NOT EXISTS todos (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  title TEXT NOT NULL,
        \\  description TEXT NOT NULL,
        \\  completed INTEGER NOT NULL DEFAULT 0,
        \\  created_at INTEGER NOT NULL,
        \\  updated_at INTEGER NOT NULL
        \\)
    , "DROP TABLE IF EXISTS todos"));

    try registry.add(E12.orm.MigrationType.init(2, "add_priority", "ALTER TABLE todos ADD COLUMN priority TEXT NOT NULL DEFAULT 'medium'", "ALTER TABLE todos DROP COLUMN priority"));

    try registry.add(E12.orm.MigrationType.init(3, "add_due_date", "ALTER TABLE todos ADD COLUMN due_date INTEGER", "-- Cannot automatically reverse ALTER TABLE ADD COLUMN"));

    try registry.add(E12.orm.MigrationType.init(4, "add_tags", "ALTER TABLE todos ADD COLUMN tags TEXT NOT NULL DEFAULT ''", "ALTER TABLE todos DROP COLUMN tags"));

    try registry.add(E12.orm.MigrationType.init(5, "add_user_id",
        \\ALTER TABLE todos ADD COLUMN user_id INTEGER NOT NULL DEFAULT 1;
        \\CREATE INDEX IF NOT EXISTS idx_todo_user_id ON todos(user_id);
    , "-- Cannot automatically reverse ALTER TABLE ADD COLUMN"));

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

fn getAllTodos(orm: *ORM, user_id: i64) !std.ArrayListUnmanaged(Todo) {
    // Filter todos by user_id using raw SQL
    // IMPORTANT: Column order must match Todo struct field order:
    // id, user_id, title, description, completed, priority, due_date, tags, created_at, updated_at
    const sql = try std.fmt.allocPrint(orm.allocator, "SELECT id, user_id, title, description, completed, priority, due_date, tags, created_at, updated_at FROM todos WHERE user_id = {d}", .{user_id});
    defer orm.allocator.free(sql);

    var query_result = try orm.db.query(sql);
    defer query_result.deinit();

    return try query_result.toArrayList(Todo);
}

fn getStats(orm: *ORM, user_id: i64) !TodoStats {
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

// JSON utilities are now provided by Model abstraction
// Use TodoModel.toJson(), TodoModel.toResponse(), etc.

fn handleIndex(request: *Request) Response {
    _ = request;

    // Use runtime template for hot reloading (development mode)
    // Template content is automatically reloaded when file changes
    const template = global_index_template orelse {
        return Response.text("Template not loaded").withStatus(500);
    };

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

    // Render template using runtime renderer (supports hot reloading)
    // Template automatically reloads if file changes
    const html = template.render(IndexContext, context, allocator) catch {
        return Response.text("Internal server error: template rendering failed").withStatus(500);
    };

    return Response.html(html)
        .withHeader("Cache-Control", "no-cache, no-store, must-revalidate")
        .withHeader("Pragma", "no-cache")
        .withHeader("Expires", "0");
}

// ============================================================================
// REST API VALIDATOR & AUTHORIZATION
// ============================================================================

fn validateTodo(req: *Request, todo: Todo) anyerror!validation.ValidationErrors {
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

fn requireAuthForRestApi(req: *Request) !AuthUser {
    const user = BasicAuthValve.requireAuth(req) catch {
        return error.AuthenticationRequired;
    };

    // Convert BasicAuthValve.User to AuthUser
    // Note: AuthUser fields will be freed by the caller
    return AuthUser{
        .id = user.id,
        .username = try req.arena.allocator().dupe(u8, user.username),
        .email = try req.arena.allocator().dupe(u8, user.email),
        .password_hash = try req.arena.allocator().dupe(u8, user.password_hash),
    };
}

fn canAccessTodo(req: *Request, todo: Todo) !bool {
    const user = BasicAuthValve.requireAuth(req) catch {
        return false;
    };
    defer {
        allocator.free(user.username);
        allocator.free(user.email);
        allocator.free(user.password_hash);
    }

    // User can only access their own todos
    return todo.user_id == user.id;
}

// ============================================================================
// REQUEST HANDLERS
// ============================================================================

fn handleSearchTodos(request: *Request) Response {
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

// Custom logging middleware removed - using built-in LoggingMiddleware instead

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

    // Use raw SQL to delete old completed todos for all users
    const sql = std.fmt.allocPrint(orm.allocator,
        \\DELETE FROM todos WHERE completed = 1 AND ({} - updated_at) > {}
    , .{ now, SEVEN_DAYS_MS }) catch {
        if (logger) |l| {
            const entry = l.logError("Failed to build cleanup SQL") catch return;
            entry.log();
        }
        return;
    };
    defer orm.allocator.free(sql);

    _ = orm.db.execute(sql) catch {
        if (logger) |l| {
            const entry = l.logError("Failed to cleanup old todos") catch return;
            entry.log();
        }
        return;
    };

    if (logger) |l| {
        const entry = l.info("Cleaned up old completed todos") catch return;
        entry.log();
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

    // Use raw SQL to count overdue todos for all users
    const sql = std.fmt.allocPrint(orm.allocator,
        \\SELECT COUNT(*) as count FROM todos WHERE completed = 0 AND due_date IS NOT NULL AND due_date < {}
    , .{now}) catch {
        if (logger) |l| {
            const entry = l.logError("Failed to build overdue check SQL") catch return;
            entry.log();
        }
        return;
    };
    defer orm.allocator.free(sql);

    var result = orm.db.query(sql) catch {
        if (logger) |l| {
            const entry = l.logError("Failed to check overdue todos") catch return;
            entry.log();
        }
        return;
    };
    defer result.deinit();

    // Parse count from result (simplified - just log if any found)
    if (logger) |l| {
        const entry = l.info("Checked for overdue todos") catch return;
        entry.log();
    }
}

fn generateStatistics() void {
    // Statistics are now user-specific, so this background task is not applicable
    // Stats are generated on-demand per user via handleGetStats
    _ = getORM() catch return;
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

    // Use raw SQL to count all todos across all users
    const sql = "SELECT COUNT(*) as count FROM todos";
    var result = orm.db.query(sql) catch {
        if (logger) |l| {
            const entry = l.logError("Failed to get todo count for health validation") catch return;
            entry.log();
        }
        return;
    };
    defer result.deinit();

    // Database doesn't have capacity limits, but we can warn if there are many todos
    // For now, just log that health check ran
    if (logger) |l| {
        const entry = l.info("Store health validation completed") catch return;
        entry.log();
    }
}

// ============================================================================
// HEALTH CHECKS
// ============================================================================

fn checkTodoStoreHealth() E12.HealthStatus {
    const orm = getORM() catch return .unhealthy;

    // Simple health check - just verify database is accessible
    _ = orm.db.query("SELECT 1") catch return .unhealthy;

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

    // Use initDevelopment() to enable hot reloading for templates and static files
    var app = try E12.Engine12.initDevelopment();

    // Initialize and register authentication valve
    const orm = getORM() catch {
        return error.DatabaseNotInitialized;
    };
    var auth_valve = BasicAuthValve.init(.{
        .secret_key = "todo-app-secret-key-change-in-production",
        .orm = orm,
        .token_expiry_seconds = 3600,
        .user_table_name = "users",
    });
    try app.registerValve(&auth_valve.valve);

    // Example: Check valve state and handle errors
    // This demonstrates the new valve system improvements:
    // - Thread-safe state queries
    // - Structured error reporting
    // - Automatic route cleanup on unregistration
    if (app.getValveRegistry()) |registry| {
        // Check valve state (thread-safe)
        if (registry.getValveState("basic_auth")) |state| {
            switch (state) {
                .registered => std.debug.print("[Valve] basic_auth: registered\n", .{}),
                .initialized => std.debug.print("[Valve] basic_auth: initialized\n", .{}),
                .started => std.debug.print("[Valve] basic_auth: started\n", .{}),
                .stopped => std.debug.print("[Valve] basic_auth: stopped\n", .{}),
                .failed => {
                    std.debug.print("[Valve] basic_auth: failed\n", .{});
                    // Get structured error information
                    if (registry.getErrorInfo("basic_auth")) |error_info| {
                        std.debug.print("[Valve] Error phase: {}\n", .{error_info.phase});
                        std.debug.print("[Valve] Error type: {s}\n", .{error_info.error_type});
                        std.debug.print("[Valve] Error message: {s}\n", .{error_info.message});
                        std.debug.print("[Valve] Error timestamp: {}\n", .{error_info.timestamp});
                    }
                    // Or get formatted error string (backward compatible)
                    const error_msg = registry.getValveErrors("basic_auth");
                    if (error_msg.len > 0) {
                        std.debug.print("[Valve] Error: {s}\n", .{error_msg});
                    }
                },
            }
        }

        // Check if valve is healthy (thread-safe)
        if (registry.isValveHealthy("basic_auth")) {
            std.debug.print("[Valve] basic_auth is healthy\n", .{});
        } else {
            std.debug.print("[Valve] basic_auth is unhealthy\n", .{});
        }

        // Get all failed valves (thread-safe)
        const failed_valves = registry.getFailedValves(allocator) catch |err| {
            std.debug.print("[Valve] Failed to get failed valves: {}\n", .{err});
            return err;
        };
        defer allocator.free(failed_valves);
        if (failed_valves.len > 0) {
            std.debug.print("[Valve] Failed valves: ", .{});
            for (failed_valves, 0..) |name, i| {
                if (i > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{name});
            }
            std.debug.print("\n", .{});
        }

        // Example: Unregistering a valve automatically cleans up its routes
        // try app.unregisterValve("basic_auth");
        // All routes registered by basic_auth would be automatically removed
    }

    // Load template for hot reloading (development mode only)
    // Template will automatically reload when file changes
    // Path is relative to the engine12 root directory (where the app is run from)
    const template_path = "todo/src/templates/index.zt.html";
    global_index_template = try app.loadTemplate(template_path);

    // Register root route FIRST to prevent default handler from being registered
    // This must be done before any other routes that might build the server
    try app.get("/", handleIndex);

    // Enable OpenAPI documentation
    try app.enableOpenApiDocs("/docs", .{
        .title = "Todo API",
        .version = "1.0.0",
        .description = "A simple todo management API with user authentication and filtering",
    });

    // Register auth routes directly (valve system doesn't support runtime route registration yet)
    try app.post("/auth/register", BasicAuthValve.handleRegister);
    try app.post("/auth/login", BasicAuthValve.handleLogin);
    try app.post("/auth/logout", BasicAuthValve.handleLogout);
    try app.get("/auth/me", BasicAuthValve.handleGetMe);

    // Store app globally for background tasks to access logger
    global_app = &app;

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
    // Order matters: body size limit -> CSRF -> CORS -> request ID -> logging
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

    // Enable built-in request/response logging middleware
    // Exclude health check endpoints from logging
    const logging_config = LoggingConfig{
        .log_requests = true,
        .log_responses = true,
        .exclude_paths = &[_][]const u8{ "/metrics", "/health" },
    };
    try app.enableRequestLogging(logging_config);

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

    // Metrics endpoint
    try app.get("/metrics", handleMetrics);

    // Static file serving - register AFTER root route so it doesn't override it
    // Serve static files except for index.html which we'll handle with template
    try app.serveStatic("/css", "todo/frontend/css");
    try app.serveStatic("/js", "todo/frontend/js");

    // API routes
    // Note: Route groups require comptime evaluation, so we register routes directly
    // Route groups are demonstrated in the codebase but require comptime usage

    // Custom endpoints for search and stats (not standard REST operations)
    try app.get("/api/todos/search", handleSearchTodos);
    try app.get("/api/todos/stats", handleGetStats);

    // RESTful API endpoints - restApi automatically handles:
    // - GET /api/todos (list with automatic user_id filtering, pagination, filtering, sorting)
    // - GET /api/todos/:id (show)
    // - POST /api/todos (create)
    // - PUT /api/todos/:id (update)
    // - DELETE /api/todos/:id (delete)
    // restApi automatically filters by user_id when authenticator is present and model has user_id field
    const orm_for_rest = getORM() catch {
        return error.DatabaseNotInitialized;
    };
    try app.restApi("/api/todos", Todo, RestApiConfig(Todo){
        .orm = orm_for_rest,
        .validator = validateTodo,
        .authenticator = requireAuthForRestApi,
        .authorization = canAccessTodo,
        .enable_pagination = true,
        .enable_filtering = true,
        .enable_sorting = true,
        .cache_ttl_ms = 30000, // 30 seconds
        // Note: Hooks are not currently supported due to Zig type system limitations
        // User_id and timestamps should be set in the validator or by modifying the model before calling restApi
    });

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
