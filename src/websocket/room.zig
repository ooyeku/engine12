const std = @import("std");
const connection = @import("connection.zig");
const WebSocketConnection = connection.WebSocketConnection;

/// WebSocket room for broadcasting to groups of connections
pub const WebSocketRoom = struct {
    /// Room name
    name: []const u8,
    
    /// Connections in this room
    connections: std.ArrayListUnmanaged(*WebSocketConnection),
    
    /// Mutex for thread-safe access
    mutex: std.Thread.Mutex = .{},
    
    /// Allocator
    allocator: std.mem.Allocator,
    
    /// Initialize a new room
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !WebSocketRoom {
        return WebSocketRoom{
            .name = try allocator.dupe(u8, name),
            .connections = .{},
            .allocator = allocator,
        };
    }
    
    /// Deinitialize room
    pub fn deinit(self: *WebSocketRoom) void {
        self.allocator.free(self.name);
        self.connections.deinit(self.allocator);
    }
    
    /// Broadcast a text message to all connections in the room
    pub fn broadcast(self: *WebSocketRoom, message: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var closed_connections = std.ArrayListUnmanaged(usize){};
        defer closed_connections.deinit(self.allocator);
        
        for (self.connections.items, 0..) |conn, i| {
            if (conn.is_open.load(.monotonic)) {
                conn.sendText(message) catch |err| {
                    // Mark closed connections for removal
                    _ = err;
                    try closed_connections.append(self.allocator, i);
                };
            } else {
                try closed_connections.append(self.allocator, i);
            }
        }
        
        // Remove closed connections (in reverse order to maintain indices)
        std.mem.sort(usize, closed_connections.items, {}, comptime std.sort.desc(usize));
        for (closed_connections.items) |idx| {
            _ = self.connections.swapRemove(idx);
        }
    }
    
    /// Broadcast a binary message to all connections in the room
    pub fn broadcastBinary(self: *WebSocketRoom, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var closed_connections = std.ArrayListUnmanaged(usize){};
        defer closed_connections.deinit(self.allocator);
        
        for (self.connections.items, 0..) |conn, i| {
            if (conn.is_open.load(.monotonic)) {
                conn.sendBinary(data) catch |err| {
                    _ = err;
                    try closed_connections.append(self.allocator, i);
                };
            } else {
                try closed_connections.append(self.allocator, i);
            }
        }
        
        std.mem.sort(usize, closed_connections.items, {}, comptime std.sort.desc(usize));
        for (closed_connections.items) |idx| {
            _ = self.connections.swapRemove(idx);
        }
    }
    
    /// Broadcast a JSON message to all connections in the room
    pub fn broadcastJson(self: *WebSocketRoom, comptime T: type, value: T) !void {
        const json = @import("../json.zig");
        const json_str = try json.Json.serialize(T, value, self.allocator);
        defer self.allocator.free(json_str);
        
        try self.broadcast(json_str);
    }
    
    /// Add a connection to the room
    pub fn join(self: *WebSocketRoom, conn: *WebSocketConnection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.connections.append(self.allocator, conn);
    }
    
    /// Remove a connection from the room
    pub fn leave(self: *WebSocketRoom, conn: *WebSocketConnection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.connections.items, 0..) |c, i| {
            if (c == conn) {
                _ = self.connections.swapRemove(i);
                break;
            }
        }
    }
    
    /// Get the number of connections in the room
    pub fn count(self: *const WebSocketRoom) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.connections.items.len;
    }
    
    /// Check if room is empty
    pub fn isEmpty(self: *const WebSocketRoom) bool {
        return self.count() == 0;
    }
};

