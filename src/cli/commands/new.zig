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
    \\    // Use Engine12 dependency (will use local path if specified in build.zig.zon)
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
    \\pub const ItemInput = struct {
    \\    title: ?[]const u8,
    \\    description: ?[]const u8,
    \\};
    \\
    \\pub const ItemModel = E12.orm.Model(Item);
    \\pub const ItemModelORM = E12.orm.ModelWithORM(Item);
;

/// Template for database.zig
const DATABASE_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\const E12 = @import("engine12");
    \\const Database = E12.orm.Database;
    \\const ORM = E12.orm.ORM;
    \\const Migration = E12.orm.MigrationType;
    \\
    \\const allocator = std.heap.page_allocator;
    \\
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
    \\        return;
    \\    }
    \\
    \\    const db_path = "app.db";
    \\    global_db = try Database.open(db_path, allocator);
    \\
    \\    global_orm = ORM.init(global_db.?, allocator);
    \\
    \\    const migrations = @import("migrations/init.zig").migrations;
    \\    try global_orm.?.runMigrations(&migrations);
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
    \\    if (item.title.len == 0) {
    \\        try errors.add("title", "Title is required", "required");
    \\    }
    \\    if (item.title.len > 200) {
    \\        try errors.add("title", "Title must be less than 200 characters", "max_length");
    \\    }
    \\
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
;

/// Template for handlers/search.zig
const HANDLER_SEARCH_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\const E12 = @import("engine12");
    \\const Request = E12.Request;
    \\const Response = E12.Response;
    \\const HandlerCtx = E12.HandlerCtx;
    \\const models = @import("../models.zig");
    \\
    \\/// Example search handler using HandlerCtx
    \\pub fn handleSearch(request: *Request) Response {
    \\    var ctx = HandlerCtx.init(request, .{
    \\        .require_auth = true,
    \\        .require_orm = true,
    \\        .get_orm = null,
    \\    }) catch |err| {
    \\        return switch (err) {
    \\            error.AuthenticationRequired => Response.errorResponse("Authentication required", 401),
    \\            error.DatabaseNotInitialized => Response.serverError("Database not initialized"),
    \\            else => Response.serverError("Internal error"),
    \\        };
    \\    };
    \\
    \\    _ = ctx.query([]const u8, "q") catch {
    \\        return ctx.badRequest("Missing query parameter 'q'");
    \\    };
    \\
    \\    return Response.json("{{\"results\":[]}}");
    \\}
;

/// Template for migrations/init.zig
const MIGRATIONS_INIT_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\const E12 = @import("engine12");
    \\const Migration = E12.orm.MigrationType;
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
    \\/* Modern, elegant stylesheet */
    \\:root {
    \\    --primary-color: #6366f1;
    \\    --primary-hover: #4f46e5;
    \\    --secondary-color: #1e293b;
    \\    --text-color: #334155;
    \\    --text-light: #64748b;
    \\    --bg-gradient-start: #f8fafc;
    \\    --bg-gradient-end: #e2e8f0;
    \\    --card-bg: #ffffff;
    \\    --shadow-sm: 0 1px 2px 0 rgb(0 0 0 / 0.05);
    \\    --shadow-md: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1);
    \\    --shadow-lg: 0 10px 15px -3px rgb(0 0 0 / 0.1), 0 4px 6px -4px rgb(0 0 0 / 0.1);
    \\}
    \\
    \\* {
    \\    box-sizing: border-box;
    \\}
    \\
    \\body {
    \\    font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    \\    margin: 0;
    \\    padding: 0;
    \\    background: linear-gradient(135deg, var(--bg-gradient-start) 0%, var(--bg-gradient-end) 100%);
    \\    min-height: 100vh;
    \\    color: var(--text-color);
    \\    line-height: 1.6;
    \\    display: flex;
    \\    align-items: center;
    \\    justify-content: center;
    \\}
    \\
    \\.container {
    \\    max-width: 1200px;
    \\    width: 95%;
    \\    margin: 2rem auto;
    \\    background: var(--card-bg);
    \\    border-radius: 24px;
    \\    box-shadow: var(--shadow-lg);
    \\    overflow: hidden;
    \\    opacity: 0;
    \\    transform: translateY(20px);
    \\    animation: fadeInUp 0.8s cubic-bezier(0.2, 0.8, 0.2, 1) forwards;
    \\}
    \\
    \\.hero {
    \\    padding: 4rem 2rem;
    \\    text-align: center;
    \\    background: linear-gradient(to bottom, #ffffff, #f8fafc);
    \\    border-bottom: 1px solid #e2e8f0;
    \\}
    \\
    \\.logo {
    \\    font-size: 4rem;
    \\    color: var(--primary-color);
    \\    margin-bottom: 1.5rem;
    \\    display: inline-block;
    \\    animation: float 6s ease-in-out infinite;
    \\}
    \\
    \\.hero h1 {
    \\    font-size: 3rem;
    \\    font-weight: 800;
    \\    margin: 0 0 1rem 0;
    \\    background: linear-gradient(135deg, #6366f1 0%, #8b5cf6 100%);
    \\    -webkit-background-clip: text;
    \\    -webkit-text-fill-color: transparent;
    \\    background-clip: text;
    \\    letter-spacing: -0.02em;
    \\}
    \\
    \\.subtitle {
    \\    font-size: 1.25rem;
    \\    color: var(--text-light);
    \\    margin: 0 auto 2.5rem auto;
    \\    max-width: 600px;
    \\}
    \\
    \\.cta-buttons {
    \\    display: flex;
    \\    gap: 1rem;
    \\    justify-content: center;
    \\}
    \\
    \\.btn {
    \\    display: inline-flex;
    \\    align-items: center;
    \\    justify-content: center;
    \\    padding: 0.75rem 1.5rem;
    \\    font-weight: 600;
    \\    border-radius: 12px;
    \\    text-decoration: none;
    \\    transition: all 0.2s ease;
    \\    gap: 0.5rem;
    \\}
    \\
    \\.btn-primary {
    \\    background: var(--primary-color);
    \\    color: white;
    \\    box-shadow: 0 4px 6px -1px rgba(99, 102, 241, 0.3);
    \\}
    \\
    \\.btn-primary:hover {
    \\    background: var(--primary-hover);
    \\    transform: translateY(-2px);
    \\    box-shadow: 0 6px 8px -1px rgba(99, 102, 241, 0.4);
    \\}
    \\
    \\.btn-secondary {
    \\    background: white;
    \\    color: var(--text-color);
    \\    border: 1px solid #e2e8f0;
    \\}
    \\
    \\.btn-secondary:hover {
    \\    background: #f8fafc;
    \\    border-color: #cbd5e1;
    \\    transform: translateY(-2px);
    \\}
    \\
    \\.features {
    \\    display: grid;
    \\    grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
    \\    gap: 2rem;
    \\    padding: 4rem 2rem;
    \\    background: #ffffff;
    \\}
    \\
    \\.feature-card {
    \\    padding: 2rem;
    \\    border-radius: 16px;
    \\    background: #f8fafc;
    \\    border: 1px solid #f1f5f9;
    \\    transition: all 0.3s ease;
    \\    text-align: center;
    \\}
    \\
    \\.feature-card:hover {
    \\    transform: translateY(-5px);
    \\    box-shadow: var(--shadow-md);
    \\    background: white;
    \\    border-color: #e2e8f0;
    \\}
    \\
    \\.icon-wrapper {
    \\    width: 64px;
    \\    height: 64px;
    \\    background: white;
    \\    border-radius: 16px;
    \\    display: flex;
    \\    align-items: center;
    \\    justify-content: center;
    \\    margin: 0 auto 1.5rem auto;
    \\    font-size: 1.75rem;
    \\    color: var(--primary-color);
    \\    box-shadow: var(--shadow-sm);
    \\}
    \\
    \\.feature-card h3 {
    \\    font-size: 1.25rem;
    \\    font-weight: 700;
    \\    margin: 0 0 0.75rem 0;
    \\    color: var(--secondary-color);
    \\}
    \\
    \\.feature-card p {
    \\    font-size: 0.95rem;
    \\    color: var(--text-light);
    \\    margin: 0;
    \\}
    \\
    \\footer {
    \\    text-align: center;
    \\    padding: 2rem;
    \\    background: #f8fafc;
    \\    border-top: 1px solid #e2e8f0;
    \\    font-size: 0.9rem;
    \\    color: var(--text-light);
    \\}
    \\
    \\footer a {
    \\    color: var(--primary-color);
    \\    text-decoration: none;
    \\    font-weight: 500;
    \\}
    \\
    \\footer a:hover {
    \\    text-decoration: underline;
    \\}
    \\
    \\@keyframes fadeInUp {
    \\    to {
    \\        opacity: 1;
    \\        transform: translateY(0);
    \\    }
    \\}
    \\
    \\@keyframes float {
    \\    0%, 100% { transform: translateY(0); }
    \\    50% { transform: translateY(-10px); }
    \\}
    \\
    \\@media (max-width: 768px) {
    \\    .hero h1 { font-size: 2.25rem; }
    \\    .features { grid-template-columns: 1fr; padding: 2rem; }
    \\    .container { width: 95%; margin: 1rem auto; }
    \\}
;

/// Template for static/js/app.js
const STATIC_JS_TEMPLATE =
    \\// Main application JavaScript
    \\document.addEventListener('DOMContentLoaded', function() {
    \\console.log('Engine12 application loaded');
    \\    
    \\    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
    \\        const href = anchor.getAttribute('href');
    \\        if (href === '#') return;
    \\        
    \\        anchor.addEventListener('click', function (e) {
    \\            e.preventDefault();
    \\            const target = document.querySelector(href);
    \\            if (target) {
    \\                target.scrollIntoView({
    \\                    behavior: 'smooth'
    \\                });
    \\            }
    \\        });
    \\    });
    \\
    \\    const cards = document.querySelectorAll('.feature-card');
    \\    cards.forEach(card => {
    \\        card.addEventListener('mouseenter', () => {
    \\            const icon = card.querySelector('.icon-wrapper');
    \\            if (icon) {
    \\                icon.style.transform = 'scale(1.1) rotate(5deg)';
    \\                icon.style.transition = 'transform 0.3s cubic-bezier(0.34, 1.56, 0.64, 1)';
    \\            }
    \\        });
    \\        
    \\        card.addEventListener('mouseleave', () => {
    \\            const icon = card.querySelector('.icon-wrapper');
    \\            if (icon) {
    \\                icon.style.transform = 'scale(1) rotate(0deg)';
    \\            }
    \\        });
    \\    });
    \\});
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
    \\    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css">
    \\</head>
    \\<body>
    \\    <div class="container">
    \\        <div class="hero">
    \\            <div class="logo">
    \\                <i class="fas fa-cubes"></i>
    \\            </div>
    \\            <h1>{{ .title }}</h1>
    \\            <p class="subtitle">{{ .message }}</p>
    \\            <div class="cta-buttons">
    \\                <a href="https://github.com/ooyeku/Engine12" class="btn btn-primary"><i class="fab fa-github"></i> GitHub</a>
    \\            </div>
    \\        </div>
    \\        
    \\        <div class="features">
    \\            <div class="feature-card">
    \\                <div class="icon-wrapper">
    \\                    <i class="fas fa-bolt"></i>
    \\                </div>
    \\                <h3>Blazing Fast</h3>
    \\                <p>Built with Zig for maximum performance and minimal resource usage.</p>
    \\            </div>
    \\            <div class="feature-card">
    \\                <div class="icon-wrapper">
    \\                    <i class="fas fa-shield-alt"></i>
    \\                </div>
    \\                <h3>Type Safe</h3>
    \\                <p>Leverage Zig's powerful type system to catch errors at compile time.</p>
    \\            </div>
    \\            <div class="feature-card">
    \\                <div class="icon-wrapper">
    \\                    <i class="fas fa-puzzle-piece"></i>
    \\                </div>
    \\                <h3>Modular</h3>
    \\                <p>Flexible architecture that scales from simple apps to complex systems.</p>
    \\            </div>
    \\        </div>
    \\
    \\        <footer>
    \\            <p>Powered by <strong>Engine12</strong> &bull; <a href="/api/items/search?q=test">Test API</a></p>
    \\        </footer>
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
    \\fn handleIndex(req: *Request) Response {
    \\    _ = req;
    \\    // Read and render template
    \\    const template_file = std.fs.cwd().openFile("src/templates/index.zt.html", .{}) catch {
    \\        return Response.text("Template not found").withStatus(404);
    \\    };
    \\    defer template_file.close();
    \\
    \\    const template_content = template_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
    \\        return Response.text("Template too large").withStatus(500);
    \\    };
    \\    defer allocator.free(template_content);
    \\
    \\    // Simple template variable replacement
    \\    const title = "Welcome to {PROJECT_NAME}";
    \\    const message = "This is a sample Engine12 application";
    \\    
    \\    // Use ArrayList to build the result dynamically
    \\    var result = std.ArrayList(u8).initCapacity(allocator, template_content.len * 2) catch {
    \\        return Response.text("Template rendering error").withStatus(500);
    \\    };
    \\    defer result.deinit(allocator);
    \\    
    \\    var i: usize = 0;
    \\    while (i < template_content.len) {
    \\        // Check for {{ .title }} (with spaces) - 12 characters: {{ .title }}
    \\        if (i + 12 <= template_content.len and std.mem.eql(u8, template_content[i..i+12], "{{ .title }}")) {
    \\            result.appendSlice(allocator, title) catch {
    \\                return Response.text("Template rendering error").withStatus(500);
    \\            };
    \\            i += 12;
    \\        }
    \\        // Check for {{.title }} (space after dot) - 12 characters: {{.title }}
    \\        else if (i + 12 <= template_content.len and std.mem.eql(u8, template_content[i..i+12], "{{.title }}")) {
    \\            result.appendSlice(allocator, title) catch {
    \\                return Response.text("Template rendering error").withStatus(500);
    \\            };
    \\            i += 12;
    \\        }
    \\        // Check for {{.title}} (no spaces) - 10 characters: {{.title}}
    \\        else if (i + 10 <= template_content.len and std.mem.eql(u8, template_content[i..i+10], "{{.title}}")) {
    \\            result.appendSlice(allocator, title) catch {
    \\                return Response.text("Template rendering error").withStatus(500);
    \\            };
    \\            i += 10;
    \\        }
    \\        // Check for {{ .message }} (with spaces) - 14 characters: {{ .message }}
    \\        else if (i + 14 <= template_content.len and std.mem.eql(u8, template_content[i..i+14], "{{ .message }}")) {
    \\            result.appendSlice(allocator, message) catch {
    \\                return Response.text("Template rendering error").withStatus(500);
    \\            };
    \\            i += 14;
    \\        }
    \\        // Check for {{.message }} (space after dot) - 13 characters: {{.message }}
    \\        else if (i + 13 <= template_content.len and std.mem.eql(u8, template_content[i..i+13], "{{.message }}")) {
    \\            result.appendSlice(allocator, message) catch {
    \\                return Response.text("Template rendering error").withStatus(500);
    \\            };
    \\            i += 13;
    \\        }
    \\        // Check for {{.message}} (no spaces) - 12 characters: {{.message}}
    \\        else if (i + 12 <= template_content.len and std.mem.eql(u8, template_content[i..i+12], "{{.message}}")) {
    \\            result.appendSlice(allocator, message) catch {
    \\                return Response.text("Template rendering error").withStatus(500);
    \\            };
    \\            i += 12;
    \\        }
    \\        // Copy character as-is
    \\        else {
    \\            result.append(allocator, template_content[i]) catch {
    \\                return Response.text("Template rendering error").withStatus(500);
    \\            };
    \\            i += 1;
    \\        }
    \\    }
    \\    
    \\    const rendered = result.toOwnedSlice(allocator) catch {
    \\        return Response.text("Template rendering error").withStatus(500);
    \\    };
    \\    
    \\    return Response.html(rendered);
    \\}
    \\
    \\pub fn main() !void {
    \\    var app = try E12.Engine12.initDevelopment();
    \\    defer app.deinit();
    \\
    \\    try app.initDatabaseWithMigrations("app.db", "src/migrations");
    \\
    \\    // Register routes before static files to ensure they take precedence
    \\    try app.get("/", handleIndex);
    \\
    \\    try app.serveStaticDirectory("static");
    \\
    \\    try app.get("/api/items/search", handlers.search.handleSearch);
    \\
    \\    // REST API example - uncomment when ready
    \\    // const orm = try app.getORM();
    \\    // try app.restApi("/api/items", Item, .{
    \\    //     .orm = orm,
    \\    //     .validator = validators.validateItem,
    \\    //     .authenticator = auth.requireAuthForRestApi,
    \\    //     .authorization = auth.canAccessItem,
    \\    //     .enable_pagination = true,
    \\    //     .enable_filtering = true,
    \\    //     .enable_sorting = true,
    \\    // });
    \\
    \\    std.debug.print("Server starting on http://127.0.0.1:8080\n", .{});
    \\    std.debug.print("Press Ctrl+C to stop\n", .{});
    \\    try app.start();
    \\
    \\    while (true) {}
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
    const original_cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch |err| {
        std.debug.print("Error: Failed to get current directory: {}\n", .{err});
        // Cleanup project directory
        var cleanup_path_buf: [512]u8 = undefined;
        const abs_project_path = std.fmt.bufPrint(&cleanup_path_buf, "./{s}", .{project_name}) catch {
            std.process.exit(1);
        };
        std.fs.cwd().deleteTree(abs_project_path) catch {};
        return err;
    };

    std.posix.chdir(project_name) catch |err| {
        std.debug.print("Error: Failed to change to project directory '{s}': {}\n", .{ project_name, err });
        // Cleanup project directory
        var cleanup_path_buf: [512]u8 = undefined;
        const abs_project_path = std.fmt.bufPrint(&cleanup_path_buf, "{s}/{s}", .{ original_cwd, project_name }) catch {
            std.process.exit(1);
        };
        std.fs.cwd().deleteTree(abs_project_path) catch {};
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

    // Write all template files with error handling
    for (files) |file_info| {
        const processed = cli_utils.processTemplate(allocator, file_info[1], project_name, engine12_hash) catch |err| {
            std.debug.print("Error: Failed to process template for '{s}': {}\n", .{ file_info[0], err });
            // Cleanup on failure
            std.posix.chdir(original_cwd) catch {};
            var cleanup_path_buf: [512]u8 = undefined;
            const abs_project_path = std.fmt.bufPrint(&cleanup_path_buf, "{s}/{s}", .{ original_cwd, project_name }) catch {
                std.process.exit(1);
            };
            std.fs.cwd().deleteTree(abs_project_path) catch {};
            std.process.exit(1);
        };
        // Note: processed is allocated with page_allocator, so we don't free it

        cli_utils.writeFile(allocator, ".", file_info[0], processed) catch |err| {
            std.debug.print("Error: Failed to write file '{s}': {}\n", .{ file_info[0], err });
            // Cleanup on failure
            std.posix.chdir(original_cwd) catch {};
            var cleanup_path_buf: [512]u8 = undefined;
            const abs_project_path = std.fmt.bufPrint(&cleanup_path_buf, "{s}/{s}", .{ original_cwd, project_name }) catch {
                std.process.exit(1);
            };
            std.fs.cwd().deleteTree(abs_project_path) catch {};
            std.process.exit(1);
        };
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
