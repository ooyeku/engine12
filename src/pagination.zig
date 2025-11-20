const std = @import("std");
const Request = @import("request.zig").Request;

/// Pagination metadata for JSON responses
pub const PaginationMeta = struct {
    page: u32,
    limit: u32,
    total: u32,
    total_pages: u32,
};

/// Pagination helper for parsing and generating pagination info
pub const Pagination = struct {
    page: u32,
    limit: u32,
    offset: u32,
    
    /// Create pagination from request query parameters
    /// Defaults: page=1, limit=20
    /// Validates: page >= 1, limit between 1 and 100
    /// 
    /// Example:
    /// ```zig
    /// const pagination = Pagination.fromRequest(request);
    /// const todos = try orm.findAllWithLimit(Todo, pagination.limit, pagination.offset);
    /// ```
    pub fn fromRequest(req: *Request) !Pagination {
        const page = (req.queryParamTyped(u32, "page") catch null) orelse 1;
        const limit = (req.queryParamTyped(u32, "limit") catch null) orelse 20;
        
        // Validate page
        if (page < 1) {
            return error.InvalidArgument;
        }
        
        // Validate limit (between 1 and 100)
        if (limit < 1 or limit > 100) {
            return error.InvalidArgument;
        }
        
        const offset = (page - 1) * limit;
        
        return Pagination{
            .page = page,
            .limit = limit,
            .offset = offset,
        };
    }
    
    /// Generate pagination metadata for JSON responses
    /// 
    /// Example:
    /// ```zig
    /// const pagination = Pagination.fromRequest(request);
    /// const todos = try orm.findAllWithLimit(Todo, pagination.limit, pagination.offset);
    /// const total = try orm.count(Todo);
    /// const meta = pagination.toResponse(total);
    /// return Response.jsonFrom(PaginatedResponse(Todo){ .data = todos, .meta = meta }, allocator);
    /// ```
    pub fn toResponse(self: Pagination, total: u32) PaginationMeta {
        const total_pages = if (total == 0) 0 else ((total - 1) / self.limit) + 1;
        
        return PaginationMeta{
            .page = self.page,
            .limit = self.limit,
            .total = total,
            .total_pages = total_pages,
        };
    }
};

// Tests
test "Pagination fromRequest with defaults" {
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/api/todos",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const pagination = try Pagination.fromRequest(&req);
    try std.testing.expectEqual(pagination.page, 1);
    try std.testing.expectEqual(pagination.limit, 20);
    try std.testing.expectEqual(pagination.offset, 0);
}

test "Pagination fromRequest with query params" {
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/api/todos?page=3&limit=10",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const pagination = try Pagination.fromRequest(&req);
    try std.testing.expectEqual(pagination.page, 3);
    try std.testing.expectEqual(pagination.limit, 10);
    try std.testing.expectEqual(pagination.offset, 20);
}

test "Pagination fromRequest invalid page" {
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/api/todos?page=0",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    try std.testing.expectError(error.InvalidArgument, Pagination.fromRequest(&req));
}

test "Pagination fromRequest invalid limit" {
    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/api/todos?limit=0",
        .method = .GET,
        .body = "",
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    try std.testing.expectError(error.InvalidArgument, Pagination.fromRequest(&req));
}

test "Pagination toResponse" {
    const pagination = Pagination{
        .page = 2,
        .limit = 10,
        .offset = 10,
    };
    
    const meta = pagination.toResponse(25);
    try std.testing.expectEqual(meta.page, 2);
    try std.testing.expectEqual(meta.limit, 10);
    try std.testing.expectEqual(meta.total, 25);
    try std.testing.expectEqual(meta.total_pages, 3);
}

test "Pagination toResponse with zero total" {
    const pagination = Pagination{
        .page = 1,
        .limit = 10,
        .offset = 0,
    };
    
    const meta = pagination.toResponse(0);
    try std.testing.expectEqual(meta.total, 0);
    try std.testing.expectEqual(meta.total_pages, 0);
}

