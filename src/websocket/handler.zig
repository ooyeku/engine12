const std = @import("std");
const ws = @import("websocket");
const connection = @import("connection.zig");
const WebSocketConnection = connection.WebSocketConnection;
const websocket_mod = @import("module.zig");

/// WebSocket handler function type for engine12
pub const WebSocketHandler = *const fn (*WebSocketConnection) void;

/// App data type passed to websocket.zig Server.listen()
pub fn createAppData(
    comptime HandlerFn: type,
) type {
    return struct {
        handler: HandlerFn,
        allocator: std.mem.Allocator,
        path: []const u8,
    };
}

/// Internal handler that bridges websocket.zig to engine12
/// This implements websocket.zig's Handler interface
pub fn createEngine12Handler(
    comptime HandlerFn: type,
) type {
    const AppData = createAppData(HandlerFn);

    return struct {
        const Self = @This();

        /// engine12 connection wrapper
        engine12_conn: ?*WebSocketConnection = null,
        /// Connection ID (generated per connection)
        conn_id: []const u8 = undefined,
        /// Path this connection is on
        path: []const u8 = undefined,
        /// Allocator
        allocator: std.mem.Allocator = undefined,
        /// Handler function
        handler: HandlerFn = undefined,

        /// websocket.zig Handler.init - called during handshake
        pub fn init(
            h: *ws.Handshake,
            conn: *ws.Conn,
            app: *AppData,
        ) !Self {
            // Generate unique connection ID
            const timestamp = std.time.milliTimestamp();
            const random = @as(u64, @intCast(std.time.nanoTimestamp())) % 1000000;
            const conn_id = try std.fmt.allocPrint(app.allocator, "ws_{d}_{d}", .{ timestamp, random });

            // Use path from app data (set when server is created)
            const path = app.path;

            // Create engine12 connection wrapper
            const engine12_conn = try app.allocator.create(WebSocketConnection);
            errdefer app.allocator.destroy(engine12_conn);

            engine12_conn.* = WebSocketConnection{
                .conn = conn,
                .id = conn_id,
                .path = try app.allocator.dupe(u8, path),
                .headers = std.StringHashMap([]const u8).init(app.allocator),
                .is_open = std.atomic.Value(bool).init(true),
                .context = std.StringHashMap([]const u8).init(app.allocator),
                .allocator = app.allocator,
                .cleaned_up = std.atomic.Value(bool).init(false),
            };

            // Copy headers from handshake if available
            // websocket.zig provides headers via h.headers.get() or iteration
            // Check if headers are available by trying to access them
            if (@hasField(@TypeOf(h.*), "headers")) {
                if (@TypeOf(h.headers) != @TypeOf(null)) {
                    // Headers are available - iterate if possible
                    // Note: websocket.zig headers API may vary, so we'll access via get() when needed
                    // For now, we'll skip bulk copying and let users access via handshake if needed
                }
            }

            return Self{
                .engine12_conn = engine12_conn,
                .conn_id = conn_id,
                .path = try app.allocator.dupe(u8, path),
                .allocator = app.allocator,
                .handler = app.handler,
            };
        }

        /// websocket.zig Handler.afterInit - called after handshake
        pub fn afterInit(self: *Self) !void {
            if (self.engine12_conn) |conn| {
                // Call the engine12 handler function
                // This gives users a chance to set up the connection
                // They can store the connection and implement custom message handling
                self.handler(conn);
            }
        }

        /// websocket.zig Handler.clientMessage - called on message
        /// This is called automatically by websocket.zig when messages arrive
        /// By default, this does nothing - users should implement message handling
        /// in their handler function by storing the connection and setting up their own logic
        pub fn clientMessage(self: *Self, data: []u8) !void {
            // Default: do nothing with messages
            // Users should implement custom message handling in their handler function
            // by storing the connection and setting up their own message processing
            _ = self;
            _ = data;
        }

        /// websocket.zig Handler.close - called on close
        pub fn close(self: *Self) void {
            if (self.engine12_conn) |conn| {
                conn.is_open.store(false, .monotonic);

                // Remove connection from room if it's in one (for hot reload)
                // Get room reference BEFORE cleanup (since get() accesses context)
                var room_ptr: ?*websocket_mod.room.WebSocketRoom = null;
                if (conn.get("hot_reload_room")) |room_ptr_str| {
                    // Copy the string since cleanup will free the context
                    const room_ptr_str_copy = self.allocator.dupe(u8, room_ptr_str) catch null;
                    defer if (room_ptr_str_copy) |str| self.allocator.free(str);

                    if (room_ptr_str_copy) |str| {
                        const room_ptr_int = std.fmt.parseInt(usize, str, 10) catch 0;
                        if (room_ptr_int != 0) {
                            room_ptr = @as(*websocket_mod.room.WebSocketRoom, @ptrFromInt(room_ptr_int));
                        }
                    }
                }

                // Now cleanup the connection (this will free the context)
                conn.cleanup();

                // Remove from room after cleanup (room.leave doesn't access connection internals)
                if (room_ptr) |room| {
                    room.leave(conn);
                }

                self.allocator.destroy(conn);
            }

            // Free path (conn_id is already freed by conn.cleanup())
            self.allocator.free(self.path);
        }
    };
}
