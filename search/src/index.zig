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
const operations = @import("operations.zig");

pub const collection = "/collections/recipes";

const OptionalSource = enum { rating, image, inspirations };
const GraphqlResponse = struct {
    data: Value,
    failed: std.EnumSet(OptionalSource) = std.EnumSet(OptionalSource).initEmpty(),
};

fn graphqlResponse(root: Value, allow_optional_errors: bool) !GraphqlResponse {
    if (root != .object) return error.InvalidDependencyResponse;
    var result = GraphqlResponse{ .data = try get(root, "data") };
    if (root.object.get("errors")) |errors| {
        for (try array(errors)) |err| {
            if (!allow_optional_errors) return error.GraphqlError;
            _ = try text(try get(err, "message"));
            const path = try array(try get(err, "path"));
            if (path.len < 2 or !std.mem.eql(u8, try text(path[0]), "recipe")) return error.GraphqlError;
            const source = std.meta.stringToEnum(OptionalSource, try text(path[1])) orelse return error.GraphqlError;
            for (path[2..]) |segment| switch (segment) {
                .string => {},
                .integer => |index| if (index < 0) return error.InvalidDependencyResponse,
                else => return error.InvalidDependencyResponse,
            };
            result.failed.insert(source);
        }
    }
    // Only an error-free null recipe confirms deletion.
    if (result.failed.count() != 0 and try get(result.data, "recipe") == .null) return error.GraphqlError;
    return result;
}

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
    fn gql(self: *Index, a: Allocator, query: []const u8, variables: Value, allow_optional_errors: bool) !GraphqlResponse {
        try self.progress();
        const response = try http(a, "POST", self.cfg.graphql, try encode(a, .{ .query = query, .variables = variables }), null);
        if (response.status != 200) return error.GraphqlUnavailable;
        return graphqlResponse(try parse(a, response.body), allow_optional_errors);
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
    pub fn reload(self: *Index, a: Allocator, id: []const u8) !bool {
        var vars = object(a);
        try vars.object.put("id", str(id));
        const response = try self.gql(a, operations.IndexRecipe, vars, true);
        const recipe = try get(response.data, "recipe");
        if (recipe == .null) {
            try self.remove(a, id);
            return false;
        }
        const old = try self.previous(a, id);
        const doc = try recipeDocument(a, recipe, response.failed, old, id);
        // POST upsert replaces the whole document, unlike PATCH which retains omitted fields.
        const written = try self.typesense(a, "POST", collection ++ "/documents?action=upsert", try encode(a, doc));
        if (written.status != 200 and written.status != 201) return error.TypesenseWriteFailed;
        return true;
    }
    pub fn rebuild(self: *Index, a: Allocator) !void {
        try self.schema(a);
        const response = try self.gql(a, operations.RecipeIds, object(a), false);
        const recipes = try array(try get(response.data, "recipes"));
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

fn recipeDocument(a: Allocator, recipe: Value, failed: std.EnumSet(OptionalSource), old: ?Value, id: []const u8) !Value {
    if (!std.mem.eql(u8, try text(try get(recipe, "id")), id)) return error.InvalidDependencyResponse;
    var doc = object(a);
    try doc.object.put("id", str(id));
    try doc.object.put("recipe_id_sort", str(id));
    try doc.object.put("name", str(try text(try get(recipe, "name"))));
    try doc.object.put("name_sort", str(try text(try get(recipe, "nameSortKey"))));
    inline for (.{ .{ "createdAt", "created_at" }, .{ "updatedAt", "updated_at" } }) |fields| {
        const value = sourceTimestamp(recipe, fields[0]) catch |err| {
            std.log.warn("recipe {s}: invalid required metadata {s}: {s}", .{ id, fields[0], @errorName(err) });
            return err;
        };
        try doc.object.put(fields[1], .{ .integer = value });
    }
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
    try optional(a, &doc, old, recipe, failed, .rating, &.{ "rating_average", "rating_count" });
    try optional(a, &doc, old, recipe, failed, .image, &.{"has_image"});
    try optional(a, &doc, old, recipe, failed, .inspirations, &.{"inspiration_urls"});
    return doc;
}

fn optional(a: Allocator, doc: *Value, old: ?Value, recipe: Value, failed: std.EnumSet(OptionalSource), source: OptionalSource, names: []const []const u8) !void {
    if (failed.contains(source)) {
        std.log.warn("optional source {s} unavailable (GraphQL error)", .{@tagName(source)});
        return preserve(doc, old, names);
    }
    const value = try get(recipe, @tagName(source));
    if (value == .null and source != .image) {
        std.log.warn("optional source {s} unavailable (GraphQL null)", .{@tagName(source)});
        return preserve(doc, old, names);
    }
    switch (source) {
        .image => {
            if (value != .null and value != .object) return error.InvalidDependencyResponse;
            try doc.object.put("has_image", .{ .bool = value != .null });
        },
        .inspirations => {
            var urls = std.ArrayList(Value).init(a);
            for (try array(value)) |link| try urls.append(str(try text(try get(link, "url"))));
            try doc.object.put("inspiration_urls", .{ .array = urls });
        },
        .rating => {
            for ([_][]const u8{ "average", "count" }, names) |field, name| {
                const v = try get(value, field);
                try doc.object.put(name, if (v == .null) .{ .integer = 0 } else v);
            }
        },
    }
}

fn preserve(doc: *Value, old: ?Value, names: []const []const u8) !void {
    const previous = old orelse return error.OptionalSourceUnavailableWithoutPreviousDocument;
    if (previous != .object) return error.InvalidDependencyResponse;
    for (names) |name| if (previous.object.get(name)) |v| {
        try doc.object.put(name, v);
    };
}

fn sourceTimestamp(recipe: Value, field: []const u8) !i64 {
    return @import("timestamp.zig").microseconds(try text(try get(recipe, field)));
}

test "required source metadata and name key are copied, never synthesized" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const failed = std.EnumSet(OptionalSource).initEmpty();
    var recipe = try parse(a, recipeFixture);
    const doc = try recipeDocument(a, recipe, failed, null, "r1");
    try std.testing.expectEqualStrings("updated", try text(try get(doc, "name_sort")));
    try std.testing.expectEqualStrings("r1", try text(try get(doc, "recipe_id_sort")));
    try std.testing.expectEqual(@as(i64, 1791464400123456), (try get(doc, "created_at")).integer);
    try std.testing.expectEqual(try sourceTimestamp(recipe, "updatedAt"), (try get(doc, "updated_at")).integer);
    for ([_][]const u8{ "createdAt", "updatedAt", "nameSortKey" }) |field| {
        const original = try get(recipe, field);
        _ = recipe.object.swapRemove(field);
        try std.testing.expectError(error.InvalidDependencyResponse, recipeDocument(a, recipe, failed, doc, "r1"));
        try recipe.object.put(field, .null);
        try std.testing.expectError(error.InvalidDependencyResponse, recipeDocument(a, recipe, failed, doc, "r1"));
        try recipe.object.put(field, original);
    }
    try recipe.object.put("createdAt", str("not a timestamp"));
    try std.testing.expectError(error.InvalidTimestamp, recipeDocument(a, recipe, failed, doc, "r1"));
}

test "unrated values become sortable zeros and optional reloads preserve source dates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var recipe = try parse(a, recipeFixture);
    try recipe.object.put("rating", try parse(a, "{\"average\":null,\"count\":0}"));
    const doc = try recipeDocument(a, recipe, std.EnumSet(OptionalSource).initEmpty(), null, "r1");
    try std.testing.expectEqual(@as(i64, 0), (try get(doc, "rating_average")).integer);
    try std.testing.expectEqual(@as(i64, 0), (try get(doc, "rating_count")).integer);
    try recipe.object.put("rating", .null);
    const reloaded = try recipeDocument(a, recipe, std.EnumSet(OptionalSource).initEmpty(), doc, "r1");
    for ([_][]const u8{ "created_at", "updated_at", "rating_average", "rating_count" }) |field| {
        try std.testing.expectEqual((try get(doc, field)).integer, (try get(reloaded, field)).integer);
    }
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

const recipeFixture =
    \\{"id":"r1","name":"Updated","nameSortKey":"updated","createdAt":"2026-10-08T13:00:00.123456Z",
    \\"updatedAt":"2026-10-09T14:00:00.654321Z","method":null,"ingredients":[],
    \\"rating":{"average":5,"count":2},"image":null,"inspirations":[]}
;
const previousFixture =
    \\{"id":"r1","name":"Old","method":"Old method","rating_average":3,"rating_count":1,
    \\"has_image":true,"inspiration_urls":["https://old.example"]}
;

test "mixed GraphQL success updates healthy sources and preserves only failed sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try parse(a, previousFixture);
    for ([_][]const u8{
        \\["recipe","image"]
        ,
        \\["recipe","rating","average"]
        ,
        \\["recipe","inspirations",0,"url"]
        ,
    }, [_]OptionalSource{ .image, .rating, .inspirations }) |path, source| {
        const root = try parse(a, try std.fmt.allocPrint(a,
            \\{{"data":{{"recipe":{s}}},"errors":[{{"message":"source failed","path":{s}}}]}}
        , .{ recipeFixture, path }));
        const response = try graphqlResponse(root, true);
        var recipe = try get(response.data, "recipe");
        // async-graphql can omit failed fields instead of serializing them as null.
        _ = recipe.object.swapRemove(@tagName(source));
        const doc = try recipeDocument(a, recipe, response.failed, old, "r1");
        try std.testing.expectEqualStrings("Updated", try text(try get(doc, "name")));
        try std.testing.expect(!doc.object.contains("method"));
        try std.testing.expectEqual(source == .image, (try get(doc, "has_image")).bool);
        try std.testing.expectEqual(@as(i64, if (source == .rating) 3 else 5), (try get(doc, "rating_average")).integer);
        try std.testing.expectEqual(@as(i64, if (source == .rating) 1 else 2), (try get(doc, "rating_count")).integer);
        const urls = try array(try get(doc, "inspiration_urls"));
        try std.testing.expectEqual(@as(usize, if (source == .inspirations) 1 else 0), urls.len);
        if (urls.len != 0) try std.testing.expectEqualStrings("https://old.example", try text(urls[0]));
        try std.testing.expectError(error.OptionalSourceUnavailableWithoutPreviousDocument, recipeDocument(a, recipe, response.failed, null, "r1"));
        try std.testing.expectError(error.GraphqlError, graphqlResponse(root, false));
    }
}

test "null optional sources preserve old values while confirmed absence clears them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try parse(a, previousFixture);
    var recipe = try parse(a, recipeFixture);
    try recipe.object.put("rating", .null);
    try recipe.object.put("inspirations", .null);
    const failed = std.EnumSet(OptionalSource).initEmpty();
    const doc = try recipeDocument(a, recipe, failed, old, "r1");
    try std.testing.expectEqual(@as(i64, 3), (try get(doc, "rating_average")).integer);
    try std.testing.expectEqual(@as(i64, 1), (try get(doc, "rating_count")).integer);
    try std.testing.expect(!(try get(doc, "has_image")).bool);
    try std.testing.expectEqualStrings("https://old.example", try text((try array(try get(doc, "inspiration_urls")))[0]));
    try std.testing.expectError(error.OptionalSourceUnavailableWithoutPreviousDocument, recipeDocument(a, recipe, failed, null, "r1"));
    const fresh = try recipeDocument(a, try parse(a, recipeFixture), failed, null, "r1");
    try std.testing.expect(!(try get(fresh, "has_image")).bool);
    try std.testing.expectEqual(@as(usize, 0), (try array(try get(fresh, "inspiration_urls"))).len);
}

test "multiple optional errors preserve all affected sources without hiding core errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try parse(a,
        \\{"data":{"recipe":{"id":"r1","name":"Updated","nameSortKey":"updated",
        \\"createdAt":"2026-10-08T13:00:00.123456Z","updatedAt":"2026-10-09T14:00:00.654321Z","method":null,"ingredients":[]}},
        \\"errors":[{"message":"offline","path":["recipe","image"]},
        \\{"message":"offline","path":["recipe","rating"]},
        \\{"message":"offline","path":["recipe","inspirations"]}]}
    );
    const response = try graphqlResponse(root, true);
    const doc = try recipeDocument(a, try get(response.data, "recipe"), response.failed, try parse(a, previousFixture), "r1");
    try std.testing.expectEqualStrings("Updated", try text(try get(doc, "name")));
    try std.testing.expect((try get(doc, "has_image")).bool);
    try std.testing.expectEqual(@as(i64, 3), (try get(doc, "rating_average")).integer);
    try std.testing.expectEqual(@as(usize, 1), (try array(try get(doc, "inspiration_urls"))).len);
    try std.testing.expectError(error.InvalidDependencyResponse, recipeDocument(a, try get(response.data, "recipe"), response.failed, null, "wrong-id"));
    var mixed = root;
    var errors = try get(mixed, "errors");
    try errors.array.append(try parse(a,
        \\{"message":"core failed","path":["recipe","name"]}
    ));
    try mixed.object.put("errors", errors);
    try std.testing.expectError(error.GraphqlError, graphqlResponse(mixed, true));
}

test "only error-free null recipes confirm deletion and malformed errors fail closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deleted = try graphqlResponse(try parse(a,
        \\{"data":{"recipe":null},"errors":[]}
    ), true);
    try std.testing.expect(try get(deleted.data, "recipe") == .null);
    for ([_][]const u8{
        \\{"data":{"recipe":null},"errors":[{"message":"failed","path":["recipe","image"]}]}
        ,
        \\{"data":{"recipe":null},"errors":[{"message":"failed","path":["recipe"]}]}
        ,
        \\{"data":{},"errors":[{"message":"failed","path":["other","image"]}]}
        ,
        \\{"data":{},"errors":[{"message":"failed","path":["recipe","unknown"]}]}
        ,
    }) |bytes| {
        try std.testing.expectError(error.GraphqlError, graphqlResponse(try parse(a, bytes), true));
    }
    for ([_][]const u8{
        \\{"data":{},"errors":null}
        ,
        \\{"data":{},"errors":[{"message":"failed"}]}
        ,
        \\{"data":{},"errors":[{"message":"failed","path":["recipe","image",false]}]}
        ,
        \\{"data":{},"errors":[{"message":"failed","path":["recipe","inspirations",-1]}]}
        ,
        \\{"data":{},"errors":[{"path":["recipe","image"]}]}
        ,
    }) |bytes| {
        try std.testing.expectError(error.InvalidDependencyResponse, graphqlResponse(try parse(a, bytes), true));
    }
}

test "reload uses one GraphQL request and writes a mixed-success document" {
    const Fixture = struct {
        server: *std.net.Server,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.failure = err;
            };
        }
        fn serve(self: *@This()) !void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            for (0..3) |step| {
                var fds = [_]std.posix.pollfd{.{ .fd = self.server.stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                if (try std.posix.poll(&fds, 5000) == 0) return error.FixtureTimeout;
                const connection = try self.server.accept();
                defer connection.stream.close();
                var buffer: [8192]u8 = undefined;
                var server = std.http.Server.init(connection, &buffer);
                var request = try server.receiveHead();
                const body = try (try request.reader()).readAllAlloc(a, 8192);
                switch (step) {
                    0 => {
                        try std.testing.expectEqualStrings("/graphql", request.head.target);
                        try std.testing.expectEqual(.POST, request.head.method);
                        const payload = try parse(a, body);
                        try std.testing.expectEqualStrings(operations.IndexRecipe, try text(try get(payload, "query")));
                        try std.testing.expectEqualStrings("r1", try text(try get(try get(payload, "variables"), "id")));
                        try request.respond(
                            \\{"data":{"recipe":{"id":"r1","name":"Updated","nameSortKey":"updated",
                            \\"createdAt":"2026-10-08T13:00:00.123456Z","updatedAt":"2026-10-09T14:00:00.654321Z","method":null,"ingredients":[],
                            \\"rating":{"average":5,"count":2},"inspirations":[]}},
                            \\"errors":[{"message":"images unavailable","path":["recipe","image"]}]}
                        , .{ .keep_alive = false });
                    },
                    1 => {
                        try std.testing.expectEqualStrings(collection ++ "/documents/r1", request.head.target);
                        try std.testing.expectEqual(.GET, request.head.method);
                        try request.respond(previousFixture, .{ .keep_alive = false });
                    },
                    2 => {
                        try std.testing.expectEqualStrings(collection ++ "/documents?action=upsert", request.head.target);
                        try std.testing.expectEqual(.POST, request.head.method);
                        const doc = try parse(a, body);
                        try std.testing.expectEqualStrings("Updated", try text(try get(doc, "name")));
                        try std.testing.expectEqualStrings("updated", try text(try get(doc, "name_sort")));
                        try std.testing.expectEqualStrings("r1", try text(try get(doc, "recipe_id_sort")));
                        try std.testing.expectEqual(@as(i64, 1791464400123456), (try get(doc, "created_at")).integer);
                        try std.testing.expectEqual(try @import("timestamp.zig").microseconds("2026-10-09T14:00:00.654321Z"), (try get(doc, "updated_at")).integer);
                        try std.testing.expect((try get(doc, "has_image")).bool);
                        try std.testing.expectEqual(@as(i64, 5), (try get(doc, "rating_average")).integer);
                        try std.testing.expectEqual(@as(usize, 0), (try array(try get(doc, "inspiration_urls"))).len);
                        try request.respond("{}", .{ .keep_alive = false });
                    },
                    else => unreachable,
                }
            }
        }
    };
    if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != c.CURLE_OK) return error.CurlInit;
    defer c.curl_global_cleanup();
    var server = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{});
    defer server.deinit();
    var fixture = Fixture{ .server = &server };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{server.listen_address.getPort()});
    var index = Index{ .cfg = .{
        .graphql = try std.mem.concat(a, u8, &.{ base, "/graphql" }),
        .typesense = base,
        .key = "",
        .nats = "",
        .port = 0,
        .state_dir = "",
        .checkpoint = 0,
    } };
    const thread = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    const result = index.reload(a, "r1");
    thread.join();
    if (fixture.failure) |err| return err;
    try std.testing.expect(try result);
}

test "startup rebuild creates the recipe collection from the current schema" {
    const Fixture = struct {
        server: *std.net.Server,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.failure = err;
            };
        }
        fn serve(self: *@This()) !void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const paths = [_][]const u8{ "/collections/recipes", "/collections", "/graphql", "/collections/recipes/documents/export" };
            for (paths, 0..) |path, step| {
                var fds = [_]std.posix.pollfd{.{ .fd = self.server.stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                if (try std.posix.poll(&fds, 5000) == 0) return error.FixtureTimeout;
                const connection = try self.server.accept();
                defer connection.stream.close();
                var buffer: [8192]u8 = undefined;
                var server = std.http.Server.init(connection, &buffer);
                var request = try server.receiveHead();
                const body = try (try request.reader()).readAllAlloc(a, 8192);
                try std.testing.expectEqualStrings(path, request.head.target);
                try std.testing.expectEqual(if (step == 1 or step == 2) std.http.Method.POST else std.http.Method.GET, request.head.method);
                switch (step) {
                    0 => try request.respond("{}", .{ .status = .not_found, .keep_alive = false }),
                    1 => {
                        try std.testing.expectEqualStrings(@embedFile("schema.json"), body);
                        try std.testing.expectEqualStrings("recipes", try text(try get(try parse(a, body), "name")));
                        try request.respond("{}", .{ .status = .created, .keep_alive = false });
                    },
                    2 => try request.respond("{\"data\":{\"recipes\":[]}}", .{ .keep_alive = false }),
                    3 => try request.respond("", .{ .keep_alive = false }),
                    else => unreachable,
                }
            }
        }
    };
    if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != c.CURLE_OK) return error.CurlInit;
    defer c.curl_global_cleanup();
    var server = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{});
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{server.listen_address.getPort()});
    var index = Index{ .cfg = .{
        .graphql = try std.mem.concat(a, u8, &.{ base, "/graphql" }),
        .typesense = base,
        .key = "",
        .nats = "",
        .port = 0,
        .state_dir = "",
        .checkpoint = 0,
    } };
    var fixture = Fixture{ .server = &server };
    const thread = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    const result = index.rebuild(a);
    thread.join();
    if (fixture.failure) |err| return err;
    try result;
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
