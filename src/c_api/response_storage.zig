const std = @import("std");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

const allocator = std.heap.page_allocator;

// Global storage for C API responses
// Uses request pointer as key for thread-safe access
var c_api_response_storage: std.AutoHashMap(*Request, Response) = undefined;
var c_api_response_storage_init = false;
var c_api_storage_mutex: std.Thread.Mutex = std.Thread.Mutex{};

fn initResponseStorage() void {
    if (!c_api_response_storage_init) {
        c_api_response_storage = std.AutoHashMap(*Request, Response).init(allocator);
        c_api_response_storage_init = true;
    }
}

/// Store a C API response for a request
pub fn storeCAPIResponse(req: *Request, resp: Response) !void {
    initResponseStorage();
    c_api_storage_mutex.lock();
    defer c_api_storage_mutex.unlock();
    
    try c_api_response_storage.put(req, resp);
}

/// Get stored C API response for a request (called by middleware chain)
pub fn getCAPIResponse(req: *Request) ?Response {
    initResponseStorage();
    c_api_storage_mutex.lock();
    defer c_api_storage_mutex.unlock();
    
    if (c_api_response_storage.fetchRemove(req)) |entry| {
        return entry.value;
    }
    return null;
}

