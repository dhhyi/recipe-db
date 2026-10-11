const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Config = struct {
    graphql: []const u8,
    typesense: []const u8,
    key: []const u8,
    nats: [:0]const u8,
    port: u16,
    state_dir: [:0]const u8,
    checkpoint: u64,

    pub fn load(a: Allocator) !Config {
        const file = try std.process.getEnvVarOwned(a, "TYPESENSE_API_KEY_FILE");
        const key = std.mem.trim(u8, try std.fs.cwd().readFileAlloc(a, file, 4096), " \r\n");
        if (key.len == 0 or std.mem.indexOfAny(u8, key, "\r\n") != null) return error.InvalidApiKey;
        const port = std.process.getEnvVarOwned(a, "PORT") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => "3000",
            else => return err,
        };
        const state_dir = std.process.getEnvVarOwned(a, "STATE_DIRECTORY") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => "/data",
            else => return err,
        };
        if (!std.fs.path.isAbsolute(state_dir)) return error.InvalidStateDirectory;
        const saved = std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ state_dir, "checkpoint" }), 32) catch |err| switch (err) {
            error.FileNotFound => "0",
            else => return err,
        };
        return .{
            .graphql = try std.process.getEnvVarOwned(a, "GRAPHQL_URL"),
            .typesense = try std.process.getEnvVarOwned(a, "TYPESENSE_URL"),
            .key = key,
            .nats = try a.dupeZ(u8, try std.process.getEnvVarOwned(a, "NATS_URL")),
            .port = try std.fmt.parseInt(u16, port, 10),
            .state_dir = try a.dupeZ(u8, state_dir),
            .checkpoint = try std.fmt.parseInt(u64, std.mem.trim(u8, saved, " \n"), 10),
        };
    }
};
