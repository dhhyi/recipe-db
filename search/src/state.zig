const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const encode = json.encode;

pub const State = struct {
    mutex: std.Thread.Mutex = .{},
    requested: u64 = 1,
    completed: u64 = 0,
    active: u64 = 0,
    ready: bool = false,
    connected: bool = false,
    last_error: ?[]const u8 = null,
    event_error: ?[]const u8 = null,
    pending_messages: u64 = 0,
    outstanding_acks: i64 = 0,
    redelivered: i64 = 0,
    checkpoint: u64 = 0,
    stream_end: u64 = 0,
    retention_gap: bool = false,
    results: [16]?Job = .{null} ** 16,

    const Job = struct { jobId: u64, failed: ?[]const u8 };

    pub fn complete(self: *State, job: u64, failure: ?[]const u8) void {
        self.completed = job;
        self.active = 0;
        self.last_error = failure;
        self.ready = failure == null;
        self.results[job % self.results.len] = .{ .jobId = job, .failed = failure };
    }

    pub fn request(self: *State) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.requested <= @max(self.active, self.completed)) self.requested += 1;
        return self.requested;
    }
    pub fn status(self: *State, a: Allocator) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return encode(a, .{ .requested = self.requested, .completed = self.completed, .active = self.active, .ready = self.ready, .connected = self.connected, .lastError = self.last_error, .eventError = self.event_error, .pendingMessages = self.pending_messages, .outstandingAcks = self.outstanding_acks, .redelivered = self.redelivered, .checkpoint = self.checkpoint, .retentionGap = self.retention_gap, .results = self.results });
    }
};
