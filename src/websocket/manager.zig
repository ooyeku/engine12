const std = @import("std");
const ws = @import("websocket");
const vigil = @import("vigil");
const handler = @import("handler.zig");
const connection = @import("connection.zig");

/// WebSocket server entry
pub const WebSocketServerEntry = struct {
    path: []const u8,
    port: u16,
    handler: handler.WebSocketHandler,
};

/// WebSocket manager that supervises multiple WebSocket servers
pub const WebSocketManager = struct {
    /// Active server entries
    servers: std.ArrayListUnmanaged(WebSocketServerEntry),
    
    /// Connection registry (optional - for tracking connections)
    connections: std.StringHashMap(*connection.WebSocketConnection),
    connections_mutex: std.Thread.Mutex = .{},
    
    /// Allocator
    allocator: std.mem.Allocator,
    
    /// Base port for WebSocket servers
    base_port: u16 = 9000,
    
    /// Next available port
    next_port: u16 = 9000,
    
    /// Built supervisor (stored after build)
    built_supervisor: ?*anyopaque = null,
    
    /// Initialize WebSocket manager
    pub fn init(allocator: std.mem.Allocator) !WebSocketManager {
        return WebSocketManager{
            .servers = .{},
            .connections = std.StringHashMap(*connection.WebSocketConnection).init(allocator),
            .allocator = allocator,
            .base_port = 9000,
            .next_port = 9000,
            .built_supervisor = null,
        };
    }
    
    /// Start a WebSocket server for a route
    /// This creates the server but doesn't start it yet
    pub fn registerServer(
        self: *WebSocketManager,
        path: []const u8,
        handler_fn: handler.WebSocketHandler,
    ) !void {
        const port = self.next_port;
        self.next_port += 1;
        
        // Store server entry (server will be started in start())
        try self.servers.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .port = port,
            .handler = handler_fn,
        });
    }
    
    /// Start the supervisor and all registered servers
    /// Call this after all servers are registered
    pub fn start(self: *WebSocketManager) !void {
        var supervisor = vigil.supervisor(self.allocator);
        
        // Start each registered server
        for (self.servers.items) |entry| {
            // Create handler type for this server
            const HandlerType = handler.createEngine12Handler(@TypeOf(entry.handler));
            
            // Create app data
            const AppData = handler.createAppData(@TypeOf(entry.handler));
            const app_data = AppData{
                .handler = entry.handler,
                .allocator = self.allocator,
                .path = entry.path,
            };
            
            // Create websocket.zig server
            const server = try ws.Server(HandlerType).init(self.allocator, .{
                .port = entry.port,
                .address = "127.0.0.1",
                .handshake = .{
                    .timeout = 3,
                    .max_size = 1024,
                    .max_headers = 32,
                },
            });
            
            // Spawn thread for this server (like engine12 does for HTTP server)
            // We'll use a thread spawn approach since we need to capture server and app_data
            const ServerThread = struct {
                server_ptr: *ws.Server(HandlerType),
                app_data: AppData,
                
                fn run(ctx: @This()) void {
                    var mutable_app_data = ctx.app_data;
                    ctx.server_ptr.listen(&mutable_app_data) catch |err| {
                        std.debug.print("[WebSocket] Server error: {}\n", .{err});
                    };
                }
            };
            
            // Allocate server on heap so it persists
            const server_ptr = try self.allocator.create(ws.Server(HandlerType));
            server_ptr.* = server;
            
            const server_thread = ServerThread{
                .server_ptr = server_ptr,
                .app_data = app_data,
            };
            
            // Spawn thread
            var thread = try std.Thread.spawn(.{}, ServerThread.run, .{server_thread});
            thread.detach();
            
            // Also register with vigil for supervision (using a no-op task since thread handles it)
            const server_name = try std.fmt.allocPrint(
                self.allocator,
                "ws_server_{s}",
                .{entry.path}
            );
            defer self.allocator.free(server_name);
            
            // Register a no-op task with vigil (thread handles actual work)
            const noop_task = struct {
                fn task() void {
                    // Thread handles the actual server
                }
            }.task;
            
            _ = supervisor.child(server_name, noop_task) catch |err| {
                std.debug.print("[ERROR] Failed to register WebSocket server '{s}': {any}\n", .{ server_name, err });
            };
        }
        
        // Build and start supervisor
        var sup = supervisor.build();
        self.built_supervisor = @ptrCast(&sup);
        try sup.start();
    }
    
    /// Stop all servers gracefully
    pub fn stop(self: *WebSocketManager) void {
        // Vigil will handle graceful shutdown
        // Clean up server entries
        for (self.servers.items) |entry| {
            self.allocator.free(entry.path);
        }
        self.servers.deinit(self.allocator);
        
        // Clean up connections
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();
        
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.cleanup();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.connections.deinit();
    }
    
    /// Register a connection (for tracking)
    pub fn registerConnection(
        self: *WebSocketManager,
        conn_id: []const u8,
        conn: *connection.WebSocketConnection,
    ) !void {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();
        
        try self.connections.put(conn_id, conn);
    }
    
    /// Remove a connection
    pub fn removeConnection(self: *WebSocketManager, conn_id: []const u8) void {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();
        
        _ = self.connections.remove(conn_id);
    }
    
    /// Get connection by ID
    pub fn getConnection(
        self: *WebSocketManager,
        conn_id: []const u8,
    ) ?*connection.WebSocketConnection {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();
        
        return self.connections.get(conn_id);
    }
};

