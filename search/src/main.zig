const std = @import("std");
const c = @import("c.zig").c;
const Config = @import("config.zig").Config;
const State = @import("state.zig").State;
const worker = @import("worker.zig").worker;
const api = @import("api.zig");

pub fn main() !void {
    if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != c.CURLE_OK) return error.CurlInit;
    const cfg = try Config.load(std.heap.page_allocator);
    try std.fs.cwd().makePath(cfg.state_dir);
    if (c.geteuid() == 0) {
        if (c.chown(cfg.state_dir.ptr, 65534, 65534) != 0 or c.chmod(cfg.state_dir.ptr, 0o700) != 0) return error.StateDirectoryPermissionsFailed;
        if (c.setgroups(0, null) != 0 or c.setgid(65534) != 0 or c.setuid(65534) != 0) return error.PrivilegeDropFailed;
    }
    var state = State{};
    const thread = try std.Thread.spawn(.{}, worker, .{ cfg, &state });
    thread.detach();
    try api.run(cfg, &state);
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
