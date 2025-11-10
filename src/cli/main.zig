const std = @import("std");
const new_command = @import("commands/new.zig");

const allocator = std.heap.page_allocator;

pub fn main() !void {
    // Use page allocator to avoid allocator corruption issues
    const alloc = std.heap.page_allocator;

    const args = try std.process.argsAlloc(alloc);

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "new")) {
        if (args.len < 3) {
            std.debug.print("Error: 'new' command requires a project name\n", .{});
            printUsage();
            std.process.exit(1);
        }

        const project_name = args[2];
        const project_path = try std.fs.cwd().realpathAlloc(alloc, ".");

        try new_command.scaffoldProject(alloc, project_name, project_path);
    } else {
        std.debug.print("Error: Unknown command '{s}'\n", .{command});
        printUsage();
        std.process.exit(1);
    }
}

fn printUsage() void {
    std.debug.print(
        \\Engine12 CLI
        \\
        \\Usage:
        \\  e12 new <project-name>    Create a new Engine12 project
        \\
    , .{});
}
