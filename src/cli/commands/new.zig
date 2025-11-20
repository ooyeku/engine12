const std = @import("std");
const cli_utils = @import("../utils.zig");

/// Template for build.zig.zon
const BUILD_ZON_TEMPLATE =
    \\.{
    \\    .name = .{PROJECT_NAME_LITERAL},
    \\    .version = "0.1.0",
    \\    .minimum_zig_version = "0.15.1",
    \\    .dependencies = .{
    \\        .engine12 = .{
    \\            .url = "git+https://github.com/ooyeku/Engine12.git",
    \\            .hash = "{ENGINE12_HASH}",
    \\        },
    \\    },
    \\    .paths = .{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    },
    \\}
;

/// Template for build.zig
const BUILD_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    const engine12_dep = b.dependency("engine12", .{
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\
    \\    const exe = b.addExecutable(.{
    \\        .name = "{PROJECT_NAME}",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/main.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\        }),
    \\    });
    \\
    \\    exe.root_module.addImport("engine12", engine12_dep.module("engine12"));
    \\    exe.linkLibC(); // Required for ORM
    \\
    \\    b.installArtifact(exe);
    \\
    \\    const run_step = b.step("run", "Run the application");
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_step.dependOn(&run_cmd.step);
    \\    if (b.args) |args| {
    \\        run_cmd.addArgs(args);
    \\    }
    \\}
;

/// Template for main.zig
const MAIN_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\const E12 = @import("engine12");
    \\const app = @import("app.zig");
    \\
    \\pub fn main() !void {
    \\    try app.run();
    \\}
;

/// Template for app.zig
const APP_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\const E12 = @import("engine12");
    \\const Request = E12.Request;
    \\const Response = E12.Response;
    \\
    \\fn handleRoot(req: *Request) Response {
    \\    _ = req;
    \\    return Response.json("{{\"message\":\"Hello from {PROJECT_NAME}!\"}}");
    \\}
    \\
    \\pub fn run() !void {
    \\    var app = try E12.Engine12.initDevelopment();
    \\    defer app.deinit();
    \\
    \\    try app.get("/", handleRoot);
    \\
    \\    std.debug.print("Server starting on http://127.0.0.1:8080\n", .{});
    \\    std.debug.print("Press Ctrl+C to stop\n", .{});
    \\    try app.start();
    \\    
    \\    // Keep the server running indefinitely until interrupted (Ctrl+C)
    \\    while (true) { }
    \\}
;

/// Template for README.md
const README_TEMPLATE =
    \\# {PROJECT_NAME}
    \\
    \\A minimal engine12 application.
    \\
    \\## Getting Started
    \\
    \\```bash
    \\zig build run
    \\```
    \\
    \\The server will start on http://127.0.0.1:8080
    \\
;

/// Template for .gitignore
const GITIGNORE_TEMPLATE =
    \\zig-out/
    \\.zig-cache/
    \\zig-cache/
    \\zig-lock.json
    \\*.db
    \\.env
    \\.DS_Store
;

/// Scaffold a new engine12 project
pub fn scaffoldProject(
    allocator: std.mem.Allocator,
    project_name: []const u8,
    base_path: []const u8,
) !void {
    _ = base_path; // We use cwd() directly instead
    // Validate project name
    if (!cli_utils.validateProjectName(project_name)) {
        std.debug.print("Error: Project name must contain only alphanumeric characters, hyphens, and underscores\n", .{});
        return error.InvalidProjectName;
    }

    // Create project directory (variable removed as it's no longer used directly)

    std.fs.cwd().makeDir(project_name) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("Error: Directory '{s}' already exists\n", .{project_name});
            return error.DirectoryExists;
        }
        return err;
    };

    // Create src directory
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_name});
    std.fs.cwd().makeDir(src_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Change to project directory for zig fetch
    const original_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");

    std.posix.chdir(project_name) catch |err| {
        std.debug.print("Error: Failed to change to project directory: {}\n", .{err});
        return err;
    };

    // Fetch engine12 hash (we're already in the project directory)
    std.debug.print("Fetching engine12 dependency...\n", .{});
    const engine12_hash: []const u8 = cli_utils.fetchEngine12Hash(allocator, ".") catch |err| {
        // Cleanup on failure - change directory back and delete project
        std.posix.chdir(original_cwd) catch {};
        // Try to clean up the project directory using a fixed buffer
        var cleanup_path_buf: [512]u8 = undefined;
        const abs_project_path = std.fmt.bufPrint(&cleanup_path_buf, "{s}/{s}", .{ original_cwd, project_name }) catch |fmt_err| {
            std.debug.print("Error: Failed to fetch engine12 dependency: {}\n", .{err});
            std.debug.print("Warning: Could not construct cleanup path: {}\n", .{fmt_err});
            // Exit immediately to avoid allocator cleanup panics
            std.process.exit(1);
        };
        std.fs.cwd().deleteTree(abs_project_path) catch {};
        std.debug.print("Error: Failed to fetch Engine12 dependency: {}\n", .{err});
        // Exit immediately to avoid allocator cleanup panics
        std.process.exit(1);
    };

    // Process templates and write files (we're already in the project directory)
    // Note: build.zig.zon is generated by zig fetch, not templated
    const files = [_]struct { []const u8, []const u8 }{
        .{ "build.zig", BUILD_ZIG_TEMPLATE },
        .{ "src/main.zig", MAIN_ZIG_TEMPLATE },
        .{ "src/app.zig", APP_ZIG_TEMPLATE },
        .{ "README.md", README_TEMPLATE },
        .{ ".gitignore", GITIGNORE_TEMPLATE },
    };

    for (files) |file_info| {
        const processed = try cli_utils.processTemplate(allocator, file_info[1], project_name, engine12_hash);
        // Note: processed is allocated with page_allocator, so we don't free it
        try cli_utils.writeFile(allocator, ".", file_info[0], processed);
    }

    // Change back to original directory (defer will handle this, but explicit is clearer)
    std.posix.chdir(original_cwd) catch {};

    std.debug.print("Created project '{s}' successfully!\n", .{project_name});
    std.debug.print("Next steps:\n", .{});
    std.debug.print("  cd {s}\n", .{project_name});
    std.debug.print("  zig build run\n", .{});

    // Exit immediately to avoid allocator cleanup issues
    std.process.exit(0);
}
