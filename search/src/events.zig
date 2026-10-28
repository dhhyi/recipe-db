const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const encode = json.encode;

pub const Event = struct {
    version: u64,
    eventId: []const u8,
    occurredAt: []const u8,
    recipeId: []const u8,
    kind: []const u8,
};
pub fn event(a: Allocator, body: []const u8) !Event {
    if (body.len > 4096) return error.InvalidEvent;
    const e = (try std.json.parseFromSlice(Event, a, body, .{ .ignore_unknown_fields = true })).value;
    if (e.version != 1 or e.eventId.len != 36 or !utcTimestamp(e.occurredAt)) return error.InvalidEvent;
    for (e.eventId, 0..) |ch, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (ch != '-') return error.InvalidEvent;
        } else if (!std.ascii.isHex(ch)) return error.InvalidEvent;
    }
    const single = [_][]const u8{ "recipe.changed", "recipe.deleted", "rating.changed", "image.changed", "inspirations.changed" };
    for (single) |kind| if (std.mem.eql(u8, kind, e.kind)) {
        if (e.recipeId.len == 0) return error.InvalidEvent;
        return e;
    };
    return error.InvalidEvent;
}

fn utcTimestamp(value: []const u8) bool {
    if (value.len < 20 or value[value.len - 1] != 'Z') return false;
    for ([_]usize{ 4, 7, 10, 13, 16 }, "--T::") |i, separator| {
        if (value[i] != separator) return false;
    }
    for (value[0..19], 0..) |ch, i| {
        if (i != 4 and i != 7 and i != 10 and i != 13 and i != 16 and !std.ascii.isDigit(ch)) return false;
    }
    if (value.len > 20) {
        if (value[19] != '.' or value.len < 22) return false;
        for (value[20 .. value.len - 1]) |ch| if (!std.ascii.isDigit(ch)) return false;
    }
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return false;
    const hour = std.fmt.parseInt(u8, value[11..13], 10) catch return false;
    const minute = std.fmt.parseInt(u8, value[14..16], 10) catch return false;
    const second = std.fmt.parseInt(u8, value[17..19], 10) catch return false;
    if (year == 0 or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 60) return false;
    const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    const max_day = days[month - 1] + @as(u8, if (month == 2 and leap) 1 else 0);
    return day > 0 and day <= max_day;
}

test "event contract rejects invalid envelopes and unsupported kinds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const valid = "{\"version\":1,\"eventId\":\"53cf7722-2b64-4e9f-a267-8b4d1f878302\",\"occurredAt\":\"2026-10-08T13:00:00Z\",\"recipeId\":\"42\",\"kind\":\"recipe.changed\",\"extra\":true}";
    try std.testing.expectEqualStrings("42", (try event(a, valid)).recipeId);
    try std.testing.expectError(error.InvalidEvent, event(a, "{\"version\":2,\"eventId\":\"53cf7722-2b64-4e9f-a267-8b4d1f878302\",\"occurredAt\":\"2026-10-08T13:00:00Z\",\"recipeId\":\"42\",\"kind\":\"recipe.changed\"}"));
    try std.testing.expectError(error.InvalidEvent, event(a, "{\"version\":1,\"eventId\":\"53cf7722-2b64-4e9f-a267-8b4d1f878302\",\"occurredAt\":\"2026-10-08T13:00:00Z\",\"recipeId\":\"42\",\"kind\":\"unknown\"}"));
}
test "event kinds and UTC timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = Event{ .version = 1, .eventId = "53cf7722-2b64-4e9f-a267-8b4d1f878302", .occurredAt = "2026-10-08T13:00:00Z", .recipeId = "", .kind = "recipe.changed" };
    for ([_][]const u8{ "recipe.changed", "recipe.deleted", "rating.changed", "image.changed", "inspirations.changed" }) |kind| {
        e.kind = kind;
        try std.testing.expectError(error.InvalidEvent, event(a, try encode(a, e)));
        e.recipeId = "42";
        _ = try event(a, try encode(a, e));
        e.recipeId = "";
    }
    try std.testing.expect(utcTimestamp("2024-02-29T13:00:00.123Z"));
    try std.testing.expect(!utcTimestamp("2026-02-29T13:00:00Z"));
    try std.testing.expect(!utcTimestamp("2026-10-08T24:00:00Z"));
    try std.testing.expect(!utcTimestamp("2026-10-08T13:00:00+01:00"));
}
