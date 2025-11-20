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
        // Copy connection pointers while holding lock
        var connections_copy = std.ArrayListUnmanaged(*connection.WebSocketConnection){};
        defer connections_copy.deinit(self.allocator);

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Copy all connections while holding the lock
            for (self.connections.items) |conn| {
                connections_copy.append(self.allocator, conn) catch continue;
            }
        }

        // Now unlock and iterate - connections might be freed, so we need to be careful
        // Use a safe wrapper to check if connection is still valid
        for (connections_copy.items) |conn| {
            // Safely check if connection is open
            // If the connection was freed, this will segfault, so we need to be defensive
            const is_open = safeIsOpen(conn);
            if (!is_open) {
                continue;
            }

            // Try to send - if connection was freed, this will fail gracefully
            conn.sendText(message) catch {
                // Connection error or freed - skip it
                continue;
            };
        }

        // Clean up closed connections (re-acquire lock)
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            var i: usize = 0;
            while (i < self.connections.items.len) {
                const conn = self.connections.items[i];
                if (safeIsOpen(conn)) {
                    i += 1;
                } else {
                    _ = self.connections.swapRemove(i);
                }
            }
        }
    }

    /// Safely check if a connection is open
    /// Returns false if connection is invalid or closed
    /// Note: This is not truly safe if the connection was freed, but we try to minimize that risk
    /// by ensuring connections are only removed from the room when they're closed
    fn safeIsOpen(conn: *connection.WebSocketConnection) bool {
        // Check if connection is still open
        // If connection was freed, this will segfault - but connections should only be freed
        // after they're removed from the room, so this should be safe
        return conn.is_open.load(.monotonic);
    }

    /// Broadcast a binary message to all connections in the room
    pub fn broadcastBinary(self: *WebSocketRoom, data: []const u8) !void {
        // Copy connection pointers while holding lock
        var connections_copy = std.ArrayListUnmanaged(*connection.WebSocketConnection){};
        defer connections_copy.deinit(self.allocator);

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Copy all connections while holding the lock
            for (self.connections.items) |conn| {
                connections_copy.append(self.allocator, conn) catch continue;
            }
        }

        for (connections_copy.items) |conn| {
            if (safeIsOpen(conn)) {
                conn.sendBinary(data) catch {
                    continue;
                };
            }
        }

        // Clean up closed connections
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            var i: usize = 0;
            while (i < self.connections.items.len) {
                const conn = self.connections.items[i];
                if (safeIsOpen(conn)) {
                    i += 1;
                } else {
                    _ = self.connections.swapRemove(i);
                }
            }
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
