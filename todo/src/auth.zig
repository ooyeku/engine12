const std = @import("std");
const E12 = @import("engine12");
const Request = E12.Request;
const AuthUser = E12.AuthUser;
const BasicAuthValve = E12.BasicAuthValve;
const models = @import("models.zig");
const Todo = models.Todo;

const allocator = std.heap.page_allocator;

/// Require authentication for REST API endpoints
/// Converts BasicAuthValve.User to AuthUser with arena-allocated strings
pub fn requireAuthForRestApi(req: *Request) !AuthUser {
    const user = BasicAuthValve.requireAuth(req) catch {
        return error.AuthenticationRequired;
    };

    // Convert BasicAuthValve.User to AuthUser
    // Note: AuthUser fields will be freed by the caller
    return AuthUser{
        .id = user.id,
        .username = try req.arena.allocator().dupe(u8, user.username),
        .email = try req.arena.allocator().dupe(u8, user.email),
        .password_hash = try req.arena.allocator().dupe(u8, user.password_hash),
    };
}

/// Check if the authenticated user can access a todo
/// Returns true if user can access the resource, false otherwise
pub fn canAccessTodo(req: *Request, todo: Todo) !bool {
    const user = BasicAuthValve.requireAuth(req) catch {
        return false;
    };
    defer {
        allocator.free(user.username);
        allocator.free(user.email);
        allocator.free(user.password_hash);
    }

    // User can only access their own todos
    return todo.user_id == user.id;
}
