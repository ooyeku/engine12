const std = @import("std");
const E12 = @import("engine12");
const Request = E12.Request;
const Response = E12.Response;
const middleware_chain = E12.middleware;
const rate_limit = E12.rate_limit;
const ResponseCache = E12.cache.ResponseCache;
const error_handler = E12.error_handler;
const ErrorResponse = error_handler.ErrorResponse;
const cors_middleware = E12.cors_middleware;
const request_id_middleware = E12.request_id_middleware;
const LoggingMiddleware = E12.LoggingMiddleware;
const LoggingConfig = E12.LoggingConfig;
const BasicAuthValve = E12.BasicAuthValve;
const RuntimeTemplate = E12.RuntimeTemplate;
const restApi = E12.restApi;
const RestApiConfig = E12.RestApiConfig;
const Logger = E12.Logger;
const LogLevel = E12.LogLevel;

// Project modules
const database = @import("database.zig");
const models = @import("models.zig");
const Todo = models.Todo;
const validators = @import("validators.zig");
const auth = @import("auth.zig");
const handlers = struct {
    const search = @import("handlers/search.zig");
    const stats = @import("handlers/stats.zig");
    const views = @import("handlers/views.zig");
    const metrics = @import("handlers/metrics.zig");
};

const allocator = std.heap.page_allocator;

// Background task constants
const DAY_IN_MS: i64 = 24 * 60 * 60 * 1000;
const SEVEN_DAYS_MS: i64 = 7 * DAY_IN_MS;

// ============================================================================
// MIDDLEWARE
// ============================================================================

fn customErrorHandler(req: *Request, err: ErrorResponse, alloc: std.mem.Allocator) Response {
    // Log error using structured logger
    if (database.getLogger()) |logger| {
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

// ============================================================================
// BACKGROUND TASKS
// ============================================================================

fn cleanupOldCompletedTodos() void {
    const logger = database.getLogger();
    const orm = database.getORM() catch {
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
    const logger = database.getLogger();
    const orm = database.getORM() catch {
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
    _ = database.getORM() catch return;
}

fn validateStoreHealth() void {
    const logger = database.getLogger();
    const orm = database.getORM() catch {
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
    const orm = database.getORM() catch return .unhealthy;

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
    try database.initDatabase();

    // Use initDevelopment() to enable hot reloading for templates and static files
    var app = try E12.Engine12.initDevelopment();

    // Initialize and register authentication valve
    const orm = database.getORM() catch {
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

    // Use template auto-discovery to automatically load templates
    // Scans templates/ directory for .zt.html files
    const template_registry_result = app.discoverTemplates("todo/src/templates");
    if (template_registry_result) |template_registry| {
        // Store template registry globally for handlers to access
        database.setGlobalTemplateRegistry(template_registry);
        std.debug.print("[Todo] Template registry set with {} templates\n", .{template_registry.count()});
    } else |err| {
        std.debug.print("[Todo] Warning: Template discovery failed: {}\n", .{err});
        // Fall back to manual template loading if discovery fails
        const template_path = "todo/src/templates/index.zt.html";
        if (app.loadTemplate(template_path)) |template| {
            database.setGlobalTemplate(template);
            std.debug.print("[Todo] Fallback: Loaded template manually\n", .{});
        } else |load_err| {
            std.debug.print("[Todo] Error: Failed to load template manually: {}\n", .{load_err});
            // Continue without template - handler will return error
        }
    }

    // Register root route FIRST to prevent default handler from being registered
    // This must be done before any other routes that might build the server
    try app.get("/", handlers.views.handleIndex);

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
    database.setGlobalApp(&app);

    // Initialize cache with 60 second default TTL
    // Allocate on heap so it persists beyond createApp() scope
    const response_cache = try allocator.create(ResponseCache);
    response_cache.* = ResponseCache.init(allocator, 60000);
    app.setCache(response_cache);

    // Store cache globally for potential background task usage
    database.setGlobalCache(response_cache);

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
    try app.get("/metrics", handlers.metrics.handleMetrics);

    // Use static file auto-discovery to automatically register static routes
    // Scans static/ directory for subdirectories and registers them
    // Convention: static/css/ -> /css/*, static/js/ -> /js/*
    app.discoverStaticFiles("todo/static") catch |err| {
        std.debug.print("[Todo] Warning: Static file discovery failed: {}\n", .{err});
        // Fall back to manual static file registration if discovery fails
        try app.serveStatic("/css", "todo/static/css");
        try app.serveStatic("/js", "todo/static/js");
    };

    // API routes
    // Note: Route groups require comptime evaluation, so we register routes directly
    // Route groups are demonstrated in the codebase but require comptime usage

    // Custom endpoints for search and stats (not standard REST operations)
    try app.get("/api/todos/search", handlers.search.handleSearchTodos);
    try app.get("/api/todos/stats", handlers.stats.handleGetStats);

    // RESTful API endpoints - restApi automatically handles:
    // - GET /api/todos (list with automatic user_id filtering, pagination, filtering, sorting)
    // - GET /api/todos/:id (show)
    // - POST /api/todos (create)
    // - PUT /api/todos/:id (update)
    // - DELETE /api/todos/:id (delete)
    // restApi automatically filters by user_id when authenticator is present and model has user_id field
    const orm_for_rest = database.getORM() catch {
        return error.DatabaseNotInitialized;
    };
    try app.restApi("/api/todos", Todo, RestApiConfig(Todo){
        .orm = orm_for_rest,
        .validator = validators.validateTodo,
        .authenticator = auth.requireAuthForRestApi,
        .authorization = auth.canAccessTodo,
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

pub fn main() !void {
    var app = try createApp();
    defer app.deinit();

    try app.start();
    app.printStatus();

    if (database.getLogger()) |logger| {
        const entry = logger.info("Server started - Press Ctrl+C to stop") catch return;
        entry.log();
    }

    while (true) {
        std.Thread.sleep(1000 * std.time.ns_per_ms);
    }
}
