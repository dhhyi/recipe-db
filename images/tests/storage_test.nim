import std/[algorithm, json, os, sequtils, strutils, times, unittest, uri]
import pixie
import ../storage

const testRoot = "tests/storage-test-data"
const versionRoot = "tests/storage-version-data"

proc outputs(color: string): tuple[normal, thumb: string] =
  let normal = newImage(648, 486)
  normal.fill(parseHtmlColor(color))
  let thumb = newImage(300, 225)
  thumb.fill(parseHtmlColor(color))
  (normal.encodeImage(PngFormat), thumb.encodeImage(PngFormat))

proc filename(metadata: JsonNode, key: string): string =
  decodeUrl(metadata[key].getStr[8 .. ^1], decodePlus = false)

proc cleanDirectory(path: string) =
  if dirExists(path):
    for kind, entry in walkDir(path):
      if kind == pcDir:
        cleanDirectory(entry)
        removeDir(entry)
      else:
        removeFile(entry)
    removeDir(path)

suite "immutable image storage":
  setup:
    if dirExists(testRoot):
      removeDir(testRoot)
    let store = ImageStorage(root: testRoot)
    store.initialize()

  teardown:
    if dirExists(testRoot):
      removeDir(testRoot)

  test "SHA-256 known vector and independent filename validation":
    check outputHash("abc") ==
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    let id = repeat('a', 128)
    check validRecipeId(id)
    check not validRecipeId(id & "a")
    for bad in ["", "../a", "a..b", "a/b", "a\\b", "a\0b", "a\nb"]:
      check not validRecipeId(bad)
    let hash = outputHash("abc")
    check parseImageName(id & "-" & hash & "-thumb.png").valid
    check not parseImageName(id & "-" & hash.toUpperAscii() & ".png").valid
    for name in ["a.png", "a-thumb.png", "../a-" & hash & ".png",
        "a-" & hash & ".png.pending-1", ".manifest.json"]:
      check not parseImageName(name).valid


  test "restart, retention, identical uploads and A to B to A":
    let a = outputs("#ff0000")
    let b = outputs("#0000ff")
    let first = store.publish("recipe", a.normal, a.thumb)
    let normalPath = store.publicFolder / first.filename("url")
    let thumbPath = store.publicFolder / first.filename("thumbUrl")
    let fixedTime = fromUnix(1_600_000_000)
    setLastModificationTime(normalPath, fixedTime)
    setLastModificationTime(thumbPath, fixedTime)
    check parseImageName(first.filename("url")).hash == outputHash(a.normal)
    check parseImageName(first.filename("thumbUrl")).hash == outputHash(a.thumb)
    check parseImageName(first.filename("url")).hash !=
        parseImageName(first.filename("thumbUrl")).hash
    check first["width"].getInt == 648
    check first["height"].getInt == 486
    check first["size"].getInt == a.normal.len
    check ImageStorage(root: testRoot).metadata("recipe") == first
    let identical = store.publish("recipe", a.normal, a.thumb)
    check identical["url"] == first["url"]
    check identical["thumbUrl"] == first["thumbUrl"]
    check getLastModificationTime(normalPath) == fixedTime
    check getLastModificationTime(thumbPath) == fixedTime
    let second = store.publish("recipe", b.normal, b.thumb)
    check second["url"] != first["url"]
    check second["thumbUrl"] != first["thumbUrl"]
    check readFile(normalPath) == a.normal
    check readFile(thumbPath) == a.thumb
    check ImageStorage(root: testRoot).metadata("recipe") == second
    let again = store.publish("recipe", a.normal, a.thumb)
    check again["url"] == first["url"]
    check again["thumbUrl"] == first["thumbUrl"]
    check getLastModificationTime(normalPath) == fixedTime
    check getLastModificationTime(thumbPath) == fixedTime
    check readFile(store.publicFolder / second.filename("url")) == b.normal
    let normalOnly = store.publish("recipe", b.normal, a.thumb)
    check normalOnly["url"] == second["url"]
    check normalOnly["thumbUrl"] == first["thumbUrl"]
    let thumbOnly = store.publish("recipe", a.normal, b.thumb)
    check thumbOnly["url"] == first["url"]
    check thumbOnly["thumbUrl"] == second["thumbUrl"]
    check parseJson(readFile(store.manifestPath("recipe"))).kind == JArray
    check thumbOnly["id"].getStr == parseImageName(first.filename("url")).hash

  test "ordered collections deduplicate, delete by id, and persist atomically":
    let
      a = outputs("#ff0000")
      b = outputs("#0000ff")
      c = outputs("#00ff00")
      firstA = store.publish("recipe", a.normal, a.thumb)
      firstB = store.publish("recipe", b.normal, b.thumb)
      firstC = store.publish("recipe", c.normal, c.thumb)
    check store.collection("recipe").mapIt(it["id"].getStr) ==
        @[firstC["id"].getStr, firstB["id"].getStr, firstA["id"].getStr]

    let updatedB = store.publish("recipe", b.normal, c.thumb)
    check updatedB["thumbUrl"] == firstC["thumbUrl"]
    check store.collection("recipe").mapIt(it["id"].getStr) ==
        @[firstB["id"].getStr, firstC["id"].getStr, firstA["id"].getStr]
    check store.collection("recipe").filterIt(
        it["id"].getStr == firstB["id"].getStr).len == 1

    let removedNormal = store.publicFolder / firstC.filename("url")
    let removedThumb = store.publicFolder / firstC.filename("thumbUrl")
    check store.deleteImage("recipe", firstC["id"].getStr)
    check fileExists(removedNormal)
    check fileExists(removedThumb)
    check not store.deleteImage("recipe", firstC["id"].getStr)
    let restarted = ImageStorage(root: testRoot)
    check restarted.collection("recipe").mapIt(it["id"].getStr) ==
        @[firstB["id"].getStr, firstA["id"].getStr]
    check restarted.metadata("recipe") == updatedB

    check restarted.deleteImage("recipe", firstB["id"].getStr)
    check restarted.deleteImage("recipe", firstA["id"].getStr)
    check restarted.collection("recipe").len == 0
    expect ImageNotFound:
      discard restarted.metadata("recipe")

  test "reorder requires exact membership and persists without changing outputs":
    let
      a = outputs("#ff0000")
      b = outputs("#0000ff")
      c = outputs("#00ff00")
      imageA = store.publish("recipe", a.normal, a.thumb)
      imageB = store.publish("recipe", b.normal, b.thumb)
      imageC = store.publish("recipe", c.normal, c.thumb)
      originalFiles = toSeq(walkDir(store.publicFolder))
          .mapIt((extractFilename(it.path), readFile(it.path)))
      requested = %*[imageB["id"], imageA["id"], imageC["id"]]
    let reordered = store.reorder("recipe", requested)
    check reordered == %*[imageB, imageA, imageC]
    check store.metadata("recipe") == imageB
    check toSeq(walkDir(store.publicFolder))
        .mapIt((extractFilename(it.path), readFile(it.path))) == originalFiles

    let manifest = readFile(store.manifestPath("recipe"))
    for invalid in [
        %*[imageB["id"], imageA["id"]],
        %*[imageB["id"], imageB["id"], imageC["id"]],
        %*[imageB["id"], imageA["id"], repeat('f', 64)],
        %*[imageB["id"], imageA["id"], %1],
    ]:
      expect ImageOrderInvalid:
        discard store.reorder("recipe", invalid)
      check readFile(store.manifestPath("recipe")) == manifest

    let restarted = ImageStorage(root: testRoot)
    check restarted.collection("recipe") == reordered
    check restarted.reorder("recipe", requested) == reordered
    check readFile(store.manifestPath("recipe")) == manifest

    let originalPermissions = getFilePermissions(store.manifestFolder)
    setFilePermissions(store.manifestFolder, originalPermissions -
        {fpUserWrite, fpGroupWrite, fpOthersWrite})
    try:
      expect OSError, IOError:
        discard store.reorder("recipe",
            %*[imageA["id"], imageB["id"], imageC["id"]])
    finally:
      setFilePermissions(store.manifestFolder, originalPermissions)
    check readFile(store.manifestPath("recipe")) == manifest
    check store.collection("recipe") == reordered

    let staleOrder = %*[imageB["id"], imageA["id"], imageC["id"]]
    let d = outputs("#ffff00")
    discard restarted.publish("recipe", d.normal, d.thumb)
    let changedManifest = readFile(store.manifestPath("recipe"))
    expect ImageOrderInvalid:
      discard restarted.reorder("recipe", staleOrder)
    check readFile(store.manifestPath("recipe")) == changedManifest

    let emptyStore = ImageStorage(root: testRoot / "empty")
    emptyStore.initialize()
    check emptyStore.reorder("empty", newJArray()) == newJArray()
    expect ImageOrderInvalid:
      discard store.reorder("recipe", newJArray())

  test "default metadata reads validate only the first image's files":
    let
      a = outputs("#ff0000")
      b = outputs("#0000ff")
    let nonDefault = store.publish("recipe", a.normal, a.thumb)
    let default = store.publish("recipe", b.normal, b.thumb)
    writeFile(store.publicFolder / nonDefault.filename("url"), "corrupt")
    check store.metadata("recipe") == default
    expect StorageError:
      discard store.collection("recipe")

  test "ten-image limit applies after deduplication and before publication":
    let a = outputs("#ff0000")
    for index in 1..9:
      let generated = outputs("#" & toHex(index, 6))
      discard store.publish("recipe", generated.normal, generated.thumb)
    let atCapacity = store.publish("recipe", a.normal, a.thumb)
    check store.collection("recipe").len == maxImagesPerRecipe

    let replacement = outputs("#0000ff")
    let refreshed = store.publish("recipe", a.normal, replacement.thumb)
    check refreshed["id"] == atCapacity["id"]
    check store.collection("recipe").len == maxImagesPerRecipe
    check store.metadata("recipe") == refreshed

    let manifest = readFile(store.manifestPath("recipe"))
    let before = toSeq(walkDir(store.publicFolder))
        .mapIt(extractFilename(it.path)).sorted()
    let eleventh = outputs("#ffffff")
    expect ImageLimitReached:
      discard store.publish("recipe", eleventh.normal, eleventh.thumb)
    check readFile(store.manifestPath("recipe")) == manifest
    check toSeq(walkDir(store.publicFolder))
        .mapIt(extractFilename(it.path)).sorted() == before

  test "accepted recipe ids are escaped only in public URLs":
    let a = outputs("#ff0000")
    let id = "recipe #?+%:ümlaut"
    check validRecipeId(id)
    let published = store.publish(id, a.normal, a.thumb)
    check published["url"].getStr.startsWith(
        "/public/recipe%20%23%3F%2B%25%3A%C3%BCmlaut-")
    check parseImageName(published.filename("url")).recipeId == id
    check store.metadata(id) == published
    check store.deleteRecipe(id)

  test "existing 650x488 manifests remain readable and retained after replacement":
    let legacy = newImage(650, 488)
    legacy.fill(parseHtmlColor("#ff0000"))
    let bytes = legacy.encodeImage(PngFormat)
    let current = outputs("#0000ff")
    var metadata = store.publish("recipe", current.normal, current.thumb)
    let name = "recipe-" & outputHash(bytes) & ".png"
    writeFile(store.publicFolder / name, bytes)
    metadata["url"] = %("/public/" & name)
    metadata["width"] = %650
    metadata["height"] = %488
    metadata["size"] = %bytes.len
    metadata["id"] = %outputHash(bytes)
    writeFile(store.manifestPath("recipe"), "[" & $metadata & "]")
    check store.metadata("recipe") == metadata
    discard store.publish("recipe", current.normal, current.thumb)
    check store.metadata("recipe")["width"].getInt == 648
    check readFile(store.publicFolder / name) == bytes

  test "malformed or incorrectly sized output cannot replace a good publication":
    let a = outputs("#ff0000")
    let first = store.publish("recipe", a.normal, a.thumb)
    expect PixieError:
      discard store.publish("recipe", "not a PNG", a.thumb)
    expect StorageError:
      discard store.publish("recipe", a.thumb, a.thumb)
    check store.metadata("recipe") == first

  test "output failure preserves last complete publication and cleans siblings":
    let a = outputs("#ff0000")
    let b = outputs("#0000ff")
    let first = store.publish("recipe", a.normal, a.thumb)
    let blocked = store.publicFolder / ("recipe-" & outputHash(b.thumb) & "-thumb.png")
    createDir(blocked)
    expect OSError, IOError:
      discard store.publish("recipe", b.normal, b.thumb)
    check store.metadata("recipe") == first
    check readFile(store.publicFolder / first.filename("url")) == a.normal
    for kind, path in walkDir(store.publicFolder):
      check ".pending-" notin path
    for kind, path in walkDir(store.manifestFolder):
      check ".pending-" notin path

  test "manifest rename failure does not publish metadata or leave temporary files":
    let a = outputs("#ff0000")
    createDir(store.manifestPath("recipe"))
    expect StorageError:
      discard store.publish("recipe", a.normal, a.thumb)
    for kind, path in walkDir(store.manifestFolder):
      check ".pending-" notin path
    expect StorageError:
      discard store.metadata("recipe")

  test "malformed manifests and missing or corrupted output are storage errors":
    expect ImageNotFound:
      discard store.metadata("absent")
    for invalid in ["{", "{}", """{"recipeId":123}"""]:
      writeFile(store.manifestPath("recipe"), invalid)
      expect StorageError:
        discard store.metadata("recipe")
    writeFile(store.manifestPath("recipe"), "[]")
    expect ImageNotFound:
      discard store.metadata("recipe")
    let a = outputs("#ff0000")
    let first = store.publish("recipe", a.normal, a.thumb)
    var invalid = parseJson($first)
    invalid["thumbUrl"] = %"/public/../secret"
    writeFile(store.manifestPath("recipe"), "[" & $invalid & "]")
    expect StorageError:
      discard store.metadata("recipe")
    writeFile(store.manifestPath("recipe"), "[" & $first & "]")
    removeFile(store.publicFolder / first.filename("thumbUrl"))
    expect StorageError:
      discard store.metadata("recipe")
    expect StorageError:
      discard store.publish("recipe", a.normal, a.thumb)
    writeFile(store.publicFolder / first.filename("thumbUrl"), a.thumb)
    writeFile(store.publicFolder / first.filename("url"), "corrupt")
    expect StorageError:
      discard store.metadata("recipe")
    expect StorageError:
      discard store.publish("recipe", a.normal, a.thumb)

  test "exact recipe deletion includes retained and orphaned versions, wipe is complete":
    let a = outputs("#ff0000")
    let b = outputs("#0000ff")
    let id = repeat('r', 128)
    discard store.publish(id, a.normal, a.thumb)
    discard store.publish(id, b.normal, b.thumb)
    let similarlyPrefixed = store.publish(id[0 .. ^2], a.normal, a.thumb)
    let recipeThumb = store.publish("recipe-thumb", a.normal, a.thumb)
    let hashId = "recipe-" & repeat('a', 64)
    let hashLike = store.publish(hashId, a.normal, a.thumb)
    discard store.publish("recipe", a.normal, a.thumb)
    check store.deleteRecipe(id)
    check not store.deleteRecipe(id)
    for kind, path in walkDir(store.publicFolder):
      check parseImageName(extractFilename(path)).recipeId != id
    check store.metadata(id[0 .. ^2]) == similarlyPrefixed
    check store.deleteRecipe("recipe")
    check store.metadata("recipe-thumb") == recipeThumb
    check store.metadata(hashId) == hashLike
    check not store.deleteRecipe("../escape")
    removeFile(store.manifestPath(id[0 .. ^2]))
    check store.deleteRecipe(id[0 .. ^2])
    store.wipe()
    check dirExists(store.publicFolder)
    check dirExists(store.manifestFolder)
    check toSeq(walkDir(store.publicFolder)).len == 0
    check toSeq(walkDir(store.manifestFolder)).len == 0

  test "backup enumeration, orphan purge and image compaction fail closed":
    let a = outputs("#ff0000")
    let b = outputs("#0000ff")
    let c = outputs("#00ff00")
    let first = store.publish("recipe-a", a.normal, a.thumb)
    let superseded = store.publish("recipe-a", b.normal, b.thumb)
    let current = store.publish("recipe-a", a.normal, b.thumb)
    let removed = store.publish("recipe-a", c.normal, c.thumb)
    check current["thumbUrl"] == superseded["thumbUrl"]
    check store.deleteImage("recipe-a", removed["id"].getStr)
    check fileExists(store.publicFolder / removed.filename("url"))
    check fileExists(store.publicFolder / removed.filename("thumbUrl"))
    discard store.publish("recipe-b", b.normal, b.thumb)
    let orphan = store.publish("recipe-c", b.normal, b.thumb)
    writeFile(store.manifestPath("recipe-c"), "{")

    check store.recipeIds() == @["recipe-a", "recipe-b", "recipe-c"]
    store.compactRecipe("recipe-a")
    check store.metadata("recipe-a") == current
    check toSeq(walkDir(store.publicFolder))
        .mapIt(extractFilename(it.path)).len == 7
    check fileExists(store.publicFolder / first.filename("url"))
    check not fileExists(store.publicFolder / first.filename("thumbUrl"))
    check fileExists(store.publicFolder / superseded.filename("url"))
    check fileExists(store.publicFolder / superseded.filename("thumbUrl"))
    check not fileExists(store.publicFolder / removed.filename("url"))
    check not fileExists(store.publicFolder / removed.filename("thumbUrl"))

    store.purgeRecipeData("recipe-c")
    store.purgeRecipeData("recipe-c")
    check store.recipeIds() == @["recipe-a", "recipe-b"]
    check not fileExists(store.manifestPath("recipe-c"))
    check toSeq(walkDir(store.publicFolder))
        .mapIt(parseImageName(extractFilename(it.path)).recipeId)
        .allIt(it != "recipe-c")
    check store.metadata("recipe-b")["recipeId"].getStr == "recipe-b"
    discard orphan

    let historical = store.publish("recipe-a", b.normal, b.thumb)
    writeFile(store.manifestPath("recipe-a"), "{")
    let before = toSeq(walkDir(store.publicFolder))
        .mapIt(readFile(it.path))
    expect ImageStateInvalid:
      store.compactRecipe("recipe-a")
    check toSeq(walkDir(store.publicFolder)).mapIt(readFile(it.path)) == before

    writeFile(store.manifestPath("recipe-a"), "[" & $historical & "]")
    removeFile(store.publicFolder / historical.filename("thumbUrl"))
    expect ImageStateInvalid:
      store.compactRecipe("recipe-a")

    let orphanOutput = store.publish("recipe-d", a.normal, a.thumb)
    removeFile(store.manifestPath("recipe-d"))
    expect ImageStateInvalid:
      store.compactRecipe("recipe-d")
    store.purgeRecipeData("recipe-d")
    check not fileExists(store.publicFolder / orphanOutput.filename("url"))

    store.compactRecipe("absent")
    writeFile(store.publicFolder / "unknown.png", "unknown")
    expect StorageError:
      discard store.recipeIds()
