const std = @import("std");

/// JSON serialization and deserialization utilities
/// Provides comptime type-safe JSON parsing and formatting
pub const Json = struct {
    /// Serialize a struct to JSON string
    /// Uses comptime introspection to automatically handle all fields
    ///
    /// Example:
    /// ```zig
    /// const Todo = struct { id: i64, title: []const u8, completed: bool };
    /// const todo = Todo{ .id = 1, .title = "Hello", .completed = false };
    /// const json = try Json.serialize(Todo, todo, allocator);
    /// defer allocator.free(json);
    /// ```
    pub fn serialize(comptime T: type, value: T, allocator: std.mem.Allocator) ![]const u8 {
        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(allocator);

        try serializeValue(T, value, &list, allocator);
        return list.toOwnedSlice(allocator);
    }

    /// Deserialize a JSON string to a struct
    /// Uses comptime introspection to automatically parse all fields
    ///
    /// Example:
    /// ```zig
    /// const Todo = struct { id: i64, title: []const u8, completed: bool };
    /// const json = "{\"id\":1,\"title\":\"Hello\",\"completed\":false}";
    /// const todo = try Json.deserialize(Todo, json, allocator);
    /// defer allocator.free(todo.title);
    /// ```
    pub fn deserialize(comptime T: type, json_str: []const u8, allocator: std.mem.Allocator) !T {
        var parser = Parser.init(json_str, allocator);
        defer parser.deinit();
        return try parser.parseStruct(T);
    }

    /// Serialize an array of structs to JSON array
    ///
    /// Example:
    /// ```zig
    /// const todos = [_]Todo{ todo1, todo2 };
    /// const json = try Json.serializeArray(Todo, &todos, allocator);
    /// defer allocator.free(json);
    /// ```
    pub fn serializeArray(comptime T: type, items: []const T, allocator: std.mem.Allocator) ![]const u8 {
        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(allocator);

        try list.writer(allocator).print("[", .{});
        for (items, 0..) |item, i| {
            if (i > 0) {
                try list.writer(allocator).print(",", .{});
            }
            try serializeValue(T, item, &list, allocator);
        }
        try list.writer(allocator).print("]", .{});

        return list.toOwnedSlice(allocator);
    }

    /// Serialize an optional value to JSON
    pub fn serializeOptional(comptime T: type, value: ?T, allocator: std.mem.Allocator) ![]const u8 {
        if (value) |v| {
            return serialize(T, v, allocator);
        } else {
            const null_str = try allocator.dupe(u8, "null");
            return null_str;
        }
    }

    // Internal serialization function
    fn serializeValue(comptime T: type, value: T, list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
        const type_info = @typeInfo(T);

        switch (type_info) {
            .@"struct" => {
                try list.writer(allocator).print("{{", .{});

                inline for (std.meta.fields(T), 0..) |field, i| {
                    if (i > 0) {
                        try list.writer(allocator).print(",", .{});
                    }

                    // Field name
                    try list.writer(allocator).print("\"{s}\":", .{field.name});

                    // Field value
                    const field_value = @field(value, field.name);
                    try serializeFieldValue(field.type, field_value, list, allocator);
                }

                try list.writer(allocator).print("}}", .{});
            },
            .array => {
                try list.writer(allocator).print("[", .{});
                for (value, 0..) |item, i| {
                    if (i > 0) {
                        try list.writer(allocator).print(",", .{});
                    }
                    try serializeFieldValue(@TypeOf(item), item, list, allocator);
                }
                try list.writer(allocator).print("]", .{});
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice) {
                    try serializeFieldValue(ptr_info.child, value, list, allocator);
                } else {
                    @compileError("Unsupported pointer type for JSON serialization");
                }
            },
            else => {
                try serializeFieldValue(T, value, list, allocator);
            },
        }
    }

    fn serializeFieldValue(comptime T: type, value: T, list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
        const type_info = @typeInfo(T);

        switch (type_info) {
            .int => {
                try list.writer(allocator).print("{}", .{value});
            },
            .float => {
                try list.writer(allocator).print("{d}", .{value});
            },
            .bool => {
                if (value) {
                    try list.writer(allocator).print("true", .{});
                } else {
                    try list.writer(allocator).print("false", .{});
                }
            },
            .optional => |opt_info| {
                if (value) |v| {
                    try serializeFieldValue(opt_info.child, v, list, allocator);
                } else {
                    try list.writer(allocator).print("null", .{});
                }
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice) {
                    if (ptr_info.child == u8) {
                        // String - escape properly
                        try escapeString(value, list, allocator);
                    } else {
                        // Array slice
                        try list.writer(allocator).print("[", .{});
                        for (value, 0..) |item, i| {
                            if (i > 0) {
                                try list.writer(allocator).print(",", .{});
                            }
                            try serializeFieldValue(ptr_info.child, item, list, allocator);
                        }
                        try list.writer(allocator).print("]", .{});
                    }
                } else {
                    @compileError("Unsupported pointer type for JSON serialization");
                }
            },
            .@"struct" => {
                try serializeValue(T, value, list, allocator);
            },
            else => {
                @compileError("Unsupported type for JSON serialization: " ++ @typeName(T));
            },
        }
    }

    fn escapeString(str: []const u8, list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
        try list.writer(allocator).print("\"", .{});
        for (str) |char| {
            switch (char) {
                '"' => try list.writer(allocator).print("\\\"", .{}),
                '\\' => try list.writer(allocator).print("\\\\", .{}),
                '\n' => try list.writer(allocator).print("\\n", .{}),
                '\r' => try list.writer(allocator).print("\\r", .{}),
                '\t' => try list.writer(allocator).print("\\t", .{}),
                else => try list.writer(allocator).print("{c}", .{char}),
            }
        }
        try list.writer(allocator).print("\"", .{});
    }

    // Parser for deserialization
    const Parser = struct {
        input: []const u8,
        pos: usize,
        allocator: std.mem.Allocator,

        fn init(input: []const u8, allocator: std.mem.Allocator) Parser {
            return Parser{
                .input = input,
                .pos = 0,
                .allocator = allocator,
            };
        }

        fn deinit(self: *Parser) void {
            _ = self;
        }

        fn skipWhitespace(self: *Parser) void {
            while (self.pos < self.input.len and (self.input[self.pos] == ' ' or self.input[self.pos] == '\t' or self.input[self.pos] == '\n' or self.input[self.pos] == '\r')) {
                self.pos += 1;
            }
        }

        fn parseStruct(self: *Parser, comptime T: type) !T {
            self.skipWhitespace();
            if (self.pos >= self.input.len or self.input[self.pos] != '{') {
                std.debug.print("[JSON Parser Error] Expected '{{' at start of struct\n", .{});
                std.debug.print("  Input: {s}\n", .{self.input});
                std.debug.print("  Position: {d}\n", .{self.pos});
                if (self.pos < self.input.len) {
                    const context_start = if (self.pos > 20) self.pos - 20 else 0;
                    const context_end = if (self.pos + 20 < self.input.len) self.pos + 20 else self.input.len;
                    std.debug.print("  Context: {s}\n", .{self.input[context_start..context_end]});
                }
                return error.InvalidJson;
            }
            self.pos += 1;

            // Initialize all fields to default values first for robustness
            // This ensures no fields remain undefined if missing from JSON
            var result: T = undefined;
            inline for (std.meta.fields(T)) |field| {
                const field_type = field.type;
                const type_info = @typeInfo(field_type);
                switch (type_info) {
                    .int => @field(result, field.name) = 0,
                    .float => @field(result, field.name) = 0.0,
                    .bool => @field(result, field.name) = false,
                    .optional => @field(result, field.name) = null,
                    .pointer => |ptr_info| {
                        if (ptr_info.size == .slice and ptr_info.child == u8) {
                            @field(result, field.name) = "";
                        }
                    },
                    else => {},
                }
            }

            var field_count: usize = 0;

            inline for (std.meta.fields(T)) |field| {
                self.skipWhitespace();

                if (field_count > 0) {
                    if (self.pos >= self.input.len or self.input[self.pos] != ',') {
                        break;
                    }
                    self.pos += 1;
                    self.skipWhitespace();
                }

                // Check for closing brace
                if (self.pos < self.input.len and self.input[self.pos] == '}') {
                    break;
                }

                // Parse field name
                const field_name = try self.parseString();
                self.skipWhitespace();

                if (self.pos >= self.input.len or self.input[self.pos] != ':') {
                    return error.InvalidJson;
                }
                self.pos += 1;
                self.skipWhitespace();

                // Parse field value if field name matches
                if (std.mem.eql(u8, field_name, field.name)) {
                    const field_value = try self.parseFieldValue(field.type);
                    @field(result, field.name) = field_value;
                } else {
                    // Skip this field value
                    _ = try self.skipValue();
                }

                self.allocator.free(field_name);
                field_count += 1;
            }

            self.skipWhitespace();
            if (self.pos >= self.input.len or self.input[self.pos] != '}') {
                std.debug.print("[JSON Parser Error] Expected '}}' at end of struct\n", .{});
                std.debug.print("  Input: {s}\n", .{self.input});
                std.debug.print("  Position: {d}\n", .{self.pos});
                return error.InvalidJson;
            }
            self.pos += 1;

            return result;
        }

        fn parseFieldValue(self: *Parser, comptime T: type) !T {
            const type_info = @typeInfo(T);

            switch (type_info) {
                .int => {
                    return try self.parseInt(T);
                },
                .float => {
                    return try self.parseFloat(T);
                },
                .bool => {
                    return try self.parseBool();
                },
                .optional => |opt_info| {
                    self.skipWhitespace();
                    if (self.pos < self.input.len and std.mem.startsWith(u8, self.input[self.pos..], "null")) {
                        self.pos += 4;
                        return null;
                    } else {
                        const value = try self.parseFieldValue(opt_info.child);
                        return value;
                    }
                },
                .pointer => |ptr_info| {
                    if (ptr_info.size == .slice) {
                        if (ptr_info.child == u8) {
                            // String
                            return try self.parseString();
                        } else {
                            @compileError("Unsupported slice type for JSON deserialization: " ++ @typeName(T));
                        }
                    } else {
                        @compileError("Unsupported pointer type for JSON deserialization: " ++ @typeName(T));
                    }
                },
                .@"struct" => {
                    return try self.parseStruct(T);
                },
                else => {
                    @compileError("Unsupported type for JSON deserialization: " ++ @typeName(T));
                },
            }
        }

        fn parseString(self: *Parser) ![]const u8 {
            self.skipWhitespace();
            if (self.pos >= self.input.len or self.input[self.pos] != '"') {
                std.debug.print("[JSON Parser Error] Expected '\\\"' at start of string\n", .{});
                std.debug.print("  Input: {s}\n", .{self.input});
                std.debug.print("  Position: {d}\n", .{self.pos});
                return error.InvalidJson;
            }
            self.pos += 1;

            const start = self.pos;
            var escaped = false;

            while (self.pos < self.input.len) {
                if (escaped) {
                    escaped = false;
                    self.pos += 1;
                    continue;
                }

                if (self.input[self.pos] == '\\') {
                    escaped = true;
                    self.pos += 1;
                    continue;
                }

                if (self.input[self.pos] == '"') {
                    break;
                }

                self.pos += 1;
            }

            if (self.pos >= self.input.len) {
                return error.InvalidJson;
            }

            const str = self.input[start..self.pos];
            self.pos += 1; // Skip closing quote

            // Unescape the string
            var result = std.ArrayListUnmanaged(u8){};
            defer result.deinit(self.allocator);

            var i: usize = 0;
            while (i < str.len) {
                if (str[i] == '\\' and i + 1 < str.len) {
                    switch (str[i + 1]) {
                        'n' => try result.append(self.allocator, '\n'),
                        'r' => try result.append(self.allocator, '\r'),
                        't' => try result.append(self.allocator, '\t'),
                        '\\' => try result.append(self.allocator, '\\'),
                        '"' => try result.append(self.allocator, '"'),
                        else => {
                            try result.append(self.allocator, str[i]);
                            try result.append(self.allocator, str[i + 1]);
                        },
                    }
                    i += 2;
                } else {
                    try result.append(self.allocator, str[i]);
                    i += 1;
                }
            }

            return result.toOwnedSlice(self.allocator);
        }

        fn parseInt(self: *Parser, comptime T: type) !T {
            self.skipWhitespace();
            const start = self.pos;
            var negative = false;

            if (self.pos < self.input.len and self.input[self.pos] == '-') {
                negative = true;
                self.pos += 1;
            }

            while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9') {
                self.pos += 1;
            }

            if (self.pos == start + @as(usize, @intFromBool(negative))) {
                return error.InvalidJson;
            }

            const num_str = self.input[start..self.pos];
            return std.fmt.parseInt(T, num_str, 10);
        }

        fn parseFloat(self: *Parser, comptime T: type) !T {
            self.skipWhitespace();
            const start = self.pos;
            var negative = false;

            if (self.pos < self.input.len and self.input[self.pos] == '-') {
                negative = true;
                self.pos += 1;
            }

            while (self.pos < self.input.len and ((self.input[self.pos] >= '0' and self.input[self.pos] <= '9') or self.input[self.pos] == '.')) {
                self.pos += 1;
            }

            if (self.pos == start + @as(usize, @intFromBool(negative))) {
                return error.InvalidJson;
            }

            const num_str = self.input[start..self.pos];
            return std.fmt.parseFloat(T, num_str);
        }

        fn parseBool(self: *Parser) !bool {
            self.skipWhitespace();
            if (std.mem.startsWith(u8, self.input[self.pos..], "true")) {
                self.pos += 4;
                return true;
            } else if (std.mem.startsWith(u8, self.input[self.pos..], "false")) {
                self.pos += 5;
                return false;
            } else {
                std.debug.print("[JSON Parser Error] Invalid boolean value\n", .{});
                std.debug.print("  Input: {s}\n", .{self.input});
                std.debug.print("  Position: {d}\n", .{self.pos});
                return error.InvalidJson;
            }
        }

        fn skipValue(self: *Parser) !void {
            self.skipWhitespace();
            if (self.pos >= self.input.len) {
                return error.InvalidJson;
            }

            switch (self.input[self.pos]) {
                '"' => {
                    // String
                    self.pos += 1;
                    while (self.pos < self.input.len and self.input[self.pos] != '"') {
                        if (self.input[self.pos] == '\\') {
                            self.pos += 1;
                        }
                        self.pos += 1;
                    }
                    if (self.pos < self.input.len) {
                        self.pos += 1;
                    }
                },
                't', 'f' => {
                    // Boolean
                    if (std.mem.startsWith(u8, self.input[self.pos..], "true")) {
                        self.pos += 4;
                    } else if (std.mem.startsWith(u8, self.input[self.pos..], "false")) {
                        self.pos += 5;
                    }
                },
                'n' => {
                    // Null
                    if (std.mem.startsWith(u8, self.input[self.pos..], "null")) {
                        self.pos += 4;
                    }
                },
                '{' => {
                    // Object
                    self.pos += 1;
                    var depth: usize = 1;
                    while (self.pos < self.input.len and depth > 0) {
                        switch (self.input[self.pos]) {
                            '{' => depth += 1,
                            '}' => depth -= 1,
                            else => {},
                        }
                        self.pos += 1;
                    }
                },
                '[' => {
                    // Array
                    self.pos += 1;
                    var depth: usize = 1;
                    while (self.pos < self.input.len and depth > 0) {
                        switch (self.input[self.pos]) {
                            '[' => depth += 1,
                            ']' => depth -= 1,
                            else => {},
                        }
                        self.pos += 1;
                    }
                },
                '-', '0'...'9' => {
                    // Number
                    while (self.pos < self.input.len and ((self.input[self.pos] >= '0' and self.input[self.pos] <= '9') or self.input[self.pos] == '.' or self.input[self.pos] == '-' or self.input[self.pos] == '+' or self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
                        self.pos += 1;
                    }
                },
                else => {
                    return error.InvalidJson;
                },
            }
        }
    };
};

// Tests
test "Json.serialize simple struct" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        id: i64,
        name: []const u8,
        active: bool,
    };

    const test_value = TestStruct{
        .id = 42,
        .name = "test",
        .active = true,
    };

    const json = try Json.serialize(TestStruct, test_value, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"active\":true") != null);
}

test "Json.deserialize simple struct" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        id: i64,
        name: []const u8,
        active: bool,
    };

    const json = "{\"id\":42,\"name\":\"test\",\"active\":true}";
    const parsed = try Json.deserialize(TestStruct, json, allocator);
    defer allocator.free(parsed.name);

    try std.testing.expectEqual(@as(i64, 42), parsed.id);
    try std.testing.expectEqualStrings("test", parsed.name);
    try std.testing.expect(parsed.active);
}

test "Json.serialize with optional" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        id: i64,
        description: ?[]const u8,
    };

    const test_value1 = TestStruct{ .id = 1, .description = "test" };
    const json1 = try Json.serialize(TestStruct, test_value1, allocator);
    defer allocator.free(json1);
    // Note: test_value1.description is a string literal, not allocated, so no need to free

    const test_value2 = TestStruct{ .id = 2, .description = null };
    const json2 = try Json.serialize(TestStruct, test_value2, allocator);
    defer allocator.free(json2);

    try std.testing.expect(std.mem.indexOf(u8, json1, "\"description\":\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json2, "\"description\":null") != null);
}

test "Json.serializeArray" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        id: i64,
        name: []const u8,
    };

    const items = [_]TestStruct{
        TestStruct{ .id = 1, .name = "one" },
        TestStruct{ .id = 2, .name = "two" },
    };

    const json = try Json.serializeArray(TestStruct, &items, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.startsWith(u8, json, "["));
    try std.testing.expect(std.mem.endsWith(u8, json, "]"));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":2") != null);
}

test "Json escape string" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        message: []const u8,
    };

    const test_value = TestStruct{ .message = "Hello \"world\"\nTest" };
    const json = try Json.serialize(TestStruct, test_value, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\n") != null);
}
