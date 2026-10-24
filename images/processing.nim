import std/[strutils, uri]
import pixie

type
  Crop* = object
    supplied*: bool
    x*, y*, width*, height*: int
  CropError* = object of CatchableError
    code*, field*: string

proc invalid(code, detail: string, field = "") =
  var error = newException(CropError, detail)
  error.code = code
  error.field = field
  raise error

proc parseCrop*(query: string): Crop =
  const names = ["cropX", "cropY", "cropWidth", "cropHeight"]
  var
    seen: array[4, bool]
    values: array[4, int]
    count = 0
  for key, value in decodeQuery(query):
    let index = names.find(key)
    if index < 0:
      continue
    if seen[index]:
      invalid("invalid-crop", "Crop parameters must occur once", key)
    seen[index] = true
    inc count
    if value.len == 0:
      invalid("invalid-crop", "Crop parameters must be integers", key)
    # Decimal digits only: no signs, whitespace, exponent, fractions or overflow.
    for c in value:
      if c notin {'0'..'9'}:
        invalid("invalid-crop", "Crop parameters must be nonnegative integers", key)
      let digit = ord(c) - ord('0')
      if values[index] > (int.high - digit) div 10:
        invalid("invalid-crop", "Crop parameter is too large", key)
      values[index] = values[index] * 10 + digit
  if count == 0:
    return
  if count != 4:
    for i, name in names:
      if not seen[i]:
        invalid("invalid-crop", "All four crop parameters are required", name)
  result = Crop(supplied: true, x: values[0], y: values[1],
      width: values[2], height: values[3])
  if result.width == 0:
    invalid("invalid-crop", "Crop width must be positive", "cropWidth")
  if result.height == 0:
    invalid("invalid-crop", "Crop height must be positive", "cropHeight")

proc validateCrop*(crop: Crop, width, height: int) =
  if crop.x > width or crop.y > height or
      crop.width > width - crop.x or crop.height > height - crop.y:
    invalid("crop-out-of-bounds", "Crop must be within the oriented source image")
  # Division avoids overflowing cross-products, even for hostile integer input.
  if crop.width mod 4 != 0 or crop.height mod 3 != 0 or
      crop.width div 4 != crop.height div 3:
    invalid("invalid-crop-aspect-ratio", "Crop must have an exact 4:3 aspect ratio")
  if crop.width < 300 or crop.height < 225:
    invalid("crop-too-small", "Crop must be at least 300x225 source pixels")

proc exifOrientation(data: string): int =
  result = 1
  if data.len < 14 or not data.startsWith("Exif\0\0"):
    return
  let little = data[6 .. 7] == "II"
  if not little and data[6 .. 7] != "MM":
    return
  proc number(offset, size: int): uint32 =
    for i in 0 ..< size:
      let index = if little: offset + size - 1 - i else: offset + i
      result = (result shl 8) or uint32(ord(data[index]))
  if number(8, 2) != 42:
    return
  let offset = number(10, 4).uint64 + 6
  if offset > uint64(data.len - 2):
    return
  let start = offset.int
  let entries = number(start, 2).int
  if entries > (data.len - start - 2) div 12:
    return
  for i in 0 ..< entries:
    let entry = start + 2 + i * 12
    if number(entry, 2) == 0x112 and number(entry + 2, 2) == 3 and
        number(entry + 4, 4) == 1:
      let value = number(entry + 8, 2).int
      if value in 1 .. 8:
        return value

proc orientedSource*(body: string, maxPixels: int): Image =
  var
    bytes = body
    orientation = 1
  if body.startsWith("\xFF\xD8"):
    # Pixie applies JPEG EXIF itself, but reads little-endian inline SHORTs
    # incorrectly. Remove EXIF before decoding and normalize exactly once here.
    bytes = body[0 .. 1]
    var position = 2
    while position < body.len:
      let start = position
      if body[position] != '\xFF':
        raise newException(PixieError, "Invalid JPEG marker")
      while position < body.len and body[position] == '\xFF':
        inc position
      if position >= body.len:
        raise newException(PixieError, "Truncated JPEG marker")
      let marker = ord(body[position])
      inc position
      if marker in [0xDA, 0xD9]:
        bytes.add(body[start .. ^1])
        break
      if marker == 0x01 or marker in 0xD0 .. 0xD7:
        bytes.add(body[start ..< position])
        continue
      if position + 2 > body.len:
        raise newException(PixieError, "Truncated JPEG segment")
      let length = ord(body[position]) * 256 + ord(body[position + 1])
      if length < 2 or length > body.len - position:
        raise newException(PixieError, "Invalid JPEG segment length")
      let finish = position + length
      let payload = body[position + 2 ..< finish]
      if marker == 0xE1 and payload.startsWith("Exif\0\0"):
        orientation = exifOrientation(payload)
      else:
        bytes.add(body[start ..< finish])
      position = finish
  elif body.startsWith("\x89PNG\r\n\x1A\n"):
    # Pixie ignores PNG eXIf chunks; browsers honor the same TIFF orientation.
    var position = 8
    while position <= body.len - 12:
      var length = 0.uint64
      for i in 0 ..< 4:
        length = (length shl 8) or uint64(ord(body[position + i]))
      if length > uint64(body.len - position - 12):
        raise newException(PixieError, "Invalid PNG chunk length")
      if body[position + 4 .. position + 7] == "eXIf":
        orientation = exifOrientation("Exif\0\0" &
            body[position + 8 ..< position + 8 + length.int])
      position += length.int + 12
  let dimensions = decodeImageDimensions(bytes)
  if dimensions.width <= 0 or dimensions.height <= 0 or
      dimensions.width > maxPixels div dimensions.height:
    invalid("image-too-large", "Image exceeds the maximum of " & $maxPixels & " pixels")
  result = decodeImage(bytes)
  case orientation
  of 2: result.flipHorizontal()
  of 3:
    result.flipVertical()
    result.flipHorizontal()
  of 4: result.flipVertical()
  of 5:
    result.rotate90()
    result.flipHorizontal()
  of 6: result.rotate90()
  of 7:
    result.rotate90()
    result.flipVertical()
  of 8:
    result.rotate90()
    result.flipVertical()
    result.flipHorizontal()
  else: discard

proc selectedSource*(image: Image, crop: Crop): Image =
  if crop.supplied:
    crop.validateCrop(image.width, image.height)
    return image.subImage(crop.x, crop.y, crop.width, crop.height)
  # Preserve small legacy uploads, including sources narrower than four pixels.
  let
    width = max(1, min(image.width, int(image.height.float * 4 / 3 + 0.5)))
    height = max(1, min(image.height, int(image.width.float * 3 / 4 + 0.5)))
  image.subImage((image.width - width) div 2, (image.height - height) div 2,
      width, height)
