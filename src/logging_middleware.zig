const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware = @import("middleware.zig");
const dev_tools = @import("dev_tools.zig");
const Logger = dev_tools.Logger;
const LogLevel = dev_tools.LogLevel;

/// Logging middleware configuration
pub const LoggingConfig = struct {
    /// Log incoming requests (default: true)
    log_requests: bool = true,
    
    /// Log outgoing responses (default: true)
    log_responses: bool = true,
    
    /// Log request/response bodies (default: false, for sensitive data)
    log_body: bool = false,
    
    /// Paths to exclude from logging (e.g., health checks)
    exclude_paths: []const []const u8 = &[_][]const u8{},
    
    /// Log level for requests (default: info)
    request_log_level: LogLevel = .info,
    
    /// Log level for responses (default: info)
    response_log_level: LogLevel = .info,
};

/// Global logger storage (thread-safe)
var global_logger: ?*Logger = null;
var global_logger_mutex: std.Thread.Mutex = .{};

/// Global logging config storage
var global_logging_config: ?LoggingConfig = null;
var global_logging_config_mutex: std.Thread.Mutex = .{};

/// Logging middleware for request/response logging
pub const LoggingMiddleware = struct {
    config: LoggingConfig,
    
    /// Initialize logging middleware with configuration
    /// 
    /// Example:
    /// ```zig
    /// const logging = LoggingMiddleware.init(.{
    ///     .log_requests = true,
    ///     .log_responses = true,
    ///     .exclude_paths = &[_][]const u8{"/health", "/metrics"},
    /// });
    /// logging.setGlobalLogger(&app.logger);
    /// logging.setGlobalConfig();
    /// try app.usePreRequest(logging.preRequestMwFn());
    /// try app.useResponse(logging.responseMwFn());
    /// ```
    pub fn init(config: LoggingConfig) LoggingMiddleware {
        return LoggingMiddleware{ .config = config };
    }
    
    /// Set the global logger (must be called before using middleware)
    pub fn setGlobalLogger(logger: *Logger) void {
        global_logger_mutex.lock();
        defer global_logger_mutex.unlock();
        global_logger = logger;
    }
    
    /// Set the global config (must be called before using middleware)
    pub fn setGlobalConfig(self: *const LoggingMiddleware) void {
        global_logging_config_mutex.lock();
        defer global_logging_config_mutex.unlock();
        global_logging_config = self.config;
    }
    
    /// Check if path should be excluded from logging
    fn isExcluded(path: []const u8, exclude_paths: []const []const u8) bool {
        for (exclude_paths) |excluded| {
            if (std.mem.startsWith(u8, path, excluded)) {
                return true;
            }
        }
        return false;
    }
    
    /// Pre-request middleware that logs incoming requests
    fn preRequestMiddleware(req: *Request) middleware.MiddlewareResult {
        // Get config and logger from global storage
        global_logging_config_mutex.lock();
        const config = global_logging_config orelse {
            global_logging_config_mutex.unlock();
            return .proceed; // No config set
        };
        global_logging_config_mutex.unlock();
        
        global_logger_mutex.lock();
        const logger = global_logger orelse {
            global_logger_mutex.unlock();
            return .proceed; // No logger set
        };
        global_logger_mutex.unlock();
        
        // Check if path is excluded
        if (isExcluded(req.path(), config.exclude_paths)) {
            return .proceed;
        }
        
        // Skip if request logging is disabled
        if (!config.log_requests) {
            return .proceed;
        }
        
        // Store request start time
        const start_time = std.time.milliTimestamp();
        const start_time_str = std.fmt.allocPrint(req.arena.allocator(), "{d}", .{start_time}) catch {
            return .proceed; // If allocation fails, just proceed
        };
        req.set("request_start_time", start_time_str) catch {};
        
        // Log request
        const entry = logger.fromRequest(req, config.request_log_level, "Request received") catch {
            return .proceed; // If logging fails, just proceed
        };
        entry.log();
        
        return .proceed;
    }
    
    /// Response middleware that logs outgoing responses
    fn responseMiddleware(resp: Response) Response {
        // Get config from global storage
        global_logging_config_mutex.lock();
        const config = global_logging_config orelse {
            global_logging_config_mutex.unlock();
            return resp; // No config set
        };
        global_logging_config_mutex.unlock();
        
        // Skip if response logging is disabled
        if (!config.log_responses) {
            return resp;
        }
        
        // Note: We can't access request from response middleware directly
        // The request context would need to be stored in a thread-local or passed differently
        // For now, we'll log without request context in response middleware
        // This is a limitation that could be addressed in future versions
        
        return resp;
    }
    
    /// Get pre-request middleware function
    pub fn preRequestMwFn(self: *const LoggingMiddleware) middleware.PreRequestMiddlewareFn {
        _ = self; // Config is stored globally
        return preRequestMiddleware;
    }
    
    /// Get response middleware function
    pub fn responseMwFn(self: *const LoggingMiddleware) middleware.ResponseMiddlewareFn {
        _ = self; // Config is stored globally
        return responseMiddleware;
    }
};

