const std = @import("std");

/// JWT Claims structure
pub const Claims = struct {
    /// User ID
    user_id: i64,
    /// Username
    username: []const u8,
    /// Expiration timestamp (Unix epoch seconds)
    exp: i64,
};

/// JWT encoding/decoding errors
pub const JwtError = error{
    InvalidToken,
    ExpiredToken,
    InvalidSignature,
    EncodingError,
};

/// Base64url encode (URL-safe base64)
fn base64urlEncode(data: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const encoded = try std.base64.standard.Encoder.encode(data, allocator);
    defer allocator.free(encoded);
    
    // Convert to base64url: replace + with -, / with _, remove padding =
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);
    
    for (encoded) |byte| {
        if (byte == '+') {
            try result.append(allocator, '-');
        } else if (byte == '/') {
            try result.append(allocator, '_');
        } else if (byte == '=') {
            // Skip padding
            break;
        } else {
            try result.append(allocator, byte);
        }
    }
    
    return result.toOwnedSlice(allocator);
}

/// Base64url decode (URL-safe base64)
fn base64urlDecode(encoded: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    // Convert from base64url to standard base64
    var standard = std.ArrayListUnmanaged(u8){};
    errdefer standard.deinit(allocator);
    
    for (encoded) |byte| {
        if (byte == '-') {
            try standard.append(allocator, '+');
        } else if (byte == '_') {
            try standard.append(allocator, '/');
        } else {
            try standard.append(allocator, byte);
        }
    }
    
    // Add padding if needed
    const remainder = standard.items.len % 4;
    if (remainder != 0) {
        const padding_needed = 4 - remainder;
        var i: usize = 0;
        while (i < padding_needed) : (i += 1) {
            try standard.append(allocator, '=');
        }
    }
    
    defer standard.deinit(allocator);
    return try std.base64.standard.Decoder.decode(allocator, standard.items);
}

/// Encode JWT token
/// Creates a JWT token with the given claims and secret
///
/// Example:
/// ```zig
/// const claims = Claims{ .user_id = 1, .username = "user", .exp = 1234567890 };
/// const token = try jwt.encode(claims, "secret-key", allocator);
/// defer allocator.free(token);
/// ```
pub fn encode(claims: Claims, secret: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    // Header: {"alg":"HS256","typ":"JWT"}
    const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const header_b64 = try base64urlEncode(header_json, allocator);
    defer allocator.free(header_b64);
    
    // Payload: {"user_id":<id>,"username":"<username>","exp":<exp>}
    var payload_json = std.ArrayListUnmanaged(u8){};
    defer payload_json.deinit(allocator);
    
    try payload_json.writer(allocator).print("{{\"user_id\":{d},\"username\":\"{s}\",\"exp\":{d}}}", .{
        claims.user_id,
        claims.username,
        claims.exp,
    });
    
    const payload_b64 = try base64urlEncode(payload_json.items, allocator);
    defer allocator.free(payload_b64);
    
    // Signature: HMAC-SHA256(header.payload, secret)
    var message = std.ArrayListUnmanaged(u8){};
    defer message.deinit(allocator);
    try message.appendSlice(allocator, header_b64);
    try message.append(allocator, '.');
    try message.appendSlice(allocator, payload_b64);
    
    var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);
    hmac.update(message.items);
    var signature: [32]u8 = undefined;
    hmac.final(&signature);
    
    const signature_b64 = try base64urlEncode(&signature, allocator);
    defer allocator.free(signature_b64);
    
    // Combine: header.payload.signature
    var token = std.ArrayListUnmanaged(u8){};
    errdefer token.deinit(allocator);
    
    try token.appendSlice(allocator, header_b64);
    try token.append(allocator, '.');
    try token.appendSlice(allocator, payload_b64);
    try token.append(allocator, '.');
    try token.appendSlice(allocator, signature_b64);
    
    return token.toOwnedSlice(allocator);
}

/// Decode and validate JWT token
/// Returns claims if token is valid and not expired
///
/// Example:
/// ```zig
/// const claims = try jwt.decode(token, "secret-key", allocator);
/// defer allocator.free(claims.username);
/// ```
pub fn decode(token: []const u8, secret: []const u8, allocator: std.mem.Allocator) !Claims {
    // Split token into parts
    var parts = std.mem.splitSequence(u8, token, ".");
    const header_b64 = parts.next() orelse return JwtError.InvalidToken;
    const payload_b64 = parts.next() orelse return JwtError.InvalidToken;
    const signature_b64 = parts.next() orelse return JwtError.InvalidToken;
    
    if (parts.next() != null) {
        return JwtError.InvalidToken;
    }
    
    // Verify signature
    var message = std.ArrayListUnmanaged(u8){};
    defer message.deinit(allocator);
    try message.appendSlice(allocator, header_b64);
    try message.append(allocator, '.');
    try message.appendSlice(allocator, payload_b64);
    
    var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);
    hmac.update(message.items);
    var expected_signature: [32]u8 = undefined;
    hmac.final(&expected_signature);
    
    const expected_sig_b64 = try base64urlEncode(&expected_signature, allocator);
    defer allocator.free(expected_sig_b64);
    
    if (!std.mem.eql(u8, signature_b64, expected_sig_b64)) {
        return JwtError.InvalidSignature;
    }
    
    // Decode payload
    const payload_json = try base64urlDecode(payload_b64, allocator);
    defer allocator.free(payload_json);
    
    // Parse JSON to extract claims
    var parser = std.json.Parser.init(allocator, .alloc_always);
    defer parser.deinit();
    
    var tree = try parser.parse(payload_json);
    defer tree.deinit();
    
    const root = tree.root;
    if (root != .object) {
        return JwtError.InvalidToken;
    }
    
    const user_id_node = root.object.get("user_id") orelse return JwtError.InvalidToken;
    const username_node = root.object.get("username") orelse return JwtError.InvalidToken;
    const exp_node = root.object.get("exp") orelse return JwtError.InvalidToken;
    
    const user_id = switch (user_id_node) {
        .integer => |i| @as(i64, @intCast(i)),
        else => return JwtError.InvalidToken,
    };
    
    const username_str = switch (username_node) {
        .string => |s| s,
        else => return JwtError.InvalidToken,
    };
    
    const exp = switch (exp_node) {
        .integer => |i| @as(i64, @intCast(i)),
        else => return JwtError.InvalidToken,
    };
    
    // Check expiration
    const now = std.time.timestamp();
    if (exp < now) {
        return JwtError.ExpiredToken;
    }
    
    // Copy username to allocated memory
    const username = try allocator.dupe(u8, username_str);
    
    return Claims{
        .user_id = user_id,
        .username = username,
        .exp = exp,
    };
}

// Tests
test "JWT encode and decode" {
    const claims = Claims{
        .user_id = 123,
        .username = "testuser",
        .exp = std.time.timestamp() + 3600,
    };
    
    const secret = "my-secret-key";
    const token = try encode(claims, secret, std.testing.allocator);
    defer std.testing.allocator.free(token);
    
    const decoded = try decode(token, secret, std.testing.allocator);
    defer std.testing.allocator.free(decoded.username);
    
    try std.testing.expectEqual(claims.user_id, decoded.user_id);
    try std.testing.expectEqualStrings(claims.username, decoded.username);
    try std.testing.expectEqual(claims.exp, decoded.exp);
}

test "JWT invalid signature" {
    const claims = Claims{
        .user_id = 123,
        .username = "testuser",
        .exp = std.time.timestamp() + 3600,
    };
    
    const secret = "my-secret-key";
    const token = try encode(claims, secret, std.testing.allocator);
    defer std.testing.allocator.free(token);
    
    const wrong_secret = "wrong-secret";
    const result = decode(token, wrong_secret, std.testing.allocator);
    try std.testing.expectError(JwtError.InvalidSignature, result);
}

test "JWT expired token" {
    const claims = Claims{
        .user_id = 123,
        .username = "testuser",
        .exp = std.time.timestamp() - 3600, // Expired
    };
    
    const secret = "my-secret-key";
    const token = try encode(claims, secret, std.testing.allocator);
    defer std.testing.allocator.free(token);
    
    const result = decode(token, secret, std.testing.allocator);
    try std.testing.expectError(JwtError.ExpiredToken, result);
}

