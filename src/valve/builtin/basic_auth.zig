const std = @import("std");
const valve = @import("../valve.zig");
const Valve = valve.Valve;
const ValveCapability = valve.ValveCapability;
const context = @import("../context.zig");
const ValveContext = context.ValveContext;
const Request = @import("../../request.zig").Request;
const Response = @import("../../response.zig").Response;
const middleware = @import("../../middleware.zig");
const orm = @import("../../orm/orm.zig");
const ORM = orm.ORM;
const Model = orm.Model;
const ModelWithORM = orm.ModelWithORM;
const Migration = @import("../../orm/migration.zig").Migration;
const SqlEscape = orm.SqlEscape;
const jwt = @import("jwt.zig");
const Claims = jwt.Claims;
const password = @import("password.zig");
const json_module = @import("../../json.zig");

/// User model for authentication
pub const User = struct {
    id: i64,
    username: []const u8,
    email: []const u8,
    password_hash: []const u8,
    created_at: i64,
};

/// User input for registration/login
const UserInput = struct {
    username: ?[]const u8,
    email: ?[]const u8,
    password: ?[]const u8,
};

/// Login response
const LoginResponse = struct {
    token: []const u8,
    expires_in: i64,
    user: struct {
        id: i64,
        username: []const u8,
        email: []const u8,
    },
};

/// Basic Auth Valve configuration
pub const BasicAuthConfig = struct {
    /// JWT secret key (required)
    secret_key: []const u8,
    /// Token expiration in seconds (default: 3600)
    token_expiry_seconds: i64 = 3600,
    /// User table name (default: "users")
    user_table_name: []const u8 = "users",
    /// ORM instance (required)
    orm: *ORM,
};

/// Production-ready JWT-based authentication valve
/// Provides user registration, login, logout, and authentication middleware
pub const BasicAuthValve = struct {
    valve: Valve,
    config: BasicAuthConfig,
    user_model: ModelWithORM(User),

    const Self = @This();

    // Global registry for valve instances (one per valve name)
    var global_registry: ?*Self = null;
    var registry_mutex: std.Thread.Mutex = .{};

    /// Initialize BasicAuthValve
    ///
    /// Example:
    /// ```zig
    /// var auth_valve = BasicAuthValve.init(.{
    ///     .secret_key = "my-secret-key",
    ///     .orm = orm_instance,
    /// });
    /// try app.registerValve(&auth_valve.valve);
    /// ```
    pub fn init(config: BasicAuthConfig) Self {
        return Self{
            .valve = Valve{
                .metadata = valve.ValveMetadata{
                    .name = "basic_auth",
                    .version = "1.0.0",
                    .description = "JWT-based authentication valve with user management",
                    .author = "Engine12 Team",
                    .required_capabilities = &[_]ValveCapability{ .routes, .middleware, .database_access },
                },
                .init = &Self.initValve,
                .deinit = &Self.deinitValve,
                .onAppStart = &Self.onAppStart,
                .onAppStop = null,
            },
            .config = config,
            .user_model = ModelWithORM(User).init(config.orm),
        };
    }

    /// Valve initialization - register routes and middleware
    pub fn initValve(v: *Valve, ctx: *ValveContext) !void {
        const offset = @offsetOf(BasicAuthValve, "valve");
        const addr = @intFromPtr(v) - offset;
        const self = @as(*BasicAuthValve, @ptrFromInt(addr));

        // Store instance in global registry
        registry_mutex.lock();
        defer registry_mutex.unlock();
        global_registry = self;

        // Note: Route registration through ctx.registerRoute() is not yet implemented
        // Routes must be registered directly on the app using app.post(), app.get(), etc.
        // The handlers (handleRegister, handleLogin, etc.) can be called directly.

        // Register authentication middleware
        try ctx.registerMiddleware(&Self.authMiddleware);
    }

    /// Valve cleanup
    pub fn deinitValve(v: *Valve) void {
        registry_mutex.lock();
        defer registry_mutex.unlock();
        global_registry = null;
        _ = v;
    }

    /// Called when app starts - run migrations
    pub fn onAppStart(v: *Valve, ctx: *ValveContext) !void {
        const offset = @offsetOf(BasicAuthValve, "valve");
        const addr = @intFromPtr(v) - offset;
        const self = @as(*BasicAuthValve, @ptrFromInt(addr));

        // Run migration to create users table
        try self.runMigration(ctx.allocator);
    }

    /// Run database migration to create users table
    fn runMigration(self: *Self, allocator: std.mem.Allocator) !void {
        // Create table directly - simpler and more reliable for built-in valve
        const create_table_sql = try std.fmt.allocPrint(allocator,
            \\CREATE TABLE IF NOT EXISTS {s} (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  username TEXT UNIQUE NOT NULL,
            \\  email TEXT UNIQUE NOT NULL,
            \\  password_hash TEXT NOT NULL,
            \\  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_users_username ON {s}(username);
            \\CREATE INDEX IF NOT EXISTS idx_users_email ON {s}(email);
        , .{ self.config.user_table_name, self.config.user_table_name, self.config.user_table_name });
        defer allocator.free(create_table_sql);

        // Execute the SQL directly
        self.config.orm.db.execute(create_table_sql) catch |err| {
            return err;
        };
    }

    /// Authentication middleware
    /// Extracts JWT token from Authorization header and validates it
    fn authMiddleware(req: *Request) middleware.MiddlewareResult {
        const auth_header = req.header("Authorization") orelse {
            // No auth header - allow through (some routes may be public)
            return .proceed;
        };

        if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
            return .proceed; // Invalid format, but allow through
        }

        const token_slice = auth_header["Bearer ".len..];
        if (token_slice.len == 0) {
            return .proceed;
        }

        // Duplicate the token so it persists beyond the header's lifetime
        // The token is stored in the request arena, which persists for the request duration
        const token = req.arena.allocator().dupe(u8, token_slice) catch {
            // If allocation fails, just proceed without storing token
            return .proceed;
        };

        // Store token in context for later validation
        req.context.put("auth_token", token) catch {
            return .proceed;
        };

        return .proceed;
    }

    /// Handle user registration
    pub fn handleRegister(req: *Request) Response {
        const self = Self.getInstance(req) orelse {
            return Response.errorResponse("Authentication valve not initialized", 500);
        };

        const allocator = req.arena.allocator();

        // Parse request body
        const body = req.body();
        const input = json_module.Json.deserialize(UserInput, body, allocator) catch {
            return Response.errorResponse("Invalid request body", 400);
        };

        // Validate input
        const username = input.username orelse {
            return Response.errorResponse("Username is required", 400);
        };
        const email = input.email orelse {
            return Response.errorResponse("Email is required", 400);
        };
        const pwd = input.password orelse {
            return Response.errorResponse("Password is required", 400);
        };

        // Validate username length
        if (username.len < 3 or username.len > 50) {
            return Response.errorResponse("Username must be between 3 and 50 characters", 400);
        }

        // Validate password length
        if (pwd.len < 6) {
            return Response.errorResponse("Password must be at least 6 characters", 400);
        }

        // Hash password (use ORM allocator for persistent storage)
        const password_hash = password.hash(pwd, self.config.orm.allocator) catch {
            return Response.serverError("Failed to hash password");
        };
        defer self.config.orm.allocator.free(password_hash);

        // Check if user already exists using raw SQL with configured table name
        const check_sql = std.fmt.allocPrint(
            allocator,
            "SELECT * FROM {s}",
            .{self.config.user_table_name},
        ) catch {
            return Response.serverError("Failed to allocate memory");
        };
        defer allocator.free(check_sql);

        var check_result = self.config.orm.db.query(check_sql) catch {
            return Response.serverError("Failed to query users");
        };
        defer check_result.deinit();

        var all_users = check_result.toArrayList(User) catch {
            return Response.serverError("Failed to parse user data");
        };
        defer {
            for (all_users.items) |user| {
                self.config.orm.allocator.free(user.username);
                self.config.orm.allocator.free(user.email);
                self.config.orm.allocator.free(user.password_hash);
            }
            all_users.deinit(self.config.orm.allocator);
        }

        for (all_users.items) |user| {
            if (std.mem.eql(u8, user.username, username)) {
                return Response.errorResponse("Username already exists", 409);
            }
            if (std.mem.eql(u8, user.email, email)) {
                return Response.errorResponse("Email already exists", 409);
            }
        }

        // Copy username and email to persistent memory (ORM allocator)
        const username_copy = self.config.orm.allocator.dupe(u8, username) catch {
            return Response.serverError("Failed to allocate username");
        };
        errdefer self.config.orm.allocator.free(username_copy);

        const email_copy = self.config.orm.allocator.dupe(u8, email) catch {
            self.config.orm.allocator.free(username_copy);
            return Response.serverError("Failed to allocate email");
        };
        errdefer self.config.orm.allocator.free(email_copy);

        // Create user using raw SQL with configured table name
        const now = std.time.timestamp();

        // Escape strings for SQL
        const escaped_username = SqlEscape.escapeString(allocator, username_copy) catch {
            self.config.orm.allocator.free(username_copy);
            self.config.orm.allocator.free(email_copy);
            return Response.serverError("Failed to escape username");
        };
        defer allocator.free(escaped_username);
        const escaped_email = SqlEscape.escapeString(allocator, email_copy) catch {
            self.config.orm.allocator.free(username_copy);
            self.config.orm.allocator.free(email_copy);
            return Response.serverError("Failed to escape email");
        };
        defer allocator.free(escaped_email);
        const escaped_password_hash = SqlEscape.escapeString(allocator, password_hash) catch {
            self.config.orm.allocator.free(username_copy);
            self.config.orm.allocator.free(email_copy);
            return Response.serverError("Failed to escape password hash");
        };
        defer allocator.free(escaped_password_hash);

        const insert_sql = std.fmt.allocPrint(
            allocator,
            "INSERT INTO {s} (username, email, password_hash, created_at) VALUES ('{s}', '{s}', '{s}', {d})",
            .{ self.config.user_table_name, escaped_username, escaped_email, escaped_password_hash, now },
        ) catch {
            self.config.orm.allocator.free(username_copy);
            self.config.orm.allocator.free(email_copy);
            return Response.serverError("Failed to allocate memory");
        };
        defer allocator.free(insert_sql);

        self.config.orm.db.execute(insert_sql) catch {
            self.config.orm.allocator.free(username_copy);
            self.config.orm.allocator.free(email_copy);
            // Check if user already exists (we checked earlier, but handle race condition)
            return Response.errorResponse("Failed to create user", 500);
        };

        // Get the created user's ID
        _ = self.config.orm.db.lastInsertRowId() catch {
            self.config.orm.allocator.free(username_copy);
            self.config.orm.allocator.free(email_copy);
            return Response.errorResponse("Failed to get created user ID", 500);
        };

        // Return success - user created (frontend will automatically log in)
        return Response.created();
    }

    /// Handle user login
    pub fn handleLogin(req: *Request) Response {
        const self = Self.getInstance(req) orelse {
            return Response.errorResponse("Authentication valve not initialized", 500);
        };

        const allocator = req.arena.allocator();

        // Parse request body
        const body = req.body();
        const input = json_module.Json.deserialize(UserInput, body, allocator) catch {
            return Response.errorResponse("Invalid request body", 400);
        };

        // Get username/email and password
        const username_or_email = input.username orelse input.email orelse {
            return Response.errorResponse("Username or email is required", 400);
        };
        const pwd = input.password orelse {
            return Response.errorResponse("Password is required", 400);
        };

        // Find user by username or email using raw SQL with configured table name
        const find_sql = std.fmt.allocPrint(
            allocator,
            "SELECT * FROM {s}",
            .{self.config.user_table_name},
        ) catch {
            return Response.serverError("Failed to allocate memory");
        };
        defer allocator.free(find_sql);

        var find_result = self.config.orm.db.query(find_sql) catch {
            return Response.serverError("Failed to query users");
        };
        defer find_result.deinit();

        var all_users = find_result.toArrayList(User) catch {
            return Response.serverError("Failed to parse user data");
        };
        defer {
            for (all_users.items) |user| {
                self.config.orm.allocator.free(user.username);
                self.config.orm.allocator.free(user.email);
                self.config.orm.allocator.free(user.password_hash);
            }
            all_users.deinit(self.config.orm.allocator);
        }

        var found_user: ?User = null;
        var found_user_index: ?usize = null;
        for (all_users.items, 0..) |user, i| {
            if (std.mem.eql(u8, user.username, username_or_email) or std.mem.eql(u8, user.email, username_or_email)) {
                found_user = user;
                found_user_index = i;
                break;
            }
        }

        const user = found_user orelse {
            return Response.errorResponse("Invalid username or password", 401);
        };

        // Copy user data we need before all_users is freed
        const user_id = user.id;
        const user_username = allocator.dupe(u8, user.username) catch {
            return Response.serverError("Failed to allocate username");
        };
        defer allocator.free(user_username);
        const user_email = allocator.dupe(u8, user.email) catch {
            return Response.serverError("Failed to allocate email");
        };
        defer allocator.free(user_email);
        const user_password_hash = allocator.dupe(u8, user.password_hash) catch {
            return Response.serverError("Failed to allocate password hash");
        };
        defer allocator.free(user_password_hash);

        // Verify password
        const password_valid = password.verify(pwd, user_password_hash);
        if (!password_valid) {
            return Response.errorResponse("Invalid username or password", 401);
        }

        // Generate JWT token
        const now = std.time.timestamp();
        const claims = Claims{
            .user_id = user_id,
            .username = user_username,
            .exp = now + self.config.token_expiry_seconds,
        };

        const token = jwt.encode(claims, self.config.secret_key, allocator) catch {
            return Response.serverError("Failed to generate token");
        };
        defer allocator.free(token);

        // Copy token to persistent memory for response
        const persistent_token = std.heap.page_allocator.dupe(u8, token) catch {
            return Response.serverError("Failed to allocate token");
        };

        // Copy username and email to persistent memory (already copied above, but need persistent versions)
        const persistent_username = std.heap.page_allocator.dupe(u8, user_username) catch {
            std.heap.page_allocator.free(persistent_token);
            return Response.serverError("Failed to allocate username");
        };
        const persistent_email = std.heap.page_allocator.dupe(u8, user_email) catch {
            std.heap.page_allocator.free(persistent_token);
            std.heap.page_allocator.free(persistent_username);
            return Response.serverError("Failed to allocate email");
        };

        // Create response with persistent strings
        const login_response = LoginResponse{
            .token = persistent_token,
            .expires_in = self.config.token_expiry_seconds,
            .user = .{
                .id = user_id,
                .username = persistent_username,
                .email = persistent_email,
            },
        };

        // Serialize to JSON (need to copy to persistent memory)
        const json_str = json_module.Json.serialize(LoginResponse, login_response, allocator) catch {
            std.heap.page_allocator.free(persistent_token);
            std.heap.page_allocator.free(persistent_username);
            std.heap.page_allocator.free(persistent_email);
            return Response.serverError("Failed to serialize response");
        };
        defer allocator.free(json_str);

        const persistent_json = std.heap.page_allocator.dupe(u8, json_str) catch {
            std.heap.page_allocator.free(persistent_token);
            std.heap.page_allocator.free(persistent_username);
            std.heap.page_allocator.free(persistent_email);
            return Response.serverError("Failed to allocate response");
        };

        return Response.json(persistent_json);
    }

    /// Handle logout
    pub fn handleLogout(req: *Request) Response {
        _ = req;
        // JWT tokens are stateless, so logout is just a success response
        // In a real implementation, you might want to maintain a token blacklist
        return Response.ok();
    }

    /// Handle get current user
    pub fn handleGetMe(req: *Request) Response {
        const self = Self.getInstance(req) orelse {
            return Response.errorResponse("Authentication valve not initialized", 500);
        };

        const allocator = req.arena.allocator();

        // Get token from context (set by middleware)
        const token = req.context.get("auth_token") orelse {
            return Response.errorResponse("Unauthorized", 401);
        };

        // Decode and validate token
        const claims = jwt.decode(token, self.config.secret_key, allocator) catch {
            return Response.errorResponse("Invalid or expired token", 401);
        };
        defer allocator.free(claims.username);

        // Find user using raw SQL with configured table name
        // (ModelWithORM uses inferTableName which returns "user" but table is "users")
        const sql = std.fmt.allocPrint(
            allocator,
            "SELECT * FROM {s} WHERE id = {d}",
            .{ self.config.user_table_name, claims.user_id },
        ) catch {
            return Response.serverError("Failed to allocate SQL");
        };
        defer allocator.free(sql);

        var result = self.config.orm.db.query(sql) catch {
            return Response.serverError("Failed to query user");
        };
        defer result.deinit();

        var users = result.toArrayList(User) catch {
            return Response.serverError("Failed to parse user data");
        };
        defer {
            for (users.items) |u| {
                self.config.orm.allocator.free(u.username);
                self.config.orm.allocator.free(u.email);
                self.config.orm.allocator.free(u.password_hash);
            }
            users.deinit(self.config.orm.allocator);
        }

        const user = if (users.items.len > 0) users.items[0] else {
            return Response.errorResponse("User not found", 404);
        };

        // Copy strings to persistent allocator for response
        const user_username = std.heap.page_allocator.dupe(u8, user.username) catch {
            return Response.serverError("Failed to allocate username");
        };
        const user_email = std.heap.page_allocator.dupe(u8, user.email) catch {
            std.heap.page_allocator.free(user_username);
            return Response.serverError("Failed to allocate email");
        };

        // Return user info (without password_hash)
        const user_response = struct {
            id: i64,
            username: []const u8,
            email: []const u8,
            created_at: i64,
        }{
            .id = user.id,
            .username = user_username,
            .email = user_email,
            .created_at = user.created_at,
        };

        return Response.jsonFrom(@TypeOf(user_response), user_response, std.heap.page_allocator);
    }

    /// Get current user from request context
    /// Returns null if not authenticated
    /// Note: User strings are allocated with ORM allocator and must be freed by caller
    pub fn getCurrentUser(req: *Request) !?User {
        const self = Self.getInstance(req) orelse {
            return null;
        };

        const token = req.context.get("auth_token") orelse {
            return null;
        };

        const allocator = req.arena.allocator();

        const claims = jwt.decode(token, self.config.secret_key, allocator) catch {
            return null;
        };
        defer allocator.free(claims.username);

        // Use raw SQL with configured table name instead of ModelWithORM
        // because ModelWithORM uses inferTableName which returns "user" but table is "users"
        const sql = try std.fmt.allocPrint(
            allocator,
            "SELECT * FROM {s} WHERE id = {d}",
            .{ self.config.user_table_name, claims.user_id },
        );
        defer allocator.free(sql);

        var result = self.config.orm.db.query(sql) catch {
            return null;
        };
        defer result.deinit();

        var users = result.toArrayList(User) catch {
            return null;
        };
        defer {
            for (users.items) |user| {
                self.config.orm.allocator.free(user.username);
                self.config.orm.allocator.free(user.email);
                self.config.orm.allocator.free(user.password_hash);
            }
            users.deinit(self.config.orm.allocator);
        }

        if (users.items.len > 0) {
            const user = users.items[0];
            // Copy strings to ORM allocator (caller will free them)
            return User{
                .id = user.id,
                .username = try self.config.orm.allocator.dupe(u8, user.username),
                .email = try self.config.orm.allocator.dupe(u8, user.email),
                .password_hash = try self.config.orm.allocator.dupe(u8, user.password_hash),
                .created_at = user.created_at,
            };
        }

        return null;
    }

    /// Require authentication or return error response
    /// Returns the authenticated user or an error response
    /// Note: User strings are allocated with ORM allocator and must be freed by caller
    pub fn requireAuth(req: *Request) !User {
        const user_opt = try getCurrentUser(req);
        const user = user_opt orelse {
            return error.Unauthorized;
        };
        return user;
    }

    /// Get valve instance from global registry
    fn getInstance(_: *Request) ?*Self {
        registry_mutex.lock();
        defer registry_mutex.unlock();
        return global_registry;
    }
};
