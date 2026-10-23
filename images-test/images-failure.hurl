# Rejected uploads and lookups of images that do not exist.

DELETE {{REST_API}}/images
HTTP 204

# Unsupported content type.

POST {{REST_API}}/images/broken
Content-Type: image/tiff
`II*`
HTTP 400

# Content type that does not match the payload.

POST {{REST_API}}/images/broken
Content-Type: image/png
file,fixtures/landscape.jpg;
HTTP 400

# Not an image at all.

POST {{REST_API}}/images/broken
Content-Type: image/png
`not an image`
HTTP 400

# Missing content type.

POST {{REST_API}}/images/broken
`not an image`
HTTP 400

# None of the rejected uploads stored anything.

GET {{REST_API}}/images/broken/meta
HTTP 404

GET {{REST_API}}/images/unknown/meta
HTTP 404
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.type" == "about:blank"
jsonpath "$.status" == 404
jsonpath "$.code" == "image-not-found"

DELETE {{REST_API}}/images/unknown
HTTP 404

GET {{WEB_API}}/public/unknown.png
HTTP 404
[Asserts]
header "Cache-Control" not contains "immutable"

# Manifests, temporary files and legacy names are never public.

GET {{WEB_API}}/public/unknown.json
HTTP 404

GET {{WEB_API}}/public/unknown.tmp
HTTP 404

GET {{WEB_API}}/public/unknown-thumb.png
HTTP 404

GET {{WEB_API}}/public/%2e%2e%5cmanifests%5cunknown.json
HTTP 404

POST {{REST_API}}/images/invalid..id
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 400
[Asserts]
jsonpath "$.code" == "invalid-recipe-id"

# The recipe ID limit applies to the ID, not its longer generated filenames.

POST {{REST_API}}/images/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 201
[Captures]
long_normal: jsonpath "$.url"
long_thumb: jsonpath "$.thumbUrl"
[Asserts]
jsonpath "$.url" matches /^\/public\/a{128}-[0-9a-f]{64}\.png$/
jsonpath "$.thumbUrl" matches /^\/public\/a{128}-[0-9a-f]{64}-thumb\.png$/

GET {{WEB_API}}{{long_normal}}
HTTP 200

GET {{WEB_API}}{{long_thumb}}
HTTP 200

DELETE {{REST_API}}/images/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HTTP 204

GET {{WEB_API}}{{long_normal}}
HTTP 404

GET {{WEB_API}}{{long_thumb}}
HTTP 404
