const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const Config = @import("config.zig").Config;
const Response = @import("http.zig").Response;
const http = @import("http.zig").http;
const natsCheck = @import("bus.zig").natsCheck;
const json = @import("json.zig");
const Value = json.Value;
const parse = json.parse;
const encode = json.encode;
const object = json.object;
const str = json.str;
const get = json.get;
const text = json.text;
const array = json.array;

pub const collection = "/collections/recipes_v1";
const fields = "id name method ingredients { name amount unit optional }";

pub const Index = struct {
    cfg: Config,
    message: ?*c.natsMsg = null,
    checkpoint: u64 = 0,

    pub fn saveCheckpoint(self: *Index, sequence: u64) !void {
        // O_PATH directory descriptors cannot be fsynced on Linux.
        var dir = try std.fs.openDirAbsolute(self.cfg.state_dir, .{ .iterate = true });
        defer dir.close();
        var file = try dir.createFile("checkpoint.tmp", .{ .mode = 0o600 });
        defer file.close();
        var buffer: [32]u8 = undefined;
        try file.writeAll(try std.fmt.bufPrint(&buffer, "{d}\n", .{sequence}));
        try file.sync();
        try dir.rename("checkpoint.tmp", "checkpoint");
        if (c.fsync(dir.fd) != 0) return error.CheckpointSyncFailed;
        self.checkpoint = sequence;
    }

    pub fn progress(self: *Index) !void {
        if (self.message) |m| try natsCheck(c.natsMsg_InProgress(m, null));
    }
    pub fn typesense(self: *Index, a: Allocator, method: [:0]const u8, path: []const u8, body: ?[]const u8) !Response {
        try self.progress();
        return http(a, method, try std.mem.concat(a, u8, &.{ self.cfg.typesense, path }), body, self.cfg.key);
    }
    fn gql(self: *Index, a: Allocator, query: []const u8, variables: Value) !Value {
        try self.progress();
        const response = try http(a, "POST", self.cfg.graphql, try encode(a, .{ .query = query, .variables = variables }), null);
        if (response.status != 200) return error.GraphqlUnavailable;
        const root = try parse(a, response.body);
        if (root != .object) return error.InvalidDependencyResponse;
        if (root.object.get("errors")) |errs| {
            if (errs != .array or errs.array.items.len != 0) return error.GraphqlError;
        }
        return get(root, "data");
    }
    fn schema(self: *Index, a: Allocator) !void {
        const existing = try self.typesense(a, "GET", collection, null);
        if (existing.status == 200) return;
        if (existing.status != 404) return error.TypesenseUnavailable;
        const response = try self.typesense(a, "POST", "/collections", @embedFile("schema.json"));
        if (response.status != 201) return error.TypesenseSchema;
    }
    fn previous(self: *Index, a: Allocator, id: []const u8) !?Value {
        const response = try self.typesense(a, "GET", try docPath(a, id), null);
        if (response.status == 404) return null;
        if (response.status != 200) return error.TypesenseUnavailable;
        return try parse(a, response.body);
    }
    fn remove(self: *Index, a: Allocator, id: []const u8) !void {
        const response = try self.typesense(a, "DELETE", try docPath(a, id), null);
        if (response.status != 200 and response.status != 404) return error.TypesenseUnavailable;
    }
    fn optional(self: *Index, a: Allocator, doc: *Value, old: ?Value, vars: Value, source: []const u8, names: []const []const u8) !void {
        const selection = if (std.mem.eql(u8, source, "rating")) "rating { average count }" else if (std.mem.eql(u8, source, "image")) "image { __typename }" else "inspirations { url }";
        const query = try std.fmt.allocPrint(a, "query($id: ID!) {{ recipe(id: $id) {{ {s} }} }}", .{selection});
        const data = self.gql(a, query, vars) catch |err| {
            std.log.err("optional source {s} unavailable: {s}", .{ source, @errorName(err) });
            return preserve(doc, old, names);
        };
        const recipe = try get(data, "recipe");
        // A core recipe disappearing between requests is retried, never interpreted as optional absence.
        if (recipe == .null) return error.SourceChangedDuringReload;
        const value = try get(recipe, source);
        if (value == .null and !std.mem.eql(u8, source, "image")) {
            std.log.err("optional source {s} unavailable (GraphQL null)", .{source});
            return preserve(doc, old, names);
        }
        if (std.mem.eql(u8, source, "image")) {
            if (value != .null and value != .object) return error.InvalidDependencyResponse;
            try doc.object.put("has_image", .{ .bool = value != .null });
        } else if (std.mem.eql(u8, source, "inspirations")) {
            var urls = std.ArrayList(Value).init(a);
            for (try array(value)) |link| try urls.append(str(try text(try get(link, "url"))));
            try doc.object.put("inspiration_urls", .{ .array = urls });
        } else {
            for ([_][]const u8{ "average", "count" }, names) |field, name| {
                const v = try get(value, field);
                if (v != .null) try doc.object.put(name, v);
            }
        }
    }
    pub fn reload(self: *Index, a: Allocator, id: []const u8) !bool {
        var vars = object(a);
        try vars.object.put("id", str(id));
        const query = "query($id: ID!) { recipe(id: $id) { " ++ fields ++ " } }";
        const recipe = try get(try self.gql(a, query, vars), "recipe");
        if (recipe == .null) {
            try self.remove(a, id);
            return false;
        }
        if (!std.mem.eql(u8, try text(try get(recipe, "id")), id)) return error.InvalidDependencyResponse;
        const old = try self.previous(a, id);
        var doc = object(a);
        try doc.object.put("id", str(id));
        try doc.object.put("name", str(try text(try get(recipe, "name"))));
        const method = try get(recipe, "method");
        if (method != .null) try doc.object.put("method", str(try text(method)));
        var ingredients = std.ArrayList(Value).init(a);
        var units = std.ArrayList(Value).init(a);
        const items = try get(recipe, "ingredients");
        if (items != .null) for (try array(items)) |ingredient| {
            try ingredients.append(str(try text(try get(ingredient, "name"))));
            const unit = try get(ingredient, "unit");
            if (unit != .null) try units.append(str(try text(unit)));
        };
        try doc.object.put("ingredients", .{ .array = ingredients });
        try doc.object.put("ingredient_units", .{ .array = units });
        try self.optional(a, &doc, old, vars, "rating", &.{ "rating_average", "rating_count" });
        try self.optional(a, &doc, old, vars, "image", &.{"has_image"});
        try self.optional(a, &doc, old, vars, "inspirations", &.{"inspiration_urls"});
        // POST upsert replaces the whole document, unlike PATCH which retains omitted fields.
        const response = try self.typesense(a, "POST", collection ++ "/documents?action=upsert", try encode(a, doc));
        if (response.status != 200 and response.status != 201) return error.TypesenseWriteFailed;
        return true;
    }
    pub fn rebuild(self: *Index, a: Allocator) !void {
        try self.schema(a);
        const recipes = try array(try get(try self.gql(a, "{ recipes { id } }", object(a)), "recipes"));
        var ids = std.StringHashMap(void).init(a);
        for (recipes) |recipe| {
            const id = try text(try get(recipe, "id"));
            try ids.put(id, {});
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            _ = try self.reload(arena.allocator(), id);
        }
        const exported = try self.typesense(a, "GET", collection ++ "/documents/export", null);
        if (exported.status != 200) return error.TypesenseUnavailable;
        var lines = std.mem.tokenizeScalar(u8, exported.body, '\n');
        while (lines.next()) |line| {
            const id = try text(try get(try parse(a, line), "id"));
            if (!ids.contains(id)) {
                // Recheck the source rather than treating an old list snapshot as proof of deletion.
                _ = try self.reload(a, id);
            }
        }
    }
};

fn preserve(doc: *Value, old: ?Value, names: []const []const u8) !void {
    const previous = old orelse return error.OptionalSourceUnavailableWithoutPreviousDocument;
    if (previous != .object) return error.InvalidDependencyResponse;
    for (names) |name| if (previous.object.get(name)) |v| {
        try doc.object.put(name, v);
    };
}
pub fn escape(a: Allocator, value: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-_.~", ch) != null) {
            try out.append(ch);
        } else try out.writer().print("%{X:0>2}", .{ch});
    }
    return out.items;
}
fn docPath(a: Allocator, id: []const u8) ![]const u8 {
    return std.mem.concat(a, u8, &.{ collection, "/documents/", try escape(a, id) });
}

test "unavailable optional source requires a previous document, including known absence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = object(a);
    try std.testing.expectError(error.OptionalSourceUnavailableWithoutPreviousDocument, preserve(&doc, null, &.{"has_image"}));
    var old = object(a);
    try old.object.put("has_image", .{ .bool = false });
    try preserve(&doc, old, &.{"has_image"});
    try std.testing.expect(!(try get(doc, "has_image")).bool);
    try old.object.put("has_image", .{ .bool = true });
    try preserve(&doc, old, &.{"has_image"});
    try std.testing.expect((try get(doc, "has_image")).bool);
    var absent = object(a);
    try preserve(&absent, object(a), &.{"has_image"});
    try std.testing.expect(!absent.object.contains("has_image"));
}

test "checkpoint persists across reloads and failed writes do not advance it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try tmp.dir.realpathAlloc(a, ".");
    var index = Index{ .cfg = .{
        .graphql = "",
        .typesense = "",
        .key = "",
        .nats = "",
        .port = 0,
        .state_dir = try a.dupeZ(u8, path),
        .checkpoint = 0,
    } };
    try index.saveCheckpoint(41);
    try std.testing.expectEqual(@as(u64, 41), index.checkpoint);
    try std.testing.expectEqualStrings("41\n", try tmp.dir.readFileAlloc(a, "checkpoint", 32));
    try index.saveCheckpoint(42);
    try std.testing.expectEqualStrings("42\n", try tmp.dir.readFileAlloc(a, "checkpoint", 32));
    index.cfg.state_dir = try std.fmt.allocPrintZ(a, "{s}/missing", .{path});
    try std.testing.expectError(error.FileNotFound, index.saveCheckpoint(43));
    try std.testing.expectEqual(@as(u64, 42), index.checkpoint);
    try std.testing.expectEqualStrings("42\n", try tmp.dir.readFileAlloc(a, "checkpoint", 32));
}
