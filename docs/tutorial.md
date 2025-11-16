# Tutorial: Building Your First Engine12 App

This tutorial will guide you through building a complete web application with Engine12, step by step.

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

## Step 6: Middleware

Add logging and authentication middleware.

### 6.1 Logging Middleware

```zig
fn loggingMiddleware(req: *Request) MiddlewareResult {
    std.debug.print("[{s}] {s} {s}\n", .{
        @tagName(std.time.timestamp()),
        req.method(),
        req.path(),
    });
    return .proceed;
}

// In main():
try app.usePreRequest(loggingMiddleware);
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

## Step 8: Advanced Features

### 8.1 Type-Safe Parameter Parsing

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

### 8.2 Pagination Helper

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

### 8.3 Error Response Helpers

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

### 8.4 JSON Serialization

Use `jsonFrom()` to automatically serialize structs:

```zig
const todo = Todo{ .id = 1, .title = "Hello", .completed = false };
return Response.jsonFrom(Todo, todo, allocator);
```

## Next Steps

- Add validation for request data
- Implement authentication with sessions
- Add rate limiting
- Set up error handling
- Add more routes and features
- Deploy to production

See the [API Reference](api-reference.md) for more details on available APIs.

