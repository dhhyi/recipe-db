import std/[json, os, sequtils, strutils, times, unittest, uri]
import pixie
import ../storage

const testRoot = "tests/storage-test-data"

proc outputs(color: string): tuple[normal, thumb: string] =
  let normal = newImage(650, 488)
  normal.fill(parseHtmlColor(color))
  let thumb = newImage(300, 225)
  thumb.fill(parseHtmlColor(color))
  (normal.encodeImage(PngFormat), thumb.encodeImage(PngFormat))

proc filename(metadata: JsonNode, key: string): string =
  decodeUrl(metadata[key].getStr[8 .. ^1], decodePlus = false)

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
    check first["width"].getInt == 650
    check first["height"].getInt == 488
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
    expect OSError, IOError:
      discard store.publish("recipe", a.normal, a.thumb)
    for kind, path in walkDir(store.manifestFolder):
      check ".pending-" notin path
    expect StorageError:
      discard store.metadata("recipe")

  test "malformed manifests and missing or corrupted output are storage errors":
    expect ImageNotFound:
      discard store.metadata("absent")
    for invalid in ["{", "[]", "{}", """{"recipeId":123}"""]:
      writeFile(store.manifestPath("recipe"), invalid)
      expect StorageError:
        discard store.metadata("recipe")
    let a = outputs("#ff0000")
    let first = store.publish("recipe", a.normal, a.thumb)
    var invalid = parseJson($first)
    invalid["thumbUrl"] = %"/public/../secret"
    writeFile(store.manifestPath("recipe"), $invalid)
    expect StorageError:
      discard store.metadata("recipe")
    writeFile(store.manifestPath("recipe"), $first)
    removeFile(store.publicFolder / first.filename("thumbUrl"))
    expect StorageError:
      discard store.metadata("recipe")
    discard store.publish("recipe", a.normal, a.thumb)
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
