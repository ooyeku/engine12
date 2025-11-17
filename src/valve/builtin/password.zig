const std = @import("std");

/// Password hashing and verification utilities
/// Uses Argon2id for secure password hashing

/// Hash a password using Argon2id
/// Returns a hash string that includes the salt and parameters
///
/// Example:
/// ```zig
/// const hash = try password.hash("mypassword", allocator);
/// defer allocator.free(hash);
/// ```
pub fn hash(password: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    // Generate random salt
    var salt: [16]u8 = undefined;
    std.crypto.random.bytes(&salt);
    
    // Hash password with Argon2id
    // Parameters: t_cost (time), m_cost (memory), p_cost (parallelism)
    const t_cost: u32 = 3; // 3 iterations
    const m_cost: u32 = 65536; // 64 MB memory
    const p_cost: u32 = 4; // 4 parallel threads
    
    var hash_output: [32]u8 = undefined;
    try std.crypto.pwhash.argon2id.hash(
        &hash_output,
        password,
        &salt,
        .{ .t = t_cost, .m = m_cost, .p = p_cost },
    );
    
    // Encode salt + hash as base64
    var combined: [48]u8 = undefined;
    @memcpy(combined[0..16], &salt);
    @memcpy(combined[16..48], &hash_output);
    
    const encoded = try std.base64.standard.Encoder.encode(&combined, allocator);
    return encoded;
}

/// Verify a password against a hash
/// Returns true if password matches, false otherwise
///
/// Example:
/// ```zig
/// const is_valid = password.verify("mypassword", stored_hash);
/// ```
pub fn verify(password: []const u8, hash_str: []const u8) bool {
    // Decode hash string
    const decoded = std.base64.standard.Decoder.decode(hash_str, std.heap.page_allocator) catch return false;
    defer std.heap.page_allocator.free(decoded);
    
    if (decoded.len != 48) {
        return false;
    }
    
    const salt = decoded[0..16];
    const stored_hash = decoded[16..48];
    
    // Hash password with same salt and parameters
    const t_cost: u32 = 3;
    const m_cost: u32 = 65536;
    const p_cost: u32 = 4;
    
    var computed_hash: [32]u8 = undefined;
    std.crypto.pwhash.argon2id.hash(
        &computed_hash,
        password,
        salt,
        .{ .t = t_cost, .m = m_cost, .p = p_cost },
    ) catch return false;
    
    // Compare hashes
    return std.mem.eql(u8, &computed_hash, stored_hash);
}

// Tests
test "password hash and verify" {
    const pwd = "testpassword123";
    
    const hash_str = try hash(pwd, std.testing.allocator);
    defer std.testing.allocator.free(hash_str);
    
    try std.testing.expect(verify(pwd, hash_str));
    try std.testing.expect(!verify("wrongpassword", hash_str));
}

test "password hash is deterministic" {
    const pwd = "testpassword123";
    
    const hash1 = try hash(pwd, std.testing.allocator);
    defer std.testing.allocator.free(hash1);
    
    const hash2 = try hash(pwd, std.testing.allocator);
    defer std.testing.allocator.free(hash2);
    
    // Hashes should be different due to random salt
    try std.testing.expect(!std.mem.eql(u8, hash1, hash2));
    
    // But both should verify correctly
    try std.testing.expect(verify(pwd, hash1));
    try std.testing.expect(verify(pwd, hash2));
}

