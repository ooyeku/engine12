#ifndef ENGINE12_H
#define ENGINE12_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handles - these are pointer types, never dereference them
typedef void Engine12;
typedef void E12Request;
typedef void E12Response;
typedef void E12Cache;
typedef void E12ValveContext;

// Error codes
typedef enum {
    E12_OK = 0,
    E12_ERROR_INVALID_ARGUMENT = 1,
    E12_ERROR_TOO_MANY_ROUTES = 2,
    E12_ERROR_SERVER_ALREADY_BUILT = 3,
    E12_ERROR_ALLOCATION_FAILED = 4,
    E12_ERROR_SERVER_START_FAILED = 5,
    E12_ERROR_INVALID_PATH = 6,
    E12_ERROR_CAPABILITY_REQUIRED = 7,
    E12_ERROR_VALVE_NOT_FOUND = 8,
    E12_ERROR_VALVE_ALREADY_REGISTERED = 9,
    E12_ERROR_TOO_MANY_VALVES = 10,
    E12_ERROR_UNKNOWN = 99,
} E12ErrorCode;

// Server profile
typedef enum {
    E12_ENV_DEVELOPMENT = 0,
    E12_ENV_STAGING = 1,
    E12_ENV_PRODUCTION = 2,
} E12Environment;

// HTTP methods
typedef enum {
    E12_METHOD_GET = 0,
    E12_METHOD_POST = 1,
    E12_METHOD_PUT = 2,
    E12_METHOD_DELETE = 3,
    E12_METHOD_PATCH = 4,
} E12Method;

// Middleware result
typedef enum {
    E12_MIDDLEWARE_PROCEED = 0,
    E12_MIDDLEWARE_ABORT = 1,
} E12MiddlewareResult;

// Request handler callback
// Returns response handle (caller must free with e12_response_free)
typedef E12Response* (*E12HandlerFn)(E12Request* req, void* user_data);

// Pre-request middleware callback
// Returns E12_MIDDLEWARE_PROCEED to continue, E12_MIDDLEWARE_ABORT to stop
typedef E12MiddlewareResult (*E12PreRequestMiddlewareFn)(E12Request* req, void* user_data);

// Response middleware callback
// Returns response handle (caller must free with e12_response_free)
typedef E12Response* (*E12ResponseMiddlewareFn)(E12Response* resp, void* user_data);

// Background task callback
typedef void (*E12BackgroundTaskFn)(void* user_data);

// Health check callback
typedef enum {
    E12_HEALTH_HEALTHY = 0,
    E12_HEALTH_DEGRADED = 1,
    E12_HEALTH_UNHEALTHY = 2,
} E12HealthStatus;

typedef E12HealthStatus (*E12HealthCheckFn)(void* user_data);

// Error handler callback
typedef E12Response* (*E12ErrorHandlerFn)(E12ErrorCode error_code, void* user_data);

// Valve capability enum
typedef enum {
    E12_VALVE_CAP_ROUTES = 0,
    E12_VALVE_CAP_MIDDLEWARE = 1,
    E12_VALVE_CAP_BACKGROUND_TASKS = 2,
    E12_VALVE_CAP_HEALTH_CHECKS = 3,
    E12_VALVE_CAP_STATIC_FILES = 4,
    E12_VALVE_CAP_WEBSOCKETS = 5,
    E12_VALVE_CAP_DATABASE_ACCESS = 6,
    E12_VALVE_CAP_CACHE_ACCESS = 7,
    E12_VALVE_CAP_METRICS_ACCESS = 8,
} E12ValveCapability;

// Valve metadata structure
typedef struct {
    const char* name;
    const char* version;
    const char* description;
    const char* author;
    E12ValveCapability* capabilities;  // Array
    size_t capabilities_count;
} E12ValveMetadata;

// Valve callbacks
typedef E12ErrorCode (*E12ValveInitFn)(E12ValveContext* ctx, void* user_data);
typedef void (*E12ValveDeinitFn)(void* user_data);
typedef E12ErrorCode (*E12ValveOnAppStartFn)(E12ValveContext* ctx, void* user_data);
typedef void (*E12ValveOnAppStopFn)(E12ValveContext* ctx, void* user_data);

// Valve structure
typedef struct {
    E12ValveMetadata metadata;
    E12ValveInitFn init;
    E12ValveDeinitFn deinit;
    E12ValveOnAppStartFn onAppStart;  // Optional, can be NULL
    E12ValveOnAppStopFn onAppStop;    // Optional, can be NULL
    void* user_data;
} E12Valve;

// ============================================================================
// Engine12 Instance Management
// ============================================================================

/// Create a new Engine12 instance
/// @param env Server environment (development/staging/production)
/// @param out_app Output parameter for the Engine12 instance
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_init(E12Environment env, Engine12** out_app);

/// Free an Engine12 instance
/// @param app Engine12 instance to free (must not be NULL)
void e12_free(Engine12* app);

/// Start the Engine12 server
/// @param app Engine12 instance
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_start(Engine12* app);

/// Stop the Engine12 server gracefully
/// @param app Engine12 instance
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_stop(Engine12* app);

/// Check if server is running
/// @param app Engine12 instance
/// @return true if running, false otherwise
bool e12_is_running(Engine12* app);

// ============================================================================
// Route Registration
// ============================================================================

/// Register a GET route
/// @param app Engine12 instance
/// @param path Route path pattern (e.g., "/api/todos/:id")
/// @param handler Handler function
/// @param user_data User data passed to handler
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_get(Engine12* app, const char* path, E12HandlerFn handler, void* user_data);

/// Register a POST route
E12ErrorCode e12_post(Engine12* app, const char* path, E12HandlerFn handler, void* user_data);

/// Register a PUT route
E12ErrorCode e12_put(Engine12* app, const char* path, E12HandlerFn handler, void* user_data);

/// Register a DELETE route
E12ErrorCode e12_delete(Engine12* app, const char* path, E12HandlerFn handler, void* user_data);

/// Register a PATCH route
E12ErrorCode e12_patch(Engine12* app, const char* path, E12HandlerFn handler, void* user_data);

// ============================================================================
// Middleware
// ============================================================================

/// Add pre-request middleware
/// @param app Engine12 instance
/// @param middleware Middleware function
/// @param user_data User data passed to middleware
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_use_pre_request(Engine12* app, E12PreRequestMiddlewareFn middleware, void* user_data);

/// Add response middleware
E12ErrorCode e12_use_response(Engine12* app, E12ResponseMiddlewareFn middleware, void* user_data);

// ============================================================================
// Static File Serving
// ============================================================================

/// Serve static files from a directory
/// @param app Engine12 instance
/// @param mount_path Mount path (e.g., "/static")
/// @param directory Directory path
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_serve_static(Engine12* app, const char* mount_path, const char* directory);

// ============================================================================
// Background Tasks
// ============================================================================

/// Register a background task
/// @param app Engine12 instance
/// @param name Task name
/// @param task Task function
/// @param interval_ms Interval in milliseconds (0 for one-time task)
/// @param user_data User data passed to task
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_register_task(Engine12* app, const char* name, E12BackgroundTaskFn task, uint32_t interval_ms, void* user_data);

// ============================================================================
// Health Checks
// ============================================================================

/// Register a health check
/// @param app Engine12 instance
/// @param check Health check function
/// @param user_data User data passed to check
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_register_health_check(Engine12* app, E12HealthCheckFn check, void* user_data);

// ============================================================================
// Request API
// ============================================================================

/// Get request path
/// @param req Request handle
/// @return Path string (owned by request, do not free)
const char* e12_request_path(E12Request* req);

/// Get request method
/// @param req Request handle
/// @return HTTP method
E12Method e12_request_method(E12Request* req);

/// Get request body
/// @param req Request handle
/// @return Body string (owned by request, do not free)
const char* e12_request_body(E12Request* req);

/// Get request body length
/// @param req Request handle
/// @return Body length in bytes
size_t e12_request_body_len(E12Request* req);

/// Get a header value by name
/// @param req Request handle
/// @param name Header name
/// @return Header value (owned by request, do not free), NULL if not found
const char* e12_request_header(E12Request* req, const char* name);

/// Get a route parameter
/// @param req Request handle
/// @param name Parameter name
/// @return Parameter value (owned by request, do not free), NULL if not found
const char* e12_request_param(E12Request* req, const char* name);

/// Get a query parameter
/// @param req Request handle
/// @param name Parameter name
/// @return Parameter value (owned by request, do not free), NULL if not found
const char* e12_request_query(E12Request* req, const char* name);

/// Set a value in request context
/// @param req Request handle
/// @param key Key
/// @param value Value
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_request_set(E12Request* req, const char* key, const char* value);

/// Get a value from request context
/// @param req Request handle
/// @param key Key
/// @return Value (owned by request, do not free), NULL if not found
const char* e12_request_get(E12Request* req, const char* key);

// ============================================================================
// Response API
// ============================================================================

/// Create a JSON response
/// @param body JSON body string
/// @return Response handle (must be freed with e12_response_free)
E12Response* e12_response_json(const char* body);

/// Create a text response
/// @param body Text body string
/// @return Response handle (must be freed with e12_response_free)
E12Response* e12_response_text(const char* body);

/// Create an HTML response
/// @param body HTML body string
/// @return Response handle (must be freed with e12_response_free)
E12Response* e12_response_html(const char* body);

/// Create a status response
/// @param status_code HTTP status code
/// @return Response handle (must be freed with e12_response_free)
E12Response* e12_response_status(uint16_t status_code);

/// Create a redirect response
/// @param location Redirect location URL
/// @return Response handle (must be freed with e12_response_free)
E12Response* e12_response_redirect(const char* location);

/// Set response status code
/// @param resp Response handle
/// @param status_code HTTP status code
/// @return Response handle (same or new)
E12Response* e12_response_with_status(E12Response* resp, uint16_t status_code);

/// Set response content type
/// @param resp Response handle
/// @param content_type Content type string
/// @return Response handle (same or new)
E12Response* e12_response_with_content_type(E12Response* resp, const char* content_type);

/// Add a header to response
/// @param resp Response handle
/// @param name Header name
/// @param value Header value
/// @return Response handle (same or new)
E12Response* e12_response_with_header(E12Response* resp, const char* name, const char* value);

/// Free a response handle
/// @param resp Response handle to free
void e12_response_free(E12Response* resp);

// ============================================================================
// Error Handling
// ============================================================================

/// Get last error message
/// @return Error message string (owned by Engine12, do not free)
const char* e12_get_last_error(void);

// ============================================================================
// Cache API
// ============================================================================

/// Initialize a response cache
/// @param default_ttl_ms Default TTL in milliseconds
/// @param out_cache Output parameter for cache handle
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_cache_init(uint64_t default_ttl_ms, E12Cache** out_cache);

/// Free a cache instance
/// @param cache Cache handle to free
void e12_cache_free(E12Cache* cache);

/// Get a cached entry
/// @param cache Cache handle
/// @param key Cache key
/// @param out_body Output parameter for cached body (owned by cache, do not free)
/// @param out_body_len Output parameter for body length
/// @return true if found and not expired, false otherwise
bool e12_cache_get(E12Cache* cache, const char* key, const char** out_body, size_t* out_body_len);

/// Set a cache entry
/// @param cache Cache handle
/// @param key Cache key
/// @param body Body to cache
/// @param ttl_ms TTL in milliseconds (0 to use default)
/// @param content_type Content type string
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_cache_set(E12Cache* cache, const char* key, const char* body, uint64_t ttl_ms, const char* content_type);

/// Invalidate a cache entry
/// @param cache Cache handle
/// @param key Cache key to invalidate
void e12_cache_invalidate(E12Cache* cache, const char* key);

/// Invalidate cache entries by prefix
/// @param cache Cache handle
/// @param prefix Prefix to match
void e12_cache_invalidate_prefix(E12Cache* cache, const char* prefix);

/// Cleanup expired cache entries
/// @param cache Cache handle
void e12_cache_cleanup(E12Cache* cache);

/// Set cache on Engine12 instance
/// @param app Engine12 instance
/// @param cache Cache handle
void e12_set_cache(Engine12* app, E12Cache* cache);

/// Get cache from request context
/// @param req Request handle
/// @return Cache handle or NULL if not configured
E12Cache* e12_request_cache(E12Request* req);

/// Get cached entry via request
/// @param req Request handle
/// @param key Cache key
/// @param out_body Output parameter for cached body
/// @param out_body_len Output parameter for body length
/// @return true if found, false otherwise
bool e12_request_cache_get(E12Request* req, const char* key, const char** out_body, size_t* out_body_len);

/// Set cache entry via request
/// @param req Request handle
/// @param key Cache key
/// @param body Body to cache
/// @param ttl_ms TTL in milliseconds
/// @param content_type Content type
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_request_cache_set(E12Request* req, const char* key, const char* body, uint64_t ttl_ms, const char* content_type);

// ============================================================================
// Metrics API
// ============================================================================

/// Get metrics collector handle
/// @param app Engine12 instance
/// @return Metrics handle or NULL if not enabled
void* e12_get_metrics(Engine12* app);

/// Increment a counter metric
/// @param metrics Metrics handle
/// @param name Counter name
void e12_metrics_increment_counter(void* metrics, const char* name);

/// Record a timing metric
/// @param metrics Metrics handle
/// @param name Metric name
/// @param duration_ms Duration in milliseconds
void e12_metrics_record_timing(void* metrics, const char* name, uint64_t duration_ms);

/// Get counter value
/// @param metrics Metrics handle
/// @param name Counter name
/// @return Counter value
uint64_t e12_metrics_get_counter(void* metrics, const char* name);

/// Increment counter via request context
/// @param req Request handle
/// @param name Counter name
void e12_request_increment_counter(E12Request* req, const char* name);

// ============================================================================
// Rate Limiting
// ============================================================================

/// Initialize a rate limiter
/// @param max_requests Maximum requests per window
/// @param window_ms Window size in milliseconds
/// @param out_limiter Output parameter for limiter handle
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_rate_limiter_init(uint32_t max_requests, uint64_t window_ms, void** out_limiter);

/// Free a rate limiter
/// @param limiter Rate limiter handle
void e12_rate_limiter_free(void* limiter);

/// Set rate limiter on Engine12 instance
/// @param app Engine12 instance
/// @param limiter Rate limiter handle
void e12_set_rate_limiter(Engine12* app, void* limiter);

/// Check if request should be rate limited
/// @param req Request handle
/// @param key Rate limit key (e.g., IP address)
/// @return true if rate limited, false otherwise
bool e12_request_rate_limit_check(E12Request* req, const char* key);

// ============================================================================
// Security Features
// ============================================================================

/// Initialize CSRF protection
/// @param secret Secret key for CSRF tokens
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_csrf_init(const char* secret);

/// Register CSRF middleware
/// @param app Engine12 instance
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_csrf_middleware(Engine12* app);

/// Get CSRF token for request
/// @param req Request handle
/// @return CSRF token string (owned by request, do not free), NULL on error
const char* e12_request_csrf_token(E12Request* req);

/// Configure CORS settings
/// @param app Engine12 instance
/// @param allowed_origins Comma-separated list of allowed origins (NULL for all)
/// @param allowed_methods Comma-separated list of allowed methods (NULL for all)
/// @param allowed_headers Comma-separated list of allowed headers (NULL for all)
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_cors_configure(Engine12* app, const char* allowed_origins, const char* allowed_methods, const char* allowed_headers);

/// Register CORS middleware
/// @param app Engine12 instance
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_cors_middleware(Engine12* app);

/// Set maximum request body size
/// @param app Engine12 instance
/// @param max_size_bytes Maximum body size in bytes
void e12_set_body_size_limit(Engine12* app, size_t max_size_bytes);

// ============================================================================
// Request Enhancements
// ============================================================================

/// Get request ID
/// @param req Request handle
/// @return Request ID string (owned by request, do not free)
const char* e12_request_id(E12Request* req);

/// Parse JSON body from request
/// @param req Request handle
/// @param out_json Output parameter for JSON handle
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_request_json(E12Request* req, void** out_json);

/// Parse JSON string
/// @param json_str JSON string
/// @param out_json Output parameter for JSON handle
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_json_parse(const char* json_str, void** out_json);

/// Get string field from JSON object
/// @param json JSON handle
/// @param field Field name
/// @return String value (owned by JSON, do not free), NULL if not found
const char* e12_json_get_string(void* json, const char* field);

/// Get integer field from JSON object
/// @param json JSON handle
/// @param field Field name
/// @param out_value Output parameter for integer value
/// @return true if found and valid, false otherwise
bool e12_json_get_int(void* json, const char* field, int64_t* out_value);

/// Get double field from JSON object
/// @param json JSON handle
/// @param field Field name
/// @param out_value Output parameter for double value
/// @return true if found and valid, false otherwise
bool e12_json_get_double(void* json, const char* field, double* out_value);

/// Get boolean field from JSON object
/// @param json JSON handle
/// @param field Field name
/// @param out_value Output parameter for boolean value
/// @return true if found and valid, false otherwise
bool e12_json_get_bool(void* json, const char* field, bool* out_value);

/// Free JSON object
/// @param json JSON handle to free
void e12_json_free(void* json);

/// Validate string field
/// @param value String value to validate
/// @param min_len Minimum length (0 for no minimum)
/// @param max_len Maximum length (0 for no maximum)
/// @return true if valid, false otherwise
bool e12_validate_string(const char* value, size_t min_len, size_t max_len);

/// Validate integer field
/// @param value Integer value to validate
/// @param min_value Minimum value
/// @param max_value Maximum value
/// @return true if valid, false otherwise
bool e12_validate_int(int64_t value, int64_t min_value, int64_t max_value);

/// Validate email address
/// @param email Email string to validate
/// @return true if valid, false otherwise
bool e12_validate_email(const char* email);

/// Validate URL
/// @param url URL string to validate
/// @return true if valid, false otherwise
bool e12_validate_url(const char* url);

/// Get query parameter as integer
/// @param req Request handle
/// @param name Parameter name
/// @param out_value Output parameter for integer value
/// @return true if found and valid, false otherwise
bool e12_request_query_int(E12Request* req, const char* name, int64_t* out_value);

/// Get query parameter as double
/// @param req Request handle
/// @param name Parameter name
/// @param out_value Output parameter for double value
/// @return true if found and valid, false otherwise
bool e12_request_query_double(E12Request* req, const char* name, double* out_value);

/// Get route parameter as integer
/// @param req Request handle
/// @param name Parameter name
/// @param out_value Output parameter for integer value
/// @return true if found and valid, false otherwise
bool e12_request_param_int(E12Request* req, const char* name, int64_t* out_value);

/// Get route parameter as double
/// @param req Request handle
/// @param name Parameter name
/// @param out_value Output parameter for double value
/// @return true if found and valid, false otherwise
bool e12_request_param_double(E12Request* req, const char* name, double* out_value);

// ============================================================================
// Error Handling
// ============================================================================

/// Register a custom error handler
/// @param app Engine12 instance
/// @param handler Error handler function
/// @param user_data User data passed to handler
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_register_error_handler(Engine12* app, E12ErrorHandlerFn handler, void* user_data);

// ============================================================================
// Health Status
// ============================================================================

/// Get overall system health status
/// @param app Engine12 instance
/// @return Health status
E12HealthStatus e12_get_system_health(Engine12* app);

// ============================================================================
// Valve System
// ============================================================================

/// Register a valve with Engine12
/// @param app Engine12 instance
/// @param valve Valve structure (will be copied)
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_register_valve(Engine12* app, const E12Valve* valve);

/// Unregister a valve by name
/// @param app Engine12 instance
/// @param name Valve name
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_unregister_valve(Engine12* app, const char* name);

/// Get list of registered valve names
/// @param app Engine12 instance
/// @param out_names Output parameter for array of valve names (caller must free)
/// @param out_count Output parameter for number of names
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_get_valve_names(Engine12* app, char*** out_names, size_t* out_count);

/// Free valve names array
/// @param names Array of valve names
/// @param count Number of names
void e12_free_valve_names(char** names, size_t count);

// Valve Context API (capability-checked)

/// Register a route via valve context
/// @param ctx Valve context handle
/// @param method HTTP method
/// @param path Route path
/// @param handler Handler function
/// @param user_data User data passed to handler
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_valve_context_register_route(
    E12ValveContext* ctx,
    const char* method,
    const char* path,
    E12HandlerFn handler,
    void* user_data
);

/// Register middleware via valve context
/// @param ctx Valve context handle
/// @param middleware Middleware function
/// @param user_data User data passed to middleware
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_valve_context_register_middleware(
    E12ValveContext* ctx,
    E12PreRequestMiddlewareFn middleware,
    void* user_data
);

/// Register response middleware via valve context
/// @param ctx Valve context handle
/// @param middleware Response middleware function
/// @param user_data User data passed to middleware
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_valve_context_register_response_middleware(
    E12ValveContext* ctx,
    E12ResponseMiddlewareFn middleware,
    void* user_data
);

/// Register a background task via valve context
/// @param ctx Valve context handle
/// @param name Task name
/// @param task Task function
/// @param interval_ms Interval in milliseconds (0 for one-time task)
/// @param user_data User data passed to task
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_valve_context_register_task(
    E12ValveContext* ctx,
    const char* name,
    E12BackgroundTaskFn task,
    uint32_t interval_ms,
    void* user_data
);

/// Register a health check via valve context
/// @param ctx Valve context handle
/// @param check Health check function
/// @param user_data User data passed to check
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_valve_context_register_health_check(
    E12ValveContext* ctx,
    E12HealthCheckFn check,
    void* user_data
);

/// Serve static files via valve context
/// @param ctx Valve context handle
/// @param mount_path Mount path
/// @param directory Directory path
/// @return E12_OK on success, error code on failure
E12ErrorCode e12_valve_context_serve_static(
    E12ValveContext* ctx,
    const char* mount_path,
    const char* directory
);

/// Get cache instance via valve context
/// @param ctx Valve context handle
/// @return Cache handle or NULL if not available
E12Cache* e12_valve_context_get_cache(E12ValveContext* ctx);

/// Get metrics instance via valve context
/// @param ctx Valve context handle
/// @return Metrics handle or NULL if not available
void* e12_valve_context_get_metrics(E12ValveContext* ctx);

#ifdef __cplusplus
}
#endif

#endif // ENGINE12_H

