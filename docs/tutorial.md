# Tutorial: Building Your First Engine12 App

This tutorial will guide you through building a complete web application with Engine12, step by step.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Step 1: Setup Project](#step-1-setup-project)
  - [1.1 Create Project Structure](#11-create-project-structure)
  - [1.2 Initialize Build Files](#12-initialize-build-files)
  - [1.3 Create Source Directory](#13-create-source-directory)
- [Step 2: Basic Server](#step-2-basic-server)
- [Step 3: Add Routes](#step-3-add-routes)
  - [3.1 Update main.zig](#31-update-mainzig)
- [Step 4: Database Integration](#step-4-database-integration)
  - [4.1 Create Database Module](#41-create-database-module)
  - [4.2 Define Todo Model](#42-define-todo-model)
  - [4.3 Update Handlers](#43-update-handlers)
  - [4.4 Initialize Database](#44-initialize-database)
- [Step 5: Templates](#step-5-templates)
  - [5.1 Create Template File](#51-create-template-file)
  - [5.2 Render Template](#52-render-template)
- [Step 5.5: Hot Reloading (Development Mode)](#step-55-hot-reloading-development-mode)
  - [Using Runtime Templates](#using-runtime-templates)
  - [Static File Hot Reloading](#static-file-hot-reloading)
  - [When to Use Hot Reloading](#when-to-use-hot-reloading)
- [Step 6: Middleware](#step-6-middleware)
  - [6.1 Structured Logging](#61-structured-logging)
  - [6.2 Authentication Middleware](#62-authentication-middleware)
  - [6.3 CORS Middleware](#63-cors-middleware)
  - [6.4 Request ID Middleware](#64-request-id-middleware)
- [Step 7: Deploy](#step-7-deploy)
  - [7.1 Build for Production](#71-build-for-production)
  - [7.2 Run Server](#72-run-server)
  - [7.3 Production Considerations](#73-production-considerations)
- [Step 8: OpenAPI Documentation](#step-8-openapi-documentation)
  - [8.1 Enable OpenAPI Documentation](#81-enable-openapi-documentation)
  - [8.2 Accessing the Documentation](#82-accessing-the-documentation)
  - [8.3 Automatic Documentation](#83-automatic-documentation)
  - [8.4 Testing with Swagger UI](#84-testing-with-swagger-ui)
- [Step 9: Advanced Features](#step-9-advanced-features)
  - [9.1 Type-Safe Parameter Parsing](#91-type-safe-parameter-parsing)
  - [9.2 Pagination Helper](#92-pagination-helper)
  - [9.3 Error Response Helpers](#93-error-response-helpers)
  - [9.4 JSON Serialization](#94-json-serialization)
- [Step 10: Using Valves](#step-10-using-valves)
  - [10.1 Creating a Simple Valve](#101-creating-a-simple-valve)
  - [10.2 Registering a Valve](#102-registering-a-valve)
  - [10.3 Creating a Valve with Routes](#103-creating-a-valve-with-routes)
  - [10.4 Using Multiple Capabilities](#104-using-multiple-capabilities)
  - [10.5 Using Builtin Valves](#105-using-builtin-valves)
  - [10.6 BasicAuthValve Example](#106-basicauthvalve-example)
  - [10.7 Best Practices](#107-best-practices)
- [Step 11: Using HandlerCtx](#step-11-using-handlerctx)
  - [11.1 Introduction to HandlerCtx](#111-introduction-to-handlerctx)
  - [11.2 Basic Usage](#112-basic-usage)
  - [11.3 Authentication Handling](#113-authentication-handling)
  - [11.4 Parameter Parsing](#114-parameter-parsing)
  - [11.5 Caching with HandlerCtx](#115-caching-with-handlerctx)
  - [11.6 Before and After Comparison](#116-before-and-after-comparison)
  - [10.5 Lifecycle Hooks](#105-lifecycle-hooks)
  - [10.6 Using Builtin Valves](#106-using-builtin-valves)
  - [10.7 Best Practices](#107-best-practices)
- [Next Steps](#next-steps)

## Prerequisites

- Zig 0.15.1 or later
- Basic understanding of Zig syntax
- A text editor or IDE

## Step 1: Setup Project

### 1.1 Create Project Structure

Create a new directory for your project:

```bash
mkdir myapp
cd myapp
```

### 1.2 Initialize Build Files

Create `build.zig.zon`:

```zig
.{
    .name = .myapp,
    .version = "0.1.0",
    .dependencies = .{
        .Engine12 = .{
            .url = "git+https://github.com/yourusername/Engine12.git",
            .hash = "...", // Run `zig build` to get the hash
        },
    },
}
```

Create `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const Engine12 = b.dependency("Engine12", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.addModule("Engine12", Engine12.module("Engine12"));
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
```

### 1.3 Create Source Directory

```bash
mkdir src
```

## Step 2: Basic Server

Create `src/main.zig`:

```zig
const std = @import("std");
const Engine12 = @import("Engine12");
const Request = Engine12.Request;
const Response = Engine12.Response;

fn handleRoot(req: *Request) Response {
    _ = req;
    return Response.text("Hello, World!");
}

pub fn main() !void {
    var app = try Engine12.initDevelopment();
    defer app.deinit();

    try app.get("/", handleRoot);
    try app.start();

    // Keep server running
    std.Thread.sleep(std.time.ns_per_min * 60);
}
```

Build and run:

```bash
zig build run
```

Visit `http://127.0.0.1:8080` in your browser. You should see "Hello, World!".

## Step 3: Add Routes

Let's add more routes for a simple todo API.

### 3.1 Update main.zig

```zig
const std = @import("std");
const Engine12 = @import("Engine12");
const Request = Engine12.Request;
const Response = Engine12.Response;

var todos = std.ArrayListUnmanaged([]const u8){};

fn handleRoot(req: *Request) Response {
    _ = req;
    return Response.text("Todo API");
}

fn handleGetTodos(req: *Request) Response {
    _ = req;
    var json = std.ArrayListUnmanaged(u8){};
    defer json.deinit(std.heap.page_allocator);

    json.writer(std.heap.page_allocator).print("[", .{}) catch return Response.status(500);
    for (todos.items, 0..) |todo, i| {
        if (i > 0) {
            json.writer(std.heap.page_allocator).print(",", .{}) catch return Response.status(500);
        }
        json.writer(std.heap.page_allocator).print("\"{s}\"", .{todo}) catch return Response.status(500);
    }
    json.writer(std.heap.page_allocator).print("]", .{}) catch return Response.status(500);

    return Response.json(json.items);
}

fn handleCreateTodo(req: *Request) Response {
    const TodoInput = struct {
        title: []const u8,
    };
    
    const input = req.jsonBody(TodoInput) catch {
        return Response.errorResponse("Invalid JSON", 400);
    };
    
    // In production, add to database
    todos.append(std.heap.page_allocator, input.title) catch {
        return Response.serverError("Failed to create todo");
    };
    
    return Response.created().withJson("{\"id\": 1}");
}

fn handleGetTodo(req: *Request) Response {
    const id = req.paramTyped(i64, "id") catch {
        return Response.errorResponse("Invalid ID", 400);
    };
    _ = id;
    return Response.json("{\"id\": 1, \"title\": \"Sample Todo\"}");
}

fn handleDeleteTodo(req: *Request) Response {
    const id = req.paramTyped(i64, "id") catch {
        return Response.errorResponse("Invalid ID", 400);
    };
    _ = id;
    return Response.noContent();
}

pub fn main() !void {
    var app = try Engine12.initDevelopment();
    defer app.deinit();

    try app.get("/", handleRoot);
    try app.get("/todos", handleGetTodos);
    try app.post("/todos", handleCreateTodo);
    try app.get("/todos/:id", handleGetTodo);
    try app.delete("/todos/:id", handleDeleteTodo);

    try app.start();
    app.printStatus();

    // Keep server running
    std.Thread.sleep(std.time.ns_per_min * 60);
}
```

Test the routes:

```bash
curl http://127.0.0.1:8080/todos
curl -X POST http://127.0.0.1:8080/todos -d '{"title":"Learn Zig"}'
curl http://127.0.0.1:8080/todos/1
curl -X DELETE http://127.0.0.1:8080/todos/1
```

## Step 4: Database Integration

Now let's add persistent storage with SQLite.

**Note**: The ORM maps columns to struct fields by name, not by position. This means column order in your queries doesn't need to match struct field order - the ORM will automatically match columns by name.

### 4.1 Create Database Module

Create `src/database.zig`:

```zig
const std = @import("std");
const Engine12 = @import("Engine12");
const Database = Engine12.orm.Database;
const ORM = Engine12.orm.ORM;

var global_db: ?Database = null;
var global_orm: ?*ORM = null;

pub fn init() !void {
    global_db = try Database.open("todos.db", std.heap.page_allocator);
    global_orm = try ORM.initPtr(global_db.?, std.heap.page_allocator);

    // Create table
    try global_db.?.execute(
        \\CREATE TABLE IF NOT EXISTS todos (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  title TEXT NOT NULL,
        \\  completed INTEGER NOT NULL DEFAULT 0,
        \\  created_at INTEGER NOT NULL
        \\)
    );
}

pub fn getORM() !*ORM {
    if (global_orm) |orm| {
        return orm;
    }
    return error.DatabaseNotInitialized;
}

pub fn deinit() void {
    if (global_orm) |orm| {
        orm.deinitPtr(std.heap.page_allocator);
    }
    if (global_db) |*db| {
        db.close();
    }
}
```

### 4.2 Define Todo Model

Add to `src/main.zig`:

```zig
const TodoStatus = enum {
    pending,
    in_progress,
    completed,
};

const Todo = struct {
    id: i64,
    title: []u8,
    description: ?[]u8 = null, // Optional field
    completed: bool,
    status: TodoStatus = .pending, // Enum field
    created_at: i64,
    updated_at: i64,
};
```

**Note**: The ORM supports:
- **Enum types**: Automatically converted to integers when saving
- **Optional fields**: Null values are skipped in INSERT/UPDATE operations

### 4.3 Update Handlers

```zig
fn handleGetTodos(req: *Request) Response {
    _ = req;
    const orm = database.getORM() catch {
        return Response.status(500).withJson("{\"error\":\"Database error\"}");
    };

    var todos_list = orm.findAll(Todo) catch |err| {
        // Enhanced error handling - error messages now include table name, SQL, and column info
        std.debug.print("Failed to fetch todos: {}\n", .{err});
        return Response.status(500).withJson("{\"error\":\"Failed to fetch todos\"}");
    };
    defer {
        for (todos_list.items) |todo| {
            std.heap.page_allocator.free(todo.title);
        }
        todos_list.deinit(std.heap.page_allocator);
    }

    // Build JSON response
    var json = std.ArrayListUnmanaged(u8){};
    defer json.deinit(std.heap.page_allocator);
    json.writer(std.heap.page_allocator).print("[", .{}) catch return Response.status(500);
    for (todos_list.items, 0..) |todo, i| {
        if (i > 0) json.writer(std.heap.page_allocator).print(",", .{}) catch return Response.status(500);
        json.writer(std.heap.page_allocator).print(
            "{{\"id\":{d},\"title\":\"{s}\",\"completed\":{}}},\"created_at\":{d}}}",
            .{ todo.id, todo.title, todo.completed, todo.created_at }
        ) catch return Response.status(500);
    }
    json.writer(std.heap.page_allocator).print("]", .{}) catch return Response.status(500);

    return Response.json(json.items);
}

fn handleCreateTodo(req: *Request) Response {
    const TodoInput = struct {
        title: []const u8,
    };

    const input = req.jsonBody(TodoInput) catch {
        return Response.badRequest().withJson("{\"error\":\"Invalid JSON\"}");
    };

    const orm = database.getORM() catch {
        return Response.status(500).withJson("{\"error\":\"Database error\"}");
    };

    const now = std.time.milliTimestamp();
    const title_copy = std.heap.page_allocator.dupe(u8, input.title) catch {
        return Response.status(500).withJson("{\"error\":\"Memory error\"}");
    };

    const todo = Todo{
        .id = 0,
        .title = title_copy,
        .completed = false,
        .created_at = now,
    };

    orm.create(Todo, todo) catch {
        std.heap.page_allocator.free(title_copy);
        return Response.status(500).withJson("{\"error\":\"Create failed\"}");
    };

    const id = orm.db.lastInsertRowId() catch 0;
    var json_buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&json_buf, "{{\"id\":{d}}}", .{id}) catch {
        return Response.status(500).withJson("{\"error\":\"Format error\"}");
    };

    return Response.created().withJson(json);
}
```

### 4.4 Initialize Database

Update `main()`:

```zig
pub fn main() !void {
    try database.init();
    defer database.deinit();

    var app = try Engine12.initDevelopment();
    defer app.deinit();

    // ... rest of code
}
```

## Step 5: Templates

Create HTML templates for rendering.

### 5.1 Create Template File

Create `src/templates/index.zt.html`:

```html
<!DOCTYPE html>
<html>
<head>
    <title>{{ .title }}</title>
</head>
<body>
    <h1>{{ .title }}</h1>
    <ul>
        {% for .todos |todo| %}
        <li>
            {{ .todo.title }}
            {% if .todo.completed %}✓{% endif %}
            <small>(Index: {{ .index }})</small>
        </li>
        {% endfor %}
    </ul>
</body>
</html>
```

### 5.2 Render Template

```zig
const templates = Engine12.templates;

fn handleIndex(req: *Request) Response {
    _ = req;
    const template_content = @embedFile("templates/index.zt.html");
    const IndexTemplate = templates.Template.compile(template_content);

    const Context = struct {
        title: []const u8,
        todos: []const Todo,
        page_info: struct {
            author: []const u8,
            version: []const u8,
        },
    };

    const context = Context{
        .title = "My Todos",
        .todos = &[_]Todo{}, // Load from database
        .page_info = .{
            .author = "Engine12",
            .version = "1.0.0",
        },
    };

    const html = IndexTemplate.render(Context, context, std.heap.page_allocator) catch {
        return Response.status(500).text("Template error");
    };
    defer std.heap.page_allocator.free(html);

    return Response.html(html);
}
```

**Template example with iteration and parent context:**

```html
<h1>{{ .title }}</h1>
<p>By {{ .page_info.author }} v{{ .page_info.version }}</p>
<ul>
{% for .todos |todo| %}
    <li>
        {{ .todo.title }}
        {% if .first %}<span>(First)</span>{% endif %}
        {% if .last %}<span>(Last)</span>{% endif %}
        <small>Index: {{ .index }}</small>
        <p>Page author: {{ ../page_info.author }}</p>
    </li>
{% endfor %}
</ul>
```

## Step 5.5: Hot Reloading (Development Mode)

In development mode, Engine12 automatically enables hot reloading for templates and static files. This means you can edit templates and static assets without restarting the server.

### Using Runtime Templates

Instead of using `@embedFile` for templates, you can use `loadTemplate()` for hot reloading:

```zig
const std = @import("std");
const E12 = @import("Engine12");

pub fn main() !void {
    var app = try E12.Engine12.initDevelopment();
    defer app.deinit();

    // Load template for hot reloading
    const template = try app.loadTemplate("templates/index.zt.html");

    try app.get("/", handleIndex);
    try app.start();
}

fn handleIndex(req: *E12.Request) E12.Response {
    _ = req;
    
    // Get template content (automatically reloads if changed)
    const template_content = template.getContentString() catch {
        return E12.Response.text("Template error").withStatus(500);
    };
    
    // Use template content with Template.compile() or runtime engine
    // For production, use comptime templates for type safety
    const TemplateType = E12.templates.Template.compile(template_content);
    const html = TemplateType.render(IndexContext, context, allocator) catch {
        return E12.Response.text("Render error").withStatus(500);
    };
    
    return E12.Response.html(html);
}
```

### Static File Hot Reloading

Static files are automatically served without cache headers in development mode:

```zig
// In development mode, cache is automatically disabled
try app.serveStatic("/", "./frontend");

// Changes to CSS, JS, or HTML files are immediately visible
// No need to hard refresh or clear browser cache
```

### When to Use Hot Reloading

- **Development**: Use `loadTemplate()` for rapid iteration during development
- **Production**: Use `@embedFile` with comptime templates for type safety and performance

**Note**: Hot reloading only works for templates and static files. Code changes still require server restart.

## Step 6: Middleware

Add logging and authentication middleware.

### 6.1 Structured Logging

Engine12 provides built-in structured logging with automatic request/response logging:

```zig
const std = @import("std");
const E12 = @import("engine12");

pub fn main() !void {
    var app = try E12.Engine12.initDevelopment();
    defer app.deinit();

    // Configure logger
    const logger = app.getLogger();
    logger.setFormat(.human); // Human-readable for development
    // For production, use JSON format:
    // logger.setFormat(.json);
    // try logger.setFileDestination("logs/app.log");

    // Enable automatic request/response logging
    // Exclude health check endpoints
    try app.enableRequestLogging(.{
        .exclude_paths = &[_][]const u8{ "/health", "/metrics" },
    });

    try app.get("/", handleRoot);
    try app.start();
}

// Store app reference globally or pass logger to handler
var global_app: ?*E12.Engine12 = null;

fn handleRoot(req: *E12.Request) E12.Response {
    // Custom logging in handlers
    if (global_app) |app| {
        const logger = app.getLogger();
        try logger.info("Root endpoint accessed")
            .field("ip", req.header("X-Real-IP") orelse "unknown")
            .log();
    }
    
    return E12.Response.text("Hello, World!");
}

// In main(), before starting:
global_app = &app;
```

#### Manual Logging

You can also log manually without middleware:

```zig
// Simple logging
try logger.info("Server started").log();

// Logging with fields
try logger.warn("High memory usage")
    .fieldInt("memory_mb", 1024)
    .fieldBool("is_critical", true)
    .log();

// Logging with request context
try logger.fromRequest(req, .info, "Request processed").log();

// Logging errors
try logger.logError("Database connection failed").log();
```

#### Multiple Log Destinations

Log to multiple destinations simultaneously:

```zig
const logger = app.getLogger();
try logger.addDestination(.stdout); // Console
try logger.setFileDestination("logs/app.log"); // File
try logger.setSyslogFacility(1); // Syslog (LOG_USER)
```

### 6.2 Authentication Middleware

```zig
fn authMiddleware(req: *Request) MiddlewareResult {
    if (req.header("Authorization")) |auth| {
        // Simple check - in production, validate token
        if (std.mem.eql(u8, auth, "Bearer secret-token")) {
            return .proceed;
        }
    }
    return .abort; // Returns 401 Unauthorized
}

// Apply to specific routes via route groups:
var api = app.group("/api");
api.usePreRequest(authMiddleware);
api.get("/todos", handleGetTodos);
```

### 6.3 CORS Middleware

Add CORS support for cross-origin requests:

```zig
const cors = cors_middleware.CorsMiddleware.init(.{
    .allowed_origins = &[_][]const u8{"http://localhost:3000"},
    .allowed_methods = &[_][]const u8{ "GET", "POST", "PUT", "DELETE" },
    .allowed_headers = &[_][]const u8{"Content-Type", "Authorization"},
    .max_age = 3600,
});

cors.setGlobalConfig();
const cors_mw_fn = cors.preflightMwFn();
try app.usePreRequest(cors_mw_fn);
```

### 6.4 Request ID Middleware

Add Request ID headers for tracing:

```zig
const req_id_mw = request_id_middleware.RequestIdMiddleware.init(.{});
const req_id_mw_fn = req_id_mw.preRequestMwFn();
try app.usePreRequest(req_id_mw_fn);
```

Request IDs are automatically added to response headers and can be accessed in handlers via `req.requestId()`.

## Step 7: Deploy

### 7.1 Build for Production

Update `build.zig` to add release build:

```zig
const release_exe = b.addExecutable(.{
    .name = "myapp",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = .ReleaseSafe, // Optimized build
});
```

Build:

```bash
zig build -Doptimize=ReleaseSafe
```

### 7.2 Run Server

```bash
./zig-out/bin/myapp
```

### 7.3 Production Considerations

- Set environment to production: `Engine12.initProduction()`
- Enable metrics: Already enabled in production profile
- Configure health checks
- Set up process management (systemd, supervisor, etc.)
- Configure logging
- Set up reverse proxy (nginx, etc.)

## Step 8: OpenAPI Documentation

Engine12 provides automatic OpenAPI 3.0 specification generation and Swagger UI integration. This makes it easy to document and test your API.

### 8.1 Enable OpenAPI Documentation

Add OpenAPI documentation to your app with a single line:

```zig
pub fn main() !void {
    var app = try Engine12.initDevelopment();
    defer app.deinit();

    // Enable OpenAPI documentation
    try app.enableOpenApiDocs("/docs", .{
        .title = "Todo API",
        .version = "1.0.0",
        .description = "A simple todo management API",
    });

    // Your routes...
    try app.get("/", handleRoot);
    try app.restApi("/api/todos", Todo, .{
        .orm = &my_orm,
        .validator = validateTodo,
    });

    try app.start();
}
```

### 8.2 Accessing the Documentation

After starting your server:

1. **Swagger UI**: Visit `http://127.0.0.1:8080/docs` to view the interactive API documentation
2. **OpenAPI JSON**: Visit `http://127.0.0.1:8080/docs/openapi.json` to get the raw OpenAPI specification

### 8.3 Automatic Documentation

When you use `restApi()`, all CRUD endpoints are automatically documented:

- Request/response schemas are generated from your model structs
- Query parameters (filter, sort, pagination) are documented
- Path parameters are documented
- Request body schemas are generated automatically

**Example**: If you have a `Todo` model, the OpenAPI spec will include:
- `GET /api/todos` - List todos with query parameters
- `GET /api/todos/{id}` - Get todo by ID
- `POST /api/todos` - Create todo with request body schema
- `PUT /api/todos/{id}` - Update todo with request body schema
- `DELETE /api/todos/{id}` - Delete todo

### 8.4 Testing with Swagger UI

The Swagger UI interface allows you to:
- Browse all available endpoints
- View request/response schemas
- Test API endpoints directly from the browser
- See example request/response payloads

This is especially useful during development for testing your API without writing separate test clients.

## Step 9: Advanced Features

### 9.1 Type-Safe Parameter Parsing

Use `paramTyped()` and `queryParamTyped()` for type-safe parameter parsing:

```zig
fn handleGetTodo(req: *Request) Response {
    // Type-safe route parameter
    const id = req.paramTyped(i64, "id") catch {
        return Response.errorResponse("Invalid ID", 400);
    };
    
    // Type-safe query parameters
    const include_completed = req.queryParamTyped(bool, "include_completed") catch false orelse false;
    const limit = req.queryParamTyped(u32, "limit") catch 20 orelse 20;
    
    // Use parameters...
}
```

### 9.2 Pagination Helper

Use the pagination helper for paginated endpoints:

```zig
fn handleGetTodos(req: *Request) Response {
    const pagination = Pagination.fromRequest(req) catch {
        return Response.errorResponse("Invalid pagination", 400);
    };
    
    // Fetch paginated results
    const todos = try fetchTodos(pagination.limit, pagination.offset);
    const total = try countTodos();
    
    // Generate metadata
    const meta = pagination.toResponse(total);
    
    // Return paginated response
    return Response.jsonFrom(PaginatedResponse, .{
        .data = todos,
        .meta = meta,
    }, req.allocator());
}
```

### 9.3 Error Response Helpers

Use standardized error response helpers:

```zig
// Custom error with status code
return Response.errorResponse("Invalid input", 400);

// Server error
return Response.serverError("Database connection failed");

// Validation error
const errors = try schema.validate();
if (!errors.isEmpty()) {
    return Response.validationError(&errors);
}

// Not found with message
return Response.notFound("Todo not found");
```

### 9.4 JSON Serialization

Use `jsonFrom()` to automatically serialize structs:

```zig
const todo = Todo{ .id = 1, .title = "Hello", .completed = false };
return Response.jsonFrom(Todo, todo, allocator);
```

## Step 10: Using Valves

Valves provide a secure and simple plugin architecture for Engine12. Each valve is an isolated service that integrates deeply with the Engine12 runtime through controlled capabilities.

### 10.1 Creating a Simple Valve

Let's create a logging valve that tracks API requests:

```zig
const std = @import("std");
const E12 = @import("Engine12");

const LoggingValve = struct {
    valve: E12.Valve,
    log_file: []const u8,

    pub fn init(log_file: []const u8) LoggingValve {
        return LoggingValve{
            .valve = E12.Valve{
                .metadata = E12.ValveMetadata{
                    .name = "logging",
                    .version = "1.0.0",
                    .description = "Request logging valve",
                    .author = "Your Name",
                    .required_capabilities = &[_]E12.ValveCapability{ .middleware },
                },
                .init = &LoggingValve.initValve,
                .deinit = &LoggingValve.deinitValve,
            },
            .log_file = log_file,
        };
    }

    pub fn initValve(v: *E12.Valve, ctx: *E12.ValveContext) !void {
        const self = @as(*LoggingValve, @ptrFromInt(@intFromPtr(v) - @offsetOf(LoggingValve, "valve")));
        
        // Register logging middleware
        try ctx.registerMiddleware(&LoggingValve.logMiddleware);
        
        _ = self;
    }

    pub fn deinitValve(v: *E12.Valve) void {
        _ = v;
        // Cleanup if needed
    }

    fn logMiddleware(req: *E12.Request) E12.middleware.MiddlewareResult {
        std.debug.print("[LOG] {s} {s}\n", .{ req.method(), req.path() });
        return .proceed;
    }
};
```

### 10.2 Registering a Valve

Register the valve with your Engine12 app:

```zig
pub fn main() !void {
    var app = try E12.Engine12.initDevelopment();
    defer app.deinit();

    // Register logging valve
    var logging_valve = LoggingValve.init("app.log");
    try app.registerValve(&logging_valve.valve);

    // Register your routes
    try app.get("/", handleRoot);

    try app.start();
}
```

### 10.3 Creating a Valve with Routes

Here's an example of a valve that registers its own routes:

```zig
const ApiValve = struct {
    valve: E12.Valve,

    pub fn init() ApiValve {
        return ApiValve{
            .valve = E12.Valve{
                .metadata = E12.ValveMetadata{
                    .name = "api",
                    .version = "1.0.0",
                    .description = "API routes valve",
                    .author = "Your Name",
                    .required_capabilities = &[_]E12.ValveCapability{ .routes },
                },
                .init = &ApiValve.initValve,
                .deinit = &ApiValve.deinitValve,
            },
        };
    }

    pub fn initValve(v: *E12.Valve, ctx: *E12.ValveContext) !void {
        // Register API routes
        try ctx.registerRoute("GET", "/api/status", ApiValve.handleStatus);
        try ctx.registerRoute("GET", "/api/version", ApiValve.handleVersion);
    }

    pub fn deinitValve(v: *E12.Valve) void {
        _ = v;
    }

    fn handleStatus(req: *E12.Request) E12.Response {
        _ = req;
        return E12.Response.json("{\"status\":\"ok\"}");
    }

    fn handleVersion(req: *E12.Request) E12.Response {
        _ = req;
        return E12.Response.json("{\"version\":\"1.0.0\"}");
    }
};
```

### 10.4 Using Multiple Capabilities

A valve can request multiple capabilities:

```zig
const FullFeatureValve = struct {
    valve: E12.Valve,

    pub fn init() FullFeatureValve {
        return FullFeatureValve{
            .valve = E12.Valve{
                .metadata = E12.ValveMetadata{
                    .name = "full_feature",
                    .version = "1.0.0",
                    .description = "Full-featured valve",
                    .author = "Your Name",
                    .required_capabilities = &[_]E12.ValveCapability{
                        .routes,
                        .middleware,
                        .background_tasks,
                        .health_checks,
                    },
                },
                .init = &FullFeatureValve.initValve,
                .deinit = &FullFeatureValve.deinitValve,
            },
        };
    }

    pub fn initValve(v: *E12.Valve, ctx: *E12.ValveContext) !void {
        // Register routes
        try ctx.registerRoute("GET", "/api/feature", FullFeatureValve.handleFeature);
        
        // Register middleware
        try ctx.registerMiddleware(&FullFeatureValve.featureMiddleware);
        
        // Register background task
        try ctx.registerTask("feature_cleanup", FullFeatureValve.cleanupTask, 60000);
        
        // Register health check
        try ctx.registerHealthCheck(&FullFeatureValve.healthCheck);
    }

    pub fn deinitValve(v: *E12.Valve) void {
        _ = v;
    }

    fn handleFeature(req: *E12.Request) E12.Response {
        _ = req;
        return E12.Response.json("{\"feature\":\"enabled\"}");
    }

    fn featureMiddleware(req: *E12.Request) E12.middleware.MiddlewareResult {
        _ = req;
        return .proceed;
    }

    fn cleanupTask() void {
        std.debug.print("[Feature] Running cleanup\n", .{});
    }

    fn healthCheck() E12.types.HealthStatus {
        return .healthy;
    }
};
```

### 10.5 Lifecycle Hooks

Valves can hook into app lifecycle events:

```zig
const LifecycleValve = struct {
    valve: E12.Valve,
    initialized: bool = false,

    pub fn init() LifecycleValve {
        return LifecycleValve{
            .valve = E12.Valve{
                .metadata = E12.ValveMetadata{
                    .name = "lifecycle",
                    .version = "1.0.0",
                    .description = "Lifecycle demo valve",
                    .author = "Your Name",
                    .required_capabilities = &[_]E12.ValveCapability{},
                },
                .init = &LifecycleValve.initValve,
                .deinit = &LifecycleValve.deinitValve,
                .onAppStart = &LifecycleValve.onStart,
                .onAppStop = &LifecycleValve.onStop,
            },
        };
    }

    pub fn initValve(v: *E12.Valve, ctx: *E12.ValveContext) !void {
        const self = @as(*LifecycleValve, @ptrFromInt(@intFromPtr(v) - @offsetOf(LifecycleValve, "valve")));
        self.initialized = true;
        std.debug.print("[Lifecycle] Valve initialized\n", .{});
        _ = ctx;
    }

    pub fn deinitValve(v: *E12.Valve) void {
        const self = @as(*LifecycleValve, @ptrFromInt(@intFromPtr(v) - @offsetOf(LifecycleValve, "valve")));
        std.debug.print("[Lifecycle] Valve deinitialized\n", .{});
        _ = self;
    }

    pub fn onStart(v: *E12.Valve, ctx: *E12.ValveContext) !void {
        _ = v;
        _ = ctx;
        std.debug.print("[Lifecycle] App started\n", .{});
    }

    pub fn onStop(v: *E12.Valve, ctx: *E12.ValveContext) void {
        _ = v;
        _ = ctx;
        std.debug.print("[Lifecycle] App stopped\n", .{});
    }
};
```

### 10.6 Using Builtin Valves

Engine12 includes production-ready builtin valves. Here's how to use the `BasicAuthValve` for authentication:

```zig
const std = @import("std");
const E12 = @import("Engine12");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // Initialize database and ORM
    const db = try E12.orm.Database.open("app.db", allocator);
    var orm_instance = E12.orm.ORM.init(db, allocator);
    
    // Create Engine12 app
    var app = try E12.Engine12.initDevelopment();
    defer app.deinit();
    
    // Create and register auth valve
    var auth_valve = E12.BasicAuthValve.init(.{
        .secret_key = "your-secret-key-change-in-production",
        .orm = &orm_instance,
        .token_expiry_seconds = 3600, // 1 hour
    });
    try app.registerValve(&auth_valve.valve);
    
    // Manually register auth routes (route registration through valve context not yet implemented)
    try app.post("/auth/register", E12.BasicAuthValve.handleRegister);
    try app.post("/auth/login", E12.BasicAuthValve.handleLogin);
    try app.post("/auth/logout", E12.BasicAuthValve.handleLogout);
    try app.get("/auth/me", E12.BasicAuthValve.handleGetMe);
    
    // Register protected route
    try app.get("/protected", handleProtected);
    
    // Start app (migration runs automatically)
    try app.start();
}

fn handleProtected(req: *E12.Request) E12.Response {
    // Require authentication
    const user = E12.BasicAuthValve.requireAuth(req) catch {
        return E12.Response.errorResponse("Unauthorized", 401);
    };
    defer {
        const allocator = std.heap.page_allocator;
        allocator.free(user.username);
        allocator.free(user.email);
        allocator.free(user.password_hash);
    }
    
    return E12.Response.json("{\"message\":\"Hello, authenticated user!\"}");
}
```

The `BasicAuthValve` provides handler functions for:
- `POST /auth/register` - User registration
- `POST /auth/login` - User login (returns JWT token)
- `POST /auth/logout` - Logout
- `GET /auth/me` - Get current user info
- Automatic authentication middleware for JWT validation

**Note**: Routes must be manually registered after registering the valve, as shown in the example above.

See the [API Reference](../api-reference.md#builtin-valves) for complete documentation.

### 10.7 Best Practices

1. **Declare Only Required Capabilities**: Only request capabilities your valve actually needs
2. **Handle Errors Gracefully**: Check for capability errors and provide clear error messages
3. **Clean Up Resources**: Implement `deinit` to free any allocated resources
4. **Use Lifecycle Hooks**: Use `onAppStart` and `onAppStop` for initialization that depends on app state
5. **Document Your Valve**: Provide clear metadata including description and author
6. **Use Builtin Valves**: Prefer builtin valves like `BasicAuthValve` when they meet your needs

## Step 11: Using HandlerCtx

HandlerCtx is a high-level abstraction that reduces boilerplate code in handlers by 70-80%. It automatically handles common patterns like authentication, ORM access, parameter parsing, caching, and logging.

### 11.1 Introduction to HandlerCtx

HandlerCtx wraps a `Request` and provides convenient methods for common handler operations. It eliminates repetitive code patterns while maintaining Zig's type safety.

**Benefits:**
- **70-80% code reduction**: Eliminates repetitive authentication, ORM access, and parameter parsing boilerplate
- **Consistent error handling**: Standardized error responses with automatic logging
- **Type safety**: Maintains Zig's compile-time guarantees
- **Memory safety**: Automatic memory management via request arena allocator

### 11.2 Basic Usage

To use HandlerCtx, initialize it at the start of your handler:

```zig
const HandlerCtx = E12.HandlerCtx;

fn handleProtected(req: *E12.Request) E12.Response {
    var ctx = HandlerCtx.init(req, .{
        .require_auth = true,
        .require_orm = true,
        .get_orm = getORM, // Your app's ORM getter function
    }) catch |err| {
        return switch (err) {
            error.AuthenticationRequired => E12.Response.errorResponse("Authentication required", 401),
            error.DatabaseNotInitialized => E12.Response.serverError("Database not initialized"),
            else => E12.Response.serverError("Internal error"),
        };
    };
    
    // Now you can use ctx.user, ctx.orm(), etc.
    const user = ctx.user.?; // Safe because require_auth = true
    const orm = ctx.orm() catch unreachable; // Safe because require_orm = true
    
    return E12.Response.text("Hello, authenticated user!");
}
```

### 11.3 Authentication Handling

HandlerCtx automatically handles authentication boilerplate. Instead of manually calling `BasicAuthValve.requireAuth()` and managing memory:

**Before:**
```zig
fn handleSearchTodos(request: *Request) Response {
    const user = BasicAuthValve.requireAuth(request) catch {
        return Response.errorResponse("Authentication required", 401);
    };
    defer {
        allocator.free(user.username);
        allocator.free(user.email);
        allocator.free(user.password_hash);
    }
    
    // Use user.id, user.username, etc.
}
```

**After:**
```zig
fn handleSearchTodos(request: *Request) Response {
    var ctx = HandlerCtx.init(request, .{
        .require_auth = true,
        .get_orm = getORM,
    }) catch |err| {
        return switch (err) {
            error.AuthenticationRequired => Response.errorResponse("Authentication required", 401),
            else => Response.serverError("Internal error"),
        };
    };
    
    const user = ctx.user.?; // Already authenticated, strings are arena-allocated
    // Use user.id, user.username, etc. - no manual memory management needed!
}
```

### 11.4 Parameter Parsing

HandlerCtx provides convenient methods for parsing query parameters and route parameters:

**Query Parameters:**
```zig
var ctx = HandlerCtx.init(req, .{}) catch return Response.serverError("Failed to initialize");

// Required query parameter (returns error if missing)
const search_query = ctx.query([]const u8, "q") catch {
    return ctx.badRequest("Missing or invalid query parameter 'q'");
};

// Optional query parameter with default value
const limit = ctx.queryOrDefault(i32, "limit", 10); // Defaults to 10 if missing
const page = ctx.queryOrDefault(i32, "page", 1);     // Defaults to 1 if missing
```

**Route Parameters:**
```zig
// Route: GET /todos/:id
var ctx = HandlerCtx.init(req, .{}) catch return Response.serverError("Failed to initialize");

const todo_id = ctx.param(i64, "id") catch {
    return ctx.badRequest("Invalid todo ID");
};
```

**JSON Body:**
```zig
var ctx = HandlerCtx.init(req, .{}) catch return Response.serverError("Failed to initialize");

const todo_input = ctx.json(TodoInput) catch {
    return ctx.badRequest("Invalid JSON body");
};
```

### 11.5 Caching with HandlerCtx

HandlerCtx simplifies cache operations, especially when working with user-specific data:

```zig
fn handleGetStats(request: *Request) Response {
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

    const user = ctx.user.?;

    // Build cache key with user context (automatically includes user_id)
    const cache_key = ctx.cacheKey("todos:stats:{d}") catch {
        return ctx.serverError("Failed to create cache key");
    };
    // If user.id = 123, cache_key = "todos:stats:123"

    // Check cache
    if (ctx.cacheGet(cache_key) catch null) |entry| {
        return Response.text(entry.body)
            .withContentType(entry.content_type)
            .withHeader("X-Cache", "HIT");
    }

    // Fetch data from database
    const orm = ctx.orm() catch unreachable;
    const stats = getStats(orm, user.id) catch {
        return ctx.serverError("Failed to fetch stats");
    };

    // Serialize and cache
    const json = serializeStats(stats) catch {
        return ctx.serverError("Failed to serialize stats");
    };
    ctx.cacheSet(cache_key, json, 10000, "application/json");

    return Response.json(json).withHeader("X-Cache", "MISS");
}
```

### 11.6 Before and After Comparison

Here's a complete example showing how HandlerCtx reduces boilerplate:

**Before (without HandlerCtx):**
```zig
fn handleSearchTodos(request: *Request) Response {
    // Require authentication
    const user = BasicAuthValve.requireAuth(request) catch {
        return Response.errorResponse("Authentication required", 401);
    };
    defer {
        allocator.free(user.username);
        allocator.free(user.email);
        allocator.free(user.password_hash);
    }

    // Parse query parameter
    const search_query = request.queryParamTyped([]const u8, "q") catch {
        return Response.errorResponse("Invalid query parameter", 400);
    } orelse {
        return Response.errorResponse("Missing query parameter", 400);
    };

    // Get ORM
    const orm = getORM() catch {
        return Response.serverError("Database not initialized");
    };

    // Build cache key
    const cache_key = std.fmt.allocPrint(request.arena.allocator(), "todos:search:{d}:{s}", .{user.id, search_query}) catch {
        return Response.serverError("Failed to create cache key");
    };

    // Check cache
    if (request.cacheGet(cache_key) catch null) |entry| {
        return Response.text(entry.body)
            .withContentType(entry.content_type)
            .withHeader("X-Cache", "HIT");
    }

    // ... rest of handler logic
}
```

**After (with HandlerCtx):**
```zig
fn handleSearchTodos(request: *Request) Response {
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

    const search_query = ctx.query([]const u8, "q") catch {
        return ctx.badRequest("Missing or invalid query parameter 'q'");
    };

    const user = ctx.user.?;
    
    // For cache keys with multiple values, use std.fmt.allocPrint directly
    const std = @import("std");
    const cache_key = std.fmt.allocPrint(request.arena.allocator(), "todos:search:{d}:{s}", .{ user.id, search_query }) catch {
        return ctx.serverError("Failed to create cache key");
    };

    if (ctx.cacheGet(cache_key) catch null) |entry| {
        return Response.text(entry.body)
            .withContentType(entry.content_type)
            .withHeader("X-Cache", "HIT");
    }

    const orm = ctx.orm() catch unreachable;
    
    // ... rest of handler logic - much cleaner!
}
```

**Code Reduction:**
- Authentication boilerplate: ~8 lines → 1 line (87% reduction)
- Query parsing: ~4 lines → 1 line (75% reduction)
- Cache key generation: ~3 lines → 1 line (67% reduction)
- Overall handler: ~15-20 lines of boilerplate → ~3-5 lines (70-80% reduction)

### 11.7 Error Handling

HandlerCtx provides convenient error response methods with automatic logging:

```zig
var ctx = HandlerCtx.init(req, .{}) catch return Response.serverError("Failed to initialize");

// Common error responses
return ctx.unauthorized("Authentication required");
return ctx.forbidden("You don't have permission");
return ctx.badRequest("Invalid input");
return ctx.notFound("Resource not found");
return ctx.serverError("Internal server error");

// Custom status code
return ctx.errorResponse("Custom error message", 418);
```

### 11.8 Integration with restApi

HandlerCtx works alongside `restApi` - it doesn't replace it. Use HandlerCtx for custom handlers that need more control:

```zig
// Use restApi for standard CRUD operations
try app.restApi("/api/todos", Todo, config);

// Use HandlerCtx for custom endpoints
try app.get("/api/todos/search", handleSearchTodos);
try app.get("/api/todos/stats", handleGetStats);
```

### 11.9 Best Practices

1. **Use HandlerCtx for Custom Handlers**: Use HandlerCtx for endpoints that need custom logic beyond standard CRUD
2. **Set Appropriate Requirements**: Use `require_auth` and `require_orm` flags to make requirements explicit
3. **Provide ORM Getter**: Pass your app's ORM getter function for flexible ORM access
4. **Use Convenience Methods**: Take advantage of `badRequest()`, `unauthorized()`, etc. for consistent error responses
5. **Leverage Caching**: Use `cacheKey()` to automatically include user context in cache keys
6. **Gradual Migration**: HandlerCtx is optional - migrate handlers incrementally

## Next Steps

- Add validation for request data
- Implement authentication with sessions
- Add rate limiting
- Set up error handling
- Add more routes and features
- Deploy to production

See the [API Reference](api-reference.md) for more details on available APIs.

