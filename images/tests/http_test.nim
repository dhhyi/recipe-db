import std/[httpclient, json, os, osproc, strtabs, strutils, unittest, uri]
import pixie
import ../storage

const
  root = "tests/http-test-data"
  base = "http://127.0.0.1:18432"

proc startServer(production = false): Process =
  var environment = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    environment[key] = value
  environment["PORT"] = "18432"
  environment["DATA_LOCATION"] = root
  environment["PRODUCTION"] = $production
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

proc stopServer(server: Process) =
  server.terminate()
  discard server.waitForExit()
  server.close()

suite "backend HTTP publication contract":
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
    check published["width"].getInt == 650
    check published["height"].getInt == 488
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
    server = startServer(production = true)
    let guarded = client.request(base & "/images", httpMethod = HttpDelete)
    check guarded.code == Http404
    discard guarded.body
    check fileExists(store.manifestPath(specialId))
    client.close()
    server.stopServer()
    server = startServer()
    let wiped = client.request(base & "/images", httpMethod = HttpDelete)
    check wiped.code == Http204
    discard wiped.body
    check not fileExists(store.manifestPath(specialId))
