local app = require "milua"
local json = require "dkjson"

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
local function save_data()
    local file = io.open(db_location, "w")
    if file then
        file:write(json.encode(data))
        file:close()
    end
end

local function check_input(array)
    if array == nil or type(array) ~= "table" or #array == 0 then
        return false
    end

    for _, v in pairs(array) do if type(v) ~= "string" then return false end end

    return true
end

if os.getenv("TESTING") == "true" then
    app.add_handler("DELETE", "/inspirations/", function()
        data = {}
        save_data()

        return nil, {[":status"] = "204"}
    end)
end

app.add_handler("GET", "/inspirations/...", function(captures)
    local recipe_id = captures[1]
    local inspirations = data[recipe_id]

    if inspirations == nil then return nil, {[":status"] = "404"} end

    return json.encode(inspirations), {["content-type"] = "application/json"}
end)

app.add_handler("PUT", "/inspirations/...", function(captures, _q, _h, body)
    local recipe_id = captures[1]

    local decoded = json.decode(body)

    if not check_input(decoded) then
        return "Input must be an json array of strings.",
               {["Content-Type"] = "text/plain", [":status"] = "400"}
    end

    data[recipe_id] = {}
    for _, v in pairs(decoded) do table.insert(data[recipe_id], v) end
    save_data()

    return nil, {[":status"] = "201"}
end)

app.add_handler("DELETE", "/inspirations/...", function(captures)
    local recipe_id = captures[1]
    local inspirations = data[recipe_id]

    if inspirations == nil then return nil, {[":status"] = "404"} end

    data[recipe_id] = nil
    save_data()

    return nil, {[":status"] = "204"}
end)

load_data()

app.start({HOST = "0.0.0.0", PORT = 8800})
