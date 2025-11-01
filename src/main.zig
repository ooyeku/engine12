const std = @import("std");
const E12 = @import("Engine12");

pub fn main() !void {
    E12.Engine12Core.init();
    var app = try E12.Engine12.initProduction();
    defer app.deinit();
    try E12.Engine12Core.runDemoApp();
    app.printStatus();
}