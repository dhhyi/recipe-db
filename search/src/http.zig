const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;

pub const Response = struct { status: c_long, body: []const u8 };
const Sink = struct {
    bytes: std.ArrayList(u8),
    fn write(ptr: [*c]u8, size: usize, count: usize, ctx: ?*anyopaque) callconv(.C) usize {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        const len = size * count;
        if (len > 8 * 1024 * 1024 - self.bytes.items.len) return 0;
        self.bytes.appendSlice(ptr[0..len]) catch return 0;
        return len;
    }
};

pub fn http(a: Allocator, method: [:0]const u8, url: []const u8, body: ?[]const u8, key: ?[]const u8) !Response {
    const curl = c.curl_easy_init() orelse return error.CurlInit;
    defer c.curl_easy_cleanup(curl);
    var sink = Sink{ .bytes = std.ArrayList(u8).init(a) };
    var headers: ?*c.curl_slist = c.curl_slist_append(null, "Content-Type: application/json");
    if (headers == null) return error.OutOfMemory;
    defer c.curl_slist_free_all(headers);
    if (key) |k| {
        const next = c.curl_slist_append(headers, try std.fmt.allocPrintZ(a, "X-TYPESENSE-API-KEY: {s}", .{k}));
        if (next == null) return error.OutOfMemory;
        headers = next;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_URL, (try a.dupeZ(u8, url)).ptr) != c.CURLE_OK or
        c.curl_easy_setopt(curl, c.CURLOPT_CUSTOMREQUEST, method.ptr) != c.CURLE_OK or
        c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, headers) != c.CURLE_OK or
        c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, &Sink.write) != c.CURLE_OK or
        c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &sink) != c.CURLE_OK or
        c.curl_easy_setopt(curl, c.CURLOPT_TIMEOUT_MS, @as(c_long, 5000)) != c.CURLE_OK or
        c.curl_easy_setopt(curl, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, 1000)) != c.CURLE_OK or
        c.curl_easy_setopt(curl, c.CURLOPT_NOSIGNAL, @as(c_long, 1)) != c.CURLE_OK) return error.CurlConfig;
    if (body) |b| {
        if (c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDS, b.ptr) != c.CURLE_OK or
            c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(b.len))) != c.CURLE_OK) return error.CurlConfig;
    }
    const performed = c.curl_easy_perform(curl);
    if (performed != c.CURLE_OK) {
        std.log.err("HTTP dependency request failed: {s}", .{c.curl_easy_strerror(performed)});
        return error.DependencyUnavailable;
    }
    var status: c_long = 0;
    if (c.curl_easy_getinfo(curl, c.CURLINFO_RESPONSE_CODE, &status) != c.CURLE_OK) return error.CurlResponse;
    return .{ .status = status, .body = sink.bytes.items };
}
