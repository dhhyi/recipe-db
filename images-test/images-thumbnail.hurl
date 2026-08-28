# The thumbnail is a centered 4:3 crop scaled to 600x450.
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
bytes startsWith hex,89504e470d0a1a0a0000000d4948445200000320000001c2;

GET {{WEB_API}}/public/landscape-thumb.png
HTTP 200
[Asserts]
bytes startsWith hex,89504e470d0a1a0a0000000d4948445200000258000001c2;

# 480x640 is taller than 4:3, so the height is cropped.

POST {{REST_API}}/images/portrait
Content-Type: image/png
file,fixtures/portrait.png;
HTTP 201

GET {{WEB_API}}/public/portrait.png
HTTP 200
[Asserts]
bytes startsWith hex,89504e470d0a1a0a0000000d49484452000001e000000280;

GET {{WEB_API}}/public/portrait-thumb.png
HTTP 200
[Asserts]
bytes startsWith hex,89504e470d0a1a0a0000000d4948445200000258000001c2;

DELETE {{REST_API}}/images
HTTP 204
