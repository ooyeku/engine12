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
pub const cors_middleware = @import("cors_middleware.zig");
pub const request_id_middleware = @import("request_id_middleware.zig");
pub const pagination = @import("pagination.zig");
pub const logging_middleware = @import("logging_middleware.zig");
pub const valve = @import("valve/valve.zig");
pub const websocket = @import("websocket/module.zig");
pub const hot_reload = @import("hot_reload/module.zig");

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

// Re-export cache types
pub const ResponseCache = cache.ResponseCache;
pub const CacheEntry = cache.CacheEntry;

// Re-export JSON utilities
pub const Json = json.Json;

// Re-export valve types
pub const Valve = valve.Valve;
pub const ValveMetadata = valve.ValveMetadata;
pub const ValveCapability = valve.ValveCapability;
pub const ValveError = valve.ValveError;
pub const ValveContext = @import("valve/context.zig").ValveContext;
pub const ValveRegistry = @import("valve/registry.zig").ValveRegistry;
pub const RegistryError = @import("valve/registry.zig").RegistryError;
pub const ValveErrorInfo = @import("valve/error_info.zig").ValveErrorInfo;
pub const ValveErrorPhase = @import("valve/error_info.zig").ValveErrorPhase;

// Re-export builtin valves
pub const BasicAuthValve = @import("valve/builtin/basic_auth.zig").BasicAuthValve;
pub const BasicAuthConfig = @import("valve/builtin/basic_auth.zig").BasicAuthConfig;
pub const User = @import("valve/builtin/basic_auth.zig").User;

// Re-export websocket types
pub const WebSocketConnection = websocket.WebSocketConnection;
pub const WebSocketHandler = websocket.WebSocketHandler;
pub const WebSocketManager = websocket.WebSocketManager;
pub const WebSocketRoom = websocket.WebSocketRoom;

// Re-export hot reload types
pub const RuntimeTemplate = hot_reload.RuntimeTemplate;
pub const HotReloadManager = hot_reload.HotReloadManager;
pub const FileWatcher = hot_reload.FileWatcher;

// Re-export logging middleware types
pub const LoggingMiddleware = logging_middleware.LoggingMiddleware;
pub const LoggingConfig = logging_middleware.LoggingConfig;

// Re-export RESTful API types
pub const rest_api = @import("rest_api.zig");
pub const restApi = rest_api.restApi;
pub const RestApiConfig = rest_api.RestApiConfig; // Generic function: RestApiConfig(Model)
pub const AuthUser = rest_api.AuthUser;

// Re-export Handler Context types
pub const handler_context = @import("handler_context.zig");
pub const HandlerCtx = handler_context.HandlerCtx;
pub const HandlerCtxError = handler_context.HandlerCtxError;

// Re-export migration discovery
pub const migration_discovery = @import("orm/migration_discovery.zig");

// Re-export TemplateRegistry (from Engine12 struct)
pub const TemplateRegistry = engine12.Engine12.TemplateRegistry;
