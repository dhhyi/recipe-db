# Full lifecycle of a recipe image.

DELETE {{REST_API}}/images
HTTP 204

POST {{REST_API}}/images/rice-pudding
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 201
[Captures]
normal_a: jsonpath "$.url"
thumb_a: jsonpath "$.thumbUrl"
normal_hash_a: jsonpath "$.url" regex /-([0-9a-f]{64})\.png$/
thumb_hash_a: jsonpath "$.thumbUrl" regex /-([0-9a-f]{64})-thumb\.png$/
size_a: jsonpath "$.size"
modified_a: jsonpath "$.modified"
[Asserts]
header "Content-Type" contains "application/json"
header "Cache-Control" == "no-store"
jsonpath "$.recipeId" == "rice-pudding"
jsonpath "$.width" == 650
jsonpath "$.height" == 488
jsonpath "$.url" matches /^\/public\/rice-pudding-[0-9a-f]{64}\.png$/
jsonpath "$.thumbUrl" matches /^\/public\/rice-pudding-[0-9a-f]{64}-thumb\.png$/

GET {{REST_API}}/images/rice-pudding/meta
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
header "Cache-Control" == "no-store"
jsonpath "$.recipeId" == "rice-pudding"
jsonpath "$.width" == 650
jsonpath "$.height" == 488
jsonpath "$.size" isInteger
jsonpath "$.size" > 0
jsonpath "$.modified" matches /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}$/
jsonpath "$.url" == "{{normal_a}}"
jsonpath "$.thumbUrl" == "{{thumb_a}}"
jsonpath "$.size" == {{size_a}}
jsonpath "$.modified" == "{{modified_a}}"

# The stored files are delivered on the public entrypoint.

GET {{WEB_API}}{{normal_a}}
HTTP 200
Content-Type: image/png
[Captures]
etag_a: header "ETag"
[Asserts]
header "Cache-Control" == "public, max-age=31536000, immutable"
header "Content-Length" toInt == {{size_a}}
sha256 toHex == "{{normal_hash_a}}"
bytes startsWith hex,89504e470d0a1a0a;

GET {{WEB_API}}{{thumb_a}}
HTTP 200
[Asserts]
header "Cache-Control" == "public, max-age=31536000, immutable"
sha256 toHex == "{{thumb_hash_a}}"
bytes startsWith hex,89504e470d0a1a0a;

GET {{WEB_API}}{{normal_a}}
If-None-Match: {{etag_a}}
HTTP 304
[Asserts]
header "Cache-Control" == "public, max-age=31536000, immutable"

GET {{WEB_API}}{{normal_a}}.pending-1
HTTP 404
[Asserts]
header "Cache-Control" not contains "immutable"

GET {{WEB_API}}/public/rice-pudding.json
HTTP 404

# Identical output keeps both URLs.

POST {{REST_API}}/images/rice-pudding
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 201
[Asserts]
jsonpath "$.url" == "{{normal_a}}"
jsonpath "$.thumbUrl" == "{{thumb_a}}"

# A different image publishes a new pair without changing the previous bytes.

POST {{REST_API}}/images/rice-pudding
Content-Type: image/png
file,fixtures/portrait.png;
HTTP 201
[Captures]
normal_b: jsonpath "$.url"
thumb_b: jsonpath "$.thumbUrl"
normal_hash_b: jsonpath "$.url" regex /-([0-9a-f]{64})\.png$/
thumb_hash_b: jsonpath "$.thumbUrl" regex /-([0-9a-f]{64})-thumb\.png$/
[Asserts]
jsonpath "$.url" != "{{normal_a}}"
jsonpath "$.thumbUrl" != "{{thumb_a}}"

GET {{REST_API}}/images/rice-pudding/meta
HTTP 200
[Asserts]
jsonpath "$.width" == 650
jsonpath "$.height" == 488
jsonpath "$.url" == "{{normal_b}}"
jsonpath "$.thumbUrl" == "{{thumb_b}}"

GET {{WEB_API}}{{normal_b}}
HTTP 200
[Asserts]
sha256 toHex == "{{normal_hash_b}}"

GET {{WEB_API}}{{thumb_b}}
HTTP 200
[Asserts]
sha256 toHex == "{{thumb_hash_b}}"

GET {{WEB_API}}{{normal_a}}
HTTP 200
[Asserts]
sha256 toHex == "{{normal_hash_a}}"
header "ETag" == "{{etag_a}}"

GET {{WEB_API}}{{thumb_a}}
HTTP 200
[Asserts]
sha256 toHex == "{{thumb_hash_a}}"

# Invalid replacements leave the current pair untouched.

POST {{REST_API}}/images/rice-pudding
Content-Type: image/png
hex,89504e470d0a1a0a;
HTTP 400

GET {{REST_API}}/images/rice-pudding/meta
HTTP 200
[Asserts]
jsonpath "$.url" == "{{normal_b}}"
jsonpath "$.thumbUrl" == "{{thumb_b}}"

# A -> B -> A returns to the original URLs.

POST {{REST_API}}/images/rice-pudding
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 201
[Asserts]
jsonpath "$.url" == "{{normal_a}}"
jsonpath "$.thumbUrl" == "{{thumb_a}}"

# A similarly prefixed recipe must survive deletion.

POST {{REST_API}}/images/rice-pudding-extra
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 201
[Captures]
neighbor: jsonpath "$.url"
neighbor_thumb: jsonpath "$.thumbUrl"

DELETE {{REST_API}}/images/rice-pudding
HTTP 204

GET {{REST_API}}/images/rice-pudding/meta
HTTP 404
[Asserts]
header "Cache-Control" == "no-store"

GET {{WEB_API}}{{normal_a}}
HTTP 404
[Asserts]
header "Cache-Control" not contains "immutable"

GET {{WEB_API}}{{thumb_a}}
HTTP 404

GET {{WEB_API}}{{normal_b}}
HTTP 404

GET {{WEB_API}}{{thumb_b}}
HTTP 404

DELETE {{REST_API}}/images/rice-pudding
HTTP 404

GET {{REST_API}}/images/rice-pudding-extra/meta
HTTP 200

GET {{WEB_API}}{{neighbor}}
HTTP 200

GET {{WEB_API}}{{neighbor_thumb}}
HTTP 200

# The testing wipe also answers on the trailing slash form used by the API gateway.

POST {{REST_API}}/images/apple-pie
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 201
[Captures]
wipe_normal: jsonpath "$.url"
wipe_thumb: jsonpath "$.thumbUrl"

DELETE {{REST_API}}/images/
HTTP 204

GET {{REST_API}}/images/apple-pie/meta
HTTP 404

GET {{WEB_API}}{{wipe_normal}}
HTTP 404

GET {{WEB_API}}{{wipe_thumb}}
HTTP 404

GET {{REST_API}}/images/rice-pudding-extra/meta
HTTP 404

GET {{WEB_API}}{{neighbor}}
HTTP 404

GET {{WEB_API}}{{neighbor_thumb}}
HTTP 404
