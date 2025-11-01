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

// Error codes
typedef enum {
    E12_OK = 0,
    E12_ERROR_INVALID_ARGUMENT = 1,
    E12_ERROR_TOO_MANY_ROUTES = 2,
    E12_ERROR_SERVER_ALREADY_BUILT = 3,
    E12_ERROR_ALLOCATION_FAILED = 4,
    E12_ERROR_SERVER_START_FAILED = 5,
    E12_ERROR_INVALID_PATH = 6,
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

#ifdef __cplusplus
}
#endif

#endif // ENGINE12_H

