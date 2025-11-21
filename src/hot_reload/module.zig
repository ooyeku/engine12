// Hot reload module for engine12
// Provides hot reloading support for development mode

pub const watcher = @import("watcher.zig");
pub const runtime_template = @import("runtime_template.zig");
pub const runtime_renderer = @import("runtime_renderer.zig");
pub const manager = @import("manager.zig");

// Re-export main types for convenience
pub const FileWatcher = watcher.FileWatcher;
pub const RuntimeTemplate = runtime_template.RuntimeTemplate;
pub const HotReloadManager = manager.HotReloadManager;

