# API Reference

Complete reference for Engine12's public APIs.

## Table of Contents

- [Engine12 Core](#engine12-core)
- [Request API](#request-api)
- [Response API](#response-api)
- [Middleware System](#middleware-system)
- [ORM API](#orm-api)
- [Database API](#database-api)
- [Migration API](#migration-api)
- [Query Builder](#query-builder)
- [Template Engine](#template-engine)
- [File Server](#file-server)
- [Rate Limiting](#rate-limiting)
- [CSRF Protection](#csrf-protection)
- [Metrics & Health Checks](#metrics--health-checks)
- [Background Tasks](#background-tasks)
- [Error Handling](#error-handling)
- [C API](#c-api)

## Engine12 Core

### Initialization

#### `initDevelopment() !Engine12`
Initialize Engine12 for development environment.

```zig
var app = try Engine12.initDevelopment();
defer app.deinit();
```

#### `initProduction() !Engine12`
Initialize Engine12 for production environment.

```zig
var app = try Engine12.initProduction();
defer app.deinit();
```

#### `initTesting() !Engine12`
Initialize Engine12 for testing environment.

```zig
var app = try Engine12.initTesting();
defer app.deinit();
```

#### `initWithProfile(profile: ServerProfile) !Engine12`
Initialize Engine12 with a custom server profile.

```zig
const profile = ServerProfile{
    .environment = .production,
    .enable_request_logging = true,
    .enable_metrics = true,
    .enable_health_checks = true,
    .graceful_shutdown_timeout_ms = 30000,
    .max_concurrent_tasks = 16,
};
var app = try Engine12.initWithProfile(profile);
```

### Route Registration

#### `get(path_pattern: []const u8, handler: HttpHandler) !void`
Register a GET endpoint. Supports route parameters with `:param` syntax.

```zig
fn handleRoot(req: *Request) Response {
    return Response.text("Hello, World!");
}

try app.get("/", handleRoot);
try app.get("/todos/:id", handleTodo);
```

#### `post(path_pattern: []const u8, handler: HttpHandler) !void`
Register a POST endpoint.

```zig
fn handleCreate(req: *Request) Response {
    const todo = try req.jsonBody(Todo);
    // ... create logic
    return Response.created().withJson(json_data);
}

try app.post("/todos", handleCreate);
```

#### `put(path_pattern: []const u8, handler: HttpHandler) !void`
Register a PUT endpoint.

```zig
try app.put("/todos/:id", handleUpdate);
```

#### `delete(path_pattern: []const u8, handler: HttpHandler) !void`
Register a DELETE endpoint.

```zig
try app.delete("/todos/:id", handleDelete);
```

#### `patch(path_pattern: []const u8, handler: HttpHandler) !void`
Register a PATCH endpoint.

```zig
try app.patch("/todos/:id", handlePatch);
```

### Route Groups

#### `group(prefix: []const u8) RouteGroup`
Create a route group with a prefix and optional shared middleware.

```zig
var api = app.group("/api");
api.usePreRequest(authMiddleware);
api.get("/todos", handleTodos);  // Registers at /api/todos
api.post("/todos", handleCreate); // Registers at /api/todos
```

### Server Lifecycle

#### `start() !void`
Start the HTTP server and background tasks.

```zig
try app.start();
```

#### `stop() !void`
Stop the server gracefully.

```zig
try app.stop();
```

#### `deinit() void`
Clean up server resources.

```zig
defer app.deinit();
```

### Middleware

#### `usePreRequest(middleware: PreRequestMiddlewareFn) !void`
Add a pre-request middleware to the chain.

```zig
fn authMiddleware(req: *Request) MiddlewareResult {
    if (req.header("Authorization")) |_| {
        return .proceed;
    }
    return .abort;
}

try app.usePreRequest(authMiddleware);
```

#### `useResponse(middleware: ResponseMiddlewareFn) !void`
Add a response middleware to the chain.

```zig
fn corsMiddleware(resp: Response) Response {
    return resp.withHeader("Access-Control-Allow-Origin", "*");
}

try app.useResponse(corsMiddleware);
```

### Static File Serving

#### `serveStatic(mount_path: []const u8, directory: []const u8) !void`
Register static file serving from a directory. Supports nested paths for non-root mounts.

```zig
try app.serveStatic("/", "frontend/public");
try app.serveStatic("/css", "frontend/css"); // Handles nested paths like /css/styles/main.css
```

**Note**: The route limit is 5000 routes.

### Configuration

#### `setRateLimiter(limiter: *RateLimiter) void`
Set a global rate limiter for all routes.

```zig
var limiter = RateLimiter.init(allocator, 100, 60000); // 100 req/min
app.setRateLimiter(&limiter);
```

#### `setCache(response_cache: *ResponseCache) void`
Set a global response cache for all routes.

```zig
var cache = ResponseCache.init(allocator);
app.setCache(&cache);
```

#### `useErrorHandler(handler: ErrorHandler) void`
Register a custom error handler.

```zig
fn customErrorHandler(err: anyerror) Response {
    return Response.status(500).withJson("{\"error\":\"Internal error\"}");
}

app.useErrorHandler(customErrorHandler);
```

### Status & Monitoring

#### `getSystemHealth() HealthStatus`
Get overall system health status.

```zig
const health = app.getSystemHealth();
// Returns: .healthy, .degraded, or .unhealthy
```

#### `getUptimeMs() i64`
Get uptime in milliseconds.

```zig
const uptime = app.getUptimeMs();
```

#### `getRequestCount() u64`
Get total request count.

```zig
const count = app.getRequestCount();
```

#### `printStatus() void`
Print streamlined server status.

```zig
app.printStatus();
// Output:
// Server ready
//   Status: RUNNING | Health: healthy | Routes: 5 | Tasks: 2
```

## Request API

### Path & Method

#### `path() []const u8`
Get the request path (without query string).

```zig
const path = req.path(); // "/todos/123"
```

#### `fullPath() []const u8`
Get the full request path including query string.

```zig
const full = req.fullPath(); // "/todos/123?limit=10"
```

#### `method() []const u8`
Get the HTTP method as a string.

```zig
const method = req.method(); // "GET", "POST", etc.
```

### Body Access

#### `body() []const u8`
Get the raw request body.

```zig
const body = req.body();
```

#### `jsonBody(comptime T: type) !T`
Parse request body as JSON into a struct.

```zig
const Todo = struct {
    title: []const u8,
    completed: bool,
};

const todo = try req.jsonBody(Todo);
```

#### `formBody() !StringHashMap([]const u8)`
Parse request body as URL-encoded form data.

```zig
const form = try req.formBody();
const title = form.get("title");
```

### Route Parameters

#### `param(name: []const u8) Param`
Get a route parameter by name. Returns a `Param` wrapper for type-safe conversion.

```zig
const id = try req.param("id").asI64();
const limit = req.param("limit").asU32Default(10);
```

### Query Parameters

#### `query(name: []const u8) !?[]const u8`
Get a query parameter by name. Returns null if not found, or error if parsing fails.

```zig
const limit = try req.query("limit");
const limit_u32 = if (limit) |l| try std.fmt.parseInt(u32, l, 10) else 10;
```

#### `queryOptional(name: []const u8) ?[]const u8`
Get a query parameter by name (optional only, throws on parse error). Returns optional only - throws if query parameter parsing fails.

```zig
const status = req.queryOptional("status"); // ?[]const u8
if (status) |s| {
    // Use status
}
```

#### `queryStrict(name: []const u8) ![]const u8`
Get a query parameter by name (strict - fails if missing). Returns error union - fails if parameter is missing or parsing fails.

```zig
const limit = try req.queryStrict("limit"); // ![]const u8
```

#### `queryParam(name: []const u8) !Param`
Get a query parameter as a `Param` wrapper.

```zig
const limit = try req.queryParam("limit").asU32Default(10);
```

#### `queryParams() !StringHashMap([]const u8)`
Get all query parameters as a hashmap.

```zig
const params = try req.queryParams();
const limit = params.get("limit");
```

### Headers

#### `header(name: []const u8) ?[]const u8`
Get a header value by name.

```zig
const auth = req.header("Authorization");
```

### Context

#### `set(key: []const u8, value: []const u8) !void`
Store a value in the request context.

```zig
try req.set("user_id", "123");
```

#### `get(key: []const u8) ?[]const u8`
Get a value from the request context.

```zig
const user_id = req.get("user_id");
```

### Allocator

#### `allocator() Allocator`
Get the arena allocator for this request. All allocations are automatically freed when the request completes.

```zig
const query = try req.allocator().dupe(u8, "some string");
// query will be automatically freed when request completes
```

## Response API

### Creating Responses

#### `text(body: []const u8) Response`
Create a text response.

```zig
return Response.text("Hello, World!");
```

#### `json(body: []const u8) Response`
Create a JSON response.

```zig
return Response.json("{\"status\":\"ok\"}");
```

#### `html(body: []const u8) Response`
Create an HTML response.

```zig
return Response.html("<html><body>Hello</body></html>");
```

### Status Codes

#### `ok() Response`
Create a 200 OK response.

```zig
return Response.ok().withJson(data);
```

#### `created() Response`
Create a 201 Created response.

```zig
return Response.created().withJson("{\"id\":123}");
```

#### `noContent() Response`
Create a 204 No Content response.

```zig
return Response.noContent();
```

#### `badRequest() Response`
Create a 400 Bad Request response.

```zig
return Response.badRequest().withJson("{\"error\":\"Invalid input\"}");
```

#### `unauthorized() Response`
Create a 401 Unauthorized response.

```zig
return Response.unauthorized();
```

#### `forbidden() Response`
Create a 403 Forbidden response.

```zig
return Response.forbidden();
```

#### `notFound() Response`
Create a 404 Not Found response.

```zig
return Response.notFound();
```

#### `internalError() Response`
Create a 500 Internal Server Error response.

```zig
return Response.internalError().withJson("{\"error\":\"Something went wrong\"}");
```

#### `status(status_code: u16) Response`
Create a response with a specific status code.

```zig
return Response.status(418); // I'm a teapot
```

### Modifying Responses

#### `withStatus(status_code: u16) Response`
Set the status code.

```zig
return Response.text("error").withStatus(400);
```

#### `withJson(body: []const u8) Response`
Set JSON body for this response. Can be chained after builder methods like `ok()`, `created()`, etc.

```zig
return Response.created().withJson("{\"id\":123}");
return Response.ok().withJson(data);
```

#### `withHeader(name: []const u8, value: []const u8) Response`
Add a custom header. For Content-Type headers, use `withContentType()` instead.

```zig
return Response.json(data).withHeader("X-Custom-Header", "value");
```

#### `withContentType(content_type: []const u8) Response`
Set the Content-Type header.

```zig
return Response.text("data").withContentType("application/json");
```

#### `withCookie(name: []const u8, value: []const u8, options: CookieOptions) Response`
Set a cookie.

```zig
const options = CookieOptions{
    .maxAge = 3600,
    .httpOnly = true,
    .secure = true,
};
return Response.ok().withCookie("session_id", "abc123", options);
```

#### `redirect(location: []const u8) Response`
Create a redirect response.

```zig
return Response.redirect("/login");
return Response.redirect("/dashboard").withStatus(301); // Permanent
```

## Middleware System

### Pre-Request Middleware

Pre-request middleware can short-circuit by returning `.abort`.

```zig
pub const PreRequestMiddlewareFn = *const fn (*Request) MiddlewareResult;

fn authMiddleware(req: *Request) MiddlewareResult {
    if (req.header("Authorization")) |_| {
        return .proceed;
    }
    return .abort; // Stops processing, returns 401
}

try app.usePreRequest(authMiddleware);
```

### Response Middleware

Response middleware transforms responses.

```zig
pub const ResponseMiddlewareFn = *const fn (Response) Response;

fn corsMiddleware(resp: Response) Response {
    return resp.withHeader("Access-Control-Allow-Origin", "*");
}

try app.useResponse(corsMiddleware);
```

### Middleware Chain

#### `executePreRequest(req: *Request) ?Response`
Execute all pre-request middleware. Returns `null` if processing should continue, or a response if aborted.

#### `executeResponse(response: Response, req: ?*Request) Response`
Execute all response middleware, transforming the response.

## ORM API

### Initialization

#### `init(db: Database, allocator: Allocator) ORM`
Initialize ORM with a database connection. Returns a value type.

```zig
var db = try Database.open("app.db", allocator);
var orm = ORM.init(db, allocator);
```

#### `initPtr(db: Database, allocator: Allocator) !*ORM`
Initialize ORM and return a heap-allocated pointer. Recommended for handler usage where you need to pass pointers.

```zig
var db = try Database.open("app.db", allocator);
var orm = try ORM.initPtr(db, allocator);
defer orm.deinitPtr(allocator);
```

**When to use `initPtr()`:**
- When you need to pass ORM instances to handlers
- When using global ORM instances that need to be pointers
- When you need explicit lifetime management

**When to use `init()`:**
- For local ORM usage within a function
- When you don't need pointer semantics
- For simpler, stack-allocated usage

#### `deinitPtr(self: *ORM, allocator: Allocator) void`
Deinitialize and free a heap-allocated ORM instance. Call this after `initPtr()` when you're done with the ORM.

```zig
var orm = try ORM.initPtr(db, allocator);
defer orm.deinitPtr(allocator);
```

#### `close() void`
Close the database connection. Use this with `init()`, use `deinitPtr()` with `initPtr()`.

```zig
var orm = ORM.init(db, allocator);
defer orm.close();
```

### CRUD Operations

#### `create(comptime T: type, instance: T) !void`
Create a new record. Supports structs with enum types and optional fields.

**Enum Support**: Enums are automatically converted to their integer values when saving to the database.

**Optional Fields**: Optional fields that are `null` are automatically skipped in INSERT statements (not included in the SQL).

```zig
const TodoStatus = enum { pending, in_progress, completed };

const Todo = struct {
    id: i64,
    title: []const u8,
    completed: bool,
    status: TodoStatus = .pending, // enum field supported
    description: ?[]const u8 = null, // optional field - null values are skipped
    created_at: i64,
    updated_at: i64,
};

const todo = Todo{
    .id = 0,
    .title = try allocator.dupe(u8, "Learn Zig"),
    .completed = false,
    .status = .pending, // enum automatically converted to integer
    .description = null, // This field will be skipped in INSERT
    .created_at = std.time.milliTimestamp(),
    .updated_at = std.time.milliTimestamp(),
};

try orm.create(Todo, todo);
```

**Note**: Optional enum fields are also supported. Null optional fields are skipped in INSERT/UPDATE operations.

#### `find(comptime T: type, id: i64) !?T`
Find a record by ID.

```zig
const todo = try orm.find(Todo, 1);
if (todo) |t| {
    // Use todo
    defer allocator.free(t.title);
}
```

#### `findAll(comptime T: type) !ArrayListUnmanaged(T)`
Find all records. Enhanced error handling provides detailed context when errors occur.

**Error Handling:**
- `error.ColumnMismatch`: When the number of database columns doesn't match the struct field count
- `error.QueryFailed`: When the SQL query fails (e.g., table doesn't exist)
- `error.InvalidData`: When data cannot be deserialized
- `error.NullValueForNonOptional`: When a non-optional field receives a null value

Error messages include:
- Table name
- SQL query that was executed
- Expected vs actual column count
- Field and column information

```zig
var todos = orm.findAll(Todo) catch |err| {
    std.debug.print("Failed to fetch todos: {}\n", .{err});
    return Response.status(500).withJson("{\"error\":\"Failed to fetch todos\"}");
};
defer {
    for (todos.items) |todo| {
        allocator.free(todo.title);
    }
    todos.deinit(allocator);
}
```

**Validation:**
The ORM automatically validates that:
- Column count matches struct field count
- Field types are compatible with column types
- Null values are handled correctly for optional/non-optional fields

#### `where(comptime T: type, condition: []const u8) !ArrayListUnmanaged(T)`
Find records matching a condition. Enhanced error handling provides detailed context when errors occur.

**Error Handling:**
Same as `findAll()` - includes detailed error messages with table name, SQL query, and column/field information.

```zig
var completed = orm.where(Todo, "completed = 1") catch |err| {
    std.debug.print("Failed to query todos: {}\n", .{err});
    return Response.status(500).withJson("{\"error\":\"Query failed\"}");
};
defer {
    for (completed.items) |todo| {
        allocator.free(todo.title);
    }
    completed.deinit(allocator);
}
```

**Note**: The condition string is inserted directly into the SQL query. Be careful with user input to prevent SQL injection. Consider using parameterized queries or the Query Builder for dynamic conditions.

#### `update(comptime T: type, instance: T) !void`
Update a record. Optional fields that are `null` are skipped in UPDATE statements (not included in the SQL).

```zig
const todo = Todo{
    .id = 1,
    .title = try allocator.dupe(u8, "Updated title"),
    .completed = true,
    .description = null, // This field will be skipped in UPDATE
    .created_at = 0,
    .updated_at = std.time.milliTimestamp(),
};

try orm.update(Todo, todo);
```

**Note**: Only non-null optional fields are included in the UPDATE statement. This allows partial updates where you only set the fields you want to change.

#### `delete(comptime T: type, id: i64) !void`
Delete a record by ID.

```zig
try orm.delete(Todo, 1);
```

### Transactions

#### `transaction(comptime T: type, callback: fn (*Transaction) anyerror!T) !T`
Execute operations in a transaction. Auto-commits on success, auto-rollbacks on error.

```zig
const result = try orm.transaction(void, struct {
    fn callback(trans: *Database.Transaction) !void {
        try trans.execute("INSERT INTO todos (title) VALUES ('Todo 1')");
        try trans.execute("INSERT INTO todos (title) VALUES ('Todo 2')");
    }
}.callback);
```

### Migrations

#### `runMigrations(migrations: []const Migration) !void`
Run pending migrations.

```zig
const migrations = [_]Migration{
    Migration.init(1, "create_todos", 
        "CREATE TABLE todos (id INTEGER PRIMARY KEY, title TEXT);",
        "DROP TABLE todos;"),
};

try orm.runMigrations(&migrations);
```

#### `migrate(migrations: []const Migration) !void`
Alias for `runMigrations`.

```zig
try orm.migrate(&migrations);
```

#### `getMigrationVersion() !?u32`
Get the current migration version.

```zig
const version = try orm.getMigrationVersion();
```

### Raw SQL

#### `query(sql: []const u8) !QueryResult`
Execute a SELECT query.

```zig
var result = try orm.query("SELECT * FROM todos WHERE completed = 1");
defer result.deinit();
```

#### `execute(sql: []const u8) !void`
Execute a non-query SQL statement.

```zig
try orm.execute("DELETE FROM todos WHERE completed = 1");
```

## Database API

### Connection

#### `open(path: []const u8, allocator: Allocator) !Database`
Open a SQLite database connection.

```zig
var db = try Database.open("app.db", allocator);
defer db.close();
```

#### `close() void`
Close the database connection.

```zig
db.close();
```

### Executing SQL

#### `execute(sql: []const u8) !void`
Execute a SQL statement (INSERT, UPDATE, DELETE, CREATE TABLE, etc.).

```zig
try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
try db.execute("INSERT INTO users (name) VALUES ('Alice')");
```

#### `executeWithRowsAffected(sql: []const u8) !i64`
Execute SQL and return the number of rows affected.

```zig
const rows = try db.executeWithRowsAffected("UPDATE users SET name = 'Bob' WHERE id = 1");
// rows = 1
```

#### `query(sql: []const u8) !QueryResult`
Execute a SELECT query and return a result set.

```zig
var result = try db.query("SELECT * FROM users");
defer result.deinit();
```

#### `lastInsertRowId() !i64`
Get the last inserted row ID.

```zig
try db.execute("INSERT INTO users (name) VALUES ('Charlie')");
const id = try db.lastInsertRowId();
```

### Transactions

#### `beginTransaction() !Transaction`
Begin a database transaction.

```zig
var trans = try db.beginTransaction();
defer trans.deinit();

try trans.execute("INSERT INTO users (name) VALUES ('Alice')");
try trans.execute("INSERT INTO users (name) VALUES ('Bob')");
try trans.commit();
```

#### Transaction Methods

- `commit() !void` - Commit the transaction
- `rollback() !void` - Rollback the transaction
- `execute(sql: []const u8) !void` - Execute SQL within transaction
- `query(sql: []const u8) !QueryResult` - Query within transaction
- `deinit() void` - Clean up transaction (auto-rollbacks if not committed)

### Connection Pooling

#### `ConnectionPoolConfig`
Configuration for connection pooling.

```zig
const config = ConnectionPoolConfig{
    .max_connections = 10,
    .idle_timeout_ms = 300000, // 5 minutes
    .acquire_timeout_ms = 5000, // 5 seconds
};
```

#### `ConnectionPool.init(db_path: []const u8, config: ConnectionPoolConfig, allocator: Allocator) ConnectionPool`
Initialize a connection pool.

```zig
var pool = ConnectionPool.init("app.db", config, allocator);
defer pool.deinit();
```

#### `acquire() !Database`
Acquire a connection from the pool.

```zig
const db = try pool.acquire();
defer pool.release(db);
```

#### `release(db: Database) void`
Return a connection to the pool.

```zig
pool.release(db);
```

## Migration API

### Migration Struct

```zig
pub const Migration = struct {
    version: u32,
    name: []const u8,
    up: []const u8,    // SQL to apply migration
    down: []const u8,  // SQL to rollback migration
};

const migration = Migration.init(
    1,
    "create_users",
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);",
    "DROP TABLE users;"
);
```

### Migration Registry

#### `MigrationRegistry.init(allocator: Allocator) MigrationRegistry`
Initialize a migration registry.

```zig
var registry = MigrationRegistry.init(allocator);
defer registry.deinit();
```

#### `add(migration: Migration) !void`
Add a migration to the registry.

```zig
try registry.add(migration);
```

#### `getMigrations() []Migration`
Get all migrations sorted by version.

```zig
const migrations = registry.getMigrations();
```

### Migration Builder

#### `MigrationBuilder.init(version: u32, name: []const u8, allocator: Allocator) MigrationBuilder`
Initialize a migration builder.

```zig
var builder = MigrationBuilder.init(1, "create_users", allocator);
defer builder.deinit();
```

#### `up(sql: []const u8) !void`
Add SQL for applying the migration.

```zig
try builder.up("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);");
```

#### `down(sql: []const u8) !void`
Add SQL for rolling back the migration.

```zig
try builder.down("DROP TABLE users;");
```

#### `createTable(table_name: []const u8, columns: []const Column) !void`
Create a table migration.

```zig
try builder.createTable("users", &.{
    .{ .name = "id", .type = "INTEGER", .constraints = "PRIMARY KEY" },
    .{ .name = "name", .type = "TEXT", .constraints = "NOT NULL" },
});
```

#### `dropTable(table_name: []const u8) !void`
Drop a table migration.

```zig
try builder.dropTable("old_table");
```

#### `alterTable(table_name: []const u8, alter_sql: []const u8) !void`
Alter a table migration.

```zig
try builder.alterTable("users", "ADD COLUMN email TEXT");
```

#### `build() !Migration`
Build the migration.

```zig
const migration = try builder.build();
```

### Migration Runner

#### `MigrationRunner.init(db: *Database, allocator: Allocator) MigrationRunner`
Initialize a migration runner.

```zig
var runner = MigrationRunner.init(&db, allocator);
```

#### `runMigrations(migrations: []const Migration) !void`
Run pending migrations.

```zig
try runner.runMigrations(&migrations);
```

#### `getCurrentVersion() !?u32`
Get the current migration version.

```zig
const version = try runner.getCurrentVersion();
```

#### `rollbackMigration(version: u32, migrations: []const Migration) !void`
Rollback a specific migration.

```zig
try runner.rollbackMigration(1, &migrations);
```

## Query Builder

### Initialization

#### `init(allocator: Allocator, table_name: []const u8) QueryBuilder`
Initialize a query builder.

```zig
var builder = QueryBuilder.init(allocator, "todos");
defer builder.deinit();
```

### Building Queries

#### `select(fields: []const []const u8) *QueryBuilder`
Specify fields to select.

```zig
builder.select(&.{ "id", "title", "completed" });
```

#### `where(field: []const u8, operator: []const u8, value: []const u8) *QueryBuilder`
Add a WHERE clause.

```zig
builder.where("completed", "=", "1");
```

#### `whereEq(field: []const u8, value: []const u8) *QueryBuilder`
Add an equality WHERE clause.

```zig
builder.whereEq("id", "1");
```

#### `whereGt(field: []const u8, value: []const u8) *QueryBuilder`
Add a greater-than WHERE clause.

```zig
builder.whereGt("created_at", "1000000");
```

#### `limit(count: usize) *QueryBuilder`
Add a LIMIT clause.

```zig
builder.limit(10);
```

#### `offset(count: usize) *QueryBuilder`
Add an OFFSET clause.

```zig
builder.offset(20);
```

#### `orderBy(field: []const u8, ascending: bool) *QueryBuilder`
Add an ORDER BY clause.

```zig
builder.orderBy("created_at", false); // descending
```

#### `join(join_type: []const u8, table: []const u8, on: []const u8) *QueryBuilder`
Add a JOIN clause.

```zig
builder.join("INNER", "users", "todos.user_id = users.id");
```

#### `build() ![]const u8`
Build the SQL query string.

```zig
const sql = try builder.build();
defer allocator.free(sql);
```

## Template Engine

### Compiling Templates

#### `Template.compile(comptime template_str: []const u8) type`
Compile a template from a string literal.

```zig
const TemplateType = Template.compile("<h1>{{ .title }}</h1>");
```

#### `Template.compileFile(comptime file_path: []const u8) type`
Compile a template from a file (uses `@embedFile`).

```zig
const TemplateType = Template.compileFile("templates/index.zt.html");
```

### Rendering Templates

#### `render(comptime Context: type, ctx: Context, allocator: Allocator) ![]const u8`
Render a compiled template with context.

**Example with iteration:**
```zig
const Context = struct {
    title: []const u8,
    todos: []const Todo,
};

const template_content = @embedFile("templates/index.zt.html");
const IndexTemplate = templates.Template.compile(template_content);

const context = Context{
    .title = "My Todos",
    .todos = &[_]Todo{
        Todo{ .id = 1, .title = "Learn Zig", .completed = false },
        Todo{ .id = 2, .title = "Build app", .completed = true },
    },
};

const html = try IndexTemplate.render(Context, context, allocator);
defer allocator.free(html);
```

**Template file (`templates/index.zt.html`):**
```html
<h1>{{ .title }}</h1>
<ul>
{% for .todos |todo| %}
    <li class="{% if .todo.completed %}completed{% endif %}">
        {{ .todo.title }}
        {% if .first %}<span>(First item)</span>{% endif %}
        {% if .last %}<span>(Last item)</span>{% endif %}
        <small>Index: {{ .index }}</small>
    </li>
{% endfor %}
</ul>
```

**Example with parent context:**
```zig
const Context = struct {
    page_title: []const u8,
    users: []const User,
};

const context = Context{
    .page_title = "User List",
    .users = &[_]User{...},
};
```

**Template:**
```html
<h1>{{ .page_title }}</h1>
{% for .users |user| %}
    <div>
        <h2>{{ .user.name }}</h2>
        <p>Page: {{ ../page_title }}</p>
    </div>
{% endfor %}
```

### Template Syntax

- `{{ .field }}` - Output field value (HTML escaped)
- `{{! .field }}` - Output field value (raw, not escaped)
- `{{ .nested.field }}` - Access nested fields
- `{% for .items |item| %}...{% endfor %}` - Iterate over arrays/slices
  - Available loop variables: `.item`, `.index`, `.first`, `.last`
  - Access parent context: `{{ ../parent.field }}`
- `{% if .condition %}...{% else %}...{% endif %}` - Conditional rendering
  - Supports truthy/falsy evaluation
  - Handles empty strings, null, false, 0 as falsy

## File Server

### Initialization

#### `FileServer.init(allocator: Allocator, base_path: []const u8, directory_path: []const u8) FileServer`
Initialize a file server.

```zig
const file_server = FileServer.init(allocator, "/", "public");
```

### Configuration

- `index_file` - Default index file name (default: "index.html")
- `enable_cache` - Enable caching (default: true)
- `max_file_size` - Maximum file size in bytes (default: 10MB)

### Serving Files

#### `serveFile(request_path: []const u8) Response`
Serve a file based on the request path.

```zig
const response = file_server.serveFile("/css/styles.css");
```

## Rate Limiting

Rate limiting is configured globally via `setRateLimiter()`.

```zig
var limiter = RateLimiter.init(allocator, 100, 60000); // 100 req/min
app.setRateLimiter(&limiter);
```

When rate limit is exceeded, middleware returns a 429 status response.

## CSRF Protection

CSRF protection is handled via middleware. See middleware documentation for details.

## Metrics & Health Checks

### Health Checks

#### `registerHealthCheck(check: HealthCheckFn) !void`
Register a health check function.

```zig
fn checkDatabase() HealthStatus {
    // Check database connection
    return .healthy;
}

try app.registerHealthCheck(checkDatabase);
```

#### `getSystemHealth() HealthStatus`
Get overall system health.

```zig
const health = app.getSystemHealth();
// Returns: .healthy, .degraded, or .unhealthy
```

### Metrics

Metrics are automatically collected. Access via `/metrics` endpoint or `MetricsCollector` API.

## Background Tasks

### One-Time Tasks

#### `runTask(name: []const u8, task: BackgroundTask) !void`
Register a background task that runs once.

```zig
fn cleanupTask() void {
    // Cleanup logic
}

try app.runTask("cleanup", cleanupTask);
```

### Periodic Tasks

#### `schedulePeriodicTask(name: []const u8, task: BackgroundTask, interval_ms: u32) !void`
Register a background task that runs periodically.

```zig
fn syncTask() void {
    // Sync logic
}

try app.schedulePeriodicTask("sync", syncTask, 60000); // Every minute
```

## Error Handling

### Error Handler Registration

```zig
fn customErrorHandler(err: anyerror) Response {
    return Response.status(500).withJson("{\"error\":\"Internal error\"}");
}

app.useErrorHandler(customErrorHandler);
```

## C API

Engine12 provides a C API for use from other languages.

### Initialization

```c
Engine12* app;
E12ErrorCode err = e12_init(E12_ENV_DEVELOPMENT, &app);
if (err != E12_OK) {
    // Handle error
}
```

### Route Registration

```c
E12Response* handler(E12Request* req, void* user_data) {
    // Handle request
    return e12_response_text("Hello, World!");
}

e12_get(app, "/", handler, NULL);
```

### Starting Server

```c
e12_start(app);
```

### Cleanup

```c
e12_free(app);
```

See `src/c_api/engine12.h` and `src/c_api/e12_orm.h` for complete C API documentation.

