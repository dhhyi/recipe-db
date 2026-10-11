const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = std.json.Value;

pub fn parse(a: Allocator, bytes: []const u8) !Value {
    return (try std.json.parseFromSlice(Value, a, bytes, .{ .allocate = .alloc_always })).value;
}
pub fn encode(a: Allocator, value: anytype) ![]const u8 {
    return try std.json.stringifyAlloc(a, value, .{});
}
pub fn object(a: Allocator) Value {
    return .{ .object = std.json.ObjectMap.init(a) };
}
pub fn str(value: []const u8) Value {
    return .{ .string = value };
}
pub fn get(value: Value, key: []const u8) !Value {
    if (value != .object) return error.InvalidDependencyResponse;
    return value.object.get(key) orelse error.InvalidDependencyResponse;
}
pub fn text(value: Value) ![]const u8 {
    if (value != .string) return error.InvalidDependencyResponse;
    return value.string;
}
pub fn array(value: Value) ![]Value {
    if (value != .array) return error.InvalidDependencyResponse;
    return value.array.items;
}
