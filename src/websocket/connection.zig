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

    /// Flag to prevent double cleanup
    cleaned_up: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
    /// Duplicates both key and value to ensure they persist
    pub fn set(self: *WebSocketConnection, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.context.put(key_copy, value_copy);
    }

    /// Cleanup connection resources
    pub fn cleanup(self: *WebSocketConnection) void {
        // Prevent double cleanup
        const already_cleaned = self.cleaned_up.swap(true, .monotonic);
        if (already_cleaned) {
            return; // Already cleaned up
        }

        // Free context entries - collect keys first to avoid iterator invalidation
        var context_keys = std.ArrayListUnmanaged([]const u8){};
        defer context_keys.deinit(self.allocator);

        var it = self.context.iterator();
        while (it.next()) |entry| {
            context_keys.append(self.allocator, entry.key_ptr.*) catch continue;
        }

        // Now free each entry
        for (context_keys.items) |key| {
            if (self.context.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
        }
        self.context.deinit();

        // Free headers - collect keys first
        var header_keys = std.ArrayListUnmanaged([]const u8){};
        defer header_keys.deinit(self.allocator);

        var header_it = self.headers.iterator();
        while (header_it.next()) |entry| {
            header_keys.append(self.allocator, entry.key_ptr.*) catch continue;
        }

        // Now free each entry
        for (header_keys.items) |key| {
            if (self.headers.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
        }
        self.headers.deinit();

        // Free id and path
        self.allocator.free(self.id);
        self.allocator.free(self.path);
    }
};
