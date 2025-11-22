const std = @import("std");
const json_module = @import("../json.zig");
const Response = @import("../response.zig").Response;
const model_utils = @import("model.zig");
const ORM = @import("orm.zig").ORM;

/// Model wrapper that provides built-in methods for ORM structs
/// Provides JSON serialization, Response creation, and utility methods
///
/// Example:
/// ```zig
/// const TodoModel = Model(Todo);
/// const json = try TodoModel.toJson(todo, allocator);
/// defer allocator.free(json);
/// return TodoModel.toResponse(todo, allocator);
/// ```
pub fn Model(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Serialize a single instance to JSON string
        /// Uses Json.serialize internally
        ///
        /// Example:
        /// ```zig
        /// const json_str = try TodoModel.toJson(todo, allocator);
        /// defer allocator.free(json_str);
        /// ```
        pub fn toJson(instance: T, allocator: std.mem.Allocator) ![]const u8 {
            return json_module.Json.serialize(T, instance, allocator);
        }

        /// Serialize an array/slice to JSON array string
        /// Uses Json.serializeArray internally
        ///
        /// Example:
        /// ```zig
        /// const json_str = try TodoModel.toJsonArray(&todos, allocator);
        /// defer allocator.free(json_str);
        /// ```
        pub fn toJsonArray(items: []const T, allocator: std.mem.Allocator) ![]const u8 {
            return json_module.Json.serializeArray(T, items, allocator);
        }

        /// Serialize an ArrayListUnmanaged to JSON array string
        /// Uses Json.serializeArray internally
        ///
        /// Example:
        /// ```zig
        /// const json_str = try TodoModel.toJsonList(todos, allocator);
        /// defer allocator.free(json_str);
        /// ```
        pub fn toJsonList(list: std.ArrayListUnmanaged(T), allocator: std.mem.Allocator) ![]const u8 {
            return json_module.Json.serializeArray(T, list.items, allocator);
        }

        /// Create a JSON Response from a single instance
        /// Uses Response.jsonFrom internally, handles persistent memory automatically
        ///
        /// Example:
        /// ```zig
        /// return TodoModel.toResponse(todo, allocator);
        /// ```
        pub fn toResponse(instance: T, allocator: std.mem.Allocator) Response {
            return Response.jsonFrom(T, instance, allocator);
        }

        /// Create a JSON Response from an array
        /// Serializes array and creates Response with persistent memory
        ///
        /// Example:
        /// ```zig
        /// return TodoModel.toResponseArray(&todos, allocator);
        /// ```
        pub fn toResponseArray(items: []const T, allocator: std.mem.Allocator) Response {
            const json_str = json_module.Json.serializeArray(T, items, allocator) catch {
                return Response.serverError("Failed to serialize array");
            };
            defer allocator.free(json_str);

            // Copy to persistent memory for response
            const persistent_json = std.heap.page_allocator.dupe(u8, json_str) catch {
                return Response.serverError("Failed to allocate response");
            };
            return Response.json(persistent_json);
        }

        /// Create a JSON Response from an ArrayListUnmanaged
        /// Serializes list and creates Response with persistent memory
        ///
        /// Example:
        /// ```zig
        /// return TodoModel.toResponseList(todos, allocator);
        /// ```
        pub fn toResponseList(list: std.ArrayListUnmanaged(T), allocator: std.mem.Allocator) Response {
            return Self.toResponseArray(list.items, allocator);
        }

        /// Deserialize JSON string to instance
        /// Uses Json.deserialize internally
        ///
        /// Example:
        /// ```zig
        /// const todo = try TodoModel.fromJson(json_str, allocator);
        /// defer allocator.free(todo.title);
        /// ```
        pub fn fromJson(json_str: []const u8, allocator: std.mem.Allocator) !T {
            return json_module.Json.deserialize(T, json_str, allocator);
        }

        /// Get table name for this model
        /// Uses model_utils.inferTableName internally
        ///
        /// Example:
        /// ```zig
        /// const table = TodoModel.tableName(); // Returns "Todo"
        /// ```
        pub fn tableName() []const u8 {
            return model_utils.inferTableName(T);
        }

        /// Get field names for this model
        /// Returns a slice of field name strings
        ///
        /// Example:
        /// ```zig
        /// const fields = TodoModel.fieldNames();
        /// // Returns &[_][]const u8{"id", "title", "description", ...}
        /// ```
        pub fn fieldNames() *const [std.meta.fields(T).len][]const u8 {
            return model_utils.getFieldNames(T);
        }
    };
}

/// Model with ORM integration
/// Wraps ORM instance and provides CRUD methods with automatic memory management
///
/// Example:
/// ```zig
/// const TodoModelORM = ModelWithORM(Todo);
/// var model = TodoModelORM.init(orm);
/// const todo = try model.create(new_todo);
/// defer allocator.free(todo.title);
/// ```
pub fn ModelWithORM(comptime T: type) type {
    return struct {
        const Self = @This();

        orm: *ORM,

        /// Initialize ModelWithORM with an ORM instance
        ///
        /// Example:
        /// ```zig
        /// var model = ModelWithORM(Todo).init(orm);
        /// ```
        pub fn init(orm: *ORM) Self {
            return Self{ .orm = orm };
        }

        /// Create a new record
        /// Creates the record in the database and returns the created instance with allocated strings
        ///
        /// Example:
        /// ```zig
        /// const todo = try model.create(new_todo);
        /// defer allocator.free(todo.title);
        /// ```
        pub fn create(self: Self, instance: T) !T {
            try self.orm.create(T, instance);

            // Get the last insert row ID
            const id = self.orm.db.lastInsertRowId() catch {
                // Fallback: find by highest ID
                var all_result = try self.orm.findAllManaged(T);
                defer all_result.deinit();
                if (all_result.isEmpty()) return error.FailedToCreate;

                var max_id: i64 = 0;
                for (all_result.getItems()) |item| {
                    const id_field = @field(item, "id");
                    if (id_field > max_id) {
                        max_id = id_field;
                    }
                }

                const max_result_opt = try self.orm.findManaged(T, max_id);
                if (max_result_opt) |result| {
                    var mutable_result = result;
                    defer mutable_result.deinit();
                    if (mutable_result.first()) |found| {
                        return try Self.copyInstance(found, self.orm.allocator);
                    }
                }
                return error.FailedToCreate;
            };

            // Fetch the created record
            const result_opt = try self.orm.findManaged(T, id);
            if (result_opt) |result| {
                var mutable_result = result;
                defer mutable_result.deinit();
                if (mutable_result.first()) |found| {
                    return try Self.copyInstance(found, self.orm.allocator);
                }
            }
            return error.FailedToCreate;
        }

        /// Find a record by ID
        /// Returns a copy with allocated strings, or null if not found
        ///
        /// Example:
        /// ```zig
        /// if (try model.find(1)) |todo| {
        ///     defer allocator.free(todo.title);
        ///     // Use todo
        /// }
        /// ```
        pub fn find(self: Self, id: i64) !?T {
            const result_opt = try self.orm.findManaged(T, id);
            if (result_opt) |result| {
                var mutable_result = result;
                defer mutable_result.deinit();
                if (mutable_result.first()) |found| {
                    return try Self.copyInstance(found, self.orm.allocator);
                }
            }
            return null;
        }

        /// Find all records
        /// Returns ArrayListUnmanaged with copies of all records (strings allocated)
        ///
        /// Example:
        /// ```zig
        /// var todos = try model.findAll();
        /// defer {
        ///     for (todos.items) |todo| {
        ///         allocator.free(todo.title);
        ///     }
        ///     todos.deinit(allocator);
        /// }
        /// ```
        pub fn findAll(self: Self) !std.ArrayListUnmanaged(T) {
            var result = try self.orm.findAllManaged(T);
            defer result.deinit();

            var items = std.ArrayListUnmanaged(T){};
            for (result.getItems()) |item| {
                try items.append(self.orm.allocator, try Self.copyInstance(item, self.orm.allocator));
            }
            return items;
        }

        /// Update a record
        /// Updates the record and returns the updated instance, or null if not found
        ///
        /// Example:
        /// ```zig
        /// if (try model.update(id, updated_todo)) |todo| {
        ///     defer allocator.free(todo.title);
        ///     // Use updated todo
        /// }
        /// ```
        pub fn update(self: Self, id: i64, instance: T) !?T {
            try self.orm.update(T, instance);
            return try self.find(id);
        }

        /// Delete a record by ID
        /// Returns true if deleted, false if not found
        ///
        /// Example:
        /// ```zig
        /// const deleted = try model.delete(id);
        /// ```
        pub fn delete(self: Self, id: i64) !bool {
            const existing = try self.find(id);
            if (existing == null) return false;
            try self.orm.delete(T, id);
            return true;
        }

        /// Helper to copy instance with allocated strings
        /// Deep copies all string fields using the provided allocator
        fn copyInstance(instance: T, allocator: std.mem.Allocator) !T {
            var copy = instance;

            inline for (std.meta.fields(T)) |field| {
                const field_type = field.type;
                const field_value = @field(instance, field.name);

                if (@typeInfo(field_type) == .pointer) {
                    const ptr_info = @typeInfo(field_type).pointer;
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        @field(copy, field.name) = try allocator.dupe(u8, field_value);
                    }
                } else if (@typeInfo(field_type) == .optional) {
                    const opt_info = @typeInfo(field_type).optional;
                    if (@typeInfo(opt_info.child) == .pointer) {
                        const ptr_info = @typeInfo(opt_info.child).pointer;
                        if (ptr_info.size == .slice and ptr_info.child == u8) {
                            if (field_value) |value| {
                                @field(copy, field.name) = try allocator.dupe(u8, value);
                            }
                        }
                    }
                }
            }

            return copy;
        }
    };
}

/// Model stats helper (for models that need statistics)
/// Provides stats calculation and serialization helpers
///
/// Example:
/// ```zig
/// const TodoStatsModel = ModelStats(Todo, TodoStats);
/// var stats_model = TodoStatsModel.init(orm);
/// const stats = try stats_model.calculate(calculateStats);
/// return stats_model.toResponse(stats, allocator);
/// ```
pub fn ModelStats(comptime T: type, comptime StatsType: type) type {
    return struct {
        const Self = @This();

        orm: *ORM,

        /// Initialize ModelStats with an ORM instance
        ///
        /// Example:
        /// ```zig
        /// var stats_model = ModelStats(Todo, TodoStats).init(orm);
        /// ```
        pub fn init(orm: *ORM) Self {
            return Self{ .orm = orm };
        }

        /// Calculate stats using a callback function
        /// The callback receives all records and an allocator
        ///
        /// Example:
        /// ```zig
        /// const stats = try stats_model.calculate(struct {
        ///     fn calc(items: []const Todo, alloc: Allocator) anyerror!TodoStats {
        ///         // Calculate stats from items
        ///         return TodoStats{ ... };
        ///     }
        /// }.calc);
        /// ```
        pub fn calculate(self: Self, callback: fn ([]const T, std.mem.Allocator) anyerror!StatsType) !StatsType {
            var result = try self.orm.findAllManaged(T);
            defer result.deinit();
            return try callback(result.getItems(), self.orm.allocator);
        }

        /// Serialize stats to JSON string
        /// Uses Json.serialize internally
        ///
        /// Example:
        /// ```zig
        /// const json_str = try stats_model.toJson(stats, allocator);
        /// defer allocator.free(json_str);
        /// ```
        pub fn toJson(self: Self, stats: StatsType, allocator: std.mem.Allocator) ![]const u8 {
            _ = self;
            return json_module.Json.serialize(StatsType, stats, allocator);
        }

        /// Create a stats Response
        /// Uses Response.jsonFrom internally
        ///
        /// Example:
        /// ```zig
        /// return stats_model.toResponse(stats, allocator);
        /// ```
        pub fn toResponse(self: Self, stats: StatsType, allocator: std.mem.Allocator) Response {
            _ = self;
            return Response.jsonFrom(StatsType, stats, allocator);
        }
    };
}

// Tests
test "Model toJson" {
    const TestStruct = struct {
        id: i64,
        name: []const u8,
    };

    const TestModel = Model(TestStruct);
    const instance = TestStruct{ .id = 1, .name = "test" };

    const json_str = try TestModel.toJson(instance, std.testing.allocator);
    defer std.testing.allocator.free(json_str);
    defer std.testing.allocator.free(instance.name);

    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"name\":\"test\"") != null);
}

test "Model toJsonArray" {
    const TestStruct = struct {
        id: i64,
    };

    const TestModel = Model(TestStruct);
    const items = [_]TestStruct{
        TestStruct{ .id = 1 },
        TestStruct{ .id = 2 },
    };

    const json_str = try TestModel.toJsonArray(&items, std.testing.allocator);
    defer std.testing.allocator.free(json_str);

    try std.testing.expect(std.mem.startsWith(u8, json_str, "["));
    try std.testing.expect(std.mem.endsWith(u8, json_str, "]"));
}

test "Model tableName" {
    const TestStruct = struct {
        id: i64,
    };

    const TestModel = Model(TestStruct);
    const table = TestModel.tableName();

    try std.testing.expectEqualStrings("TestStruct", table);
}

test "Model fieldNames" {
    const TestStruct = struct {
        id: i64,
        name: []const u8,
        age: i32,
    };

    const TestModel = Model(TestStruct);
    const fields = TestModel.fieldNames();

    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("id", fields[0]);
    try std.testing.expectEqualStrings("name", fields[1]);
    try std.testing.expectEqualStrings("age", fields[2]);
}
