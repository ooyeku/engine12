const std = @import("std");
const cli_utils = @import("../utils.zig");

/// Template for build.zig.zon
const BUILD_ZON_TEMPLATE =
    \\.{
    \\    .name = .{PROJECT_NAME_LITERAL},
    \\    .version = "0.1.0",
    \\    .minimum_zig_version = "0.15.1",
    \\    .dependencies = .{
    \\        .engine12 = .{
    \\            .url = "git+https://github.com/ooyeku/Engine12.git",
    \\            .hash = "{ENGINE12_HASH}",
    \\        },
    \\    },
    \\    .paths = .{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    },
    \\}
;

/// Template for build.zig
const BUILD_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    const engine12_dep = b.dependency("engine12", .{
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\
    \\    const exe = b.addExecutable(.{
    \\        .name = "{PROJECT_NAME}",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/main.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\        }),
    \\    });
    \\
    \\    exe.root_module.addImport("engine12", engine12_dep.module("engine12"));
    \\    exe.linkLibC(); // Required for ORM
    \\
    \\    b.installArtifact(exe);
    \\
    \\    const run_step = b.step("run", "Run the application");
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_step.dependOn(&run_cmd.step);
    \\    if (b.args) |args| {
    \\        run_cmd.addArgs(args);
    \\    }
    \\}
;

/// Template for main.zig
const MAIN_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\const E12 = @import("engine12");
    \\const app = @import("app.zig");
    \\
    \\pub fn main() !void {
    \\    try app.run();
    \\}
;

/// Template for app.zig
const APP_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\const E12 = @import("engine12");
    \\const Request = E12.Request;
    \\const Response = E12.Response;
    \\
    \\fn handleRoot(req: *Request) Response {
    \\    _ = req;
    \\    return Response.json("{{\"message\":\"Hello from {PROJECT_NAME}!\"}}");
    \\}
    \\
    \\pub fn run() !void {
    \\    var app = try E12.Engine12.initDevelopment();
    \\    defer app.deinit();
    \\
    \\    try app.get("/", handleRoot);
    \\
    \\    std.debug.print("Server starting on http://127.0.0.1:8080\n", .{});
    \\    std.debug.print("Press Ctrl+C to stop\n", .{});
    \\    try app.start();
    \\    
    \\    // Keep the server running indefinitely until interrupted (Ctrl+C)
    \\    while (true) { }
    \\}
;

/// Template for README.md
const README_TEMPLATE =
    \\# {PROJECT_NAME}
    \\
    \\A minimal engine12 application.
    \\
    \\## Getting Started
    \\
    \\```bash
    \\zig build run
    \\```
    \\
    \\The server will start on http://127.0.0.1:8080
    \\
;

/// Template for .gitignore
const GITIGNORE_TEMPLATE =
    \\zig-out/
    \\.zig-cache/
    \\zig-cache/
    \\zig-lock.json
    \\*.db
    \\.env
    \\.DS_Store
;

/// Template for models.zig
const MODELS_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\const E12 = @import("engine12");
    \\
    \\/// Example model
    \\pub const Item = struct {
    \\    id: i64,
    \\    user_id: i64,
    \\    title: []u8,
    \\    description: []u8,
    \\    created_at: i64,
    \\    updated_at: i64,
    \\};
    \\
    \\/// Input struct for JSON parsing
    \\pub const ItemInput = struct {
    \\    title: ?[]const u8,
    \\    description: ?[]const u8,
    \\};
    \\
    \\// Model wrappers
    \\pub const ItemModel = E12.orm.Model(Item);
    \\pub const ItemModelORM = E12.orm.ModelWithORM(Item);
;

/// Template for database.zig
const DATABASE_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\const E12 = @import("engine12");
    \\const Database = E12.orm.Database;
    \\const ORM = E12.orm.ORM;
    \\const MigrationRegistry = E12.orm.MigrationRegistryType;
    \\
    \\const allocator = std.heap.page_allocator;
    \\
    \\// Global state
    \\var global_db: ?Database = null;
    \\var global_orm: ?ORM = null;
    \\var db_mutex: std.Thread.Mutex = .{};
    \\
    \\/// Get the ORM instance
    \\pub fn getORM() !*ORM {
    \\    db_mutex.lock();
    \\    defer db_mutex.unlock();
    \\
    \\    if (global_orm) |*orm| {
    \\        return orm;
    \\    }
    \\
    \\    return error.DatabaseNotInitialized;
    \\}
    \\
    \\/// Initialize the database and run migrations
    \\pub fn initDatabase() !void {
    \\    db_mutex.lock();
    \\    defer db_mutex.unlock();
    \\
    \\    if (global_db != null) {
    \\        return; // Already initialized
    \\    }
    \\
    \\    // Open database file
    \\    const db_path = "app.db";
    \\    global_db = try Database.open(db_path, allocator);
    \\
    \\    // Initialize ORM
    \\    global_orm = ORM.init(global_db.?, allocator);
    \\
    \\    // Use migration discovery to load migrations
    \\    const migration_discovery = @import("engine12").orm.migration_discovery;
    \\    var registry = try migration_discovery.discoverMigrations(allocator, "src/migrations");
    \\    defer registry.deinit();
    \\
    \\    // Run migrations
    \\    try global_orm.?.runMigrationsFromRegistry(&registry);
    \\}
;

/// Template for validators.zig
const VALIDATORS_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\const E12 = @import("engine12");
    \\const Request = E12.Request;
    \\const validation = E12.validation;
    \\const models = @import("models.zig");
    \\const Item = models.Item;
    \\
    \\/// Validate an Item model instance
    \\pub fn validateItem(req: *Request, item: Item) anyerror!validation.ValidationErrors {
    \\    var errors = validation.ValidationErrors.init(req.arena.allocator());
    \\
    \\    // Validate title (required, max 200 chars)
    \\    if (item.title.len == 0) {
    \\        try errors.add("title", "Title is required", "required");
    \\    }
    \\    if (item.title.len > 200) {
    \\        try errors.add("title", "Title must be less than 200 characters", "max_length");
    \\    }
    \\
    \\    // Validate description (max 1000 chars)
    \\    if (item.description.len > 1000) {
    \\        try errors.add("description", "Description must be less than 1000 characters", "max_length");
    \\    }
    \\
    \\    return errors;
    \\}
;

/// Template for auth.zig
const AUTH_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\const E12 = @import("engine12");
    \\const Request = E12.Request;
    \\const AuthUser = E12.AuthUser;
    \\const BasicAuthValve = E12.BasicAuthValve;
    \\const models = @import("models.zig");
    \\const Item = models.Item;
    \\
    \\/// Require authentication for REST API endpoints
    \\pub fn requireAuthForRestApi(req: *Request) !AuthUser {
    \\    const user = BasicAuthValve.requireAuth(req) catch {
    \\        return error.AuthenticationRequired;
    \\    };
    \\
    \\    return AuthUser{
    \\        .id = user.id,
    \\        .username = try req.arena.allocator().dupe(u8, user.username),
    \\        .email = try req.arena.allocator().dupe(u8, user.email),
    \\        .password_hash = try req.arena.allocator().dupe(u8, user.password_hash),
    \\    };
    \\}
    \\
    \\/// Check if the authenticated user can access an item
    \\pub fn canAccessItem(req: *Request, item: Item) !bool {
    \\    const user = BasicAuthValve.requireAuth(req) catch {
    \\        return false;
    \\    };
    \\    defer {
    \\        std.heap.page_allocator.free(user.username);
    \\        std.heap.page_allocator.free(user.email);
    \\        std.heap.page_allocator.free(user.password_hash);
    \\    }
    \\
    \\    return item.user_id == user.id;
    \\}
;

/// Template for utils.zig
const UTILS_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\const E12 = @import("engine12");
    \\
    \\// Add your utility functions here
;

/// Template for handlers/search.zig
const HANDLER_SEARCH_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\const E12 = @import("engine12");
    \\const Request = E12.Request;
    \\const Response = E12.Response;
    \\const HandlerCtx = E12.HandlerCtx;
    \\const models = @import("../models.zig");
    \\const database = @import("../database.zig");
    \\const getORM = database.getORM;
    \\
    \\/// Example search handler using HandlerCtx
    \\pub fn handleSearch(request: *Request) Response {
    \\    var ctx = HandlerCtx.init(request, .{
    \\        .require_auth = true,
    \\        .require_orm = true,
    \\        .get_orm = getORM,
    \\    }) catch |err| {
    \\        return switch (err) {
    \\            error.AuthenticationRequired => Response.errorResponse("Authentication required", 401),
    \\            error.DatabaseNotInitialized => Response.serverError("Database not initialized"),
    \\            else => Response.serverError("Internal error"),
    \\        };
    \\    };
    \\
    \\    const query = ctx.query([]const u8, "q") catch {
    \\        return ctx.badRequest("Missing query parameter 'q'");
    \\    };
    \\
    \\    // Add your search logic here
    \\    return Response.json("{{\"results\":[]}}");
    \\}
;

/// Template for migrations/init.zig
const MIGRATIONS_INIT_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\const E12 = @import("engine12");
    \\const Migration = E12.orm.Migration;
    \\
    \\/// Initial migration
    \\pub const migrations = [_]Migration{
    \\    Migration.init(1, "create_items",
    \\        \\CREATE TABLE IF NOT EXISTS items (
    \\        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\        \\  user_id INTEGER NOT NULL,
    \\        \\  title TEXT NOT NULL,
    \\        \\  description TEXT NOT NULL,
    \\        \\  created_at INTEGER NOT NULL,
    \\        \\  updated_at INTEGER NOT NULL
    \\        \\)
    \\    , "DROP TABLE IF EXISTS items"),
    \\};
;

/// Template for static/css/style.css
const STATIC_CSS_TEMPLATE =
    \\/* Main stylesheet */
    \\body {
    \\    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
    \\    margin: 0;
    \\    padding: 20px;
    \\    background-color: #f5f5f5;
    \\}
    \\
    \\.container {
    \\    max-width: 800px;
    \\    margin: 0 auto;
    \\    background: white;
    \\    padding: 20px;
    \\    border-radius: 8px;
    \\    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    \\}
;

/// Template for static/js/app.js
const STATIC_JS_TEMPLATE =
    \\// Main application JavaScript
    \\console.log('Engine12 application loaded');
;

/// Template for templates/index.zt.html
const TEMPLATE_INDEX_ZT_HTML =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\    <meta charset="UTF-8">
    \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\    <title>{{ .title }}</title>
    \\    <link rel="stylesheet" href="/css/style.css">
    \\</head>
    \\<body>
    \\    <div class="container">
    \\        <h1>{{ .title }}</h1>
    \\        <p>{{ .message }}</p>
    \\    </div>
    \\    <script src="/js/app.js"></script>
    \\</body>
    \\</html>
;

/// Updated template for main.zig (recommended structure)
const MAIN_ZIG_RECOMMENDED_TEMPLATE =
    \\const std = @import("std");
    \\const E12 = @import("engine12");
    \\const Request = E12.Request;
    \\const Response = E12.Response;
    \\
    \\// Project modules
    \\const database = @import("database.zig");
    \\const models = @import("models.zig");
    \\const Item = models.Item;
    \\const validators = @import("validators.zig");
    \\const auth = @import("auth.zig");
    \\const handlers = struct {
    \\    const search = @import("handlers/search.zig");
    \\};
    \\
    \\const allocator = std.heap.page_allocator;
    \\
    \\pub fn main() !void {
    \\    // Initialize database
    \\    try database.initDatabase();
    \\
    \\    // Create app
    \\    var app = try E12.Engine12.initDevelopment();
    \\    defer app.deinit();
    \\
    \\    // Auto-discover static files
    \\    app.discoverStaticFiles("static") catch |err| {
    \\        std.debug.print("[Engine12] Warning: Static file discovery failed: {}\n", .{err});
    \\    };
    \\
    \\    // Auto-discover templates (development mode only)
    \\    const template_registry = app.discoverTemplates("src/templates") catch |err| {
    \\        std.debug.print("[Engine12] Warning: Template discovery failed: {}\n", .{err});
    \\        // Continue without templates
    \\    };
    \\    defer template_registry.deinit();
    \\
    \\    // Register root route
    \\    try app.get("/", handleIndex);
    \\
    \\    // Register custom handlers
    \\    try app.get("/api/items/search", handlers.search.handleSearch);
    \\
    \\    // Register REST API endpoints
    \\    const orm = try database.getORM();
    \\    try app.restApi("/api/items", Item, E12.RestApiConfig(Item){
    \\        .orm = orm,
    \\        .validator = validators.validateItem,
    \\        .authenticator = auth.requireAuthForRestApi,
    \\        .authorization = auth.canAccessItem,
    \\        .enable_pagination = true,
    \\        .enable_filtering = true,
    \\        .enable_sorting = true,
    \\    });
    \\
    \\    std.debug.print("Server starting on http://127.0.0.1:8080\n", .{});
    \\    std.debug.print("Press Ctrl+C to stop\n", .{});
    \\    try app.start();
    \\
    \\    // Keep the server running
    \\    while (true) {}
    \\}
    \\
    \\fn handleIndex(req: *Request) Response {
    \\    _ = req;
    \\    // Load template manually (or use template registry if stored globally)
    \\    const template = app.loadTemplate("src/templates/index.zt.html") catch {
    \\        return Response.text("Template not found").withStatus(500);
    \\    };
    \\
    \\    const context = struct {
    \\        title: []const u8,
    \\        message: []const u8,
    \\    }{
    \\        .title = "Welcome to {PROJECT_NAME}",
    \\        .message = "This is a sample Engine12 application",
    \\    };
    \\
    \\    const html = template.render(@TypeOf(context), context, allocator) catch {
    \\        return Response.text("Template rendering failed").withStatus(500);
    \\    };
    \\
    \\    return Response.html(html);
    \\}
;

/// Scaffold a new engine12 project
pub fn scaffoldProject(
    allocator: std.mem.Allocator,
    project_name: []const u8,
    base_path: []const u8,
) !void {
    _ = base_path; // We use cwd() directly instead
    // Validate project name
    if (!cli_utils.validateProjectName(project_name)) {
        std.debug.print("Error: Project name must contain only alphanumeric characters, hyphens, and underscores\n", .{});
        return error.InvalidProjectName;
    }

    // Create project directory (variable removed as it's no longer used directly)

    std.fs.cwd().makeDir(project_name) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("Error: Directory '{s}' already exists\n", .{project_name});
            return error.DirectoryExists;
        }
        return err;
    };

    // Create directory structure
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_name});
    std.fs.cwd().makeDir(src_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Create subdirectories for recommended structure
    const handlers_path = try std.fmt.allocPrint(allocator, "{s}/src/handlers", .{project_name});
    std.fs.cwd().makeDir(handlers_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const migrations_path = try std.fmt.allocPrint(allocator, "{s}/src/migrations", .{project_name});
    std.fs.cwd().makeDir(migrations_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const static_path = try std.fmt.allocPrint(allocator, "{s}/static", .{project_name});
    std.fs.cwd().makeDir(static_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const static_css_path = try std.fmt.allocPrint(allocator, "{s}/static/css", .{project_name});
    std.fs.cwd().makeDir(static_css_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const static_js_path = try std.fmt.allocPrint(allocator, "{s}/static/js", .{project_name});
    std.fs.cwd().makeDir(static_js_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const templates_path = try std.fmt.allocPrint(allocator, "{s}/src/templates", .{project_name});
    std.fs.cwd().makeDir(templates_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Change to project directory for zig fetch
    const original_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");

    std.posix.chdir(project_name) catch |err| {
        std.debug.print("Error: Failed to change to project directory: {}\n", .{err});
        return err;
    };

    // Fetch engine12 hash (we're already in the project directory)
    std.debug.print("Fetching engine12 dependency...\n", .{});
    const engine12_hash: []const u8 = cli_utils.fetchEngine12Hash(allocator, ".") catch |err| {
        // Cleanup on failure - change directory back and delete project
        std.posix.chdir(original_cwd) catch {};
        // Try to clean up the project directory using a fixed buffer
        var cleanup_path_buf: [512]u8 = undefined;
        const abs_project_path = std.fmt.bufPrint(&cleanup_path_buf, "{s}/{s}", .{ original_cwd, project_name }) catch |fmt_err| {
            std.debug.print("Error: Failed to fetch engine12 dependency: {}\n", .{err});
            std.debug.print("Warning: Could not construct cleanup path: {}\n", .{fmt_err});
            // Exit immediately to avoid allocator cleanup panics
            std.process.exit(1);
        };
        std.fs.cwd().deleteTree(abs_project_path) catch {};
        std.debug.print("Error: Failed to fetch Engine12 dependency: {}\n", .{err});
        // Exit immediately to avoid allocator cleanup panics
        std.process.exit(1);
    };

    // Process templates and write files (we're already in the project directory)
    // Note: build.zig.zon is generated by zig fetch, not templated
    const files = [_]struct { []const u8, []const u8 }{
        .{ "build.zig", BUILD_ZIG_TEMPLATE },
        .{ "src/main.zig", MAIN_ZIG_RECOMMENDED_TEMPLATE },
        .{ "src/models.zig", MODELS_ZIG_TEMPLATE },
        .{ "src/database.zig", DATABASE_ZIG_TEMPLATE },
        .{ "src/validators.zig", VALIDATORS_ZIG_TEMPLATE },
        .{ "src/auth.zig", AUTH_ZIG_TEMPLATE },
        .{ "src/utils.zig", UTILS_ZIG_TEMPLATE },
        .{ "src/handlers/search.zig", HANDLER_SEARCH_ZIG_TEMPLATE },
        .{ "src/migrations/init.zig", MIGRATIONS_INIT_ZIG_TEMPLATE },
        .{ "static/css/style.css", STATIC_CSS_TEMPLATE },
        .{ "static/js/app.js", STATIC_JS_TEMPLATE },
        .{ "src/templates/index.zt.html", TEMPLATE_INDEX_ZT_HTML },
        .{ "README.md", README_TEMPLATE },
        .{ ".gitignore", GITIGNORE_TEMPLATE },
    };

    for (files) |file_info| {
        const processed = try cli_utils.processTemplate(allocator, file_info[1], project_name, engine12_hash);
        // Note: processed is allocated with page_allocator, so we don't free it
        try cli_utils.writeFile(allocator, ".", file_info[0], processed);
    }

    // Change back to original directory (defer will handle this, but explicit is clearer)
    std.posix.chdir(original_cwd) catch {};

    std.debug.print("Created project '{s}' successfully!\n", .{project_name});
    std.debug.print("Next steps:\n", .{});
    std.debug.print("  cd {s}\n", .{project_name});
    std.debug.print("  zig build run\n", .{});

    // Exit immediately to avoid allocator cleanup issues
    std.process.exit(0);
}
