local json = require "dkjson"
local root = assert(arg[1], "Pass an isolated fixture directory")
local location = root .. "/db.json"

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function exists(path)
    local file = io.open(path, "r")
    if not file then return false end
    file:close()
    return true
end

local function read_data(path)
    local file = io.open(path or location, "r")
    if not file then return nil end
    local contents = file:read("*a")
    file:close()
    return contents
end

local function write_data(contents, path)
    local file = assert(io.open(path or location, "w"))
    assert(file:write(contents))
    assert(file:close())
end

assert(not exists(root), "Inspirations fixture already exists")
assert(os.execute("mkdir -p -- " .. shell_quote(root)))

local function start(mode, options)
    options = options or {}
    local selected_location = options.location or location
    if selected_location:sub(-5) ~= ".json" then
        selected_location = selected_location .. "/db.json"
    end
    local handlers, started, messages = {}, false, {}
    package.loaded.milua = {
        add_handler = function(method, path, handler)
            handlers[method .. " " .. path] = handler
        end,
        start = function() started = true end
    }
    package.loaded.milua_log = {add_logger = function() end}
    local environment = setmetatable({
        os = setmetatable({}, {__index = os}),
        io = setmetatable({}, {__index = io}),
        print = function() end
    }, {__index = _G})
    environment.os.getenv = function(name)
        if name == "MODE" then return mode end
        if name == "DATA_LOCATION" then return options.location or location end
        return nil
    end
    environment.os.exit = function(code) error({exit_code = code}) end
    environment.io.stderr = {
        write = function(_, ...)
            table.insert(messages, table.concat({...}))
        end
    }
    environment.io.open = function(path, access)
        if options.read_error and path == selected_location and access == "r" then
            return nil, "Permission denied", 13
        end
        if options.write_error and path == selected_location .. ".tmp" then
            return nil, "Permission denied", 13
        end
        return io.open(path, access)
    end
    local ok, failure = pcall(assert(loadfile("server.lua", "t", environment)))
    if not ok then
        assert(type(failure) == "table" and failure.exit_code == 1,
               tostring(failure))
    end
    assert(started == ok)
    return ok, handlers, table.concat(messages)
end

local function status(handlers, route, expected, ...)
    local _, headers = assert(handlers[route], route)(...)
    assert((headers[":status"] or "200") == tostring(expected), route)
end

assert(start())
assert(read_data() == "[]")
assert(os.remove(location))
for _, mode in ipairs({"production", "testing"}) do
    assert(start(mode))
    assert(read_data() == "[]")
    assert(os.remove(location))
end

local ok, _, message = start("backup")
assert(not ok and message:find("application data missing", 1, true))
assert(read_data() == nil and not exists(location .. ".tmp"))
local missing_root = root .. "/missing-backup-root"
ok = start("backup", {location = missing_root .. "/db.json"})
assert(not ok and not exists(missing_root))

local fresh_root = root .. "/fresh-root"
assert(start("testing", {location = fresh_root}))
assert(read_data(fresh_root .. "/db.json") == "[]")

for _, mode in ipairs({"production", "testing"}) do
    ok, _, message = start(mode, {write_error = true})
    assert(not ok and message:find("Cannot initialize", 1, true))
    assert(read_data() == nil and not exists(location .. ".tmp"))
end

local populated = '{"recipe":["https://example.com"],"second":["https://second.example.com"]}'
write_data(populated)
local loaded, default_handlers = start()
assert(loaded)
for _, route in ipairs({"DELETE /inspirations", "DELETE /inspirations/"}) do
    status(default_handlers, route, 404)
end
for _, route in ipairs({"HEAD /inspirations", "HEAD /inspirations/"}) do
    assert(default_handlers[route] == nil, route)
end
assert(read_data() == populated)
status(default_handlers, "DELETE /inspirations/...", 204, {"recipe"})
assert(json.decode(read_data()).recipe == nil)

for _, operation in ipairs({
    {
        mode = "production",
        route = "PUT /inspirations/...",
        args = {{"recipe"}, false, false, '["https://changed.example.com"]'}
    },
    {mode = "production", route = "DELETE /inspirations/...", args = {{"recipe"}}},
    {mode = "testing", route = "DELETE /inspirations", args = {}},
    {
        mode = "backup",
        route = "POST /maintenance/recipes/purge",
        args = {false, false, {["content-type"] = "application/json"},
                '{"recipeId":"recipe"}'}
    }
}) do
    write_data(populated)
    local started, handlers = start(operation.mode, {write_error = true})
    assert(started)
    local body, headers = handlers[operation.route](table.unpack(operation.args))
    assert(headers[":status"] == "500" and json.decode(body).code == "storage-error",
           operation.route)
    assert(read_data() == populated, operation.route .. " changed storage")
    for id, url in pairs({
        recipe = "https://example.com",
        second = "https://second.example.com"
    }) do
        local current = handlers["GET /inspirations/..."]({id})
        local urls = json.decode(current)
        assert(#urls == 1 and urls[1] == url, operation.route .. " changed memory")
    end
end

for _, mode in ipairs({"production", "testing", "backup"}) do
    write_data(populated)
    ok, _, message = start(mode, {read_error = true})
    assert(not ok and message:find("Permission denied", 1, true))
    assert(read_data() == populated)
end

for _, invalid in ipairs({
    "not JSON", '{"recipe":"not a list"}', '{"recipe":[4]}'
}) do
    write_data(invalid)
    for _, mode in ipairs({"production", "testing", "backup"}) do
        ok = start(mode)
        assert(not ok, "Invalid inspirations storage was accepted in " .. mode)
        assert(read_data() == invalid, "Rejected startup changed inspirations data")
    end
end

for _, mode in ipairs({"", "invalid"}) do
    local original = read_data()
    ok = start(mode)
    assert(not ok, "Invalid runtime mode was accepted")
    assert(read_data() == original, "Invalid mode startup changed inspirations data")
end

for _, mode in ipairs({"production", "testing", "backup"}) do
    write_data(populated)
    local loaded, handlers = start(mode)
    assert(loaded)
    status(handlers, "GET /health", 204)

    local expected = mode == "backup" and "200" or "404"
    for _, suffix in ipairs({"", "/"}) do
        local status_body, status_headers = handlers["GET /maintenance/status" .. suffix]()
        local ids_body, ids_headers = handlers["GET /maintenance/recipe%-ids" .. suffix]()
        assert((status_headers[":status"] or "200") == expected)
        assert((ids_headers[":status"] or "200") == expected)
        if mode == "backup" then
            assert(json.decode(status_body).service == "inspirations")
            local ids = json.decode(ids_body).recipeIds
            assert(#ids == 2 and ids[1] == "recipe" and ids[2] == "second")
        end
    end

    for _, route in ipairs({
        "POST /maintenance/recipes/purge",
        "POST /maintenance/recipes/purge/"
    }) do
        status(handlers, route, mode == "backup" and 415 or 404)
    end

    for _, route in ipairs({"DELETE /inspirations", "DELETE /inspirations/"}) do
        if mode == "testing" then
            write_data(populated)
            loaded, handlers = start(mode)
            assert(loaded)
        end
        status(handlers, route, mode == "testing" and 204 or 404)
        if mode == "testing" then
            assert(read_data() == "[]")
        else
            assert(read_data() == populated)
        end
    end

    for _, route in ipairs({"HEAD /inspirations", "HEAD /inspirations/"}) do
        if mode == "testing" then
            local body, headers = assert(handlers[route])()
            assert(body == nil and headers[":status"] == "204", route)
        else
            assert(handlers[route] == nil, route)
        end
    end

    if mode == "backup" then
        status(handlers, "PUT /inspirations/...", 503, {"recipe"}, nil, nil,
               '["https://changed.example.com"]')
        status(handlers, "DELETE /inspirations/...", 503, {"recipe"})
        assert(read_data() == populated)
    elseif mode == "production" then
        status(handlers, "DELETE /inspirations/...", 204, {"recipe"})
        assert(json.decode(read_data()).recipe == nil)
    end
end

for _, route in ipairs({
    "POST /maintenance/recipes/purge", "POST /maintenance/recipes/purge/"
}) do
    write_data(populated)
    local loaded, handlers = start("backup")
    assert(loaded)
    status(handlers, route, 204, nil, nil,
           {["content-type"] = "application/json"}, '{"recipeId":"recipe"}')
    local remaining = json.decode(read_data())
    assert(remaining.recipe == nil and remaining.second ~= nil)
    assert(start("backup"))
end

assert(os.execute("rm -rf -- " .. shell_quote(root)))
print("Inspirations storage initialization and mode boundaries passed")
