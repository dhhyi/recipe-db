import std/[httpcore, json, logging, os, strutils, times]

import jester
import pixie

const
  thumbWidth = 600
  thumbHeight = 450
  imagesSubfolder = "public"
  pngSignature = "\x89PNG\r\n\x1A\n"
  jpegSignature = "\xFF\xD8"

let
  testingMode = existsEnv("TESTING")
  verbose = getEnv("VERBOSE") == "true"
  documentRoot = getEnv("DATA_LOCATION", "public")
  dataFolder = documentRoot / imagesSubfolder
  port = parseInt(getEnv("PORT", "8000"))
  maxUploadBytes = parseInt(getEnv("MAX_UPLOAD_BYTES", $(10 * 1024 * 1024)))
  maxPixels = parseInt(getEnv("MAX_PIXELS", $(40_000_000)))

proc isSafeSegment(segment: string): bool =
  ## Rejects anything that could escape the data folder or confuse the file system.
  if segment.len == 0 or segment.len > 128:
    return false
  if ".." in segment:
    return false
  for c in segment:
    if c in {'/', '\\', '\0'} or c < ' ':
      return false
  true

proc imageFileName(recipeId: string, thumb = false): string =
  if thumb: recipeId & "-thumb.png" else: recipeId & ".png"

proc imageFile(recipeId: string, thumb = false): string =
  dataFolder / imageFileName(recipeId, thumb)

proc imageUrl(recipeId: string, thumb = false): string =
  "/" & imagesSubfolder & "/" & imageFileName(recipeId, thumb)

proc cropToThumbRatio(image: Image): Image =
  ## Centered crop so the result has the thumbnail's aspect ratio.
  let
    targetRatio = thumbWidth / thumbHeight
    ratio = image.width / image.height
  if ratio > targetRatio:
    let w = min(image.width, int(image.height.float * targetRatio + 0.5))
    image.subImage((image.width - w) div 2, 0, w, image.height)
  elif ratio < targetRatio:
    let h = min(image.height, int(image.width.float / targetRatio + 0.5))
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

router imagesRouter:
  get "/health":
    resp Http204, ""

  get "/public/@name":
    let name = @"name"
    if not isSafeSegment(name):
      resp Http404, "Not found"
    let path = dataFolder / name
    if not fileExists(path):
      resp Http404, "Not found"
    sendFile(path)

  post "/images/@recipeId":
    let recipeId = @"recipeId"
    if not isSafeSegment(recipeId):
      resp Http400, "Invalid recipe id"

    let contentType = ($request.headers.getOrDefault(
        "Content-Type")).split(';')[0].strip().toLowerAscii()
    let body = request.body
    if not matchesContentType(body, contentType):
      resp Http400, "Unsupported content type '" & contentType & "'"

    try:
      let dimensions = decodeImageDimensions(body)
      if dimensions.width * dimensions.height > maxPixels:
        resp Http400, "Image exceeds the maximum of " & $maxPixels & " pixels"

      let image = decodeImage(body)
      image.writeFile(imageFile(recipeId))
      image.cropToThumbRatio().resize(thumbWidth, thumbHeight).writeFile(
          imageFile(recipeId, true))
      resp Http201, ""
    except PixieError, IOError, OSError:
      error "Upload of '", recipeId, "' failed: ", getCurrentExceptionMsg()
      resp Http400, "Error: " & getCurrentExceptionMsg()

  get "/images/@recipeId/meta":
    let recipeId = @"recipeId"
    if not isSafeSegment(recipeId):
      resp Http404, "Not found"

    let path = imageFile(recipeId)
    if not fileExists(path):
      resp Http404, "Not found"

    try:
      let
        info = getFileInfo(path)
        dimensions = readImageDimensions(path)
      resp Http200, $(%*{
        "recipeId": recipeId,
        "height": dimensions.height,
        "width": dimensions.width,
        "size": info.size,
        "modified": info.lastWriteTime.utc.format(
            "yyyy-MM-dd'T'HH:mm:ss'.'fff"),
        "url": imageUrl(recipeId),
        "thumbUrl": imageUrl(recipeId, true),
      }), "application/json"
    except PixieError, OSError:
      error "Meta of '", recipeId, "' failed: ", getCurrentExceptionMsg()
      resp Http500, "Error: " & getCurrentExceptionMsg()

  delete "/images/?":
    if not testingMode:
      resp Http404, "Not found"
    removeDir(dataFolder)
    createDir(dataFolder)
    resp Http204, ""

  delete "/images/@recipeId":
    let recipeId = @"recipeId"
    if not isSafeSegment(recipeId):
      resp Http404, "Not found"

    let path = imageFile(recipeId)
    if not fileExists(path):
      resp Http404, "Not found"
    removeFile(path)
    removeFile(imageFile(recipeId, true))
    resp Http204, ""

proc main() =
  addHandler(newConsoleLogger(
    levelThreshold = if verbose: lvlInfo else: lvlWarn,
    fmtStr = "$levelname ",
  ))
  createDir(dataFolder)
  info "Data location '", dataFolder, "'"
  if testingMode:
    info "Running in TESTING mode"

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
