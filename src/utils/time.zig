const std = @import("std");

/// Timestamp and date/time utilities
/// Provides convenient functions for working with timestamps and dates
pub const Time = struct {
    /// Get current timestamp in milliseconds since Unix epoch
    /// 
    /// Example:
    /// ```zig
    /// const now = Time.nowMillis();
    /// ```
    pub fn nowMillis() i64 {
        return std.time.milliTimestamp();
    }

    /// Get current timestamp in seconds since Unix epoch
    /// 
    /// Example:
    /// ```zig
    /// const now = Time.nowSeconds();
    /// ```
    pub fn nowSeconds() i64 {
        return std.time.timestamp();
    }

    /// Format a timestamp as ISO 8601 string (YYYY-MM-DDTHH:MM:SSZ)
    /// 
    /// Example:
    /// ```zig
    /// const timestamp = Time.nowMillis();
    /// const formatted = try Time.formatTimestamp(timestamp, allocator);
    /// defer allocator.free(formatted);
    /// ```
    pub fn formatTimestamp(timestamp: i64, allocator: std.mem.Allocator) ![]const u8 {
        // Convert milliseconds to seconds if needed
        const seconds = if (timestamp > 1000000000000) @divTrunc(timestamp, 1000) else timestamp;
        
        const epoch = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(seconds)) };
        const epoch_day = epoch.getEpochDay();
        const day_seconds = epoch.getDaySeconds();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        
        const year = year_day.year;
        const month = month_day.month.numeric();
        const day = month_day.day_index + 1;
        const hour = day_seconds.getHoursIntoDay();
        const minute = day_seconds.getMinutesIntoHour();
        const second = day_seconds.getSecondsIntoMinute();
        
        return std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
            .{ year, month, day, hour, minute, second },
        );
    }

    /// Parse an ISO 8601 timestamp string to milliseconds
    /// Supports formats: YYYY-MM-DDTHH:MM:SSZ, YYYY-MM-DDTHH:MM:SS
    /// 
    /// Example:
    /// ```zig
    /// const timestamp = try Time.parseTimestamp("2024-01-15T10:30:00Z");
    /// ```
    pub fn parseTimestamp(iso_string: []const u8) !i64 {
        // Simple parser for ISO 8601 format: YYYY-MM-DDTHH:MM:SSZ
        if (iso_string.len < 19) {
            return error.InvalidTimestamp;
        }

        // Parse year
        const year = try std.fmt.parseInt(i32, iso_string[0..4], 10);
        
        // Parse month
        const month = try std.fmt.parseInt(u8, iso_string[5..7], 10);
        if (month < 1 or month > 12) {
            return error.InvalidTimestamp;
        }
        
        // Parse day
        const day = try std.fmt.parseInt(u8, iso_string[8..10], 10);
        if (day < 1 or day > 31) {
            return error.InvalidTimestamp;
        }
        
        // Parse hour
        const hour = try std.fmt.parseInt(u8, iso_string[11..13], 10);
        if (hour > 23) {
            return error.InvalidTimestamp;
        }
        
        // Parse minute
        const minute = try std.fmt.parseInt(u8, iso_string[14..16], 10);
        if (minute > 59) {
            return error.InvalidTimestamp;
        }
        
        // Parse second
        const second = try std.fmt.parseInt(u8, iso_string[17..19], 10);
        if (second > 59) {
            return error.InvalidTimestamp;
        }

        // Calculate timestamp (simplified - doesn't handle leap years, etc.)
        // This is a basic implementation
        const days_since_epoch = calculateDaysSinceEpoch(year, month, day);
        const seconds_since_epoch = days_since_epoch * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
        
        return seconds_since_epoch * 1000; // Return in milliseconds
    }

    /// Format a timestamp as a readable date string
    /// Format: "January 15, 2024"
    /// 
    /// Example:
    /// ```zig
    /// const timestamp = Time.nowMillis();
    /// const formatted = try Time.formatDate(timestamp, allocator);
    /// defer allocator.free(formatted);
    /// ```
    pub fn formatDate(timestamp: i64, allocator: std.mem.Allocator) ![]const u8 {
        // Convert milliseconds to seconds if needed
        const seconds = if (timestamp > 1000000000000) @divTrunc(timestamp, 1000) else timestamp;
        
        const epoch = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(seconds)) };
        const epoch_day = epoch.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        
        const year = year_day.year;
        const month = month_day.month;
        const day = month_day.day_index + 1;
        
        const month_names = [_][]const u8{
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December",
        };
        
        const month_name = month_names[@as(usize, @intFromEnum(month)) - 1];
        
        return std.fmt.allocPrint(
            allocator,
            "{s} {d}, {d}",
            .{ month_name, day, year },
        );
    }

    fn calculateDaysSinceEpoch(year: i32, month: u8, day: u8) i64 {
        // Simplified calculation (doesn't handle leap years perfectly)
        const year_diff = year - 1970;
        var days: i64 = @as(i64, @intCast(year_diff)) * 365;
        
        // Add days for leap years
        const leap_years = (year - 1969) / 4;
        days += @as(i64, @intCast(leap_years));
        
        // Add days for months (simplified - assumes 30 days per month)
        days += @as(i64, @intCast(month - 1)) * 30;
        
        // Add days
        days += @as(i64, @intCast(day - 1));
        
        return days;
    }
};

// Tests
test "Time.nowMillis" {
    const now = Time.nowMillis();
    try std.testing.expect(now > 0);
}

test "Time.nowSeconds" {
    const now = Time.nowSeconds();
    try std.testing.expect(now > 0);
}

test "Time.formatTimestamp" {
    const allocator = std.testing.allocator;
    // Use a known timestamp: January 1, 2024 00:00:00 UTC
    const timestamp: i64 = 1704067200000; // Approximate
    const formatted = try Time.formatTimestamp(timestamp, allocator);
    defer allocator.free(formatted);
    
    // Should contain year 2024
    try std.testing.expect(std.mem.indexOf(u8, formatted, "2024") != null);
}

test "Time.formatDate" {
    const allocator = std.testing.allocator;
    const timestamp = Time.nowMillis();
    const formatted = try Time.formatDate(timestamp, allocator);
    defer allocator.free(formatted);
    
    // Should contain a month name
    const months = [_][]const u8{ "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December" };
    var found = false;
    for (months) |month| {
        if (std.mem.indexOf(u8, formatted, month) != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

