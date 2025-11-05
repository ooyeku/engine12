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
                        // Get the collection value using comptime introspection
                        const collection_value = try getCollectionValue(for_node.collection_path, ctx, allocator);
                        defer collection_value.deinit();

                        // Iterate over items
                        var index: usize = 0;
                        while (index < collection_value.len) : (index += 1) {
                            const item_value = try collection_value.getItem(index, allocator);
                            defer item_value.deinit();

                            // Render nodes with loop context
                            try renderNodesWithLoopVars(for_node.block.nodes, ctx, for_node.item_name, item_value.value, index, collection_value.len, buffer, allocator);
                        }
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

                        // Field not found - provide helpful error message
                        // Runtime error: field not found in struct
                        return error.InvalidVariablePath;
                    },
                    .pointer => |ptr_info| {
                        if (ptr_info.size == .slice) {
                            // Handle slices - convert to string representation for now
                            // Full iteration support would require more complex handling
                            return formatValue(value, allocator);
                        }
                        // Cannot access fields on non-slice pointers
                        return error.InvalidVariablePath;
                    },
                    else => {
                        // Cannot access fields on non-struct types
                        return error.InvalidVariablePath;
                    },
                }
            }

            // Helper to get collection value using comptime introspection
            fn getCollectionValue(collection_path: []const []const u8, ctx: context_type, allocator: std.mem.Allocator) !CollectionWrapper {
                return getCollectionValueImpl(ctx, collection_path, allocator);
            }

            // Comptime introspection to get collection value
            fn getCollectionValueImpl(value: anytype, path: []const []const u8, allocator: std.mem.Allocator) !CollectionWrapper {
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
                                    // Last field - check if it's a collection
                                    return wrapCollection(field_value);
                                } else {
                                    // Navigate deeper
                                    return getCollectionValueImpl(field_value, path[1..], allocator);
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

            // Wrap a collection into CollectionWrapper based on its type
            fn wrapCollection(collection: anytype) !CollectionWrapper {
                const T = @TypeOf(collection);
                const type_info = @typeInfo(T);

                return switch (type_info) {
                    .pointer => |ptr_info| switch (ptr_info.size) {
                        .slice => {
                            // Handle slices []T or []const T
                            return CollectionWrapper.initSlice(collection, ptr_info.child);
                        },
                        else => error.InvalidVariablePath,
                    },
                    .array => |array_info| {
                        // Handle arrays [N]T
                        return CollectionWrapper.initArray(collection, array_info.child);
                    },
                    .@"struct" => {
                        // Check if it's ArrayListUnmanaged
                        if (@hasDecl(T, "items") and @hasDecl(T, "capacity")) {
                            // Assume it's ArrayListUnmanaged-like
                            const ItemType = @TypeOf(collection.items[0]);
                            return CollectionWrapper.initArrayList(collection, ItemType);
                        }
                        return error.InvalidVariablePath;
                    },
                    else => error.InvalidVariablePath,
                };
            }

            // Helper to render nodes with loop variables
            fn renderNodesWithLoopVars(
                nodes: []const ast.TemplateAST.Node,
                ctx: context_type,
                item_name: []const u8,
                item_value: []const u8,
                index: usize,
                total: usize,
                buffer: *std.ArrayListUnmanaged(u8),
                allocator: std.mem.Allocator,
            ) !void {
                // Create loop context with item and index variables
                const loop_ctx = LoopContext{
                    .parent_ctx = ctx,
                    .item_name = item_name,
                    .item_value = item_value,
                    .index = index,
                    .total = total,
                };

                // Render nodes with loop context
                try renderNodesWithContext(nodes, loop_ctx, buffer, allocator);
            }

            // Render nodes with explicit context (supports both main ctx and loop ctx)
            fn renderNodesWithContext(
                nodes: []const ast.TemplateAST.Node,
                ctx: anytype,
                buffer: *std.ArrayListUnmanaged(u8),
                allocator: std.mem.Allocator,
            ) (std.mem.Allocator.Error || error{InvalidVariablePath})!void {
                for (nodes) |node| {
                    try renderNodeWithContext(node, ctx, buffer, allocator);
                }
            }

            fn renderNodeWithContext(
                node: ast.TemplateAST.Node,
                ctx: anytype,
                buffer: *std.ArrayListUnmanaged(u8),
                allocator: std.mem.Allocator,
            ) (std.mem.Allocator.Error || error{InvalidVariablePath})!void {
                switch (node) {
                    .text => |text| {
                        try buffer.appendSlice(allocator, text);
                    },
                    .variable => |var_node| {
                        const value = try getVariableValueWithContext(var_node.path, ctx, allocator);
                        defer allocator.free(value);
                        const escaped = try escape.Escape.escapeHtml(allocator, value);
                        defer allocator.free(escaped);
                        try buffer.appendSlice(allocator, escaped);
                    },
                    .raw_variable => |var_node| {
                        const value = try getVariableValueWithContext(var_node.path, ctx, allocator);
                        defer allocator.free(value);
                        try buffer.appendSlice(allocator, value);
                    },
                    .if_block => |if_node| {
                        const condition_value = try getVariableValueWithContext(if_node.condition.path, ctx, allocator);
                        defer allocator.free(condition_value);

                        const is_true = isTruthy(condition_value);
                        if (is_true) {
                            try renderNodesWithContext(if_node.true_block.nodes, ctx, buffer, allocator);
                        } else if (if_node.false_block) |false_block| {
                            try renderNodesWithContext(false_block.nodes, ctx, buffer, allocator);
                        }
                    },
                    .for_block => |for_node| {
                        // Nested loops - get collection from current context
                        const collection_value = try getCollectionValueWithContext(for_node.collection_path, ctx, allocator);
                        defer collection_value.deinit();

                        var index: usize = 0;
                        while (index < collection_value.len) : (index += 1) {
                            const item_value = try collection_value.getItem(index, allocator);
                            defer item_value.deinit();

                            // Check if we're already in a loop context
                            const T = @TypeOf(ctx);
                            if (T == LoopContext) {
                                // Nested loop - preserve parent loop context
                                try renderNodesWithLoopVars(for_node.block.nodes, ctx.parent_ctx, for_node.item_name, item_value.value, index, collection_value.len, buffer, allocator);
                            } else {
                                // First level loop
                                try renderNodesWithLoopVars(for_node.block.nodes, ctx, for_node.item_name, item_value.value, index, collection_value.len, buffer, allocator);
                            }
                        }
                    },
                    .include => |_| {
                        // Includes handled separately
                    },
                }
            }

            // Get variable value with context (checks loop context first)
            fn getVariableValueWithContext(path: []const []const u8, ctx: anytype, allocator: std.mem.Allocator) ![]const u8 {
                // Check if context is LoopContext
                const T = @TypeOf(ctx);
                if (T == LoopContext) {
                    // Check for parent navigation (../)
                    if (path.len > 0 and std.mem.eql(u8, path[0], "..")) {
                        // Navigate to parent context
                        if (path.len == 1) {
                            // Just "../" - return parent context as string (not useful, but handle it)
                            return error.InvalidVariablePath;
                        }
                        // Use parent context with remaining path
                        return getVariableValueImpl(ctx.parent_ctx, path[1..], allocator);
                    }

                    // Check if path matches loop variable names
                    if (path.len == 1) {
                        if (std.mem.eql(u8, path[0], ctx.item_name)) {
                            return try allocator.dupe(u8, ctx.item_value);
                        }
                        if (std.mem.eql(u8, path[0], "index")) {
                            return try std.fmt.allocPrint(allocator, "{d}", .{ctx.index});
                        }
                        if (std.mem.eql(u8, path[0], "first")) {
                            const first_str = if (ctx.index == 0) "true" else "false";
                            return try allocator.dupe(u8, first_str);
                        }
                        if (std.mem.eql(u8, path[0], "last")) {
                            const last_str = if (ctx.index == ctx.total - 1) "true" else "false";
                            return try allocator.dupe(u8, last_str);
                        }
                    }
                    // Fall through to parent context
                    return getVariableValueImpl(ctx.parent_ctx, path, allocator);
                }
                // Regular context - check for parent navigation (should not happen in non-loop context)
                if (path.len > 0 and std.mem.eql(u8, path[0], "..")) {
                    return error.InvalidVariablePath;
                }
                return getVariableValueImpl(ctx, path, allocator);
            }

            // Get collection value with context
            fn getCollectionValueWithContext(collection_path: []const []const u8, ctx: anytype, allocator: std.mem.Allocator) !CollectionWrapper {
                const T = @TypeOf(ctx);
                if (T == LoopContext) {
                    // Try parent context first
                    return getCollectionValueImpl(ctx.parent_ctx, collection_path, allocator);
                }
                return getCollectionValueImpl(ctx, collection_path, allocator);
            }

            const LoopContext = struct {
                parent_ctx: context_type,
                item_name: []const u8,
                item_value: []const u8,
                index: usize,
                total: usize,
            };

            const CollectionWrapper = struct {
                const CollectionData = union(enum) {
                    slice: *const anyopaque,
                    array: *const anyopaque,
                    array_list: *const anyopaque,
                };

                data: CollectionData,
                len: usize,
                get_item_fn: *const fn (*const anyopaque, usize, std.mem.Allocator) (std.mem.Allocator.Error || error{InvalidVariablePath})![]const u8,

                fn initSlice(collection: anytype, comptime ItemType: type) CollectionWrapper {
                    _ = ItemType; // Used for type checking at comptime
                    const CollectionType = @TypeOf(collection);
                    return CollectionWrapper{
                        .data = .{ .slice = @as(*const anyopaque, @ptrCast(&collection)) },
                        .len = collection.len,
                        .get_item_fn = &struct {
                            fn getItem(ptr: *const anyopaque, idx: usize, alloc: std.mem.Allocator) (std.mem.Allocator.Error || error{InvalidVariablePath})![]const u8 {
                                const slice_ptr: *const CollectionType = @ptrCast(@alignCast(ptr));
                                const slice = slice_ptr.*;
                                if (idx >= slice.len) return error.InvalidVariablePath;
                                const item = slice[idx];
                                return formatValue(item, alloc);
                            }
                        }.getItem,
                    };
                }

                fn initArray(collection: anytype, comptime ItemType: type) CollectionWrapper {
                    _ = ItemType; // Used for type checking at comptime
                    const CollectionType = @TypeOf(collection);
                    return CollectionWrapper{
                        .data = .{ .array = @as(*const anyopaque, @ptrCast(&collection)) },
                        .len = collection.len,
                        .get_item_fn = &struct {
                            fn getItem(ptr: *const anyopaque, idx: usize, alloc: std.mem.Allocator) (std.mem.Allocator.Error || error{InvalidVariablePath})![]const u8 {
                                const array_ptr: *const CollectionType = @ptrCast(@alignCast(ptr));
                                const array = array_ptr.*;
                                if (idx >= array.len) return error.InvalidVariablePath;
                                const item = array[idx];
                                return formatValue(item, alloc);
                            }
                        }.getItem,
                    };
                }

                fn initArrayList(collection: anytype, comptime ItemType: type) CollectionWrapper {
                    _ = ItemType; // Used for type checking at comptime
                    const CollectionType = @TypeOf(collection);
                    return CollectionWrapper{
                        .data = .{ .array_list = @as(*const anyopaque, @ptrCast(&collection)) },
                        .len = collection.items.len,
                        .get_item_fn = &struct {
                            fn getItem(ptr: *const anyopaque, idx: usize, alloc: std.mem.Allocator) (std.mem.Allocator.Error || error{InvalidVariablePath})![]const u8 {
                                const list_ptr: *const CollectionType = @ptrCast(@alignCast(ptr));
                                const list = list_ptr.*;
                                if (idx >= list.items.len) return error.InvalidVariablePath;
                                const item = list.items[idx];
                                return formatValue(item, alloc);
                            }
                        }.getItem,
                    };
                }

                fn deinit(self: CollectionWrapper) void {
                    _ = self;
                }

                fn getItem(self: CollectionWrapper, index: usize, allocator: std.mem.Allocator) !struct {
                    value: []const u8,
                    item_allocator: std.mem.Allocator,
                    fn deinit(item: @This()) void {
                        item.item_allocator.free(item.value);
                    }
                } {
                    if (index >= self.len) {
                        return error.InvalidVariablePath;
                    }

                    const ptr = switch (self.data) {
                        .slice => |p| p,
                        .array => |p| p,
                        .array_list => |p| p,
                    };
                    const value_str = try self.get_item_fn(ptr, index, allocator);

                    return .{
                        .value = value_str,
                        .item_allocator = allocator,
                    };
                }
            };

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
                    .optional => |_| {
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
                // Empty strings are falsy
                if (value.len == 0) return false;

                // Explicit false values
                if (std.mem.eql(u8, value, "false")) return false;
                if (std.mem.eql(u8, value, "0")) return false;
                if (std.mem.eql(u8, value, "null")) return false;
                if (std.mem.eql(u8, value, "nil")) return false;

                // Explicit true values
                if (std.mem.eql(u8, value, "true")) return true;
                if (std.mem.eql(u8, value, "1")) return true;

                // All other non-empty strings are truthy
                return true;
            }
        };
    }
};
