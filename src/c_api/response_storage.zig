const std = @import("std");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

const allocator = std.heap.page_allocator;

// Global storage for C API responses
// Uses request ID as key for thread-safe access and automatic cleanup
// Responses are automatically removed when retrieved (fetchRemove) to prevent leaks
var c_api_response_storage: std.StringHashMap(Response) = undefined;
var c_api_response_storage_init = false;
var c_api_storage_mutex: std.Thread.Mutex = std.Thread.Mutex{};

fn initResponseStorage() void {
    if (!c_api_response_storage_init) {
        c_api_response_storage = std.StringHashMap(Response).init(allocator);
        c_api_response_storage_init = true;
    }
}

/// Store a C API response for a request
/// Uses request ID as key to enable automatic cleanup
pub fn storeCAPIResponse(req: *Request, resp: Response) !void {
    initResponseStorage();
    c_api_storage_mutex.lock();
    defer c_api_storage_mutex.unlock();

    // Use request ID as key instead of pointer for better cleanup
    const request_id = req.requestId() orelse {
        // Fallback to pointer address if no request ID (shouldn't happen)
        var buffer: [32]u8 = undefined;
        const ptr_str = std.fmt.bufPrint(&buffer, "{d}", .{@intFromPtr(req)}) catch return error.OutOfMemory;
        try c_api_response_storage.put(ptr_str, resp);
        return;
    };

    // Request ID is allocated in request arena, so we need to duplicate it
    const id_copy = try allocator.dupe(u8, request_id);
    errdefer allocator.free(id_copy);

    try c_api_response_storage.put(id_copy, resp);
}

/// Get stored C API response for a request (called by middleware chain)
/// Automatically removes the response from storage to prevent memory leaks
pub fn getCAPIResponse(req: *Request) ?Response {
    initResponseStorage();
    c_api_storage_mutex.lock();
    defer c_api_storage_mutex.unlock();

    const request_id = req.requestId() orelse {
        // Fallback to pointer address if no request ID
        var buffer: [32]u8 = undefined;
        const ptr_str = std.fmt.bufPrint(&buffer, "{d}", .{@intFromPtr(req)}) catch return null;
        if (c_api_response_storage.fetchRemove(ptr_str)) |entry| {
            // No key to free for stack-allocated buffer
            return entry.value;
        }
        return null;
    };

    if (c_api_response_storage.fetchRemove(request_id)) |entry| {
        // Free the duplicated key
        allocator.free(entry.key);
        return entry.value;
    }
    return null;
}

