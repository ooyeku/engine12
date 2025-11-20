const std = @import("std");

/// File watcher for hot reloading
/// Uses polling-based approach for cross-platform compatibility
pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    watch_entries: std.ArrayListUnmanaged(WatchEntry),
    is_running: std.atomic.Value(bool),
    watch_thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},

    const WatchEntry = struct {
        path: []const u8,
        last_modified: i64,
        callback: *const fn ([]const u8, ?*anyopaque) void,
        context: ?*anyopaque = null,
    };

    const POLL_INTERVAL_NS: u64 = 500_000_000; // 500ms

    pub fn init(allocator: std.mem.Allocator) FileWatcher {
        return FileWatcher{
            .allocator = allocator,
            .watch_entries = .{},
            .is_running = std.atomic.Value(bool).init(false),
            .watch_thread = null,
        };
    }

    /// Watch a file path for changes
    /// The callback will be called when the file is modified with the context
    pub fn watch(self: *FileWatcher, path: []const u8, callback: *const fn ([]const u8, ?*anyopaque) void, context: ?*anyopaque) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        // Get initial modification time
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            self.allocator.free(path_copy);
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        const last_modified = @as(i64, @intCast(stat.mtime));

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.watch_entries.append(self.allocator, WatchEntry{
            .path = path_copy,
            .last_modified = last_modified,
            .callback = callback,
            .context = context,
        });
    }

    /// Start the file watcher in a background thread
    pub fn start(self: *FileWatcher) !void {
        if (self.is_running.load(.monotonic)) {
            return; // Already running
        }

        self.is_running.store(true, .monotonic);
        self.watch_thread = try std.Thread.spawn(.{}, watchLoop, .{self});
    }

    /// Stop the file watcher
    pub fn stop(self: *FileWatcher) void {
        if (!self.is_running.load(.monotonic)) {
            return;
        }

        self.is_running.store(false, .monotonic);
        if (self.watch_thread) |thread| {
            thread.join();
            self.watch_thread = null;
        }
    }

    /// Background thread that polls for file changes
    fn watchLoop(self: *FileWatcher) void {
        while (self.is_running.load(.monotonic)) {
            std.Thread.sleep(POLL_INTERVAL_NS);

            self.mutex.lock();
            defer self.mutex.unlock();

            var i: usize = 0;
            while (i < self.watch_entries.items.len) {
                const entry = &self.watch_entries.items[i];

                // Check if file still exists and get modification time
                const file = std.fs.cwd().openFile(entry.path, .{}) catch {
                    // File doesn't exist or can't be opened, skip
                    i += 1;
                    continue;
                };
                defer file.close();

                const stat = file.stat() catch {
                    i += 1;
                    continue;
                };

                const current_modified = @as(i64, @intCast(stat.mtime));

                // If file was modified, call callback
                if (current_modified > entry.last_modified) {
                    entry.last_modified = current_modified;
                    // Release mutex before calling callback to avoid deadlock
                    self.mutex.unlock();
                    entry.callback(entry.path, entry.context);
                    self.mutex.lock();
                }

                i += 1;
            }
        }
    }

    /// Clean up resources
    pub fn deinit(self: *FileWatcher) void {
        self.stop();

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.watch_entries.items) |entry| {
            self.allocator.free(entry.path);
        }
        self.watch_entries.deinit(self.allocator);
    }
};

test "FileWatcher init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var watcher = FileWatcher.init(allocator);
    watcher.deinit();
}

test "FileWatcher watch and start" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var watcher = FileWatcher.init(allocator);
    defer watcher.deinit();

    const TestCallback = struct {
        fn callback(path: []const u8, context: ?*anyopaque) void {
            _ = path;
            _ = context;
            // Callback called - template will reload on next access
        }
    };

    // Create a test file
    const test_file = "test_watch.txt";
    std.fs.cwd().writeFile(test_file, "test") catch {
        // Skip test if file creation fails
        return;
    };
    defer std.fs.cwd().deleteFile(test_file) catch {};

    try watcher.watch(test_file, TestCallback.callback, null);
    try watcher.start();
    defer watcher.stop();

    // Wait a bit for initial check
    std.Thread.sleep(600_000_000); // 600ms

    // Modify the file
    std.fs.cwd().writeFile(test_file, "modified") catch {
        return;
    };

    // Wait for watcher to detect change
    std.Thread.sleep(600_000_000); // 600ms

    // Note: This test mainly ensures the watcher doesn't crash
    // Actual callback execution is tested indirectly through template reloading
}
