const std = @import("std");
const E12 = @import("engine12");
const app = @import("app.zig");

pub fn main() !void {
    try app.run();
}
