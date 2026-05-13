const std = @import("std");

pub fn to_epoch_seconds(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) error{InvalidDate}!i64 {
    if (year < 1970) return error.InvalidDate;
    if (month < 1 or month > 12) return error.InvalidDate;
    if (day < 1) return error.InvalidDate;

    const days_per_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = is_leap_year(year);

    const max_day: u8 = if (month == 2 and leap)
        29
    else
        days_per_month[month - 1];
    if (day > max_day) return error.InvalidDate;

    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        days += if (is_leap_year(y)) 366 else 365;
    }
    for (0..month - 1) |m| {
        const month_days: u8 = if (m == 1 and leap) 29 else days_per_month[m];
        days += month_days;
    }
    days += @as(i64, day) - 1;

    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

fn is_leap_year(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

test "to_epoch_seconds returns 0 for Unix epoch" {
    const result = try to_epoch_seconds(1970, 1, 1, 0, 0, 0);
    try std.testing.expectEqual(@as(i64, 0), result);
}

test "to_epoch_seconds computes known date correctly" {
    const result = try to_epoch_seconds(2026, 4, 10, 12, 0, 0);
    try std.testing.expectEqual(@as(i64, 1775822400), result);
}

test "to_epoch_seconds rejects invalid month" {
    try std.testing.expectError(error.InvalidDate, to_epoch_seconds(2026, 0, 1, 0, 0, 0));
    try std.testing.expectError(error.InvalidDate, to_epoch_seconds(2026, 13, 1, 0, 0, 0));
}

test "to_epoch_seconds rejects invalid day" {
    try std.testing.expectError(error.InvalidDate, to_epoch_seconds(2026, 1, 0, 0, 0, 0));
    try std.testing.expectError(error.InvalidDate, to_epoch_seconds(2026, 1, 32, 0, 0, 0));
}

test "to_epoch_seconds accepts Feb 29 in leap years" {
    // 2000 is a leap year (divisible by 400)
    _ = try to_epoch_seconds(2000, 2, 29, 0, 0, 0);
    // 2024 is a leap year (divisible by 4, not by 100)
    _ = try to_epoch_seconds(2024, 2, 29, 0, 0, 0);
    // 1900 is not a leap year (divisible by 100 but not 400)
    try std.testing.expectError(error.InvalidDate, to_epoch_seconds(1900, 2, 29, 0, 0, 0));
    // 2023 is not a leap year
    try std.testing.expectError(error.InvalidDate, to_epoch_seconds(2023, 2, 29, 0, 0, 0));
}

test "to_epoch_seconds rejects Feb 30 in any year" {
    try std.testing.expectError(error.InvalidDate, to_epoch_seconds(2024, 2, 30, 0, 0, 0));
    try std.testing.expectError(error.InvalidDate, to_epoch_seconds(2000, 2, 30, 0, 0, 0));
}

test "to_epoch_seconds rejects Apr 31 and other invalid month-day combinations" {
    // April has 30 days
    try std.testing.expectError(error.InvalidDate, to_epoch_seconds(2024, 4, 31, 0, 0, 0));
    // June has 30 days
    try std.testing.expectError(error.InvalidDate, to_epoch_seconds(2024, 6, 31, 0, 0, 0));
    // November has 30 days
    try std.testing.expectError(error.InvalidDate, to_epoch_seconds(2024, 11, 31, 0, 0, 0));
    // January has 31 days — day 31 is valid
    _ = try to_epoch_seconds(2024, 1, 31, 0, 0, 0);
}

test "to_epoch_seconds rejects pre-1970 year" {
    try std.testing.expectError(error.InvalidDate, to_epoch_seconds(1969, 12, 31, 23, 59, 59));
    try std.testing.expectError(error.InvalidDate, to_epoch_seconds(1900, 1, 1, 0, 0, 0));
    try std.testing.expectError(error.InvalidDate, to_epoch_seconds(0, 1, 1, 0, 0, 0));
}
