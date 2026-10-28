const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const Config = @import("config.zig").Config;
const Index = @import("index.zig").Index;
const State = @import("state.zig").State;
const Bus = @import("bus.zig").Bus;
const durable = @import("bus.zig").durable;
const natsCheck = @import("bus.zig").natsCheck;
const Event = @import("events.zig").Event;
const event = @import("events.zig").event;

fn deadline(now: i64, succeeded: bool) i64 {
    return now + if (succeeded) @as(i64, 24 * 60 * 60) else @as(i64, 30);
}

fn inspectBus(bus: *Bus, state: *State, checkpoint: u64) !bool {
    var info: ?*c.jsConsumerInfo = null;
    try natsCheck(c.js_GetConsumerInfo(&info, bus.js, "RECIPE_EVENTS", durable, null, null));
    defer c.jsConsumerInfo_Destroy(info);
    const cfg = info.?.Config.*;
    if (cfg.AckPolicy != c.js_AckExplicit or cfg.DeliverPolicy != c.js_DeliverAll or
        cfg.MaxAckPending != 16 or cfg.MaxWaiting != 16 or cfg.MaxDeliver != -1 or
        cfg.DeliverSubject != null or cfg.BackOffLen != 3 or
        cfg.BackOff[0] != 30 * std.time.ns_per_s or cfg.BackOff[1] != 60 * std.time.ns_per_s or
        cfg.BackOff[2] != 300 * std.time.ns_per_s or
        cfg.FilterSubject == null or !std.mem.eql(u8, std.mem.span(cfg.FilterSubject), "recipes.events.v1")) return error.ConsumerContractMismatch;
    var stream: ?*c.jsStreamInfo = null;
    try natsCheck(c.js_GetStreamInfo(&stream, bus.js, "RECIPE_EVENTS", null, null));
    defer c.jsStreamInfo_Destroy(stream);
    state.mutex.lock();
    defer state.mutex.unlock();
    state.pending_messages = info.?.NumPending;
    state.outstanding_acks = info.?.NumAckPending;
    state.redelivered = info.?.NumRedelivered;
    state.stream_end = stream.?.State.LastSeq;
    state.retention_gap = (stream.?.State.FirstSeq > checkpoint and stream.?.State.FirstSeq - checkpoint > 1) or stream.?.State.LastSeq < checkpoint;
    return state.retention_gap;
}

pub fn worker(cfg: Config, state: *State) void {
    var bus = Bus{};
    defer bus.close();
    var index = Index{ .cfg = cfg, .checkpoint = cfg.checkpoint };
    var next_rebuild: i64 = 0;
    var next_inspect: i64 = 0;
    var retention_gap = false;
    var messages: c.natsMsgList = std.mem.zeroes(c.natsMsgList);
    defer c.natsMsgList_Destroy(&messages);
    var next_event_retry: i64 = 0;
    while (true) {
        index.message = if (messages.Count > 0) messages.Msgs[0] else null;
        if (bus.sub == null) {
            bus.connect(cfg) catch |err| {
                state.mutex.lock();
                state.connected = false;
                state.event_error = @errorName(err);
                state.mutex.unlock();
                std.Thread.sleep(2 * std.time.ns_per_s);
                continue;
            };
            state.mutex.lock();
            state.connected = true;
            state.mutex.unlock();
            _ = state.request();
            next_inspect = 0;
        }
        const now = std.time.timestamp();
        if (now >= next_inspect) {
            const gap = inspectBus(&bus, state, index.checkpoint) catch |err| {
                std.log.err("message bus inspection failed: {s}", .{@errorName(err)});
                state.mutex.lock();
                state.connected = false;
                state.event_error = @errorName(err);
                state.mutex.unlock();
                index.message = null;
                c.natsMsgList_Destroy(&messages);
                messages = std.mem.zeroes(c.natsMsgList);
                bus.close();
                std.Thread.sleep(2 * std.time.ns_per_s);
                continue;
            };
            if (gap and !retention_gap) {
                std.log.err("retained history does not cover durable checkpoint; rebuilding", .{});
                _ = state.request();
            }
            retention_gap = gap;
            next_inspect = now + 10;
        }
        state.mutex.lock();
        if (now >= next_rebuild and state.requested <= state.completed) state.requested += 1;
        const job = if (state.requested > state.completed) state.requested else 0;
        if (job != 0) {
            state.active = job;
            state.ready = false;
        }
        state.mutex.unlock();
        if (job != 0) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            state.mutex.lock();
            const watermark = state.stream_end;
            state.mutex.unlock();
            const result = rebuild(&index, arena.allocator(), watermark);
            arena.deinit();
            state.mutex.lock();
            if (result) {
                state.complete(job, null);
                state.checkpoint = index.checkpoint;
                next_rebuild = deadline(std.time.timestamp(), true);
                std.log.info("rebuild {d} completed", .{job});
            } else |err| {
                state.complete(job, @errorName(err));
                next_rebuild = deadline(std.time.timestamp(), false);
                std.log.err("rebuild {d} FAILED: {s}", .{ job, @errorName(err) });
            }
            state.mutex.unlock();
        }
        if (now < next_event_retry) {
            std.Thread.sleep(std.time.ns_per_s);
            continue;
        }
        if (messages.Count == 0) {
            const fetched = c.natsSubscription_Fetch(&messages, bus.sub, 1, 1000, null);
            if (fetched == c.NATS_TIMEOUT) continue;
            if (fetched != c.NATS_OK) {
                natsCheck(fetched) catch {};
                c.natsMsgList_Destroy(&messages);
                messages = std.mem.zeroes(c.natsMsgList);
                bus.close();
                state.mutex.lock();
                state.connected = false;
                state.event_error = "MessageBusUnavailable";
                state.mutex.unlock();
                continue;
            }
        }
        const msg = messages.Msgs[0];
        index.message = msg;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const payload = c.natsMsg_GetData(msg)[0..@intCast(c.natsMsg_GetDataLength(msg))];
        const envelope = event(a, payload) catch |err| {
            std.log.err("MALFORMED/UNSUPPORTED event requires operator recovery: {s}", .{@errorName(err)});
            natsCheck(c.natsMsg_NakWithDelay(msg, 300000, null)) catch |nak_err| std.log.err("NAK failed: {s}", .{@errorName(nak_err)});
            state.mutex.lock();
            state.event_error = @errorName(err);
            state.mutex.unlock();
            next_event_retry = std.time.timestamp() + 300;
            continue;
        };
        const outcome = process(&index, a, envelope, msg);
        const done = if (outcome) natsCheck(c.natsMsg_AckSync(msg, null, null)) else |err| failed: {
            std.log.err("event unfinished: {s}", .{@errorName(err)});
            break :failed @as(anyerror!void, err);
        };
        state.mutex.lock();
        state.event_error = if (done) null else |err| @errorName(err);
        state.checkpoint = index.checkpoint;
        state.mutex.unlock();
        if (done) {
            index.message = null;
            c.natsMsgList_Destroy(&messages);
            messages = std.mem.zeroes(c.natsMsgList);
            next_event_retry = 0;
        } else |_| next_event_retry = std.time.timestamp() + 5;
    }
}
fn rebuild(index: *Index, a: Allocator, watermark: u64) !void {
    try index.rebuild(a);
    try index.saveCheckpoint(watermark);
}

fn process(index: *Index, a: Allocator, e: Event, msg: ?*c.natsMsg) !void {
    var metadata: ?*c.jsMsgMetaData = null;
    try natsCheck(c.natsMsg_GetMetaData(&metadata, msg));
    defer c.jsMsgMetaData_Destroy(metadata);
    try index.progress();
    _ = try index.reload(a, e.recipeId);
    try index.saveCheckpoint(@max(index.checkpoint, metadata.?.Sequence.Stream));
}

test "daily schedule, failed rebuild retry and overlapping jobs" {
    try std.testing.expectEqual(@as(i64, 86410), deadline(10, true));
    try std.testing.expectEqual(@as(i64, 40), deadline(10, false));
    var state = State{};
    try std.testing.expectEqual(@as(u64, 1), state.request());
    state.active = 1;
    try std.testing.expectEqual(@as(u64, 2), state.request());
    try std.testing.expectEqual(@as(u64, 2), state.request());
    state.complete(1, "GraphqlError");
    state.complete(2, null);
    try std.testing.expectEqualStrings("GraphqlError", state.results[1].?.failed.?);
    try std.testing.expect(state.results[2].?.failed == null);
}
