const std = @import("std");
const E12 = @import("engine12");
const Database = E12.orm.Database;
const ORM = E12.orm.ORM;
const MigrationRegistry = E12.orm.MigrationRegistryType;
const Logger = E12.Logger;
const RuntimeTemplate = E12.RuntimeTemplate;
const ResponseCache = E12.cache.ResponseCache;

const allocator = std.heap.page_allocator;

// Global state
var global_db: ?Database = null;
var global_orm: ?ORM = null;
var global_index_template: ?*RuntimeTemplate = null;
var db_mutex: std.Thread.Mutex = .{};
var global_app: ?*E12.Engine12 = null;
var global_cache: ?*ResponseCache = null;
var cache_mutex: std.Thread.Mutex = .{};

/// Get the logger from the global app instance
pub fn getLogger() ?*Logger {
    if (global_app) |app| {
        return app.getLogger();
    }
    return null;
}

/// Get the ORM instance
pub fn getORM() !*ORM {
    db_mutex.lock();
    defer db_mutex.unlock();

    if (global_orm) |*orm| {
        return orm;
    }

    return error.DatabaseNotInitialized;
}

/// Initialize the database and run migrations
pub fn initDatabase() !void {
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

    // Use MigrationRegistry to manage migrations
    var registry = MigrationRegistry.init(allocator);
    defer registry.deinit();

    // Add migrations to registry
    try registry.add(E12.orm.MigrationType.init(1, "create_todos",
        \\CREATE TABLE IF NOT EXISTS todos (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  title TEXT NOT NULL,
        \\  description TEXT NOT NULL,
        \\  completed INTEGER NOT NULL DEFAULT 0,
        \\  created_at INTEGER NOT NULL,
        \\  updated_at INTEGER NOT NULL
        \\)
    , "DROP TABLE IF EXISTS todos"));

    try registry.add(E12.orm.MigrationType.init(2, "add_priority", "ALTER TABLE todos ADD COLUMN priority TEXT NOT NULL DEFAULT 'medium'", "ALTER TABLE todos DROP COLUMN priority"));

    try registry.add(E12.orm.MigrationType.init(3, "add_due_date", "ALTER TABLE todos ADD COLUMN due_date INTEGER", "-- Cannot automatically reverse ALTER TABLE ADD COLUMN"));

    try registry.add(E12.orm.MigrationType.init(4, "add_tags", "ALTER TABLE todos ADD COLUMN tags TEXT NOT NULL DEFAULT ''", "ALTER TABLE todos DROP COLUMN tags"));

    try registry.add(E12.orm.MigrationType.init(5, "add_user_id",
        \\ALTER TABLE todos ADD COLUMN user_id INTEGER NOT NULL DEFAULT 1;
        \\CREATE INDEX IF NOT EXISTS idx_todo_user_id ON todos(user_id);
    , "-- Cannot automatically reverse ALTER TABLE ADD COLUMN"));

    // Run migrations using the registry
    try global_orm.?.runMigrationsFromRegistry(&registry);
}

/// Set the global app instance (for logger access)
pub fn setGlobalApp(app: *E12.Engine12) void {
    global_app = app;
}

/// Set the global template instance
pub fn setGlobalTemplate(template: *RuntimeTemplate) void {
    global_index_template = template;
}

/// Get the global template instance
pub fn getGlobalTemplate() ?*RuntimeTemplate {
    return global_index_template;
}

/// Set the global cache instance
pub fn setGlobalCache(cache: *ResponseCache) void {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    global_cache = cache;
}
