const std = @import("std");

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
                    "0.2.1"
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
                \\    _ = b.dependency("Engine12", .{
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
        std.debug.print("Error: zig fetch failed with exit code {}\n", .{term.Exited});
        std.debug.print("Trying alternative approach...\n", .{});

        // Fallback: try without --save flag to at least get diagnostic info
        var process2 = std.process.Child.init(&[_][]const u8{ "zig", "fetch", "git+https://github.com/ooyeku/Engine12.git" }, std.heap.page_allocator);
        process2.stdout_behavior = .Ignore;
        process2.stderr_behavior = .Ignore;
        _ = process2.spawn() catch {};
        _ = process2.wait() catch {};

        return error.FetchFailed;
    }

    // Read and parse build.zig.zon - use page allocator for file content
    var cwd = try std.fs.cwd().openDir(project_path, .{});
    defer cwd.close();

    const build_zon_content = try cwd.readFileAlloc(std.heap.page_allocator, "build.zig.zon", 1024 * 1024);
    // Note: page_allocator doesn't support free(), so we don't defer it

    // Find and extract the hash value
    const engine12_prefix = ".Engine12 =";
    const engine12_start = std.mem.indexOf(u8, build_zon_content, engine12_prefix) orelse {
        std.debug.print("Error: Could not find Engine12 dependency in build.zig.zon\n", .{});
        return error.HashNotFound;
    };

    const hash_prefix = ".hash = \"";
    const hash_start = std.mem.indexOfPos(u8, build_zon_content, engine12_start, hash_prefix) orelse {
        std.debug.print("Error: Could not find hash field in Engine12 dependency\n", .{});
        return error.HashNotFound;
    };

    const hash_value_start = hash_start + hash_prefix.len;
    const hash_end = std.mem.indexOfScalar(u8, build_zon_content[hash_value_start..], '"') orelse {
        std.debug.print("Error: Could not find end of hash value\n", .{});
        return error.HashNotFound;
    };

    const hash = build_zon_content[hash_value_start..][0..hash_end];
    return try allocator.dupe(u8, hash);
}

/// Write a file, creating parent directories if needed
pub fn writeFile(
    _: std.mem.Allocator,
    base_path: []const u8,
    file_path: []const u8,
    content: []const u8,
) !void {
    var base_dir = try std.fs.cwd().openDir(base_path, .{});
    defer base_dir.close();

    // Split file path into directory and filename
    const last_slash = std.mem.lastIndexOfScalar(u8, file_path, '/');
    if (last_slash) |slash_idx| {
        const dir_path = file_path[0..slash_idx];
        const filename = file_path[slash_idx + 1 ..];

        // Create directory structure
        var dir = base_dir;
        var path_iter = std.mem.splitScalar(u8, dir_path, '/');
        while (path_iter.next()) |segment| {
            if (segment.len == 0) continue;
            dir.makeDir(segment) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
            dir = try dir.openDir(segment, .{});
        }

        try dir.writeFile(.{ .sub_path = filename, .data = content });
        dir.close();
    } else {
        // No directory, just write file
        try base_dir.writeFile(.{ .sub_path = file_path, .data = content });
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
