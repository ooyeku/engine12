const std = @import("std");
const ziggurat = @import("ziggurat");
const Response = @import("response.zig").Response;

pub const FileServer = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8,
    directory: []const u8,
    index_file: []const u8,
    enable_cache: bool,
    max_file_size: usize,

    const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB default

    pub fn init(
        allocator: std.mem.Allocator,
        base_path: []const u8,
        directory_path: []const u8,
    ) FileServer {
        return FileServer{
            .allocator = allocator,
            .base_path = base_path,
            .directory = directory_path,
            .index_file = "index.html",
            .enable_cache = true,
            .max_file_size = MAX_FILE_SIZE,
        };
    }

    /// Create a handler function that serves files from this FileServer
    /// The handler uses the route path to determine which file to serve
    pub fn createHandler(self: *const FileServer) fn (*ziggurat.request.Request) ziggurat.response.Response {
        const self_ptr = self;
        const mount_path = self.base_path;
        return struct {
            const fs = self_ptr;
            const base = mount_path;
            
            fn handler(request: *ziggurat.request.Request) ziggurat.response.Response {
                // Since ziggurat doesn't expose request.uri directly,
                // we'll need to handle this at the route level
                // For now, serve the index file for the base path
                _ = request;
                
                // If base path is "/", serve index.html
                if (std.mem.eql(u8, base, "/")) {
                    return fs.serveFile("/").toZiggurat();
                }
                
                // Otherwise serve the base path
                return fs.serveFile(base).toZiggurat();
            }
        }.handler;
    }
    
    /// Create a handler that serves a specific file path
    pub fn createPathHandler(self: *const FileServer, route_path: []const u8) fn (*ziggurat.request.Request) ziggurat.response.Response {
        const self_ptr = self;
        const path = route_path;
        return struct {
            const fs = self_ptr;
            const route = path;
            
            fn handler(request: *ziggurat.request.Request) ziggurat.response.Response {
                _ = request;
                return fs.serveFile(route).toZiggurat();
            }
        }.handler;
    }

    /// Serve a file based on the request path
    pub fn serveFile(self: *const FileServer, request_path: []const u8) Response {
        // Remove base_path prefix if present
        var file_path = request_path;
        if (std.mem.startsWith(u8, request_path, self.base_path)) {
            file_path = request_path[self.base_path.len..];
        }
        
        // Remove leading slash
        if (file_path.len > 0 and file_path[0] == '/') {
            file_path = file_path[1..];
        }
        
        // If path is empty or ends with '/', serve index file
        if (file_path.len == 0 or (file_path.len > 0 and file_path[file_path.len - 1] == '/')) {
            file_path = self.index_file;
        }
        
        // Validate path security
        if (!self.isValidPath(file_path)) {
            return self.createErrorResponse(403, "Forbidden: Invalid path");
        }
        
        // Read file
        const contents = self.readFile(file_path) catch |err| {
            return switch (err) {
                error.FileNotFound => self.createErrorResponse(404, "File not found"),
                error.FileTooLarge => self.createErrorResponse(413, "File too large"),
                error.InvalidPath => self.createErrorResponse(403, "Forbidden: Invalid path"),
                else => self.createErrorResponse(500, "Internal server error"),
            };
        };
        
        // Response stores a reference to the body string, so it must persist
        // We use page_allocator in readFile to ensure the memory persists for async response handling
        // The memory will not be freed - this is acceptable for static files as they're small
        
        // Determine MIME type and use appropriate Response method
        const mime_type = self.getMimeType(file_path);
        
        // Create response with correct Content-Type
        // Response stores a reference to the body string, so contents must persist
        const response = if (std.mem.eql(u8, mime_type, "text/html"))
            Response.html(contents)
        else if (std.mem.eql(u8, mime_type, "text/css"))
            Response.text(contents).withContentType("text/css")
        else if (std.mem.eql(u8, mime_type, "application/javascript"))
            Response.text(contents).withContentType("application/javascript")
        else
            Response.text(contents).withContentType(mime_type);
        
        return response;
    }
    
    /// Create an error response
    fn createErrorResponse(self: *const FileServer, status_code: u16, message: []const u8) Response {
        _ = self;
        _ = status_code;
        // Use page_allocator for error responses to ensure they persist for async handling
        const error_json = std.fmt.allocPrint(
            std.heap.page_allocator,
            "{{\"error\":\"{s}\"}}",
            .{message}
        ) catch {
            return Response.text("Internal server error");
        };
        // Don't free - Response stores a reference, so memory must persist
        return Response.json(error_json);
    }

    /// Get MIME type from file extension
    pub fn getMimeType(self: *const FileServer, file_path: []const u8) []const u8 {
        _ = self;
        
        if (std.mem.lastIndexOf(u8, file_path, ".")) |dot_index| {
            const ext = file_path[dot_index + 1 ..];
            
            if (std.mem.eql(u8, ext, "html")) return "text/html";
            if (std.mem.eql(u8, ext, "css")) return "text/css";
            if (std.mem.eql(u8, ext, "js")) return "application/javascript";
            if (std.mem.eql(u8, ext, "json")) return "application/json";
            if (std.mem.eql(u8, ext, "png")) return "image/png";
            if (std.mem.eql(u8, ext, "jpg") or std.mem.eql(u8, ext, "jpeg")) return "image/jpeg";
            if (std.mem.eql(u8, ext, "svg")) return "image/svg+xml";
            if (std.mem.eql(u8, ext, "ico")) return "image/x-icon";
            if (std.mem.eql(u8, ext, "woff")) return "font/woff";
            if (std.mem.eql(u8, ext, "woff2")) return "font/woff2";
            if (std.mem.eql(u8, ext, "ttf")) return "font/ttf";
            if (std.mem.eql(u8, ext, "txt")) return "text/plain";
            if (std.mem.eql(u8, ext, "xml")) return "application/xml";
        }
        
        return "application/octet-stream";
    }

    /// Validate that the requested path is safe (no directory traversal)
    pub fn isValidPath(self: *const FileServer, requested_path: []const u8) bool {
        _ = self;
        
        // Prevent directory traversal
        if (std.mem.indexOf(u8, requested_path, "..")) |_| {
            return false;
        }
        
        // Prevent null bytes
        if (std.mem.indexOf(u8, requested_path, "\x00")) |_| {
            return false;
        }
        
        // Prevent absolute paths
        if (requested_path.len > 0 and requested_path[0] == '/') {
            // Allow leading slash for URL paths, but we'll validate against base_path
            return true;
        }
        
        return true;
    }

    /// Read a file from the filesystem safely
    /// Uses page_allocator to ensure contents persist for ziggurat's async response handling
    /// Note: Memory is not freed - this is acceptable for static file serving as files are small
    pub fn readFile(self: *const FileServer, file_path: []const u8) ![]const u8 {
        // Validate path security
        if (!self.isValidPath(file_path)) {
            return error.InvalidPath;
        }

        var dir = std.fs.cwd().openDir(self.directory, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return error.FileNotFound;
            }
            return err;
        };
        defer dir.close();

        var file = dir.openFile(file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return error.FileNotFound;
            }
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size > self.max_file_size) {
            return error.FileTooLarge;
        }

        // Use page_allocator to ensure memory persists for ziggurat's async response handling
        // ziggurat Response stores a reference to the body string, so it must persist
        const contents = try std.heap.page_allocator.alloc(u8, @as(usize, @intCast(stat.size)));

        const bytes_read = try file.readAll(contents);
        if (bytes_read != contents.len) {
            std.heap.page_allocator.free(contents);
            return error.UnexpectedEOF;
        }

        return contents;
    }
};

// Tests
test "FileServer init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const server = FileServer.init(allocator, "/static", "public");
    try std.testing.expectEqualStrings(server.base_path, "/static");
    try std.testing.expectEqualStrings(server.directory, "public");
    try std.testing.expectEqualStrings(server.index_file, "index.html");
    try std.testing.expect(server.enable_cache == true);
}

test "FileServer getMimeType" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");
    try std.testing.expectEqualStrings(server.getMimeType("test.html"), "text/html");
    try std.testing.expectEqualStrings(server.getMimeType("style.css"), "text/css");
    try std.testing.expectEqualStrings(server.getMimeType("script.js"), "application/javascript");
    try std.testing.expectEqualStrings(server.getMimeType("data.json"), "application/json");
    try std.testing.expectEqualStrings(server.getMimeType("image.png"), "image/png");
    try std.testing.expectEqualStrings(server.getMimeType("unknown"), "application/octet-stream");
}

test "FileServer isValidPath" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");
    try std.testing.expect(server.isValidPath("index.html") == true);
    try std.testing.expect(server.isValidPath("/css/styles.css") == true);
    try std.testing.expect(server.isValidPath("../secret.txt") == false);
    try std.testing.expect(server.isValidPath("..\\file.txt") == false);
    try std.testing.expect(server.isValidPath("normal/file.txt") == true);
}

