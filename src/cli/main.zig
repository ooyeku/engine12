const std = @import("std");
const new_command = @import("commands/new.zig");
const cli_utils = @import("utils.zig");

const allocator = std.heap.page_allocator;

pub fn main() !void {
    // Use page allocator to avoid allocator corruption issues
    const alloc = std.heap.page_allocator;

    const args = try std.process.argsAlloc(alloc);
    // Note: argsAlloc uses page_allocator internally, so no need to free

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "new")) {
        if (args.len < 3) {
            std.debug.print("Error: 'new' command requires a project name\n\n", .{});
            printUsage();
            std.process.exit(1);
        }

        const project_name = args[2];

        // Validate project name before proceeding
        if (!cli_utils.validateProjectName(project_name)) {
            std.debug.print("Error: Invalid project name '{s}'\n", .{project_name});
            std.debug.print("Project names must contain only alphanumeric characters, hyphens, and underscores\n\n", .{});
            std.process.exit(1);
        }

        const project_path = std.fs.cwd().realpathAlloc(alloc, ".") catch |err| {
            std.debug.print("Error: Failed to get current directory: {}\n", .{err});
            std.process.exit(1);
        };

        new_command.scaffoldProject(alloc, project_name, project_path) catch |err| {
            std.debug.print("\nError: Failed to create project: {}\n", .{err});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "-v") or std.mem.eql(u8, command, "--version")) {
        std.debug.print("Engine12 CLI v{s}\n", .{cli_utils.ENGINE12_VERSION});
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        printUsage();
    } else {
        std.debug.print("Error: Unknown command '{s}'\n\n", .{command});
        printUsage();
        std.process.exit(1);
    }
}

fn printUsage() void {
    std.debug.print(
        \\Engine12 CLI v{s}
        \\
        \\Usage:
        \\  e12 new <project-name>    Create a new Engine12 project
        \\  e12 version               Show version information
        \\  e12 help                  Show this help message
        \\
        \\Examples:
        \\  e12 new my-app            Create a new project named 'my-app'
        \\  e12 new api-server        Create a new project named 'api-server'
        \\
    , .{cli_utils.ENGINE12_VERSION});
}
