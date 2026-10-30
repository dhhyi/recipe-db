import std/[algorithm, json, os, strutils, times, uri]
import nimcrypto/sha2
import pixie

type
  ImageStorage* = object
    root*: string
  StorageError* = object of CatchableError
  ImageNotFound* = object of CatchableError
  ImageStateInvalid* = object of CatchableError

proc validRecipeId*(id: string): bool =
  if id.len == 0 or id.len > 128 or ".." in id:
    return false
  for c in id:
    if c in {'/', '\\', '\0'} or c < ' ':
      return false
  true

proc outputHash*(bytes: string): string =
  ($sha256.digest(bytes)).toLowerAscii()

proc parseImageName*(name: string): tuple[valid: bool, recipeId, hash: string,
    thumb: bool] =
  if not name.endsWith(".png"):
    return
  var stem = name[0 ..< name.len - 4]
  result.thumb = stem.endsWith("-thumb")
  if result.thumb:
    stem.setLen(stem.len - 6)
  if stem.len < 66 or stem[^65] != '-':
    return
  result.recipeId = stem[0 ..< stem.len - 65]
  result.hash = stem[^64 .. ^1]
  if not validRecipeId(result.recipeId):
    return
  for c in result.hash:
    if c notin {'0'..'9', 'a'..'f'}:
      return
  result.valid = true

proc publicFolder*(store: ImageStorage): string = store.root / "public"
proc manifestFolder*(store: ImageStorage): string = store.root / "manifests"
proc manifestPath*(store: ImageStorage, id: string): string =
  store.manifestFolder / (id & ".json")

proc initialize*(store: ImageStorage) =
  createDir(store.publicFolder)
  createDir(store.manifestFolder)

var nextTemporary = 0

proc temporarySibling(path: string): string =
  while true:
    inc nextTemporary
    result = path & ".pending-" & $nextTemporary
    if not fileExists(result) and not dirExists(result):
      return

proc writeAtomic(path, bytes: string) =
  let temporary = temporarySibling(path)
  try:
    writeFile(temporary, bytes)
    moveFile(temporary, path)
  finally:
    if fileExists(temporary):
      removeFile(temporary)

proc publishOutput(store: ImageStorage, name, bytes: string) =
  let path = store.publicFolder / name
  if fileExists(path):
    if readFile(path) != bytes:
      raise newException(StorageError, "Existing output does not match its hash")
    return
  writeAtomic(path, bytes)

proc publish*(store: ImageStorage, id, normal, thumbnail: string): JsonNode =
  if not validRecipeId(id):
    raise newException(StorageError, "Invalid recipe id")
  let
    dimensions = decodeImageDimensions(normal)
    thumbDimensions = decodeImageDimensions(thumbnail)
    normalName = id & "-" & outputHash(normal) & ".png"
    thumbName = id & "-" & outputHash(thumbnail) & "-thumb.png"
  if dimensions.width != 648 or dimensions.height != 486 or
      thumbDimensions.width != 300 or thumbDimensions.height != 225:
    raise newException(StorageError, "Invalid output dimensions")
  result = %*{
    "recipeId": id,
    "height": dimensions.height,
    "width": dimensions.width,
    "size": normal.len,
    "modified": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff"),
    "url": "/public/" & encodeUrl(normalName, usePlus = false),
    "thumbUrl": "/public/" & encodeUrl(thumbName, usePlus = false),
  }
  # Requests use synchronous file operations with threads disabled: publication
  # cannot interleave with another upload or deletion.
  store.publishOutput(normalName, normal)
  store.publishOutput(thumbName, thumbnail)
  writeAtomic(store.manifestPath(id), $result)

proc metadata*(store: ImageStorage, id: string): JsonNode =
  if not validRecipeId(id):
    raise newException(ImageNotFound, "Image not found")
  let path = store.manifestPath(id)
  if not fileExists(path):
    if dirExists(path):
      raise newException(StorageError, "Invalid manifest")
    raise newException(ImageNotFound, "Image not found")
  try:
    result = parseJson(readFile(path))
    if result.kind != JObject:
      raise newException(StorageError, "Invalid manifest")
    for key in ["recipeId", "modified", "url", "thumbUrl"]:
      if not result.hasKey(key) or result[key].kind != JString:
        raise newException(StorageError, "Invalid manifest field: " & key)
    for key in ["width", "height", "size"]:
      if not result.hasKey(key) or result[key].kind != JInt:
        raise newException(StorageError, "Invalid manifest field: " & key)
    let width = result["width"].getInt
    let height = result["height"].getInt
    if result["recipeId"].getStr != id or
        not ((width == 650 and height == 488) or
        (width == 648 and height == 486)) or result["size"].getInt <= 0:
      raise newException(StorageError, "Invalid manifest metadata")
    discard parse(result["modified"].getStr, "yyyy-MM-dd'T'HH:mm:ss'.'fff",
        utc())
    for key in ["url", "thumbUrl"]:
      let url = result[key].getStr
      if not url.startsWith("/public/"):
        raise newException(StorageError, "Invalid manifest URL")
      let name = decodeUrl(url[8 .. ^1], decodePlus = false)
      let parsed = parseImageName(name)
      if not parsed.valid or parsed.recipeId != id or
          parsed.thumb != (key == "thumbUrl"):
        raise newException(StorageError, "Invalid manifest filename")
      let bytes = readFile(store.publicFolder / name)
      if outputHash(bytes) != parsed.hash or
          (key == "url" and bytes.len != result["size"].getInt):
        raise newException(StorageError, "Invalid stored output")
      let dimensions = decodeImageDimensions(bytes)
      if dimensions.width != (if parsed.thumb: 300 else: width) or
          dimensions.height != (if parsed.thumb: 225 else: height):
        raise newException(StorageError, "Invalid stored output dimensions")
  except StorageError:
    raise
  except CatchableError:
    raise newException(StorageError, "Cannot read image metadata: " &
        getCurrentExceptionMsg())

proc deleteRecipe*(store: ImageStorage, id: string): bool =
  if not validRecipeId(id):
    return false
  let manifest = store.manifestPath(id)
  result = fileExists(manifest) or dirExists(manifest)
  for kind, path in walkDir(store.publicFolder):
    let parsed = parseImageName(extractFilename(path))
    if kind == pcFile and parsed.valid and parsed.recipeId == id:
      removeFile(path)
      result = true
  if fileExists(manifest):
    removeFile(manifest)
  elif dirExists(manifest):
    removeDir(manifest)

proc addRecipeId(ids: var seq[string], id: string) =
  if id notin ids:
    ids.add(id)

proc recipeIds*(store: ImageStorage): seq[string] =
  for kind, path in walkDir(store.manifestFolder):
    if kind != pcFile:
      raise newException(StorageError, "Unclassifiable entry in manifest storage")
    let name = extractFilename(path)
    if not name.endsWith(".json"):
      raise newException(StorageError, "Unclassifiable manifest filename")
    let id = name[0 ..< name.len - 5]
    if not validRecipeId(id):
      raise newException(StorageError, "Invalid recipe ID in manifest filename")
    result.addRecipeId(id)

  for kind, path in walkDir(store.publicFolder):
    if kind != pcFile:
      raise newException(StorageError, "Unclassifiable entry in image storage")
    let parsed = parseImageName(extractFilename(path))
    if not parsed.valid:
      raise newException(StorageError, "Unclassifiable image filename")
    result.addRecipeId(parsed.recipeId)

  result.sort()

proc purgeRecipeData*(store: ImageStorage, id: string) =
  if not validRecipeId(id):
    raise newException(StorageError, "Invalid recipe ID")
  discard store.recipeIds()
  discard store.deleteRecipe(id)

proc compactRecipe*(store: ImageStorage, id: string) =
  if not validRecipeId(id):
    raise newException(StorageError, "Invalid recipe ID")
  discard store.recipeIds()

  let manifest = store.manifestPath(id)
  let hasManifest = fileExists(manifest)
  var outputs: seq[string]
  for kind, path in walkDir(store.publicFolder):
    let parsed = parseImageName(extractFilename(path))
    if parsed.recipeId == id:
      outputs.add(extractFilename(path))

  if not hasManifest:
    if outputs.len > 0:
      raise newException(ImageStateInvalid, "Image outputs have no manifest")
    return

  var current: JsonNode
  try:
    current = store.metadata(id)
  except CatchableError as error:
    raise newException(ImageStateInvalid, "Cannot validate current image pair: " & error.msg)

  let
    currentNormal = parseImageName(decodeUrl(current["url"].getStr[8 .. ^1], decodePlus = false))
    currentThumb = parseImageName(decodeUrl(current["thumbUrl"].getStr[8 .. ^1], decodePlus = false))
  if not currentNormal.valid or not currentThumb.valid:
    raise newException(ImageStateInvalid, "Manifest does not identify a valid image pair")

  for name in outputs:
    if name != extractFilename(decodeUrl(current["url"].getStr[8 .. ^1], decodePlus = false)) and
        name != extractFilename(decodeUrl(current["thumbUrl"].getStr[8 .. ^1], decodePlus = false)):
      removeFile(store.publicFolder / name)

proc wipe*(store: ImageStorage) =
  removeDir(store.publicFolder)
  removeDir(store.manifestFolder)
  store.initialize()
