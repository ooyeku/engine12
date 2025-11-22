const std = @import("std");

/// Simple template rendering utility for runtime template processing
/// Reads template files from disk and performs basic variable replacement
/// Works without hot reload (production-safe)
///
/// Example:
/// ```zig
/// const html = try renderSimple(
///     "src/templates/index.zt.html",
///     .{ .title = "Welcome", .message = "Hello" },
///     allocator
/// );
/// defer allocator.free(html);
/// ```
pub fn renderSimple(
    template_path: []const u8,
    variables: anytype,
    allocator: std.mem.Allocator,
) ![]u8 {
    // Read template file
    const file = std.fs.cwd().openFile(template_path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => error.TemplateNotFound,
            else => err,
        };
    };
    defer file.close();

    const template_content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| {
        return switch (err) {
            error.FileTooBig => error.TemplateTooLarge,
            else => err,
        };
    };
    defer allocator.free(template_content);

    // Get variable struct type info
    const VariableType = @TypeOf(variables);
    const type_info = @typeInfo(VariableType);
    if (type_info != .Struct) {
        return error.InvalidVariableType;
    }

    var result = try allocator.dupe(u8, template_content);
    errdefer allocator.free(result);

    // Replace each field in the struct
    inline for (type_info.Struct.fields) |field| {
        const field_name = field.name;
        const field_value = @field(variables, field_name);

        // Convert field value to string
        const value_str = switch (@typeInfo(@TypeOf(field_value))) {
            .Pointer => |ptr_info| switch (ptr_info.size) {
                .Slice => if (ptr_info.child == u8) field_value else blk: {
                    // For non-string slices, format as JSON or use default
                    var buffer = std.ArrayList(u8).init(allocator);
                    defer buffer.deinit();
                    try std.fmt.format(buffer.writer(), "{}", .{field_value});
                    break :blk try buffer.toOwnedSlice();
                },
                else => blk: {
                    var buffer = std.ArrayList(u8).init(allocator);
                    defer buffer.deinit();
                    try std.fmt.format(buffer.writer(), "{}", .{field_value});
                    break :blk try buffer.toOwnedSlice();
                },
            },
            .Int, .ComptimeInt => blk: {
                var buffer = std.ArrayList(u8).init(allocator);
                defer buffer.deinit();
                try std.fmt.format(buffer.writer(), "{d}", .{field_value});
                break :blk try buffer.toOwnedSlice();
            },
            .Float, .ComptimeFloat => blk: {
                var buffer = std.ArrayList(u8).init(allocator);
                defer buffer.deinit();
                try std.fmt.format(buffer.writer(), "{d}", .{field_value});
                break :blk try buffer.toOwnedSlice();
            },
            .Bool => if (field_value) "true" else "false",
            .Optional => if (field_value) |val| blk: {
                // Recursively handle optional value
                var buffer = std.ArrayList(u8).init(allocator);
                defer buffer.deinit();
                try std.fmt.format(buffer.writer(), "{}", .{val});
                break :blk try buffer.toOwnedSlice();
            } else "",
            else => blk: {
                // Default: format as string
                var buffer = std.ArrayList(u8).init(allocator);
                defer buffer.deinit();
                try std.fmt.format(buffer.writer(), "{}", .{field_value});
                break :blk try buffer.toOwnedSlice();
            },
        };

        // Create replacement pattern: {{ .field_name }}
        const pattern = try std.fmt.allocPrint(allocator, "{{{{ .{s} }}}}", .{field_name});
        defer allocator.free(pattern);

        // Replace all occurrences
        const new_result = try std.mem.replaceOwned(u8, allocator, result, pattern, value_str);
        allocator.free(result);
        result = new_result;

        // Free value_str if it was allocated
        if (@typeInfo(@TypeOf(field_value)) != .Pointer or
            (@typeInfo(@TypeOf(field_value)) == .Pointer and @typeInfo(@TypeOf(field_value)).Pointer.size != .Slice))
        {
            allocator.free(value_str);
        }
    }

    return result;
}

test "renderSimple with string variables" {
    const allocator = std.testing.allocator;

    // Create a temporary template file
    const test_template = "<h1>{{ .title }}</h1><p>{{ .message }}</p>";
    const test_file = "test_template_simple.zt.html";
    try std.fs.cwd().writeFile(test_file, test_template);
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const html = try renderSimple(
        test_file,
        .{ .title = "Test Title", .message = "Test Message" },
        allocator,
    );
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "Test Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Test Message") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "{{ .title }}") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "{{ .message }}") == null);
}

test "renderSimple with integer variable" {
    const allocator = std.testing.allocator;

    const test_template = "Count: {{ .count }}";
    const test_file = "test_template_int.zt.html";
    try std.fs.cwd().writeFile(test_file, test_template);
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const html = try renderSimple(
        test_file,
        .{ .count = 42 },
        allocator,
    );
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "42") != null);
}

test "renderSimple with boolean variable" {
    const allocator = std.testing.allocator;

    const test_template = "Active: {{ .is_active }}";
    const test_file = "test_template_bool.zt.html";
    try std.fs.cwd().writeFile(test_file, test_template);
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const html = try renderSimple(
        test_file,
        .{ .is_active = true },
        allocator,
    );
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "true") != null);
}
