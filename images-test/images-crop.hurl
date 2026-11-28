DELETE {{REST_API}}/images
HTTP 204

# Explicit source-pixel coordinates, with upscaling allowed above 300x225.
POST {{REST_API}}/images/cropped?cropX=400&cropY=150&cropWidth=400&cropHeight=300
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 201
[Captures]
saved: jsonpath "$"
normal: jsonpath "$.url"
thumb: jsonpath "$.thumbUrl"
[Asserts]
jsonpath "$.width" == 648
jsonpath "$.height" == 486

GET {{WEB_API}}{{normal}}
HTTP 200
[Asserts]
bytes contains hex,4948445200000288000001e6;

GET {{WEB_API}}{{thumb}}
HTTP 200
[Asserts]
bytes contains hex,494844520000012c000000e1;

POST {{REST_API}}/images/cropped?cropX=0
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 400
Content-Type: application/problem+json
Cache-Control: no-store
[Asserts]
jsonpath "$.type" == "about:blank"
jsonpath "$.title" isString
jsonpath "$.status" == 400
jsonpath "$.detail" isString
jsonpath "$.code" == "invalid-crop"
jsonpath "$.field" == "cropY"

GET {{REST_API}}/images/cropped/meta
HTTP 200
[Asserts]
jsonpath "$[0]" == {{saved}}
jsonpath "$[1]" not exists

POST {{REST_API}}/images/cropped?cropX=0&cropY=0&cropWidth=400&cropHeight=299
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 400
Content-Type: application/problem+json
Cache-Control: no-store
[Asserts]
jsonpath "$.type" == "about:blank"
jsonpath "$.title" isString
jsonpath "$.status" == 400
jsonpath "$.detail" isString
jsonpath "$.code" == "invalid-crop-aspect-ratio"
jsonpath "$.field" not exists

GET {{REST_API}}/images/cropped/meta
HTTP 200
[Asserts]
jsonpath "$[0]" == {{saved}}
jsonpath "$[1]" not exists

POST {{REST_API}}/images/cropped?cropX=0&cropY=0&cropWidth=301&cropHeight=225
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 400
Content-Type: application/problem+json
Cache-Control: no-store
[Asserts]
jsonpath "$.type" == "about:blank"
jsonpath "$.title" isString
jsonpath "$.status" == 400
jsonpath "$.detail" isString
jsonpath "$.code" == "invalid-crop-aspect-ratio"
jsonpath "$.field" not exists

GET {{REST_API}}/images/cropped/meta
HTTP 200
[Asserts]
jsonpath "$[0]" == {{saved}}
jsonpath "$[1]" not exists

POST {{REST_API}}/images/cropped?cropX=0&cropY=0&cropWidth=296&cropHeight=222
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 400
Content-Type: application/problem+json
Cache-Control: no-store
[Asserts]
jsonpath "$.type" == "about:blank"
jsonpath "$.title" isString
jsonpath "$.status" == 400
jsonpath "$.detail" isString
jsonpath "$.code" == "crop-too-small"
jsonpath "$.field" not exists

GET {{REST_API}}/images/cropped/meta
HTTP 200
[Asserts]
jsonpath "$[0]" == {{saved}}
jsonpath "$[1]" not exists

POST {{REST_API}}/images/cropped?cropX=401&cropY=150&cropWidth=400&cropHeight=300
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 400
Content-Type: application/problem+json
Cache-Control: no-store
[Asserts]
jsonpath "$.type" == "about:blank"
jsonpath "$.title" isString
jsonpath "$.status" == 400
jsonpath "$.detail" isString
jsonpath "$.code" == "crop-out-of-bounds"
jsonpath "$.field" not exists

GET {{REST_API}}/images/cropped/meta
HTTP 200
[Asserts]
jsonpath "$[0]" == {{saved}}
jsonpath "$[1]" not exists

DELETE {{REST_API}}/images
HTTP 204
