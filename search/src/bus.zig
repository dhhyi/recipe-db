const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const Config = @import("config.zig").Config;

pub const durable = "search-index-v1";

pub fn natsCheck(status: c.natsStatus) !void {
    if (status != c.NATS_OK) {
        std.log.err("NATS: {s}", .{c.natsStatus_GetText(status)});
        return error.MessageBusUnavailable;
    }
}
pub const Bus = struct {
    connection: ?*c.natsConnection = null,
    js: ?*c.jsCtx = null,
    sub: ?*c.natsSubscription = null,
    pub fn close(self: *Bus) void {
        c.natsSubscription_Destroy(self.sub);
        c.jsCtx_Destroy(self.js);
        c.natsConnection_Destroy(self.connection);
        self.* = .{};
    }
    pub fn connect(self: *Bus, cfg: Config) !void {
        errdefer self.close();
        var options: ?*c.natsOptions = null;
        try natsCheck(c.natsOptions_Create(&options));
        defer c.natsOptions_Destroy(options);
        try natsCheck(c.natsOptions_SetURL(options, cfg.nats.ptr));
        try natsCheck(c.natsOptions_SetTimeout(options, 1000));
        try natsCheck(c.natsConnection_Connect(&self.connection, options));
        var js_options: c.jsOptions = undefined;
        try natsCheck(c.jsOptions_Init(&js_options));
        js_options.Wait = 1000;
        try natsCheck(c.natsConnection_JetStream(&self.js, self.connection, &js_options));
        var sub_options: c.jsSubOptions = undefined;
        try natsCheck(c.jsSubOptions_Init(&sub_options));
        sub_options.Stream = "RECIPE_EVENTS";
        sub_options.Consumer = durable;
        sub_options.ManualAck = true;
        try natsCheck(c.js_PullSubscribe(&self.sub, self.js, "recipes.events.v1", durable, null, &sub_options, null));
    }
};
