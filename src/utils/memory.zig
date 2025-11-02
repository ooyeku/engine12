const std = @import("std");

/// Memory management utilities for structs
/// Provides convenient functions to free memory allocated in structs
pub const Memory = struct {
    /// Free all string slices in a struct
    /// Uses comptime introspection to find and free []u8 and ?[]u8 fields
    /// 
    /// Example:
    /// ```zig
    /// const Todo = struct { id: i64, title: []const u8, description: []const u8 };
    /// const todo = Todo{ .id = 1, .title = try allocator.dupe(u8, "test"), .description = try allocator.dupe(u8, "desc") };
    /// defer Memory.freeStruct(Todo, todo, allocator);
    /// ```
    pub fn freeStruct(comptime T: type, instance: T, allocator: std.mem.Allocator) void {
        inline for (std.meta.fields(T)) |field| {
            const field_type = field.type;
            const field_value = @field(instance, field.name);
            
            freeFieldValue(field_type, field_value, allocator);
        }
    }

    /// Free all string slices in an array of structs
    /// 
    /// Example:
    /// ```zig
    /// const todos = try orm.findAll(Todo);
    /// defer Memory.freeStructArray(Todo, todos.items, allocator);
    /// defer todos.deinit(allocator);
    /// ```
    pub fn freeStructArray(comptime T: type, items: []T, allocator: std.mem.Allocator) void {
        for (items) |item| {
            freeStruct(T, item, allocator);
        }
    }

    fn freeFieldValue(comptime T: type, value: T, allocator: std.mem.Allocator) void {
        const type_info = @typeInfo(T);
        
        switch (type_info) {
            .Pointer => |ptr_info| {
                if (ptr_info.size == .Slice) {
                    if (ptr_info.child == u8) {
                        // String slice - free it
                        allocator.free(value);
                    } else {
                        // Array slice - recursively free elements
                        for (value) |item| {
                            freeFieldValue(ptr_info.child, item, allocator);
                        }
                        allocator.free(value);
                    }
                }
            },
            .Optional => |opt_info| {
                if (value) |v| {
                    freeFieldValue(opt_info.child, v, allocator);
                }
            },
            .Struct => {
                // Nested struct - recursively free its fields
                inline for (std.meta.fields(T)) |field| {
                    const field_value = @field(value, field.name);
                    freeFieldValue(field.type, field_value, allocator);
                }
            },
            .Array => |arr_info| {
                // Array - free each element
                for (value) |item| {
                    freeFieldValue(arr_info.child, item, allocator);
                }
            },
            else => {
                // Primitive types, etc. - nothing to free
            },
        }
    }
};

// Tests
test "Memory.freeStruct with string fields" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        id: i64,
        name: []const u8,
        description: []const u8,
    };
    
    const name = try allocator.dupe(u8, "test");
    const desc = try allocator.dupe(u8, "description");
    
    const test_value = TestStruct{
        .id = 1,
        .name = name,
        .description = desc,
    };
    
    Memory.freeStruct(TestStruct, test_value, allocator);
    
    // Memory should be freed (no leak check in test, but this exercises the code)
}

test "Memory.freeStruct with optional string" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        id: i64,
        name: ?[]const u8,
    };
    
    const name = try allocator.dupe(u8, "test");
    const test1 = TestStruct{ .id = 1, .name = name };
    Memory.freeStruct(TestStruct, test1, allocator);
    
    const test2 = TestStruct{ .id = 2, .name = null };
    Memory.freeStruct(TestStruct, test2, allocator);
}

test "Memory.freeStructArray" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        id: i64,
        name: []const u8,
    };
    
    const items = [_]TestStruct{
        TestStruct{ .id = 1, .name = try allocator.dupe(u8, "one") },
        TestStruct{ .id = 2, .name = try allocator.dupe(u8, "two") },
    };
    
    Memory.freeStructArray(TestStruct, &items, allocator);
}

test "Memory.freeStruct with nested struct" {
    const allocator = std.testing.allocator;
    const Inner = struct {
        value: []const u8,
    };
    const Outer = struct {
        id: i64,
        inner: Inner,
    };
    
    const value = try allocator.dupe(u8, "nested");
    const inner = Inner{ .value = value };
    const outer = Outer{ .id = 1, .inner = inner };
    
    Memory.freeStruct(Outer, outer, allocator);
}

