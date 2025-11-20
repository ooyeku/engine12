const std = @import("std");
const ws = @import("websocket");
const json = @import("../json.zig");

/// WebSocket connection wrapper for Engine12
/// Provides a clean API that wraps websocket.zig's Conn type
pub const WebSocketConnection = struct {
    /// Underlying websocket.zig connection
    conn: *ws.Conn,
    
    /// Connection metadata
    id: []const u8,
    path: []const u8,
    headers: std.StringHashMap([]const u8),
    
    /// Connection state
    is_open: std.atomic.Value(bool),
    
    /// Context storage (like Request.context)
    context: std.StringHashMap([]const u8),
    
    /// Allocator for this connection
    allocator: std.mem.Allocator,
    
    /// Send a text message
    /// websocket.zig expects []u8, not []const u8, so we need to duplicate
    pub fn sendText(self: *WebSocketConnection, text: []const u8) !void {
        if (!self.is_open.load(.monotonic)) {
            return error.ConnectionClosed;
        }
        
        // websocket.zig expects mutable buffer for masking
        const mutable = try self.allocator.dupe(u8, text);
        defer self.allocator.free(mutable);
        
        try self.conn.write(mutable);
    }
    
    /// Send a binary message
    pub fn sendBinary(self: *WebSocketConnection, data: []const u8) !void {
        if (!self.is_open.load(.monotonic)) {
            return error.ConnectionClosed;
        }
        
        const mutable = try self.allocator.dupe(u8, data);
        defer self.allocator.free(mutable);
        
        try self.conn.writeBin(mutable);
    }
    
    /// Send a JSON message (serializes struct to JSON)
    pub fn sendJson(self: *WebSocketConnection, comptime T: type, value: T) !void {
        const json_str = try json.Json.serialize(T, value, self.allocator);
        defer self.allocator.free(json_str);
        try self.sendText(json_str);
    }
    
    /// Close the connection gracefully
    pub fn close(self: *WebSocketConnection, code: ?u16, reason: ?[]const u8) !void {
        self.is_open.store(false, .monotonic);
        
        if (code) |c| {
            const close_reason = reason orelse "";
            try self.conn.close(.{ .code = c, .reason = close_reason });
        } else {
            try self.conn.close(.{});
        }
    }
    
    /// Get value from context
    pub fn get(self: *const WebSocketConnection, key: []const u8) ?[]const u8 {
        return self.context.get(key);
    }
    
    /// Set value in context
    pub fn set(self: *WebSocketConnection, key: []const u8, value: []const u8) !void {
        try self.context.put(key, value);
    }
    
    /// Cleanup connection resources
    pub fn cleanup(self: *WebSocketConnection) void {
        // Free context entries
        var it = self.context.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.context.deinit();
        
        // Free headers
        var header_it = self.headers.iterator();
        while (header_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
        
        // Free id and path
        self.allocator.free(self.id);
        self.allocator.free(self.path);
    }
};

