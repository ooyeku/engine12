# API Reference

Complete reference for Engine12's public APIs.

## Table of Contents

- [Engine12 Core](#engine12-core)
- [RESTful API Resource](#restful-api-resource)
- [Handler Context](#handler-context)
- [Valve System](#valve-system)
- [Request API](#request-api)
- [Response API](#response-api)
- [Middleware System](#middleware-system)
- [ORM API](#orm-api)
- [Database API](#database-api)
- [Migration API](#migration-api)
- [Auto-Discovery Features](#auto-discovery-features)
  - [Migration Auto-Discovery](#migration-auto-discovery)
  - [Static File Auto-Discovery](#static-file-auto-discovery)
  - [Template Auto-Discovery](#template-auto-discovery)
- [Query Builder](#query-builder)
- [Template Engine](#template-engine)
- [File Server](#file-server)
- [Rate Limiting](#rate-limiting)
- [CSRF Protection](#csrf-protection)
- [Caching](#caching)
- [Pagination Helper](#pagination-helper)
- [Metrics & Health Checks](#metrics--health-checks)
- [Background Tasks](#background-tasks)
- [WebSocket API](#websocket-api)
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

### RESTful API Resource

#### `restApi(prefix: []const u8, comptime Model: type, config: RestApiConfig) !void`
Generate complete RESTful CRUD endpoints for a model with built-in support for filtering, sorting, pagination, authentication, authorization, validation, and caching.

This function automatically generates 5 endpoints:
- `GET {prefix}` - List all resources (with filtering, sorting, pagination)
- `GET {prefix}/:id` - Get a single resource by ID
- `POST {prefix}` - Create a new resource
- `PUT {prefix}/:id` - Update a resource by ID
- `DELETE {prefix}/:id` - Delete a resource by ID

**RestApiConfig**:
```zig
pub const RestApiConfig = struct {
    /// ORM instance (required)
    orm: *ORM,
    /// Validator function that validates a model instance from request
    validator: *const fn (*Request, anytype) !ValidationErrors,
    /// Optional authentication function
    authenticator: ?*const fn (*Request) !AuthUser = null,
    /// Optional authorization function for GET/PUT/DELETE by ID
    authorization: ?*const fn (*Request, anytype) !bool = null,
    /// Optional cache TTL in milliseconds
    cache_ttl_ms: ?u32 = null,
    /// Enable pagination (default: true)
    enable_pagination: bool = true,
    /// Enable filtering via ?filter=field:value (default: true)
    enable_filtering: bool = true,
    /// Enable sorting via ?sort=field:asc|desc (default: true)
    enable_sorting: bool = true,
    /// Optional hook called before creating a record
    before_create: ?*const fn (*Request, anytype) !anytype = null,
    /// Optional hook called after creating a record
    after_create: ?*const fn (*Request, anytype) void = null,
    /// Optional hook called before updating a record
    before_update: ?*const fn (*Request, i64, anytype) !anytype = null,
    /// Optional hook called after updating a record
    after_update: ?*const fn (*Request, anytype) void = null,
    /// Optional hook called before deleting a record
    before_delete: ?*const fn (*Request, i64) !void = null,
};
```

**Example: Basic Usage**
```zig
const Todo = struct {
    id: i64,
    title: []const u8,
    description: []const u8,
    completed: bool,
    created_at: i64,
};

fn validateTodo(req: *Request, todo: Todo) !ValidationErrors {
    var errors = ValidationErrors.init(req.arena.allocator());
    if (todo.title.len == 0) {
        try errors.add("title", "Title is required", "required");
    }
    if (todo.title.len > 200) {
        try errors.add("title", "Title must be less than 200 characters", "max_length");
    }
    return errors;
}

fn requireAuth(req: *Request) !AuthUser {
    // Your authentication logic here
    // Return AuthUser or error
}

fn canAccessTodo(req: *Request, todo: Todo) !bool {
    // Your authorization logic here
    // Return true if user can access, false otherwise
}

try app.restApi("/api/todos", Todo, .{
    .orm = &my_orm,
    .validator = validateTodo,
    .authenticator = requireAuth,
    .authorization = canAccessTodo,
    .enable_pagination = true,
    .enable_filtering = true,
    .enable_sorting = true,
    .cache_ttl_ms = 30000, // 30 seconds
});
```

**Query Parameters**:

**Filtering** (`?filter=field:value`):
- Multiple filters are combined with AND logic
- Example: `GET /api/todos?filter=completed:true&filter=priority:high`
- Field names are validated against the model struct fields

**Sorting** (`?sort=field:asc` or `?sort=field:desc`):
- Example: `GET /api/todos?sort=created_at:desc`
- Field names are validated against the model struct fields
- Direction must be either "asc" or "desc"

**Pagination** (`?page=1&limit=20`):
- Default: page=1, limit=20
- Validates: page >= 1, limit between 1 and 100
- Response includes pagination metadata:
```json
{
  "data": [...],
  "meta": {
    "page": 1,
    "limit": 20,
    "total": 100,
    "total_pages": 5
  }
}
```

**Response Formats**:

- **GET /prefix** (List): Returns `{data: [...], meta: {...}}` with pagination metadata
- **GET /prefix/:id** (Show): Returns single resource JSON
- **POST /prefix** (Create): Returns created resource with status 201
- **PUT /prefix/:id** (Update): Returns updated resource
- **DELETE /prefix/:id** (Delete): Returns 204 No Content

**Caching**:
- When `cache_ttl_ms` is provided, responses are cached
- Cache keys include user ID (if authenticated), filters, sort, and pagination
- Cache is automatically invalidated on create/update/delete operations
- Cache hit/miss is indicated by `X-Cache` header

**Hooks**:
- `before_create`: Called before creating a record, can modify the model
- `after_create`: Called after creating a record
- `before_update`: Called before updating a record, can modify the model
- `after_update`: Called after updating a record
- `before_delete`: Called before deleting a record, can prevent deletion by returning an error

**OpenAPI Integration**:
- When OpenAPI documentation is enabled, `restApi` automatically registers all CRUD endpoints with the OpenAPI generator
- Schemas are automatically generated from your model structs using Zig's comptime reflection
- All endpoints are documented with request/response schemas, parameters, and descriptions

### OpenAPI Documentation

Engine12 provides automatic OpenAPI 3.0 specification generation and Swagger UI integration. This feature automatically introspects your `restApi` resources and generates complete API documentation.

#### `enableOpenApiDocs(mount_path: []const u8, info: OpenApiInfo) !void`

Enable OpenAPI documentation generation and serve Swagger UI. This registers two endpoints:
- `GET {mount_path}/openapi.json` - Serves the generated OpenAPI 3.0 JSON specification
- `GET {mount_path}` - Serves an HTML page with embedded Swagger UI

**OpenApiInfo**:
```zig
pub const OpenApiInfo = struct {
    title: []const u8,           // API title (e.g., "My API")
    version: []const u8,         // API version (e.g., "1.0.0")
    description: ?[]const u8 = null, // Optional API description
};
```

**Example: Basic Usage**
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

    // Register REST API resources (automatically added to OpenAPI spec)
    try app.restApi("/api/todos", Todo, .{
        .orm = &my_orm,
        .validator = validateTodo,
    });

    try app.start();
}
```

After starting the server, visit `http://127.0.0.1:8080/docs` to view the interactive Swagger UI documentation.

**How It Works**:

1. **Automatic Schema Generation**: When you call `restApi()`, Engine12 automatically:
   - Generates OpenAPI schemas from your model structs using Zig's comptime reflection
   - Maps Zig types to OpenAPI types (e.g., `i64` → `integer`, `[]const u8` → `string`, `bool` → `boolean`)
   - Handles optional fields, arrays, and nested structs
   - Registers schemas in the `components.schemas` section

2. **CRUD Endpoint Documentation**: For each `restApi` resource, the following endpoints are automatically documented:
   - `GET {prefix}` - List endpoint with query parameters (filter, sort, pagination)
   - `GET {prefix}/{id}` - Get by ID endpoint with path parameter
   - `POST {prefix}` - Create endpoint with request body schema
   - `PUT {prefix}/{id}` - Update endpoint with path parameter and request body
   - `DELETE {prefix}/{id}` - Delete endpoint with path parameter

3. **Type Mapping**: The OpenAPI generator maps Zig types to OpenAPI types:
   - `i32`, `i64` → `integer` (with appropriate format: `int32` or `int64`)
   - `f32`, `f64` → `number` (with appropriate format: `float` or `double`)
   - `bool` → `boolean`
   - `[]const u8` → `string`
   - `?T` → `T` with `nullable: true`
   - `[]T` → `array` with items schema
   - Structs → `object` with properties schema

**Example: Custom API Info**
```zig
try app.enableOpenApiDocs("/api-docs", .{
    .title = "My Application API",
    .version = "2.1.0",
    .description = "Complete API documentation for My Application",
});
```

**Accessing the Documentation**:

- **Swagger UI**: Visit `http://127.0.0.1:8080/docs` (or your configured mount path)
- **OpenAPI JSON**: Visit `http://127.0.0.1:8080/docs/openapi.json` to get the raw OpenAPI specification

The Swagger UI provides an interactive interface where you can:
- Browse all available endpoints
- View request/response schemas
- Test API endpoints directly from the browser
- See example request/response payloads

**Integration with restApi**:

When you use `restApi()`, endpoints are automatically registered with the OpenAPI generator. No additional configuration is needed - just enable OpenAPI docs and your REST APIs will be documented automatically.

```zig
// Enable OpenAPI docs first
try app.enableOpenApiDocs("/docs", .{
    .title = "My API",
    .version = "1.0.0",
});

// All restApi calls after this will be automatically documented
try app.restApi("/api/todos", Todo, config);
try app.restApi("/api/users", User, config);
try app.restApi("/api/posts", Post, config);
```

**Note**: OpenAPI documentation is generated at runtime based on your registered routes. If you add or remove `restApi` resources, the documentation will reflect those changes automatically.

## Handler Context

The `HandlerCtx` abstraction provides a high-level interface for writing handlers that reduces boilerplate code by 70-80%. It automatically handles common patterns like authentication, ORM access, parameter parsing, caching, and logging.

### Overview

`HandlerCtx` wraps a `Request` and provides convenient methods for common handler operations. It eliminates repetitive code patterns while maintaining Zig's type safety and zero-cost principles.

**Benefits:**
- **70-80% code reduction**: Eliminates repetitive authentication, ORM access, and parameter parsing boilerplate
- **Consistent error handling**: Standardized error responses with automatic logging
- **Type safety**: Maintains Zig's compile-time guarantees
- **Memory safety**: Automatic memory management via request arena allocator
- **Better developer experience**: Cleaner, more maintainable handler code

### Initialization

#### `init(req: *Request, options: struct) HandlerCtxError!HandlerCtx`

Initialize a HandlerCtx from a request with optional requirements.

**Options:**
- `require_auth: bool = false` - If true, authentication is required (returns error if not authenticated)
- `require_orm: bool = false` - If true, ORM must be available (returns error if not available)
- `get_orm: ?*const fn () anyerror!*ORM = null` - Optional function to get ORM instance

**Example: Basic Usage**
```zig
fn handleProtected(req: *Request) Response {
    var ctx = HandlerCtx.init(req, .{
        .require_auth = true,
        .require_orm = true,
        .get_orm = getORM, // Your app's ORM getter function
    }) catch |err| {
        return switch (err) {
            error.AuthenticationRequired => Response.errorResponse("Authentication required", 401),
            error.DatabaseNotInitialized => Response.serverError("Database not initialized"),
            else => Response.serverError("Internal error"),
        };
    };
    
    const user = ctx.user.?; // Safe because require_auth = true
    const orm = ctx.orm() catch unreachable; // Safe because require_orm = true
    
    // Your handler logic here
    return Response.text("Hello, authenticated user!");
}
```

**Example: Optional Authentication**
```zig
fn handlePublic(req: *Request) Response {
    var ctx = HandlerCtx.init(req, .{}) catch |err| {
        return Response.serverError("Failed to initialize context");
    };
    
    // Authentication is optional - check if user exists
    if (ctx.getAuth() catch null) |user| {
        return Response.text("Hello, authenticated user!");
    }
    
    return Response.text("Hello, anonymous user!");
}
```

### Authentication

#### `requireAuth() HandlerCtxError!AuthUser`

Require authentication or return error. Converts `BasicAuthValve.User` to `AuthUser` with arena-allocated strings (automatically freed with request).

```zig
var ctx = HandlerCtx.init(req, .{}) catch return Response.serverError("Failed to initialize");
const user = ctx.requireAuth() catch {
    return ctx.unauthorized("Authentication required");
};
// user.username, user.email, user.password_hash are available
```

#### `getAuth() HandlerCtxError!?AuthUser`

Get authenticated user (optional, doesn't error if not authenticated).

```zig
var ctx = HandlerCtx.init(req, .{}) catch return Response.serverError("Failed to initialize");
if (ctx.getAuth() catch null) |user| {
    // User is authenticated
} else {
    // User is not authenticated
}
```

### ORM Access

#### `orm() HandlerCtxError!*ORM`

Get ORM instance. Returns error if ORM is not available.

```zig
var ctx = HandlerCtx.init(req, .{
    .require_orm = true,
    .get_orm = getORM,
}) catch return Response.serverError("Failed to initialize");

const orm = ctx.orm() catch {
    return ctx.serverError("Database not initialized");
};
```

### Parameter Parsing

#### `query(comptime T: type, name: []const u8) HandlerCtxError!T`

Parse query parameter with better error messages. Returns error if parameter is missing or invalid.

```zig
var ctx = HandlerCtx.init(req, .{}) catch return Response.serverError("Failed to initialize");

const search_query = ctx.query([]const u8, "q") catch {
    return ctx.badRequest("Missing or invalid query parameter 'q'");
};

const limit = ctx.query(i32, "limit") catch {
    return ctx.badRequest("Missing or invalid query parameter 'limit'");
};
```

#### `queryOrDefault(comptime T: type, name: []const u8, default: T) T`

Parse query parameter with default value. Returns default if parameter is missing or invalid.

```zig
var ctx = HandlerCtx.init(req, .{}) catch return Response.serverError("Failed to initialize");

const limit = ctx.queryOrDefault(i32, "limit", 10); // Defaults to 10 if missing
const page = ctx.queryOrDefault(i32, "page", 1);   // Defaults to 1 if missing
```

#### `param(comptime T: type, name: []const u8) HandlerCtxError!T`

Get route parameter. Returns error if parameter is missing or invalid.

```zig
// Route: GET /todos/:id
var ctx = HandlerCtx.init(req, .{}) catch return Response.serverError("Failed to initialize");

const todo_id = ctx.param(i64, "id") catch {
    return ctx.badRequest("Invalid todo ID");
};
```

#### `json(comptime T: type) HandlerCtxError!T`

Parse JSON body. Returns error if JSON is invalid.

```zig
var ctx = HandlerCtx.init(req, .{}) catch return Response.serverError("Failed to initialize");

const todo = ctx.json(TodoInput) catch {
    return ctx.badRequest("Invalid JSON body");
};
```

### Caching

#### `cacheKey(comptime pattern: []const u8) ![]const u8`

Build cache key with user context. Automatically includes user_id if user is authenticated. The pattern must be a comptime-known string and should use `{d}` placeholder for user_id.

**Note**: This method only supports a single `{d}` placeholder for user_id. For cache keys with multiple values, use `std.fmt.allocPrint` directly with `request.arena.allocator()`.

```zig
var ctx = HandlerCtx.init(req, .{ .require_auth = true }) catch return Response.serverError("Failed to initialize");

const cache_key = ctx.cacheKey("todos:stats:{d}") catch {
    return ctx.serverError("Failed to create cache key");
};
// If user.id = 123, cache_key = "todos:stats:123"

// For multiple values, use std.fmt.allocPrint directly:
const std = @import("std");
const user = ctx.user.?;
const search_query = ctx.query([]const u8, "q") catch return ctx.badRequest("Missing query parameter");
const complex_key = std.fmt.allocPrint(ctx.request.arena.allocator(), "todos:search:{d}:{s}", .{ user.id, search_query }) catch {
    return ctx.serverError("Failed to create cache key");
};
```

#### `cacheGet(key: []const u8) !?*CacheEntry`

Check cache and return cache entry if hit. Returns an error if cache access fails, or null if not found.

```zig
const cache_key = ctx.cacheKey("todos:stats:{d}") catch return ctx.serverError("Failed to create cache key");

if (ctx.cacheGet(cache_key) catch null) |entry| {
    return Response.text(entry.body)
        .withContentType(entry.content_type)
        .withHeader("X-Cache", "HIT");
}
```

#### `cacheSet(key: []const u8, value: []const u8, ttl_ms: u32, content_type: []const u8) void`

Set cache entry.

```zig
ctx.cacheSet(cache_key, json_data, 10000, "application/json");
```

#### `cacheInvalidate(key: []const u8) void`

Invalidate cache entry.

```zig
ctx.cacheInvalidate(cache_key);
```

### Logging

#### `log(level: LogLevel, message: []const u8) void`

Log message with context (user_id if authenticated, request_id if available).

```zig
var ctx = HandlerCtx.init(req, .{ .require_auth = true }) catch return Response.serverError("Failed to initialize");

ctx.log(.info, "Todo created successfully");
ctx.log(.warn, "Rate limit approaching");
ctx.log(.err, "Database connection failed");
```

### Error Responses

HandlerCtx provides convenient methods for common HTTP error responses with automatic logging:

#### `errorResponse(message: []const u8, status: u16) Response`

Return error response with automatic logging (log level determined by status code).

```zig
return ctx.errorResponse("Resource not found", 404);
return ctx.errorResponse("Invalid input", 400);
return ctx.errorResponse("Internal server error", 500);
```

#### `unauthorized(message: []const u8) Response`

Return 401 Unauthorized response.

```zig
return ctx.unauthorized("Authentication required");
```

#### `forbidden(message: []const u8) Response`

Return 403 Forbidden response.

```zig
return ctx.forbidden("You don't have permission to access this resource");
```

#### `badRequest(message: []const u8) Response`

Return 400 Bad Request response.

```zig
return ctx.badRequest("Invalid query parameter");
```

#### `notFound(message: []const u8) Response`

Return 404 Not Found response.

```zig
return ctx.notFound("Todo not found");
```

#### `serverError(message: []const u8) Response`

Return 500 Internal Server Error response.

```zig
return ctx.serverError("Database connection failed");
```

### Success Responses

#### `jsonResponse(data: anytype) Response`

Return JSON response from data.

```zig
const todo = Todo{ .id = 1, .title = "Example" };
return ctx.jsonResponse(todo);
```

#### `success(data: anytype, status: u16) Response`

Return success response with JSON data and custom status code.

```zig
return ctx.success(todo, 200);
```

#### `created(data: anytype) Response`

Return 201 Created response with JSON data.

```zig
const new_todo = createTodo(input) catch return ctx.serverError("Failed to create todo");
return ctx.created(new_todo);
```

### Complete Example

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

    const search_query = request.queryParamTyped([]const u8, "q") catch {
        return Response.errorResponse("Invalid query parameter", 400);
    } orelse {
        return Response.errorResponse("Missing query parameter", 400);
    };

    const orm = getORM() catch {
        return Response.serverError("Database not initialized");
    };
    
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

    const orm = ctx.orm() catch unreachable; // Safe because require_orm = true
    const user = ctx.user.?; // Safe because require_auth = true
    
    // ... rest of handler logic - much cleaner!
}
```

### Error Types

```zig
pub const HandlerCtxError = error{
    AuthenticationRequired,      // User is not authenticated
    DatabaseNotInitialized,      // ORM is not available
    InvalidQueryParameter,       // Query parameter parsing failed
    MissingQueryParameter,       // Required query parameter is missing
    InvalidRouteParameter,       // Route parameter parsing failed
    InvalidJSON,                 // JSON body parsing failed
};
```

### Integration with restApi

HandlerCtx works alongside `restApi` - it doesn't replace it. Use HandlerCtx for custom handlers that need more control than `restApi` provides.

```zig
// Use restApi for standard CRUD operations
try app.restApi("/api/todos", Todo, config);

// Use HandlerCtx for custom endpoints
try app.get("/api/todos/search", handleSearchTodos);
try app.get("/api/todos/stats", handleGetStats);
```

### Migration Path

HandlerCtx is optional - existing handlers continue to work. You can adopt it incrementally:

1. Start with new handlers using HandlerCtx
2. Gradually refactor existing handlers
3. Mix HandlerCtx handlers with traditional handlers
4. Works alongside restApi without conflicts

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

#### `discoverStaticFiles(static_dir: []const u8) !void`

Auto-discover and register static files from a directory structure. Scans the `static/` directory for subdirectories and automatically registers them as static routes.

**Convention**: `static/css/` → `/css/*`, `static/js/` → `/js/*`, `static/images/` → `/images/*`

```zig
// Auto-discover all static directories
try app.discoverStaticFiles("static");
// Automatically registers:
// - static/css/ -> /css/*
// - static/js/ -> /js/*
// - static/images/ -> /images/*
```

**Behavior**:
- Only processes subdirectories (skips files)
- Skips hidden directories (starting with `.`)
- Creates mount paths based on directory names
- Uses existing `serveStatic()` internally
- Fails gracefully if directory doesn't exist (logs warning, continues)

**Example Directory Structure**:
```
static/
├── css/
│   └── style.css
├── js/
│   └── app.js
└── images/
    └── logo.png
```

After calling `discoverStaticFiles("static")`, these routes are automatically registered:
- `/css/style.css` → serves `static/css/style.css`
- `/js/app.js` → serves `static/js/app.js`
- `/images/logo.png` → serves `static/images/logo.png`

**Error Handling**:
- Missing `static/` directory: logs warning, returns without error
- Permission errors: logs warning, skips problematic directories
- Individual directory registration failures: logs warning, continues with others

**Best Practice**: Call `discoverStaticFiles()` early in your application setup, before registering custom routes that might conflict.

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
- `.websockets` - Handle WebSocket connections
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

#### `loadTemplate(template_path: []const u8) !*RuntimeTemplate`
Load a template file for hot reloading (development mode only). Returns a `RuntimeTemplate` that automatically reloads when the file changes.

```zig
const template = try app.loadTemplate("templates/index.zt.html");
const content = try template.getContentString();
```

**Note:** Hot reloading is only available in development mode. In production, use comptime templates with `@embedFile` for type safety.

#### `serveStatic(mount_path: []const u8, directory: []const u8) !void`
Serve static files from a directory. In development mode, cache is automatically disabled for hot reloading. Requires `.static_files` capability.

```zig
try ctx.serveStatic("/static", "./public");
```

#### `registerWebSocket(path: []const u8, handler: WebSocketHandler) !void`
Register a WebSocket endpoint. Requires `.websockets` capability.

```zig
fn handleChat(conn: *websocket.WebSocketConnection) void {
    // Connection established
}
try ctx.registerWebSocket("/ws/chat", handleChat);
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
Unregister a valve by name. Automatically cleans up all routes registered by the valve, calls `valve.deinit()`, and removes from registry. Thread-safe.

**Automatic Route Cleanup**: When a valve is unregistered, all HTTP routes it registered are automatically removed from the runtime route registry. This prevents orphaned routes and ensures clean unregistration.

```zig
try registry.unregister("my_valve");
// All routes registered by "my_valve" are automatically cleaned up
```

#### `getContext(name: []const u8) ?*ValveContext`
Get context for a valve by name. Returns null if valve not found. Thread-safe.

```zig
if (registry.getContext("my_valve")) |ctx| {
    try ctx.registerRoute("GET", "/test", handler);
}
```

#### `getValveNames(allocator: Allocator) ![]const []const u8`
Get all registered valve names. Returns a slice allocated with the provided allocator. Thread-safe.

```zig
const names = try registry.getValveNames(allocator);
defer allocator.free(names);
for (names) |name| {
    std.debug.print("Valve: {s}\n", .{name});
}
```

#### `getValveState(name: []const u8) ?ValveState`
Get the current state of a valve by name. Returns null if valve not found. Thread-safe.

```zig
if (registry.getValveState("my_valve")) |state| {
    switch (state) {
        .registered => std.debug.print("Valve registered\n", .{}),
        .initialized => std.debug.print("Valve initialized\n", .{}),
        .started => std.debug.print("Valve started\n", .{}),
        .stopped => std.debug.print("Valve stopped\n", .{}),
        .failed => std.debug.print("Valve failed\n", .{}),
    }
}
```

#### `getErrorInfo(name: []const u8) ?ValveErrorInfo`
Get structured error information for a valve by name. Returns null if no error or valve not found. Thread-safe.

```zig
if (registry.getErrorInfo("my_valve")) |error_info| {
    std.debug.print("Error phase: {}\n", .{error_info.phase});
    std.debug.print("Error type: {s}\n", .{error_info.error_type});
    std.debug.print("Error message: {s}\n", .{error_info.message});
    std.debug.print("Timestamp: {}\n", .{error_info.timestamp});
}
```

#### `getValveErrors(name: []const u8) []const u8`
Get error message for a valve by name. Returns empty string if no error or valve not found. Returns the error message from structured error info for backward compatibility. Thread-safe.

**Note**: For structured error information, use `getErrorInfo()` instead.

```zig
const error_msg = registry.getValveErrors("my_valve");
if (error_msg.len > 0) {
    std.debug.print("Error: {s}\n", .{error_msg});
}
```

#### `isValveHealthy(name: []const u8) bool`
Check if a valve is healthy (not failed). Returns false if valve not found or failed. Thread-safe.

```zig
if (registry.isValveHealthy("my_valve")) {
    std.debug.print("Valve is healthy\n", .{});
} else {
    std.debug.print("Valve is unhealthy or not found\n", .{});
}
```

#### `getFailedValves(allocator: Allocator) ![]const []const u8`
Get all failed valve names. Returns a slice allocated with the provided allocator. Thread-safe.

```zig
const failed = try registry.getFailedValves(allocator);
defer allocator.free(failed);
for (failed) |name| {
    std.debug.print("Failed valve: {s}\n", .{name});
}
```

### Valve Error Information

#### `ValveErrorPhase`
Enum indicating the phase in valve lifecycle where an error occurred.

- `.init` - Error during valve initialization (init callback)
- `.start` - Error during app start (onAppStart callback)
- `.stop` - Error during app stop (onAppStop callback)
- `.runtime` - Error during runtime operation

#### `ValveErrorInfo`
Structured error information providing detailed context for debugging and monitoring.

```zig
pub const ValveErrorInfo = struct {
    phase: ValveErrorPhase,        // Phase where error occurred
    error_type: []const u8,        // Error type name (e.g., "OutOfMemory")
    message: []const u8,           // Human-readable error message
    timestamp: i64,                // Unix timestamp in milliseconds
    
    pub fn deinit(self: *ValveErrorInfo, allocator: Allocator) void;
    pub fn format(self: *const ValveErrorInfo, allocator: Allocator) ![]const u8;
};
```

**Example**:
```zig
if (registry.getErrorInfo("my_valve")) |error_info| {
    // Access structured error information
    std.debug.print("Phase: {}\n", .{error_info.phase});
    std.debug.print("Type: {s}\n", .{error_info.error_type});
    std.debug.print("Message: {s}\n", .{error_info.message});
    
    // Format as string
    const formatted = try error_info.format(allocator);
    defer allocator.free(formatted);
    std.debug.print("Formatted: {s}\n", .{formatted});
}
```

### Thread Safety

All `ValveRegistry` query methods are thread-safe and protected by a mutex:
- `getContext()`
- `getValveState()`
- `getValveErrors()`
- `getErrorInfo()`
- `isValveHealthy()`
- `getFailedValves()`
- `getValveNames()`
- `register()`
- `unregister()`

This ensures safe concurrent access to valve registry state from multiple threads.

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

The valve provides handler functions that must be manually registered on your Engine12 app. Route registration through the valve context is not yet implemented.

- `POST /auth/register` - Register a new user (requires username, email, password)
- `POST /auth/login` - Login and receive JWT token (requires username/email and password)
- `POST /auth/logout` - Logout (returns success)
- `GET /auth/me` - Get current authenticated user info (requires valid JWT token)

**Route Registration:**

After registering the valve, you must manually register the routes:

```zig
// Register valve
try app.registerValve(&auth_valve.valve);

// Manually register auth routes
try app.post("/auth/register", BasicAuthValve.handleRegister);
try app.post("/auth/login", BasicAuthValve.handleLogin);
try app.post("/auth/logout", BasicAuthValve.handleLogout);
try app.get("/auth/me", BasicAuthValve.handleGetMe);
```

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

**Error handling**: Returns `error.InvalidArgument` if parameter is missing or type conversion fails.

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

The ORM maps columns to struct fields by name, not by position. This means column order in your queries doesn't need to match struct field order - the ORM will automatically match columns by name.

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
Find a record by ID. Columns are mapped to struct fields by name, so column order doesn't matter.

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
- All struct fields have corresponding columns (by name)
- Field types are compatible with column types
- Null values are handled correctly for optional/non-optional fields

**Column Mapping**: Columns are mapped to struct fields by name, so column order in the query doesn't matter. Extra columns in the query result are ignored.

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

**Column Mapping**: Columns are mapped to struct fields by name, so column order doesn't matter.

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
Execute a SELECT query. Columns are mapped to struct fields by name, so column order in your SELECT statement doesn't matter.

**Example**:
```zig
// Column order doesn't matter - ORM maps by name
var result = try orm.query("SELECT id, title, completed FROM todos WHERE completed = 1");
defer result.deinit();

// SELECT * also works - columns are matched by name
var result2 = try orm.query("SELECT * FROM todos WHERE completed = 1");
defer result2.deinit();
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

## Auto-Discovery Features

Engine12 provides auto-discovery features that reduce boilerplate by automatically discovering and registering migrations, static files, and templates based on directory structure and naming conventions. All features are opt-in and gracefully handle missing directories/files.

### Migration Auto-Discovery

Engine12 provides automatic migration discovery to simplify migration management. This feature scans your migrations directory and automatically loads migrations, reducing boilerplate code.

#### `discoverMigrations(allocator: Allocator, migrations_dir: []const u8) !MigrationRegistry`

Automatically discover and load migrations from a directory. Supports two approaches:

1. **Convention-based**: If `migrations/init.zig` exists, it's detected (though you should use `@import()` for comptime safety)
2. **File scanning**: Scans for numbered migration files matching pattern `{number}_{name}.zig`

```zig
const migration_discovery = @import("engine12").orm.migration_discovery;

// Discover migrations from directory
var registry = try migration_discovery.discoverMigrations(allocator, "src/migrations");
defer registry.deinit();

// Run discovered migrations
try orm.runMigrationsFromRegistry(&registry);
```

**Migration File Naming Convention**:
- Files must match pattern: `{number}_{name}.zig`
- Example: `1_create_users.zig`, `2_add_email.zig`
- Files are automatically sorted by version number
- `init.zig` is skipped during scanning (use it for manual imports)

**Migration File Format**:
Each migration file should export a migration constant:

```zig
// migrations/1_create_users.zig
pub const migration = Migration.init(
    1,
    "create_users",
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);",
    "DROP TABLE users;"
);
```

**Error Handling**:
- Missing directories return empty registry (no error)
- Invalid migration files are skipped with warnings
- Continues processing even if individual migrations fail to parse

**Benefits**:
- No manual migration registration
- Automatic version sorting
- Easy to add new migrations (just create a file)
- Works alongside manual migration management

### Static File Auto-Discovery

#### `discoverStaticFiles(static_dir: []const u8) !void`

Auto-discover and register static files from a directory structure. Scans the `static/` directory for subdirectories and automatically registers them as static routes.

**Convention**: `static/css/` → `/css/*`, `static/js/` → `/js/*`, `static/images/` → `/images/*`

```zig
// Auto-discover all static directories
try app.discoverStaticFiles("static");
// Automatically registers:
// - static/css/ -> /css/*
// - static/js/ -> /js/*
// - static/images/ -> /images/*
```

**Behavior**:
- Only processes subdirectories (skips files)
- Skips hidden directories (starting with `.`)
- Creates mount paths based on directory names
- Uses existing `serveStatic()` internally
- Fails gracefully if directory doesn't exist (logs warning, continues)

**Example Directory Structure**:
```
static/
├── css/
│   └── style.css
├── js/
│   └── app.js
└── images/
    └── logo.png
```

After calling `discoverStaticFiles("static")`, these routes are automatically registered:
- `/css/style.css` → serves `static/css/style.css`
- `/js/app.js` → serves `static/js/app.js`
- `/images/logo.png` → serves `static/images/logo.png`

**Error Handling**:
- Missing `static/` directory: logs warning, returns without error
- Permission errors: logs warning, skips problematic directories
- Individual directory registration failures: logs warning, continues with others

**Best Practice**: Call `discoverStaticFiles()` early in your application setup, before registering custom routes that might conflict.

### Template Auto-Discovery

#### `discoverTemplates(templates_dir: []const u8) !TemplateRegistry`

Auto-discover and load templates from a directory. Scans the `templates/` directory for `.zt.html` files and loads them automatically.

**Convention**: 
- `index.zt.html` → available as `"index"` in registry
- `about.zt.html` → available as `"about"` in registry
- `contact.zt.html` → available as `"contact"` in registry

```zig
// Auto-discover all templates
const template_registry = try app.discoverTemplates("src/templates");
defer template_registry.deinit();

// Access templates by name
if (template_registry.get("index")) |template| {
    const html = try template.render(Context, context, allocator);
    return Response.html(html);
}
```

**TemplateRegistry API**:

```zig
pub const TemplateRegistry = struct {
    /// Get a template by name
    pub fn get(self: *TemplateRegistry, name: []const u8) ?*RuntimeTemplate;
    
    /// Check if a template exists
    pub fn has(self: *TemplateRegistry, name: []const u8) bool;
    
    /// Clean up registry (templates are owned by HotReloadManager)
    pub fn deinit(self: *TemplateRegistry) void;
};
```

**Requirements**:
- Only works in development mode (requires hot reload)
- Returns empty registry if hot reload is disabled
- Template names are extracted from filenames (without `.zt.html` extension)

**Error Handling**:
- Missing `templates/` directory: returns empty registry (no error)
- Invalid template files: logs warning, skips file
- Hot reload disabled: logs warning, returns empty registry

**Example Usage**:

```zig
pub fn main() !void {
    var app = try Engine12.initDevelopment();
    defer app.deinit();
    
    // Discover templates
    const templates = try app.discoverTemplates("src/templates");
    defer templates.deinit();
    
    // Register route that uses discovered template
    try app.get("/", handleIndex);
    
    try app.start();
}

fn handleIndex(req: *Request) Response {
    _ = req;
    
    // Get template from registry
    const template = templates.get("index") orelse {
        return Response.text("Template not found").withStatus(500);
    };
    
    // Render template
    const context = struct {
        title: []const u8,
        message: []const u8,
    }{
        .title = "Welcome",
        .message = "Hello from Engine12!",
    };
    
    const html = template.render(@TypeOf(context), context, allocator) catch {
        return Response.text("Rendering failed").withStatus(500);
    };
    
    return Response.html(html);
}
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

## Hot Reloading API

Engine12 provides hot reloading support for development mode, enabling automatic reloading of templates and static files without server restart. Hot reloading is automatically enabled when using `initDevelopment()` and disabled in production.

### Loading Templates for Hot Reloading

#### `loadTemplate(template_path: []const u8) !*RuntimeTemplate`

Load a template file for hot reloading. Returns a `RuntimeTemplate` that automatically reloads when the file changes.

```zig
const template = try app.loadTemplate("templates/index.zt.html");
const content = try template.getContentString();
// Use content with Template.compile() or a runtime template engine
```

**Note:** Since Engine12 templates use comptime compilation, runtime templates provide the content string. For full type safety, use comptime templates with `@embedFile` in production.

#### `discoverTemplates(templates_dir: []const u8) !TemplateRegistry`

Auto-discover and load templates from a directory. Scans the `templates/` directory for `.zt.html` files and loads them automatically.

**Convention**: 
- `index.zt.html` → available as `"index"` in registry
- `about.zt.html` → available as `"about"` in registry
- `contact.zt.html` → available as `"contact"` in registry

```zig
// Auto-discover all templates
const template_registry = try app.discoverTemplates("src/templates");
defer template_registry.deinit();

// Access templates by name
if (template_registry.get("index")) |template| {
    const html = try template.render(Context, context, allocator);
    return Response.html(html);
}
```

**TemplateRegistry API**:

```zig
pub const TemplateRegistry = struct {
    /// Get a template by name
    pub fn get(self: *TemplateRegistry, name: []const u8) ?*RuntimeTemplate;
    
    /// Check if a template exists
    pub fn has(self: *TemplateRegistry, name: []const u8) bool;
    
    /// Clean up registry (templates are owned by HotReloadManager)
    pub fn deinit(self: *TemplateRegistry) void;
};
```

**Requirements**:
- Only works in development mode (requires hot reload)
- Returns empty registry if hot reload is disabled
- Template names are extracted from filenames (without `.zt.html` extension)

**Error Handling**:
- Missing `templates/` directory: returns empty registry (no error)
- Invalid template files: logs warning, skips file
- Hot reload disabled: logs warning, returns empty registry

**Example Usage**:

```zig
pub fn main() !void {
    var app = try Engine12.initDevelopment();
    defer app.deinit();
    
    // Discover templates
    const templates = try app.discoverTemplates("src/templates");
    defer templates.deinit();
    
    // Register route that uses discovered template
    try app.get("/", handleIndex);
    
    try app.start();
}

fn handleIndex(req: *Request) Response {
    _ = req;
    
    // Get template from registry
    const template = templates.get("index") orelse {
        return Response.text("Template not found").withStatus(500);
    };
    
    // Render template
    const context = struct {
        title: []const u8,
        message: []const u8,
    }{
        .title = "Welcome",
        .message = "Hello from Engine12!",
    };
    
    const html = template.render(@TypeOf(context), context, allocator) catch {
        return Response.text("Rendering failed").withStatus(500);
    };
    
    return Response.html(html);
}
```

### RuntimeTemplate

The `RuntimeTemplate` struct provides methods for working with hot-reloadable templates.

#### `getContentString() ![]const u8`

Get the current template content as a string. Automatically reloads if the file has changed.

```zig
const content = try template.getContentString();
```

#### `reload() !void`

Manually check for file changes and reload if necessary.

```zig
try template.reload();
```

#### `deinit() void`

Clean up template resources.

```zig
template.deinit();
```

### Hot Reload Manager

The `HotReloadManager` coordinates all hot reload functionality. It's automatically initialized in development mode.

#### `watchTemplate(template_path: []const u8) !*RuntimeTemplate`

Watch a template file for changes and return a `RuntimeTemplate` instance.

```zig
const template = try hot_reload_manager.watchTemplate("templates/index.zt.html");
```

#### `watchStaticFiles(file_server: *FileServer) !void`

Register a static file server for hot reloading. Static files are automatically served without cache headers in development mode.

```zig
try hot_reload_manager.watchStaticFiles(&file_server);
```

### Static File Cache Control

In development mode, static files are automatically served without cache headers to ensure changes are immediately visible. The `FileServer` provides methods to control caching:

#### `disableCache() void`

Disable caching for this file server (automatically called in development mode).

```zig
file_server.disableCache();
```

#### `enableCache() void`

Enable caching for this file server.

```zig
file_server.enableCache();
```

### Complete Example

```zig
const std = @import("std");
const Engine12 = @import("Engine12");

pub fn main() !void {
    // Initialize in development mode (hot reloading enabled)
    var app = try Engine12.initDevelopment();
    defer app.deinit();

    // Load template for hot reloading
    const template = try app.loadTemplate("templates/index.zt.html");

    // Register route that uses the template
    try app.get("/", handleIndex);

    // Serve static files (cache disabled in dev mode)
    try app.serveStatic("/", "./frontend");

    try app.start();
}

fn handleIndex(req: *Engine12.Request) Engine12.Response {
    _ = req;
    
    // Get template content (automatically reloads if changed)
    const template_content = template.getContentString() catch {
        return Engine12.Response.text("Template error").withStatus(500);
    };
    
    // Use template content with Template.compile() or runtime engine
    // For now, just return the content as example
    return Engine12.Response.html(template_content);
}
```

### Limitations

- **Code Changes**: Hot reloading only applies to templates and static files. Code changes still require server restart (Zig limitation).
- **Comptime Templates**: Runtime templates provide content strings but don't support full comptime type checking. Use comptime templates (`@embedFile`) for production.
- **File Watching**: Uses polling-based file watching (500ms interval) for cross-platform compatibility.

## WebSocket API

Engine12 provides WebSocket support for real-time bidirectional communication. Each WebSocket route runs on its own port (starting from 9000) and uses thread-based execution for concurrency.

### Registering WebSocket Routes

#### `websocket(path_pattern: []const u8, handler: WebSocketHandler) !void`

Register a WebSocket endpoint. The handler function is called when a connection is established.

```zig
const websocket = @import("Engine12").websocket;

fn handleChat(conn: *websocket.WebSocketConnection) void {
    std.debug.print("New connection: {s}\n", .{conn.id});
    
    // Set up message handling
    // Messages are handled automatically by websocket.zig
}

try app.websocket("/ws/chat", handleChat);
```

### WebSocketConnection

The `WebSocketConnection` struct provides methods for interacting with WebSocket connections.

#### `sendText(text: []const u8) !void`

Send a text message to the client.

```zig
try conn.sendText("Hello, client!");
```

#### `sendBinary(data: []const u8) !void`

Send a binary message to the client.

```zig
try conn.sendBinary(&[4]u8{ 0x01, 0x02, 0x03, 0x04 });
```

#### `sendJson(comptime T: type, value: T) !void`

Send a JSON message by serializing a struct.

```zig
const Message = struct {
    type: []const u8,
    content: []const u8,
};

try conn.sendJson(Message, .{
    .type = "chat",
    .content = "Hello!",
});
```

#### `close(code: ?u16, reason: ?[]const u8) !void`

Close the connection gracefully.

```zig
try conn.close(1000, "Normal closure");
```

#### `get(key: []const u8) ?[]const u8`

Get a value from the connection's context storage.

```zig
if (conn.get("user_id")) |user_id| {
    std.debug.print("User ID: {s}\n", .{user_id});
}
```

#### `set(key: []const u8, value: []const u8) !void`

Set a value in the connection's context storage.

```zig
try conn.set("user_id", "12345");
```

### Connection Properties

- `id: []const u8` - Unique connection identifier
- `path: []const u8` - WebSocket path pattern
- `headers: std.StringHashMap([]const u8)` - HTTP headers from handshake
- `is_open: std.atomic.Value(bool)` - Connection state

### WebSocket Rooms

Rooms allow broadcasting messages to groups of connections.

#### `WebSocketRoom.init(allocator: std.mem.Allocator, name: []const u8) !WebSocketRoom`

Create a new room.

```zig
var chatRoom = try websocket.WebSocketRoom.init(allocator, "general");
defer chatRoom.deinit();
```

#### `join(conn: *WebSocketConnection) !void`

Add a connection to the room.

```zig
try chatRoom.join(conn);
```

#### `leave(conn: *WebSocketConnection) void`

Remove a connection from the room.

```zig
chatRoom.leave(conn);
```

#### `broadcast(message: []const u8) !void`

Broadcast a text message to all connections in the room.

```zig
try chatRoom.broadcast("Hello everyone!");
```

#### `broadcastBinary(data: []const u8) !void`

Broadcast a binary message to all connections in the room.

```zig
try chatRoom.broadcastBinary(&[4]u8{ 0x01, 0x02, 0x03, 0x04 });
```

#### `broadcastJson(comptime T: type, value: T) !void`

Broadcast a JSON message to all connections in the room.

```zig
const Message = struct {
    type: []const u8,
    content: []const u8,
};

try chatRoom.broadcastJson(Message, .{
    .type = "notification",
    .content = "New message!",
});
```

#### `count() usize`

Get the number of connections in the room.

```zig
const count = chatRoom.count();
std.debug.print("Room has {d} connections\n", .{count});
```

#### `isEmpty() bool`

Check if the room is empty.

```zig
if (chatRoom.isEmpty()) {
    std.debug.print("Room is empty\n", .{});
}
```

### Complete Example

```zig
const std = @import("std");
const Engine12 = @import("Engine12");
const websocket = Engine12.websocket;

var chatRoom: websocket.WebSocketRoom = undefined;

fn handleChat(conn: *websocket.WebSocketConnection) void {
    std.debug.print("New chat connection: {s}\n", .{conn.id});
    
    // Join the chat room
    chatRoom.join(conn) catch |err| {
        std.debug.print("Error joining room: {}\n", .{err});
        return;
    };
    
    // Broadcast welcome message
    chatRoom.broadcast("User joined the chat") catch {};
    
    // Store user info in connection context
    conn.set("user_id", "12345") catch {};
    
    // Messages are handled automatically by websocket.zig
    // You can set up custom message handling in your handler
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var app = try Engine12.initDevelopment();
    defer app.deinit();
    
    // Initialize chat room
    chatRoom = try websocket.WebSocketRoom.init(allocator, "general");
    defer chatRoom.deinit();
    
    // Register WebSocket route
    try app.websocket("/ws/chat", handleChat);
    
    // Register HTTP routes
    try app.get("/", handleRoot);
    
    try app.start();
}
```

### Valve Integration

Valves can register WebSocket routes using the ValveContext API.

```zig
pub fn init(ctx: *valve.ValveContext) !void {
    if (!ctx.hasCapability(.websockets)) {
        return error.CapabilityRequired;
    }
    
    try ctx.registerWebSocket("/ws/chat", handleChat);
}
```

## Error Handling

### Error Handler Registration

```zig
fn customErrorHandler(err: anyerror) Response {
    return Response.status(500).withJson("{\"error\":\"Internal error\"}");
}

app.useErrorHandler(customErrorHandler);
```

## Structured Logging

Engine12 provides structured logging with support for multiple output destinations, log levels, and formats.

### Logger

The `Logger` struct provides structured logging capabilities with support for multiple destinations (stdout, file, syslog), log levels, and output formats (JSON, human-readable).

#### `Logger.init(allocator: Allocator, min_level: LogLevel) Logger`

Create a new logger with a minimum log level.

```zig
var logger = Logger.init(allocator, .info);
```

#### `Logger.fromEnvironment(allocator: Allocator, environment: Environment) Logger`

Create a logger configured for a specific environment (development, staging, production).

```zig
var logger = Logger.fromEnvironment(allocator, .production);
// Production: JSON format, info level
// Development: Human-readable format, debug level
```

#### `logger.addDestination(destination: LogDestination) !void`

Add a log destination (stdout, file, or syslog).

```zig
try logger.addDestination(.stdout);
try logger.addDestination(.file);
```

#### `logger.setFileDestination(file_path: []const u8) !void`

Configure file logging destination.

```zig
try logger.setFileDestination("logs/app.log");
```

#### `logger.setSyslogFacility(facility: u8) !void`

Configure syslog facility (0-23, see syslog.h).

```zig
try logger.setSyslogFacility(1); // LOG_USER
```

#### `logger.setFormat(format: OutputFormat) void`

Set the output format (JSON or human-readable).

```zig
logger.setFormat(.json); // For production
logger.setFormat(.human); // For development
```

#### `logger.log(level: LogLevel, message: []const u8) !*LogEntry`

Create a log entry builder.

```zig
var entry = try logger.log(.info, "User logged in");
try entry.field("user_id", "123");
try entry.fieldInt("login_count", 5);
entry.log();
```

#### `logger.debug(message: []const u8) !*LogEntry`
#### `logger.info(message: []const u8) !*LogEntry`
#### `logger.warn(message: []const u8) !*LogEntry`
#### `logger.logError(message: []const u8) !*LogEntry`

Convenience methods for logging at specific levels.

```zig
try logger.info("Server started").log();
try logger.warn("High memory usage").fieldInt("memory_mb", 1024).log();
try logger.logError("Database connection failed").log();
```

#### `logger.fromRequest(req: *Request, level: LogLevel, message: []const u8) !*LogEntry`

Create a log entry with request context pre-populated.

```zig
var entry = try logger.fromRequest(req, .info, "Request handled");
entry.log(); // Automatically includes request_id, method, path, IP, etc.
```

#### `logger.logRequest(req: *Request, level: LogLevel, message: []const u8) !void`

Convenience method to log a request.

```zig
try logger.logRequest(req, .info, "Request received");
```

#### `logger.logResponse(req: *Request, status_code: ?u16, level: LogLevel, message: []const u8) !void`

Convenience method to log a response with duration.

```zig
try logger.logResponse(req, 200, .info, "Request completed");
```

### LogEntry

The `LogEntry` struct provides a builder pattern for creating structured log entries.

#### `entry.field(key: []const u8, value: []const u8) !*LogEntry`
#### `entry.fieldInt(key: []const u8, value: anytype) !*LogEntry`
#### `entry.fieldBool(key: []const u8, value: bool) !*LogEntry`

Add fields to a log entry.

```zig
var entry = try logger.info("User action");
try entry.field("user_id", "123");
try entry.fieldInt("action_count", 42);
try entry.fieldBool("is_premium", true);
entry.log();
```

#### `entry.withRequest(req: *Request) !*LogEntry`

Add request context to a log entry (request_id, method, path, IP, user_agent).

```zig
var entry = try logger.info("Request processed");
try entry.withRequest(req);
entry.log();
```

#### `entry.withResponse(status_code: ?u16, req: ?*Request) !*LogEntry`

Add response context to a log entry (status_code, duration_ms).

```zig
var entry = try logger.info("Response sent");
try entry.withRequest(req);
try entry.withResponse(200, req);
entry.log();
```

### Logging Middleware

The `LoggingMiddleware` provides automatic request/response logging.

#### `LoggingMiddleware.init(config: LoggingConfig) LoggingMiddleware`

Initialize logging middleware with configuration.

```zig
const logging_config = LoggingConfig{
    .log_requests = true,
    .log_responses = true,
    .exclude_paths = &[_][]const u8{ "/health", "/metrics" },
};
var logging_mw = LoggingMiddleware.init(logging_config);
logging_mw.setGlobalLogger(&app.logger);
logging_mw.setGlobalConfig();
try app.usePreRequest(logging_mw.preRequestMwFn());
try app.useResponse(logging_mw.responseMwFn());
```

#### `app.enableRequestLogging(config: ?LoggingConfig) !void`

Convenience method to enable request/response logging.

```zig
// Use default configuration
try app.enableRequestLogging(null);

// Or with custom configuration
const config = LoggingConfig{
    .log_requests = true,
    .log_responses = true,
    .exclude_paths = &[_][]const u8{ "/health" },
};
try app.enableRequestLogging(config);
```

#### `app.getLogger() *Logger`

Get the logger instance from the app.

```zig
const logger = app.getLogger();
try logger.info("Custom log message").log();
```

### Log Levels

- `.debug` - Debug messages (development only)
- `.info` - Informational messages
- `.warn` - Warning messages
- `.err` - Error messages

### Output Formats

- `.json` - JSON format (production)
- `.human` - Human-readable format (development)

### Example Usage

```zig
const std = @import("std");
const E12 = @import("engine12");

pub fn main() !void {
    var app = try E12.Engine12.initDevelopment();
    defer app.deinit();

    // Configure logger
    const logger = app.getLogger();
    logger.setFormat(.human); // Human-readable for development
    try logger.setFileDestination("logs/app.log"); // Also log to file

    // Enable automatic request/response logging
    try app.enableRequestLogging(.{
        .exclude_paths = &[_][]const u8{ "/health" },
    });

    // Custom logging in handlers
    try app.get("/", handleRoot);
    try app.start();
}

// Store app reference globally or pass logger to handler
var global_app: ?*E12.Engine12 = null;

fn handleRoot(req: *E12.Request) E12.Response {
    if (global_app) |app| {
        const logger = app.getLogger();
        try logger.info("Root endpoint accessed")
            .field("ip", req.header("X-Real-IP") orelse "unknown")
            .log();
    }
    
    return E12.Response.text("Hello, World!");
}
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

