const std = @import("std");
const ast = @import("ast.zig");

/// Type inference and validation for templates
/// Validates that context types match template requirements
pub const TypeChecker = struct {
    /// Infer required type from AST
    /// Returns a struct type definition that represents required context
    /// This is a simplified version - full implementation would generate actual struct types
    pub fn inferRequiredType(comptime ast_tree: ast.TemplateAST) type {
        // For Phase 3, we'll use a simple approach
        // Walk AST and collect field requirements
        // Full implementation would use comptime type building
        _ = ast_tree;
        
        // Placeholder - return a generic struct
        // In full implementation, this would build a struct type at comptime
        return struct {
            // Fields would be inferred from AST
        };
    }
    
    /// Validate that context type matches AST requirements
    /// This is a compile-time check
    pub fn validateContext(
        ast_tree: ast.TemplateAST,
        comptime context_type: type,
    ) void {
        // For Phase 3, we'll do basic validation
        // Walk AST and check that all accessed fields exist in context_type
        
        // Validate each node
        for (ast_tree.nodes) |node| {
            validateNode(node, context_type);
        }
    }
    
    /// Validate a single node
    fn validateNode(comptime node: ast.TemplateAST.Node, comptime context_type: type) void {
        switch (node) {
            .variable => |var_node| {
                validateVariablePath(var_node.path, context_type);
            },
            .raw_variable => |var_node| {
                validateVariablePath(var_node.path, context_type);
            },
            .if_block => |if_node| {
                validateVariablePath(if_node.condition.path, context_type);
                validateContext(if_node.true_block, context_type);
                if (if_node.false_block) |false_block| {
                    validateContext(false_block, context_type);
                }
            },
            .for_block => |for_node| {
                validateVariablePath(for_node.collection_path, context_type);
                validateContext(for_node.block, context_type);
            },
            .include => |_| {
                // Includes validated separately
            },
            .text => |_| {
                // Text nodes don't need validation
            },
        }
    }
    
    /// Validate that a variable path exists in context type
    fn validateVariablePath(
        comptime path: []const []const u8,
        comptime context_type: type,
    ) void {
        if (path.len == 0) {
            // Root context - always valid
            return;
        }
        
        // Navigate through struct fields
        var current_type = context_type;
        var i: usize = 0;
        
        while (i < path.len) : (i += 1) {
            const field_name = path[i];
            
            // Check if current_type is a struct
            const type_info = @typeInfo(current_type);
            switch (type_info) {
                .@"struct" => |struct_info| {
                    // Find field in struct
                    var field_found = false;
                    var field_type: type = void;
                    
                    inline for (struct_info.fields) |field| {
                        if (std.mem.eql(u8, field.name, field_name)) {
                            field_found = true;
                            field_type = field.type;
                            break;
                        }
                    }
                    
                    if (!field_found) {
                        @compileError("Context type '" ++ @typeName(context_type) ++ "' has no field '" ++ field_name ++ "'");
                    }
                    
                    // Check if field is optional
                    const field_type_info = @typeInfo(field_type);
                    switch (field_type_info) {
                        .@"optional" => |optional_info| {
                            current_type = optional_info.child;
                        },
                        else => {
                            current_type = field_type;
                        },
                    }
                    
                    // If this is the last path element, check if it's accessible
                    if (i == path.len - 1) {
                        // Field exists and is accessible
                        return;
                    }
                    
                    // For nested paths, check if current_type supports field access
                    // Arrays and slices are handled specially
                    const next_type_info = @typeInfo(current_type);
                    switch (next_type_info) {
                        .array, .pointer => {
                            if (i < path.len - 1) {
                                @compileError("Cannot access field '" ++ path[i + 1] ++ "' on array/slice type");
                            }
                        },
                        else => {},
                    }
                },
                else => {
                    @compileError("Context type must be a struct");
                },
            }
        }
    }
};

// Tests
test "validate simple context" {
    const TestAST = ast.TemplateAST.init(&[_]ast.TemplateAST.Node{
        .{ .variable = ast.TemplateAST.VariableNode{
            .path = &[_][]const u8{"name"},
            .filters = &[_]ast.TemplateAST.Filter{},
        } },
    });
    
    const TestContext = struct {
        name: []const u8,
    };
    
    TypeChecker.validateContext(TestAST, TestContext);
}

test "validate nested context" {
    const TestAST = ast.TemplateAST.init(&[_]ast.TemplateAST.Node{
        .{ .variable = ast.TemplateAST.VariableNode{
            .path = &[_][]const u8{"user", "name"},
            .filters = &[_]ast.TemplateAST.Filter{},
        } },
    });
    
    const TestContext = struct {
        user: struct {
            name: []const u8,
        },
    };
    
    TypeChecker.validateContext(TestAST, TestContext);
}

