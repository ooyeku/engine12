# Engine12

A professional backend framework for Zig, designed for building high-performance web applications and APIs.

## Quick Start

```zig
const std = @import("std");
const Engine12 = @import("Engine12");

fn handleRoot(req: *Engine12.Request) Engine12.Response {
    _ = req;
    return Engine12.Response.text("Hello, World!");
}

pub fn main() !void {
    var app = try Engine12.initDevelopment();
    defer app.deinit();

    try app.get("/", handleRoot);
    try app.start();
}
```

## Installation

### Step 1: Fetch the package

Run `zig fetch` to add Engine12 to your `build.zig.zon`:

```bash
zig fetch --save "git+https://github.com/ooyeku/engine12.git"
```

This will automatically add the dependency with the correct hash to your `build.zig.zon` file.

Alternatively, you can manually add it to your `build.zig.zon`:

```zig
.dependencies = .{
    .engine12 = .{
        .url = "git+https://github.com/ooyeku/engine12.git",
        .hash = "...", // Run `zig fetch` to get the hash
    },
},
```

### Step 2: Add to your build.zig

Add the dependency and module to your `build.zig`:

```zig
const engine12_dep = b.dependency("engine12", .{
    .target = target,
    .optimize = optimize,
});

exe.addModule("engine12", engine12_dep.module("engine12"));
```

If you're using the ORM or C API, you'll also need to link libc:

```zig
// Link libc (required for ORM and C API functionality)
exe.linkLibC();
```

## Features

- **HTTP Routing** - GET, POST, PUT, DELETE, PATCH with route parameters
- **WebSocket Support** - Real-time bidirectional communication with room management
- **Hot Reloading** - Automatic template and static file reloading in development mode
- **Structured Logging** - JSON and human-readable logging with multiple destinations (stdout, file, syslog)
- **Middleware System** - Pre-request and response middleware chains
- **SQLite ORM** - Type-safe database operations with migrations
- **Template Engine** - Server-side HTML rendering
- **Request/Response API** - Clean, memory-safe HTTP handling
- **Rate Limiting** - Per-route rate limiting
- **CSRF Protection** - Built-in CSRF token validation
- **Metrics & Health Checks** - Request timing and health monitoring
- **Background Tasks** - Periodic and one-time task scheduling
- **Static File Serving** - Serve static assets
- **C API** - Language bindings for non-Zig code

See [TODO.md](TODO.md) for a complete feature list and roadmap.

## Documentation

- [API Reference](docs/api-reference.md) - Complete API documentation
- [Tutorial](docs/tutorial.md) - Step-by-step guide to building your first app
- [Architecture Guide](docs/architecture.md) - System design and architecture
- [Examples](docs/examples/todo-app.md) - Complete todo app walkthrough
- [Troubleshooting](docs/troubleshooting.md) - Common issues and solutions

## Example

See the [todo app example](todo/src/app.zig) for a complete working application demonstrating:

- Database setup and migrations
- CRUD operations with the ORM
- Template rendering
- Route handlers
- Frontend integration

## Requirements

- Zig 0.15.1 or later

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Contributing

Contributions welcome! Please see our contributing guidelines.
