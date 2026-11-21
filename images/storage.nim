import std/[algorithm, json, os, posix, strutils, times, uri]
import nimcrypto/sha2
import pixie
import storage_version_generated

type
  ImageStorage* = object
    root*: string
  StorageError* = object of CatchableError
  ImageNotFound* = object of CatchableError
  ImageLimitReached* = object of CatchableError
  ImageOrderInvalid* = object of CatchableError
  ImageStateInvalid* = object of CatchableError

const maxImagesPerRecipe* = 10

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

proc restrictFreshRoot*(store: ImageStorage) =
  createDir(store.root)
  setFilePermissions(store.root, {fpUserRead, fpUserWrite, fpUserExec})

proc storageFailure(marker, reason: string) {.noreturn.} =
  raise newException(StorageError, "images storage version failure at " &
    marker & ": expected " & $expectedStorageVersion & ", " & reason)

proc checkStorageVersion*(store: ImageStorage, mode: string): bool =
  let marker = store.root / "storage-version"
  var version = -1
  if fileExists(marker) or dirExists(marker):
    let info = getFileInfo(marker, followSymlink = false)
    if info.kind != pcFile:
      storageFailure(marker, "unsafe marker file type")
    try:
      let contents = readFile(marker)
      if not contents.endsWith("\n") or contents.len < 2 or
          contents[0 .. ^2].len == 0 or contents[0] == '0':
        storageFailure(marker, "invalid marker contents")
      for c in contents[0 .. ^2]:
        if c notin {'0'..'9'}:
          storageFailure(marker, "invalid marker contents")
      version = parseInt(contents[0 .. ^2])
      if version <= 0:
        storageFailure(marker, "invalid marker contents")
    except StorageError:
      raise
    except CatchableError:
      storageFailure(marker, "cannot read marker")
  elif fileExists(store.root):
    storageFailure(marker, "cannot inspect data root")

  var hasEntries: bool
  if dirExists(store.root):
    try:
      for kind, path in walkDir(store.root, checkDir = true):
        let name = extractFilename(path)
        if name == "storage-version":
          if kind != pcFile:
            storageFailure(marker, "unsafe marker file type")
          continue
        hasEntries = true
    except StorageError:
      raise
    except CatchableError:
      storageFailure(marker, "cannot inspect data root")

  if version == -1:
    if hasEntries:
      storageFailure(marker, "marker missing; existing data found")
    if mode == "backup":
      storageFailure(marker, "marker missing; backup mode cannot initialize")
    return true
  if mode == "backup" and
      (not dirExists(store.publicFolder) or not dirExists(store.manifestFolder)):
    storageFailure(marker, "application data missing; backup mode cannot initialize")
  false

proc publishStorageVersion*(store: ImageStorage) =
  let marker = store.root / "storage-version"
  let temporary = marker & ".pending-" & $getpid()
  try:
    writeFile(temporary, $expectedStorageVersion & "\n")
    if posix.link(temporary.cstring, marker.cstring) != 0:
      storageFailure(marker, "cannot atomically publish marker")
  finally:
    if fileExists(temporary):
      removeFile(temporary)

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
    if getFileInfo(path, followSymlink = false).kind != pcFile:
      raise newException(StorageError, "Existing output is not a regular file")
    if readFile(path) != bytes:
      raise newException(StorageError, "Existing output does not match its hash")
    return
  writeAtomic(path, bytes)

proc validateMetadata(store: ImageStorage, id: string,
    metadata: JsonNode, validateFiles = true): JsonNode =
  if metadata.kind != JObject:
    raise newException(StorageError, "Invalid manifest entry")
  for key in ["recipeId", "id", "modified", "url", "thumbUrl"]:
    if not metadata.hasKey(key) or metadata[key].kind != JString:
      raise newException(StorageError, "Invalid manifest field: " & key)
  for key in ["width", "height", "size"]:
    if not metadata.hasKey(key) or metadata[key].kind != JInt:
      raise newException(StorageError, "Invalid manifest field: " & key)
  let
    width = metadata["width"].getInt
    height = metadata["height"].getInt
    imageId = metadata["id"].getStr
  if metadata["recipeId"].getStr != id or
      not ((width == 650 and height == 488) or
      (width == 648 and height == 486)) or metadata["size"].getInt <= 0 or
      imageId.len != 64:
    raise newException(StorageError, "Invalid manifest metadata")
  for c in imageId:
    if c notin {'0'..'9', 'a'..'f'}:
      raise newException(StorageError, "Invalid image id")
  discard parse(metadata["modified"].getStr, "yyyy-MM-dd'T'HH:mm:ss'.'fff",
      utc())

  for key in ["url", "thumbUrl"]:
    let url = metadata[key].getStr
    if not url.startsWith("/public/"):
      raise newException(StorageError, "Invalid manifest URL")
    let name = decodeUrl(url[8 .. ^1], decodePlus = false)
    let parsed = parseImageName(name)
    if not parsed.valid or parsed.recipeId != id or
        parsed.thumb != (key == "thumbUrl") or
        (key == "url" and parsed.hash != imageId):
      raise newException(StorageError, "Invalid manifest filename")
    if not validateFiles:
      continue
    let path = store.publicFolder / name
    if not fileExists(path) or
        getFileInfo(path, followSymlink = false).kind != pcFile:
      raise newException(StorageError, "Missing or unsafe stored output")
    let bytes = readFile(path)
    if outputHash(bytes) != parsed.hash or
        (key == "url" and bytes.len != metadata["size"].getInt):
      raise newException(StorageError, "Invalid stored output")
    let dimensions = decodeImageDimensions(bytes)
    if dimensions.width != (if parsed.thumb: 300 else: width) or
        dimensions.height != (if parsed.thumb: 225 else: height):
      raise newException(StorageError, "Invalid stored output dimensions")
  metadata

proc readCollection(store: ImageStorage, id: string,
    validateFiles: bool): JsonNode =
  if not validRecipeId(id):
    raise newException(ImageNotFound, "Image not found")
  let path = store.manifestPath(id)
  if not fileExists(path):
    if dirExists(path):
      raise newException(StorageError, "Invalid manifest")
    return newJArray()
  if getFileInfo(path, followSymlink = false).kind != pcFile:
    raise newException(StorageError, "Invalid manifest file type")
  try:
    result = parseJson(readFile(path))
    if result.kind != JArray or result.len > maxImagesPerRecipe:
      raise newException(StorageError, "Invalid manifest")
    var ids: seq[string]
    for entry in result:
      discard store.validateMetadata(id, entry, validateFiles)
      let imageId = entry["id"].getStr
      if imageId in ids:
        raise newException(StorageError, "Duplicate image id in manifest")
      ids.add(imageId)
  except StorageError:
    raise
  except CatchableError:
    raise newException(StorageError, "Cannot read image metadata: " &
        getCurrentExceptionMsg())

proc collection*(store: ImageStorage, id: string): JsonNode =
  store.readCollection(id, true)

proc metadata*(store: ImageStorage, id: string): JsonNode =
  let images = store.readCollection(id, false)
  if images.len == 0:
    raise newException(ImageNotFound, "Image not found")
  store.validateMetadata(id, images[0])

proc reorder*(store: ImageStorage, id: string,
    requestedIds: JsonNode): JsonNode =
  if requestedIds.kind != JArray:
    raise newException(ImageOrderInvalid,
        "Image order must be an array of image IDs")

  let images = store.collection(id)
  if requestedIds.len != images.len:
    raise newException(ImageOrderInvalid,
        "Image order must contain each current image exactly once")

  var currentIds: seq[string]
  for image in images:
    currentIds.add(image["id"].getStr)

  var seen: seq[string]
  result = newJArray()
  var changed = false
  for index in 0 ..< requestedIds.len:
    let requested = requestedIds[index]
    if requested.kind != JString:
      raise newException(ImageOrderInvalid,
          "Image order must contain only image IDs")
    let imageId = requested.getStr
    if imageId in seen:
      raise newException(ImageOrderInvalid,
          "Image order must contain each current image exactly once")
    seen.add(imageId)

    var found = false
    for image in images:
      if image["id"].getStr == imageId:
        result.add(image)
        found = true
        break
    if not found:
      raise newException(ImageOrderInvalid,
          "Image order must contain each current image exactly once")
    if currentIds[index] != imageId:
      changed = true

  if changed:
    writeAtomic(store.manifestPath(id), $result)

proc publish*(store: ImageStorage, id, normal, thumbnail: string): JsonNode =
  if not validRecipeId(id):
    raise newException(StorageError, "Invalid recipe id")
  let
    dimensions = decodeImageDimensions(normal)
    thumbDimensions = decodeImageDimensions(thumbnail)
    imageId = outputHash(normal)
    normalName = id & "-" & imageId & ".png"
    thumbName = id & "-" & outputHash(thumbnail) & "-thumb.png"
  if dimensions.width != 648 or dimensions.height != 486 or
      thumbDimensions.width != 300 or thumbDimensions.height != 225:
    raise newException(StorageError, "Invalid output dimensions")
  result = %*{
    "recipeId": id,
    "id": imageId,
    "height": dimensions.height,
    "width": dimensions.width,
    "size": normal.len,
    "modified": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff"),
    "url": "/public/" & encodeUrl(normalName, usePlus = false),
    "thumbUrl": "/public/" & encodeUrl(thumbName, usePlus = false),
  }

  var images = newJArray()
  images.add(result)
  for existing in store.collection(id):
    if existing["id"].getStr != imageId:
      images.add(existing)
  if images.len > maxImagesPerRecipe:
    raise newException(ImageLimitReached,
        "A recipe can have at most " & $maxImagesPerRecipe & " images")

  # Requests use synchronous file operations with threads disabled: publication
  # cannot interleave with another upload or deletion.
  store.publishOutput(normalName, normal)
  store.publishOutput(thumbName, thumbnail)
  writeAtomic(store.manifestPath(id), $images)

proc deleteImage*(store: ImageStorage, id, imageId: string): bool =
  if not validRecipeId(id):
    return false
  let images = store.collection(id)
  var retained = newJArray()
  for entry in images:
    if entry["id"].getStr == imageId:
      result = true
    else:
      retained.add(entry)
  if result:
    writeAtomic(store.manifestPath(id), $retained)

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
    current = store.collection(id)
  except CatchableError as error:
    raise newException(ImageStateInvalid, "Cannot validate current image collection: " & error.msg)

  var retained: seq[string]
  for entry in current:
    retained.add(decodeUrl(entry["url"].getStr[8 .. ^1], decodePlus = false))
    retained.add(decodeUrl(entry["thumbUrl"].getStr[8 .. ^1], decodePlus = false))
  for name in outputs:
    if name notin retained:
      removeFile(store.publicFolder / name)

proc wipe*(store: ImageStorage) =
  removeDir(store.publicFolder)
  removeDir(store.manifestFolder)
  store.initialize()
