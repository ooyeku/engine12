const Migration = @import("engine12").orm.Migration;

pub const migration = Migration.init(
    4,
    "add_tags",
    "ALTER TABLE todos ADD COLUMN tags TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE todos DROP COLUMN tags"
);

