# Troubleshooting Guide

Common issues and solutions when using Engine12.

## Build Issues

### Dependency Errors

**Problem**: `zig build` fails with dependency errors.

**Solution**: Run `zig build --fetch` to fetch dependencies:

```bash
zig build --fetch
zig build
```

### Compilation Errors

**Problem**: Compilation errors related to missing includes or undefined symbols.

**Solution**: Ensure you've added the Engine12 module correctly in `build.zig`:

```zig
exe.addModule("Engine12", Engine12.module("Engine12"));
exe.linkLibC(); // Required for SQLite
```

### Version Mismatch

**Problem**: Errors about Zig version compatibility.

**Solution**: Ensure you're using Zig 0.15.1 or later. Check your version:

```bash
zig version
```

Update if needed or adjust `minimum_zig_version` in `build.zig.zon`.

## Runtime Issues

### Server Won't Start

**Problem**: Server fails to start with "port already in use" error.

**Solution**: 
1. Check if another process is using port 8080:
   ```bash
   lsof -i :8080
   ```
2. Kill the process or change the port in `src/engine12.zig` (default: 8080)

**Problem**: Server starts but immediately exits.

**Solution**: Ensure you're keeping the main thread alive:

```zig
// Keep server running
std.Thread.sleep(std.time.ns_per_min * 60);
```

Or use a signal handler for graceful shutdown.

### Routes Not Working

**Problem**: Routes return 404 Not Found.

**Solution**:
1. Verify routes are registered before `app.start()`
2. Check route patterns match exactly (including leading `/`)
3. Ensure route parameters use `:param` syntax:
   ```zig
   try app.get("/todos/:id", handleTodo); // Correct
   try app.get("/todos/{id}", handleTodo); // Wrong
   ```

**Problem**: Route handler receives wrong parameters.

**Solution**: 
1. Check parameter names match route pattern:
   ```zig
   // Route: /todos/:id
   const id = req.paramTyped(i64, "id") catch {
       return Response.errorResponse("Invalid ID", 400);
   }; // Correct - type-safe parsing
   const todo_id = req.paramTyped(i64, "todo_id") catch {
       return Response.errorResponse("Invalid ID", 400);
   }; // Wrong - parameter name doesn't match route
   ```

2. Use `paramTyped()` for type-safe parsing:
   ```zig
   // Type-safe route parameter parsing
   const id = req.paramTyped(i64, "id") catch {
       return Response.errorResponse("Invalid ID", 400);
   };
   ```

### Query Parameter Errors

**Problem**: Query parameter methods return unexpected results.

**Solution**: Use the appropriate method for your use case:

1. **Type-safe optional parameters** - Use `queryParamTyped()` for automatic type conversion:
   ```zig
   const limit = req.queryParamTyped(u32, "limit") catch 20 orelse 20;
   const page = req.queryParamTyped(u32, "page") catch 1 orelse 1;
   ```

2. **Type-safe required parameters** - Use `queryParamTyped()` with error handling:
   ```zig
   const id = req.queryParamTyped(i64, "id") catch {
       return Response.errorResponse("Invalid ID parameter", 400);
   } orelse {
       return Response.errorResponse("Missing ID parameter", 400);
   };
   ```

3. **Legacy methods** - Still available for backward compatibility:
   ```zig
   // Optional parameter
   const limit = req.queryOptional("limit");
   if (limit) |l| {
       const limit_u32 = try std.fmt.parseInt(u32, l, 10);
   }
   
   // Required parameter
   const filter = req.queryStrict("filter") catch {
       return Response.errorResponse("Missing filter parameter", 400);
   };
   ```

**Common errors:**
- `error.InvalidArgument` - Type conversion failed when using `queryParamTyped()` or `paramTyped()`
- `error.ParameterMissing` - Parameter not found when using `paramTyped()`
- Solution: Check parameter name spelling, ensure type matches (u32, i64, etc.), or use optional handling with `orelse`

### Database Connection Errors

**Problem**: "Database not initialized" error.

**Solution**: Ensure database is initialized before use:

```zig
try database.init();
defer database.close();
```

**Problem**: "Database is locked" error.

**Solution**: 
1. Ensure only one connection per database file (or use connection pooling)
2. Close connections properly:
   ```zig
   defer db.close();
   ```
3. Check for long-running transactions

**Problem**: Database file permissions error.

**Solution**: Ensure the application has write permissions to the database directory:

```bash
chmod 755 /path/to/database/directory
```

### ORM Issues

**Problem**: "Todo not found" even when record exists.

**Solution**: 
1. Check table name matches struct name (case-sensitive)
2. Verify ID field exists and is named `id`
3. Ensure `id` field is `i64` type

**Problem**: Query returns wrong data types.

**Solution**: 
1. Ensure struct field types match database column types
2. Text fields must be `[]u8` or `[]const u8`
3. Integer fields must be `i64` or `i32`

**Problem**: Memory leaks with ORM queries.

**Solution**: Always free allocated strings:

```zig
var todos = try orm.findAll(Todo);
defer {
    for (todos.items) |todo| {
        allocator.free(todo.title);
        allocator.free(todo.description);
    }
    todos.deinit(allocator);
}
```

**Problem**: `findAll()` or `where()` fails with `error.ColumnMismatch`.

**Solution**: 
1. Check that the number of struct fields matches the number of database columns
2. Ensure your `SELECT *` query returns the expected columns
3. Verify table schema matches struct definition:
   ```zig
   // Struct has 3 fields
   const User = struct {
       id: i64,
       name: []u8,
       age: i32,
   };
   
   // Table must have exactly 3 columns
   // CREATE TABLE User (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)
   ```
4. Check error messages for detailed context - they include:
   - Table name
   - SQL query executed
   - Expected vs actual column count

**Problem**: `findAll()` fails silently or returns generic errors.

**Solution**: 
The ORM now provides detailed error messages. Check debug output for:
- Table name
- SQL query
- Column count mismatch details
- Field type information

If you're catching errors generically, update your error handling:

```zig
var todos = orm.findAll(Todo) catch |err| {
    std.debug.print("ORM error: {}\n", .{err});
    // Error messages now include table name, SQL, and column info
    return Response.status(500).withJson("{\"error\":\"Failed to fetch todos\"}");
};
```

**Problem**: Need to pass ORM instance to handlers but `init()` returns a value.

**Solution**: Use `initPtr()` for pointer-based initialization:

```zig
// In initialization code
var orm = try ORM.initPtr(db, allocator);
defer orm.deinitPtr(allocator);

// Can now pass orm pointer to handlers
try app.get("/todos", handleTodos, orm);
```

Or use a singleton pattern:

```zig
var global_orm: ?ORM = null;

pub fn init() !void {
    global_db = try Database.open("app.db", allocator);
    global_orm = ORM.init(global_db.?, allocator);
}

pub fn getORM() !*ORM {
    if (global_orm) |*orm| {
        return orm;
    }
    return error.DatabaseNotInitialized;
}
```

## Migration Issues

**Problem**: "Duplicate migration version" error.

**Solution**: 
1. Check migration versions are unique
2. Ensure migrations are sorted by version
3. Remove duplicate migrations from the list

**Problem**: Migration fails partway through.

**Solution**: 
1. Check migration SQL syntax
2. Verify database state matches expected state
3. Use transactions for multi-step migrations:
   ```zig
   var trans = try db.beginTransaction();
   defer trans.deinit();
   try trans.execute("...");
   try trans.commit();
   ```

**Problem**: Can't rollback migration.

**Solution**: 
1. Ensure `down` SQL is correct
2. Check if migration was already applied
3. Verify migration version exists in `schema_migrations` table

## Template Issues

**Problem**: Template compilation error.

**Solution**: 
1. Check template syntax:
   - Variables: `{{ .field }}`
   - Raw variables: `{{! .field }}`
2. Ensure context struct matches template fields
3. Check file path is correct for `@embedFile`

**Problem**: Template renders empty or wrong data.

**Solution**: 
1. Verify context struct fields match template references
2. Check field names are correct (case-sensitive)
3. Ensure data is populated before rendering

## Middleware Issues

**Problem**: Middleware not executing.

**Solution**: 
1. Ensure middleware is registered before routes:
   ```zig
   try app.usePreRequest(authMiddleware);
   try app.get("/api/todos", handleTodos); // After middleware
   ```
2. Check middleware function signature matches expected type

**Problem**: Middleware aborts all requests.

**Solution**: 
1. Check middleware return value:
   ```zig
   fn middleware(req: *Request) MiddlewareResult {
       // Logic
       return .proceed; // Continue
       // return .abort; // Stop
   }
   ```
2. Verify middleware logic isn't always returning `.abort`

**Problem**: CORS headers not being added.

**Solution**:
1. Ensure CORS middleware is configured and registered:
   ```zig
   const cors = cors_middleware.CorsMiddleware.init(.{
       .allowed_origins = &[_][]const u8{"http://localhost:3000"},
   });
   cors.setGlobalConfig(); // Must call this before using middleware
   const cors_mw_fn = cors.preflightMwFn();
   try app.usePreRequest(cors_mw_fn);
   ```
2. Check that `Origin` header is present in the request
3. Verify origin is in `allowed_origins` list (or use `"*"` for all origins)
4. For preflight OPTIONS requests, ensure `Access-Control-Request-Method` and `Access-Control-Request-Headers` are allowed

**Problem**: Request ID header not appearing in responses.

**Solution**:
1. Ensure Request ID middleware is registered:
   ```zig
   const req_id_mw = request_id_middleware.RequestIdMiddleware.init(.{});
   const req_id_mw_fn = req_id_mw.preRequestMwFn();
   try app.usePreRequest(req_id_mw_fn);
   ```
2. Request IDs are automatically generated - middleware only ensures they're exposed via headers
3. Access request ID in handlers via `req.requestId()`

## Performance Issues

### Memory Leaks

**Problem**: Memory usage grows over time.

**Solution**: 
1. Ensure all allocations are freed:
   ```zig
   defer allocator.free(allocated_string);
   ```
2. Check for circular references
3. Use arena allocators for temporary allocations
4. Verify request cleanup happens

### Slow Queries

**Problem**: Database queries are slow.

**Solution**: 
1. Add indexes:
   ```sql
   CREATE INDEX idx_todos_completed ON todos(completed);
   ```
2. Use `EXPLAIN QUERY PLAN` to analyze queries
3. Consider connection pooling for concurrent requests
4. Use transactions for multiple operations

### High CPU Usage

**Problem**: Server uses high CPU.

**Solution**: 
1. Check for tight loops in handlers
2. Verify background tasks aren't running too frequently
3. Profile with `perf` or similar tools
4. Check for inefficient template rendering

## Debugging Tips

### Enable Debug Logging

Add debug prints in handlers:

```zig
fn handleRequest(req: *Request) Response {
    std.debug.print("Request: {s} {s}\n", .{req.method(), req.path()});
    // Handler logic
}
```

### Check Server Status

Use `printStatus()` to see server state:

```zig
app.printStatus();
// Output:
// Server ready
//   Status: RUNNING | Health: healthy | Routes: 5 | Tasks: 2
```

### Inspect Requests

Log request details:

```zig
fn debugMiddleware(req: *Request) MiddlewareResult {
    std.debug.print("Method: {s}\n", .{req.method()});
    std.debug.print("Path: {s}\n", .{req.path()});
    std.debug.print("Body: {s}\n", .{req.body()});
    return .proceed;
}
```

### Database Debugging

Check database state:

```zig
var result = try db.query("SELECT * FROM schema_migrations");
defer result.deinit();
while (result.nextRow()) |row| {
    std.debug.print("Migration: {d}\n", .{row.getInt64(0)});
}
```

### Common Error Messages

**"Too many routes"**
- Solution: Reduce number of routes or increase `MAX_ROUTES` constant (default limit is 5000 routes)

**"Server already built"**
- Solution: Register all routes before calling `app.start()`

**"Invalid argument"**
- Solution: Check function parameters match expected types

**"Query failed"**
- Solution: Check SQL syntax and database state

**"QueryParameterMissing"**
- Solution: Query parameter is required but not provided. Use `queryOptional()` if parameter is optional, or ensure client sends the parameter.

**"InvalidArgument"**
- Solution: Type conversion failed for `queryParamTyped()` or `paramTyped()`. Check that the parameter value matches the expected type (e.g., integer for `u32`, valid boolean string for `bool`).

**"ParameterMissing"**
- Solution: Route parameter is missing when using `paramTyped()`. Check that the route pattern includes the parameter (e.g., `/todos/:id`), and the parameter name matches exactly.

**ORM Error Messages**

The ORM provides improved error messages with context:
- **Field name errors**: Errors include the exact field name that caused the issue
- **Type mismatch errors**: Shows expected vs actual types
- **Missing field errors**: Lists available fields and suggests correct field names
- **Actionable suggestions**: Errors provide hints on how to fix the issue

**Template Engine Error Messages**

The template engine provides improved error messages:
- **Field access errors**: Includes context type and field name
- **Type information**: Shows what type was expected vs what was found
- **Available fields**: Lists fields available in the context struct
- **Suggestions**: Provides hints for common mistakes (e.g., checking struct definition, using correct field names)

## Pagination Issues

**Problem**: `Pagination.fromRequest()` returns `error.InvalidArgument`.

**Solution**:
1. Check that `page` parameter is >= 1:
   ```zig
   const pagination = Pagination.fromRequest(req) catch {
       return Response.errorResponse("Invalid pagination: page must be >= 1", 400);
   };
   ```
2. Check that `limit` parameter is between 1 and 100:
   ```zig
   // Limit must be between 1 and 100
   const pagination = Pagination.fromRequest(req) catch {
       return Response.errorResponse("Invalid pagination: limit must be between 1 and 100", 400);
   };
   ```
3. Ensure query parameters are valid integers:
   ```zig
   // Use queryParamTyped for type-safe parsing
   const page = req.queryParamTyped(u32, "page") catch 1 orelse 1;
   const limit = req.queryParamTyped(u32, "limit") catch 20 orelse 20;
   ```

**Problem**: Pagination metadata shows incorrect `total_pages`.

**Solution**:
1. Ensure `total` count is accurate (use `COUNT(*)` query)
2. Check that `Pagination.toResponse()` is called with the correct total:
   ```zig
   const total = try countTodos(); // Get accurate count
   const meta = pagination.toResponse(total);
   ```

## Getting Help

If you encounter issues not covered here:

1. Check the [API Reference](api-reference.md) for correct usage
2. Review the [Tutorial](tutorial.md) for examples
3. Check the [Examples](examples/todo-app.md) for working code
4. File an issue on GitHub with:
   - Error message
   - Minimal reproduction code
   - Zig version
   - System information

