// Root module - exports all public API
pub const types = @import("types.zig");
pub const engine12 = @import("engine12.zig");
pub const fileserver = @import("fileserver.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const middleware = @import("middleware.zig");
pub const route_group = @import("route_group.zig");
pub const validation = @import("validation.zig");
pub const error_handler = @import("error_handler.zig");
pub const metrics = @import("metrics.zig");
pub const rate_limit = @import("rate_limit.zig");
pub const body_size_limit = @import("body_size_limit.zig");
pub const csrf = @import("csrf.zig");
pub const cache = @import("cache.zig");
pub const router = @import("router.zig");
pub const templates = @import("templates/template.zig");
pub const dev_tools = @import("dev_tools.zig");
pub const orm = @import("orm/orm.zig");
pub const json = @import("json.zig");
pub const utils = @import("utils.zig");

// Re-export main types for convenience
pub const Engine12 = engine12.Engine12;
pub const FileServer = fileserver.FileServer;
pub const Request = request.Request;
pub const Response = response.Response;
pub const Environment = types.Environment;
pub const HealthStatus = types.HealthStatus;
pub const ServerProfile = types.ServerProfile;
pub const ServerProfile_Development = types.ServerProfile_Development;
pub const ServerProfile_Production = types.ServerProfile_Production;
pub const ServerProfile_Testing = types.ServerProfile_Testing;
pub const HttpHandler = types.HttpHandler;
pub const BackgroundTask = types.BackgroundTask;
pub const HealthCheckFn = types.HealthCheckFn;
pub const PreRequestMiddleware = types.PreRequestMiddleware;
pub const ResponseTransformMiddleware = types.ResponseTransformMiddleware;

// Re-export logging types
pub const Logger = dev_tools.Logger;
pub const LogLevel = dev_tools.LogLevel;
pub const LogEntry = dev_tools.LogEntry;
pub const OutputFormat = dev_tools.OutputFormat;
