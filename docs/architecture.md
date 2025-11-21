# Architecture Guide

This document provides an overview of Engine12's architecture and design decisions.

## System Overview

Engine12 is a web framework built on top of Zig, designed for high performance and type safety. It integrates with the ziggurat HTTP server library and provides a clean, memory-safe API for building web applications.

## Core Components

### Engine12 Framework

The main `Engine12` struct (`src/engine12.zig`) serves as the application container:

- **Route Management**: Stores and registers HTTP routes
- **Middleware Chain**: Manages pre-request and response middleware
- **Background Tasks**: Coordinates periodic and one-time tasks
- **Health Checks**: Manages system health monitoring
- **Metrics Collection**: Tracks request timing and statistics

### HTTP Server Integration

Engine12 uses the `ziggurat` library for HTTP server functionality:

- Routes are registered with ziggurat's `Server` builder
- Request/Response wrappers bridge ziggurat and Engine12 APIs
- The server runs in a background thread to allow non-blocking operation

### Request/Response Handling

#### Request Wrapper (`src/request.zig`)

- Wraps `ziggurat.request.Request` with an Engine12 API
- Provides an arena allocator per request for memory-safe temporary allocations
- Extracts route parameters, query parameters, and parses request bodies
- Stores request context for middleware communication
- **Type-safe parameter parsing**: `paramTyped()` and `queryParamTyped()` provide compile-time type checking for route and query parameters
- **Automatic request ID generation**: Each request gets a unique ID for correlation tracking

#### Response Wrapper (`src/response.zig`)

- Wraps `ziggurat.response.Response` with fluent builder methods
- Automatically copies response bodies to persistent memory
- Provides convenience methods for common response types (JSON, HTML, text)
- **Error response helpers**: `errorResponse()`, `serverError()`, `validationError()` for standardized error responses
- **JSON serialization**: `jsonFrom()` automatically serializes structs to JSON responses

### Router System

The router (`src/router.zig`) handles:

- Route pattern parsing (e.g., `/todos/:id`)
- Parameter extraction from URLs
- Route matching and parameter binding

Route parameters are extracted at request time and stored in the `Request` struct's `route_params` hashmap.

## Middleware Architecture

### Middleware Chain

The `MiddlewareChain` (`src/middleware.zig`) manages two types of middleware:

1. **Pre-Request Middleware**: Executed before the route handler
   - Can short-circuit by returning `.abort`
   - Used for authentication, rate limiting, CSRF protection, etc.

2. **Response Middleware**: Executed after the route handler
   - Transforms responses
   - Used for CORS headers, response logging, etc.
   - Built-in CORS middleware automatically adds CORS headers based on request context
   - Built-in Request ID middleware automatically adds Request ID headers

### Execution Flow

```
Request → Pre-Request Middleware → Handler → Response Middleware → Response
              ↓ (if abort)
         Response (early return)
```

### Global State

Middleware uses thread-local global pointers for:
- `global_middleware`: Current middleware chain
- `global_metrics`: Metrics collector
- `global_rate_limiter`: Rate limiter instance
- `global_cache`: Response cache instance

These are set when routes are registered and accessed at runtime.

## Caching Architecture

### Response Cache

The `ResponseCache` (`src/cache.zig`) provides:
- In-memory response caching with TTL-based expiration
- ETag generation for cache validation
- Prefix-based cache invalidation
- Automatic expiration cleanup

### Cache Access Pattern

Cache is accessed via global pointer (`global_cache`) similar to rate limiting:
- Set globally via `app.setCache(&cache)`
- Accessed from Request objects via `req.cache()`, `req.cacheGet()`, etc.
- Thread-safe access through global pointer

### Cache Entry Structure

Each cache entry (`CacheEntry`) stores:
- Response body (duplicated into cache allocator)
- ETag (generated from body hash)
- Content type
- TTL and expiration timestamp
- Last modified timestamp

### Cache Operations

- **Get**: Returns cached entry if not expired, null otherwise
- **Set**: Stores response with optional custom TTL
- **Invalidate**: Removes specific entry
- **InvalidatePrefix**: Removes all entries matching prefix
- **Cleanup**: Removes expired entries

### Request Integration

Request objects provide convenience methods:
- `req.cache()` - Get cache instance
- `req.cacheGet(key)` - Get cached entry
- `req.cacheSet(key, body, ttl, content_type)` - Store entry
- `req.cacheInvalidate(key)` - Invalidate entry
- `req.cacheInvalidatePrefix(prefix)` - Invalidate by prefix

This allows handlers to easily implement caching without direct cache access.

## ORM Architecture

### Database Layer

The `Database` struct (`src/orm/database.zig`) provides:

- SQLite connection management
- SQL execution (execute/query)
- Transaction support
- Connection pooling

### Query Builder

The `QueryBuilder` (`src/orm/query_builder.zig`) provides:

- Fluent API for building SQL queries
- Type-safe query construction
- Support for WHERE, JOIN, ORDER BY, LIMIT, OFFSET

### Type System Integration

The ORM uses Zig's comptime features for type safety:

- `model.inferTableName(T)`: Infers table name from struct name
- Field introspection via `std.meta.fields(T)`
- Compile-time SQL generation
- **Enum support**: Enum types are automatically converted to their integer values when saving
- **Optional field handling**: Null optional fields are automatically skipped in INSERT/UPDATE statements, allowing partial updates

### Row Mapping

The `QueryResult` (`src/orm/row.zig`) handles:

- Reading SQLite result sets
- Mapping rows to Zig structs
- Type-safe column access
- **Optional field deserialization**: Correctly handles null values for optional fields
- **Optional enum deserialization**: Supports optional enum fields with proper type conversion

**Column Mapping**: The ORM maps database columns to struct fields by name, not by position. This means column order in queries doesn't need to match struct field order - the ORM automatically matches columns by name. Extra columns in query results are ignored, and missing columns result in `error.ColumnMismatch` with detailed error messages listing missing fields.

### Error Messages

The ORM provides improved error messages with detailed context:

- **Table name**: Shows which table caused the error
- **SQL query**: Shows the exact SQL query that was executed
- **Missing fields**: Lists struct fields that don't have corresponding columns
- **Available columns**: Lists columns available in the query result
- **Field information**: Shows struct field names and types
- **Error type**: Shows the specific error that occurred

When `findAll()`, `where()`, or `query()` operations fail, error messages include:
- Table name
- SQL query that was executed
- Missing struct fields
- Available columns in the query result

This makes it much easier to diagnose schema mismatches and type errors.

## Template System

### Compile-Time Compilation

Templates are compiled at comptime:

1. Template string is parsed into an AST
2. Type checker validates context types
3. Code generator creates render function
4. Template becomes a type that can be rendered

### AST Structure

Templates are parsed into an Abstract Syntax Tree (`src/templates/ast.zig`):

- Text nodes: Raw HTML/text
- Variable nodes: `{{ .field }}` expressions
- Control structures: Loops (`{% for %}...{% endfor %}`), conditionals (`{% if %}...{% endif %}`)
- Nested variable access: `{{ .nested.field }}` and parent context navigation (`{{ ../parent.field }}`)

### Type Safety

The type checker (`src/templates/type_checker.zig`) ensures:

- Context struct contains all referenced fields
- Field types match template usage
- Compile-time errors for invalid templates
- **Improved error messages**: Includes context type information, field names, and actionable suggestions

### Template Features

The template engine supports:

- **Array/slice iteration**: `{% for .items |item| %}...{% endfor %}` with loop variables
- **Loop variables**: `.item` (or custom name), `.index`, `.first`, `.last`
- **Parent context navigation**: `{{ ../parent.field }}` to access parent context from within loops
- **Improved conditional rendering**: Enhanced truthy/falsy evaluation with explicit string handling
- **Runtime collection support**: Supports slices, arrays, and `ArrayListUnmanaged` collections

## Error Handling

### Error Handler Registry

The `ErrorHandlerRegistry` (`src/error_handler.zig`) allows:

- Custom error handlers for specific error types
- Default error handling fallback
- Error-to-response conversion

### Middleware Error Handling

Middleware can set error context in the request:

- `req.set("rate_limited", "true")` - Rate limit error
- `req.set("csrf_error", "true")` - CSRF error
- `req.set("body_size_exceeded", "true")` - Body size error

The middleware chain checks these and returns appropriate responses.

## Concurrency Model

### Request Handling

- Each request runs in ziggurat's thread pool
- Request allocator is arena-based for fast cleanup
- No shared mutable state between requests

### Background Tasks

Background tasks use the `vigil` supervision library:

- Tasks run in separate threads
- Supervisor manages task lifecycle
- Tasks can be periodic or one-time

### Thread Safety

- Global state uses mutexes where needed
- Request handlers are thread-safe (no shared state)
- Database connections are per-request or pooled

## Memory Management

### Arena Allocators

Each request gets an arena allocator:

- Fast allocation/deallocation
- Automatic cleanup when request completes
- Prevents memory leaks

### Persistent Allocators

Response bodies use page allocator:

- Responses persist after request completes
- Memory is not freed (acceptable for small responses)
- For large responses, consider streaming

### ORM Initialization

The ORM supports two initialization patterns:

**Value-based initialization (`init()`):**
- Returns a value type
- Suitable for local usage within functions
- Use `close()` for cleanup

**Pointer-based initialization (`initPtr()`):**
- Returns a heap-allocated pointer
- Recommended for handler usage where pointers are needed
- Use `deinitPtr()` for cleanup
- Better for global ORM instances

### ORM Memory Management

- Struct fields are allocated by caller
- ORM methods accept pre-allocated structs
- Query results allocate strings for text fields
- Caller must free allocated memory

## Valve System Architecture

The Valve System provides a secure and simple plugin architecture for Engine12. Each valve is an isolated service that integrates deeply with the Engine12 runtime through controlled capabilities.

### Design Philosophy

The valve system is designed around three core principles:

1. **Security through Isolation**: Valves can only access Engine12 features through a controlled `ValveContext`, preventing direct access to internal state
2. **Simplicity**: The interface is minimal - valves implement a simple `Valve` struct with lifecycle hooks
3. **Deep Integration**: Valves can register routes, middleware, background tasks, and more, making them first-class citizens in the Engine12 runtime

### Capability Model

Valves declare required capabilities in their metadata. Capabilities are granted at registration time and checked at runtime:

- **Declaration**: Valves declare capabilities in `ValveMetadata.required_capabilities`
- **Granting**: The registry grants all requested capabilities when a valve is registered
- **Enforcement**: `ValveContext` methods check capabilities before allowing access
- **Error Handling**: Attempts to use features without capabilities return `error.CapabilityRequired`

### Valve Lifecycle

1. **Registration**: Valve is registered with `Engine12.registerValve()`
2. **Initialization**: `valve.init()` is called with a `ValveContext` containing granted capabilities
3. **App Start**: `valve.onAppStart()` is called when `app.start()` is invoked (if provided)
4. **Runtime**: Valve operates normally, registering routes, middleware, etc.
5. **App Stop**: `valve.onAppStop()` is called when `app.stop()` is invoked (if provided)
6. **Cleanup**: `valve.deinit()` is called when valve is unregistered or app is deinitialized

### Isolation Guarantees

- Valves cannot directly access `Engine12` internals
- All access goes through `ValveContext`, which enforces capability checks
- Valves receive their own allocator from Engine12
- Each valve has its own context, preventing cross-valve interference

### Thread Safety

The `ValveRegistry` provides thread-safe access to valve state and information:

- **Mutex Protection**: All registry methods are protected by a mutex, ensuring safe concurrent access
- **Query Methods**: All query methods (`getContext`, `getValveState`, `getValveErrors`, `getErrorInfo`, `isValveHealthy`, `getFailedValves`, `getValveNames`) are thread-safe
- **Registration Methods**: `register()` and `unregister()` are thread-safe and can be called concurrently
- **Lifecycle Methods**: `onAppStart()` and `onAppStop()` are thread-safe

This allows safe monitoring and management of valves from multiple threads, such as health check endpoints or administrative interfaces.

### Automatic Route Cleanup

When a valve is unregistered, the registry automatically cleans up all routes registered by that valve:

- **Route Discovery**: Uses `runtime_routes.getValveRoutes()` to find all routes registered by the valve
- **Automatic Unregistration**: Each route is automatically removed from the runtime route registry
- **Error Handling**: Route cleanup errors are logged but don't prevent valve unregistration
- **Clean Unregistration**: Ensures no orphaned routes remain after valve removal

This prevents route conflicts and ensures clean unregistration without manual route management.

### Error Reporting

The valve system provides structured error information for better debugging and monitoring:

- **Structured Errors**: Errors are stored as `ValveErrorInfo` structures containing phase, type, message, and timestamp
- **Error Phases**: Errors are categorized by lifecycle phase (init, start, stop, runtime)
- **Backward Compatibility**: `getValveErrors()` still returns formatted strings for compatibility
- **Detailed Information**: `getErrorInfo()` provides structured access to error details including timestamps
- **Automatic Cleanup**: Error information is automatically freed when valves are unregistered

**Error Information Structure**:
```zig
pub const ValveErrorInfo = struct {
    phase: ValveErrorPhase,        // Phase where error occurred
    error_type: []const u8,        // Error type name
    message: []const u8,           // Human-readable message
    timestamp: i64,                // Unix timestamp in milliseconds
};
```

### Security Considerations

- **Capability-Based Access Control**: Valves must declare and receive capabilities before accessing features
- **No Direct Engine12 Access**: Valves cannot access Engine12 fields directly
- **Controlled Resource Access**: ORM, cache, and metrics access is gated by capabilities
- **Type Safety**: All valve operations are type-checked at compile time

### Example Use Cases

- **Authentication Valves**: Provide JWT or session-based authentication
- **WebSocket Valves**: Manage WebSocket connections and real-time communication (now supported)
- **Database Valves**: Provide database utilities and health checks
- **Logging Valves**: Centralized request logging and monitoring
- **API Gateway Valves**: Route requests to external services

## Extension Points

### Custom Middleware

Users can create custom middleware:

```zig
fn customMiddleware(req: *Request) MiddlewareResult {
    // Custom logic
    return .proceed;
}
```

### Custom Error Handlers

Users can register custom error handlers:

```zig
fn customErrorHandler(err: anyerror) Response {
    // Custom error handling
    return Response.status(500);
}
```

### Route Groups

Route groups allow:

- Shared middleware across routes
- Route prefixing
- Organizing related routes

## Design Decisions

### Why Zig?

- Zero-cost abstractions
- Compile-time execution
- Memory safety without garbage collection
- Excellent performance

### Why SQLite?

- Embedded database (no separate server)
- ACID compliance
- Excellent performance for most use cases
- Simple deployment

### Why ziggurat?

- Lightweight HTTP server
- Good performance
- Simple API
- Zig-native implementation

### Why Comptime Templates?

- Type safety at compile time
- No runtime template parsing overhead
- Compile-time errors for invalid templates
- Better performance

## WebSocket Architecture

Engine12 provides WebSocket support using the `karlseguin/websocket.zig` library. Each WebSocket route runs on its own port (starting from 9000) and uses thread-based execution for concurrency, similar to the HTTP server.

### Key Components

- **WebSocketConnection**: Wraps `websocket.zig`'s `Conn` type with an Engine12-friendly API
- **WebSocketManager**: Manages multiple WebSocket servers and their lifecycle
- **WebSocketRoom**: Provides room-based broadcasting to groups of connections
- **Handler Bridge**: Bridges `websocket.zig`'s Handler interface to Engine12 handlers

### Design Decisions

- **Thread-based Execution**: Each WebSocket server runs in its own thread, similar to Engine12's HTTP server
- **Port-per-Route**: Each WebSocket route gets its own port for isolation and simplicity
- **Room Management**: Built-in room system for broadcasting to groups of connections
- **Type Safety**: WebSocket handlers are type-checked at compile time

## Hot Reloading Architecture

Engine12 provides hot reloading support for development mode, enabling automatic reloading of templates and static files without server restart. Hot reloading is automatically enabled when using `initDevelopment()` and disabled in production.

### Key Components

- **FileWatcher**: Polling-based file watcher that monitors file changes (500ms interval)
- **RuntimeTemplate**: Runtime template loader that tracks file modifications and reloads content
- **HotReloadManager**: Central coordinator that manages file watching and template/static file reloading
- **FileServer Cache Control**: Automatic cache disabling in development mode

### Design Decisions

- **Development Only**: Hot reloading is automatically enabled only in `initDevelopment()`, ensuring zero performance impact in production
- **Polling-based Watching**: Uses 500ms polling interval for cross-platform compatibility (can be optimized per-platform later)
- **Comptime Compatibility**: Runtime templates complement comptime templates - users can choose based on their needs
- **Thread Safety**: All hot reload operations use proper synchronization with mutexes
- **Graceful Degradation**: Hot reload failures don't crash the server - errors are logged but operations continue

### How It Works

1. **Template Hot Reloading**: When a template file is loaded via `loadTemplate()`, it's watched for changes. On each access, the file modification time is checked and content is reloaded if changed.

2. **Static File Hot Reloading**: Static file servers registered in development mode automatically disable caching, ensuring browsers always fetch the latest version.

3. **File Watching**: A background thread polls watched files every 500ms, detecting changes by comparing modification times.

### Limitations

- **Code Changes**: Hot reloading only applies to templates and static files. Code changes still require server restart (Zig's comptime limitation).
- **Comptime Templates**: Runtime templates provide content strings but don't support full comptime type checking. Use comptime templates (`@embedFile`) for production type safety.
- **Performance**: Polling adds minimal overhead (500ms intervals), but is acceptable for development mode.

## Future Considerations

- Async/await support when Zig adds it
- More database backends (PostgreSQL, MySQL)
- Plugin system for extensions

