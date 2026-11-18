# Full lifecycle of a recipe image.

DELETE {{REST_API}}/images
HTTP 204

GET {{REST_API}}/images/no-image/meta/
HTTP 200
[Asserts]
jsonpath "$[0]" not exists

GET {{REST_API}}/images/no-image/meta/0
HTTP 404
[Asserts]
jsonpath "$.code" == "image-not-found"

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
image_id_a: jsonpath "$.id"
[Asserts]
header "Content-Type" contains "application/json"
header "Cache-Control" == "no-store"
jsonpath "$.recipeId" == "rice-pudding"
jsonpath "$.width" == 648
jsonpath "$.height" == 486
jsonpath "$.url" matches /^\/public\/rice-pudding-[0-9a-f]{64}\.png$/
jsonpath "$.thumbUrl" matches /^\/public\/rice-pudding-[0-9a-f]{64}-thumb\.png$/
jsonpath "$.id" matches /^[0-9a-f]{64}$/
jsonpath "$.id" == "{{normal_hash_a}}"

GET {{REST_API}}/images/rice-pudding/meta
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
header "Cache-Control" == "no-store"
jsonpath "$[0].recipeId" == "rice-pudding"
jsonpath "$[0].id" == "{{image_id_a}}"
jsonpath "$[0].width" == 648
jsonpath "$[0].height" == 486
jsonpath "$[0].size" isInteger
jsonpath "$[0].size" > 0
jsonpath "$[0].modified" matches /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}$/
jsonpath "$[0].url" == "{{normal_a}}"
jsonpath "$[0].thumbUrl" == "{{thumb_a}}"
jsonpath "$[0].size" == {{size_a}}
jsonpath "$[0].modified" == "{{modified_a}}"

GET {{REST_API}}/images/rice-pudding/meta/0/
HTTP 200
[Asserts]
jsonpath "$.id" == "{{image_id_a}}"
jsonpath "$.url" == "{{normal_a}}"

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
image_id_b: jsonpath "$.id"
[Asserts]
jsonpath "$.url" != "{{normal_a}}"
jsonpath "$.thumbUrl" != "{{thumb_a}}"

GET {{REST_API}}/images/rice-pudding/meta
HTTP 200
[Asserts]
jsonpath "$[0].id" == "{{image_id_b}}"
jsonpath "$[0].url" == "{{normal_b}}"
jsonpath "$[0].thumbUrl" == "{{thumb_b}}"
jsonpath "$[1].id" == "{{image_id_a}}"
jsonpath "$[1].url" == "{{normal_a}}"

GET {{REST_API}}/images/rice-pudding/meta/0
HTTP 200
[Asserts]
jsonpath "$.id" == "{{image_id_b}}"
jsonpath "$.url" == "{{normal_b}}"

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
jsonpath "$[0].url" == "{{normal_b}}"
jsonpath "$[0].thumbUrl" == "{{thumb_b}}"

# A -> B -> A returns to the original URLs.

POST {{REST_API}}/images/rice-pudding
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 201
[Asserts]
jsonpath "$.id" == "{{image_id_a}}"
jsonpath "$.url" == "{{normal_a}}"

GET {{REST_API}}/images/rice-pudding/meta
HTTP 200
[Asserts]
jsonpath "$[0].id" == "{{image_id_a}}"
jsonpath "$[0].url" == "{{normal_a}}"
jsonpath "$[1].id" == "{{image_id_b}}"

# A similarly prefixed recipe must survive deletion.

POST {{REST_API}}/images/rice-pudding-extra
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 201
[Captures]
neighbor: jsonpath "$.url"
neighbor_thumb: jsonpath "$.thumbUrl"

DELETE {{REST_API}}/images/rice-pudding/{{image_id_a}}/
HTTP 204

GET {{REST_API}}/images/rice-pudding/meta
HTTP 200
[Asserts]
jsonpath "$[0].id" == "{{image_id_b}}"

GET {{WEB_API}}{{normal_a}}
HTTP 200

DELETE {{REST_API}}/images/rice-pudding/{{image_id_b}}
HTTP 204

GET {{REST_API}}/images/rice-pudding/meta/
HTTP 200
[Asserts]
jsonpath "$[0]" not exists

DELETE {{REST_API}}/images/rice-pudding/{{image_id_a}}
HTTP 404
[Asserts]
jsonpath "$.code" == "image-not-found"

GET {{WEB_API}}{{normal_b}}
HTTP 200

DELETE {{REST_API}}/images/rice-pudding
HTTP 204

GET {{REST_API}}/images/rice-pudding/meta
HTTP 200
[Asserts]
jsonpath "$[0]" not exists

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
HTTP 200
[Asserts]
jsonpath "$[0]" not exists

GET {{REST_API}}/images/apple-pie/meta/0
HTTP 404

GET {{WEB_API}}{{wipe_normal}}
HTTP 404

GET {{WEB_API}}{{wipe_thumb}}
HTTP 404

GET {{REST_API}}/images/rice-pudding-extra/meta
HTTP 200
[Asserts]
jsonpath "$[0]" not exists

GET {{WEB_API}}{{neighbor}}
HTTP 404

GET {{WEB_API}}{{neighbor_thumb}}
HTTP 404
