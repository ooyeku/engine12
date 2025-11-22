# Engine12 Project Layout Best Practices

This document outlines the recommended project structure and organization patterns for Engine12 applications, optimized to leverage Engine12's powerful features including `restApi`, `HandlerCtx`, Valves, and built-in middleware.

## Overview

The recommended structure emphasizes:

- **Separation of concerns** - Clear boundaries between handlers, models, utilities, and frontend assets
- **Leveraging Engine12 features** - Maximize use of `restApi`, `HandlerCtx`, Valves, and built-in middleware
- **Scalability** - Easy to add new features without restructuring
- **Maintainability** - Intuitive organization that new developers can understand quickly
- **Modularity** - Reusable components and utilities

## Directory Structure

```
project-root/
├── build.zig                 # Build configuration
├── build.zig.zon            # Dependency declarations
├── src/
│   ├── main.zig             # Application entry point and route registration
│   ├── root.zig             # Module root (re-exports public API, optional)
│   ├── database.zig         # Database connection and ORM setup
│   ├── models.zig           # Data models and types
│   ├── utils.zig            # Shared utility functions
│   ├── validators.zig       # Validation functions for restApi
│   ├── auth.zig             # Authentication helpers (for restApi authenticator)
│   │
│   ├── handlers/            # Custom request handlers (when restApi isn't sufficient)
│   │   ├── search.zig       # Custom search endpoints
│   │   ├── stats.zig        # Statistics/aggregation endpoints
│   │   ├── views.zig        # HTML view handlers (server-side rendering)
│   │   ├── websocket.zig    # WebSocket handlers
│   │   └── health.zig       # Custom health check endpoints (optional)
│   │
│   ├── valves/              # Custom Engine12 Valves (plugins)
│   │   ├── my_plugin.zig    # Custom valve implementation
│   │   └── ...
│   │
│   ├── migrations/          # Database migrations
│   │   └── init.zig         # Initial migration
│   │
│   ├── static/              # Static assets served directly
│   │   ├── css/
│   │   │   └── style.css    # Main stylesheet
│   │   └── js/
│   │       ├── app.js       # Core application logic
│   │       ├── index.js     # Index page specific JS
│   │       └── [component].js # UI component utilities
│   │
│   └── templates/           # Server-side HTML templates
│       ├── layout.zt.html   # Base layout template
│       ├── index.zt.html    # Index page template
│       └── [resource].zt.html # Resource-specific pages
│
└── [database files]         # SQLite database files (if applicable)
```

## Core Principles

### 1. Prefer `restApi` for Standard CRUD Operations

**Principle**: Use Engine12's `restApi()` function for standard CRUD operations instead of writing manual handlers.

**Rationale**:
- Automatically generates 5 endpoints: `GET /prefix`, `GET /prefix/:id`, `POST /prefix`, `PUT /prefix/:id`, `DELETE /prefix/:id`
- Built-in support for filtering, sorting, pagination, authentication, authorization, validation, and caching
- Automatic OpenAPI documentation generation
- Automatic user filtering when model has `user_id` field
- Reduces code by 80-90% compared to manual handlers

**When to Use `restApi`**:
- Standard CRUD operations
- Resources that need filtering, sorting, pagination
- APIs that should be documented in OpenAPI/Swagger

**When to Use Custom Handlers**:
- Complex business logic beyond CRUD
- Custom search/aggregation endpoints
- Endpoints that don't fit REST patterns
- Server-side rendered views

**Example Structure**:

```zig
// In main.zig - Use restApi for standard CRUD
try app.restApi("/api/todos", Todo, RestApiConfig(Todo){
    .orm = orm_instance,
    .validator = validateTodo,
    .authenticator = requireAuthForRestApi,
    .authorization = canAccessTodo,
    .enable_pagination = true,
    .enable_filtering = true,
    .enable_sorting = true,
    .cache_ttl_ms = 30000,
});

// Custom handlers only for non-CRUD operations
try app.get("/api/todos/search", handlers.search.handleSearchTodos);
try app.get("/api/todos/stats", handlers.stats.handleGetStats);
```

### 2. Use `HandlerCtx` for Custom Handlers

**Principle**: Always use `HandlerCtx` when writing custom handlers to reduce boilerplate by 70-80%.

**Rationale**:
- Eliminates repetitive authentication, ORM access, and parameter parsing code
- Provides type-safe parameter parsing with better error messages
- Automatic memory management via request arena allocator
- Consistent error handling with automatic logging
- Built-in caching helpers

**Handler File Structure**:

```zig
// handlers/search.zig
const std = @import("std");
const Engine12 = @import("Engine12");
const HandlerCtx = Engine12.HandlerCtx;

fn getORM() !*Engine12.ORM {
    // Your ORM getter function
}

pub fn handleSearchTodos(req: *Engine12.Request) Engine12.Response {
    var ctx = HandlerCtx.init(req, .{
        .require_auth = true,
        .require_orm = true,
        .get_orm = getORM,
    }) catch |err| {
        return switch (err) {
            error.AuthenticationRequired => HandlerCtx.init(req, .{}).unauthorized("Authentication required"),
            error.DatabaseNotInitialized => HandlerCtx.init(req, .{}).serverError("Database not available"),
            else => HandlerCtx.init(req, .{}).serverError("Internal error"),
        };
    };

    const query = ctx.query([]const u8, "q") catch |err| {
        return ctx.badRequest("Missing query parameter 'q'");
    };

    const orm = ctx.orm() catch return ctx.serverError("Database error");
    // ... search logic using orm

    return ctx.success(results, 200);
}
```

**Benefits**:
- 70-80% code reduction compared to manual handlers
- Type-safe parameter parsing: `ctx.query(T, "name")`, `ctx.param(T, "id")`, `ctx.json(T)`
- Automatic authentication handling
- Built-in caching: `ctx.cacheKey()`, `ctx.cacheGet()`, `ctx.cacheSet()`
- Context-aware logging: `ctx.log(level, message)`

### 3. Flat Handler Organization

**Principle**: Keep handlers at a single level in `src/handlers/` directory.

**Rationale**:
- Easy to locate handlers by resource name
- Avoids deep nesting that makes navigation difficult
- Scales well up to ~20-30 handlers before needing subdirectories
- Most CRUD operations handled by `restApi`, so fewer custom handlers needed

**Naming Convention**:
- Use descriptive names: `search.zig`, `stats.zig`, `views.zig`
- One handler file per concern/feature
- Use plural resource names only if the file handles multiple related operations

**When to Split**:
- If a handler file exceeds ~500-800 lines, consider splitting by operation type
- Example: `stats.zig` could split into `stats_basic.zig` and `stats_advanced.zig`

### 4. Organize Validators and Auth Helpers

**Principle**: Separate validation and authentication logic into dedicated files for use with `restApi`.

**Structure**:

```zig
// validators.zig
pub fn validateTodo(req: *Engine12.Request, todo: Todo) !Engine12.ValidationErrors {
    var errors = Engine12.ValidationErrors.init(allocator);
    defer errors.deinit();

    if (todo.title.len == 0) {
        try errors.add("title", "Title is required");
    }
    // ... more validation

    return errors;
}

// auth.zig
pub fn requireAuthForRestApi(req: *Engine12.Request) !Engine12.AuthUser {
    return Engine12.BasicAuthValve.requireAuth(req);
}

pub fn canAccessTodo(req: *Engine12.Request, todo: Todo) !bool {
    const user = try requireAuthForRestApi(req);
    return todo.user_id == user.id;
}
```

**Benefits**:
- Reusable validation logic
- Clear separation of concerns
- Easy to test independently
- Works seamlessly with `restApi` configuration

### 5. Use Valves for Extensibility

**Principle**: Create custom Valves for reusable features that need deep Engine12 integration.

**When to Create a Valve**:
- Reusable features that need to register routes, middleware, or background tasks
- Features that should be optional/pluggable
- Third-party integrations that need Engine12 capabilities
- Features shared across multiple projects

**Structure**:

```
valves/
├── analytics.zig      # Analytics tracking valve
├── email_service.zig  # Email service valve
└── payment_gateway.zig # Payment integration valve
```

**Example**:

```zig
// valves/analytics.zig
pub const AnalyticsValve = Engine12.Valve{
    .metadata = .{
        .name = "analytics",
        .version = "1.0.0",
        .description = "Analytics tracking",
        .author = "Your Name",
        .required_capabilities = &[_]Engine12.ValveCapability{
            .routes,
            .middleware,
            .metrics_access,
        },
    },
    .init = initAnalytics,
    .deinit = deinitAnalytics,
};

fn initAnalytics(valve: *Engine12.Valve, ctx: *Engine12.ValveContext) !void {
    // Register routes, middleware, etc.
}
```

**Benefits**:
- Isolated, reusable components
- Controlled access to Engine12 features via capabilities
- Can be shared across projects
- Easy to enable/disable

### 6. Leverage Built-in Middleware

**Principle**: Use Engine12's built-in middleware before writing custom middleware.

**Available Middleware**:
- **CORS**: `cors_middleware.preflightMwFn()` - Cross-origin resource sharing
- **CSRF**: `csrf.middlewareFn()` - CSRF protection
- **Rate Limiting**: `rate_limit.middlewareFn()` - Per-route rate limiting
- **Request ID**: `request_id_middleware.middlewareFn()` - Request correlation
- **Logging**: `LoggingMiddleware.init()` - Structured request logging
- **Body Size Limit**: `body_size_limit.middlewareFn()` - Request size limits

**Setup in main.zig**:

```zig
// Middleware setup (order matters!)
try app.usePreRequest(cors_middleware.preflightMwFn());
try app.usePreRequest(request_id_middleware.middlewareFn());
try app.usePreRequest(LoggingMiddleware.init(.{
    .log_requests = true,
    .log_responses = true,
}));
try app.usePreRequest(csrf.middlewareFn());
try app.usePreRequest(body_size_limit.middlewareFn(1024 * 1024)); // 1MB limit
```

### 7. Use Background Tasks for Periodic Work

**Principle**: Use Engine12's background task system for periodic operations.

**Common Use Cases**:
- Cleanup tasks (old records, expired sessions)
- Periodic data aggregation
- Health checks
- Cache warming
- Report generation

**Setup**:

```zig
// In main.zig or a dedicated tasks.zig file
fn cleanupOldTodos() void {
    // Cleanup logic
}

fn generateStatistics() void {
    // Statistics generation
}

// Register in main.zig
try app.schedulePeriodicTask("cleanup_old_todos", &cleanupOldTodos, 3600000); // Every hour
try app.schedulePeriodicTask("generate_stats", &generateStatistics, 300000); // Every 5 minutes
```

### 8. Register Health Checks

**Principle**: Use Engine12's health check system for monitoring.

**Setup**:

```zig
// In main.zig or handlers/health.zig
fn checkDatabaseHealth() Engine12.HealthStatus {
    // Check database connectivity
    return .healthy;
}

fn checkSystemPerformance() Engine12.HealthStatus {
    // Check system metrics
    return .healthy;
}

// Register in main.zig
try app.registerHealthCheck(&checkDatabaseHealth);
try app.registerHealthCheck(&checkSystemPerformance);
```

**Access**: Health checks are automatically available at `/health` endpoint.

### 9. Enable OpenAPI Documentation

**Principle**: Always enable OpenAPI documentation for API projects.

**Setup**:

```zig
// Enable OpenAPI docs early in main.zig (before restApi calls)
try app.enableOpenApiDocs("/docs", .{
    .title = "My API",
    .version = "1.0.0",
    .description = "API documentation",
});

// All restApi calls after this will be automatically documented
try app.restApi("/api/todos", Todo, config);
try app.restApi("/api/users", User, config);
```

**Benefits**:
- Automatic documentation generation
- Interactive API testing via Swagger UI
- No manual documentation maintenance
- Available at `/docs` endpoint

### 10. Static Assets Organization

**Directory Structure**:

```
static/
├── css/
│   └── style.css     # Main stylesheet (consider splitting for large apps)
└── js/
    ├── app.js         # Core application logic, API client, shared utilities
    ├── [page].js      # Page-specific JavaScript (one per template)
    └── [component].js # Reusable UI components/utilities
```

**Naming Conventions**:
- **Page-specific JS**: Match template names (`index.js`, `workspace.js`, `project.js`)
- **Component JS**: Descriptive names (`collapsible.js`, `time.js`, `modal.js`)
- **Core JS**: `app.js` for shared functionality

**Best Practices**:
- Keep `app.js` focused on shared utilities (API client, error handling, common UI)
- Page-specific files should be lightweight and focused
- Component files should be reusable and independent
- Avoid deep nesting - keep structure flat

**When to Split CSS**:
- Single file is fine for small-medium projects
- Consider splitting by component/page for large projects:
  ```
  css/
  ├── base.css        # Reset, typography, variables
  ├── components.css  # Reusable components
  ├── layout.css      # Layout and grid
  └── pages/          # Page-specific styles
      ├── index.css
      └── workspace.css
  ```

### 11. Template Organization

**Structure**:

```
templates/
├── layout.zt.html    # Base layout with header, footer, navigation
├── index.zt.html     # Home/index page
├── [resource].zt.html # Resource-specific pages
└── [component].zt.html # Reusable template components (optional)
```

**Naming Convention**:
- Match route names: `/workspaces/:id` → `workspace.zt.html`
- Use singular form for templates: `workspace.zt.html` (not `workspaces.zt.html`)
- Layout template should be named `layout.zt.html`

**Template Best Practices**:
- Use `layout.zt.html` as base template with common structure
- Include page-specific templates that extend or include layout
- Keep templates focused on presentation, not business logic
- Use template variables for dynamic content
- Leverage Engine12's hot reloading in development mode

**Hot Reloading**: Engine12 automatically reloads templates in development mode. No restart needed when editing templates.

### 12. Migrations Organization

**Structure**:

```
migrations/
├── init.zig          # Initial schema setup
├── 001_add_users.zig # Sequential migrations (if needed)
├── 002_add_posts.zig
└── ...
```

**Best Practices**:
- Start with `init.zig` for initial schema
- Use sequential numbering for subsequent migrations: `001_`, `002_`, etc.
- Include descriptive names: `001_add_user_authentication.zig`
- Each migration should be idempotent when possible

**Migration File Structure**:

```zig
// migrations/init.zig
const Engine12 = @import("Engine12");
const Migration = Engine12.orm.Migration;

pub const migrations = [_]Migration{
    .{
        .version = 1,
        .up = "CREATE TABLE IF NOT EXISTS todos (id INTEGER PRIMARY KEY, ...)",
        .down = "DROP TABLE IF EXISTS todos",
    },
};
```

**Running Migrations**:

```zig
// In database.zig or main.zig
const migrations = @import("migrations/init.zig");
try orm.runMigrations(migrations.migrations);
```

## Route Organization in main.zig

**Recommended Order**:

1. **Application Initialization** (ORM, Cache, Logger setup)
2. **OpenAPI Documentation** (enable early, before routes)
3. **Middleware Setup** (CORS, CSRF, Rate Limiting, etc.)
4. **Root Route** (`/`)
5. **Static File Routes** (early, before API routes)
6. **restApi Routes** (automatic CRUD endpoints)
7. **Custom API Routes** (non-CRUD operations)
8. **View Routes** (HTML pages)
9. **System Routes** (health, metrics - auto-registered)
10. **WebSocket Routes** (if applicable)
11. **Valve Registration** (plugins/extensions)
12. **Background Tasks** (periodic tasks)
13. **Health Checks** (monitoring)

**Example Structure**:

```zig
pub fn main() !void {
    var app = try Engine12.initDevelopment();
    defer app.deinit();

    // 1. Initialize database and ORM
    const orm = try initDatabase();
    
    // 2. Enable OpenAPI docs (before restApi calls)
    try app.enableOpenApiDocs("/docs", .{
        .title = "My API",
        .version = "1.0.0",
    });

    // 3. Middleware
    try app.usePreRequest(cors_middleware.preflightMwFn());
    try app.usePreRequest(request_id_middleware.middlewareFn());
    try app.usePreRequest(csrf.middlewareFn());

    // 4. Root route
    try app.get("/", handleRoot);

    // 5. Static files
    try app.get("/static/css/:file", handleStatic);
    try app.get("/static/js/:file", handleStatic);

    // 6. restApi routes (automatic CRUD)
    try app.restApi("/api/todos", Todo, RestApiConfig(Todo){...});
    try app.restApi("/api/users", User, RestApiConfig(User){...});

    // 7. Custom API routes
    try app.get("/api/todos/search", handlers.search.handleSearchTodos);
    try app.get("/api/todos/stats", handlers.stats.handleGetStats);

    // 8. View routes
    try app.get("/todos/:id", handlers.views.handleTodoView);
    try app.get("/users/:id", handlers.views.handleUserView);

    // 9. System routes (auto-registered)
    // /health and /metrics are automatically available

    // 10. WebSocket routes
    try app.websocket("/ws", handlers.websocket.handleWebSocket);

    // 11. Register Valves
    try app.registerValve(&my_plugin_valve);

    // 12. Background tasks
    try app.schedulePeriodicTask("cleanup", &cleanupTask, 3600000);

    // 13. Health checks
    try app.registerHealthCheck(&checkDatabaseHealth);

    // Start server
    try app.start();
    app.printStatus();
}
```

## Frontend Organization Patterns

### JavaScript File Organization

**Pattern 1: Page-Specific Files** (Recommended)

```
js/
├── app.js           # Core: API client, utilities, event delegation
├── index.js         # Index page logic
├── workspace.js     # Workspace page logic
├── project.js       # Project page logic
└── issue.js         # Issue page logic
```

**Pattern 2: Component-Based** (For larger applications)

```
js/
├── app.js           # Core application
├── api/
│   └── client.js    # API client
├── components/
│   ├── modal.js
│   ├── form.js
│   └── table.js
└── pages/
    ├── index.js
    └── workspace.js
```

**Best Practices**:
- `app.js` should contain:
  - API client functions (for calling `/api/*` endpoints)
  - Shared utilities (date formatting, DOM helpers)
  - Global event handlers
  - Common UI initialization
  
- Page-specific files should:
  - Initialize page-specific functionality
  - Handle page-specific events
  - Be loaded only on their respective pages

**API Client Example**:

```javascript
// app.js
async function apiRequest(endpoint, options = {}) {
    const response = await fetch(`/api${endpoint}`, {
        headers: {
            'Content-Type': 'application/json',
            ...options.headers,
        },
        ...options,
    });
    if (!response.ok) throw new Error(`API error: ${response.status}`);
    return response.json();
}

// Usage in page-specific files
const todos = await apiRequest('/todos');
```

### CSS Organization

**Small-Medium Projects**:

```
css/
└── style.css        # All styles in one file
```

**Large Projects**:

```
css/
├── base.css         # Reset, variables, typography
├── layout.css       # Grid, containers, layout
├── components.css   # Buttons, forms, cards
└── pages.css        # Page-specific styles
```

**Best Practices**:
- Start with single file, split when it exceeds ~500-1000 lines
- Use CSS variables for theming
- Follow BEM or similar naming convention
- Keep specificity low

## WebSocket Organization

**Structure**:

```zig
// handlers/websocket.zig
pub fn handleWebSocket(conn: *Engine12.WebSocketConnection) void {
    // Join a room
    const room = getOrCreateRoom("chat");
    room.join(conn) catch return;

    // Handle messages
    conn.onMessage = handleMessage;
    conn.onClose = handleClose;
}
```

**Best Practices**:
- Use Engine12's room system for grouping connections
- Handle connection lifecycle (join, leave, close)
- Keep WebSocket handlers focused on real-time communication
- Consider separating by feature: `chat_websocket.zig`, `notifications_websocket.zig`

## Scaling Guidelines

### Small Projects (< 5 resources)

- Use `restApi` for all CRUD operations
- Single handler file per custom feature
- Single CSS file
- 5-10 JavaScript files maximum
- Flat structure is sufficient

### Medium Projects (5-15 resources)

- Continue with `restApi` for CRUD
- Flat handler structure for custom endpoints
- Consider splitting CSS by concern (base, components, pages)
- Organize JS by page/component
- May need utility subdirectories

### Large Projects (15+ resources)

- Use `restApi` extensively
- Consider grouping related custom handlers:
  ```
  handlers/
  ├── api/
  │   ├── v1/
  │   │   ├── search.zig
  │   │   └── analytics.zig
  │   └── v2/
  └── views/
      └── pages.zig
  ```
- Split static assets by type and feature
- Consider template partials/components
- Use Valves for major features/plugins
- May need middleware subdirectory

## Import Patterns

**In main.zig**:

```zig
// Group imports logically
const std = @import("std");
const Engine12 = @import("Engine12");

// Database and migrations
const database = @import("database.zig");
const migrations = @import("migrations/init.zig");

// Validators and auth
const validators = @import("validators.zig");
const auth = @import("auth.zig");

// Handlers (only custom handlers, restApi handles CRUD)
const handlers = struct {
    const search = @import("handlers/search.zig");
    const stats = @import("handlers/stats.zig");
    const views = @import("handlers/views.zig");
    const websocket = @import("handlers/websocket.zig");
};

// Valves
const my_plugin = @import("valves/my_plugin.zig");
```

**In handlers**:

```zig
const std = @import("std");
const Engine12 = @import("Engine12");
const HandlerCtx = Engine12.HandlerCtx;

// Relative imports for project modules
const database = @import("../database.zig");
const models = @import("../models.zig");
const utils = @import("../utils.zig");
```

## Testing Considerations

**Recommended Structure** (when adding tests):

```
src/
├── handlers/
│   └── search.zig
└── tests/
    ├── handlers/
    │   └── search_test.zig
    └── utils_test.zig
```

**Alternative** (co-located tests):

```
src/
└── handlers/
    ├── search.zig
    └── search_test.zig
```

## Configuration Files

**Root Level**:
- `build.zig` - Build configuration
- `build.zig.zon` - Dependencies
- `.gitignore` - Git ignore rules
- `README.md` - Project documentation

**Avoid**:
- Configuration files in `src/` directory
- Deep nesting of config files
- Scattered configuration

## Example: Complete File Structure

```
my-app/
├── build.zig
├── build.zig.zon
├── README.md
├── .gitignore
├── src/
│   ├── main.zig              # App initialization, routes, restApi setup
│   ├── database.zig          # ORM initialization
│   ├── models.zig            # Data models
│   ├── validators.zig        # Validation functions for restApi
│   ├── auth.zig              # Authentication helpers
│   ├── utils.zig             # Shared utilities
│   │
│   ├── handlers/              # Custom handlers (non-CRUD)
│   │   ├── search.zig        # Custom search endpoint
│   │   ├── stats.zig         # Statistics endpoint
│   │   ├── views.zig         # HTML view handlers
│   │   └── websocket.zig     # WebSocket handlers
│   │
│   ├── valves/               # Custom Engine12 Valves
│   │   └── analytics.zig     # Analytics plugin
│   │
│   ├── migrations/
│   │   └── init.zig          # Database migrations
│   │
│   ├── static/
│   │   ├── css/
│   │   │   └── style.css
│   │   └── js/
│   │       ├── app.js
│   │       ├── index.js
│   │       └── utils.js
│   │
│   └── templates/
│       ├── layout.zt.html
│       ├── index.zt.html
│       └── [resource].zt.html
│
└── [database files]
```

## Key Takeaways

1. **Use `restApi` for CRUD** - Reduces code by 80-90% and provides built-in features
2. **Use `HandlerCtx` for custom handlers** - Reduces boilerplate by 70-80%
3. **Leverage built-in middleware** - CORS, CSRF, rate limiting, logging, etc.
4. **Enable OpenAPI docs** - Automatic documentation for all `restApi` endpoints
5. **Use Valves for extensibility** - Create reusable plugins with controlled capabilities
6. **Register background tasks** - For periodic operations
7. **Register health checks** - For monitoring and observability
8. **Keep it flat** - Avoid deep nesting until necessary
9. **Separate concerns** - Validators, auth helpers, handlers, views
10. **Start simple** - Begin with flat structure, refactor when needed

## Migration from Other Structures

If migrating from a different structure:

1. **Replace CRUD handlers with `restApi`** - Convert manual CRUD handlers to `restApi` calls
2. **Refactor custom handlers to use `HandlerCtx`** - Update handlers to use `HandlerCtx` for reduced boilerplate
3. **Extract validators** - Move validation logic to `validators.zig` for use with `restApi`
4. **Extract auth helpers** - Move authentication logic to `auth.zig` for use with `restApi`
5. **Organize static assets** - Separate CSS and JS into their directories
6. **Extract templates** - Move templates to `templates/` directory
7. **Consolidate utilities** - Move shared code to `utils.zig`
8. **Update imports** - Fix all import paths to match new structure
9. **Enable OpenAPI** - Add OpenAPI documentation for automatic API docs
10. **Register middleware** - Use Engine12's built-in middleware instead of custom implementations

## Engine12-Specific Best Practices

### 1. ORM Initialization Pattern

```zig
// database.zig
var global_orm: ?ORM = null;
var db_mutex: std.Thread.Mutex = .{};

pub fn getORM() !*ORM {
    db_mutex.lock();
    defer db_mutex.unlock();
    
    if (global_orm) |*orm| {
        return orm;
    }
    
    return error.DatabaseNotInitialized;
}

pub fn initDatabase() !void {
    db_mutex.lock();
    defer db_mutex.unlock();
    
    if (global_orm != null) return;
    
    const db = try Database.init("app.db");
    global_orm = try ORM.initPtr(db);
    
    // Run migrations
    const migrations = @import("migrations/init.zig");
    try global_orm.?.runMigrations(migrations.migrations);
}
```

### 2. restApi Configuration Pattern

```zig
// In main.zig
const orm = try getORM();

try app.restApi("/api/todos", Todo, RestApiConfig(Todo){
    .orm = orm,
    .validator = validators.validateTodo,
    .authenticator = auth.requireAuthForRestApi,
    .authorization = auth.canAccessTodo,
    .enable_pagination = true,
    .enable_filtering = true,
    .enable_sorting = true,
    .cache_ttl_ms = 30000, // 30 seconds
});
```

### 3. HandlerCtx Pattern

```zig
// handlers/search.zig
pub fn handleSearch(req: *Engine12.Request) Engine12.Response {
    var ctx = HandlerCtx.init(req, .{
        .require_auth = true,
        .require_orm = true,
        .get_orm = getORM,
    }) catch |err| {
        return handleCtxError(err, req);
    };

    const query = ctx.query([]const u8, "q") catch |err| {
        return ctx.badRequest("Missing query parameter 'q'");
    };

    const orm = ctx.orm() catch return ctx.serverError("Database error");
    
    // Use orm for search...
    
    return ctx.success(results, 200);
}
```

### 4. Valve Pattern

```zig
// valves/my_plugin.zig
pub const MyPluginValve = Engine12.Valve{
    .metadata = .{
        .name = "my_plugin",
        .version = "1.0.0",
        .description = "My custom plugin",
        .author = "Your Name",
        .required_capabilities = &[_]Engine12.ValveCapability{
            .routes,
            .middleware,
        },
    },
    .init = initPlugin,
    .deinit = deinitPlugin,
};

fn initPlugin(valve: *Engine12.Valve, ctx: *Engine12.ValveContext) !void {
    if (!ctx.hasCapability(.routes)) return error.CapabilityRequired;
    
    try ctx.registerRoute("GET", "/api/plugin", handlePlugin);
    try ctx.registerMiddleware(&pluginMiddleware);
}
```

## Conclusion

This structure provides a solid foundation for Engine12 applications that:

- Maximizes use of Engine12's powerful features (`restApi`, `HandlerCtx`, Valves)
- Scales from small to medium-large projects
- Maintains clear separation of concerns
- Follows intuitive organization patterns
- Supports both API and server-rendered applications
- Facilitates team collaboration and onboarding
- Reduces boilerplate code significantly

Adjust the structure as needed for your specific project requirements, but use this as a starting point for consistency and maintainability. The key is to leverage Engine12's features rather than reinventing them.

