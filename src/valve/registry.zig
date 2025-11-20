const std = @import("std");
const valve = @import("valve.zig");
const Valve = valve.Valve;
const ValveCapability = valve.ValveCapability;
const context = @import("context.zig");
const ValveContext = context.ValveContext;
const Engine12 = @import("../engine12.zig").Engine12;

/// Registry-specific errors
pub const RegistryError = error{
    TooManyValves,
};

/// Maximum number of valves that can be registered
pub const MAX_VALVES = 32;

/// Registry for managing valve registration and lifecycle
pub const ValveRegistry = struct {
    /// Registered valves
    valves: std.ArrayListUnmanaged(*Valve),
    /// Valve contexts (parallel array with valves)
    contexts: std.ArrayListUnmanaged(ValveContext),
    /// Error messages for valves (parallel array with valves)
    valve_errors: std.ArrayListUnmanaged([]const u8),
    /// Allocator for registry operations
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new valve registry
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .valves = std.ArrayListUnmanaged(*Valve){},
            .contexts = std.ArrayListUnmanaged(ValveContext){},
            .valve_errors = std.ArrayListUnmanaged([]const u8){},
            .allocator = allocator,
        };
    }

    /// Register a valve with an engine12 instance
    /// Creates a context with granted capabilities and calls valve.init()
    ///
    /// Example:
    /// ```zig
    /// var registry = ValveRegistry.init(allocator);
    /// try registry.register(&my_valve, &app);
    /// ```
    pub fn register(self: *Self, valve_ptr: *Valve, app: *Engine12) !void {
        // Check for duplicate registration
        for (self.valves.items) |existing| {
            if (std.mem.eql(u8, existing.metadata.name, valve_ptr.metadata.name)) {
                return error.ValveAlreadyRegistered;
            }
        }

        // Check max valves limit
        if (self.valves.items.len >= MAX_VALVES) {
            return RegistryError.TooManyValves;
        }

        // Create context with granted capabilities
        var capabilities = std.ArrayListUnmanaged(ValveCapability){};
        errdefer capabilities.deinit(self.allocator);

        // Grant all requested capabilities from metadata
        for (valve_ptr.metadata.required_capabilities) |cap| {
            try capabilities.append(self.allocator, cap);
        }

        var ctx = ValveContext{
            .app = app,
            .allocator = app.allocator,
            .capabilities = capabilities,
            .valve_name = valve_ptr.metadata.name,
            .state = .registered,
        };

        // Initialize valve
        valve_ptr.init(valve_ptr, &ctx) catch |err| {
            ctx.state = .failed;
            const err_msg = try std.fmt.allocPrint(self.allocator, "init: {s}", .{@errorName(err)});
            try self.valves.append(self.allocator, valve_ptr);
            try self.contexts.append(self.allocator, ctx);
            try self.valve_errors.append(self.allocator, err_msg);
            return err;
        };
        ctx.state = .initialized;

        // Store valve and context (no error)
        try self.valves.append(self.allocator, valve_ptr);
        try self.contexts.append(self.allocator, ctx);
        try self.valve_errors.append(self.allocator, "");
    }

    /// Unregister a valve by name
    /// Calls valve.deinit() and removes from registry
    ///
    /// Example:
    /// ```zig
    /// try registry.unregister("my_valve");
    /// ```
    pub fn unregister(self: *Self, name: []const u8) !void {
        var i: usize = 0;
        while (i < self.valves.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.valves.items[i].metadata.name, name)) {
                // Call deinit
                self.valves.items[i].deinit(self.valves.items[i]);

                // Remove from arrays
                _ = self.valves.swapRemove(i);
                var ctx = self.contexts.swapRemove(i);
                ctx.deinit();
                const err_msg = self.valve_errors.swapRemove(i);
                if (err_msg.len > 0) {
                    self.allocator.free(err_msg);
                }

                return;
            }
        }
        return valve.ValveError.ValveNotFound;
    }

    /// Get context for a valve by name
    /// Returns null if valve not found
    ///
    /// Example:
    /// ```zig
    /// if (registry.getContext("my_valve")) |ctx| {
    ///     try ctx.registerRoute("GET", "/test", handler);
    /// }
    /// ```
    pub fn getContext(self: *Self, name: []const u8) ?*ValveContext {
        var i: usize = 0;
        while (i < self.valves.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.valves.items[i].metadata.name, name)) {
                return &self.contexts.items[i];
            }
        }
        return null;
    }

    /// Get all registered valve names
    /// Returns a slice of valve names (allocated with provided allocator)
    pub fn getValveNames(self: *Self, allocator: std.mem.Allocator) ![]const []const u8 {
        var names = std.ArrayListUnmanaged([]const u8){};
        for (self.valves.items) |v| {
            try names.append(allocator, v.metadata.name);
        }
        return names.toOwnedSlice(allocator);
    }

    /// Call onAppStart for all registered valves
    /// Called by engine12 when app starts
    /// Collects errors and marks valves as failed if errors occur
    pub fn onAppStart(self: *Self) !void {
        var i: usize = 0;
        while (i < self.valves.items.len) : (i += 1) {
            // Skip valves that failed during initialization
            if (self.contexts.items[i].state == .failed) continue;

            if (self.valves.items[i].onAppStart) |callback| {
                callback(self.valves.items[i], &self.contexts.items[i]) catch |err| {
                    self.contexts.items[i].state = .failed;
                    // Free old error message if exists
                    if (self.valve_errors.items[i].len > 0) {
                        self.allocator.free(self.valve_errors.items[i]);
                    }
                    // Store new error message
                    const err_msg = std.fmt.allocPrint(self.allocator, "onAppStart: {s}", .{@errorName(err)}) catch {
                        self.valve_errors.items[i] = "onAppStart: unknown error";
                        std.debug.print("[Valve] Error in onAppStart for '{s}': {}\n", .{ self.valves.items[i].metadata.name, err });
                        continue;
                    };
                    self.valve_errors.items[i] = err_msg;
                    std.debug.print("[Valve] Error in onAppStart for '{s}': {}\n", .{ self.valves.items[i].metadata.name, err });
                    continue;
                };
                // Success - mark as started
                if (self.contexts.items[i].state == .initialized) {
                    self.contexts.items[i].state = .started;
                }
            } else {
                // No onAppStart callback - mark as started if initialized
                if (self.contexts.items[i].state == .initialized) {
                    self.contexts.items[i].state = .started;
                }
            }
        }
    }

    /// Call onAppStop for all registered valves
    /// Called by engine12 when app stops
    pub fn onAppStop(self: *Self) void {
        var i: usize = 0;
        while (i < self.valves.items.len) : (i += 1) {
            if (self.valves.items[i].onAppStop) |callback| {
                callback(self.valves.items[i], &self.contexts.items[i]);
            }
            // Mark as stopped
            if (self.contexts.items[i].state != .failed) {
                self.contexts.items[i].state = .stopped;
            }
        }
    }

    /// Cleanup all valves and deinitialize registry
    pub fn deinit(self: *Self) void {
        // Call deinit on all valves
        for (self.valves.items) |v| {
            v.deinit(v);
        }

        // Cleanup contexts
        for (self.contexts.items) |*ctx| {
            ctx.deinit();
        }

        // Cleanup error messages
        for (self.valve_errors.items) |err_msg| {
            if (err_msg.len > 0) {
                self.allocator.free(err_msg);
            }
        }

        self.valves.deinit(self.allocator);
        self.contexts.deinit(self.allocator);
        self.valve_errors.deinit(self.allocator);
    }

    /// Get the state of a valve by name
    pub fn getValveState(self: *Self, name: []const u8) ?valve.ValveState {
        var i: usize = 0;
        while (i < self.valves.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.valves.items[i].metadata.name, name)) {
                return self.contexts.items[i].state;
            }
        }
        return null;
    }

    /// Get error message for a valve by name
    /// Returns empty string if no error or valve not found
    pub fn getValveErrors(self: *Self, name: []const u8) []const u8 {
        var i: usize = 0;
        while (i < self.valves.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.valves.items[i].metadata.name, name)) {
                return self.valve_errors.items[i];
            }
        }
        return "";
    }

    /// Check if a valve is healthy (not failed)
    pub fn isValveHealthy(self: *Self, name: []const u8) bool {
        if (self.getValveState(name)) |state| {
            return state != .failed;
        }
        return false;
    }

    /// Get all failed valve names
    pub fn getFailedValves(self: *Self, allocator: std.mem.Allocator) ![]const []const u8 {
        var failed = std.ArrayListUnmanaged([]const u8){};
        var i: usize = 0;
        while (i < self.valves.items.len) : (i += 1) {
            if (self.contexts.items[i].state == .failed) {
                try failed.append(allocator, self.valves.items[i].metadata.name);
            }
        }
        return failed.toOwnedSlice(allocator);
    }
};

// Tests
test "ValveRegistry init" {
    var registry = ValveRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try std.testing.expectEqual(registry.valves.items.len, 0);
}

test "ValveRegistry register and unregister" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var registry = ValveRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const TestValve = struct {
        valve: Valve,
        init_called: bool = false,
        deinit_called: bool = false,

        pub fn initFn(v: *Valve, ctx: *ValveContext) !void {
            // Get parent struct using pointer arithmetic
            const Self = @This();
            const offset = @offsetOf(Self, "valve");
            const addr = @intFromPtr(v) - offset;
            const self = @as(*Self, @ptrFromInt(addr));
            self.init_called = true;
            _ = ctx;
        }

        pub fn deinitFn(v: *Valve) void {
            // Get parent struct using pointer arithmetic
            const Self = @This();
            const offset = @offsetOf(Self, "valve");
            const addr = @intFromPtr(v) - offset;
            const self = @as(*Self, @ptrFromInt(addr));
            self.deinit_called = true;
        }
    };

    var test_valve = TestValve{
        .valve = Valve{
            .metadata = valve.ValveMetadata{
                .name = "test",
                .version = "1.0.0",
                .description = "Test valve",
                .author = "Test",
                .required_capabilities = &[_]ValveCapability{},
            },
            .init = &TestValve.initFn,
            .deinit = &TestValve.deinitFn,
        },
    };

    try registry.register(&test_valve.valve, &app);
    try std.testing.expect(test_valve.init_called);
    try std.testing.expectEqual(registry.valves.items.len, 1);

    try registry.unregister("test");
    try std.testing.expect(test_valve.deinit_called);
    try std.testing.expectEqual(registry.valves.items.len, 0);
}

test "ValveRegistry duplicate registration fails" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var registry = ValveRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const TestValve = struct {
        valve: Valve,

        pub fn initFn(_: *Valve, _: *ValveContext) !void {}
        pub fn deinitFn(_: *Valve) void {}
    };

    var test_valve = TestValve{
        .valve = Valve{
            .metadata = valve.ValveMetadata{
                .name = "test",
                .version = "1.0.0",
                .description = "Test",
                .author = "Test",
                .required_capabilities = &[_]ValveCapability{},
            },
            .init = &TestValve.initFn,
            .deinit = &TestValve.deinitFn,
        },
    };

    try registry.register(&test_valve.valve, &app);
    try std.testing.expectError(valve.ValveError.ValveAlreadyRegistered, registry.register(&test_valve.valve, &app));
}

test "ValveRegistry getContext" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var registry = ValveRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const TestValve = struct {
        valve: Valve,

        pub fn initFn(_: *Valve, _: *ValveContext) !void {}
        pub fn deinitFn(_: *Valve) void {}
    };

    var test_valve = TestValve{
        .valve = Valve{
            .metadata = valve.ValveMetadata{
                .name = "test",
                .version = "1.0.0",
                .description = "Test",
                .author = "Test",
                .required_capabilities = &[_]ValveCapability{},
            },
            .init = &TestValve.initFn,
            .deinit = &TestValve.deinitFn,
        },
    };

    try registry.register(&test_valve.valve, &app);

    const ctx = registry.getContext("test");
    try std.testing.expect(ctx != null);
    if (ctx) |c| {
        try std.testing.expectEqualStrings(c.valve_name, "test");
    }

    try std.testing.expect(registry.getContext("nonexistent") == null);
}
