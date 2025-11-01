const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

/// Metric type
pub const MetricType = enum {
    counter,
    histogram,
    gauge,
};

/// Metric entry
pub const Metric = struct {
    name: []const u8,
    value: f64,
    labels: std.StringHashMap([]const u8),
    metric_type: MetricType,
    timestamp: i64,
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, value: f64, metric_type: MetricType) Metric {
        return Metric{
            .name = name,
            .value = value,
            .labels = std.StringHashMap([]const u8).init(allocator),
            .metric_type = metric_type,
            .timestamp = std.time.milliTimestamp(),
        };
    }
    
    pub fn deinit(self: *Metric) void {
        self.labels.deinit();
    }
    
    /// Add a label to the metric
    pub fn addLabel(self: *Metric, key: []const u8, value: []const u8) !void {
        try self.labels.put(key, value);
    }
};

/// Metrics collector
pub const MetricsCollector = struct {
    metrics: std.ArrayListUnmanaged(Metric),
    allocator: std.mem.Allocator,
    
    // Route timing data
    route_timings: std.StringHashMap(RouteTiming),
    
    // Request counters
    request_count: u64 = 0,
    error_count: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator) MetricsCollector {
        return MetricsCollector{
            .metrics = std.ArrayListUnmanaged(Metric){},
            .allocator = allocator,
            .route_timings = std.StringHashMap(RouteTiming).init(allocator),
        };
    }
    
    /// Record a metric
    pub fn record(self: *MetricsCollector, metric: Metric) !void {
        try self.metrics.append(self.allocator, metric);
    }
    
    /// Increment request counter
    pub fn incrementRequest(self: *MetricsCollector) void {
        self.request_count += 1;
    }
    
    /// Increment error counter
    pub fn incrementError(self: *MetricsCollector) void {
        self.error_count += 1;
    }
    
    /// Record route timing
    pub fn recordRouteTiming(self: *MetricsCollector, route: []const u8, duration_ms: u64) !void {
        const timing_ptr = self.route_timings.getPtr(route);
        if (timing_ptr) |timing| {
            timing.count += 1;
            timing.total_ms += duration_ms;
            if (duration_ms < timing.min_ms) timing.min_ms = duration_ms;
            if (duration_ms > timing.max_ms) timing.max_ms = duration_ms;
        } else {
            const new_timing = RouteTiming{
                .route = route,
                .count = 1,
                .total_ms = duration_ms,
                .min_ms = duration_ms,
                .max_ms = duration_ms,
            };
            try self.route_timings.put(route, new_timing);
        }
    }
    
    /// Get Prometheus format metrics
    pub fn getPrometheusMetrics(self: *const MetricsCollector) ![]const u8 {
        var output = std.ArrayListUnmanaged(u8){};
        const writer = output.writer(self.allocator);
        
        // Request counter
        try writer.print("http_requests_total {d}\n", .{self.request_count});
        
        // Error counter
        try writer.print("http_errors_total {d}\n", .{self.error_count});
        
        // Route timings
        var iterator = self.route_timings.iterator();
        while (iterator.next()) |entry| {
            const timing = entry.value_ptr;
            const avg_ms = if (timing.count > 0) @as(f64, @floatFromInt(timing.total_ms)) / @as(f64, @floatFromInt(timing.count)) else 0.0;
            
            try writer.print("http_route_duration_ms{{route=\"{s}\"}} {d}\n", .{ timing.route, avg_ms });
            try writer.print("http_route_requests_total{{route=\"{s}\"}} {d}\n", .{ timing.route, timing.count });
            try writer.print("http_route_duration_min_ms{{route=\"{s}\"}} {d}\n", .{ timing.route, timing.min_ms });
            try writer.print("http_route_duration_max_ms{{route=\"{s}\"}} {d}\n", .{ timing.route, timing.max_ms });
        }
        
        return output.toOwnedSlice(self.allocator);
    }
    
    pub fn deinit(self: *MetricsCollector) void {
        for (self.metrics.items) |*metric| {
            metric.deinit();
        }
        self.metrics.deinit(self.allocator);
        
        var iterator = self.route_timings.iterator();
        while (iterator.next()) |entry| {
            _ = entry;
        }
        self.route_timings.deinit();
    }
};

/// Route timing statistics
pub const RouteTiming = struct {
    route: []const u8,
    count: u64,
    total_ms: u64,
    min_ms: u64,
    max_ms: u64,
};

/// Request timing context
pub const RequestTiming = struct {
    start_time: i64,
    route: []const u8,
    
    pub fn start(route: []const u8) RequestTiming {
        return RequestTiming{
            .start_time = std.time.milliTimestamp(),
            .route = route,
        };
    }
    
    pub fn elapsed(self: *const RequestTiming) u64 {
        const now = std.time.milliTimestamp();
        return @intCast(now - self.start_time);
    }
    
    pub fn finish(self: *const RequestTiming, collector: *MetricsCollector) !void {
        const duration = self.elapsed();
        try collector.recordRouteTiming(self.route, duration);
        collector.incrementRequest();
    }
};

// Tests
test "MetricsCollector incrementRequest" {
    var collector = MetricsCollector.init(std.testing.allocator);
    defer collector.deinit();
    
    try std.testing.expectEqual(collector.request_count, 0);
    collector.incrementRequest();
    try std.testing.expectEqual(collector.request_count, 1);
}

test "MetricsCollector recordRouteTiming" {
    var collector = MetricsCollector.init(std.testing.allocator);
    defer collector.deinit();
    
    try collector.recordRouteTiming("/api/todos", 100);
    try collector.recordRouteTiming("/api/todos", 200);
    
    const timing = collector.route_timings.get("/api/todos");
    try std.testing.expect(timing != null);
    if (timing) |t| {
        try std.testing.expectEqual(t.count, 2);
        try std.testing.expectEqual(t.total_ms, 300);
    }
}

test "RequestTiming elapsed" {
    var timing = RequestTiming.start("/test");
    std.time.sleep(10 * std.time.ns_per_ms);
    const elapsed = timing.elapsed();
    try std.testing.expect(elapsed >= 10);
}

