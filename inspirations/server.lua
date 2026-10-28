local app = require "milua"
local json = require "dkjson"
local logger = require("milua_log")

local mode = os.getenv("MODE") or "production"
if mode ~= "production" and mode ~= "testing" then
    io.stderr:write("Invalid MODE; expected production or testing\n")
    os.exit(1)
end

local data = {}

local function database_location()
    local location = os.getenv("DATA_LOCATION")
    if location == nil then
        location = "db.json"
    else
        local ending = ".json"
        if location:sub(-#ending) ~= ending then
            location = location .. "/db.json"
        end
        local directory = location:match("(.*/)")
        if directory ~= nil then os.execute("mkdir -p " .. directory) end
    end
    return location
end

local db_location = database_location()
print("Database location: " .. db_location)

-- function that loads data from a file
local function load_data()
    local file = io.open(db_location, "r")
    if file then
        data = json.decode(file:read("*a")) or {}
        file:close()
    end
end

-- function that saves data to a file
local function save_data(updated_data)
    local temporary_location = db_location .. ".tmp"
    local file, open_error = io.open(temporary_location, "w")
    if not file then return false, open_error end
    local written, write_error = file:write(json.encode(updated_data))
    local closed, close_error = file:close()
    if not written or not closed then
        os.remove(temporary_location)
        return false, write_error or close_error
    end
    local renamed, rename_error = os.rename(temporary_location, db_location)
    if not renamed then
        os.remove(temporary_location)
        return false, rename_error
    end
    return true
end

local function check_input(array)
    if array == nil or type(array) ~= "table" or #array == 0 then
        return false
    end

    for _, v in pairs(array) do if type(v) ~= "string" then return false end end

    return true
end

-- RFC 9457 Problem Details body, mirroring the recipes service's error shape.
local function problem_details(status, title, detail, code)
    local body = json.encode({
        type = "about:blank",
        title = title,
        status = status,
        detail = detail,
        code = code
    })
    return body, {
        ["Content-Type"] = "application/problem+json",
        [":status"] = tostring(status)
    }
end

local function delete_all()
    if mode ~= "testing" then
        return problem_details(404, "Not Found", "Route not found", "not-found")
    end
    local saved, save_error = save_data({})
    if not saved then
        io.stderr:write("Cannot clear inspirations file: ",
                        tostring(save_error), "\n")
        return problem_details(500, "Internal Server Error",
                               "Cannot delete inspirations", "storage-error")
    end
    data = {}
    return nil, {[":status"] = "204"}
end

app.add_handler("DELETE", "/inspirations", delete_all)
app.add_handler("DELETE", "/inspirations/", delete_all)

app.add_handler("GET", "/health",
                function() return nil, {[":status"] = "204"} end)

app.add_handler("GET", "/inspirations/...", function(captures)
    local recipe_id = captures[1]
    local inspirations = data[recipe_id]

    if inspirations == nil then
        return problem_details(404, "Not Found", "Inspiration not found",
                               "inspiration-not-found")
    end

    return json.encode(inspirations), {["content-type"] = "application/json"}
end)

app.add_handler("PUT", "/inspirations/...", function(captures, _q, _h, body)
    local recipe_id = captures[1]

    local decoded = json.decode(body)

    if not check_input(decoded) then
        return problem_details(400, "Bad Request",
                               "Input must be a JSON array of strings.",
                               "invalid-input")
    end

    local updated_data = {}
    for key, values in pairs(data) do updated_data[key] = values end
    updated_data[recipe_id] = {}
    for _, v in pairs(decoded) do table.insert(updated_data[recipe_id], v) end
    local saved, save_error = save_data(updated_data)
    if not saved then
        io.stderr:write("Cannot save inspirations file: ", tostring(save_error),
                        "\n")
        return problem_details(500, "Internal Server Error",
                               "Cannot save inspirations", "storage-error")
    end
    data = updated_data

    return nil, {[":status"] = "201"}
end)

app.add_handler("DELETE", "/inspirations/...", function(captures)
    local recipe_id = captures[1]
    local inspirations = data[recipe_id]

    if inspirations == nil then
        return problem_details(404, "Not Found", "Inspiration not found",
                               "inspiration-not-found")
    end

    local updated_data = {}
    for key, values in pairs(data) do
        if key ~= recipe_id then updated_data[key] = values end
    end
    local saved, save_error = save_data(updated_data)
    if not saved then
        io.stderr:write("Cannot delete inspiration: ", tostring(save_error),
                        "\n")
        return problem_details(500, "Internal Server Error",
                               "Cannot delete inspiration", "storage-error")
    end
    data = updated_data

    return nil, {[":status"] = "204"}
end)

load_data()

if os.getenv("VERBOSE") ~= "true" then
    local function noop() end
    logger:add_logger("INFO", noop)
    logger:add_logger("DEBUG", noop)
end

local config = {HOST = "0.0.0.0", PORT = 8800}
print("Starting server on " .. config.HOST .. ":" .. config.PORT .. "...")
app.start(config)
