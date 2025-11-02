# Todo App Example

Complete walkthrough of the Engine12 todo application example.

## Overview

The todo app demonstrates:
- Database setup and ORM usage
- CRUD operations (Create, Read, Update, Delete)
- RESTful API endpoints
- Template rendering
- Frontend integration
- Error handling
- Memory management

## Project Structure

```
todo/
├── src/
│   ├── app.zig          # Main application code
│   ├── main.zig         # Entry point
│   └── templates/
│       └── index.zt.html # HTML template
├── frontend/
│   ├── css/
│   │   └── styles.css  # Styling
│   └── js/
│       └── app.js       # Frontend JavaScript
└── todo.db              # SQLite database (created at runtime)
```

## Database Setup

### Model Definition

```zig
const Todo = struct {
    id: i64,
    title: []u8,
    description: []u8,
    completed: bool,
    created_at: i64,
    updated_at: i64,
};
```

### Database Initialization

```zig
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
```

Key points:
- Uses a mutex for thread-safe initialization
- Creates the table schema if it doesn't exist
- Initializes the ORM with the database connection

## CRUD Operations

### Create Todo

```zig
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
        // ... (fallback logic)
    };

    // Fetch the created todo by ID
    const created = try orm.find(Todo, last_id);
    // ... return created todo
}
```

Memory management:
- Uses `errdefer` to clean up on error
- Duplicates strings before storing in struct
- Fetches created todo to return complete object

### Read Todos

```zig
fn getAllTodos(orm: *ORM) !std.ArrayListUnmanaged(Todo) {
    return try orm.findAll(Todo);
}

fn findTodoById(orm: *ORM, id: i64) !?Todo {
    const todo = try orm.find(Todo, id);
    return todo;
}
```

### Update Todo

```zig
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
```

Key points:
- Partial updates using optional fields
- Properly frees old strings before allocating new ones
- Updates timestamp

### Delete Todo

```zig
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
```

## Route Handlers

### GET / - Index Page

```zig
fn handleIndex(request: *Request) Response {
    _ = request;

    // Compile template at comptime
    const template_content = @embedFile("templates/index.zt.html");
    const IndexTemplate = templates.Template.compile(template_content);

    // Define context type
    const IndexContext = struct {
        title: []const u8,
        subtitle: []const u8,
        // ... other fields
    };

    // Create context
    const context = IndexContext{
        .title = "Todo List",
        .subtitle = "Enter your todos here",
        // ... other values
    };

    // Render template
    const html = IndexTemplate.render(IndexContext, context, allocator) catch {
        return Response.text("Internal server error: template rendering failed").withStatus(500);
    };

    return Response.html(html)
        .withHeader("Cache-Control", "no-cache, no-store, must-revalidate")
        .withHeader("Pragma", "no-cache")
        .withHeader("Expires", "0");
}
```

### GET /api/todos - List All Todos

```zig
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
```

Memory management:
- Properly frees all todo strings in defer block
- Frees JSON string after use

### POST /api/todos - Create Todo

```zig
fn handleCreateTodo(request: *Request) Response {
    const body = request.body();
    const parsed = parseTodoFromJson(body, allocator) catch {
        return Response.json("{\"error\":\"Invalid JSON\"}").withStatus(400);
    };
    defer {
        allocator.free(parsed.title);
        allocator.free(parsed.description);
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
```

### PUT /api/todos/:id - Update Todo

```zig
fn handleUpdateTodo(request: *Request) Response {
    const id = request.param("id").asI64() catch {
        return Response.json("{\"error\":\"Invalid ID\"}").withStatus(400);
    };

    const body = request.body();
    const parsed = parseTodoFromJson(body, allocator) catch {
        return Response.json("{\"error\":\"Invalid JSON\"}").withStatus(400);
    };
    defer {
        allocator.free(parsed.title);
        allocator.free(parsed.description);
    }

    const orm = getORM() catch {
        return Response.json("{\"error\":\"Database not initialized\"}").withStatus(500);
    };

    const updates = struct {
        title: ?[]const u8 = parsed.title,
        description: ?[]const u8 = parsed.description,
        completed: ?bool = parsed.completed,
    };

    const todo = updateTodo(orm, id, updates) catch {
        return Response.json("{\"error\":\"Failed to update todo\"}").withStatus(500);
    };

    if (todo) |t| {
        defer {
            allocator.free(t.title);
            allocator.free(t.description);
        }
        const json = formatTodoJson(t, allocator) catch {
            return Response.json("{\"error\":\"Failed to format todo\"}").withStatus(500);
        };
        defer allocator.free(json);
        return Response.json(json);
    } else {
        return Response.json("{\"error\":\"Todo not found\"}").withStatus(404);
    }
}
```

### DELETE /api/todos/:id - Delete Todo

```zig
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
```

### GET /api/stats - Get Statistics

```zig
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
```

## Application Setup

```zig
pub fn main() !void {
    try initDatabase();

    var app = try Engine12.initDevelopment();
    defer app.deinit();

    // Register routes
    try app.get("/", handleIndex);
    try app.serveStatic("/", "frontend");
    try app.get("/api/todos", handleGetTodos);
    try app.get("/api/todos/:id", handleGetTodo);
    try app.post("/api/todos", handleCreateTodo);
    try app.put("/api/todos/:id", handleUpdateTodo);
    try app.delete("/api/todos/:id", handleDeleteTodo);
    try app.get("/api/stats", handleGetStats);

    try app.start();
    app.printStatus();

    // Keep server running
    std.Thread.sleep(std.time.ns_per_min * 60);
}
```

## Frontend Integration

The frontend (`frontend/js/app.js`) uses the Fetch API to interact with the backend:

```javascript
const API_BASE = '/api/todos';

async function fetchTodos() {
    const response = await fetch(API_BASE, {
        cache: 'no-store',
    });
    const data = await response.json();
    todos = Array.isArray(data) ? data : [];
    renderTodos();
    updateStats();
}

async function createTodo(title, description) {
    const response = await fetch(API_BASE, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ title, description }),
        cache: 'no-store',
    });
    await response.json();
    await fetchTodos();
    await fetchStats();
}

async function updateTodo(id, updates) {
    const response = await fetch(`${API_BASE}/${id}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(updates),
        cache: 'no-store',
    });
    await response.json();
    await fetchTodos();
    await fetchStats();
}

async function deleteTodo(id) {
    const response = await fetch(`${API_BASE}/${id}`, {
        method: 'DELETE',
        cache: 'no-store',
    });
    await response.json();
    await fetchTodos();
    await fetchStats();
}
```

## Key Patterns Demonstrated

### Memory Management

1. **Always free allocated strings**: Use `defer` blocks to ensure cleanup
2. **Use `errdefer`**: Clean up on error paths
3. **Arena allocators**: Request handlers use arena allocators for temporary data
4. **Persistent memory**: Response bodies use page allocator

### Error Handling

1. **Graceful degradation**: Return appropriate HTTP status codes
2. **Error messages**: Provide helpful error messages in JSON responses
3. **Null checks**: Check for null/empty results before use

### API Design

1. **RESTful**: Follow REST conventions (GET, POST, PUT, DELETE)
2. **JSON responses**: Consistent JSON format for all API responses
3. **Status codes**: Use appropriate HTTP status codes
4. **Cache headers**: Prevent caching for dynamic content

### Type Safety

1. **Comptime templates**: Templates are type-checked at compile time
2. **Struct definitions**: Use structs for data models
3. **Type inference**: Leverage Zig's type system

## Running the Example

1. Build the application:
   ```bash
   cd todo
   zig build
   ```

2. Run the server:
   ```bash
   ./zig-out/bin/todo
   ```

3. Visit `http://127.0.0.1:8080` in your browser

4. Interact with the API:
   ```bash
   # Get all todos
   curl http://127.0.0.1:8080/api/todos

   # Create a todo
   curl -X POST http://127.0.0.1:8080/api/todos \
     -H "Content-Type: application/json" \
     -d '{"title":"Learn Zig","description":"Study Engine12"}'

   # Update a todo
   curl -X PUT http://127.0.0.1:8080/api/todos/1 \
     -H "Content-Type: application/json" \
     -d '{"completed":true}'

   # Delete a todo
   curl -X DELETE http://127.0.0.1:8080/api/todos/1

   # Get statistics
   curl http://127.0.0.1:8080/api/stats
   ```

## Advanced Features

### Transactions

The app could use transactions for atomic operations:

```zig
try orm.transaction(void, struct {
    fn callback(trans: *Database.Transaction) !void {
        try trans.execute("INSERT INTO todos (title) VALUES ('Todo 1')");
        try trans.execute("INSERT INTO todos (title) VALUES ('Todo 2')");
    }
}.callback);
```

### Migrations

Use migrations for schema management:

```zig
const migrations = [_]Migration{
    Migration.init(1, "create_todos",
        "CREATE TABLE todos (...);",
        "DROP TABLE todos;"),
};

try orm.runMigrations(&migrations);
```

## Lessons Learned

1. **Memory management is explicit**: Always free what you allocate
2. **Type safety catches errors**: Use Zig's type system to your advantage
3. **Error handling is important**: Handle errors gracefully
4. **API design matters**: Consistent APIs are easier to use
5. **Templates are powerful**: Compile-time templates provide type safety

This example demonstrates best practices for building Engine12 applications. Use it as a reference for your own projects.

