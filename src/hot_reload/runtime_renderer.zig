const std = @import("std");
const escape = @import("../templates/escape.zig");

/// Simple runtime template renderer for hot reloading
/// Supports basic variable substitution: {{ .field }} and {{! .field }}
/// Note: This is a simplified version - full template features (if/for blocks) require comptime compilation
pub const RuntimeRenderer = struct {
    /// Render template with context using simple variable substitution
    /// Supports:
    /// - {{ .field }} - HTML-escaped variables
    /// - {{! .field }} - Raw (unescaped) variables
    pub fn render(
        template_content: []const u8,
        comptime Context: type,
        ctx: Context,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < template_content.len) {
            // Look for {{ or {%
            const var_start = std.mem.indexOf(u8, template_content[i..], "{{");
            const block_start = std.mem.indexOf(u8, template_content[i..], "{%");

            // Determine which comes first
            var next_token: ?struct { start: usize, is_block: bool } = null;

            if (var_start) |vs| {
                next_token = .{ .start = i + vs, .is_block = false };
            }
            if (block_start) |bs| {
                if (next_token == null or (var_start != null and bs < var_start.?)) {
                    next_token = .{ .start = i + bs, .is_block = true };
                }
            }

            if (next_token) |token| {
                // Add text before token
                if (token.start > i) {
                    try result.appendSlice(allocator, template_content[i..token.start]);
                }

                if (token.is_block) {
                    // For now, skip {% blocks %} - they require comptime compilation
                    // Just output the block as-is
                    const block_end = std.mem.indexOf(u8, template_content[token.start + 2..], "%}") orelse {
                        // No closing tag, skip to end
                        i = template_content.len;
                        continue;
                    };
                    try result.appendSlice(allocator, template_content[token.start..token.start + 2 + block_end + 2]);
                    i = token.start + 2 + block_end + 2;
                } else {
                    // Parse {{ ... }} variable
                    const var_end = std.mem.indexOf(u8, template_content[token.start + 2..], "}}") orelse {
                        // No closing tag, skip
                        i = template_content.len;
                        continue;
                    };

                    const var_content = template_content[token.start + 2..token.start + 2 + var_end];
                    const is_raw = var_content.len > 0 and var_content[0] == '!';
                    const var_str = if (is_raw) std.mem.trim(u8, var_content[1..], " \t\n") else std.mem.trim(u8, var_content, " \t\n");

                    // Get variable value
                    const value = getVariableValue(var_str, Context, ctx, allocator) catch |err| {
                        // If variable not found or null, output empty string
                        if (err == error.InvalidVariablePath) {
                            i = token.start + 2 + var_end + 2;
                            continue;
                        }
                        return err;
                    };
                    defer allocator.free(value);

                    // Output value (escaped or raw)
                    if (is_raw) {
                        try result.appendSlice(allocator, value);
                    } else {
                        const escaped = try escape.Escape.escapeHtml(allocator, value);
                        defer allocator.free(escaped);
                        try result.appendSlice(allocator, escaped);
                    }

                    i = token.start + 2 + var_end + 2;
                }
            } else {
                // No more tokens - add remaining text
                try result.appendSlice(allocator, template_content[i..]);
                break;
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Get variable value from context
    fn getVariableValue(
        var_path: []const u8,
        comptime Context: type,
        ctx: Context,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        // Remove leading dot if present
        const path = if (var_path.len > 0 and var_path[0] == '.') var_path[1..] else var_path;

        // Split path by dots
        var parts = std.ArrayListUnmanaged([]const u8){};
        defer parts.deinit(allocator);

        var start: usize = 0;
        var i: usize = 0;
        while (i < path.len) {
            if (path[i] == '.') {
                if (i > start) {
                    const part = path[start..i];
                    try parts.append(allocator, part);
                }
                start = i + 1;
            }
            i += 1;
        }
        if (start < path.len) {
            try parts.append(allocator, path[start..]);
        }

        // Navigate context using comptime introspection
        return getVariableValueImpl(ctx, parts.items, allocator);
    }

    /// Get variable value using comptime introspection (similar to codegen)
    fn getVariableValueImpl(
        value: anytype,
        path: []const []const u8,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        switch (type_info) {
            .@"struct" => |struct_info| {
                if (path.len == 0) {
                    return error.InvalidVariablePath;
                }

                const field_name = path[0];

                // Find field and get its value using inline for
                inline for (struct_info.fields) |field| {
                    if (std.mem.eql(u8, field.name, field_name)) {
                        const field_value = @field(value, field.name);

                        if (path.len == 1) {
                            // Last field - convert to string
                            return formatValue(field_value, allocator);
                        } else {
                            // Navigate deeper
                            return getVariableValueImpl(field_value, path[1..], allocator);
                        }
                    }
                }

                // Field not found
                return error.InvalidVariablePath;
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    // String slice - return as-is
                    return try allocator.dupe(u8, value);
                }
                return error.InvalidVariablePath;
            },
            else => {
                // Convert to string
                return formatValue(value, allocator);
            },
        }
    }

    /// Format a value as a string
    fn formatValue(value: anytype, allocator: std.mem.Allocator) ![]const u8 {
        const T = @TypeOf(value);

        return switch (@typeInfo(T)) {
            .pointer => |ptr_info| switch (ptr_info.size) {
                .slice => {
                    if (ptr_info.child == u8) {
                        return try allocator.dupe(u8, value);
                    } else {
                        return try std.fmt.allocPrint(allocator, "{any}", .{value});
                    }
                },
                else => try std.fmt.allocPrint(allocator, "{any}", .{value}),
            },
            .array => |arr_info| {
                if (arr_info.child == u8) {
                    return try allocator.dupe(u8, &value);
                } else {
                    return try std.fmt.allocPrint(allocator, "{any}", .{value});
                }
            },
            .int => try std.fmt.allocPrint(allocator, "{d}", .{value}),
            .float => try std.fmt.allocPrint(allocator, "{d}", .{value}),
            .bool => {
                const bool_str = if (value) "true" else "false";
                return try allocator.dupe(u8, bool_str);
            },
            .optional => {
                if (value) |val| {
                    return formatValue(val, allocator);
                } else {
                    // Return empty string for null optional
                    return try allocator.dupe(u8, "");
                }
            },
            else => {
                // Try to convert to string using format
                return try std.fmt.allocPrint(allocator, "{any}", .{value});
            },
        };
    }
};

