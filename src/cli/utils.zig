const std = @import("std");
const build_options = @import("build_options");

/// Engine12 version - extracted from build.zig.zon via build options
/// Falls back to "unknown" if version cannot be determined (should never happen in normal builds)
pub const ENGINE12_VERSION = if (@hasDecl(build_options, "version"))
    build_options.version
else
    "unknown";

/// Process a template string by replacing placeholders
/// Placeholders: {PROJECT_NAME}, {ENGINE12_HASH}, {ENGINE12_VERSION}
pub fn processTemplate(
    allocator: std.mem.Allocator,
    template_content: []const u8,
    project_name: []const u8,
    engine12_hash: []const u8,
) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < template_content.len) {
        if (i < template_content.len - 1 and template_content[i] == '{') {
            // Check for placeholder
            const placeholder_start = i;
            var placeholder_end = i + 1;
            while (placeholder_end < template_content.len and template_content[placeholder_end] != '}') {
                placeholder_end += 1;
            }

            if (placeholder_end < template_content.len) {
                const placeholder = template_content[placeholder_start + 1 .. placeholder_end];
                const replacement: ?[]const u8 = if (std.mem.eql(u8, placeholder, "PROJECT_NAME"))
                    project_name
                else if (std.mem.eql(u8, placeholder, "PROJECT_NAME_LITERAL"))
                    project_name // Used as enum literal (e.g., .my_project_name)
                else if (std.mem.eql(u8, placeholder, "ENGINE12_HASH"))
                    engine12_hash
                else if (std.mem.eql(u8, placeholder, "ENGINE12_VERSION"))
                    ENGINE12_VERSION
                else
                    null;

                if (replacement) |repl| {
                    try result.appendSlice(allocator, repl);
                    i = placeholder_end + 1;
                    continue;
                }
            }
        }

        try result.append(allocator, template_content[i]);
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

/// Execute zig fetch and parse the hash from the output
/// Returns the hash string in format: Engine12-<version>-<hash>
/// NOTE: This function is minimal to work around allocator issues
pub fn fetchEngine12Hash(
    allocator: std.mem.Allocator,
    project_path: []const u8,
) ![]const u8 {
    // Create build.zig first (zig fetch will create/update build.zig.zon)
    {
        var cwd = try std.fs.cwd().openDir(project_path, .{});
        defer cwd.close();

        // Create build.zig if it doesn't exist
        _ = cwd.access("build.zig", .{}) catch {
            const minimal_build_zig =
                \\const std = @import("std");
                \\pub fn build(b: *std.Build) void {
                \\    const target = b.standardTargetOptions(.{});
                \\    const optimize = b.standardOptimizeOption(.{});
                \\    _ = b.dependency("engine12", .{
                \\        .target = target,
                \\        .optimize = optimize,
                \\    });
                \\}
            ;
            try cwd.writeFile(.{ .sub_path = "build.zig", .data = minimal_build_zig });
        };
    }

    // Execute zig fetch - capture stderr to see what went wrong
    const zig_fetch_args = [_][]const u8{ "zig", "fetch", "--save", "git+https://github.com/ooyeku/Engine12.git" };

    var process = std.process.Child.init(&zig_fetch_args, std.heap.page_allocator);
    defer {
        _ = process.kill() catch {};
    }
    process.cwd = project_path;
    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Pipe;

    try process.spawn();

    // Read and print any error output
    if (process.stderr) |stderr| {
        var buf: [1024]u8 = undefined;
        const bytes_read = stderr.readAll(&buf) catch 0;
        if (bytes_read > 0) {
            std.debug.print("zig fetch stderr: {s}\n", .{buf[0..bytes_read]});
        }
    }

    if (process.stdout) |stdout| {
        var buf: [1024]u8 = undefined;
        const bytes_read = stdout.readAll(&buf) catch 0;
        if (bytes_read > 0) {
            std.debug.print("zig fetch stdout: {s}\n", .{buf[0..bytes_read]});
        }
    }

    const term = try process.wait();

    if (term.Exited != 0) {
        std.debug.print("\nError: 'zig fetch' failed with exit code {}\n", .{term.Exited});
        std.debug.print("This usually means:\n", .{});
        std.debug.print("  - Network connectivity issues\n", .{});
        std.debug.print("  - GitHub is unreachable\n", .{});
        std.debug.print("  - Zig is not installed or not in PATH\n\n", .{});
        std.debug.print("Please ensure:\n", .{});
        std.debug.print("  1. You have internet connectivity\n", .{});
        std.debug.print("  2. Zig is installed and available in your PATH\n", .{});
        std.debug.print("  3. GitHub (github.com) is accessible\n\n", .{});
        return error.FetchFailed;
    }

    // Read and parse build.zig.zon - use page allocator for file content
    var cwd = try std.fs.cwd().openDir(project_path, .{});
    defer cwd.close();

    const build_zon_content = try cwd.readFileAlloc(std.heap.page_allocator, "build.zig.zon", 1024 * 1024);
    // Note: page_allocator doesn't support free(), so we don't defer it

    // Find and extract the hash value with robust error handling
    const engine12_prefix = ".engine12 =";
    const engine12_start = std.mem.indexOf(u8, build_zon_content, engine12_prefix) orelse {
        std.debug.print("Error: Could not find '.engine12 =' dependency in build.zig.zon\n", .{});
        std.debug.print("The build.zig.zon file may be malformed or missing the engine12 dependency.\n", .{});
        return error.HashNotFound;
    };

    const hash_prefix = ".hash = \"";
    const hash_start = std.mem.indexOfPos(u8, build_zon_content, engine12_start, hash_prefix) orelse {
        std.debug.print("Error: Could not find '.hash = \"' field in engine12 dependency\n", .{});
        std.debug.print("The engine12 dependency in build.zig.zon may be missing the hash field.\n", .{});
        return error.HashNotFound;
    };

    const hash_value_start = hash_start + hash_prefix.len;
    if (hash_value_start >= build_zon_content.len) {
        std.debug.print("Error: Hash value appears to be empty or malformed\n", .{});
        return error.HashNotFound;
    }

    const hash_end = std.mem.indexOfScalar(u8, build_zon_content[hash_value_start..], '"') orelse {
        std.debug.print("Error: Could not find closing quote for hash value\n", .{});
        std.debug.print("The hash value in build.zig.zon may be malformed.\n", .{});
        return error.HashNotFound;
    };

    if (hash_end == 0) {
        std.debug.print("Error: Hash value is empty\n", .{});
        return error.HashNotFound;
    }

    const hash = build_zon_content[hash_value_start..][0..hash_end];
    if (hash.len == 0) {
        std.debug.print("Error: Extracted hash is empty\n", .{});
        return error.HashNotFound;
    }

    return try allocator.dupe(u8, hash);
}

/// Write a file, creating parent directories if needed
/// Returns error if file cannot be written
pub fn writeFile(
    _: std.mem.Allocator,
    base_path: []const u8,
    file_path: []const u8,
    content: []const u8,
) !void {
    var base_dir = std.fs.cwd().openDir(base_path, .{}) catch |err| {
        std.debug.print("Error: Cannot open base directory '{s}': {}\n", .{ base_path, err });
        return err;
    };
    defer base_dir.close();

    // Split file path into directory and filename
    const last_slash = std.mem.lastIndexOfScalar(u8, file_path, '/');
    if (last_slash) |slash_idx| {
        const dir_path = file_path[0..slash_idx];
        const filename = file_path[slash_idx + 1 ..];

        if (filename.len == 0) {
            std.debug.print("Error: Invalid file path '{s}' (empty filename)\n", .{file_path});
            return error.InvalidPath;
        }

        // Create directory structure
        var dir = base_dir;
        var path_iter = std.mem.splitScalar(u8, dir_path, '/');
        while (path_iter.next()) |segment| {
            if (segment.len == 0) continue;
            dir.makeDir(segment) catch |err| {
                if (err != error.PathAlreadyExists) {
                    std.debug.print("Error: Cannot create directory '{s}': {}\n", .{ segment, err });
                    return err;
                }
            };
            dir = dir.openDir(segment, .{}) catch |err| {
                std.debug.print("Error: Cannot open directory '{s}': {}\n", .{ segment, err });
                return err;
            };
        }

        dir.writeFile(.{ .sub_path = filename, .data = content }) catch |err| {
            std.debug.print("Error: Cannot write file '{s}': {}\n", .{ file_path, err });
            dir.close();
            return err;
        };
        dir.close();
    } else {
        // No directory, just write file
        if (file_path.len == 0) {
            std.debug.print("Error: Invalid file path (empty)\n", .{});
            return error.InvalidPath;
        }
        base_dir.writeFile(.{ .sub_path = file_path, .data = content }) catch |err| {
            std.debug.print("Error: Cannot write file '{s}': {}\n", .{ file_path, err });
            return err;
        };
    }
}

/// Validate project name (alphanumeric, hyphens, underscores)
pub fn validateProjectName(name: []const u8) bool {
    if (name.len == 0) return false;

    for (name) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') {
            return false;
        }
    }

    return true;
}
