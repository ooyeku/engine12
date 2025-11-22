const Migration = @import("engine12").orm.Migration;

pub const migration = Migration.init(
    5,
    "add_user_id",
    \\ALTER TABLE todos ADD COLUMN user_id INTEGER NOT NULL DEFAULT 1;
    \\CREATE INDEX IF NOT EXISTS idx_todo_user_id ON todos(user_id);
,
    "-- Cannot automatically reverse ALTER TABLE ADD COLUMN"
);

