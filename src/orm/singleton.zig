const std = @import("std");
const Database = @import("database.zig").Database;
const ORM = @import("orm.zig").ORM;

/// Thread-safe database singleton pattern
/// Provides a global database/ORM instance that can be safely accessed from multiple threads
/// 
/// Example:
/// ```zig
/// // Initialize singleton once at startup
/// try DatabaseSingleton.init("myapp.db", allocator);
/// defer DatabaseSingleton.deinit();
/// 
/// // Access from anywhere in your application
/// const orm = try DatabaseSingleton.get();
/// const todos = try orm.findAll(Todo);
/// ```
pub const DatabaseSingleton = struct {
    var global_db: ?Database = null;
    var global_orm: ?ORM = null;
    var mutex: std.Thread.Mutex = .{};
    var initialized: bool = false;

    /// Initialize the database singleton
    /// Opens the database and creates the ORM instance
    /// Thread-safe: can be called multiple times safely (idempotent)
    /// 
    /// Example:
    /// ```zig
    /// try DatabaseSingleton.init("myapp.db", allocator);
    /// ```
    pub fn init(db_path: []const u8, allocator: std.mem.Allocator) !void {
        mutex.lock();
        defer mutex.unlock();

        if (initialized) {
            return; // Already initialized
        }

        global_db = try Database.open(db_path, allocator);
        global_orm = ORM.init(global_db.?, allocator);
        initialized = true;
    }

    /// Get the ORM instance
    /// Returns a pointer to the thread-safe ORM instance
    /// Thread-safe: can be called from multiple threads concurrently
    /// 
    /// Example:
    /// ```zig
    /// const orm = try DatabaseSingleton.get();
    /// const todo = try orm.find(Todo, 1);
    /// ```
    pub fn get() !*ORM {
        mutex.lock();
        defer mutex.unlock();

        if (!initialized) {
            return error.DatabaseNotInitialized;
        }

        if (global_orm) |*orm| {
            return orm;
        }

        return error.DatabaseNotInitialized;
    }

    /// Get the database instance directly
    /// Returns a pointer to the thread-safe Database instance
    /// Thread-safe: can be called from multiple threads concurrently
    /// 
    /// Example:
    /// ```zig
    /// const db = try DatabaseSingleton.getDatabase();
    /// try db.execute("SELECT * FROM users");
    /// ```
    pub fn getDatabase() !*Database {
        mutex.lock();
        defer mutex.unlock();

        if (!initialized) {
            return error.DatabaseNotInitialized;
        }

        if (global_db) |*db| {
            return db;
        }

        return error.DatabaseNotInitialized;
    }

    /// Check if the singleton has been initialized
    /// Thread-safe
    pub fn isInitialized() bool {
        mutex.lock();
        defer mutex.unlock();
        return initialized;
    }

    /// Deinitialize the singleton
    /// Closes the database connection and cleans up resources
    /// Thread-safe: should be called once at application shutdown
    /// 
    /// Example:
    /// ```zig
    /// defer DatabaseSingleton.deinit();
    /// ```
    pub fn deinit() void {
        mutex.lock();
        defer mutex.unlock();

        if (global_db) |*db| {
            db.close();
        }

        global_db = null;
        global_orm = null;
        initialized = false;
    }
};

// Tests
test "DatabaseSingleton init and get" {
    const allocator = std.testing.allocator;
    const test_db_path = ":memory:";
    
    try DatabaseSingleton.init(test_db_path, allocator);
    defer DatabaseSingleton.deinit();
    
    try std.testing.expect(DatabaseSingleton.isInitialized());
    
    const orm = try DatabaseSingleton.get();
    _ = orm; // Use ORM
    
    const db = try DatabaseSingleton.getDatabase();
    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)");
}

test "DatabaseSingleton idempotent init" {
    const allocator = std.testing.allocator;
    const test_db_path = ":memory:";
    
    try DatabaseSingleton.init(test_db_path, allocator);
    defer DatabaseSingleton.deinit();
    
    // Second init should not error
    try DatabaseSingleton.init(test_db_path, allocator);
}

test "DatabaseSingleton error when not initialized" {
    // Ensure not initialized
    if (DatabaseSingleton.isInitialized()) {
        DatabaseSingleton.deinit();
    }
    
    const result = DatabaseSingleton.get();
    try std.testing.expectError(error.DatabaseNotInitialized, result);
}

