const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const Config = @import("config.zig").Config;
const Index = @import("index.zig").Index;
const collection = @import("index.zig").collection;
const escape = @import("index.zig").escape;
const State = @import("state.zig").State;
const Response = @import("http.zig").Response;
const json = @import("json.zig");
const Value = json.Value;
const parse = json.parse;
const encode = json.encode;
const str = json.str;
const get = json.get;
const text = json.text;
const array = json.array;

fn search(index: *Index, a: Allocator, options: Value) !Response {
    if (options != .object) return error.InvalidSearchOptions;
    var query = std.ArrayList(u8).init(a);
    try query.appendSlice(collection ++ "/documents/search?");
    if (!options.object.contains("query_by")) try query.appendSlice("query_by=name,method,ingredients&");
    if (!options.object.contains("num_typos")) try query.appendSlice("num_typos=2&");
    var entries = options.object.iterator();
    while (entries.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "highlight_fields") or std.mem.eql(u8, key, "highlight_full_fields") or
            std.mem.eql(u8, key, "include_fields") or std.mem.eql(u8, key, "exclude_fields")) continue;
        const value = switch (entry.value_ptr.*) {
            .string => |v| v,
            .integer, .float, .bool => try encode(a, entry.value_ptr.*),
            else => return error.InvalidSearchOptions,
        };
        try query.writer().print("{s}={s}&", .{ try escape(a, key), try escape(a, value) });
    }
    try query.appendSlice("highlight_fields=none&highlight_full_fields=none&include_fields=id");
    const response = try index.typesense(a, "GET", query.items, null);
    if (response.status != 200) return response;
    const root = try parse(a, response.body);
    var ids = std.ArrayList(Value).init(a);
    if (root != .object) return error.InvalidDependencyResponse;
    if (root.object.get("hits")) |hits| {
        for (try array(hits)) |hit| try ids.append(str(try text(try get(try get(hit, "document"), "id"))));
    } else {
        for (try array(try get(root, "grouped_hits"))) |group| {
            for (try array(try get(group, "hits"))) |hit| try ids.append(str(try text(try get(try get(hit, "document"), "id"))));
        }
    }
    return .{ .status = 200, .body = try encode(a, .{
        .recipeIds = ids.items,
        .facetCounts = try get(root, "facet_counts"),
        .found = try get(root, "found"),
        .outOf = try get(root, "out_of"),
        .page = try get(root, "page"),
        .perPage = try get(try get(root, "request_params"), "per_page"),
    }) };
}

fn problem(request: *std.http.Server.Request, a: Allocator, status: std.http.Status, code: []const u8, detail: []const u8) !void {
    const body = try encode(a, .{ .type = "about:blank", .title = status.phrase(), .status = @intFromEnum(status), .detail = detail, .code = code });
    try request.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/problem+json" }} });
}
fn serve(request: *std.http.Server.Request, a: Allocator, cfg: Config, state: *State) !void {
    const path = request.head.target;
    if (std.mem.startsWith(u8, path, "/search/reindex/")) {
        if (request.head.method != .GET) return problem(request, a, .method_not_allowed, "method-not-allowed", "Use GET to inspect a rebuild job.");
        const id = std.fmt.parseInt(u64, path["/search/reindex/".len..], 10) catch return problem(request, a, .bad_request, "invalid-job-id", "Expected a numeric rebuild job ID.");
        state.mutex.lock();
        const result = state.results[id % state.results.len];
        const requested = state.requested;
        const completed = state.completed;
        const active = state.active;
        state.mutex.unlock();
        if (id == 0 or id > requested) return problem(request, a, .not_found, "job-not-found", "Unknown rebuild job.");
        if (result) |job| if (job.jobId == id) {
            if (job.failed) |failure| return problem(request, a, .internal_server_error, "reindex-failed", try std.fmt.allocPrint(a, "The rebuild failed ({s}); inspect service logs and restore the affected dependency before retrying.", .{failure}));
            return request.respond(try encode(a, .{ .jobId = id, .status = "succeeded" }), .{ .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        };
        if (id <= completed) return problem(request, a, .gone, "job-result-expired", "Result is no longer retained; success is unknown.");
        return request.respond(try encode(a, .{ .jobId = id, .status = if (active == id) "running" else "pending" }), .{ .status = .accepted, .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
    }
    if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/search/reindex")) {
        if (std.mem.eql(u8, path, "/search/reindex") and request.head.method == .POST) {
            const job = state.request();
            try request.respond(try encode(a, .{ .jobId = job }), .{ .status = .accepted, .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
            return;
        }
        if (request.head.method != .GET) return problem(request, a, .method_not_allowed, "method-not-allowed", "Use GET, or POST to request a rebuild.");
        try request.respond(try state.status(a), .{ .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        return;
    }
    if (!std.mem.eql(u8, path, "/search")) return problem(request, a, .not_found, "route-not-found", "Unknown search route.");
    if (request.head.method != .POST) return problem(request, a, .method_not_allowed, "method-not-allowed", "Use POST /search with a JSON object of Typesense options.");
    state.mutex.lock();
    const ready = state.ready;
    state.mutex.unlock();
    if (!ready) return problem(request, a, .service_unavailable, "index-not-ready", "Baseline or rebuild incomplete.");
    const reader = request.reader() catch return problem(request, a, .bad_request, "invalid-search-options", "Could not read request body.");
    const body = reader.readAllAlloc(a, 16384) catch return problem(request, a, .bad_request, "invalid-search-options", "Expected a JSON object, at most 16384 bytes.");
    const options = parse(a, body) catch return problem(request, a, .bad_request, "invalid-search-options", "Invalid JSON.");
    var index = Index{ .cfg = cfg };
    const response = search(&index, a, options) catch |err| {
        std.log.err("search failed: {s}", .{@errorName(err)});
        return problem(request, a, if (err == error.InvalidSearchOptions) .bad_request else .service_unavailable, if (err == error.InvalidSearchOptions) "invalid-search-options" else "search-dependency-unavailable", if (err == error.InvalidSearchOptions) "Expected a flat JSON object of string, number or boolean Typesense options." else "Search could not reach or validate its Typesense dependency.");
    };
    if (response.status != 200) {
        const invalid = response.status == 400 or response.status == 422;
        return problem(request, a, if (invalid) .bad_request else .service_unavailable, if (invalid) "invalid-search-options" else "search-dependency-unavailable", if (invalid) response.body else "Typesense rejected the search request.");
    }
    try request.respond(response.body, .{ .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
}

pub fn run(cfg: Config, state: *State) !void {
    var listener = try (try std.net.Address.parseIp("0.0.0.0", cfg.port)).listen(.{ .reuse_address = true });
    defer listener.deinit();
    std.log.info("search listening on {d}", .{cfg.port});
    while (true) {
        const connection = try listener.accept();
        defer connection.stream.close();
        var timeout = c.timeval{ .tv_sec = 5, .tv_usec = 0 };
        if (c.setsockopt(connection.stream.handle, c.SOL_SOCKET, c.SO_RCVTIMEO, &timeout, @sizeOf(c.timeval)) != 0) {
            std.log.err("failed to configure HTTP receive timeout", .{});
            continue;
        }
        var buffer: [32768]u8 = undefined;
        var server = std.http.Server.init(connection, &buffer);
        var request = server.receiveHead() catch |err| {
            std.log.warn("invalid HTTP request: {s}", .{@errorName(err)});
            continue;
        };
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        serve(&request, arena.allocator(), cfg, state) catch |err| std.log.err("HTTP response failed: {s}", .{@errorName(err)});
    }
}
