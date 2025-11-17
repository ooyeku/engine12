# API Reference

Complete reference for Engine12's public APIs.

## Table of Contents

- [Engine12 Core](#engine12-core)
- [Valve System](#valve-system)
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
- [Caching](#caching)
- [Pagination Helper](#pagination-helper)
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
var cache = ResponseCache.init(allocator, 60000); // 60 second default TTL
app.setCache(&cache);
```

#### `getCache() ?*ResponseCache`
Get the global response cache instance. Returns null if cache is not configured.

```zig
if (app.getCache()) |cache| {
    cache.cleanup(); // Clean up expired entries
}
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

#### `registerValve(valve: *Valve) !void`
Register a valve with this Engine12 instance. Valves provide isolated services that integrate with Engine12 runtime.

```zig
var auth_valve = AuthValve.init("secret-key");
try app.registerValve(&auth_valve.valve);
```

#### `unregisterValve(name: []const u8) !void`
Unregister a valve by name.

```zig
try app.unregisterValve("auth");
```

#### `getValveRegistry() ?*ValveRegistry`
Get the valve registry instance. Returns null if no valves are registered.

```zig
if (app.getValveRegistry()) |registry| {
    const names = try registry.getValveNames(allocator);
    defer allocator.free(names);
}
```

## Valve System

The Valve System provides a secure and simple plugin architecture for Engine12. Each valve is an isolated service that integrates deeply with the Engine12 runtime through controlled capabilities.

### Valve Interface

#### `Valve`
The core interface that all valves must implement.

```zig
pub const Valve = struct {
    metadata: ValveMetadata,
    init: *const fn (*Valve, *ValveContext) anyerror!void,
    deinit: *const fn (*Valve) void,
    onAppStart: ?*const fn (*Valve, *ValveContext) anyerror!void = null,
    onAppStop: ?*const fn (*Valve, *ValveContext) void = null,
};
```

#### `ValveMetadata`
Metadata describing a valve, including required capabilities.

```zig
pub const ValveMetadata = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    author: []const u8,
    required_capabilities: []const ValveCapability,
};
```

#### `ValveCapability`
Capabilities that a valve can request. Each capability grants access to specific Engine12 features.

- `.routes` - Register HTTP routes
- `.middleware` - Register middleware
- `.background_tasks` - Register background tasks
- `.health_checks` - Register health check functions
- `.static_files` - Serve static files from directories
- `.websockets` - Handle WebSocket connections (future)
- `.database_access` - Access ORM/database operations
- `.cache_access` - Access response cache
- `.metrics_access` - Access metrics collector

### ValveContext

`ValveContext` provides controlled access to Engine12 runtime for valves. All methods check capabilities before allowing access.

#### `hasCapability(cap: ValveCapability) bool`
Check if valve has a specific capability.

```zig
if (ctx.hasCapability(.routes)) {
    try ctx.registerRoute("GET", "/api/users", handleUsers);
}
```

#### `registerRoute(method: []const u8, path: []const u8, handler: HttpHandler) !void`
Register an HTTP route. Requires `.routes` capability.

```zig
try ctx.registerRoute("GET", "/api/users", handleUsers);
try ctx.registerRoute("POST", "/api/users", handleCreateUser);
```

#### `registerMiddleware(mw: PreRequestMiddlewareFn) !void`
Register pre-request middleware. Requires `.middleware` capability.

```zig
try ctx.registerMiddleware(&authMiddleware);
```

#### `registerResponseMiddleware(mw: ResponseMiddlewareFn) !void`
Register response middleware. Requires `.middleware` capability.

```zig
try ctx.registerResponseMiddleware(&corsMiddleware);
```

#### `registerTask(name: []const u8, task: BackgroundTask, interval_ms: ?u32) !void`
Register a background task. Requires `.background_tasks` capability.

```zig
// One-time task
try ctx.registerTask("cleanup", cleanupTask, null);

// Periodic task (every 60 seconds)
try ctx.registerTask("periodic", periodicTask, 60000);
```

#### `registerHealthCheck(check: HealthCheckFn) !void`
Register a health check function. Requires `.health_checks` capability.

```zig
try ctx.registerHealthCheck(&checkDatabase);
```

#### `serveStatic(mount_path: []const u8, directory: []const u8) !void`
Serve static files from a directory. Requires `.static_files` capability.

```zig
try ctx.serveStatic("/static", "./public");
```

#### `getORM() !?*ORM`
Get ORM instance. Requires `.database_access` capability. Returns null if ORM is not initialized.

```zig
if (try ctx.getORM()) |orm| {
    const todos = try orm.findAll(Todo);
}
```

#### `getCache() ?*ResponseCache`
Get cache instance. Requires `.cache_access` capability. Returns null if cache is not configured.

```zig
if (ctx.getCache()) |cache| {
    try cache.set("key", "value", 60000);
}
```

#### `getMetrics() ?*MetricsCollector`
Get metrics collector. Requires `.metrics_access` capability. Returns null if metrics are not enabled.

```zig
if (ctx.getMetrics()) |metrics| {
    metrics.incrementCounter("requests");
}
```

### ValveRegistry

`ValveRegistry` manages valve registration and lifecycle.

#### `ValveRegistry.init(allocator: Allocator) ValveRegistry`
Initialize a new valve registry.

```zig
var registry = ValveRegistry.init(allocator);
defer registry.deinit();
```

#### `register(valve: *Valve, app: *Engine12) !void`
Register a valve with an Engine12 instance. Creates a context with granted capabilities and calls `valve.init()`.

```zig
try registry.register(&my_valve, &app);
```

#### `unregister(name: []const u8) !void`
Unregister a valve by name. Calls `valve.deinit()` and removes from registry.

```zig
try registry.unregister("my_valve");
```

#### `getContext(name: []const u8) ?*ValveContext`
Get context for a valve by name. Returns null if valve not found.

```zig
if (registry.getContext("my_valve")) |ctx| {
    try ctx.registerRoute("GET", "/test", handler);
}
```

#### `getValveNames(allocator: Allocator) ![]const []const u8`
Get all registered valve names. Returns a slice allocated with the provided allocator.

```zig
const names = try registry.getValveNames(allocator);
defer allocator.free(names);
for (names) |name| {
    std.debug.print("Valve: {s}\n", .{name});
}
```

### Valve Errors

#### `ValveError`
Valve-specific errors.

- `CapabilityRequired` - Valve attempted to use a feature without the required capability
- `ValveNotFound` - Valve with the specified name was not found
- `ValveAlreadyRegistered` - Attempted to register a valve with a name that's already in use
- `InvalidMethod` - Invalid HTTP method passed to `registerRoute`

### Builtin Valves

Engine12 includes production-ready builtin valves that provide common functionality.

#### BasicAuthValve

A production-ready JWT-based authentication valve that provides user registration, login, logout, and authentication middleware. Uses Engine12's built-in ORM for user storage.

**Configuration:**

```zig
const auth_valve = BasicAuthValve.init(.{
    .secret_key = "your-secret-key-here",
    .orm = orm_instance,
    .token_expiry_seconds = 3600, // Optional, default: 3600
    .user_table_name = "users",   // Optional, default: "users"
});
try app.registerValve(&auth_valve.valve);
```

**Configuration Options:**

- `secret_key` (required): JWT secret key for token signing
- `orm` (required): ORM instance for user storage
- `token_expiry_seconds` (optional): Token expiration time in seconds (default: 3600)
- `user_table_name` (optional): Database table name for users (default: "users")

**Routes:**

- `POST /auth/register` - Register a new user (requires username, email, password)
- `POST /auth/login` - Login and receive JWT token (requires username/email and password)
- `POST /auth/logout` - Logout (returns success)
- `GET /auth/me` - Get current authenticated user info (requires valid JWT token)

**Authentication Middleware:**

The valve automatically registers authentication middleware that extracts JWT tokens from the `Authorization: Bearer <token>` header and stores them in request context. Routes can check authentication using:

```zig
// Get current user (returns null if not authenticated)
if (try BasicAuthValve.getCurrentUser(req)) |user| {
    defer {
        allocator.free(user.username);
        allocator.free(user.email);
        allocator.free(user.password_hash);
    }
    // User is authenticated
}

// Require authentication (returns error if not authenticated)
const user = try BasicAuthValve.requireAuth(req);
defer {
    allocator.free(user.username);
    allocator.free(user.email);
    allocator.free(user.password_hash);
}
```

**User Model:**

```zig
pub const User = struct {
    id: i64,
    username: []const u8,
    email: []const u8,
    password_hash: []const u8,
    created_at: i64,
};
```

**Example Usage:**

```zig
const std = @import("std");
const E12 = @import("Engine12");

// Initialize database and ORM
const db = try E12.orm.Database.open("app.db", allocator);
var orm_instance = E12.orm.ORM.init(db, allocator);

// Create auth valve
var auth_valve = E12.BasicAuthValve.init(.{
    .secret_key = "my-secret-key-change-in-production",
    .orm = &orm_instance,
});

// Register valve
try app.registerValve(&auth_valve.valve);

// Start app (migration runs automatically on app start)
try app.start();
```

**Security Features:**

- Password hashing using Argon2id
- JWT token signing with HMAC-SHA256
- Token expiration validation
- Username and email uniqueness enforcement
- Password strength validation (minimum 6 characters)
- Username length validation (3-50 characters)

### Example: Creating a Custom Valve

```zig
const std = @import("std");
const E12 = @import("Engine12");

const MyValve = struct {
    valve: E12.Valve,
    config: []const u8,

    pub fn init(config: []const u8) MyValve {
        return MyValve{
            .valve = E12.Valve{
                .metadata = E12.ValveMetadata{
                    .name = "my_valve",
                    .version = "1.0.0",
                    .description = "My custom valve",
                    .author = "My Name",
                    .required_capabilities = &[_]E12.ValveCapability{ .routes, .middleware },
                },
                .init = &MyValve.initValve,
                .deinit = &MyValve.deinitValve,
            },
            .config = config,
        };
    }

    pub fn initValve(v: *E12.Valve, ctx: *E12.ValveContext) !void {
        const self = @as(*MyValve, @ptrFromInt(@intFromPtr(v) - @offsetOf(MyValve, "valve")));
        
        // Register routes
        try ctx.registerRoute("GET", "/api/my-valve", Self.handleRequest);
        
        // Register middleware
        try ctx.registerMiddleware(&Self.myMiddleware);
        
        _ = self;
    }

    pub fn deinitValve(v: *E12.Valve) void {
        _ = v;
        // Cleanup resources
    }

    fn handleRequest(req: *E12.Request) E12.Response {
        _ = req;
        return E12.Response.json("{\"status\":\"ok\"}");
    }

    fn myMiddleware(req: *E12.Request) E12.middleware.MiddlewareResult {
        _ = req;
        return .proceed;
    }
};

// Usage
pub fn main() !void {
    var app = try E12.Engine12.initDevelopment();
    defer app.deinit();

    var my_valve = MyValve.init("config-value");
    try app.registerValve(&my_valve.valve);

    try app.start();
}
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

#### `paramTyped(comptime T: type, name: []const u8) !T`
Get a route parameter with direct type conversion. Returns an error union - fails if parameter is missing or conversion fails.

**Supported types**: `u32`, `i32`, `u64`, `i64`, `f64`, `bool`, `[]const u8`

```zig
// Integer parameter
const id = try req.paramTyped(i64, "id");

// String parameter
const slug = try req.paramTyped([]const u8, "slug");

// Boolean parameter (accepts "true"/"1" or "false"/"0")
const enabled = try req.paramTyped(bool, "enabled");
```

**Error handling**: Returns `error.ParameterMissing` if parameter is missing, or `error.InvalidArgument` if type conversion fails.

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

#### `queryParamTyped(comptime T: type, name: []const u8) !?T`
Get a query parameter with automatic type conversion. Returns an optional value - null if parameter is missing, or error if conversion fails.

**Supported types**: `u32`, `i32`, `u64`, `i64`, `f64`, `bool`, `[]const u8`

```zig
// Optional parameter with default
const page = req.queryParamTyped(u32, "page") catch 1 orelse 1;
const limit = req.queryParamTyped(u32, "limit") catch 20 orelse 20;

// Required parameter
const id = req.queryParamTyped(i64, "id") catch {
    return Response.errorResponse("Invalid ID parameter", 400);
} orelse {
    return Response.errorResponse("Missing ID parameter", 400);
};

// String parameter
const search = req.queryParamTyped([]const u8, "q") catch null;
```

**Error handling**: Returns `error.InvalidArgument` if type conversion fails. Use `catch` to handle errors and `orelse` to handle null values.

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

### Cache Access

#### `cache() ?*ResponseCache`
Get the cache instance if available. Returns null if cache is not configured.

```zig
if (req.cache()) |cache| {
    if (cache.get("my_key")) |entry| {
        return Response.text(entry.body);
    }
}
```

#### `cacheGet(key: []const u8) !?*CacheEntry`
Get a cached entry by key. Returns null if not found or expired.

```zig
if (try req.cacheGet("user:123")) |entry| {
    return Response.text(entry.body).withContentType(entry.content_type);
}
```

#### `cacheSet(key: []const u8, body: []const u8, ttl_ms: ?u64, content_type: []const u8) !void`
Store a value in the cache. Uses default TTL if `ttl_ms` is null.

```zig
const body = "{\"data\":\"value\"}";
try req.cacheSet("my_key", body, 60000, "application/json");
```

#### `cacheInvalidate(key: []const u8) void`
Invalidate a specific cache entry.

```zig
req.cacheInvalidate("user:123");
```

#### `cacheInvalidatePrefix(prefix: []const u8) void`
Invalidate all cache entries matching a prefix.

```zig
req.cacheInvalidatePrefix("user:"); // Invalidates all user:* entries
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

#### `notFound(message: []const u8) Response`
Create a 404 Not Found response with an error message.

```zig
return Response.notFound("Todo not found");
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

#### `errorResponse(message: []const u8, status_code: u16) Response`
Create an error response with a custom message and status code.

```zig
return Response.errorResponse("Invalid input", 400);
return Response.errorResponse("Unauthorized", 401);
```

#### `serverError(message: []const u8) Response`
Create a 500 Internal Server Error response with a message.

```zig
return Response.serverError("Database connection failed");
```

#### `validationError(errors: *ValidationErrors) Response`
Create a validation error response from `ValidationErrors`. Automatically serializes validation errors to JSON and sets status code to 400.

```zig
const errors = try schema.validate();
if (!errors.isEmpty()) {
    return Response.validationError(&errors);
}
```

#### `jsonFrom(comptime T: type, value: T, allocator: Allocator) Response`
Serialize a struct to JSON and return as a Response. Uses `Json.serialize` internally and handles memory management automatically.

```zig
const todo = Todo{ .id = 1, .title = "Hello", .completed = false };
return Response.jsonFrom(Todo, todo, allocator);
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
Execute all response middleware, transforming the response. Automatically adds CORS headers and Request ID headers if configured.

### Built-in Middleware

Engine12 provides built-in middleware for common use cases:

#### CORS Middleware

The CORS middleware handles Cross-Origin Resource Sharing (CORS) requests, including preflight OPTIONS requests.

**Configuration:**

```zig
const cors = cors_middleware.CorsMiddleware.init(.{
    .allowed_origins = &[_][]const u8{"http://localhost:3000", "https://example.com"},
    .allowed_methods = &[_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS" },
    .allowed_headers = &[_][]const u8{"Content-Type", "Authorization", "X-CSRF-Token"},
    .max_age = 3600,
    .allow_credentials = false,
    .exposed_headers = &[_][]const u8{"X-Request-ID"},
});

// Set global config before using middleware
cors.setGlobalConfig();

// Add middleware to app
const cors_mw_fn = cors.preflightMwFn();
try app.usePreRequest(cors_mw_fn);
```

**CorsConfig options:**
- `allowed_origins`: List of allowed origins (use `"*"` for all origins)
- `allowed_methods`: List of allowed HTTP methods
- `allowed_headers`: List of allowed request headers
- `max_age`: Preflight cache duration in seconds (default: 3600)
- `allow_credentials`: Whether to allow credentials (cookies, auth headers)
- `exposed_headers`: Headers that can be accessed by JavaScript

**How it works:**
- Pre-request middleware checks the `Origin` header and validates it against allowed origins
- For OPTIONS preflight requests, validates `Access-Control-Request-Method` and `Access-Control-Request-Headers`
- Response middleware (`executeResponse`) automatically adds CORS headers based on request context
- Preflight requests return a 204 No Content response

#### Request ID Middleware

The Request ID middleware ensures request IDs are exposed via response headers for tracing and logging.

**Configuration:**

```zig
const req_id_mw = request_id_middleware.RequestIdMiddleware.init(.{
    .header_name = "X-Request-ID", // Default
});

// Add middleware to app
const req_id_mw_fn = req_id_mw.preRequestMwFn();
try app.usePreRequest(req_id_mw_fn);
```

**How it works:**
- Request IDs are automatically generated in `Request.fromZiggurat()`
- Middleware stores the header name in request context
- Response middleware (`executeResponse`) automatically adds the Request ID header
- Request IDs can be accessed via `req.requestId()` in handlers

**Note**: Request IDs are already auto-generated. This middleware only ensures they're exposed via headers.

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

#### `findManaged(comptime T: type, id: i64) !?Result(T)`
Find a record by ID with automatic memory management. Returns a `Result` wrapper that automatically frees string fields on `deinit()`.

```zig
if (try orm.findManaged(Todo, 1)) |result| {
    defer result.deinit();
    if (result.first()) |todo| {
        // Use todo - strings are automatically freed when result.deinit() is called
    }
}
```

**Benefits**: Eliminates manual memory management for ORM results. The `Result` wrapper handles freeing all string fields automatically.

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

#### `findAllManaged(comptime T: type) !Result(T)`
Find all records with automatic memory management. Returns a `Result` wrapper that automatically frees string fields on `deinit()`.

```zig
var result = try orm.findAllManaged(Todo);
defer result.deinit();
for (result.getItems()) |todo| {
    // Use todo - strings are automatically freed when result.deinit() is called
}
```

**Result(T) methods:**
- `getItems() []const T` - Get items as a slice
- `getItemsMut() []T` - Get mutable access to items
- `len() usize` - Get the number of items
- `isEmpty() bool` - Check if empty
- `first() ?T` - Get first item, or null if empty
- `deinit() void` - Free all string fields and deinitialize

**Benefits**: Eliminates manual memory management for ORM results. The `Result` wrapper handles freeing all string fields automatically.

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

#### `runMigrationsFromRegistry(registry: *MigrationRegistry) !void`
Run migrations from a `MigrationRegistry`. This is the recommended way to manage migrations.

```zig
var registry = MigrationRegistry.init(allocator);
defer registry.deinit();

try registry.add(Migration.init(1, "create_todos", 
    "CREATE TABLE todos (...);",
    "DROP TABLE todos;"));

try orm.runMigrationsFromRegistry(&registry);
```

**Benefits**: Centralized migration management, automatic sorting by version, and easier migration organization.

#### `escapeLike(pattern: []const u8, allocator: Allocator) ![]const u8`
Escape a string for safe use in SQL LIKE patterns. Prevents SQL injection when using user input in LIKE clauses.

```zig
const search_query = req.queryParamTyped([]const u8, "q") orelse "";
const escaped_query = try orm.escapeLike(search_query, allocator);
defer allocator.free(escaped_query);

const sql = try std.fmt.allocPrint(allocator, 
    "SELECT * FROM todos WHERE title LIKE '%{s}%'", .{escaped_query});
```

**Note**: The escaped pattern must be freed by the caller using the provided allocator.

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

## Caching

Engine12 provides a built-in response cache for storing and retrieving cached responses. The cache supports TTL-based expiration, ETag generation, and prefix-based invalidation.

### Initialization

#### `ResponseCache.init(allocator: Allocator, default_ttl_ms: u64) ResponseCache`
Initialize a response cache with a default TTL in milliseconds.

```zig
var cache = ResponseCache.init(allocator, 60000); // 60 second default TTL
defer cache.deinit();
app.setCache(&cache);
```

### Cache Entry

#### `CacheEntry`
A cache entry contains:
- `body: []const u8` - Cached response body
- `etag: []const u8` - ETag value for cache validation
- `content_type: []const u8` - Content type of the cached response
- `ttl_ms: u64` - Time-to-live in milliseconds
- `expires_at: i64` - Expiration timestamp
- `last_modified: i64` - Last modified timestamp

### Cache Operations

#### `get(key: []const u8) ?*CacheEntry`
Get a cached entry by key. Returns null if not found or expired.

```zig
if (cache.get("user:123")) |entry| {
    // Use cached entry
    std.debug.print("Cached: {s}\n", .{entry.body});
}
```

#### `set(key: []const u8, body: []const u8, ttl_ms: ?u64, content_type: []const u8) !void`
Store a response in the cache. Uses default TTL if `ttl_ms` is null.

```zig
try cache.set("user:123", json_data, 60000, "application/json");
```

#### `invalidate(key: []const u8) void`
Invalidate a specific cache entry.

```zig
cache.invalidate("user:123");
```

#### `invalidatePrefix(prefix: []const u8) void`
Invalidate all cache entries matching a prefix.

```zig
cache.invalidatePrefix("user:"); // Invalidates all user:* entries
```

#### `cleanup() void`
Remove all expired entries from the cache.

```zig
cache.cleanup();
```

### Request Cache Methods

Cache operations are also available directly from Request objects:

```zig
fn handleGetUser(req: *Request) Response {
    // Check cache first
    if (try req.cacheGet("user:123")) |entry| {
        return Response.text(entry.body)
            .withContentType(entry.content_type);
    }
    
    // Generate response
    const user_data = generateUserData();
    
    // Cache it
    try req.cacheSet("user:123", user_data, 60000, "application/json");
    
    return Response.json(user_data);
}

fn handleUpdateUser(req: *Request) Response {
    // ... update logic ...
    
    // Invalidate cached user data
    req.cacheInvalidate("user:123");
    
    return Response.json("{\"updated\":true}");
}
```

### Cache Configuration

The cache is configured globally via `setCache()`:

```zig
var cache = ResponseCache.init(allocator, 60000); // 60 second default TTL
app.setCache(&cache);
```

Once configured, all Request objects can access the cache via `req.cache()`, `req.cacheGet()`, `req.cacheSet()`, etc.

## Pagination Helper

The pagination helper provides utilities for parsing pagination parameters and generating pagination metadata for API responses.

### Pagination Struct

#### `Pagination.fromRequest(req: *Request) !Pagination`
Create pagination from request query parameters. Defaults to `page=1` and `limit=20` if not provided.

**Validation:**
- `page` must be >= 1
- `limit` must be between 1 and 100

```zig
const pagination = Pagination.fromRequest(request) catch {
    return Response.errorResponse("Invalid pagination parameters", 400);
};

// Use pagination values
const todos = try orm.queryBuilder(Todo)
    .limit(pagination.limit)
    .offset(pagination.offset)
    .build();
```

**Pagination fields:**
- `page: u32` - Current page number (1-indexed)
- `limit: u32` - Number of items per page
- `offset: u32` - Calculated offset for database queries

#### `Pagination.toResponse(total: u32) PaginationMeta`
Generate pagination metadata for JSON responses.

```zig
const pagination = Pagination.fromRequest(request) catch {
    return Response.errorResponse("Invalid pagination", 400);
};

const todos = try fetchTodos(pagination.limit, pagination.offset);
const total = try countTodos();

const meta = pagination.toResponse(total);

// Include in response
const PaginatedResponse = struct {
    data: []const Todo,
    meta: PaginationMeta,
};

return Response.jsonFrom(PaginatedResponse, .{
    .data = todos.items,
    .meta = meta,
}, allocator);
```

**PaginationMeta fields:**
- `page: u32` - Current page number
- `limit: u32` - Items per page
- `total: u32` - Total number of items
- `total_pages: u32` - Total number of pages

**Example usage:**

```zig
fn handleGetTodos(req: *Request) Response {
    const pagination = Pagination.fromRequest(req) catch {
        return Response.errorResponse("Invalid pagination", 400);
    };

    const orm = getORM() catch {
        return Response.serverError("Database error");
    };

    // Fetch paginated results
    var builder = QueryBuilder.init(req.allocator(), "todos");
    defer builder.deinit();
    const sql = builder
        .limit(pagination.limit)
        .offset(pagination.offset)
        .build() catch {
            return Response.serverError("Query error");
        };
    defer req.allocator().free(sql);

    const todos = try orm.query(sql);
    defer todos.deinit();

    // Get total count
    const total_result = try orm.query("SELECT COUNT(*) FROM todos");
    defer total_result.deinit();
    const total = total_result.nextRow().?.getInt64(0);

    // Generate metadata
    const meta = pagination.toResponse(@intCast(total));

    // Return paginated response
    return Response.jsonFrom(PaginatedResponse, .{
        .data = todos.items,
        .meta = meta,
    }, req.allocator());
}
```

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

