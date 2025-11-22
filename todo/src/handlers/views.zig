const std = @import("std");
const E12 = @import("engine12");
const Request = E12.Request;
const Response = E12.Response;
const database = @import("../database.zig");
const getGlobalTemplate = database.getGlobalTemplate;

const allocator = std.heap.page_allocator;

/// Handle index page (root route)
pub fn handleIndex(request: *Request) Response {
    _ = request;

    // Use runtime template for hot reloading (development mode)
    // Template content is automatically reloaded when file changes
    const template = getGlobalTemplate() orelse {
        return Response.text("Template not loaded").withStatus(500);
    };

    // Define context type
    const IndexContext = struct {
        title: []const u8,
        subtitle: []const u8,
        title_placeholder: []const u8,
        description_placeholder: []const u8,
        add_button_text: []const u8,
        filter_all: []const u8,
        filter_pending: []const u8,
        filter_completed: []const u8,
        empty_state_message: []const u8,
    };

    // Create context
    const context = IndexContext{
        .title = "Todo List",
        .subtitle = "Enter your todos here",
        .title_placeholder = "Enter todo title...",
        .description_placeholder = "Enter description (optional)...",
        .add_button_text = "Add Todo",
        .filter_all = "All",
        .filter_pending = "Pending",
        .filter_completed = "Completed",
        .empty_state_message = "No todos yet. Add one above to get started!",
    };

    // Render template using runtime renderer (supports hot reloading)
    // Template automatically reloads if file changes
    const html = template.render(IndexContext, context, allocator) catch {
        return Response.text("Internal server error: template rendering failed").withStatus(500);
    };

    return Response.html(html)
        .withHeader("Cache-Control", "no-cache, no-store, must-revalidate")
        .withHeader("Pragma", "no-cache")
        .withHeader("Expires", "0");
}

