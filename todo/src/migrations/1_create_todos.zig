const Migration = @import("engine12").orm.Migration;

pub const migration = Migration.init(
    1,
    "create_todos",
    \\CREATE TABLE IF NOT EXISTS todos (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  title TEXT NOT NULL,
    \\  description TEXT NOT NULL,
    \\  completed INTEGER NOT NULL DEFAULT 0,
    \\  created_at INTEGER NOT NULL,
    \\  updated_at INTEGER NOT NULL
    \\)
,
    "DROP TABLE IF EXISTS todos"
);

