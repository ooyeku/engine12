const std = @import("std");

/// Generate engine12-docs.md in the current working directory
/// Reads docs/api-reference.md and writes it to engine12-docs.md
/// Tries multiple paths to find the docs file:
/// 1. Relative to current directory (if running from Engine12 root)
/// 2. Relative to executable location
pub fn generateDocs(allocator: std.mem.Allocator) !void {
    _ = allocator; // Not used, but kept for consistency with other commands

    // Try to read docs/api-reference.md from various locations
    const docs_content = readDocsFile() catch |err| {
        std.debug.print("Error: Failed to read docs/api-reference.md: {}\n", .{err});
        std.debug.print("Please ensure you're running from the Engine12 root directory,\n", .{});
        std.debug.print("or that docs/api-reference.md exists relative to the executable.\n", .{});
        return err;
    };
    defer std.heap.page_allocator.free(docs_content);

    const cwd = std.fs.cwd();

    // Write the docs to engine12-docs.md
    // This will overwrite existing file if it exists
    cwd.writeFile(.{ .sub_path = "engine12-docs.md", .data = docs_content }) catch |err| {
        std.debug.print("Error: Failed to write engine12-docs.md: {}\n", .{err});
        return err;
    };

    std.debug.print("Successfully generated engine12-docs.md\n", .{});
}

/// Read docs/api-reference.md from various possible locations
fn readDocsFile() ![]const u8 {
    // Try 1: Relative to current working directory
    if (readDocsFromPath("docs/api-reference.md")) |content| {
        return content;
    } else |_| {}

    // Try 2: Relative to executable location
    const exe_path = try std.fs.selfExePathAlloc(std.heap.page_allocator);
    defer std.heap.page_allocator.free(exe_path);

    // Get directory of executable
    const last_slash = std.mem.lastIndexOfScalar(u8, exe_path, '/') orelse {
        return error.DocsNotFound;
    };
    const exe_dir = exe_path[0..last_slash];

    // Try docs/api-reference.md relative to executable
    var path_buf: [1024]u8 = undefined;
    const relative_path = try std.fmt.bufPrint(&path_buf, "{s}/../docs/api-reference.md", .{exe_dir});

    if (readDocsFromPath(relative_path)) |content| {
        return content;
    } else |_| {}

    return error.DocsNotFound;
}

/// Try to read docs file from a specific path
fn readDocsFromPath(path: []const u8) ![]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    const max_size = 10 * 1024 * 1024; // 10MB max
    if (stat.size > max_size) {
        return error.FileTooLarge;
    }

    const content = try std.heap.page_allocator.alloc(u8, @as(usize, @intCast(stat.size)));
    const bytes_read = try file.readAll(content);
    if (bytes_read != content.len) {
        std.heap.page_allocator.free(content);
        return error.UnexpectedEOF;
    }

    return content;
}
