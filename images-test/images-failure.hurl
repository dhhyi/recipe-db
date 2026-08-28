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

DELETE {{REST_API}}/images/unknown
HTTP 404

GET {{WEB_API}}/public/unknown.png
HTTP 404
