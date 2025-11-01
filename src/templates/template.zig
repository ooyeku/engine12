const std = @import("std");
const ast = @import("ast.zig");
const escape = @import("escape.zig");
const type_checker = @import("type_checker.zig");
const codegen = @import("codegen.zig");

/// Template engine public API
/// Compiles templates at comptime and provides type-safe rendering
pub const Template = struct {
    /// Compile template from file path (uses @embedFile)
    pub fn compileFile(comptime file_path: []const u8) type {
        const content = @embedFile(file_path);
        return compile(content);
    }
    
    /// Compile template from string literal
    pub fn compile(comptime template_str: []const u8) type {
        const parsed_ast = comptime Parser.parse(template_str) catch |err| {
            @compileError("Template parse error: " ++ @errorName(err));
        };
        
        return struct {
            const template_ast = parsed_ast;
            
            /// Render template with context
            pub fn render(
                comptime Context: type,
                ctx: Context,
                allocator: std.mem.Allocator,
            ) ![]const u8 {
                comptime type_checker.TypeChecker.validateContext(template_ast, Context);
                const RenderFn = comptime codegen.Codegen.generateRenderFunction(template_ast, Context);
                return RenderFn.render(ctx, allocator);
            }
        };
    }
};

const Parser = @import("parser.zig").Parser;

/// Convenience function for rendering templates from files
pub fn renderFile(
    comptime file_path: []const u8,
    comptime Context: type,
    ctx: Context,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const TemplateType = Template.compileFile(file_path);
    return TemplateType.render(Context, ctx, allocator);
}

test "simple template rendering" {
    const TemplateType = Template.compile("<h1>{{ .title }}</h1>");
    const context = struct {
        title: []const u8,
    }{ .title = "Test" };
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings(html, "<h1>Test</h1>");
}

test "template with HTML escaping" {
    const TemplateType = Template.compile("<div>{{ .content }}</div>");
    const context = struct {
        content: []const u8,
    }{ .content = "<script>alert('xss')</script>" };
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;") != null);
}

test "template with nested variable" {
    const TemplateType = Template.compile("Hello {{ .user.name }}");
    const context = struct {
        user: struct {
            name: []const u8,
        },
    }{ .user = .{ .name = "Alice" } };
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings(html, "Hello Alice");
}

test "template with raw variable" {
    const TemplateType = Template.compile("{{! .html }}");
    const context = struct {
        html: []const u8,
    }{ .html = "<div>Hello</div>" };
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings(html, "<div>Hello</div>");
}

