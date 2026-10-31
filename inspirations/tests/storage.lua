local json = require "dkjson"
local root = assert(arg[1], "Pass an isolated fixture directory")
local location = root .. "/db.json"
assert(not io.open(location, "r"), "Fixture database must not exist")

local function read_data()
    local file = io.open(location, "r")
    if not file then return nil end
    local contents = file:read("*a")
    file:close()
    return contents
end

local function write_data(contents)
    local file = assert(io.open(location, "w"))
    assert(file:write(contents))
    assert(file:close())
end

local function start(mode, options)
    options = options or {}
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
        io = setmetatable({}, {__index = io})
    }, {__index = _G})
    environment.os.getenv = function(name)
        if name == "MODE" then return mode end
        if name == "DATA_LOCATION" then
            return options.location or location
        end
        return nil
    end
    environment.os.exit = function(code) error({exit_code = code}) end
    environment.io.stderr = {
        write = function(_, ...)
            table.insert(messages, table.concat({...}))
        end
    }
    environment.io.open = function(path, access)
        if options.read_error and path == location and access == "r" then
            return nil, "Permission denied", 13
        end
        if options.write_error and path == location .. ".tmp" then
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
    assert(headers[":status"] == tostring(expected), route)
end

for _, mode in ipairs({"unset", "production", "testing"}) do
    local selected = mode
    if mode == "unset" then selected = nil end
    assert(start(selected))
    assert(read_data() == "[]")
    assert(os.remove(location))
end

local ok, _, message = start("backup")
assert(not ok and message:find("database missing", 1, true))
assert(read_data() == nil)
assert(not io.open(location .. ".tmp", "r"))
ok = start("backup", {location = root .. "/missing-subdir"})
assert(not ok and not io.open(root .. "/missing-subdir", "r"))

for _, mode in ipairs({"production", "testing", "backup"}) do
    ok, _, message = start(mode, {read_error = true})
    assert(not ok and message:find("Permission denied", 1, true))
    assert(read_data() == nil)
end
for _, mode in ipairs({"production", "testing"}) do
    ok, _, message = start(mode, {write_error = true})
    assert(not ok and message:find("Cannot initialize", 1, true))
    assert(read_data() == nil)
end
for _, mode in ipairs({"", "invalid"}) do
    assert(not start(mode))
    assert(read_data() == nil)
end

local populated = '{"recipe":["https://example.com"]}'
for _, document in ipairs({"{}", "[]", populated}) do
    for _, mode in ipairs({"production", "testing", "backup"}) do
        write_data(document)
        local loaded, handlers = start(mode)
        assert(loaded and read_data() == document)
        status(handlers, "GET /health", 204)
        if mode == "backup" then
            status(handlers, "PUT /inspirations/...", 503, {"recipe"}, nil, nil,
                   '["https://changed.example.com"]')
            status(handlers, "DELETE /inspirations/...", 503, {"recipe"})
        else
            status(handlers, "POST /maintenance/recipes/purge", 404)
        end
        if mode ~= "testing" then
            status(handlers, "DELETE /inspirations", 404)
            status(handlers, "DELETE /inspirations/", 404)
        end
        assert(read_data() == document)
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
    assert(read_data() == "[]" and next((json.decode(read_data()))) == nil)
    assert(start("backup"))
end
write_data(populated)
local loaded, handlers = start("production")
assert(loaded)
status(handlers, "DELETE /inspirations/...", 204, {"recipe"})
assert(read_data() == "[]")
for _, route in ipairs({"DELETE /inspirations", "DELETE /inspirations/"}) do
    write_data(populated)
    loaded, handlers = start("testing")
    assert(loaded)
    status(handlers, route, 204)
    assert(read_data() == "[]")
end

write_data("not JSON")
assert(not start("production"))
assert(read_data() == "not JSON")
assert(os.remove(location))
print("Inspirations storage initialization and mode boundaries passed")
