import std/[strutils, unittest]
import pixie
import ../processing

proc exifData(orientation: int, little: bool): string =
  let tiff = if little:
    "II\x2A\0\x08\0\0\0\x01\0\x12\x01\x03\0\x01\0\0\0" &
        char(orientation) & "\0\0\0\0\0\0\0"
  else:
    "MM\0\x2A\0\0\0\x08\0\x01\x01\x12\0\x03\0\0\0\x01\0" &
        char(orientation) & "\0\0\0\0\0\0"
  "Exif\0\0" & tiff

proc withExif(jpeg: string, orientation: int, little: bool): string =
  let exif = exifData(orientation, little)
  jpeg[0 .. 1] & "\xFF\xE1" & char((exif.len + 2) shr 8) &
      char((exif.len + 2) and 255) & exif & jpeg[2 .. ^1]

proc bigEndian(value: uint32): string =
  for shift in [24, 16, 8, 0]:
    result.add(char((value shr shift) and 255))

proc withPngExif(png: string, orientation: int, little: bool): string =
  let payload = "eXIf" & exifData(orientation, little)[6 .. ^1]
  var crc = 0xFFFFFFFF.uint32
  for c in payload:
    crc = crc xor uint32(ord(c))
    for bit in 0 ..< 8:
      crc = (crc shr 1) xor (if (crc and 1) !=
          0: 0xEDB88320.uint32 else: 0.uint32)
  # Insert after IHDR, before IDAT.
  png[0 ..< 33] & bigEndian(uint32(payload.len - 4)) & payload &
      bigEndian(not crc) & png[33 .. ^1]

suite "oriented image processing":
  test "all EXIF orientations, both TIFF byte orders, match visual source coordinates":
    let jpeg = readFile("../images-test/fixtures/landscape.jpg")
    for png in [false, true]:
      let bytes = if png: decodeImage(jpeg).encodeImage(PngFormat) else: jpeg
      let decoded = decodeImage(bytes)
      let w = decoded.width
      let h = decoded.height
      check decoded[0, 0] != decoded[w - 1, h - 1]
      for little in [false, true]:
        for orientation in 1 .. 8:
          let fixture = if png: withPngExif(bytes, orientation, little)
            else: withExif(bytes, orientation, little)
          let actual = orientedSource(fixture, 40_000_000)
          check actual.width == (if orientation < 5: w else: h)
          check actual.height == (if orientation < 5: h else: w)
          for y in 0 ..< decoded.height:
            for x in 0 ..< decoded.width:
              let position = case orientation
                of 2: (w - 1 - x, y)
                of 3: (w - 1 - x, h - 1 - y)
                of 4: (x, h - 1 - y)
                of 5: (y, x)
                of 6: (h - 1 - y, x)
                of 7: (h - 1 - y, w - 1 - x)
                of 8: (y, w - 1 - x)
                else: (x, y)
              check actual[position[0], position[1]] == decoded[x, y]

  test "pixel limit is checked before decoding and without multiplication overflow":
    let source = newImage(40, 30).encodeImage(PngFormat)
    expect CropError:
      discard orientedSource(source, 1199)
    check orientedSource(source, 1200).width == 40

  test "strict integer parsing and complete tuple":
    for query in ["cropX=0", "cropX=", "cropX=-1", "cropX=%2B1",
        "cropX=1.0", "cropX=1e2", "cropX=%201", "cropX=1&cropX=2",
        "cropX=" & repeat('9', 100)]:
      expect CropError:
        discard parseCrop(query)
    check not parseCrop("").supplied
    check not parseCrop("unrelated=value").supplied
    let crop = parseCrop("cropX=0&cropY=0&cropWidth=300&cropHeight=225")
    crop.validateCrop(300, 225)

  test "small legacy sources, including single pixels, remain accepted":
    for dimensions in [(1, 1), (1, 20), (20, 1), (70, 40)]:
      let cropped = newImage(dimensions[0], dimensions[1]).selectedSource(Crop())
      check cropped.width > 0
      check cropped.height > 0

  test "PNG alpha survives decoding, selection and independent resizing":
    let image = newImage(600, 450)
    image.fill(color(0, 1, 0, 0.5))
    let source = orientedSource(image.encodeImage(PngFormat), 40_000_000)
    let cropped = source.selectedSource(parseCrop(
        "cropX=300&cropY=225&cropWidth=300&cropHeight=225"))
    for dimensions in [(648, 486), (300, 225)]:
      let output = decodeImage(cropped.resize(dimensions[0],
          dimensions[1]).encodeImage(PngFormat))
      check output[dimensions[0] div 2, dimensions[1] div 2].a in 127.uint8 .. 128.uint8
