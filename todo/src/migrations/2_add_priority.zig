const Migration = @import("engine12").orm.Migration;

pub const migration = Migration.init(
    2,
    "add_priority",
    "ALTER TABLE todos ADD COLUMN priority TEXT NOT NULL DEFAULT 'medium'",
    "ALTER TABLE todos DROP COLUMN priority"
);

