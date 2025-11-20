const std = @import("std");
const watcher = @import("watcher.zig");
const runtime_template = @import("runtime_template.zig");
const fileserver = @import("../fileserver.zig");
const websocket_room = @import("../websocket/room.zig");

/// Hot reload manager for development mode
/// Coordinates file watching, template reloading, and static file cache invalidation
pub const HotReloadManager = struct {
    allocator: std.mem.Allocator,
    file_watcher: watcher.FileWatcher,
    template_cache: std.StringHashMap(*runtime_template.RuntimeTemplate),
    static_file_servers: std.ArrayListUnmanaged(*fileserver.FileServer),
    reload_room: ?*websocket_room.WebSocketRoom = null,
    enabled: bool,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, enabled: bool) HotReloadManager {
        // Create WebSocket room for hot reload notifications
        const reload_room = if (enabled) allocator.create(websocket_room.WebSocketRoom) catch null else null;
        if (reload_room) |room| {
            room.* = websocket_room.WebSocketRoom.init(allocator, "hot_reload") catch {
                allocator.destroy(room);
                return HotReloadManager{
                    .allocator = allocator,
                    .file_watcher = watcher.FileWatcher.init(allocator),
                    .template_cache = std.StringHashMap(*runtime_template.RuntimeTemplate).init(allocator),
                    .static_file_servers = .{},
                    .reload_room = null,
                    .enabled = enabled,
                };
            };
        }

        return HotReloadManager{
            .allocator = allocator,
            .file_watcher = watcher.FileWatcher.init(allocator),
            .template_cache = std.StringHashMap(*runtime_template.RuntimeTemplate).init(allocator),
            .static_file_servers = .{},
            .reload_room = reload_room,
            .enabled = enabled,
        };
    }

    /// Get the WebSocket room for hot reload notifications
    pub fn getReloadRoom(self: *HotReloadManager) ?*websocket_room.WebSocketRoom {
        return self.reload_room;
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

        // Watch file for changes with callback that broadcasts reload notification
        // Pass self as context so callback can access manager
        try self.file_watcher.watch(template_path, templateReloadCallback, self);

        return rt_ptr;
    }

    /// Callback for template file changes
    /// This is called by the file watcher when a template file changes
    fn templateReloadCallback(path: []const u8, context: ?*anyopaque) void {
        if (context) |ctx| {
            const manager = @as(*HotReloadManager, @ptrCast(@alignCast(ctx)));
            manager.notifyReload(path);
        }
    }

    /// Notify all connected clients that a file has changed
    /// This is called from the file watcher thread, so we need to be thread-safe
    fn notifyReload(self: *HotReloadManager, file_path: []const u8) void {
        // Lock mutex to ensure thread-safe access to reload_room
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.reload_room) |room| {
            const json = std.fmt.allocPrint(self.allocator, "{{\"type\":\"reload\",\"file\":\"{s}\"}}", .{file_path}) catch return;
            defer self.allocator.free(json);

            room.broadcast(json) catch |err| {
                std.debug.print("[HotReload] Error broadcasting reload: {}\n", .{err});
            };
        }
    }

    /// Watch static file server for changes
    /// In development mode, static files are served without cache headers
    /// Also watches the directory for file changes and sends reload notifications
    pub fn watchStaticFiles(self: *HotReloadManager, file_server: *fileserver.FileServer) !void {
        if (!self.enabled) {
            return;
        }

        self.mutex.lock();
        try self.static_file_servers.append(self.allocator, file_server);
        const directory = file_server.directory;
        self.mutex.unlock();

        // Watch the static file directory for changes (without holding mutex)
        // When any file in the directory changes, send a reload notification
        try self.watchDirectory(directory, staticFileReloadCallback, self);
    }

    /// Watch a directory recursively for file changes
    /// When any file changes, the callback is called with the file path
    fn watchDirectory(self: *HotReloadManager, directory_path: []const u8, callback: *const fn ([]const u8, ?*anyopaque) void, context: ?*anyopaque) !void {
        var dir = std.fs.cwd().openDir(directory_path, .{ .iterate = true }) catch {
            // Directory doesn't exist or can't be opened, skip
            return;
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ directory_path, entry.name });
            defer self.allocator.free(full_path);

            if (entry.kind == .directory) {
                // Recursively watch subdirectories
                try self.watchDirectory(full_path, callback, context);
            } else {
                // Watch individual files
                self.file_watcher.watch(full_path, callback, context) catch |err| {
                    // Log but don't fail - some files might not be readable
                    std.debug.print("[HotReload] Warning: Failed to watch file {s}: {}\n", .{ full_path, err });
                };
            }
        }
    }

    /// Callback for static file changes
    /// This is called by the file watcher when a static file changes
    fn staticFileReloadCallback(path: []const u8, context: ?*anyopaque) void {
        if (context) |ctx| {
            const manager = @as(*HotReloadManager, @ptrCast(@alignCast(ctx)));
            manager.notifyReload(path);
        }
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

        // Clean up reload room
        if (self.reload_room) |room| {
            room.deinit();
            self.allocator.destroy(room);
            self.reload_room = null;
        }

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
