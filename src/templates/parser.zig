const std = @import("std");
const ast = @import("ast.zig");

/// Comptime template parser
/// Parses template strings into AST at compile time
pub const Parser = struct {
    /// Parse a template string into AST
    pub fn parse(comptime template: []const u8) !ast.TemplateAST {
        // Increase branch quota for parsing large templates
        @setEvalBranchQuota(1000000);
        // Use a comptime helper to build nodes
        var end_pos: usize = 0;
        const nodes = try parseNodes(template, 0, &end_pos);
        return ast.TemplateAST.init(nodes);
    }
    
    /// Parse nodes recursively at comptime
    fn parseNodes(
        comptime template: []const u8,
        comptime start: usize,
        comptime end_pos: *usize,
    ) ![]const ast.TemplateAST.Node {
        var result: []const ast.TemplateAST.Node = &[_]ast.TemplateAST.Node{};
        var i: usize = start;
        end_pos.* = start;
        
        while (i < template.len) {
            // Look for {{ or {%
            const var_start = std.mem.indexOf(u8, template[i..], "{{");
            const block_start = std.mem.indexOf(u8, template[i..], "{%");
            
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
                    const text = template[i..token.start];
                    if (text.len > 0) {
                        result = appendNode(result, ast.TemplateAST.Node{ .text = text });
                    }
                }
                
                if (token.is_block) {
                    // Parse {% ... %} block
                    const block_end = std.mem.indexOf(u8, template[token.start + 2..], "%}") orelse {
                        return error.UnclosedBlock;
                    };
                    const block_content = template[token.start + 2..token.start + 2 + block_end];
                    const block_end_pos = token.start + 2 + block_end + 2;
                    
                    // Parse block type
                    const trimmed = std.mem.trim(u8, block_content, " \t\n");
                    if (std.mem.startsWith(u8, trimmed, "if")) {
                        // Parse if block
                        const if_result = try parseIfBlock(template, block_end_pos);
                        result = appendNode(result, ast.TemplateAST.Node{ .if_block = if_result.block });
                        i = if_result.end_pos;
                        end_pos.* = i;
                    } else if (std.mem.startsWith(u8, trimmed, "for")) {
                        // Parse for block
                        const for_result = try parseForBlock(template, block_end_pos);
                        result = appendNode(result, ast.TemplateAST.Node{ .for_block = for_result.block });
                        i = for_result.end_pos;
                        end_pos.* = i;
                    } else if (std.mem.startsWith(u8, trimmed, "include")) {
                        // Parse include
                        const include_node = try parseInclude(block_content);
                        result = appendNode(result, ast.TemplateAST.Node{ .include = include_node });
                        i = block_end_pos;
                        end_pos.* = i;
                    } else if (std.mem.startsWith(u8, trimmed, "endif") or std.mem.startsWith(u8, trimmed, "endfor")) {
                        // End tag - return what we have
                        end_pos.* = i;
                        break;
                    } else if (std.mem.startsWith(u8, trimmed, "else")) {
                        // Else tag - return what we have (handled by parseIfBlock)
                        end_pos.* = i;
                        break;
                    } else {
                        return error.InvalidIfSyntax;
                    }
                } else {
                    // Parse {{ ... }} variable
                    const var_end = std.mem.indexOf(u8, template[token.start + 2..], "}}") orelse {
                        return error.UnclosedBlock;
                    };
                    const var_content = template[token.start + 2..token.start + 2 + var_end];
                    
                    const is_raw = var_content.len > 0 and var_content[0] == '!';
                    const var_str = if (is_raw) var_content[1..] else var_content;
                    
                    const var_node = try parseVariable(std.mem.trim(u8, var_str, " \t\n"));
                    if (is_raw) {
                        result = appendNode(result, ast.TemplateAST.Node{ .raw_variable = var_node });
                    } else {
                        result = appendNode(result, ast.TemplateAST.Node{ .variable = var_node });
                    }
                    
                    i = token.start + 2 + var_end + 2;
                    end_pos.* = i;
                }
            } else {
                // No more tokens - add remaining text
                if (i < template.len) {
                    const text = template[i..];
                    if (text.len > 0) {
                        result = appendNode(result, ast.TemplateAST.Node{ .text = text });
                    }
                }
                end_pos.* = template.len;
                break;
            }
        }
        
        return result;
    }
    
    /// Parse if block
    fn parseIfBlock(comptime template: []const u8, comptime start: usize) !struct {
        block: ast.TemplateAST.IfBlock,
        end_pos: usize,
    } {
        // Find the opening if tag
        const if_start = start - 2; // Go back to {% if
        const if_block_start = std.mem.indexOf(u8, template[if_start..], "{% if") orelse {
            return error.InvalidIfSyntax;
        };
        const if_tag_start = if_start + if_block_start;
        const if_tag_end = std.mem.indexOf(u8, template[if_tag_start + 5..], "%}") orelse {
            return error.UnclosedBlock;
        };
        const if_content = template[if_tag_start + 5..if_tag_start + 5 + if_tag_end];
        
        // Parse condition
        const condition_str = std.mem.trim(u8, if_content, " \t\n");
        const condition = try parseVariable(condition_str);
        
        // Parse content until {% else %} or {% endif %}
        var content_end: usize = 0;
        const true_block_nodes = try parseNodes(template, if_tag_start + 5 + if_tag_end + 2, &content_end);
        const true_block = ast.TemplateAST.init(true_block_nodes);
        
        // Check if there's an else block
        var false_block: ?ast.TemplateAST = null;
        var final_end_pos = content_end;
        
        // Look for {% else %} or {% endif %}
        const else_pos = std.mem.indexOf(u8, template[content_end..], "{% else");
        const endif_pos = std.mem.indexOf(u8, template[content_end..], "{% endif");
        
        if (else_pos) |ep| {
            if (endif_pos == null or ep < endif_pos.?) {
                // Found else block
                const else_tag_start = content_end + ep;
                const else_tag_end = std.mem.indexOf(u8, template[else_tag_start + 7..], "%}") orelse {
                    return error.UnclosedBlock;
                };
                const else_content_start = else_tag_start + 7 + else_tag_end + 2;
                
                // Parse false block content
                var false_end_pos: usize = 0;
                const false_block_nodes = try parseNodes(template, else_content_start, &false_end_pos);
                false_block = ast.TemplateAST.init(false_block_nodes);
                
                // Find endif
                const endif_pos_after_else = std.mem.indexOf(u8, template[false_end_pos..], "{% endif") orelse {
                    return error.UnclosedBlock;
                };
                const endif_tag_start = false_end_pos + endif_pos_after_else;
                const endif_tag_end = std.mem.indexOf(u8, template[endif_tag_start + 8..], "%}") orelse {
                    return error.UnclosedBlock;
                };
                final_end_pos = endif_tag_start + 8 + endif_tag_end + 2;
            } else {
                // Found endif directly
                const endif_tag_start = content_end + endif_pos.?;
                const endif_tag_end = std.mem.indexOf(u8, template[endif_tag_start + 8..], "%}") orelse {
                    return error.UnclosedBlock;
                };
                final_end_pos = endif_tag_start + 8 + endif_tag_end + 2;
            }
        } else if (endif_pos) |ep| {
            // Found endif directly
            const endif_tag_start = content_end + ep;
            const endif_tag_end = std.mem.indexOf(u8, template[endif_tag_start + 8..], "%}") orelse {
                return error.UnclosedBlock;
            };
            final_end_pos = endif_tag_start + 8 + endif_tag_end + 2;
        } else {
            return error.UnclosedBlock;
        }
        
        return .{
            .block = ast.TemplateAST.IfBlock{
                .condition = condition,
                .true_block = true_block,
                .false_block = false_block,
            },
            .end_pos = final_end_pos,
        };
    }
    
    /// Parse for block
    fn parseForBlock(comptime template: []const u8, comptime start: usize) !struct {
        block: ast.TemplateAST.ForBlock,
        end_pos: usize,
    } {
        // Find the opening for tag
        const for_start = start - 2; // Go back to {% for
        const for_block_start = std.mem.indexOf(u8, template[for_start..], "{% for") orelse {
            return error.InvalidForSyntax;
        };
        const for_tag_start = for_start + for_block_start;
        const for_tag_end = std.mem.indexOf(u8, template[for_tag_start + 6..], "%}") orelse {
            return error.UnclosedBlock;
        };
        const for_content = template[for_tag_start + 6..for_tag_start + 6 + for_tag_end];
        
        // Parse "collection_path |item_name|"
        const trimmed = std.mem.trim(u8, for_content, " \t\n");
        
        // Find pipe separator
        const pipe_pos = std.mem.indexOfScalar(u8, trimmed, '|') orelse {
            return error.InvalidForSyntax;
        };
        
        const collection_str = std.mem.trim(u8, trimmed[0..pipe_pos], " \t\n");
        const collection_path = try parseVariablePath(collection_str);
        
        // Parse item name between pipes
        const after_pipe = trimmed[pipe_pos + 1..];
        const item_pipe_pos = std.mem.indexOfScalar(u8, after_pipe, '|') orelse {
            return error.InvalidForSyntax;
        };
        const item_name = std.mem.trim(u8, after_pipe[0..item_pipe_pos], " \t\n");
        
        // Parse content until {% endfor %}
        var content_end: usize = 0;
        const block_nodes = try parseNodes(template, for_tag_start + 6 + for_tag_end + 2, &content_end);
        const block = ast.TemplateAST.init(block_nodes);
        
        // Find {% endfor %}
        const endfor_pos = std.mem.indexOf(u8, template[content_end..], "{% endfor") orelse {
            return error.UnclosedBlock;
        };
        const endfor_tag_start = content_end + endfor_pos;
        const endfor_tag_end = std.mem.indexOf(u8, template[endfor_tag_start + 9..], "%}") orelse {
            return error.UnclosedBlock;
        };
        const final_end_pos = endfor_tag_start + 9 + endfor_tag_end + 2;
        
        return .{
            .block = ast.TemplateAST.ForBlock{
                .collection_path = collection_path,
                .item_name = item_name,
                .block = block,
            },
            .end_pos = final_end_pos,
        };
    }
    
    /// Append a node to a comptime array
    fn appendNode(comptime existing: []const ast.TemplateAST.Node, comptime new_node: ast.TemplateAST.Node) []const ast.TemplateAST.Node {
        return existing ++ &[_]ast.TemplateAST.Node{new_node};
    }
    
    /// Parse a variable expression (e.g., ".user.name | uppercase")
    fn parseVariable(comptime input: []const u8) !ast.TemplateAST.VariableNode {
        // Split by | to get variable path and filters
        const pipe_pos = std.mem.indexOfScalar(u8, input, '|');
        
        const var_path_str = if (pipe_pos) |pos|
            std.mem.trim(u8, input[0..pos], " \t\n")
        else
            std.mem.trim(u8, input, " \t\n");
        
        // Parse variable path (e.g., ".user.name" -> ["user", "name"])
        const path = try parseVariablePath(var_path_str);
        
        // Parse filters if present
        var filters: []const ast.TemplateAST.Filter = &[_]ast.TemplateAST.Filter{};
        if (pipe_pos) |pos| {
            const filter_str = std.mem.trim(u8, input[pos + 1..], " \t\n");
            filters = try parseFilters(filter_str);
        }
        
        return ast.TemplateAST.VariableNode{
            .path = path,
            .filters = filters,
        };
    }
    
    /// Parse variable path (e.g., ".user.name" -> ["user", "name"], "../parent.field" -> ["..", "parent", "field"])
    fn parseVariablePath(comptime path_str: []const u8) ![]const []const u8 {
        if (path_str.len == 0) {
            return error.InvalidVariableSyntax;
        }
        
        // Check for parent navigation syntax (../)
        if (std.mem.startsWith(u8, path_str, "../")) {
            // Handle parent navigation
            const remaining = path_str[3..]; // Skip "../"
            if (remaining.len == 0) {
                // Just "../" - return parent marker
                return &[_][]const u8{".."};
            }
            
            // Must start with . after ../
            if (remaining[0] != '.') {
                return error.InvalidVariableSyntax;
            }
            
            // Parse the rest as normal path
            const rest_path = try parseVariablePath(remaining);
            
            // Prepend parent marker
            var parts: []const []const u8 = &[_][]const u8{".."};
            for (rest_path) |part| {
                parts = parts ++ &[_][]const u8{part};
            }
            return parts;
        }
        
        // Must start with .
        if (path_str[0] != '.') {
            return error.InvalidVariableSyntax;
        }
        
        if (path_str.len == 1) {
            // Just "." - root context
            return &[_][]const u8{};
        }
        
        // Split by dots
        var parts: []const []const u8 = &[_][]const u8{};
        var i: usize = 1; // Skip leading dot
        var start: usize = 1;
        
        while (i < path_str.len) {
            if (path_str[i] == '.') {
                if (start < i) {
                    parts = parts ++ &[_][]const u8{path_str[start..i]};
                }
                start = i + 1;
            }
            i += 1;
        }
        
        // Add final part
        if (start < path_str.len) {
            parts = parts ++ &[_][]const u8{path_str[start..]};
        }
        
        return parts;
    }
    
    /// Parse filter pipeline (e.g., "uppercase | trim")
    fn parseFilters(comptime filter_str: []const u8) ![]const ast.TemplateAST.Filter {
        var filters: []const ast.TemplateAST.Filter = &[_]ast.TemplateAST.Filter{};
        var i: usize = 0;
        var start: usize = 0;
        
        while (i < filter_str.len) {
            if (filter_str[i] == '|') {
                const filter_name = std.mem.trim(u8, filter_str[start..i], " \t\n");
                if (filter_name.len > 0) {
                    filters = filters ++ &[_]ast.TemplateAST.Filter{.{
                        .name = filter_name,
                        .args = &[_][]const u8{},
                    }};
                }
                start = i + 1;
            }
            i += 1;
        }
        
        // Add final filter
        const final_filter = std.mem.trim(u8, filter_str[start..], " \t\n");
        if (final_filter.len > 0) {
            filters = filters ++ &[_]ast.TemplateAST.Filter{.{
                .name = final_filter,
                .args = &[_][]const u8{},
            }};
        }
        
        return filters;
    }
    
    /// Parse include statement
    fn parseInclude(comptime block_content: []const u8) !ast.TemplateAST.IncludeNode {
        // Extract file path from "include \"path.zt.html\""
        const trimmed = std.mem.trim(u8, block_content, " \t\n");
        if (!std.mem.startsWith(u8, trimmed, "include")) {
            return error.InvalidIncludePath;
        }
        
        const after_include = std.mem.trim(u8, trimmed[7..], " \t\n");
        
        // Find quoted string
        const quote_start = std.mem.indexOfScalar(u8, after_include, '"') orelse {
            return error.InvalidIncludePath;
        };
        const quote_end = std.mem.indexOfScalar(u8, after_include[quote_start + 1..], '"') orelse {
            return error.InvalidIncludePath;
        };
        
        const file_path = after_include[quote_start + 1..quote_start + 1 + quote_end];
        
        // Validate path (no ..)
        if (std.mem.indexOf(u8, file_path, "..") != null) {
            return error.InvalidIncludePath;
        }
        
        return ast.TemplateAST.IncludeNode{
            .file_path = file_path,
        };
    }
};

// Tests
test "parse simple text" {
    const ast_result = try Parser.parse("Hello World");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqual(ast_result.nodes[0], .text);
    try std.testing.expectEqualStrings(ast_result.nodes[0].text, "Hello World");
}

test "parse variable" {
    const ast_result = try Parser.parse("Hello {{ .name }}");
    try std.testing.expectEqual(ast_result.nodes.len, 3);
    try std.testing.expectEqualStrings(ast_result.nodes[0].text, "Hello ");
    try std.testing.expectEqual(ast_result.nodes[1], .variable);
    try std.testing.expectEqualStrings(ast_result.nodes[2].text, " ");
}

test "parse nested variable path" {
    const ast_result = try Parser.parse("{{ .user.name }}");
    try std.testing.expectEqual(ast_result.nodes[0], .variable);
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.path.len, 2);
    try std.testing.expectEqualStrings(var_node.path[0], "user");
    try std.testing.expectEqualStrings(var_node.path[1], "name");
}

test "parse raw variable" {
    const ast_result = try Parser.parse("{{! .html }}");
    try std.testing.expectEqual(ast_result.nodes[0], .raw_variable);
}

test "parse filter" {
    const ast_result = try Parser.parse("{{ .name | uppercase }}");
    try std.testing.expectEqual(ast_result.nodes[0], .variable);
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.filters.len, 1);
    try std.testing.expectEqualStrings(var_node.filters[0].name, "uppercase");
}

test "parse if block" {
    const ast_result = try Parser.parse("{% if .condition %}Yes{% endif %}");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqual(ast_result.nodes[0], .if_block);
}

test "parse for block" {
    const ast_result = try Parser.parse("{% for .items |item| %}{{ item }}{% endfor %}");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqual(ast_result.nodes[0], .for_block);
}
