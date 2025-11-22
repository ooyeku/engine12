const Migration = @import("engine12").orm.Migration;

pub const migration = Migration.init(
    3,
    "add_due_date",
    "ALTER TABLE todos ADD COLUMN due_date INTEGER",
    "-- Cannot automatically reverse ALTER TABLE ADD COLUMN"
);

