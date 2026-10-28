import std/[httpclient, json, options, os, osproc, sequtils, strtabs, strutils, unittest, uri]
import pixie
import ../storage

const
  root = "tests/http-test-data"
  base = "http://127.0.0.1:18432"

proc serverEnvironment(mode: Option[string], maxPixels, maxUploadBytes: int): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["PORT"] = "18432"
  result["DATA_LOCATION"] = root
  result.del("MODE")
  if mode.isSome:
    result["MODE"] = mode.get
  result["MAX_PIXELS"] = $maxPixels
  result["MAX_UPLOAD_BYTES"] = $maxUploadBytes

proc startServer(mode = some("testing"), maxPixels = 40_000_000,
    maxUploadBytes = 10 * 1024 * 1024): Process =
  let environment = serverEnvironment(mode, maxPixels, maxUploadBytes)
  result = startProcess("./server", env = environment,
      options = {poParentStreams})
  let client = newHttpClient(timeout = 100)
  defer: client.close()
  for attempt in 0 ..< 100:
    try:
      if client.get(base & "/health").code == Http204:
        return
    except CatchableError:
      discard
    sleep(20)
  result.terminate()
  discard result.waitForExit()
  result.close()
  raise newException(IOError, "Test server did not become ready")

proc checkInvalidMode(mode: string) =
  let environment = serverEnvironment(some(mode), none(string),
      40_000_000, 10 * 1024 * 1024)
  let server = startProcess("./server", env = environment,
      options = {poParentStreams})
  check server.waitForExit() != 0
  server.close()

proc stopServer(server: Process) =
  server.terminate()
  discard server.waitForExit()
  server.close()

suite "backend HTTP publication contract":
  test "validates mode values and rejects unsupported configuration":
    for mode in ["", "backup", "Production", " production", "testing "]:
      checkInvalidMode(mode)

  test "off-center crop pixels, strict errors and failed saves preserve the complete pair":
    if dirExists(root):
      removeDir(root)
    var server = startServer()
    let client = newHttpClient(timeout = 5000)
    defer:
      client.close()
      server.stopServer()
      if dirExists(root):
        removeDir(root)
    let source = newImage(1200, 900)
    source.fill(parseHtmlColor("#ff0000"))
    for y in 200 ..< 650:
      for x in 600 ..< 1200:
        source[x, y] = parseHtmlColor(
            if x < 900: "#00ff00" else: "#0000ff").rgbx
    let body = source.encodeImage(PngFormat)
    let query = "?cropX=600&cropY=200&cropWidth=600&cropHeight=450"
    proc upload(query: string, bytes = body, mime = "image/png"): Response =
      client.request(base & "/images/crop" & query, httpMethod = HttpPost,
          body = bytes, headers = newHttpHeaders({"Content-Type": mime}))
    let response = upload(query)
    check response.code == Http201
    let saved = parseJson(response.body)
    var savedBytes: array[2, string]
    for i, key in ["url", "thumbUrl"]:
      let bytes = client.getContent(base & saved[key].getStr)
      savedBytes[i] = bytes
      let image = decodeImage(bytes)
      check image.width == (if i == 0: 648 else: 300)
      check image.height == (if i == 0: 486 else: 225)
      check image[image.width div 4, image.height div 2] ==
          parseHtmlColor("#00ff00").rgbx
      check image[image.width * 3 div 4, image.height div 2] ==
          parseHtmlColor("#0000ff").rgbx
    let store = ImageStorage(root: root)
    check toSeq(walkDir(store.publicFolder)).len == 2
    for (query, code, field) in [
        ("?cropX=0", "invalid-crop", "cropY"),
        ("?cropX=-1&cropY=0&cropWidth=300&cropHeight=225", "invalid-crop",
            "cropX"),
        ("?cropX=1.5&cropY=0&cropWidth=300&cropHeight=225", "invalid-crop",
            "cropX"),
        ("?cropX=&cropY=0&cropWidth=300&cropHeight=225", "invalid-crop",
            "cropX"),
        ("?cropX=0&cropY=0&cropWidth=0&cropHeight=225", "invalid-crop",
            "cropWidth"),
        ("?cropX=0&cropX=1&cropY=0&cropWidth=300&cropHeight=225",
            "invalid-crop", "cropX"),
        ("?cropX=999999999999999999999999&cropY=0&cropWidth=300&cropHeight=225",
          "invalid-crop", "cropX"),
        ("?cropX=0&cropY=0&cropWidth=301&cropHeight=225",
            "invalid-crop-aspect-ratio", ""),
        ("?cropX=0&cropY=0&cropWidth=296&cropHeight=222", "crop-too-small", ""),
        ("?cropX=901&cropY=0&cropWidth=300&cropHeight=225",
            "crop-out-of-bounds", ""),
        ("?cropX=0&cropY=676&cropWidth=300&cropHeight=225",
            "crop-out-of-bounds", ""),
        ("?cropX=9223372036854775807&cropY=0&cropWidth=300&cropHeight=225",
          "crop-out-of-bounds", "")]:
      let rejected = upload(query)
      check rejected.code == Http400
      check rejected.headers["Content-Type"] == "application/problem+json"
      check rejected.headers["Cache-Control"] == "no-store"
      let problem = parseJson(rejected.body)
      check problem["type"].getStr == "about:blank"
      check problem["status"].getInt == 400
      check problem["code"].getStr == code
      if field.len > 0:
        check problem["field"].getStr == field
      check parseJson(client.getContent(base & "/images/crop/meta")) == saved
    for (bytes, mime, code) in [
        ("not an image", "image/png", "unsupported-content-type"),
        ("\x89PNG\r\n\x1A\nbroken", "image/png", "invalid-image"),
        (body, "image/jpeg", "unsupported-content-type")]:
      let rejected = upload(query, bytes, mime)
      check rejected.code == Http400
      check parseJson(rejected.body)["code"].getStr == code
    let replacement = newImage(600, 450)
    replacement.fill(parseHtmlColor("#ffffff"))
    let blockedThumb = replacement.resize(300, 225).encodeImage(PngFormat)
    let blockedPath = store.publicFolder /
        ("crop-" & outputHash(blockedThumb) & "-thumb.png")
    createDir(blockedPath)
    let failed = upload("?cropX=0&cropY=0&cropWidth=600&cropHeight=450",
        replacement.encodeImage(PngFormat))
    check failed.code == Http500
    check parseJson(failed.body)["code"].getStr == "storage-error"
    check parseJson(client.getContent(base & "/images/crop/meta")) == saved
    for i, key in ["url", "thumbUrl"]:
      check client.getContent(base & saved[key].getStr) == savedBytes[i]
    for kind, path in walkDir(store.publicFolder):
      check ".pending-" notin path
    for kind, path in walkDir(store.manifestFolder):
      check ".pending-" notin path
    client.close()
    server.stopServer()
    server = startServer(maxPixels = 100)
    let tooManyPixels = upload(query)
    check tooManyPixels.code == Http400
    check parseJson(tooManyPixels.body)["code"].getStr == "image-too-large"
    check parseJson(client.getContent(base & "/images/crop/meta")) == saved
    client.close()
    server.stopServer()
    server = startServer(maxUploadBytes = 64)
    let tooManyBytes = upload(query)
    check tooManyBytes.code == Http413
    discard tooManyBytes.body
    check parseJson(client.getContent(base & "/images/crop/meta")) == saved

  test "metadata, immutable headers, private files, errors, restart and production wipe guard":
    if dirExists(root):
      removeDir(root)
    var server = startServer()
    let client = newHttpClient(timeout = 2000)
    defer:
      client.close()
      server.stopServer()
      if dirExists(root):
        removeDir(root)

    let image = newImage(70, 40)
    image.fill(parseHtmlColor("#ff0000"))
    let input = image.encodeImage(PngFormat)
    let id = repeat('a', 128)
    let uploaded = client.request(base & "/images/" & id, httpMethod = HttpPost,
        body = input, headers = newHttpHeaders({"Content-Type": "image/png"}))
    check uploaded.code == Http201
    check uploaded.headers["Content-Type"] == "application/json"
    let published = parseJson(uploaded.body)
    check published["width"].getInt == 648
    check published["height"].getInt == 486
    let metadata = client.get(base & "/images/" & id & "/meta")
    check metadata.code == Http200
    check metadata.headers["Cache-Control"] == "no-store"
    check parseJson(metadata.body) == published
    var originalBytes: array[2, string]
    for index, key in ["url", "thumbUrl"]:
      let response = client.get(base & published[key].getStr)
      check response.code == Http200
      check response.headers["Content-Type"] == "image/png"
      check response.headers["Cache-Control"] ==
          "public, max-age=31536000, immutable"
      let bytes = response.body
      originalBytes[index] = bytes
      check parseImageName(published[key].getStr[8 .. ^1]).hash == outputHash(bytes)
      if key == "url":
        check bytes.len == published["size"].getInt
      let cached = client.request(base & published[key].getStr,
          headers = newHttpHeaders({"If-None-Match": $response.headers["ETag"]}))
      check cached.code == Http304
      check cached.headers["Cache-Control"] ==
          "public, max-age=31536000, immutable"
      discard cached.body
    for path in ["/public/" & id & ".png", "/public/" & id & ".json",
        "/manifests/" & id & ".json",
        published["url"].getStr & ".pending-1", "/public/../manifests/" & id & ".json"]:
      let response = client.get(base & path)
      check response.code == Http404
      check "immutable" notin response.headers.getOrDefault("Cache-Control")
      discard response.body
    let specialId = "recipe #?+%:ümlaut"
    let specialUpload = client.request(base & "/images/" &
        encodeUrl(specialId, usePlus = false), httpMethod = HttpPost,
        body = input, headers = newHttpHeaders({"Content-Type": "image/png"}))
    check specialUpload.code == Http201
    let special = parseJson(specialUpload.body)
    check special["recipeId"].getStr == specialId
    let specialImage = client.get(base & special["url"].getStr)
    check specialImage.code == Http200
    discard specialImage.body
    image.fill(parseHtmlColor("#0000ff"))
    let replacement = client.request(base & "/images/" & id,
        httpMethod = HttpPost, body = image.encodeImage(PngFormat),
        headers = newHttpHeaders({"Content-Type": "image/png"}))
    check replacement.code == Http201
    let replaced = parseJson(replacement.body)
    check replaced["url"] != published["url"]
    check replaced["thumbUrl"] != published["thumbUrl"]
    client.close()
    server.stopServer()
    server = startServer()
    let afterRestart = client.get(base & "/images/" & id & "/meta")
    check afterRestart.code == Http200
    check parseJson(afterRestart.body) == replaced
    for index, key in ["url", "thumbUrl"]:
      let retained = client.get(base & published[key].getStr)
      check retained.code == Http200
      let bytes = retained.body
      check bytes == originalBytes[index]
      check outputHash(bytes) == parseImageName(published[key].getStr[8 .. ^1]).hash

    let store = ImageStorage(root: root)
    writeFile(store.manifestPath(id), "{")
    let corrupt = client.get(base & "/images/" & id & "/meta")
    check corrupt.code == Http500
    check corrupt.headers["Content-Type"] == "application/problem+json"
    check corrupt.headers["Cache-Control"] == "no-store"
    check parseJson(corrupt.body)["code"].getStr == "metadata-error"
    writeFile(store.manifestPath(id), $replaced)
    removeFile(store.publicFolder / replaced["thumbUrl"].getStr[8 .. ^1])
    let missing = client.get(base & "/images/" & id & "/meta")
    check missing.code == Http500
    check parseJson(missing.body)["code"].getStr == "metadata-error"
    let absent = client.get(base & "/images/absent/meta")
    check absent.code == Http404
    check absent.headers["Cache-Control"] == "no-store"
    check parseJson(absent.body)["code"].getStr == "image-not-found"
    let deleted = client.request(base & "/images/" & id,
        httpMethod = HttpDelete)
    check deleted.code == Http204
    discard deleted.body
    let deletedImage = client.get(base & published["url"].getStr)
    check deletedImage.code == Http404
    check "immutable" notin deletedImage.headers.getOrDefault("Cache-Control")
    discard deletedImage.body
    client.close()
    server.stopServer()
    client.close()
    server.stopServer()
    server = startServer(mode = some("production"))
    let explicitProduction = client.request(base & "/images", httpMethod = HttpDelete)
    check explicitProduction.code == Http404
    discard explicitProduction.body
    check fileExists(store.manifestPath(specialId))
    client.close()
    server.stopServer()
    server = startServer(mode = none(string))
    let guarded = client.request(base & "/images", httpMethod = HttpDelete)
    check guarded.code == Http404
    discard guarded.body
    check fileExists(store.manifestPath(specialId))
    client.close()
    server.stopServer()
    server = startServer(mode = some("testing"))
    let wiped = client.request(base & "/images/", httpMethod = HttpDelete)
    check wiped.code == Http204
    discard wiped.body
    check not fileExists(store.manifestPath(specialId))
    let repeated = client.request(base & "/images", httpMethod = HttpDelete)
    check repeated.code == Http204
    discard repeated.body
