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
   const id = req.param("id"); // Correct
   const todo_id = req.param("todo_id"); // Wrong
   ```

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
- Solution: Reduce number of routes or increase `MAX_ROUTES` constant

**"Server already built"**
- Solution: Register all routes before calling `app.start()`

**"Invalid argument"**
- Solution: Check function parameters match expected types

**"Query failed"**
- Solution: Check SQL syntax and database state

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

