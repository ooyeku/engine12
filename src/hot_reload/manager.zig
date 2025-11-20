const std = @import("std");
const watcher = @import("watcher.zig");
const runtime_template = @import("runtime_template.zig");
const fileserver = @import("../fileserver.zig");

/// Hot reload manager for development mode
/// Coordinates file watching, template reloading, and static file cache invalidation
pub const HotReloadManager = struct {
    allocator: std.mem.Allocator,
    file_watcher: watcher.FileWatcher,
    template_cache: std.StringHashMap(*runtime_template.RuntimeTemplate),
    static_file_servers: std.ArrayListUnmanaged(*fileserver.FileServer),
    enabled: bool,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, enabled: bool) HotReloadManager {
        return HotReloadManager{
            .allocator = allocator,
            .file_watcher = watcher.FileWatcher.init(allocator),
            .template_cache = std.StringHashMap(*runtime_template.RuntimeTemplate).init(allocator),
            .static_file_servers = .{},
            .enabled = enabled,
        };
    }

    /// Watch a template file for changes
    /// Returns a RuntimeTemplate that automatically reloads when the file changes
    pub fn watchTemplate(self: *HotReloadManager, template_path: []const u8) !*runtime_template.RuntimeTemplate {
        if (!self.enabled) {
            return error.HotReloadNotEnabled;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if already watching
        if (self.template_cache.get(template_path)) |existing| {
            return existing;
        }

        // Create runtime template
        const rt = try runtime_template.RuntimeTemplate.init(self.allocator, template_path);
        const rt_ptr = try self.allocator.create(runtime_template.RuntimeTemplate);
        rt_ptr.* = rt;

        // Store in cache
        const path_copy = try self.allocator.dupe(u8, template_path);
        try self.template_cache.put(path_copy, rt_ptr);

        // Watch file for changes
        // The RuntimeTemplate will handle reloading on its own when accessed
        // We just watch the file to detect changes (the template reloads on next access)
        try self.file_watcher.watch(template_path, templateReloadCallback);

        return rt_ptr;
    }

    /// Callback for template file changes
    fn templateReloadCallback(path: []const u8) void {
        _ = path;
        // Template reloading is handled by RuntimeTemplate.reload() on access
        // This callback can be used for logging or other side effects
    }

    /// Watch static file server for changes
    /// In development mode, static files are served without cache headers
    pub fn watchStaticFiles(self: *HotReloadManager, file_server: *fileserver.FileServer) !void {
        if (!self.enabled) {
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.static_file_servers.append(self.allocator, file_server);

        // Disable cache for this file server in development
        // Note: FileServer doesn't have a setter for enable_cache, so we'll handle this
        // in the FileServer.serveFile() method by checking if hot reload is enabled
    }

    /// Start the hot reload manager
    pub fn start(self: *HotReloadManager) !void {
        if (!self.enabled) {
            return;
        }

        try self.file_watcher.start();
    }

    /// Stop the hot reload manager
    pub fn stop(self: *HotReloadManager) void {
        if (!self.enabled) {
            return;
        }

        self.file_watcher.stop();
    }

    /// Clean up resources
    pub fn deinit(self: *HotReloadManager) void {
        self.stop();

        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up templates
        var it = self.template_cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.template_cache.deinit();

        // Clean up static file servers list (servers themselves are managed elsewhere)
        self.static_file_servers.deinit(self.allocator);

        self.file_watcher.deinit();
    }
};

test "HotReloadManager init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = HotReloadManager.init(allocator, true);
    manager.deinit();
}

test "HotReloadManager disabled" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = HotReloadManager.init(allocator, false);
    defer manager.deinit();

    // Should return error when trying to watch template
    const result = manager.watchTemplate("test.zt.html");
    try std.testing.expectError(error.HotReloadNotEnabled, result);
}

