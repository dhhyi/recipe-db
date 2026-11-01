const std = @import("std");
const c = @import("c.zig").c;
const Config = @import("config.zig").Config;
const State = @import("state.zig").State;
const worker = @import("worker.zig").worker;
const api = @import("api.zig");

const RuntimeMode = enum { production, testing, backup };

fn parseMode(value: ?[]const u8) !RuntimeMode {
    const configured = value orelse "production";
    if (std.mem.eql(u8, configured, "production")) return .production;
    if (std.mem.eql(u8, configured, "testing")) return .testing;
    if (std.mem.eql(u8, configured, "backup")) return .backup;
    return error.InvalidRuntimeMode;
}

fn terminate(_: c_int) callconv(.C) void {
    std.posix.exit(0);
}

pub fn main() !void {
    // As PID 1 the process ignores SIGTERM unless a handler is installed.
    const action = std.posix.Sigaction{ .handler = .{ .handler = terminate }, .mask = std.posix.empty_sigset, .flags = 0 };
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    const mode_value = std.process.getEnvVarOwned(std.heap.page_allocator, "MODE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    const mode = try parseMode(mode_value);
    if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != c.CURLE_OK) return error.CurlInit;
    const cfg = try Config.load(std.heap.page_allocator);
    try std.fs.cwd().makePath(cfg.state_dir);
    if (c.geteuid() == 0) {
        if (c.chown(cfg.state_dir.ptr, 65534, 65534) != 0 or c.chmod(cfg.state_dir.ptr, 0o700) != 0) return error.StateDirectoryPermissionsFailed;
        if (c.setgroups(0, null) != 0 or c.setgid(65534) != 0 or c.setuid(65534) != 0) return error.PrivilegeDropFailed;
    }
    var state = State{};
    if (mode != .backup) {
        const thread = try std.Thread.spawn(.{}, worker, .{ cfg, &state });
        thread.detach();
    }
    try api.run(cfg, &state, mode == .backup);
}

test {
    std.testing.refAllDeclsRecursive(@This());
}

test "runtime modes default to production and reject unsupported values" {
    try std.testing.expectEqual(RuntimeMode.production, try parseMode(null));
    try std.testing.expectEqual(RuntimeMode.testing, try parseMode("testing"));
    try std.testing.expectEqual(RuntimeMode.backup, try parseMode("backup"));
    try std.testing.expectError(error.InvalidRuntimeMode, parseMode(""));
    try std.testing.expectError(error.InvalidRuntimeMode, parseMode("unknown"));
}
