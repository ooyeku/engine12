const std = @import("std");
const E12 = @import("engine12");
const Database = E12.orm.Database;
const ORM = E12.orm.ORM;
const MigrationRegistry = E12.orm.MigrationRegistryType;
const migration_discovery = E12.migration_discovery;
const Logger = E12.Logger;
const RuntimeTemplate = E12.RuntimeTemplate;
const ResponseCache = E12.cache.ResponseCache;

const allocator = std.heap.page_allocator;

// Global state
var global_db: ?Database = null;
var global_orm: ?ORM = null;
var global_index_template: ?*RuntimeTemplate = null;
var global_template_registry: E12.TemplateRegistry = undefined;
var template_registry_initialized: bool = false;
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

    // Use migration auto-discovery to automatically load migrations
    // Scans migrations/ directory for numbered files: {number}_{name}.zig
    var registry = migration_discovery.discoverMigrations(allocator, "todo/src/migrations") catch |err| {
        std.debug.print("[Todo] Warning: Migration discovery failed: {}\n", .{err});
        // Fall back to empty registry if discovery fails
        var fallback_registry = MigrationRegistry.init(allocator);
        defer fallback_registry.deinit();
        // Return early - no migrations to run
        return;
    };
    defer registry.deinit();

    // Run discovered migrations
    try global_orm.?.runMigrationsFromRegistry(&registry);
}

/// Set the global app instance (for logger access)
pub fn setGlobalApp(app: *E12.Engine12) void {
    global_app = app;
}

/// Set the global template instance (deprecated - use template registry instead)
pub fn setGlobalTemplate(template: *RuntimeTemplate) void {
    global_index_template = template;
}

/// Get the global template instance (deprecated - use template registry instead)
pub fn getGlobalTemplate() ?*RuntimeTemplate {
    return global_index_template;
}

/// Set the global template registry instance
pub fn setGlobalTemplateRegistry(registry: E12.TemplateRegistry) void {
    global_template_registry = registry;
    template_registry_initialized = true;
}

/// Get the global template registry instance
pub fn getGlobalTemplateRegistry() ?*E12.TemplateRegistry {
    if (template_registry_initialized) {
        return &global_template_registry;
    }
    return null;
}

/// Set the global cache instance
pub fn setGlobalCache(cache: *ResponseCache) void {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    global_cache = cache;
}
