using Genie
import Genie.Renderer.Json: json
using Genie.Requests
using FileIO
import Dates: unix2datetime
using Images
using HTTP

testingMode = haskey(ENV, "TESTING")

imagesSubfolder = "public"

if (haskey(ENV, "DATA_LOCATION"))
    Genie.config.server_document_root = ENV["DATA_LOCATION"]
else
    Genie.config.server_document_root = "public"
end
dataFolder = mkpath(Genie.config.server_document_root * "/" * imagesSubfolder)
@info "Data location '$dataFolder'"

function imageFileName(recipeId, thumb = false)
    if (thumb)
        "$recipeId-thumb.jpg"
    else
        "$recipeId.jpg"
    end

end

function imageFile(recipeId, thumb = false)
    "$dataFolder/$(imageFileName(recipeId, thumb))"
end

THUMB_WIDTH = 600
THUMB_HEIGHT = 450

route("/images/:recipeId", method = POST) do
    contentType = if (typeof(headers()) == Dict{String,String})
        get(headers(), "Content-Type", nothing)
    else
        @show typeof(headers)
        @show headers
        @show methods(headers)
        nothing
    end

    fmt = if (contentType == "image/jpeg" || contentType == "image/jpg")
        format"JPEG"
    elseif (contentType == "image/png")
        format"PNG"
    else
        nothing
    end

    if (fmt !== nothing)
        try
            img = load(Stream{fmt}(IOBuffer(rawpayload())))
            save(imageFile(payload(:recipeId)), img)

            # create thumbnail

            # crop image 4:3
            origSize = size(img)
            origRatio = origSize[2] / origSize[1]
            @info "Uploaded Image" origSize origRatio

            img_cropped = if (origRatio > (THUMB_WIDTH / THUMB_HEIGHT))
                cropWidth = round(Int, origSize[1] * (THUMB_WIDTH / THUMB_HEIGHT))
                border = round(Int, (origSize[2] - cropWidth) / 2)
                @info "Crop width $(origSize[2]) -> $cropWidth"
                @view img[1:origSize[1], border:(origSize[2]-border)]
            else
                cropHeight = round(Int, origSize[2] * (THUMB_HEIGHT / THUMB_WIDTH))
                border = round(Int, (origSize[1] - cropHeight) / 2)
                if (border <= 0)
                    @info "No crop"
                    img
                else
                    @info "Crop height: $(origSize[1]) -> $cropHeight"
                    @view img[border:(origSize[1]-border), 1:origSize[2]]
                end
            end

            # resize to thumbnail size
            img_thumb = imresize(img_cropped, (THUMB_HEIGHT, THUMB_WIDTH))

            # save thumbnail
            save(imageFile(payload(:recipeId), true), img_thumb)

            HTTP.Response(201, "")
        catch e
            @error "Error: $(e)"
            HTTP.Response(400, "Error: $(e)")
        end
    else
        HTTP.Response(400, "Unsupported content type '$contentType'")
    end
end

route("/images/:recipeId/meta", method = GET) do
    recipeId = payload(:recipeId)
    path = imageFile(recipeId)
    if (isfile(path))
        stat = Base.stat(open(path, "r"))
        img = load(path)
        dimensions = size(img)
        json(
            Dict(
                "recipeId" => recipeId,
                "height" => dimensions[1],
                "width" => dimensions[2],
                "size" => stat.size,
                "modified" => unix2datetime(ceil(stat.mtime)),
                "url" => "/$imagesSubfolder/$(imageFileName(recipeId))",
                "thumbUrl" => "/$imagesSubfolder/$(imageFileName(recipeId, true))",
            ),
        )
    else
        HTTP.Response(404, "Not found")
    end
end

route("/images/:recipeId", method = DELETE) do
    recipeId = payload(:recipeId)
    path = imageFile(recipeId)
    if (isfile(path))
        rm(path)
        thumbPath = imageFile(recipeId, true)
        if (isfile(thumbPath))
            rm(thumbPath)
        end
        HTTP.Response(204, "")
    else
        HTTP.Response(404, "Not found")
    end
end

if (testingMode)
    route("/images", method = DELETE) do
        rm(dataFolder, recursive = true)
        mkpath(dataFolder)
        HTTP.Response(204, "")
    end
end

route("/health", method = GET) do
    HTTP.Response(204, "")
end

port = if haskey(ENV, "PORT")
    parse(Int, ENV["PORT"])
else
    8000
end

if (testingMode)
    @info "Running in TESTING mode"
end
up(host = "127.0.0.1", port = port, async = true)

using JSON

function testImage(extension, width = 800, height = 600)
    test_image = [RGB(rand(N0f8, 3)...) for x ∈ 1:height, y ∈ 1:width]
    save("/tmp/test.$extension", test_image)
    open("/tmp/test.$extension", "r")
end

try
    headers = Dict("Content-Type" => "image/jpeg")
    res = HTTP.post(
        "http://localhost:$port/images/test-direct1",
        headers,
        testImage("jpg", 800, 450),
    )
    @assert res.status == 201 "status should be 201 but was $(res.status)"

    res = HTTP.get("http://localhost:$port/images/test-direct1/meta")
    @assert res.status == 200 "status should be 200 but was $(res.status)"
    meta = JSON.parse(String(res.body))
    @info JSON.json(meta, 2)
    @assert meta["recipeId"] == "test-direct1" "recipeId should be test-direct1 but was $(meta["recipeId"])"
    @assert meta["width"] == 800 "width should be 800 but was $(meta["width"])"
    @assert meta["height"] == 450 "height should be 450 but was $(meta["height"])"

    HTTP.get("http://localhost:$port" * meta["url"])
    HTTP.get("http://localhost:$port" * meta["thumbUrl"])

    res = HTTP.delete("http://localhost:$port/images/test-direct1")
    @assert res.status == 204 "status should be 204 but was $(res.status)"
catch e
    println("Error: $(e)")
    exit(1)
end

try
    headers = ["Content-Type" => "image/png"]
    res = HTTP.post(
        "http://localhost:$port/images/test-direct2",
        headers,
        testImage("png", 800, 600),
    )
    @assert res.status == 201 "status should be 201 but was $(res.status)"

    res = HTTP.get("http://localhost:$port/images/test-direct2/meta")
    @assert res.status == 200 "status should be 200 but was $(res.status)"
    meta = JSON.parse(String(res.body))
    @info JSON.json(meta, 2)
    @assert meta["width"] == 800 "width should be 800 but was $(meta["width"])"
    @assert meta["height"] == 600 "height should be 600 but was $(meta["height"])"

    HTTP.get("http://localhost:$port" * meta["url"])
    HTTP.get("http://localhost:$port" * meta["thumbUrl"])

    res = HTTP.delete("http://localhost:$port/images/test-direct2")
    @assert res.status == 204 "status should be 204 but was $(res.status)"
catch e
    println("Error: $(e)")
    exit(1)
end

try
    headers = Dict("Content-Type" => "image/tiff")
    res =
        HTTP.post("http://localhost:$port/images/test-direct3", headers, testImage("tiff"))
    @assert res.status == 400 "status should be 400 but was $(res.status)"
catch e
    if (!isa(e, HTTP.Exceptions.StatusError))
        println("Error: $(e)")
        exit(1)
    end
end

try
    headers = Dict("Content-Type" => "image/png")
    res = HTTP.post(
        "http://localhost:$port/images/test-direct4",
        headers,
        IOBuffer("not an image"),
    )
    @assert res.status == 400 "status should be 400 but was $(res.status)"
catch e
    if (!isa(e, HTTP.Exceptions.StatusError))
        println("Error: $(e)")
        exit(1)
    end
end

down()
@info "All tests passed"

if (!haskey(ENV, "PRECOMPILE"))
    up(host = "0.0.0.0", port = port, async = false)
end
