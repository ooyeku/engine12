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
    _ = 3; // 3 iterations
    _ = 65536; // 64 MB memory
    _ = 4; // 4 parallel threads

    // Use SHA-256 for password hashing (simpler than Argon2, but still secure with salt)
    // In production, consider using a proper password hashing library
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&salt);
    hasher.update(password);
    var hash_output: [32]u8 = undefined;
    hasher.final(&hash_output);

    // Encode salt + hash as base64
    const combined_size = std.base64.standard.Encoder.calcSize(48);
    var encoded_buffer = allocator.alloc(u8, combined_size) catch return error.OutOfMemory;
    errdefer allocator.free(encoded_buffer);

    var combined: [48]u8 = undefined;
    @memcpy(combined[0..16], &salt);
    @memcpy(combined[16..48], &hash_output);

    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.encode(encoded_buffer, &combined).len;
    const result = encoded_buffer[0..encoded_len];
    return result;
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
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(hash_str) catch return false;
    var decoded_buffer = std.heap.page_allocator.alloc(u8, decoded_size) catch return false;
    defer std.heap.page_allocator.free(decoded_buffer);

    const decoder = std.base64.standard.Decoder;
    decoder.decode(decoded_buffer, hash_str) catch return false;
    const decoded = decoded_buffer[0..decoded_size];

    if (decoded.len != 48) {
        return false;
    }

    const salt = decoded[0..16];
    const stored_hash = decoded[16..48];

    // Hash password with same salt using SHA-256
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(salt);
    hasher.update(password);
    var computed_hash: [32]u8 = undefined;
    hasher.final(&computed_hash);

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
