const std = @import("std");
const templates = @import("../templates/template.zig");
const runtime_renderer = @import("runtime_renderer.zig");

/// Runtime template loader for hot reloading
/// Loads template content from filesystem and recompiles when changed
/// Note: Templates still use comptime compilation, but content is loaded at runtime
pub const RuntimeTemplate = struct {
    file_path: []const u8,
    last_modified: i64,
    template_content: []const u8,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    /// Initialize a runtime template from a file path
    pub fn init(allocator: std.mem.Allocator, file_path: []const u8) !RuntimeTemplate {
        const path_copy = try allocator.dupe(u8, file_path);

        // Load initial template content
        const content = try std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024);

        // Get initial modification time
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const stat = try file.stat();
        const last_modified = @as(i64, @intCast(stat.mtime));

        return RuntimeTemplate{
            .file_path = path_copy,
            .last_modified = last_modified,
            .template_content = content,
            .allocator = allocator,
        };
    }

    /// Check if template file has changed and reload if necessary
    pub fn reload(self: *RuntimeTemplate) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if file still exists
        const file = std.fs.cwd().openFile(self.file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // File was deleted, keep current content
                return;
            }
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        const current_modified = @as(i64, @intCast(stat.mtime));

        // If file was modified, reload content
        if (current_modified > self.last_modified) {
            self.last_modified = current_modified;

            // Read new content
            const new_content = try std.fs.cwd().readFileAlloc(self.allocator, self.file_path, 10 * 1024 * 1024);

            // Free old content
            self.allocator.free(self.template_content);

            // Update content
            self.template_content = new_content;
        }
    }

    /// Get the current template content
    /// This will check for changes and reload if necessary
    pub fn getContent(self: *RuntimeTemplate) ![]const u8 {
        try self.reload();
        return self.template_content;
    }

    /// Render template with context using runtime rendering
    /// Supports basic variable substitution: {{ .field }} and {{! .field }}
    /// Note: Full template features (if/for blocks) require comptime compilation
    /// For production, use comptime templates with @embedFile for full type safety
    pub fn render(
        self: *RuntimeTemplate,
        comptime Context: type,
        ctx: Context,
        render_allocator: std.mem.Allocator,
    ) ![]const u8 {
        // Reload template content if changed
        try self.reload();

        // Use runtime renderer for basic variable substitution
        return runtime_renderer.RuntimeRenderer.render(
            self.template_content,
            Context,
            ctx,
            render_allocator,
        );
    }

    /// Get template content as string (for use with runtime template engines)
    pub fn getContentString(self: *RuntimeTemplate) ![]const u8 {
        try self.reload();
        return self.template_content;
    }

    /// Clean up resources
    pub fn deinit(self: *RuntimeTemplate) void {
        self.allocator.free(self.file_path);
        self.allocator.free(self.template_content);
    }
};

test "RuntimeTemplate init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a test template file
    const test_file = "test_template.zt.html";
    std.fs.cwd().writeFile(test_file, "<h1>{{ .title }}</h1>") catch {
        // Skip test if file creation fails
        return;
    };
    defer std.fs.cwd().deleteFile(test_file) catch {};

    var rt = try RuntimeTemplate.init(allocator, test_file);
    defer rt.deinit();

    const content = try rt.getContentString();
    try std.testing.expect(std.mem.indexOf(u8, content, "<h1>") != null);
}

test "RuntimeTemplate reload on change" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a test template file
    const test_file = "test_reload.zt.html";
    std.fs.cwd().writeFile(test_file, "original") catch {
        return;
    };
    defer std.fs.cwd().deleteFile(test_file) catch {};

    var rt = try RuntimeTemplate.init(allocator, test_file);
    defer rt.deinit();

    var content = try rt.getContentString();
    try std.testing.expectEqualStrings(content, "original");

    // Modify the file
    std.fs.cwd().writeFile(test_file, "modified") catch {
        return;
    };

    // Reload and check
    try rt.reload();
    content = try rt.getContentString();
    try std.testing.expectEqualStrings(content, "modified");
}

