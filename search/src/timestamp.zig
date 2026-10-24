const std = @import("std");

/// Parse RFC 3339 into Unix microseconds without consulting the clock.
pub fn microseconds(value: []const u8) !i64 {
    if (value.len < 20) return error.InvalidTimestamp;
    for ([_]usize{ 4, 7, 13, 16 }, "--::") |i, separator| {
        if (value[i] != separator) return error.InvalidTimestamp;
    }
    if (value[10] != 'T' and value[10] != 't') return error.InvalidTimestamp;
    const year = try digits(value[0..4]);
    const month = try digits(value[5..7]);
    const day = try digits(value[8..10]);
    const hour = try digits(value[11..13]);
    const minute = try digits(value[14..16]);
    const second = try digits(value[17..19]);
    if (month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59) return error.InvalidTimestamp;
    const months = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day > months[@intCast(month - 1)] + @as(i64, if (month == 2 and leap(year)) 1 else 0)) return error.InvalidTimestamp;

    var pos: usize = 19;
    var fraction: i64 = 0;
    if (value[pos] == '.') {
        pos += 1;
        const start = pos;
        while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) {
            if (pos - start < 6) fraction = fraction * 10 + value[pos] - '0';
        }
        if (pos == start) return error.InvalidTimestamp;
        var precision = pos - start;
        while (precision < 6) : (precision += 1) fraction *= 10;
    }
    if (pos >= value.len) return error.InvalidTimestamp;
    var offset: i64 = 0;
    if (value[pos] == 'Z' or value[pos] == 'z') {
        if (pos + 1 != value.len) return error.InvalidTimestamp;
    } else {
        if ((value[pos] != '+' and value[pos] != '-') or value.len - pos != 6 or value[pos + 3] != ':') return error.InvalidTimestamp;
        const hours = try digits(value[pos + 1 .. pos + 3]);
        const minutes = try digits(value[pos + 4 .. pos + 6]);
        if (hours > 23 or minutes > 59) return error.InvalidTimestamp;
        offset = (hours * 60 + minutes) * 60;
        if (value[pos] == '-') offset = -offset;
    }
    // Count proleptic Gregorian days relative to 1970, including pre-epoch dates.
    var days: i64 = 0;
    var y: i64 = 0;
    while (y < year) : (y += 1) days += if (leap(y)) @as(i64, 366) else 365;
    days -= 719528;
    for (months[0..@intCast(month - 1)], 0..) |length, i| {
        days += length + @as(i64, if (i == 1 and leap(year)) 1 else 0);
    }
    days += day - 1;
    return ((days * 24 + hour) * 3600 + minute * 60 + second - offset) * 1_000_000 + fraction;
}

fn digits(value: []const u8) !i64 {
    for (value) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidTimestamp;
    return std.fmt.parseInt(i64, value, 10) catch error.InvalidTimestamp;
}

fn leap(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

test "RFC3339 preserves microseconds and normalizes offsets and pre-epoch dates" {
    try std.testing.expectEqual(@as(i64, 0), try microseconds("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, -1), try microseconds("1969-12-31T23:59:59.999999Z"));
    try std.testing.expectEqual(@as(i64, 123456), try microseconds("1970-01-01T01:30:00.123456+01:30"));
    try std.testing.expectEqual(@as(i64, 123456), try microseconds("1969-12-31t22:30:00.123456789-01:30"));
    try std.testing.expectEqual(@as(i64, 120000), try microseconds("1970-01-01t00:00:00.12z"));
    try std.testing.expectEqual(@as(i64, 951782400000000), try microseconds("2000-02-29T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 1791464400123456), try microseconds("2026-10-08T13:00:00.123456Z"));
}

test "malformed or impossible timestamps cannot silently default" {
    for ([_][]const u8{
        "",                          "0",                         "2026-10-08",               "2026-10-08 13:00:00Z",
        "2026-10-08T13:00:00",       "2026-10-08T13:00:00.Z",     "2026-10-08T13:00:00Zjunk", "2026-10-08T13:00:00+0100",
        "2026-10-08T13:00:00+24:00", "2026-10-08T13:00:00+00:60", "2026-02-29T13:00:00Z",     "1900-02-29T13:00:00Z",
        "2026-00-01T13:00:00Z",      "2026-13-01T13:00:00Z",      "2026-01-00T13:00:00Z",     "2026-04-31T13:00:00Z",
        "2026-10-08T24:00:00Z",      "2026-10-08T13:60:00Z",      "2026-10-08T13:00:60Z",     "202x-10-08T13:00:00Z",
    }) |value| try std.testing.expectError(error.InvalidTimestamp, microseconds(value));
}
