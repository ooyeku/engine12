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

#### Response Wrapper (`src/response.zig`)

- Wraps `ziggurat.response.Response` with fluent builder methods
- Automatically copies response bodies to persistent memory
- Provides convenience methods for common response types (JSON, HTML, text)

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

### Row Mapping

The `QueryResult` (`src/orm/row.zig`) handles:

- Reading SQLite result sets
- Mapping rows to Zig structs
- Type-safe column access

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
- Control structures: Loops, conditionals (if supported)

### Type Safety

The type checker (`src/templates/type_checker.zig`) ensures:

- Context struct contains all referenced fields
- Field types match template usage
- Compile-time errors for invalid templates

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

### ORM Memory Management

- Struct fields are allocated by caller
- ORM methods accept pre-allocated structs
- Query results allocate strings for text fields
- Caller must free allocated memory

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

## Future Considerations

- Async/await support when Zig adds it
- WebSocket support
- More database backends (PostgreSQL, MySQL)
- Plugin system for extensions
- Hot reloading for development

