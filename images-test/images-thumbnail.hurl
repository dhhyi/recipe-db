# The uploaded image is normalized to 4:3 and stored at 650x488, while the
# thumbnail is scaled to 300x225.
#
# Dimensions are asserted on the raw PNG bytes: the 8 byte signature is followed
# by the IHDR chunk, whose payload starts with width and height as 32 bit big
# endian integers.

DELETE {{REST_API}}/images
HTTP 204

# 800x450 is wider than 4:3, so the width is cropped.

POST {{REST_API}}/images/landscape
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 201

GET {{WEB_API}}/public/landscape.png
HTTP 200
[Asserts]
bytes contains hex,494844520000028a000001e8;

GET {{WEB_API}}/public/landscape-thumb.png
HTTP 200
[Asserts]
bytes contains hex,494844520000012c000000e1;

# 480x640 is taller than 4:3, so the height is cropped.

POST {{REST_API}}/images/portrait
Content-Type: image/png
file,fixtures/portrait.png;
HTTP 201

GET {{WEB_API}}/public/portrait.png
HTTP 200
[Asserts]
bytes contains hex,494844520000028a000001e8;

GET {{WEB_API}}/public/portrait-thumb.png
HTTP 200
[Asserts]
bytes contains hex,494844520000012c000000e1;

DELETE {{REST_API}}/images
HTTP 204
