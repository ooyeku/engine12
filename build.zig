const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("Engine12", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const ziggurat = b.dependency("ziggurat", .{
        .target = target,
        .optimize = optimize,
    });

    const vigil = b.dependency("vigil", .{
        .target = target,
        .optimize = optimize,
    });

    // Create ziggurat module from its root source
    const ziggurat_mod = b.createModule(.{
        .root_source_file = ziggurat.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add vigil and ziggurat to the Engine12 module's imports
    mod.addImport("vigil", vigil.module("vigil"));
    mod.addImport("ziggurat", ziggurat_mod);

    // Compile SQLite C sources as a static library to avoid duplicate symbols
    const sqlite_lib = b.addLibrary(.{
        .name = "sqlite_orm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/empty.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    sqlite_lib.addCSourceFiles(.{
        .files = &.{
            "src/sqlite/sqlite3.c",
            "src/c_api/e12_orm_c.c",
        },
        .flags = &.{
            "-std=c99",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_ENABLE_FTS4=1",
            "-DSQLITE_ENABLE_FTS5=1",
            "-DSQLITE_ENABLE_JSON1=1",
            "-DSQLITE_ENABLE_RTREE=1",
            "-DSQLITE_ENABLE_EXPLAIN_COMMENTS=1",
            "-DSQLITE_ENABLE_UNKNOWN_SQL_FUNCTION=1",
            "-DSQLITE_ENABLE_STAT4=1",
            "-DSQLITE_ENABLE_COLUMN_METADATA=1",
            "-DSQLITE_ENABLE_UNLOCK_NOTIFY=1",
            "-DSQLITE_ENABLE_DBSTAT_VTAB=1",
            "-DSQLITE_ENABLE_BATCH_ATOMIC_WRITE=1",
        },
    });
    sqlite_lib.addIncludePath(b.path("src"));
    sqlite_lib.addIncludePath(b.path("src/sqlite"));
    sqlite_lib.addIncludePath(b.path("src/c_api"));
    sqlite_lib.linkLibC();

    // Build shared library for C API
    const lib = b.addLibrary(.{
        .name = "engine12",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api/engine12.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vigil", .module = vigil.module("vigil") },
                .{ .name = "ziggurat", .module = ziggurat_mod },
                .{ .name = "Engine12", .module = mod },
            },
        }),
        .linkage = .dynamic,
    });

    // Link C standard library
    lib.linkLibC();

    // Link SQLite static library
    lib.linkLibrary(sqlite_lib);

    // Install shared library
    // Note: Symbols marked with 'export' in Zig are automatically exported for shared libraries
    b.installArtifact(lib);

    // Install header file
    const header_install = b.addInstallFile(
        b.path("src/c_api/engine12.h"),
        "include/engine12.h",
    );
    b.getInstallStep().dependOn(&header_install.step);

    // Install ORM header file
    const orm_header_install = b.addInstallFile(
        b.path("src/c_api/e12_orm.h"),
        "include/e12_orm.h",
    );
    b.getInstallStep().dependOn(&orm_header_install.step);

    const exe = b.addExecutable(.{
        .name = "Engine12",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Engine12", .module = mod },
                .{ .name = "vigil", .module = vigil.module("vigil") },
                .{ .name = "ziggurat", .module = ziggurat_mod },
            },
        }),
    });

    // Link SQLite static library to main executable
    exe.linkLibrary(sqlite_lib);
    exe.linkLibC();

    b.installArtifact(exe);

    const run_step = b.step("run", "Show available build commands");
    const run_info_cmd = b.addSystemCommand(&.{ "sh", "-c" });
    run_info_cmd.addArgs(&.{
        "printf '\\nEngine12 Build Commands\\n=========================================================\\n  zig build             Build Engine12 library and executables\\n  zig build test         Run all tests\\n  zig build todo-run     Run the TODO application\\n  zig build todo-test    Run TODO application tests\\n=========================================================\\n\\n'",
    });
    run_step.dependOn(&run_info_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // Add include paths for C headers
    mod_tests.addIncludePath(b.path("src"));
    mod_tests.addIncludePath(b.path("src/sqlite"));
    mod_tests.addIncludePath(b.path("src/c_api"));

    // Link SQLite static library to mod tests
    mod_tests.linkLibrary(sqlite_lib);
    mod_tests.linkLibC();

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.has_side_effects = true;

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // Add include paths for C headers
    exe_tests.addIncludePath(b.path("src"));
    exe_tests.addIncludePath(b.path("src/sqlite"));
    exe_tests.addIncludePath(b.path("src/c_api"));

    // Link SQLite static library to exe tests
    exe_tests.linkLibrary(sqlite_lib);
    exe_tests.linkLibC();

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.has_side_effects = true;

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // TODO Application executable
    const todo_exe = b.addExecutable(.{
        .name = "todo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("todo/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Engine12", .module = mod },
                .{ .name = "vigil", .module = vigil.module("vigil") },
                .{ .name = "ziggurat", .module = ziggurat_mod },
            },
        }),
    });

    // Add include paths for C headers
    todo_exe.addIncludePath(b.path("src"));
    todo_exe.addIncludePath(b.path("src/sqlite"));
    todo_exe.addIncludePath(b.path("src/c_api"));

    // Link SQLite static library to todo executable
    todo_exe.linkLibrary(sqlite_lib);
    todo_exe.linkLibC();

    // Install todo executable
    b.installArtifact(todo_exe);

    // TODO run step
    const todo_run_step = b.step("todo-run", "Run the TODO application");
    const todo_run_cmd = b.addRunArtifact(todo_exe);
    todo_run_step.dependOn(&todo_run_cmd.step);
    todo_run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        todo_run_cmd.addArgs(args);
    }

    // TODO test step
    const todo_test_exe = b.addTest(.{
        .root_module = todo_exe.root_module,
    });

    // Add include paths for C headers
    todo_test_exe.addIncludePath(b.path("src"));
    todo_test_exe.addIncludePath(b.path("src/sqlite"));
    todo_test_exe.addIncludePath(b.path("src/c_api"));

    // Link SQLite static library to todo test executable
    todo_test_exe.linkLibrary(sqlite_lib);
    todo_test_exe.linkLibC();

    const todo_test_step = b.step("todo-test", "Run TODO application tests");
    const run_todo_tests = b.addRunArtifact(todo_test_exe);
    todo_test_step.dependOn(&run_todo_tests.step);

    // CLI executable
    const cli_exe = b.addExecutable(.{
        .name = "e12",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Install CLI executable
    b.installArtifact(cli_exe);

    // CLI install step
    const cli_install_step = b.step("cli-install", "Install e12 CLI tool");
    const cli_install_artifact = b.addInstallArtifact(cli_exe, .{});
    cli_install_step.dependOn(&cli_install_artifact.step);

    // Add reminder message after installation
    const cli_reminder_cmd = b.addSystemCommand(&.{ "sh", "-c" });
    cli_reminder_cmd.addArgs(&.{
        "printf '\\n\\033[1;32m✓ e12 CLI installed successfully!\\033[0m\\n\\nTo use the e12 command, add it to your PATH:\\n  For zsh: source ~/.zshrc\\n  For bash: source ~/.bashrc\\n\\nOr restart your terminal.\\n\\nYou can also run it directly: ./zig-out/bin/e12\\n\\n'",
    });
    cli_install_step.dependOn(&cli_reminder_cmd.step);
}
