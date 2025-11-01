const std = @import("std");

/// Abstract Syntax Tree for templates
/// All nodes are known at comptime after parsing
pub const TemplateAST = struct {
    nodes: []const Node,
    
    pub const Node = union(enum) {
        text: []const u8,
        variable: VariableNode,
        raw_variable: VariableNode,  // {{! ... }}
        if_block: IfBlock,
        for_block: ForBlock,
        include: IncludeNode,
    };
    
    pub const VariableNode = struct {
        path: []const []const u8,  // ["user", "name"] for .user.name
        filters: []const Filter,
    };
    
    pub const IfBlock = struct {
        condition: VariableNode,
        true_block: TemplateAST,
        false_block: ?TemplateAST,
    };
    
    pub const ForBlock = struct {
        collection_path: []const []const u8,  // ["todos"]
        item_name: []const u8,  // "item"
        block: TemplateAST,
    };
    
    pub const IncludeNode = struct {
        file_path: []const u8,
    };
    
    pub const Filter = struct {
        name: []const u8,
        args: []const []const u8,
    };
    
    pub fn init(comptime nodes: []const Node) TemplateAST {
        return TemplateAST{ .nodes = nodes };
    }
    
    pub fn empty() TemplateAST {
        return TemplateAST{ .nodes = &[_]Node{} };
    }
};

/// Parse error types
pub const ParseError = error{
    UnexpectedEndOfInput,
    InvalidVariableSyntax,
    InvalidIfSyntax,
    InvalidForSyntax,
    UnclosedBlock,
    InvalidIncludePath,
    InvalidFilterSyntax,
};

