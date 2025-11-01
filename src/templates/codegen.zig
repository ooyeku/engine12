const std = @import("std");
const ast = @import("ast.zig");
const escape = @import("escape.zig");

/// Code generator for templates
/// Generates optimized rendering functions at comptime
pub const Codegen = struct {
    /// Generate render function for AST and context type
    pub fn generateRenderFunction(
        ast_tree: ast.TemplateAST,
        comptime context_type: type,
    ) type {
        return struct {
            pub fn render(ctx: context_type, allocator: std.mem.Allocator) ![]const u8 {
                // Estimate buffer size (simplified - could be more accurate)
                var buffer = std.ArrayListUnmanaged(u8){};
                defer buffer.deinit(allocator);
                
                // Render all nodes
                try renderNodes(ast_tree.nodes, ctx, &buffer, allocator);
                
                return buffer.toOwnedSlice(allocator);
            }
            
            fn renderNodes(
                nodes: []const ast.TemplateAST.Node,
                ctx: context_type,
                buffer: *std.ArrayListUnmanaged(u8),
                allocator: std.mem.Allocator,
            ) (std.mem.Allocator.Error || error{InvalidVariablePath})!void {
                for (nodes) |node| {
                    try renderNode(node, ctx, buffer, allocator);
                }
            }
            
            fn renderNode(
                node: ast.TemplateAST.Node,
                ctx: context_type,
                buffer: *std.ArrayListUnmanaged(u8),
                allocator: std.mem.Allocator,
            ) (std.mem.Allocator.Error || error{InvalidVariablePath})!void {
                switch (node) {
                    .text => |text| {
                        try buffer.appendSlice(allocator, text);
                    },
                    .variable => |var_node| {
                        const value = try getVariableValue(var_node.path, ctx, allocator);
                        defer allocator.free(value);
                        const escaped = try escape.Escape.escapeHtml(allocator, value);
                        defer allocator.free(escaped);
                        try buffer.appendSlice(allocator, escaped);
                    },
                    .raw_variable => |var_node| {
                        const value = try getVariableValue(var_node.path, ctx, allocator);
                        defer allocator.free(value);
                        try buffer.appendSlice(allocator, value);
                    },
                    .if_block => |if_node| {
                        const condition_value = try getVariableValue(if_node.condition.path, ctx, allocator);
                        defer allocator.free(condition_value);
                        
                        const is_true = isTruthy(condition_value);
                        if (is_true) {
                            try renderNodes(if_node.true_block.nodes, ctx, buffer, allocator);
                        } else if (if_node.false_block) |false_block| {
                            try renderNodes(false_block.nodes, ctx, buffer, allocator);
                        }
                    },
                    .for_block => |for_node| {
                        // For Phase 5, placeholder for array iteration
                        // Full implementation would require runtime type checking and iteration
                        _ = for_node;
                    },
                    .include => |_| {
                        // Includes handled separately in Phase 7
                    },
                }
            }
            
            fn getVariableValue(
                path: []const []const u8,
                ctx: context_type,
                allocator: std.mem.Allocator,
            ) ![]const u8 {
                if (path.len == 0) {
                    return error.InvalidVariablePath;
                }
                
                // Navigate through context using runtime reflection
                return getVariableValueImpl(ctx, path, allocator);
            }
            
            fn getVariableValueImpl(value: anytype, path: []const []const u8, allocator: std.mem.Allocator) ![]const u8 {
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
                        
                        return error.InvalidVariablePath;
                    },
                    else => {
                        return error.InvalidVariablePath;
                    },
                }
            }
            
            fn formatValue(value: anytype, allocator: std.mem.Allocator) ![]const u8 {
                const T = @TypeOf(value);
                
                return switch (@typeInfo(T)) {
                    .pointer => |ptr_info| switch (ptr_info.size) {
                        .slice => {
                            if (ptr_info.child == u8) {
                                // String slice
                                return try allocator.dupe(u8, value);
                            } else {
                                // Other slice - convert to string representation
                                return try std.fmt.allocPrint(allocator, "{any}", .{value});
                            }
                        },
                        else => try std.fmt.allocPrint(allocator, "{any}", .{value}),
                    },
                    .int => try std.fmt.allocPrint(allocator, "{d}", .{value}),
                    .float => try std.fmt.allocPrint(allocator, "{d}", .{value}),
                    .bool => {
                        const bool_str = if (value) "true" else "false";
                        return try allocator.dupe(u8, bool_str);
                    },
                    .@"optional" => |_| {
                        if (value) |v| {
                            return formatValue(v, allocator);
                        } else {
                            return try allocator.dupe(u8, "");
                        }
                    },
                    else => try std.fmt.allocPrint(allocator, "{any}", .{value}),
                };
            }
            
            fn isTruthy(value: []const u8) bool {
                // Check if value is "truthy"
                if (value.len == 0) return false;
                if (std.mem.eql(u8, value, "false")) return false;
                if (std.mem.eql(u8, value, "0")) return false;
                if (std.mem.eql(u8, value, "")) return false;
                return true;
            }
            
        };
    }
};

