const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const orm_mod = @import("orm/orm.zig");
const ORM = orm_mod.ORM;
const QueryBuilder = @import("orm/query_builder.zig").QueryBuilder;
const QueryResult = @import("orm/row.zig").QueryResult;
const validation = @import("validation.zig");
const ValidationErrors = validation.ValidationErrors;
const pagination_mod = @import("pagination.zig");
const Pagination = pagination_mod.Pagination;
const PaginationMeta = pagination_mod.PaginationMeta;
const json_mod = @import("json.zig");
const model_utils = @import("orm/model.zig");

const allocator = std.heap.page_allocator;

/// Generic authentication user type
/// Users should define their own User type that matches this structure
pub const AuthUser = struct {
    id: i64,
    username: []const u8,
    email: []const u8,
    password_hash: []const u8,
};

/// RESTful API configuration
/// Must be created with the Model type using RestApiConfig(Model)
pub fn RestApiConfig(comptime Model: type) type {
    return struct {
        /// ORM instance (required)
        orm: *ORM,
        /// Validator function that validates a model instance from request
        /// Should return ValidationErrors (empty if valid)
        validator: *const fn (*Request, Model) anyerror!ValidationErrors,
        /// Optional authentication function
        /// Should return AuthUser or error if not authenticated
        authenticator: ?*const fn (*Request) anyerror!AuthUser = null,
        /// Optional authorization function for GET/PUT/DELETE by ID
        /// Should return true if user can access the resource, false otherwise
        authorization: ?*const fn (*Request, Model) anyerror!bool = null,
    /// Optional cache TTL in milliseconds
    cache_ttl_ms: ?u32 = null,
    /// Enable pagination (default: true)
    enable_pagination: bool = true,
    /// Enable filtering via ?filter=field:value (default: true)
    enable_filtering: bool = true,
    /// Enable sorting via ?sort=field:asc|desc (default: true)
    enable_sorting: bool = true,
    /// Optional hook called before creating a record
    /// Note: Hooks are not currently supported due to Zig type system limitations
    /// This field is reserved for future use
    _reserved_before_create: ?*const fn () void = null,
    /// Optional hook called after creating a record
    /// Note: Hooks are not currently supported due to Zig type system limitations
    /// This field is reserved for future use
    _reserved_after_create: ?*const fn () void = null,
    /// Optional hook called before updating a record
    /// Note: Hooks are not currently supported due to Zig type system limitations
    /// This field is reserved for future use
    _reserved_before_update: ?*const fn () void = null,
    /// Optional hook called after updating a record
    /// Note: Hooks are not currently supported due to Zig type system limitations
    /// This field is reserved for future use
    _reserved_after_update: ?*const fn () void = null,
    /// Optional hook called before deleting a record
    /// Note: Hooks are not currently supported due to Zig type system limitations
    /// This field is reserved for future use
    _reserved_before_delete: ?*const fn () void = null,
    };
}

/// Parse filter query parameters into QueryBuilder where clauses
/// Format: ?filter=field1:value1&filter=field2:value2
fn parseFilters(
    comptime T: type,
    builder: *QueryBuilder,
    request: *Request,
) !void {
    const filter_params = try request.queryParams();
    var filter_iter = filter_params.iterator();
    
    while (filter_iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, "filter")) continue;
        
        const filter_value = entry.value_ptr.*;
        const colon_pos = std.mem.indexOfScalar(u8, filter_value, ':') orelse continue;
        
        const field_name = filter_value[0..colon_pos];
        const field_value = filter_value[colon_pos + 1..];
        
        // Validate field name exists in struct (runtime check)
        var field_valid = false;
        inline for (std.meta.fields(T)) |field| {
            if (std.mem.eql(u8, field.name, field_name)) {
                field_valid = true;
                break;
            }
        }
        
        if (!field_valid) {
            return error.InvalidFieldName;
        }
        
        // Add where clause (using equals by default)
        _ = builder.whereEq(field_name, field_value);
    }
}

/// Parse sort query parameter into QueryBuilder orderBy
/// Format: ?sort=field:asc or ?sort=field:desc
fn parseSort(
    comptime T: type,
    builder: *QueryBuilder,
    request: *Request,
) !void {
    const sort_param = try request.query("sort");
    const sort_value = sort_param orelse return;
    
    const colon_pos = std.mem.indexOfScalar(u8, sort_value, ':') orelse return;
    
    const field_name = sort_value[0..colon_pos];
    const direction = sort_value[colon_pos + 1..];
    
    // Validate field name exists in struct (runtime check)
    var field_valid = false;
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            field_valid = true;
            break;
        }
    }
    
    if (!field_valid) {
        return error.InvalidFieldName;
    }
    
    // Validate direction
    const ascending = if (std.mem.eql(u8, direction, "asc"))
        true
    else if (std.mem.eql(u8, direction, "desc"))
        false
    else
        return error.InvalidSortDirection;
    
    _ = builder.orderBy(field_name, ascending);
}

/// Build cache key for list endpoint
fn buildListCacheKey(
    prefix: []const u8,
    request: *Request,
    user_id: ?i64,
) ![]const u8 {
    const arena = request.arena.allocator();
    
    // Build key string directly
    var key_buf = std.ArrayListUnmanaged(u8){};
    defer key_buf.deinit(arena);
    const writer = key_buf.writer(arena);
    
    try writer.print("{s}:list", .{prefix});
    
    // Add user_id if authenticated
    if (user_id) |uid| {
        try writer.print(":user:{d}", .{uid});
    }
    
    // Add filters
    const filter_params = try request.queryParams();
    var filter_iter = filter_params.iterator();
    var has_filters = false;
    while (filter_iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "filter")) {
            if (!has_filters) {
                try writer.writeAll(":filter");
                has_filters = true;
            }
            try writer.print(":{s}", .{entry.value_ptr.*});
        }
    }
    
    // Add sort
    if (try request.query("sort")) |sort| {
        try writer.print(":sort:{s}", .{sort});
    }
    
    // Add pagination
    const page = (request.queryParamTyped(u32, "page") catch null) orelse 1;
    const limit = (request.queryParamTyped(u32, "limit") catch null) orelse 20;
    try writer.print(":page:{d}:limit:{d}", .{ page, limit });
    
    return try key_buf.toOwnedSlice(arena);
}

/// Build cache key for show endpoint
fn buildShowCacheKey(prefix: []const u8, id: i64, user_id: ?i64) ![]const u8 {
    if (user_id) |uid| {
        return std.fmt.allocPrint(allocator, "{s}:{d}:user:{d}", .{ prefix, id, uid });
    } else {
        return std.fmt.allocPrint(allocator, "{s}:{d}", .{ prefix, id });
    }
}

/// Paginated response structure
fn PaginatedResponse(comptime T: type) type {
    return struct {
        data: []const T,
        meta: PaginationMeta,
    };
}

/// Handler for GET /resource (list endpoint)
fn handleList(
    comptime T: type,
    prefix: []const u8,
    config: RestApiConfig(T),
    request: *Request,
) Response {
    // Check authentication
    var user: ?AuthUser = null;
    if (config.authenticator) |auth_fn| {
        user = auth_fn(request) catch {
            return Response.errorResponse("Authentication required", 401);
        };
    }
    
    // Check cache
    if (config.cache_ttl_ms) |_| {
            const cache_key = buildListCacheKey(prefix, request, if (user) |u| u.id else null) catch null;
            if (cache_key) |key| {
                // Note: key is allocated with request.arena.allocator(), so no manual free needed
                if (request.cacheGet(key) catch null) |entry| {
                return Response.text(entry.body)
                    .withContentType(entry.content_type)
                    .withHeader("X-Cache", "HIT");
            }
        }
    }
    
    // Parse pagination
    const pagination = if (config.enable_pagination)
        Pagination.fromRequest(request) catch {
            return Response.errorResponse("Invalid pagination parameters", 400);
        }
    else
        Pagination{ .page = 1, .limit = 1000, .offset = 0 };
    
    // Build query - get table name using model utilities
    const raw_table_name = model_utils.inferTableName(T);
    var table_name = model_utils.toLowercaseTableName(config.orm.allocator, raw_table_name) catch {
        return Response.serverError("Failed to get table name");
    };
    defer config.orm.allocator.free(table_name);
    
    // Handle special case: "todo" -> "todos"
    if (std.mem.eql(u8, table_name, "todo")) {
        config.orm.allocator.free(table_name);
        table_name = config.orm.allocator.dupe(u8, "todos") catch {
            return Response.serverError("Failed to allocate table name");
        };
    }
    
    var builder = QueryBuilder.init(config.orm.allocator, table_name);
    defer builder.deinit();
    
    // Add filters
    if (config.enable_filtering) {
        parseFilters(T, &builder, request) catch |err| {
            if (err == error.InvalidFieldName) {
                return Response.errorResponse("Invalid filter field name", 400);
            }
            return Response.serverError("Failed to parse filters");
        };
    }
    
    // Add sort
    if (config.enable_sorting) {
        parseSort(T, &builder, request) catch |err| {
            if (err == error.InvalidFieldName) {
                return Response.errorResponse("Invalid sort field name", 400);
            }
            if (err == error.InvalidSortDirection) {
                return Response.errorResponse("Invalid sort direction (must be 'asc' or 'desc')", 400);
            }
        };
    }
    
    // Add pagination
    _ = builder.limit(pagination.limit).offset(pagination.offset);
    
    // Build and execute query
    const sql = builder.build() catch {
        return Response.serverError("Failed to build query");
    };
    defer config.orm.allocator.free(sql);
    
    var query_result = config.orm.query(sql) catch {
        return Response.serverError("Failed to execute query");
    };
    defer query_result.deinit();
    
    var items = query_result.toArrayList(T) catch {
        return Response.serverError("Failed to deserialize results");
    };
    defer {
        for (items.items) |item| {
            inline for (std.meta.fields(T)) |field| {
                const field_type = @TypeOf(@field(item, field.name));
                if (@typeInfo(field_type) == .pointer) {
                    const ptr_info = @typeInfo(field_type).pointer;
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        config.orm.allocator.free(@field(item, field.name));
                    }
                } else if (@typeInfo(field_type) == .optional) {
                    const opt_info = @typeInfo(field_type).optional;
                    if (@typeInfo(opt_info.child) == .pointer) {
                        const ptr_info = @typeInfo(opt_info.child).pointer;
                        if (ptr_info.size == .slice and ptr_info.child == u8) {
                            if (@field(item, field.name)) |val| {
                                config.orm.allocator.free(val);
                            }
                        }
                    }
                }
            }
        }
        items.deinit(config.orm.allocator);
    }
    
    // Get total count for pagination
    var count_builder = QueryBuilder.init(config.orm.allocator, table_name);
    defer count_builder.deinit();
    
    if (config.enable_filtering) {
        // Parse filters for count query - ignore errors as filtering is optional
        // If parsing fails, count query will proceed without filters
        parseFilters(T, &count_builder, request) catch |err| {
            std.debug.print("[REST API] Warning: Failed to parse filters for count query: {}\n", .{err});
        };
    }
    
    // Build COUNT query
    var count_sql_buf = std.ArrayListUnmanaged(u8){};
    defer count_sql_buf.deinit(config.orm.allocator);
    
    count_sql_buf.writer(config.orm.allocator).print("SELECT COUNT(*) as count FROM {s}", .{table_name}) catch {
        return Response.serverError("Failed to build count query");
    };
    
    // Add WHERE clause if filters exist
    if (count_builder.where_clauses.items.len > 0) {
        count_sql_buf.writer(config.orm.allocator).print(" WHERE ", .{}) catch {
            return Response.serverError("Failed to build count query");
        };
        for (count_builder.where_clauses.items, 0..) |clause, i| {
            if (i > 0) count_sql_buf.writer(config.orm.allocator).print(" AND ", .{}) catch {
                return Response.serverError("Failed to build count query");
            };
            var escaped_value = std.ArrayListUnmanaged(u8){};
            defer escaped_value.deinit(config.orm.allocator);
            for (clause.value) |char| {
                if (char == '\'') {
                    // Escaping SQL single quotes - best effort, log if allocation fails
                    escaped_value.append(config.orm.allocator, '\'') catch {
                        std.debug.print("[REST API] Warning: Failed to escape SQL value, skipping character\n", .{});
                        continue;
                    };
                    escaped_value.append(config.orm.allocator, '\'') catch {
                        std.debug.print("[REST API] Warning: Failed to escape SQL value, skipping character\n", .{});
                        continue;
                    };
                } else {
                    escaped_value.append(config.orm.allocator, char) catch {
                        std.debug.print("[REST API] Warning: Failed to escape SQL value, skipping character\n", .{});
                        continue;
                    };
                }
            }
            count_sql_buf.writer(config.orm.allocator).print("{s} {s} '{s}'", .{ clause.field, clause.operator, escaped_value.items }) catch {
                return Response.serverError("Failed to build count query");
            };
        }
    }
    
    const count_sql = count_sql_buf.toOwnedSlice(config.orm.allocator) catch {
        return Response.serverError("Failed to allocate count query");
    };
    defer config.orm.allocator.free(count_sql);
    
    var count_result = config.orm.query(count_sql) catch {
        return Response.serverError("Failed to execute count query");
    };
    defer count_result.deinit();
    
    const count_row = count_result.nextRow() orelse {
        return Response.serverError("Failed to get count");
    };
    const total = count_row.getInt64(0);
    
    // Create paginated response
    const meta = pagination.toResponse(@intCast(total));
    const paginated = PaginatedResponse(T){
        .data = items.items,
        .meta = meta,
    };
    
    const response = Response.jsonFrom(PaginatedResponse(T), paginated, config.orm.allocator);
    
    // Cache the response
    if (config.cache_ttl_ms) |ttl| {
        const cache_key = buildListCacheKey(prefix, request, if (user) |u| u.id else null) catch null;
        if (cache_key) |key| {
            // Note: key is allocated with request.arena.allocator(), so no manual free needed
            const json = json_mod.Json.serialize(PaginatedResponse(T), paginated, config.orm.allocator) catch null;
            if (json) |j| {
                defer config.orm.allocator.free(j);
                const persistent_json = std.heap.page_allocator.dupe(u8, j) catch null;
                if (persistent_json) |pj| {
                    // Cache set is best-effort - log but don't fail request if caching fails
                    request.cacheSet(key, pj, ttl, "application/json") catch |err| {
                        std.debug.print("[REST API] Warning: Failed to cache response: {}\n", .{err});
                    };
                }
            }
        }
    }
    
    return response.withHeader("X-Cache", "MISS");
}

/// Handler for GET /resource/:id (show endpoint)
fn handleShow(
    comptime T: type,
    prefix: []const u8,
    config: RestApiConfig(T),
    request: *Request,
) Response {
    // Check authentication
    var user: ?AuthUser = null;
    if (config.authenticator) |auth_fn| {
        user = auth_fn(request) catch {
            return Response.errorResponse("Authentication required", 401);
        };
    }
    
    // Get ID from route params
    const id = request.paramTyped(i64, "id") catch {
        return Response.errorResponse("Invalid ID", 400);
    };
    
    // Check cache
    if (config.cache_ttl_ms) |_| {
        const cache_key = buildShowCacheKey(prefix, id, if (user) |u| u.id else null) catch null;
        if (cache_key) |key| {
            defer allocator.free(key);
            if (request.cacheGet(key) catch null) |entry| {
                return Response.text(entry.body)
                    .withContentType(entry.content_type)
                    .withHeader("X-Cache", "HIT");
            }
        }
    }
    
    // Find record
    const found = config.orm.find(T, id) catch {
        return Response.serverError("Failed to fetch record");
    };
    
    const record = found orelse {
        return Response.notFound("Record not found");
    };
    defer {
        inline for (std.meta.fields(T)) |field| {
            const field_type = @TypeOf(@field(record, field.name));
            if (@typeInfo(field_type) == .pointer) {
                const ptr_info = @typeInfo(field_type).pointer;
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    config.orm.allocator.free(@field(record, field.name));
                }
            } else if (@typeInfo(field_type) == .optional) {
                const opt_info = @typeInfo(field_type).optional;
                if (@typeInfo(opt_info.child) == .pointer) {
                    const ptr_info = @typeInfo(opt_info.child).pointer;
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        if (@field(record, field.name)) |val| {
                            config.orm.allocator.free(val);
                        }
                    }
                }
            }
        }
    }
    
    // Check authorization
    if (config.authorization) |authz_fn| {
        const allowed = authz_fn(request, record) catch {
            return Response.errorResponse("Authorization failed", 403);
        };
        if (!allowed) {
            return Response.errorResponse("Access denied", 403);
        }
    }
    
    const response = Response.jsonFrom(T, record, config.orm.allocator);
    
    // Cache the response
    if (config.cache_ttl_ms) |ttl| {
        const cache_key = buildShowCacheKey(prefix, id, if (user) |u| u.id else null) catch null;
        if (cache_key) |key| {
            defer allocator.free(key);
            const json = json_mod.Json.serialize(T, record, config.orm.allocator) catch null;
            if (json) |j| {
                defer config.orm.allocator.free(j);
                const persistent_json = std.heap.page_allocator.dupe(u8, j) catch null;
                if (persistent_json) |pj| {
                    // Cache set is best-effort - log but don't fail request if caching fails
                    request.cacheSet(key, pj, ttl, "application/json") catch |err| {
                        std.debug.print("[REST API] Warning: Failed to cache response: {}\n", .{err});
                    };
                }
            }
        }
    }
    
    return response.withHeader("X-Cache", "MISS");
}

/// Handler for POST /resource (create endpoint)
fn handleCreate(
    comptime T: type,
    prefix: []const u8,
    config: RestApiConfig(T),
    request: *Request,
) Response {
    // Check authentication
    var user: ?AuthUser = null;
    if (config.authenticator) |auth_fn| {
        user = auth_fn(request) catch {
            return Response.errorResponse("Authentication required", 401);
        };
    }
    
    // Parse JSON body
    const parsed = request.jsonBody(T) catch {
        return Response.errorResponse("Invalid JSON", 400);
    };
    
    // Validate
    var validation_errors = config.validator(request, parsed) catch {
        return Response.serverError("Validation error");
    };
    defer validation_errors.deinit();
    
    if (!validation_errors.isEmpty()) {
        return Response.validationError(&validation_errors);
    }
    
    // Create record
    // Note: Hooks are not currently supported due to Zig type system limitations
    // Set user_id and timestamps if needed (handled by validator/authorization)
    const model_to_create = parsed;
    
    // Ensure user_id is set (should be done by authenticator/validator)
    // For now, we'll rely on the model being properly constructed
    config.orm.create(T, model_to_create) catch {
        return Response.serverError("Failed to create record");
    };
    
    // Invalidate cache
    if (config.cache_ttl_ms) |_| {
        // Invalidate list cache
        const cache_key = buildListCacheKey(prefix, request, if (user) |u| u.id else null) catch null;
        if (cache_key) |key| {
            // Note: key is allocated with request.arena.allocator(), so no manual free needed
            request.cacheInvalidate(key);
        }
    }
    
    const response = Response.jsonFrom(T, model_to_create, config.orm.allocator);
    return response.withStatus(201);
}

/// Handler for PUT /resource/:id (update endpoint)
fn handleUpdate(
    comptime T: type,
    prefix: []const u8,
    config: RestApiConfig(T),
    request: *Request,
) Response {
    // Check authentication
    var user: ?AuthUser = null;
    if (config.authenticator) |auth_fn| {
        user = auth_fn(request) catch {
            return Response.errorResponse("Authentication required", 401);
        };
    }
    
    // Get ID from route params
    const id = request.paramTyped(i64, "id") catch {
        return Response.errorResponse("Invalid ID", 400);
    };
    
    // Find existing record
    const existing = config.orm.find(T, id) catch {
        return Response.serverError("Failed to fetch record");
    };
    
    const existing_record = existing orelse {
        return Response.notFound("Record not found");
    };
    defer {
        inline for (std.meta.fields(T)) |field| {
            const field_type = @TypeOf(@field(existing_record, field.name));
            if (@typeInfo(field_type) == .pointer) {
                const ptr_info = @typeInfo(field_type).pointer;
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    config.orm.allocator.free(@field(existing_record, field.name));
                }
            } else if (@typeInfo(field_type) == .optional) {
                const opt_info = @typeInfo(field_type).optional;
                if (@typeInfo(opt_info.child) == .pointer) {
                    const ptr_info = @typeInfo(opt_info.child).pointer;
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        if (@field(existing_record, field.name)) |val| {
                            config.orm.allocator.free(val);
                        }
                    }
                }
            }
        }
    }
    
    // Check authorization
    if (config.authorization) |authz_fn| {
        const allowed = authz_fn(request, existing_record) catch {
            return Response.errorResponse("Authorization failed", 403);
        };
        if (!allowed) {
            return Response.errorResponse("Access denied", 403);
        }
    }
    
    // Parse JSON body (partial update)
    const parsed = request.jsonBody(T) catch {
        return Response.errorResponse("Invalid JSON", 400);
    };
    
    // Merge with existing record (copy non-null fields from parsed to existing)
    var updated_record = existing_record;
    inline for (std.meta.fields(T)) |field| {
        const parsed_value = @field(parsed, field.name);
        const field_type = @TypeOf(parsed_value);
        if (@typeInfo(field_type) == .optional) {
            if (parsed_value) |val| {
                @field(updated_record, field.name) = val;
            }
        } else {
            @field(updated_record, field.name) = parsed_value;
        }
    }
    
    // Ensure ID is set
    @field(updated_record, "id") = id;
    
    // Validate
    var validation_errors = config.validator(request, updated_record) catch {
        return Response.serverError("Validation error");
    };
    defer validation_errors.deinit();
    
    if (!validation_errors.isEmpty()) {
        return Response.validationError(&validation_errors);
    }
    
    // Update record
    // Note: Hooks are not currently supported due to Zig type system limitations
    var model_to_update = updated_record;
    
    // Update timestamp if needed
    @field(model_to_update, "updated_at") = std.time.milliTimestamp();
    
    config.orm.update(T, model_to_update) catch {
        return Response.serverError("Failed to update record");
    };
    
    // Invalidate cache
    if (config.cache_ttl_ms) |_| {
        // Invalidate list cache
        const cache_key = buildListCacheKey(prefix, request, if (user) |u| u.id else null) catch null;
        if (cache_key) |key| {
            // Note: key is allocated with request.arena.allocator(), so no manual free needed
            request.cacheInvalidate(key);
        }
        // Invalidate show cache
        const show_cache_key = buildShowCacheKey(prefix, id, if (user) |u| u.id else null) catch null;
        if (show_cache_key) |key| {
            defer allocator.free(key); // buildShowCacheKey uses allocator (page_allocator)
            request.cacheInvalidate(key);
        }
    }
    
    const response = Response.jsonFrom(T, model_to_update, config.orm.allocator);
    return response;
}

/// Handler for DELETE /resource/:id (delete endpoint)
fn handleDelete(
    comptime T: type,
    prefix: []const u8,
    config: RestApiConfig(T),
    request: *Request,
) Response {
    // Check authentication
    var user: ?AuthUser = null;
    if (config.authenticator) |auth_fn| {
        user = auth_fn(request) catch {
            return Response.errorResponse("Authentication required", 401);
        };
    }
    
    // Get ID from route params
    const id = request.paramTyped(i64, "id") catch {
        return Response.errorResponse("Invalid ID", 400);
    };
    
    // Find existing record
    const existing = config.orm.find(T, id) catch {
        return Response.serverError("Failed to fetch record");
    };
    
    const existing_record = existing orelse {
        return Response.notFound("Record not found");
    };
    defer {
        inline for (std.meta.fields(T)) |field| {
            const field_type = @TypeOf(@field(existing_record, field.name));
            if (@typeInfo(field_type) == .pointer) {
                const ptr_info = @typeInfo(field_type).pointer;
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    config.orm.allocator.free(@field(existing_record, field.name));
                }
            } else if (@typeInfo(field_type) == .optional) {
                const opt_info = @typeInfo(field_type).optional;
                if (@typeInfo(opt_info.child) == .pointer) {
                    const ptr_info = @typeInfo(opt_info.child).pointer;
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        if (@field(existing_record, field.name)) |val| {
                            config.orm.allocator.free(val);
                        }
                    }
                }
            }
        }
    }
    
    // Check authorization
    if (config.authorization) |authz_fn| {
        const allowed = authz_fn(request, existing_record) catch {
            return Response.errorResponse("Authorization failed", 403);
        };
        if (!allowed) {
            return Response.errorResponse("Access denied", 403);
        }
    }
    
    // Delete record
    // Note: Hooks are not currently supported due to Zig type system limitations
    config.orm.delete(T, id) catch {
        return Response.serverError("Failed to delete record");
    };
    
    // Invalidate cache
    if (config.cache_ttl_ms) |_| {
        // Invalidate list cache
        const cache_key = buildListCacheKey(prefix, request, if (user) |u| u.id else null) catch null;
        if (cache_key) |key| {
            // Note: key is allocated with request.arena.allocator(), so no manual free needed
            request.cacheInvalidate(key);
        }
        // Invalidate show cache
        const show_cache_key = buildShowCacheKey(prefix, id, if (user) |u| u.id else null) catch null;
        if (show_cache_key) |key| {
            defer allocator.free(key); // buildShowCacheKey uses allocator (page_allocator)
            request.cacheInvalidate(key);
        }
    }
    
    return Response.text("").withStatus(204);
}

/// Global registry for REST API configs (keyed by prefix)
var rest_api_configs: std.StringHashMap(*const anyopaque) = undefined;
var rest_api_configs_mutex: std.Thread.Mutex = .{};
var rest_api_configs_initialized: bool = false;

fn initRestApiConfigs() void {
    if (!rest_api_configs_initialized) {
        rest_api_configs = std.StringHashMap(*const anyopaque).init(allocator);
        rest_api_configs_initialized = true;
    }
}

/// Register RESTful API endpoints for a model
/// Generates: GET /prefix, GET /prefix/:id, POST /prefix, PUT /prefix/:id, DELETE /prefix/:id
pub fn restApi(
    app: *@import("engine12.zig").Engine12,
    comptime prefix: []const u8,
    comptime Model: type,
    config: RestApiConfig(Model),
) !void {
    initRestApiConfigs();
    
    // Store config in global registry (allocate on heap so it persists)
    const config_ptr = try allocator.create(RestApiConfig(Model));
    config_ptr.* = config;
    
    rest_api_configs_mutex.lock();
    defer rest_api_configs_mutex.unlock();
    try rest_api_configs.put(prefix, config_ptr);
    
    // Register GET /prefix (list)
    try app.get(prefix, struct {
        const model_type = Model;
        const api_prefix = prefix;
        fn handler(req: *Request) Response {
            rest_api_configs_mutex.lock();
            defer rest_api_configs_mutex.unlock();
            const config_ptr_opt = rest_api_configs.get(api_prefix) orelse {
                return Response.serverError("REST API config not found");
            };
            const api_config = @as(*const RestApiConfig(model_type), @ptrCast(@alignCast(config_ptr_opt))).*;
            return handleList(model_type, api_prefix, api_config, req);
        }
    }.handler);
    
    // Register GET /prefix/:id (show)
    const show_path = comptime prefix ++ "/:id";
    try app.get(show_path, struct {
        const model_type = Model;
        const api_prefix = prefix;
        fn handler(req: *Request) Response {
            rest_api_configs_mutex.lock();
            defer rest_api_configs_mutex.unlock();
            const config_ptr_opt = rest_api_configs.get(api_prefix) orelse {
                return Response.serverError("REST API config not found");
            };
            const api_config = @as(*const RestApiConfig(model_type), @ptrCast(@alignCast(config_ptr_opt))).*;
            return handleShow(model_type, api_prefix, api_config, req);
        }
    }.handler);
    
    // Register POST /prefix (create)
    try app.post(prefix, struct {
        const model_type = Model;
        const api_prefix = prefix;
        fn handler(req: *Request) Response {
            rest_api_configs_mutex.lock();
            defer rest_api_configs_mutex.unlock();
            const config_ptr_opt = rest_api_configs.get(api_prefix) orelse {
                return Response.serverError("REST API config not found");
            };
            const api_config = @as(*const RestApiConfig(model_type), @ptrCast(@alignCast(config_ptr_opt))).*;
            return handleCreate(model_type, api_prefix, api_config, req);
        }
    }.handler);
    
    // Register PUT /prefix/:id (update)
    const update_path = comptime prefix ++ "/:id";
    try app.put(update_path, struct {
        const model_type = Model;
        const api_prefix = prefix;
        fn handler(req: *Request) Response {
            rest_api_configs_mutex.lock();
            defer rest_api_configs_mutex.unlock();
            const config_ptr_opt = rest_api_configs.get(api_prefix) orelse {
                return Response.serverError("REST API config not found");
            };
            const api_config = @as(*const RestApiConfig(model_type), @ptrCast(@alignCast(config_ptr_opt))).*;
            return handleUpdate(model_type, api_prefix, api_config, req);
        }
    }.handler);
    
    // Register DELETE /prefix/:id (delete)
    const delete_path = comptime prefix ++ "/:id";
    try app.delete(delete_path, struct {
        const model_type = Model;
        const api_prefix = prefix;
        fn handler(req: *Request) Response {
            rest_api_configs_mutex.lock();
            defer rest_api_configs_mutex.unlock();
            const config_ptr_opt = rest_api_configs.get(api_prefix) orelse {
                return Response.serverError("REST API config not found");
            };
            const api_config = @as(*const RestApiConfig(model_type), @ptrCast(@alignCast(config_ptr_opt))).*;
            return handleDelete(model_type, api_prefix, api_config, req);
        }
    }.handler);
}

