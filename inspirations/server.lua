local app = require "milua"
local json = require "dkjson"
local logger = require("milua_log")

local expected_storage_version = require "storage_version_generated"
local mode = os.getenv("MODE") or "production"
if mode ~= "production" and mode ~= "testing" and mode ~= "backup" then
    io.stderr:write("Invalid MODE; expected production, testing or backup\n")
    os.exit(1)
end

local data = {}

local function database_location()
    local location = os.getenv("DATA_LOCATION")
    if location == nil then
        location = "data/db.json"
    else
        local ending = ".json"
        if location:sub(-#ending) ~= ending then
            location = location .. "/db.json"
        end
    end
    return location
end

local db_location = database_location()
print("Database location: " .. db_location)
local data_root = db_location:match("^(.*)/[^/]*$") or "."
if data_root == "" then data_root = "/" end
local marker_path = data_root .. "/storage-version"

local function shell_quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end

local function storage_failure(reason)
    io.stderr:write("inspirations storage version failure at ", marker_path,
                    ": expected ", tostring(expected_storage_version), ", ",
                    reason, "\n")
    os.exit(1)
end

local function directory_entries(path)
    local directory_status = os.execute("test -d " .. shell_quote(path))
    if directory_status ~= true and directory_status ~= 0 then
        local path_status = os.execute("test -e " .. shell_quote(path))
        if path_status == true or path_status == 0 then
            storage_failure("data root is not a directory")
        end
        return {}
    end
    local pipe = io.popen("find -P " .. shell_quote(path) ..
                              " -mindepth 1 -maxdepth 1 -printf '%y %f\\0' 2>&1")
    if not pipe then storage_failure("cannot inspect data root") end
    local output = pipe:read("*a")
    local ok = pipe:close()
    if not ok then
        if output:match("No such file or directory") then return {} end
        storage_failure("cannot inspect data root: " .. output:gsub("%s+$", ""))
    end
    local entries = {}
    for entry in output:gmatch("([^%z]+)%z") do
        local kind, name = entry:match("^(.).(.*)$")
        entries[name] = kind
    end
    return entries
end

local marker_entries = directory_entries(data_root)
local marker_kind = marker_entries["storage-version"]
local marker_version
if marker_kind then
    if marker_kind ~= "f" then storage_failure("unsafe marker file type") end
    local marker_file, marker_error = io.open(marker_path, "r")
    if not marker_file then
        storage_failure("cannot read marker: " .. tostring(marker_error))
    end
    local contents = marker_file:read("*a")
    marker_file:close()
    local value = contents:match("^([1-9][0-9]*)\n$")
    if not value then storage_failure("invalid marker contents") end
    marker_version = tonumber(value)
    if marker_version ~= expected_storage_version then
        storage_failure("actual " .. tostring(marker_version))
    end
end

for name, kind in pairs(marker_entries) do
    if name ~= "storage-version" and
        (name ~= (db_location:match("([^/]*)$") or db_location) or kind ~= "f") then
        storage_failure("unrecognized data-root entry " .. name)
    end
end

local has_database =
    marker_entries[db_location:match("([^/]*)$") or db_location] == "f"
local fresh_storage = marker_version == nil and not has_database or
                          marker_version == expected_storage_version and
                          not has_database
if marker_version == nil and has_database then
    storage_failure("marker missing; existing data found")
end
if marker_version == nil and not fresh_storage then
    storage_failure("marker missing; existing data found")
end
if fresh_storage and mode == "backup" then
    storage_failure(
        "marker missing or application data absent; backup mode cannot initialize")
end
if fresh_storage then
    local directory_status =
        os.execute("mkdir -p -- " .. shell_quote(data_root))
    if directory_status ~= true and directory_status ~= 0 then
        storage_failure("cannot create data root")
    end
end

-- function that loads data from a file
local function load_data()
    local file, open_error, error_code = io.open(db_location, "r")
    if not file then
        if error_code == 2 then return false end
        io.stderr:write("Cannot read inspirations storage: ",
                        tostring(open_error), "\n")
        os.exit(1)
    end
    if file then
        local contents = file:read("*a")
        file:close()
        local loaded, _, decode_error = json.decode(contents)
        if type(loaded) ~= "table" then
            io.stderr:write("Cannot read inspirations storage: ",
                            tostring(decode_error or "expected a JSON object"),
                            "\n")
            os.exit(1)
        end
        for recipe_id, urls in pairs(loaded) do
            if type(recipe_id) ~= "string" or type(urls) ~= "table" then
                io.stderr:write(
                    "Cannot read inspirations storage: invalid recipe record\n")
                os.exit(1)
            end
            for _, url in pairs(urls) do
                if type(url) ~= "string" then
                    io.stderr:write(
                        "Cannot read inspirations storage: invalid URL record\n")
                    os.exit(1)
                end
            end
        end
        data = loaded
    end
    return true
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
local function problem_details(status, title, detail, code, field)
    local problem = {
        type = "about:blank",
        title = title,
        status = status,
        detail = detail,
        code = code
    }
    if field then problem.field = field end
    local body = json.encode(problem)
    return body, {
        ["Content-Type"] = "application/problem+json",
        [":status"] = tostring(status)
    }
end

local function maintenance_status()
    if mode ~= "backup" then
        return problem_details(404, "Not Found", "Route not found", "not-found")
    end
    return
        json.encode({version = 1, service = "inspirations", mode = "backup"}),
        {["Content-Type"] = "application/json"}
end

local function maintenance_recipe_ids()
    if mode ~= "backup" then
        return problem_details(404, "Not Found", "Route not found", "not-found")
    end
    local ids = {}
    for recipe_id in pairs(data) do table.insert(ids, recipe_id) end
    table.sort(ids)
    return json.encode({recipeIds = ids}),
           {["Content-Type"] = "application/json"}
end

local function purge_recipe(_captures, _query, headers, body)
    if mode ~= "backup" then
        return problem_details(404, "Not Found", "Route not found", "not-found")
    end
    local content_type = headers and
                             (headers["content-type"] or headers["Content-Type"])
    if type(content_type) ~= "string" or
        content_type:lower():match("^%s*([^;]+)") ~= "application/json" then
        return problem_details(415, "Unsupported Media Type",
                               "Expected application/json",
                               "unsupported-content-type")
    end
    local document = json.decode(body or "")
    if type(document) ~= "table" then
        return problem_details(400, "Bad Request", "Invalid JSON",
                               "invalid-input")
    end
    for field in pairs(document) do
        if field ~= "recipeId" then
            return problem_details(400, "Bad Request", "Unknown field",
                                   "invalid-input", field)
        end
    end
    if type(document.recipeId) ~= "string" or document.recipeId == "" then
        return problem_details(400, "Bad Request",
                               "Expected a non-empty recipeId", "invalid-input",
                               "recipeId")
    end

    local updated_data = {}
    for key, values in pairs(data) do
        if key ~= document.recipeId then updated_data[key] = values end
    end
    local saved, save_error = save_data(updated_data)
    if not saved then
        io.stderr:write("Cannot purge inspirations: ", tostring(save_error),
                        "\n")
        return problem_details(500, "Internal Server Error",
                               "Cannot delete inspirations", "storage-error")
    end
    data = updated_data
    return nil, {[":status"] = "204"}
end

app.add_handler("GET", "/maintenance/status", maintenance_status)
app.add_handler("GET", "/maintenance/status/", maintenance_status)
app.add_handler("GET", "/maintenance/recipe%-ids", maintenance_recipe_ids)
app.add_handler("GET", "/maintenance/recipe%-ids/", maintenance_recipe_ids)
app.add_handler("POST", "/maintenance/recipes/purge", purge_recipe)
app.add_handler("POST", "/maintenance/recipes/purge/", purge_recipe)

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
    if mode == "backup" then
        return problem_details(503, "Service Unavailable",
                               "Application writes are unavailable during backup maintenance",
                               "maintenance-mode")
    end
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
    if mode == "backup" then
        return problem_details(503, "Service Unavailable",
                               "Application writes are unavailable during backup maintenance",
                               "maintenance-mode")
    end
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

if not load_data() then
    local saved, save_error = save_data(data)
    if not saved then
        io.stderr:write("Cannot initialize inspirations storage: ",
                        tostring(save_error), "\n")
        os.exit(1)
    end
    if fresh_storage and marker_version == nil then
        local temporary = marker_path .. ".pending-" .. tostring(os.time()) ..
                              "-" .. tostring(math.random(1, 1000000000))
        if io.open(temporary, "r") then
            storage_failure("temporary marker already exists")
        end
        local marker_file, marker_error = io.open(temporary, "w")
        if not marker_file then
            storage_failure("cannot create temporary marker: " ..
                                tostring(marker_error))
        end
        local written, write_error = marker_file:write(tostring(
                                                           expected_storage_version),
                                                       "\n")
        local closed, close_error = marker_file:close()
        if not written or not closed then
            os.remove(temporary)
            storage_failure("cannot write marker: " ..
                                tostring(write_error or close_error))
        end
        local ok = os.execute("ln -T -- " .. shell_quote(temporary) .. " " ..
                                  shell_quote(marker_path))
        os.remove(temporary)
        if ok ~= true and ok ~= 0 then
            storage_failure("cannot atomically publish marker")
        end
    end
elseif fresh_storage then
    storage_failure("fresh storage unexpectedly contains application data")
end

if os.getenv("VERBOSE") ~= "true" then
    local function noop() end
    logger:add_logger("INFO", noop)
    logger:add_logger("DEBUG", noop)
end

local config = {HOST = "0.0.0.0", PORT = 8800}
print("Starting server on " .. config.HOST .. ":" .. config.PORT .. "...")
app.start(config)
