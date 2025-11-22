const std = @import("std");
const E12 = @import("engine12");
const Request = E12.Request;
const Response = E12.Response;

/// Handle metrics endpoint
/// Returns Prometheus-formatted metrics
pub fn handleMetrics(request: *Request) Response {
    _ = request;
    // Access global metrics collector
    const metrics_collector = E12.engine12.global_metrics;

    if (metrics_collector) |mc| {
        const prometheus_output = mc.getPrometheusMetrics() catch {
            return Response.serverError("Failed to generate metrics");
        };
        defer std.heap.page_allocator.free(prometheus_output);

        var resp = Response.text(prometheus_output);
        resp = resp.withContentType("text/plain; version=0.0.4");
        return resp;
    }

    // Fallback if metrics collector not available
    return Response.json("{\"metrics\":{\"uptime_ms\":0,\"requests_total\":0}}");
}

