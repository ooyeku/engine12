const std = @import("std");
const E12 = @import("Engine12");
const Request = E12.Request;
const Response = E12.Response;
const validation = E12.validation;
const middleware_chain = E12.middleware;
const rate_limit = E12.rate_limit;
const cache = E12.cache;
const templates = E12.templates;
const Database = E12.orm.Database;
const ORM = E12.orm.ORM;
const Logger = E12.Logger;
const LogLevel = E12.LogLevel;
const ResponseCache = E12.ResponseCache;
const error_handler = E12.error_handler;
const ErrorResponse = error_handler.ErrorResponse;

const allocator = std.heap.page_allocator;

// ============================================================================
// TODO MODEL & DATABASE
// ============================================================================

const Todo = struct {
    id: i64,
    title: []u8,
    description: []u8,
    completed: bool,
    priority: []u8,
    due_date: ?i64,
    tags: []u8,
    created_at: i64,
    updated_at: i64,
};

var global_db: ?Database = null;
var global_orm: ?ORM = null;
var db_mutex: std.Thread.Mutex = .{};
var global_logger: ?*Logger = null;
var logger_mutex: std.Thread.Mutex = .{};
var global_cache: ?*ResponseCache = null;
var cache_mutex: std.Thread.Mutex = .{};

fn getLogger() ?*Logger {
    logger_mutex.lock();
    defer logger_mutex.unlock();
    return global_logger;
}

fn getORM() !*ORM {
    db_mutex.lock();
    defer db_mutex.unlock();

    if (global_orm) |*orm| {
        return orm;
    }

    return error.DatabaseNotInitialized;
}

fn initDatabase() !void {
    db_mutex.lock();
    defer db_mutex.unlock();

    if (global_db != null) {
        return; // Already initialized
    }

    // Open database file
    const db_path = "todo.db";
    global_db = try Database.open(db_path, allocator);

    // Initialize ORM first (needed for migrations)
    global_orm = ORM.init(global_db.?, allocator);

    // Define migrations
    // Note: Using inline Migration struct since it's not exported from E12.orm
    // The struct matches the Migration type from src/orm/migration.zig
    const MigrationType = struct {
        version: u32,
        name: []const u8,
        up: []const u8,
        down: []const u8,
        
        pub fn init(version: u32, name: []const u8, up: []const u8, down: []const u8) @This() {
            return @This(){
                .version = version,
                .name = name,
                .up = up,
                .down = down,
            };
        }
    };
    
    const migrations = [_]MigrationType{
        MigrationType.init(1, "create_todos",
            \\CREATE TABLE IF NOT EXISTS Todo (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  title TEXT NOT NULL,
            \\  description TEXT NOT NULL,
            \\  completed INTEGER NOT NULL DEFAULT 0,
            \\  created_at INTEGER NOT NULL,
            \\  updated_at INTEGER NOT NULL
            \\)
        ,
            "DROP TABLE IF EXISTS Todo"),
        
        MigrationType.init(2, "add_priority",
            "ALTER TABLE Todo ADD COLUMN priority TEXT NOT NULL DEFAULT 'medium'",
            "ALTER TABLE Todo DROP COLUMN priority"),
        
        MigrationType.init(3, "add_due_date",
            "ALTER TABLE Todo ADD COLUMN due_date INTEGER",
            "-- Cannot automatically reverse ALTER TABLE ADD COLUMN"),
        
        MigrationType.init(4, "add_tags",
            "ALTER TABLE Todo ADD COLUMN tags TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE Todo DROP COLUMN tags"),
    };

    // Run migrations manually since Migration type is not exported
    // This executes the same logic as the migration system
    // Create migrations table if it doesn't exist
    global_db.?.execute(
        \\CREATE TABLE IF NOT EXISTS schema_migrations (
        \\  version INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  applied_at INTEGER NOT NULL
        \\);
    ) catch {};
    
    // Execute each migration if not already applied
    for (migrations) |migration| {
        // Check if migration is already applied
        const check_sql = std.fmt.allocPrint(allocator, "SELECT COUNT(*) FROM schema_migrations WHERE version = {d}", .{migration.version}) catch continue;
        defer allocator.free(check_sql);
        var check_result = global_db.?.query(check_sql) catch continue;
        defer check_result.deinit();
        
        var already_applied = false;
        if (check_result.nextRow()) |row| {
            already_applied = row.getInt64(0) > 0;
        }
        
        if (!already_applied) {
            // Execute migration
            global_db.?.execute(migration.up) catch continue;
            
            // Record migration
            const timestamp = std.time.timestamp();
            const record_sql = std.fmt.allocPrint(allocator, "INSERT INTO schema_migrations (version, name, applied_at) VALUES ({d}, '{s}', {d})", .{ migration.version, migration.name, timestamp }) catch continue;
            defer allocator.free(record_sql);
            global_db.?.execute(record_sql) catch continue;
        }
    }
}

const TodoStats = struct {
    total: u32,
    completed: u32,
    pending: u32,
    completed_percentage: f32,
    overdue: u32,
};

fn createTodo(orm: *ORM, title: []const u8, description: []const u8, priority: []const u8, due_date: ?i64, tags: []const u8) !Todo {
    const now = std.time.milliTimestamp();
    const title_copy = try allocator.dupe(u8, title);
    errdefer allocator.free(title_copy);
    const desc_copy = try allocator.dupe(u8, description);
    errdefer allocator.free(desc_copy);
    const priority_copy = try allocator.dupe(u8, priority);
    errdefer allocator.free(priority_copy);
    const tags_copy = try allocator.dupe(u8, tags);
    errdefer allocator.free(tags_copy);

    const todo = Todo{
        .id = 0,
        .title = title_copy,
        .description = desc_copy,
        .completed = false,
        .priority = priority_copy,
        .due_date = due_date,
        .tags = tags_copy,
        .created_at = now,
        .updated_at = now,
    };

    try orm.create(Todo, todo);

    // Get the last insert row ID
    const last_id = orm.db.lastInsertRowId() catch {
        // Fallback: query for the most recently created todo
        var all_todos = try orm.findAll(Todo);
        defer {
            for (all_todos.items) |t| {
                allocator.free(t.title);
                allocator.free(t.description);
                allocator.free(t.priority);
                allocator.free(t.tags);
            }
            all_todos.deinit(allocator);
        }

        if (all_todos.items.len == 0) {
            return error.FailedToCreateTodo;
        }

        // Find the todo with the highest ID
        var max_id: i64 = 0;
        var found_todo: ?Todo = null;
        for (all_todos.items) |t| {
            if (t.id > max_id) {
                max_id = t.id;
                found_todo = t;
            }
        }

        if (found_todo) |t| {
            return Todo{
                .id = t.id,
                .title = try allocator.dupe(u8, t.title),
                .description = try allocator.dupe(u8, t.description),
                .completed = t.completed,
                .priority = try allocator.dupe(u8, t.priority),
                .due_date = t.due_date,
                .tags = try allocator.dupe(u8, t.tags),
                .created_at = t.created_at,
                .updated_at = t.updated_at,
            };
        }

        return error.FailedToCreateTodo;
    };

    // Fetch the created todo by ID
    const created = try orm.find(Todo, last_id);
    if (created) |t| {
        defer {
            allocator.free(t.title);
            allocator.free(t.description);
            allocator.free(t.priority);
            allocator.free(t.tags);
        }
        return Todo{
            .id = t.id,
            .title = try allocator.dupe(u8, t.title),
            .description = try allocator.dupe(u8, t.description),
            .completed = t.completed,
            .priority = try allocator.dupe(u8, t.priority),
            .due_date = t.due_date,
            .tags = try allocator.dupe(u8, t.tags),
            .created_at = t.created_at,
            .updated_at = t.updated_at,
        };
    }

    return error.FailedToCreateTodo;
}

fn findTodoById(orm: *ORM, id: i64) !?Todo {
    const todo = try orm.find(Todo, id);
    return todo;
}

fn getAllTodos(orm: *ORM) !std.ArrayListUnmanaged(Todo) {
    return try orm.findAll(Todo);
}

fn updateTodo(orm: *ORM, id: i64, updates: struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    completed: ?bool = null,
    priority: ?[]const u8 = null,
    due_date: ?i64 = null,
    tags: ?[]const u8 = null,
}) !?Todo {
    const existing = try orm.find(Todo, id);
    if (existing == null) return null;

    var todo = existing.?;
    defer {
        allocator.free(todo.title);
        allocator.free(todo.description);
        allocator.free(todo.priority);
        allocator.free(todo.tags);
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

    if (updates.priority) |priority| {
        allocator.free(todo.priority);
        todo.priority = try allocator.dupe(u8, priority);
    }

    if (updates.due_date) |due_date| {
        todo.due_date = due_date;
    }

    if (updates.tags) |tags| {
        allocator.free(todo.tags);
        todo.tags = try allocator.dupe(u8, tags);
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
        .priority = try allocator.dupe(u8, todo.priority),
        .due_date = todo.due_date,
        .tags = try allocator.dupe(u8, todo.tags),
        .created_at = todo.created_at,
        .updated_at = todo.updated_at,
    };
}

fn deleteTodo(orm: *ORM, id: i64) !bool {
    const existing = try orm.find(Todo, id);
    if (existing == null) return false;

    defer {
        allocator.free(existing.?.title);
        allocator.free(existing.?.description);
        allocator.free(existing.?.priority);
        allocator.free(existing.?.tags);
    }

    try orm.delete(Todo, id);
    return true;
}

fn getStats(orm: *ORM) !TodoStats {
    var all_todos = try orm.findAll(Todo);
    defer {
        for (all_todos.items) |t| {
            allocator.free(t.title);
            allocator.free(t.description);
            allocator.free(t.priority);
            allocator.free(t.tags);
        }
        all_todos.deinit(allocator);
    }

    var total: u32 = 0;
    var completed: u32 = 0;
    var overdue: u32 = 0;
    const now = std.time.milliTimestamp();

    for (all_todos.items) |todo| {
        total += 1;
        if (todo.completed) {
            completed += 1;
        } else if (todo.due_date) |due_date| {
            if (due_date < now) {
                overdue += 1;
            }
        }
    }

    const pending = total - completed;
    const completed_percentage = if (total > 0)
        (@as(f32, @floatFromInt(completed)) / @as(f32, @floatFromInt(total))) * 100.0
    else
        0.0;

    return TodoStats{
        .total = total,
        .completed = completed,
        .pending = pending,
        .completed_percentage = completed_percentage,
        .overdue = overdue,
    };
}

// ============================================================================
// JSON UTILITIES
// ============================================================================

fn formatTodoJson(todo: Todo, alloc: std.mem.Allocator) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(alloc);

    const due_date_str = if (todo.due_date) |dd| try std.fmt.allocPrint(alloc, "{}", .{dd}) else try alloc.dupe(u8, "null");
    defer alloc.free(due_date_str);

    try list.writer(alloc).print(
        \\{{"id":{},"title":"{s}","description":"{s}","completed":{},"priority":"{s}","due_date":{s},"tags":"{s}","created_at":{},"updated_at":{}}}
    , .{ todo.id, todo.title, todo.description, todo.completed, todo.priority, due_date_str, todo.tags, todo.created_at, todo.updated_at });

    return list.toOwnedSlice(alloc);
}

fn formatTodoListJson(todos: std.ArrayListUnmanaged(Todo), alloc: std.mem.Allocator) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(alloc);

    try list.writer(alloc).print("[", .{});

    for (todos.items, 0..) |todo, i| {
        if (i > 0) {
            try list.writer(alloc).print(",", .{});
        }
        const todo_json = try formatTodoJson(todo, alloc);
        defer alloc.free(todo_json);
        try list.writer(alloc).print("{s}", .{todo_json});
    }

    try list.writer(alloc).print("]", .{});
    return list.toOwnedSlice(alloc);
}

fn formatStatsJson(stats: TodoStats, alloc: std.mem.Allocator) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(alloc);

    try list.writer(alloc).print(
        \\{{"total":{},"completed":{},"pending":{},"completed_percentage":{d:.2},"overdue":{}}}
    , .{ stats.total, stats.completed, stats.pending, stats.completed_percentage, stats.overdue });

    return list.toOwnedSlice(alloc);
}

fn parseTodoFromJson(json_str: []const u8, alloc: std.mem.Allocator) !struct {
    title: []const u8,
    description: []const u8,
    completed: ?bool,
    priority: ?[]const u8,
    due_date: ?i64,
    tags: ?[]const u8,
} {
    var title: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var completed: ?bool = null;
    var priority: ?[]const u8 = null;
    var due_date: ?i64 = null;
    var tags: ?[]const u8 = null;

    var i: usize = 0;
    while (i < json_str.len) {
        if (std.mem.indexOf(u8, json_str[i..], "\"title\"") != null) {
            const title_start = std.mem.indexOf(u8, json_str[i..], "\"title\"") orelse break;
            const colon = std.mem.indexOf(u8, json_str[i + title_start ..], ":") orelse break;
            const quote_start = std.mem.indexOf(u8, json_str[i + title_start + colon ..], "\"") orelse break;
            const val_start = i + title_start + colon + quote_start + 1;
            const quote_end = std.mem.indexOf(u8, json_str[val_start..], "\"") orelse break;
            title = try alloc.dupe(u8, json_str[val_start .. val_start + quote_end]);
            i = val_start + quote_end;
        } else if (std.mem.indexOf(u8, json_str[i..], "\"description\"") != null) {
            const desc_start = std.mem.indexOf(u8, json_str[i..], "\"description\"") orelse break;
            const colon = std.mem.indexOf(u8, json_str[i + desc_start ..], ":") orelse break;
            const quote_start = std.mem.indexOf(u8, json_str[i + desc_start + colon ..], "\"") orelse break;
            const val_start = i + desc_start + colon + quote_start + 1;
            const quote_end = std.mem.indexOf(u8, json_str[val_start..], "\"") orelse break;
            description = try alloc.dupe(u8, json_str[val_start .. val_start + quote_end]);
            i = val_start + quote_end;
        } else if (std.mem.indexOf(u8, json_str[i..], "\"completed\"") != null) {
            const comp_start = std.mem.indexOf(u8, json_str[i..], "\"completed\"") orelse break;
            const colon = std.mem.indexOf(u8, json_str[i + comp_start ..], ":") orelse break;
            const val_start = i + comp_start + colon + 1;
            if (std.mem.startsWith(u8, json_str[val_start..], "true")) {
                completed = true;
                i = val_start + 4;
            } else if (std.mem.startsWith(u8, json_str[val_start..], "false")) {
                completed = false;
                i = val_start + 5;
            } else {
                break;
            }
        } else if (std.mem.indexOf(u8, json_str[i..], "\"priority\"") != null) {
            const priority_start = std.mem.indexOf(u8, json_str[i..], "\"priority\"") orelse break;
            const colon = std.mem.indexOf(u8, json_str[i + priority_start ..], ":") orelse break;
            const quote_start = std.mem.indexOf(u8, json_str[i + priority_start + colon ..], "\"") orelse break;
            const val_start = i + priority_start + colon + quote_start + 1;
            const quote_end = std.mem.indexOf(u8, json_str[val_start..], "\"") orelse break;
            priority = try alloc.dupe(u8, json_str[val_start .. val_start + quote_end]);
            i = val_start + quote_end;
        } else if (std.mem.indexOf(u8, json_str[i..], "\"due_date\"") != null) {
            const due_start = std.mem.indexOf(u8, json_str[i..], "\"due_date\"") orelse break;
            const colon = std.mem.indexOf(u8, json_str[i + due_start ..], ":") orelse break;
            const val_start = i + due_start + colon + 1;
            // Skip whitespace
            var j = val_start;
            while (j < json_str.len and (json_str[j] == ' ' or json_str[j] == '\t')) j += 1;
            if (std.mem.startsWith(u8, json_str[j..], "null")) {
                due_date = null;
                i = j + 4;
            } else {
                // Parse number
                var num_end = j;
                while (num_end < json_str.len and json_str[num_end] >= '0' and json_str[num_end] <= '9') {
                    num_end += 1;
                }
                if (num_end > j) {
                    const num_str = json_str[j..num_end];
                    due_date = try std.fmt.parseInt(i64, num_str, 10);
                    i = num_end;
                } else {
                    break;
                }
            }
        } else if (std.mem.indexOf(u8, json_str[i..], "\"tags\"") != null) {
            const tags_start = std.mem.indexOf(u8, json_str[i..], "\"tags\"") orelse break;
            const colon = std.mem.indexOf(u8, json_str[i + tags_start ..], ":") orelse break;
            const quote_start = std.mem.indexOf(u8, json_str[i + tags_start + colon ..], "\"") orelse break;
            const val_start = i + tags_start + colon + quote_start + 1;
            const quote_end = std.mem.indexOf(u8, json_str[val_start..], "\"") orelse break;
            tags = try alloc.dupe(u8, json_str[val_start .. val_start + quote_end]);
            i = val_start + quote_end;
        } else {
            i += 1;
        }
    }

    return .{
        .title = title orelse "",
        .description = description orelse "",
        .completed = completed,
        .priority = priority,
        .due_date = due_date,
        .tags = tags,
    };
}

fn handleIndex(request: *Request) Response {
    _ = request;

    // Compile template at comptime - embed template content directly
    // Template is in the same directory structure (todo/src/templates/)
    const template_content = @embedFile("templates/index.zt.html");
    const IndexTemplate = templates.Template.compile(template_content);

    // Define context type
    const IndexContext = struct {
        title: []const u8,
        subtitle: []const u8,
        title_placeholder: []const u8,
        description_placeholder: []const u8,
        add_button_text: []const u8,
        filter_all: []const u8,
        filter_pending: []const u8,
        filter_completed: []const u8,
        empty_state_message: []const u8,
    };

    // Create context
    const context = IndexContext{
        .title = "Todo List",
        .subtitle = "Enter your todos here",
        .title_placeholder = "Enter todo title...",
        .description_placeholder = "Enter description (optional)...",
        .add_button_text = "Add Todo",
        .filter_all = "All",
        .filter_pending = "Pending",
        .filter_completed = "Completed",
        .empty_state_message = "No todos yet. Add one above to get started!",
    };

    // Render template - use page allocator for persistent memory
    // Response.html() expects memory that persists beyond the request
    const html = IndexTemplate.render(IndexContext, context, allocator) catch {
        return Response.text("Internal server error: template rendering failed").withStatus(500);
    };

    return Response.html(html)
        .withHeader("Cache-Control", "no-cache, no-store, must-revalidate")
        .withHeader("Pragma", "no-cache")
        .withHeader("Expires", "0");
}

// ============================================================================
// REQUEST HANDLERS
// ============================================================================

fn handleGetTodos(request: *Request) Response {
    // Check cache first
    const cache_key = "todos:all";
    if (request.cacheGet(cache_key) catch null) |entry| {
        return Response.text(entry.body)
            .withContentType(entry.content_type)
            .withHeader("X-Cache", "HIT");
    }

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
            allocator.free(todo.priority);
            allocator.free(todo.tags);
        }
        todos.deinit(allocator);
    }

    const json = formatTodoListJson(todos, allocator) catch {
        return Response.json("{\"error\":\"Failed to format todos\"}").withStatus(500);
    };
    defer allocator.free(json);
    
    // Cache the result for 30 seconds
    request.cacheSet(cache_key, json, 30000, "application/json") catch {};
    
    return Response.json(json)
        .withHeader("X-Cache", "MISS");
}

fn handleGetTodo(request: *Request) Response {
    const id = request.param("id").asI64() catch {
        return Response.json("{\"error\":\"Invalid ID\"}").withStatus(400);
    };

    const orm = getORM() catch {
        return Response.json("{\"error\":\"Database not initialized\"}").withStatus(500);
    };

    const todo = findTodoById(orm, id) catch {
        return Response.json("{\"error\":\"Failed to fetch todo\"}").withStatus(500);
    };

    const found = todo orelse {
        return Response.json("{\"error\":\"Todo not found\"}").withStatus(404);
    };
    defer {
        allocator.free(found.title);
        allocator.free(found.description);
        allocator.free(found.priority);
        allocator.free(found.tags);
    }

    const json = formatTodoJson(found, allocator) catch {
        return Response.json("{\"error\":\"Failed to format todo\"}").withStatus(500);
    };
    defer allocator.free(json);
    return Response.json(json)
        .withHeader("Cache-Control", "no-cache, no-store, must-revalidate")
        .withHeader("Pragma", "no-cache")
        .withHeader("Expires", "0");
}

fn handleCreateTodo(request: *Request) Response {
    const parsed = parseTodoFromJson(request.body(), allocator) catch {
        return Response.json("{\"error\":\"Invalid JSON\"}");
    };
    defer {
        if (parsed.title.len > 0) allocator.free(parsed.title);
        if (parsed.description.len > 0) allocator.free(parsed.description);
        if (parsed.priority) |p| allocator.free(p);
        if (parsed.tags) |t| allocator.free(t);
    }

    // Use validation framework
    var schema = validation.ValidationSchema.init(request.arena.allocator());
    defer schema.deinit();

    // Validate title (required, max 200 chars)
    const title_validator = schema.field("title", parsed.title) catch {
        return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
    };
    title_validator.rule(validation.required) catch {
        return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
    };

    const titleMaxLength = struct {
        fn validate(value: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
            _ = alloc;
            if (value.len > 200) {
                return "Title must be 200 characters or less";
            }
            return null;
        }
    };
    title_validator.rule(titleMaxLength.validate) catch {
        return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
    };

    // Validate description if provided (max 1000 chars)
    if (parsed.description.len > 0) {
        const desc_validator = schema.field("description", parsed.description) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
        const descMaxLength = struct {
            fn validate(value: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
                _ = alloc;
                if (value.len > 1000) {
                    return "Description must be 1000 characters or less";
                }
                return null;
            }
        };
        desc_validator.rule(descMaxLength.validate) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
    }

    // Validate priority if provided
    if (parsed.priority) |priority| {
        const priority_validator = schema.field("priority", priority) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
        const validPriority = struct {
            fn validate(value: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
                _ = alloc;
                if (!std.mem.eql(u8, value, "low") and !std.mem.eql(u8, value, "medium") and !std.mem.eql(u8, value, "high")) {
                    return "Priority must be 'low', 'medium', or 'high'";
                }
                return null;
            }
        };
        priority_validator.rule(validPriority.validate) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
    }

    // Validate tags if provided (max 500 chars)
    if (parsed.tags) |tags| {
        const tags_validator = schema.field("tags", tags) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
        const tagsMaxLength = struct {
            fn validate(value: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
                _ = alloc;
                if (value.len > 500) {
                    return "Tags must be 500 characters or less";
                }
                return null;
            }
        };
        tags_validator.rule(tagsMaxLength.validate) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
    }

    // Run validation
    var validation_errors = schema.validate() catch {
        return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
    };
    defer validation_errors.deinit();

    if (!validation_errors.isEmpty()) {
        const error_json = validation_errors.toJson() catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
        defer allocator.free(error_json);
        return Response.json(error_json).withStatus(400);
    }

    const orm = getORM() catch {
        return Response.json("{\"error\":\"Database not initialized\"}").withStatus(500);
    };

    const priority_value = parsed.priority orelse "medium";
    const tags_value = parsed.tags orelse "";
    const todo = createTodo(orm, parsed.title, parsed.description, priority_value, parsed.due_date, tags_value) catch {
        return Response.json("{\"error\":\"Failed to create todo\"}").withStatus(500);
    };
    defer {
        allocator.free(todo.title);
        allocator.free(todo.description);
        allocator.free(todo.priority);
        allocator.free(todo.tags);
    }

    const json = formatTodoJson(todo, allocator) catch {
        return Response.json("{\"error\":\"Failed to format todo\"}").withStatus(500);
    };
    defer allocator.free(json);
    
    // Invalidate cache when todos change
    request.cacheInvalidate("todos:all");
    request.cacheInvalidate("todos:stats");
    
    return Response.json(json);
}

fn handleUpdateTodo(request: *Request) Response {
    const id = request.param("id").asI64() catch {
        return Response.json("{\"error\":\"Invalid ID\"}").withStatus(400);
    };

    const parsed = parseTodoFromJson(request.body(), allocator) catch {
        return Response.json("{\"error\":\"Invalid JSON\"}");
    };

    defer {
        if (parsed.title.len > 0) allocator.free(parsed.title);
        if (parsed.description.len > 0) allocator.free(parsed.description);
        if (parsed.priority) |p| allocator.free(p);
        if (parsed.tags) |t| allocator.free(t);
    }

    // Use validation framework
    var schema = validation.ValidationSchema.init(request.arena.allocator());
    defer schema.deinit();

    // Validate title if provided
    if (parsed.title.len > 0) {
        const title_validator = schema.field("title", parsed.title) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
        const titleMaxLength = struct {
            fn validate(value: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
                _ = alloc;
                if (value.len > 200) {
                    return "Title must be 200 characters or less";
                }
                return null;
            }
        };
        title_validator.rule(titleMaxLength.validate) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
    }

    // Validate description if provided
    if (parsed.description.len > 0) {
        const desc_validator = schema.field("description", parsed.description) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
        const descMaxLength = struct {
            fn validate(value: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
                _ = alloc;
                if (value.len > 1000) {
                    return "Description must be 1000 characters or less";
                }
                return null;
            }
        };
        desc_validator.rule(descMaxLength.validate) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
    }

    // Validate priority if provided
    if (parsed.priority) |priority| {
        const priority_validator = schema.field("priority", priority) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
        const validPriority = struct {
            fn validate(value: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
                _ = alloc;
                if (!std.mem.eql(u8, value, "low") and !std.mem.eql(u8, value, "medium") and !std.mem.eql(u8, value, "high")) {
                    return "Priority must be 'low', 'medium', or 'high'";
                }
                return null;
            }
        };
        priority_validator.rule(validPriority.validate) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
    }

    // Validate tags if provided (max 500 chars)
    if (parsed.tags) |tags| {
        const tags_validator = schema.field("tags", tags) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
        const tagsMaxLength = struct {
            fn validate(value: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
                _ = alloc;
                if (value.len > 500) {
                    return "Tags must be 500 characters or less";
                }
                return null;
            }
        };
        tags_validator.rule(tagsMaxLength.validate) catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
    }

    // Run validation
    var validation_errors = schema.validate() catch {
        return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
    };
    defer validation_errors.deinit();

    if (!validation_errors.isEmpty()) {
        const error_json = validation_errors.toJson() catch {
            return Response.json("{\"error\":\"Validation error\"}").withStatus(500);
        };
        defer allocator.free(error_json);
        return Response.json(error_json).withStatus(400);
    }

    const orm = getORM() catch {
        return Response.json("{\"error\":\"Database not initialized\"}").withStatus(500);
    };

    const updates = updateTodo(orm, id, .{
        .title = if (parsed.title.len > 0) parsed.title else null,
        .description = if (parsed.description.len > 0) parsed.description else null,
        .completed = parsed.completed,
        .priority = parsed.priority,
        .due_date = parsed.due_date,
        .tags = parsed.tags,
    }) catch {
        return Response.json("{\"error\":\"Failed to update todo\"}").withStatus(500);
    };

    const todo = updates orelse {
        return Response.json("{\"error\":\"Todo not found\"}").withStatus(404);
    };
    defer {
        allocator.free(todo.title);
        allocator.free(todo.description);
        allocator.free(todo.priority);
        allocator.free(todo.tags);
    }

    const json = formatTodoJson(todo, allocator) catch {
        return Response.json("{\"error\":\"Failed to format todo\"}").withStatus(500);
    };
    defer allocator.free(json);
    
    // Invalidate cache when todos change
    request.cacheInvalidate("todos:all");
    request.cacheInvalidate("todos:stats");
    // Also invalidate specific todo cache if we had one
    const todo_cache_key = std.fmt.allocPrint(request.arena.allocator(), "todo:{d}", .{id}) catch {
        // If allocation fails, just skip individual cache invalidation
        return Response.json(json);
    };
    request.cacheInvalidate(todo_cache_key);
    
    return Response.json(json);
}

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
        // Invalidate cache when todos change
        request.cacheInvalidate("todos:all");
        request.cacheInvalidate("todos:stats");
        const todo_cache_key = std.fmt.allocPrint(request.arena.allocator(), "todo:{d}", .{id}) catch {
            // If allocation fails, just skip individual cache invalidation
            return Response.json("{\"success\":true}");
        };
        request.cacheInvalidate(todo_cache_key);
        
        return Response.json("{\"success\":true}");
    } else {
        return Response.json("{\"error\":\"Todo not found\"}").withStatus(404);
    }
}

fn handleSearchTodos(request: *Request) Response {
    // NOTE: QueryBuilder Limitation
    // The Engine12 QueryBuilder doesn't currently support OR conditions in WHERE clauses.
    // For this search functionality that needs to search across multiple columns (title, description, tags)
    // with OR conditions, we use raw SQL instead.
    //
    // Example of QueryBuilder usage for simpler queries (without OR):
    // ```zig
    // var query = QueryBuilder.init(orm.db, "Todo");
    // query.where("completed", "=", "0");
    // query.orderBy("created_at", "DESC");
    // query.limit(10);
    // const result = query.execute();
    // ```
    //
    // For OR conditions or complex queries, raw SQL is the current approach.
    
    const query_param = request.query("q") catch {
        return Response.json("{\"error\":\"Missing query parameter\"}").withStatus(400);
    };

    const search_query = query_param orelse {
        return Response.json("{\"error\":\"Missing query parameter\"}").withStatus(400);
    };

    const orm = getORM() catch {
        return Response.json("{\"error\":\"Database not initialized\"}").withStatus(500);
    };

    // Escape single quotes for SQL safety (SQLite escapes by doubling)
    var escaped_query = std.ArrayListUnmanaged(u8){};
    defer escaped_query.deinit(request.arena.allocator());
    for (search_query) |char| {
        if (char == '\'') {
            escaped_query.append(request.arena.allocator(), '\'') catch {
                return Response.json("{\"error\":\"Failed to escape query\"}").withStatus(500);
            };
            escaped_query.append(request.arena.allocator(), '\'') catch {
                return Response.json("{\"error\":\"Failed to escape query\"}").withStatus(500);
            };
        } else {
            escaped_query.append(request.arena.allocator(), char) catch {
                return Response.json("{\"error\":\"Failed to escape query\"}").withStatus(500);
            };
        }
    }
    const safe_query = escaped_query.items;

    // Build search query - search in title, description, and tags
    const search_pattern = std.fmt.allocPrint(request.arena.allocator(), "%{s}%", .{safe_query}) catch {
        return Response.json("{\"error\":\"Failed to format search query\"}").withStatus(500);
    };
    const sql = std.fmt.allocPrint(request.arena.allocator(),
        \\SELECT * FROM Todo WHERE 
        \\  title LIKE '{s}' OR 
        \\  description LIKE '{s}' OR 
        \\  tags LIKE '{s}'
        \\ORDER BY created_at DESC
    , .{ search_pattern, search_pattern, search_pattern }) catch {
        return Response.json("{\"error\":\"Failed to build search query\"}").withStatus(500);
    };

    var result = orm.db.query(sql) catch {
        return Response.json("{\"error\":\"Failed to search todos\"}").withStatus(500);
    };
    defer result.deinit();

    var todos = result.toArrayList(Todo) catch {
        return Response.json("{\"error\":\"Failed to parse search results\"}").withStatus(500);
    };
    defer {
        for (todos.items) |todo| {
            allocator.free(todo.title);
            allocator.free(todo.description);
            allocator.free(todo.priority);
            allocator.free(todo.tags);
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

fn handleMetrics(request: *Request) Response {
    _ = request;
    // Access global metrics collector
    const metrics_collector = E12.engine12.global_metrics;
    
    if (metrics_collector) |mc| {
        const prometheus_output = mc.getPrometheusMetrics() catch {
            return Response.json("{\"error\":\"Failed to generate metrics\"}").withStatus(500);
        };
        defer std.heap.page_allocator.free(prometheus_output);
        
        var resp = Response.text(prometheus_output);
        resp = resp.withContentType("text/plain; version=0.0.4");
        return resp;
    }
    
    // Fallback if metrics collector not available
    return Response.json("{\"metrics\":{\"uptime_ms\":0,\"requests_total\":0}}");
}

fn handleGetStats(request: *Request) Response {
    // Check cache first (shorter TTL for dynamic data)
    const cache_key = "todos:stats";
    if (request.cacheGet(cache_key) catch null) |entry| {
        return Response.text(entry.body)
            .withContentType(entry.content_type)
            .withHeader("X-Cache", "HIT");
    }
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
    
    // Cache stats for 10 seconds (shorter TTL since stats change frequently)
    request.cacheSet(cache_key, json, 10000, "application/json") catch {};
    
    return Response.json(json)
        .withHeader("X-Cache", "MISS");
}

// ============================================================================
// MIDDLEWARE
// ============================================================================

fn customErrorHandler(req: *Request, err: ErrorResponse, alloc: std.mem.Allocator) Response {
    // Log error using structured logger
    if (getLogger()) |logger| {
        const log_level: LogLevel = switch (err.error_type) {
            .validation_error, .bad_request => .warn,
            .authentication_error, .authorization_error => .warn,
            .not_found => .info,
            .rate_limit_exceeded => .warn,
            .request_too_large => .warn,
            .timeout => .warn,
            .internal_error, .unknown => LogLevel.err,
        };
        
        const entry_opt = logger.log(log_level, err.message) catch null;
        if (entry_opt) |entry| {
            _ = entry.field("error_code", err.code) catch {};
            _ = entry.field("error_type", @tagName(err.error_type)) catch {};
            if (err.details) |details| {
                _ = entry.field("details", details) catch {};
            }
            // Include request ID if available
            if (req.get("request_id")) |request_id| {
                _ = entry.field("request_id", request_id) catch {};
            }
            entry.log();
        }
    }
    
    // Create JSON error response
    const json = err.toJson(alloc) catch {
        return Response.json("{\"error\":\"Failed to serialize error\"}").withStatus(500);
    };
    defer alloc.free(json);
    
    // Determine status code
    const status_code: u16 = switch (err.error_type) {
        .validation_error, .bad_request => 400,
        .authentication_error => 401,
        .authorization_error => 403,
        .not_found => 404,
        .rate_limit_exceeded => 429,
        .request_too_large => 413,
        .timeout => 408,
        .internal_error, .unknown => 500,
    };
    
    var resp = Response.json(json).withStatus(status_code);
    
    // Add request ID to response headers if available
    if (req.get("request_id")) |request_id| {
        resp = resp.withHeader("X-Request-ID", request_id);
    }
    
    return resp;
}

fn bodySizeLimitMiddleware(req: *Request) middleware_chain.MiddlewareResult {
    const MAX_BODY_SIZE: usize = 10 * 1024; // 10KB
    
    const body = req.body();
    if (body.len > MAX_BODY_SIZE) {
        // Set context flag
        req.set("body_size_exceeded", "true") catch {};
        
        // Abort request
        return .abort;
    }
    
    return .proceed;
}

fn csrfMiddleware(req: *Request) middleware_chain.MiddlewareResult {
    const method = req.method();
    
    // Skip CSRF check for safe methods
    if (std.mem.eql(u8, method, "GET") or 
        std.mem.eql(u8, method, "HEAD") or 
        std.mem.eql(u8, method, "OPTIONS")) {
        return .proceed;
    }
    
    // For POST/PUT/DELETE, check for CSRF token
    // Simplified implementation - in production, validate token against session
    const csrf_token = req.header("X-CSRF-Token");
    
    if (csrf_token == null or csrf_token.?.len == 0) {
        // Missing CSRF token - abort request
        return .abort;
    }
    
    // In a full implementation, we would validate the token here
    // For this example, we just check that it exists and is not empty
    // A real implementation would compare against a session-stored token
    
    return .proceed;
}

fn requestTrackingMiddleware(req: *Request) middleware_chain.MiddlewareResult {
    // Store request start time in context
    const start_time = std.time.milliTimestamp();
    const start_time_str = std.fmt.allocPrint(req.arena.allocator(), "{d}", .{start_time}) catch {
        // If allocation fails, just proceed without tracking
        return .proceed;
    };
    req.set("request_start_time", start_time_str) catch {};
    
    return .proceed;
}

fn loggingMiddleware(req: *Request) middleware_chain.MiddlewareResult {
    if (getLogger()) |logger| {
        const entry = logger.fromRequest(req, .info, "Request received") catch {
            // If logging fails, just proceed
            return .proceed;
        };
        
        // Add request timing if available
        if (req.get("request_start_time")) |start_time_str| {
            _ = entry.field("start_time", start_time_str) catch {};
        }
        
        // Add request ID if available
        if (req.get("request_id")) |request_id| {
            _ = entry.field("request_id", request_id) catch {};
        }
        
        entry.log();
    }
    return .proceed;
}

fn corsMiddleware(resp: Response) Response {
    return resp;
}

// ============================================================================
// BACKGROUND TASKS
// ============================================================================

const DAY_IN_MS: i64 = 24 * 60 * 60 * 1000;
const SEVEN_DAYS_MS: i64 = 7 * DAY_IN_MS;

fn cleanupOldCompletedTodos() void {
    const logger = getLogger();
    const orm = getORM() catch {
        if (logger) |l| {
            const entry = l.logError("Failed to get ORM for cleanup task") catch return;
            entry.log();
        }
        return;
    };
    const now = std.time.milliTimestamp();

    var cleaned: u32 = 0;

    var all_todos = getAllTodos(orm) catch {
        if (logger) |l| {
            const entry = l.logError("Failed to get todos for cleanup") catch return;
            entry.log();
        }
        return;
    };
    defer {
        for (all_todos.items) |todo| {
            allocator.free(todo.title);
            allocator.free(todo.description);
            allocator.free(todo.priority);
            allocator.free(todo.tags);
        }
        all_todos.deinit(allocator);
    }

    for (all_todos.items) |todo| {
        if (todo.completed and (now - todo.updated_at) > SEVEN_DAYS_MS) {
            _ = deleteTodo(orm, todo.id) catch continue;
            cleaned += 1;
        }
    }

    if (cleaned > 0) {
        if (logger) |l| {
            const entry = l.info("Cleaned up old completed todos") catch return;
            _ = entry.fieldInt("count", cleaned) catch return;
            entry.log();
        }
    }
}

fn checkOverdueTodos() void {
    const logger = getLogger();
    const orm = getORM() catch {
        if (logger) |l| {
            const entry = l.logError("Failed to get ORM for overdue check") catch return;
            entry.log();
        }
        return;
    };
    const now = std.time.milliTimestamp();

    var overdue_count: u32 = 0;

    var all_todos = getAllTodos(orm) catch {
        if (logger) |l| {
            const entry = l.logError("Failed to get todos for overdue check") catch return;
            entry.log();
        }
        return;
    };
    defer {
        for (all_todos.items) |todo| {
            allocator.free(todo.title);
            allocator.free(todo.description);
            allocator.free(todo.priority);
            allocator.free(todo.tags);
        }
        all_todos.deinit(allocator);
    }

    for (all_todos.items) |todo| {
        if (!todo.completed) {
            if (todo.due_date) |due_date| {
                if (due_date < now) {
                    overdue_count += 1;
                    if (logger) |l| {
                        const entry = l.warn("Overdue todo found") catch return;
                        _ = entry.field("title", todo.title) catch return;
                        _ = entry.fieldInt("due_date", due_date) catch return;
                        _ = entry.fieldInt("now", now) catch return;
                        entry.log();
                    }
                }
            }
        }
    }

    if (overdue_count > 0) {
        if (logger) |l| {
            const entry = l.info("Found overdue todos") catch return;
            _ = entry.fieldInt("count", overdue_count) catch return;
            entry.log();
        }
    }
}

fn generateStatistics() void {
    const orm = getORM() catch return;
    _ = getStats(orm) catch {};
}

fn validateStoreHealth() void {
    const logger = getLogger();
    const orm = getORM() catch {
        if (logger) |l| {
            const entry = l.logError("Failed to get ORM for health validation") catch return;
            entry.log();
        }
        return;
    };
    const stats = getStats(orm) catch {
        if (logger) |l| {
            const entry = l.logError("Failed to get stats for health validation") catch return;
            entry.log();
        }
        return;
    };

    // Database doesn't have capacity limits, but we can warn if there are many todos
    if (stats.total > 10000) {
        if (logger) |l| {
            const entry = l.warn("Todo count very high") catch return;
            _ = entry.fieldInt("count", stats.total) catch return;
            _ = entry.fieldInt("threshold", 10000) catch return;
            entry.log();
        }
    } else if (stats.total > 5000) {
        if (logger) |l| {
            const entry = l.warn("Todo count getting high") catch return;
            _ = entry.fieldInt("count", stats.total) catch return;
            _ = entry.fieldInt("threshold", 5000) catch return;
            entry.log();
        }
    }
}

// ============================================================================
// HEALTH CHECKS
// ============================================================================

fn checkTodoStoreHealth() E12.HealthStatus {
    const orm = getORM() catch return .unhealthy;
    const stats = getStats(orm) catch return .unhealthy;

    // Database doesn't have capacity limits, but we can check if there are too many todos
    if (stats.total > 10000) {
        return .degraded;
    }

    return .healthy;
}

fn checkSystemPerformance() E12.HealthStatus {
    return .healthy;
}

// ============================================================================
// APP SETUP
// ============================================================================

pub fn createApp() !E12.Engine12 {
    // Initialize database
    try initDatabase();

    var app = try E12.Engine12.initProduction();

    // Store logger globally for background tasks
    logger_mutex.lock();
    global_logger = &app.logger;
    logger_mutex.unlock();

    // Initialize cache with 60 second default TTL
    var response_cache = ResponseCache.init(allocator, 60000);
    app.setCache(&response_cache);
    
    // Store cache globally for potential background task usage
    cache_mutex.lock();
    global_cache = &response_cache;
    cache_mutex.unlock();

    // Middleware
    // Order matters: body size limit -> CSRF -> request tracking -> logging
    try app.usePreRequest(&bodySizeLimitMiddleware);
    try app.usePreRequest(&csrfMiddleware);
    try app.usePreRequest(&requestTrackingMiddleware);
    try app.usePreRequest(&loggingMiddleware);
    try app.useResponse(&corsMiddleware);

    // Custom error handler
    app.useErrorHandler(customErrorHandler);

    // Rate limiting for API endpoints
    var api_rate_limiter = rate_limit.RateLimiter.init(allocator, rate_limit.RateLimitConfig{
        .max_requests = 100,
        .window_ms = 60000, // 1 minute
    });

    try api_rate_limiter.setRouteConfig("/api/todos", rate_limit.RateLimitConfig{
        .max_requests = 50,
        .window_ms = 60000,
    });

    app.setRateLimiter(&api_rate_limiter);

    // Root route - serve templated index page (register BEFORE static files)
    try app.get("/", handleIndex);

    // Metrics endpoint
    try app.get("/metrics", handleMetrics);

    // Static file serving - register AFTER root route so it doesn't override it
    // Serve static files except for index.html which we'll handle with template
    try app.serveStatic("/css", "todo/frontend/css");
    try app.serveStatic("/js", "todo/frontend/js");

    // API routes
    // Note: Route groups require comptime evaluation, so we register routes directly
    // Route groups are demonstrated in the codebase but require comptime usage
    try app.get("/api/todos", handleGetTodos);
    try app.get("/api/todos/search", handleSearchTodos);
    try app.get("/api/todos/stats", handleGetStats);
    try app.get("/api/todos/:id", handleGetTodo);
    try app.post("/api/todos", handleCreateTodo);
    try app.put("/api/todos/:id", handleUpdateTodo);
    try app.delete("/api/todos/:id", handleDeleteTodo);

    // Background tasks
    try app.schedulePeriodicTask("cleanup_old_todos", &cleanupOldCompletedTodos, 3600000);
    try app.schedulePeriodicTask("check_overdue_todos", &checkOverdueTodos, 3600000); // Every hour
    try app.schedulePeriodicTask("generate_stats", &generateStatistics, 300000);
    try app.schedulePeriodicTask("validate_store_health", &validateStoreHealth, 600000);

    // Health checks
    try app.registerHealthCheck(&checkTodoStoreHealth);
    try app.registerHealthCheck(&checkSystemPerformance);

    return app;
}

pub fn run() !void {
    var app = try createApp();
    defer app.deinit();

    try app.start();
    app.printStatus();

    if (getLogger()) |logger| {
        const entry = logger.info("Server started - Press Ctrl+C to stop") catch return;
        entry.log();
    }

    while (true) {
        std.Thread.sleep(1000 * std.time.ns_per_ms);
    }
}
