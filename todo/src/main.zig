const std = @import("std");
const E12 = @import("Engine12");
const app = @import("app.zig");

pub fn main() !void {
    E12.Engine12Core.init();
    try app.run();
}

