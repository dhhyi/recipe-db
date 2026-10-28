import std/[httpcore, json, logging, os, strutils, uri]

import jester
import pixie
import storage
import processing

const
  thumbWidth = 300
  normalWidth = 648
  imagesSubfolder = "public"
  pngSignature = "\x89PNG\r\n\x1A\n"
  jpegSignature = "\xFF\xD8"

let
  modeValue = getEnv("MODE", "production")
  runtimeMode = case modeValue
    of "production": "production"
    of "testing": "testing"
    else: raise newException(ValueError,
      "Invalid MODE='" & modeValue & "'; expected 'production' or 'testing'")
  verbose = getEnv("VERBOSE") == "true"
  documentRoot = getEnv("DATA_LOCATION", "public")
  dataFolder = documentRoot / imagesSubfolder
  store = ImageStorage(root: documentRoot)
  port = parseInt(getEnv("PORT", "8000"))
  maxUploadBytes = parseInt(getEnv("MAX_UPLOAD_BYTES", $(10 * 1024 * 1024)))
  maxPixels = parseInt(getEnv("MAX_PIXELS", $(40_000_000)))

proc matchesContentType(body, contentType: string): bool =
  ## The declared type must match the actual magic bytes, otherwise pixie would
  ## happily decode other formats such as SVG.
  case contentType
  of "image/png": body.startsWith(pngSignature)
  of "image/jpeg", "image/jpg": body.startsWith(jpegSignature)
  else: false

proc problemDetails(status: HttpCode, title, detail, code: string,
    field = ""): string =
  ## RFC 9457 Problem Details body, mirroring the recipes service's error shape.
  var body = %*{
    "type": "about:blank",
    "title": title,
    "status": ord(status),
    "detail": detail,
    "code": code,
  }
  if field.len > 0:
    body["field"] = %field
  $body

template respProblem(status: HttpCode, title, detail, code: string, field = "") =
  resp status, @[("Content-Type", "application/problem+json"),
      ("Cache-Control", "no-store")], problemDetails(status, title, detail,
          code, field)

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
    if body.len > maxUploadBytes:
      respProblem(Http413, "Content Too Large",
          "Image exceeds the maximum of " & $maxUploadBytes & " encoded bytes",
          "image-too-large")
    if not matchesContentType(body, contentType):
      respProblem(Http400, "Bad Request",
          "Unsupported content type '" & contentType & "'", "unsupported-content-type")

    var cropped: Image
    try:
      let crop = parseCrop(request.query)
      cropped = orientedSource(body, maxPixels).selectedSource(crop)
    except CropError as error:
      respProblem(Http400, "Bad Request", error.msg, error.code, error.field)
    except PixieError:
      error "Upload of '", recipeId, "' failed: ", getCurrentExceptionMsg()
      respProblem(Http400, "Bad Request", getCurrentExceptionMsg(), "invalid-image")
    try:
      let normal = cropped.resize(normalWidth, 486).encodeImage(PngFormat)
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
    if runtimeMode != "testing":
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
  if runtimeMode == "production":
    info "Running in production mode"

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
