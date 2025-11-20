const std = @import("std");
const E12 = @import("engine12");

pub fn main() !void {
    var app = try E12.Engine12.initProduction();
    defer app.deinit();

    try app.start();
    app.printStatus();

    // Keep server running
    std.Thread.sleep(std.time.ns_per_min * 60);
}
