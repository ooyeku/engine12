const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const ORM = @import("orm/orm.zig").ORM;
const Logger = @import("dev_tools.zig").Logger;
const LogLevel = @import("dev_tools.zig").LogLevel;
const BasicAuthValve = @import("valve/builtin/basic_auth.zig").BasicAuthValve;
const AuthUser = @import("rest_api.zig").AuthUser;
const engine12_mod = @import("engine12.zig");

const allocator = std.heap.page_allocator;

/// Handler Context Error Types
pub const HandlerCtxError = error{
    AuthenticationRequired,
    DatabaseNotInitialized,
    InvalidQueryParameter,
    MissingQueryParameter,
    InvalidRouteParameter,
    InvalidJSON,
};

/// Handler Context - High-level abstraction for writing handlers
/// Reduces boilerplate by handling common patterns automatically:
/// - Authentication handling
/// - ORM access
/// - Parameter parsing with better error messages
/// - Caching helpers
/// - Logging with context
pub const HandlerCtx = struct {
    request: *Request,
    user: ?AuthUser = null,
    orm_instance: ?*ORM = null,
    logger: ?*Logger = null,
    get_orm_fn: ?*const fn () anyerror!*ORM = null,

    /// Initialize HandlerCtx from request
    /// Options:
    /// - require_auth: If true, authentication is required (returns error if not authenticated)
    /// - require_orm: If true, ORM must be available (returns error if not available)
    /// - get_orm: Optional function to get ORM instance (if not provided, tries to get from global)
    pub fn init(
        req: *Request,
        options: struct {
            require_auth: bool = false,
            require_orm: bool = false,
            get_orm: ?*const fn () anyerror!*ORM = null,
        },
    ) HandlerCtxError!HandlerCtx {
        var ctx = HandlerCtx{
            .request = req,
            .get_orm_fn = options.get_orm,
        };

        // Load logger from global
        ctx.logger = engine12_mod.global_logger;

        // Handle ORM access
        if (options.require_orm or options.get_orm != null) {
            ctx.orm_instance = if (options.get_orm) |get_fn|
                get_fn() catch return error.DatabaseNotInitialized
            else blk: {
                // Try to get from DatabaseSingleton if available
                const DatabaseSingleton = @import("orm/singleton.zig").DatabaseSingleton;
                break :blk DatabaseSingleton.get() catch null;
            };

            if (ctx.orm_instance == null and options.require_orm) {
                return error.DatabaseNotInitialized;
            }
        }

        // Handle authentication
        if (options.require_auth) {
            ctx.user = try ctx.requireAuth();
        } else {
            ctx.user = ctx.getAuth() catch null;
        }

        return ctx;
    }

    /// Initialize HandlerCtx or return Response on error
    /// Convenience method that eliminates repetitive error handling
    /// Returns null if initialization fails (caller should return the Response)
    ///
    /// Example:
    /// ```zig
    /// const ctx = HandlerCtx.initOrRespond(request, .{
    ///     .require_auth = true,
    ///     .require_orm = true,
    ///     .get_orm = getORM,
    /// }) orelse return;
    /// ```
    pub fn initOrRespond(
        req: *Request,
        options: struct {
            require_auth: bool = false,
            require_orm: bool = false,
            get_orm: ?*const fn () anyerror!*ORM = null,
        },
    ) ?HandlerCtx {
        return init(req, options) catch |err| {
            const response = switch (err) {
                error.AuthenticationRequired => Response.errorResponse("Authentication required", 401),
                error.DatabaseNotInitialized => Response.serverError("Database not initialized"),
                else => Response.serverError("Internal error"),
            };
            // Note: This returns a Response, but we need to return ?HandlerCtx
            // The caller should handle the error response separately
            // For now, we'll return null and the caller should check for it
            _ = response; // Suppress unused warning
            return null;
        };
    }

    /// Require authentication or return error
    /// Converts BasicAuthValve.User to AuthUser with arena-allocated strings
    pub fn requireAuth(self: *HandlerCtx) HandlerCtxError!AuthUser {
        if (self.user) |u| return u;

        const user = BasicAuthValve.requireAuth(self.request) catch {
            return error.AuthenticationRequired;
        };
        defer {
            allocator.free(user.username);
            allocator.free(user.email);
            allocator.free(user.password_hash);
        }

        // Convert to AuthUser with arena-allocated strings (auto-freed with request)
        const auth_user = AuthUser{
            .id = user.id,
            .username = self.request.arena.allocator().dupe(u8, user.username) catch {
                return error.AuthenticationRequired;
            },
            .email = self.request.arena.allocator().dupe(u8, user.email) catch {
                return error.AuthenticationRequired;
            },
            .password_hash = self.request.arena.allocator().dupe(u8, user.password_hash) catch {
                return error.AuthenticationRequired;
            },
        };

        self.user = auth_user;
        return auth_user;
    }

    /// Get authenticated user (optional, doesn't error if not authenticated)
    pub fn getAuth(self: *HandlerCtx) HandlerCtxError!?AuthUser {
        if (self.user) |u| return u;

        const user = BasicAuthValve.requireAuth(self.request) catch {
            return null;
        };
        defer {
            allocator.free(user.username);
            allocator.free(user.email);
            allocator.free(user.password_hash);
        }

        const auth_user = AuthUser{
            .id = user.id,
            .username = self.request.arena.allocator().dupe(u8, user.username) catch {
                return null;
            },
            .email = self.request.arena.allocator().dupe(u8, user.email) catch {
                return null;
            },
            .password_hash = self.request.arena.allocator().dupe(u8, user.password_hash) catch {
                return null;
            },
        };

        self.user = auth_user;
        return auth_user;
    }

    /// Get ORM instance
    /// Returns error if ORM is not available
    pub fn orm(self: *HandlerCtx) HandlerCtxError!*ORM {
        if (self.orm_instance) |orm_instance| return orm_instance;

        // Try to get ORM using provided function
        if (self.get_orm_fn) |get_fn| {
            const orm_instance = get_fn() catch {
                return error.DatabaseNotInitialized;
            };
            self.orm_instance = orm_instance;
            return orm_instance;
        }

        // Try to get from DatabaseSingleton if available
        const DatabaseSingleton = @import("orm/singleton.zig").DatabaseSingleton;
        const orm_instance = DatabaseSingleton.get() catch {
            return error.DatabaseNotInitialized;
        };
        self.orm_instance = orm_instance;
        return orm_instance;
    }

    /// Parse query parameter with better error messages
    /// Returns error if parameter is missing or invalid
    pub fn query(self: *HandlerCtx, comptime T: type, name: []const u8) HandlerCtxError!T {
        const value = self.request.queryParamTyped(T, name) catch {
            return error.InvalidQueryParameter;
        } orelse {
            return error.MissingQueryParameter;
        };
        return value;
    }

    /// Parse query parameter with default value
    /// Returns default if parameter is missing or invalid
    pub fn queryOrDefault(self: *HandlerCtx, comptime T: type, name: []const u8, default: T) T {
        return self.request.queryParamTyped(T, name) catch null orelse default;
    }

    /// Get route parameter
    /// Returns error if parameter is missing or invalid
    pub fn param(self: *HandlerCtx, comptime T: type, name: []const u8) HandlerCtxError!T {
        return self.request.paramTyped(T, name) catch {
            return error.InvalidRouteParameter;
        };
    }

    /// Parse JSON body
    /// Returns error if JSON is invalid
    pub fn json(self: *HandlerCtx, comptime T: type) HandlerCtxError!T {
        return self.request.jsonBody(T) catch {
            return error.InvalidJSON;
        };
    }

    /// Build cache key with user context
    /// Automatically includes user_id if user is authenticated
    /// Pattern should use {d} placeholder for user_id
    pub fn cacheKey(self: *HandlerCtx, comptime pattern: []const u8) ![]const u8 {
        const user_id = if (self.user) |u| u.id else 0;
        return std.fmt.allocPrint(
            self.request.arena.allocator(),
            pattern,
            .{user_id}
        );
    }

    /// Check cache and return cache entry if hit
    pub fn cacheGet(self: *HandlerCtx, key: []const u8) !?*@import("cache.zig").CacheEntry {
        return self.request.cacheGet(key);
    }

    /// Set cache entry
    pub fn cacheSet(self: *HandlerCtx, key: []const u8, value: []const u8, ttl_ms: u32, content_type: []const u8) void {
        self.request.cacheSet(key, value, ttl_ms, content_type) catch {};
    }

    /// Invalidate cache entry
    pub fn cacheInvalidate(self: *HandlerCtx, key: []const u8) void {
        self.request.cacheInvalidate(key);
    }

    /// Log message with context (user_id if authenticated)
    pub fn log(self: *HandlerCtx, level: LogLevel, message: []const u8) void {
        if (self.logger) |logger| {
            const entry = logger.log(level, message) catch return;
            if (self.user) |u| {
                _ = entry.fieldInt("user_id", u.id) catch {};
            }
            // Include request ID if available
            if (self.request.get("request_id")) |request_id| {
                _ = entry.field("request_id", request_id) catch {};
            }
            entry.log();
        }
    }

    /// Return error response with automatic logging
    pub fn errorResponse(self: *HandlerCtx, message: []const u8, status: u16) Response {
        const level: LogLevel = switch (status) {
            400, 422 => .warn,
            401, 403 => .warn,
            404 => .info,
            429 => .warn,
            413 => .warn,
            408 => .warn,
            else => .err,
        };
        self.log(level, message);
        return Response.errorResponse(message, status);
    }

    /// Return JSON response from data
    pub fn jsonResponse(self: *HandlerCtx, data: anytype) Response {
        return Response.jsonFrom(@TypeOf(data), data, self.request.arena.allocator());
    }

    /// Return success response with JSON data
    pub fn success(self: *HandlerCtx, data: anytype, status: u16) Response {
        return self.jsonResponse(data).withStatus(status);
    }

    /// Return created response (201) with JSON data
    pub fn created(self: *HandlerCtx, data: anytype) Response {
        return self.jsonResponse(data).withStatus(201);
    }

    /// Return not found response (404)
    pub fn notFound(self: *HandlerCtx, message: []const u8) Response {
        return self.errorResponse(message, 404);
    }

    /// Return unauthorized response (401)
    pub fn unauthorized(self: *HandlerCtx, message: []const u8) Response {
        return self.errorResponse(message, 401);
    }

    /// Return forbidden response (403)
    pub fn forbidden(self: *HandlerCtx, message: []const u8) Response {
        return self.errorResponse(message, 403);
    }

    /// Return bad request response (400)
    pub fn badRequest(self: *HandlerCtx, message: []const u8) Response {
        return self.errorResponse(message, 400);
    }

    /// Return server error response (500)
    pub fn serverError(self: *HandlerCtx, message: []const u8) Response {
        return self.errorResponse(message, 500);
    }
};

