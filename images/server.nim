import std/[httpcore, json, logging, os, strutils, uri]

import jester
import pixie
import storage

const
  ratio = 4.0 / 3.0
  thumbWidth = 300
  normalWidth = 650
  imagesSubfolder = "public"
  pngSignature = "\x89PNG\r\n\x1A\n"
  jpegSignature = "\xFF\xD8"

let
  productionMode = getEnv("PRODUCTION") == "true"
  verbose = getEnv("VERBOSE") == "true"
  documentRoot = getEnv("DATA_LOCATION", "public")
  dataFolder = documentRoot / imagesSubfolder
  store = ImageStorage(root: documentRoot)
  port = parseInt(getEnv("PORT", "8000"))
  maxUploadBytes = parseInt(getEnv("MAX_UPLOAD_BYTES", $(10 * 1024 * 1024)))
  maxPixels = parseInt(getEnv("MAX_PIXELS", $(40_000_000)))

proc cropToRatio(image: Image): Image =
  ## Centered crop so the result has the thumbnail's aspect ratio.
  let
    imageRatio = image.width / image.height
  if imageRatio > ratio:
    let w = min(image.width, int(image.height.float * ratio + 0.5))
    image.subImage((image.width - w) div 2, 0, w, image.height)
  elif imageRatio < ratio:
    let h = min(image.height, int(image.width.float / ratio + 0.5))
    image.subImage(0, (image.height - h) div 2, image.width, h)
  else:
    image

proc matchesContentType(body, contentType: string): bool =
  ## The declared type must match the actual magic bytes, otherwise pixie would
  ## happily decode other formats such as SVG.
  case contentType
  of "image/png": body.startsWith(pngSignature)
  of "image/jpeg", "image/jpg": body.startsWith(jpegSignature)
  else: false

proc problemDetails(status: HttpCode, title, detail, code: string): string =
  ## RFC 9457 Problem Details body, mirroring the recipes service's error shape.
  $(%*{
    "type": "about:blank",
    "title": title,
    "status": ord(status),
    "detail": detail,
    "code": code,
  })

template respProblem(status: HttpCode, title, detail, code: string) =
  resp status, @[("Content-Type", "application/problem+json"),
      ("Cache-Control", "no-store")], problemDetails(status, title, detail, code)

router imagesRouter:
  get "/health":
    resp Http204, ""

  get "/public/@name":
    let name = decodeUrl(@"name", decodePlus = false)
    let parsed = parseImageName(name)
    if not parsed.valid:
      respProblem(Http404, "Not Found", "Image not found", "image-not-found")
    let path = dataFolder / name
    if not fileExists(path):
      respProblem(Http404, "Not Found", "Image not found", "image-not-found")
    try:
      let bytes = readFile(path)
      if outputHash(bytes) != parsed.hash:
        raise newException(StorageError, "Invalid stored output")
      let etag = "\"" & parsed.hash & "\""
      let headers = @[
        ("Content-Type", "image/png"),
        ("Cache-Control", "public, max-age=31536000, immutable"),
        ("ETag", etag)]
      var unchanged = false
      for candidate in ($request.headers.getOrDefault("If-None-Match")).split(','):
        let value = candidate.strip()
        if value == etag or value == "W/" & etag or value == "*":
          unchanged = true
      if unchanged:
        resp Http304, headers, ""
      resp Http200, headers, bytes
    except CatchableError:
      error "GET public image '", name, "' failed: ", getCurrentExceptionMsg()
      respProblem(Http500, "Internal Server Error", "Cannot read stored image", "storage-error")

  post "/images/@recipeId":
    let recipeId = decodeUrl(@"recipeId", decodePlus = false)
    if not validRecipeId(recipeId):
      respProblem(Http400, "Bad Request", "Invalid recipe id", "invalid-recipe-id")

    let contentType = ($request.headers.getOrDefault(
        "Content-Type")).split(';')[0].strip().toLowerAscii()
    let body = request.body
    if not matchesContentType(body, contentType):
      respProblem(Http400, "Bad Request",
          "Unsupported content type '" & contentType & "'", "unsupported-content-type")

    var image: Image
    try:
      let dimensions = decodeImageDimensions(body)
      if dimensions.width * dimensions.height > maxPixels:
        respProblem(Http400, "Bad Request",
            "Image exceeds the maximum of " & $maxPixels & " pixels", "image-too-large")

      image = decodeImage(body)
    except PixieError:
      error "Upload of '", recipeId, "' failed: ", getCurrentExceptionMsg()
      respProblem(Http400, "Bad Request", getCurrentExceptionMsg(), "invalid-image")
    try:
      let cropped = image.cropToRatio()
      let normal = cropped.resize(normalWidth, 488).encodeImage(PngFormat)
      let thumbnail = cropped.resize(thumbWidth, 225).encodeImage(PngFormat)
      let metadata = store.publish(recipeId, normal, thumbnail)
      info "POST upload of '", recipeId, "' succeeded"
      resp Http201, @[("Content-Type", "application/json"),
          ("Cache-Control", "no-store")], $metadata
    except CatchableError:
      error "Publication of '", recipeId, "' failed: ", getCurrentExceptionMsg()
      respProblem(Http500, "Internal Server Error", "Cannot publish image", "storage-error")

  get "/images/@recipeId/meta":
    let recipeId = decodeUrl(@"recipeId", decodePlus = false)
    if not validRecipeId(recipeId):
      respProblem(Http404, "Not Found", "Image not found", "image-not-found")
    info "GET meta for '", recipeId, "'"
    try:
      let metadata = store.metadata(recipeId)
      resp Http200, @[("Content-Type", "application/json"),
          ("Cache-Control", "no-store")], $metadata
    except ImageNotFound:
      respProblem(Http404, "Not Found", "Image not found", "image-not-found")
    except CatchableError:
      error "Meta of '", recipeId, "' failed: ", getCurrentExceptionMsg()
      respProblem(Http500, "Internal Server Error",
          "Cannot read image metadata", "metadata-error")

  delete "/images/?":
    if productionMode:
      respProblem(Http404, "Not Found", "Not found", "not-found")
    info "DELETE all images"
    try:
      store.wipe()
    except CatchableError:
      error "Image wipe failed: ", getCurrentExceptionMsg()
      respProblem(Http500, "Internal Server Error", "Cannot delete images", "storage-error")
    resp Http204, ""

  delete "/images/@recipeId":
    let recipeId = decodeUrl(@"recipeId", decodePlus = false)
    if not validRecipeId(recipeId):
      respProblem(Http404, "Not Found", "Image not found", "image-not-found")
    try:
      if not store.deleteRecipe(recipeId):
        respProblem(Http404, "Not Found", "Image not found", "image-not-found")
    except CatchableError:
      error "Delete of '", recipeId, "' failed: ", getCurrentExceptionMsg()
      respProblem(Http500, "Internal Server Error", "Cannot delete image", "storage-error")
    resp Http204, ""

proc main() =
  addHandler(newConsoleLogger(
    levelThreshold = if verbose: lvlInfo else: lvlWarn,
    fmtStr = "$levelname ",
  ))
  store.initialize()
  info "Data location '", dataFolder, "'"
  if productionMode:
    info "Running in PRODUCTION mode"

  let settings = newSettings(
    port = Port(port),
    bindAddr = "0.0.0.0",
    # Static files are served by the /public route, so disable Jester's own handling.
    staticDir = dataFolder / ".static-disabled",
    maxBody = maxUploadBytes,
  )
  var server = initJester(imagesRouter, settings = settings)
  server.serve()

when isMainModule:
  main()
