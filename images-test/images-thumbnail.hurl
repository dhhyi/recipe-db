# The uploaded image is normalized to 4:3 and stored at 648x486, while the
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
[Captures]
normal: jsonpath "$.url"
thumb: jsonpath "$.thumbUrl"

GET {{WEB_API}}{{normal}}
HTTP 200
[Asserts]
bytes contains hex,4948445200000288000001e6;

GET {{WEB_API}}{{thumb}}
HTTP 200
[Asserts]
bytes contains hex,494844520000012c000000e1;

# 480x640 is taller than 4:3, so the height is cropped.

POST {{REST_API}}/images/portrait
Content-Type: image/png
file,fixtures/portrait.png;
HTTP 201
[Captures]
normal: jsonpath "$.url"
thumb: jsonpath "$.thumbUrl"

GET {{WEB_API}}{{normal}}
HTTP 200
[Asserts]
bytes contains hex,4948445200000288000001e6;

GET {{WEB_API}}{{thumb}}
HTTP 200
[Asserts]
bytes contains hex,494844520000012c000000e1;

DELETE {{REST_API}}/images
HTTP 204
