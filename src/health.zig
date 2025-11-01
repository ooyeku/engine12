const std = @import("std");
const types = @import("types.zig");

pub fn checkDatabaseHealth() types.HealthStatus {
    return .healthy;
}

pub fn checkCacheHealth() types.HealthStatus {
    return .healthy;
}

// Tests
test "checkDatabaseHealth returns healthy" {
    const status = checkDatabaseHealth();
    try std.testing.expectEqual(status, types.HealthStatus.healthy);
}

test "checkCacheHealth returns healthy" {
    const status = checkCacheHealth();
    try std.testing.expectEqual(status, types.HealthStatus.healthy);
}

