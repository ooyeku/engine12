// WebSocket module for engine12
// Provides WebSocket support using karlseguin/websocket.zig

pub const connection = @import("connection.zig");
pub const handler = @import("handler.zig");
pub const manager = @import("manager.zig");
pub const room = @import("room.zig");

// Re-export main types for convenience
pub const WebSocketConnection = connection.WebSocketConnection;
pub const WebSocketHandler = handler.WebSocketHandler;
pub const WebSocketManager = manager.WebSocketManager;
pub const WebSocketRoom = room.WebSocketRoom;
pub const WebSocketServerEntry = manager.WebSocketServerEntry;

