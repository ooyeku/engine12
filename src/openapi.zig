const std = @import("std");
const json_mod = @import("json.zig");
const model_utils = @import("orm/model.zig");

pub const OpenApiInfo = struct {
    title: []const u8,
    version: []const u8,
    description: ?[]const u8 = null,
};

pub const OpenApiServer = struct {
    url: []const u8,
    description: ?[]const u8 = null,
};

pub const OpenApiSchema = struct {
    type: []const u8,
    format: ?[]const u8 = null,
    properties: ?std.StringHashMapUnmanaged(OpenApiSchema) = null,
    items: ?*OpenApiSchema = null,
    required: ?std.ArrayListUnmanaged([]const u8) = null,
    nullable: bool = false,

    // For serialization (custom since we have hashmaps/pointers)
    pub fn toJson(self: OpenApiSchema, allocator: std.mem.Allocator) ![]const u8 {
        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(allocator);
        try self.serialize(&list, allocator);
        return list.toOwnedSlice(allocator);
    }

    fn serialize(self: OpenApiSchema, list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
        try list.writer(allocator).print("{{\"type\":\"{s}\"", .{self.type});

        if (self.format) |fmt| {
            try list.writer(allocator).print(",\"format\":\"{s}\"", .{fmt});
        }

        if (self.nullable) {
            try list.writer(allocator).print(",\"nullable\":true", .{});
        }

        if (self.properties) |props| {
            try list.writer(allocator).print(",\"properties\":{{", .{});
            var it = props.iterator();
            var i: usize = 0;
            while (it.next()) |entry| {
                if (i > 0) try list.writer(allocator).print(",", .{});
                try list.writer(allocator).print("\"{s}\":", .{entry.key_ptr.*});
                try entry.value_ptr.serialize(list, allocator);
                i += 1;
            }
            try list.writer(allocator).print("}}", .{});
        }

        if (self.items) |items_ptr| {
            try list.writer(allocator).print(",\"items\":", .{});
            try items_ptr.serialize(list, allocator);
        }

        if (self.required) |req| {
            if (req.items.len > 0) {
                try list.writer(allocator).print(",\"required\":[", .{});
                for (req.items, 0..) |field, i| {
                    if (i > 0) try list.writer(allocator).print(",", .{});
                    try list.writer(allocator).print("\"{s}\"", .{field});
                }
                try list.writer(allocator).print("]", .{});
            }
        }

        try list.writer(allocator).print("}}", .{});
    }
};

pub const OpenApiParameter = struct {
    name: []const u8,
    in: []const u8, // "query", "header", "path", "cookie"
    description: ?[]const u8 = null,
    required: bool = false,
    schema: OpenApiSchema,
};

pub const OpenApiRequestBody = struct {
    description: ?[]const u8 = null,
    required: bool = false,
    content: std.StringHashMapUnmanaged(OpenApiMediaType),
};

pub const OpenApiMediaType = struct {
    schema: OpenApiSchema,
};

pub const OpenApiResponse = struct {
    description: []const u8,
    content: ?std.StringHashMapUnmanaged(OpenApiMediaType) = null,
};

pub const OpenApiOperation = struct {
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    operationId: ?[]const u8 = null,
    tags: ?std.ArrayListUnmanaged([]const u8) = null,
    parameters: ?std.ArrayListUnmanaged(OpenApiParameter) = null,
    requestBody: ?OpenApiRequestBody = null,
    responses: std.StringHashMapUnmanaged(OpenApiResponse),
};

pub const OpenApiPathItem = struct {
    get: ?OpenApiOperation = null,
    put: ?OpenApiOperation = null,
    post: ?OpenApiOperation = null,
    delete: ?OpenApiOperation = null,
    patch: ?OpenApiOperation = null,
};

pub const OpenApiComponents = struct {
    schemas: std.StringHashMapUnmanaged(OpenApiSchema),
};

pub const OpenApiDoc = struct {
    openapi: []const u8 = "3.0.0",
    info: OpenApiInfo,
    servers: std.ArrayListUnmanaged(OpenApiServer),
    paths: std.StringHashMapUnmanaged(OpenApiPathItem),
    components: OpenApiComponents,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, info: OpenApiInfo) OpenApiDoc {
        return OpenApiDoc{
            .info = info,
            .servers = std.ArrayListUnmanaged(OpenApiServer){},
            .paths = std.StringHashMapUnmanaged(OpenApiPathItem){},
            .components = OpenApiComponents{
                .schemas = std.StringHashMapUnmanaged(OpenApiSchema){},
            },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OpenApiDoc) void {
        self.servers.deinit(self.allocator);

        var path_it = self.paths.iterator();
        while (path_it.next()) |entry| {
            // Deep free path items would be needed for a complete implementation
            // For now assume arena allocation or simplified memory model
            _ = entry;
        }
        self.paths.deinit(self.allocator);
        self.components.schemas.deinit(self.allocator);
    }

    pub fn toJson(self: *OpenApiDoc) ![]const u8 {
        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(self.allocator);
        try self.serialize(&list);
        return list.toOwnedSlice(self.allocator);
    }

    fn serialize(self: *OpenApiDoc, list: *std.ArrayListUnmanaged(u8)) !void {
        try list.writer(self.allocator).print("{{\"openapi\":\"3.0.0\"", .{});

        // Info
        try list.writer(self.allocator).print(",\"info\":{{", .{});
        try list.writer(self.allocator).print("\"title\":\"{s}\"", .{self.info.title});
        try list.writer(self.allocator).print(",\"version\":\"{s}\"", .{self.info.version});
        if (self.info.description) |desc| {
            try list.writer(self.allocator).print(",\"description\":\"{s}\"", .{desc});
        }
        try list.writer(self.allocator).print("}}", .{});

        // Paths
        try list.writer(self.allocator).print(",\"paths\":{{", .{});
        var path_it = self.paths.iterator();
        var i: usize = 0;
        while (path_it.next()) |entry| {
            if (i > 0) try list.writer(self.allocator).print(",", .{});
            try list.writer(self.allocator).print("\"{s}\":{{", .{entry.key_ptr.*});

            var has_method = false;
            if (entry.value_ptr.get) |op| {
                try list.writer(self.allocator).print("\"get\":", .{});
                try self.serializeOperation(op, list);
                has_method = true;
            }
            if (entry.value_ptr.post) |op| {
                if (has_method) try list.writer(self.allocator).print(",", .{});
                try list.writer(self.allocator).print("\"post\":", .{});
                try self.serializeOperation(op, list);
                has_method = true;
            }
            if (entry.value_ptr.put) |op| {
                if (has_method) try list.writer(self.allocator).print(",", .{});
                try list.writer(self.allocator).print("\"put\":", .{});
                try self.serializeOperation(op, list);
                has_method = true;
            }
            if (entry.value_ptr.delete) |op| {
                if (has_method) try list.writer(self.allocator).print(",", .{});
                try list.writer(self.allocator).print("\"delete\":", .{});
                try self.serializeOperation(op, list);
                has_method = true;
            }

            try list.writer(self.allocator).print("}}", .{});
            i += 1;
        }
        try list.writer(self.allocator).print("}}", .{});

        // Components (Schemas)
        if (self.components.schemas.count() > 0) {
            try list.writer(self.allocator).print(",\"components\":{{\"schemas\":{{", .{});
            var schema_it = self.components.schemas.iterator();
            var j: usize = 0;
            while (schema_it.next()) |entry| {
                if (j > 0) try list.writer(self.allocator).print(",", .{});
                try list.writer(self.allocator).print("\"{s}\":", .{entry.key_ptr.*});
                try entry.value_ptr.serialize(list, self.allocator);
                j += 1;
            }
            try list.writer(self.allocator).print("}}}}", .{});
        }

        try list.writer(self.allocator).print("}}", .{});
    }

    fn serializeOperation(self: *OpenApiDoc, op: OpenApiOperation, list: *std.ArrayListUnmanaged(u8)) !void {
        try list.writer(self.allocator).print("{{", .{});
        var first = true;

        if (op.summary) |s| {
            try list.writer(self.allocator).print("\"summary\":\"{s}\"", .{s});
            first = false;
        }

        if (op.tags) |tags| {
            if (!first) try list.writer(self.allocator).print(",", .{});
            try list.writer(self.allocator).print("\"tags\":[", .{});
            for (tags.items, 0..) |tag, i| {
                if (i > 0) try list.writer(self.allocator).print(",", .{});
                try list.writer(self.allocator).print("\"{s}\"", .{tag});
            }
            try list.writer(self.allocator).print("]", .{});
            first = false;
        }

        if (op.parameters) |params| {
            if (!first) try list.writer(self.allocator).print(",", .{});
            try list.writer(self.allocator).print("\"parameters\":[", .{});
            for (params.items, 0..) |p, i| {
                if (i > 0) try list.writer(self.allocator).print(",", .{});
                try list.writer(self.allocator).print("{{\"name\":\"{s}\",\"in\":\"{s}\",\"required\":{s},\"schema\":", .{ p.name, p.in, if (p.required) "true" else "false" });
                try p.schema.serialize(list, self.allocator);
                try list.writer(self.allocator).print("}}", .{});
            }
            try list.writer(self.allocator).print("]", .{});
            first = false;
        }

        if (op.requestBody) |body| {
            if (!first) try list.writer(self.allocator).print(",", .{});
            try list.writer(self.allocator).print("\"requestBody\":{{\"required\":{s},\"content\":{{", .{if (body.required) "true" else "false"});
            var content_it = body.content.iterator();
            var i: usize = 0;
            while (content_it.next()) |entry| {
                if (i > 0) try list.writer(self.allocator).print(",", .{});
                try list.writer(self.allocator).print("\"{s}\":{{\"schema\":", .{entry.key_ptr.*});
                try entry.value_ptr.schema.serialize(list, self.allocator);
                try list.writer(self.allocator).print("}}", .{});
                i += 1;
            }
            try list.writer(self.allocator).print("}}}}", .{});
            first = false;
        }

        if (!first) try list.writer(self.allocator).print(",", .{});
        try list.writer(self.allocator).print("\"responses\":{{", .{});
        var resp_it = op.responses.iterator();
        var k: usize = 0;
        while (resp_it.next()) |entry| {
            if (k > 0) try list.writer(self.allocator).print(",", .{});
            try list.writer(self.allocator).print("\"{s}\":{{\"description\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.description });

            if (entry.value_ptr.content) |content| {
                try list.writer(self.allocator).print(",\"content\":{{", .{});
                var c_it = content.iterator();
                var l: usize = 0;
                while (c_it.next()) |c_entry| {
                    if (l > 0) try list.writer(self.allocator).print(",", .{});
                    try list.writer(self.allocator).print("\"{s}\":{{\"schema\":", .{c_entry.key_ptr.*});
                    try c_entry.value_ptr.schema.serialize(list, self.allocator);
                    try list.writer(self.allocator).print("}}", .{});
                    l += 1;
                }
                try list.writer(self.allocator).print("}}", .{});
            }
            try list.writer(self.allocator).print("}}", .{});
            k += 1;
        }
        try list.writer(self.allocator).print("}}", .{});

        try list.writer(self.allocator).print("}}", .{});
    }
};

pub const OpenAPIGenerator = struct {
    doc: OpenApiDoc,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, info: OpenApiInfo) OpenAPIGenerator {
        return OpenAPIGenerator{
            .doc = OpenApiDoc.init(allocator, info),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OpenAPIGenerator) void {
        self.doc.deinit();
    }

    pub fn generateSchema(self: *OpenAPIGenerator, comptime T: type) !OpenApiSchema {
        const type_info = @typeInfo(T);
        switch (type_info) {
            .int => |info| {
                return OpenApiSchema{
                    .type = "integer",
                    .format = if (info.bits <= 32) "int32" else "int64",
                };
            },
            .float => |info| {
                return OpenApiSchema{
                    .type = "number",
                    .format = if (info.bits <= 32) "float" else "double",
                };
            },
            .bool => {
                return OpenApiSchema{ .type = "boolean" };
            },
            .optional => |info| {
                var schema = try self.generateSchema(info.child);
                schema.nullable = true;
                return schema;
            },
            .pointer => |info| {
                if (info.size == .slice) {
                    if (info.child == u8) {
                        return OpenApiSchema{ .type = "string" };
                    } else {
                        const item_schema = try self.generateSchema(info.child);
                        const item_ptr = try self.allocator.create(OpenApiSchema);
                        item_ptr.* = item_schema;
                        return OpenApiSchema{
                            .type = "array",
                            .items = item_ptr,
                        };
                    }
                }
                return OpenApiSchema{ .type = "string" }; // Fallback
            },
            .@"struct" => {
                // Check if already registered in components (simple check by name)
                const name = @typeName(T);
                // Simple mangling cleanup for name
                var safe_name_buf: [64]u8 = undefined;
                var safe_name_len: usize = 0;

                const last_dot = std.mem.lastIndexOfScalar(u8, name, '.');
                const start_idx = if (last_dot) |idx| idx + 1 else 0;

                for (name[start_idx..]) |c| {
                    if (safe_name_len < safe_name_buf.len) {
                        if (std.ascii.isAlphanumeric(c)) {
                            safe_name_buf[safe_name_len] = c;
                            safe_name_len += 1;
                        }
                    }
                }
                const safe_name = try self.allocator.dupe(u8, safe_name_buf[0..safe_name_len]);

                if (self.doc.components.schemas.contains(safe_name)) {
                    // Return reference
                    // Note: For now we return the full schema directly rather than a $ref to avoid complexity
                    // A real implementation would use a union type to support both inline schemas and references
                }

                var properties = std.StringHashMapUnmanaged(OpenApiSchema){};
                var required = std.ArrayListUnmanaged([]const u8){};

                inline for (std.meta.fields(T)) |field| {
                    const field_schema = try self.generateSchema(field.type);
                    try properties.put(self.allocator, field.name, field_schema);

                    // Assume non-optional fields are required
                    if (@typeInfo(field.type) != .optional) {
                        try required.append(self.allocator, field.name);
                    }
                }

                const schema = OpenApiSchema{
                    .type = "object",
                    .properties = properties,
                    .required = required,
                };

                // Register in components
                try self.doc.components.schemas.put(self.allocator, safe_name, schema);

                // Return reference
                // const ref = try std.fmt.allocPrint(self.allocator, "#/components/schemas/{s}", .{safe_name});
                // For simplicity in this POC, we return a ref object (using type="" as marker for $ref if we had it, but here we just rely on direct embedding or simple types)
                // Ideally we'd return { "$ref": ... }
                // Let's actually just return the schema directly for now to ensure it works without dealing with ref complexity in serialization
                return schema;
            },
            else => return OpenApiSchema{ .type = "string" },
        }
    }

    pub fn registerResource(self: *OpenAPIGenerator, prefix: []const u8, comptime Model: type) !void {
        const schema = try self.generateSchema(Model);
        const model_name = @typeName(Model);
        // Get last part of type name
        const last_dot = std.mem.lastIndexOfScalar(u8, model_name, '.');
        const simple_name = if (last_dot) |idx| model_name[idx + 1 ..] else model_name;

        // Define common parameter: ID
        var id_param = std.ArrayListUnmanaged(OpenApiParameter){};
        try id_param.append(self.allocator, OpenApiParameter{
            .name = "id",
            .in = "path",
            .required = true,
            .schema = OpenApiSchema{ .type = "integer", .format = "int64" },
        });

        // Define responses
        var success_resp = std.StringHashMapUnmanaged(OpenApiResponse){};
        var json_content = std.StringHashMapUnmanaged(OpenApiMediaType){};
        try json_content.put(self.allocator, "application/json", OpenApiMediaType{ .schema = schema });
        try success_resp.put(self.allocator, "200", OpenApiResponse{ .description = "Successful operation", .content = json_content });

        // Define list responses (array)
        var list_resp = std.StringHashMapUnmanaged(OpenApiResponse){};
        var list_json_content = std.StringHashMapUnmanaged(OpenApiMediaType){};

        const items_ptr = try self.allocator.create(OpenApiSchema);
        items_ptr.* = schema;
        const array_schema = OpenApiSchema{ .type = "array", .items = items_ptr };

        try list_json_content.put(self.allocator, "application/json", OpenApiMediaType{ .schema = array_schema });
        try list_resp.put(self.allocator, "200", OpenApiResponse{ .description = "List of items", .content = list_json_content });

        // Define tags
        var tags = std.ArrayListUnmanaged([]const u8){};
        try tags.append(self.allocator, simple_name);

        // Path: /prefix
        var path_item = OpenApiPathItem{};

        // GET /prefix
        path_item.get = OpenApiOperation{
            .summary = "List items",
            .tags = try tags.clone(self.allocator),
            .responses = list_resp,
        };

        // POST /prefix
        const create_req_body = OpenApiRequestBody{
            .required = true,
            .content = try json_content.clone(self.allocator),
        };
        path_item.post = OpenApiOperation{
            .summary = "Create item",
            .tags = try tags.clone(self.allocator),
            .requestBody = create_req_body,
            .responses = try success_resp.clone(self.allocator),
        };

        try self.doc.paths.put(self.allocator, prefix, path_item);

        // Path: /prefix/{id}
        const detail_path = try std.fmt.allocPrint(self.allocator, "{s}/{{id}}", .{prefix});
        var detail_item = OpenApiPathItem{};

        // GET /prefix/{id}
        detail_item.get = OpenApiOperation{
            .summary = "Get item by ID",
            .tags = try tags.clone(self.allocator),
            .parameters = try id_param.clone(self.allocator),
            .responses = try success_resp.clone(self.allocator),
        };

        // PUT /prefix/{id}
        detail_item.put = OpenApiOperation{
            .summary = "Update item",
            .tags = try tags.clone(self.allocator),
            .parameters = try id_param.clone(self.allocator),
            .requestBody = OpenApiRequestBody{
                .required = true,
                .content = try json_content.clone(self.allocator),
            },
            .responses = try success_resp.clone(self.allocator),
        };

        // DELETE /prefix/{id}
        var delete_resp = std.StringHashMapUnmanaged(OpenApiResponse){};
        try delete_resp.put(self.allocator, "204", OpenApiResponse{ .description = "Deleted successfully" });

        detail_item.delete = OpenApiOperation{
            .summary = "Delete item",
            .tags = try tags.clone(self.allocator),
            .parameters = try id_param.clone(self.allocator),
            .responses = delete_resp,
        };

        try self.doc.paths.put(self.allocator, detail_path, detail_item);
    }
};
