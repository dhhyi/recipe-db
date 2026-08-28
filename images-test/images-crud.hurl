# Full lifecycle of a recipe image.

DELETE {{REST_API}}/images
HTTP 204

POST {{REST_API}}/images/rice-pudding
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 201

GET {{REST_API}}/images/rice-pudding/meta
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.recipeId" == "rice-pudding"
jsonpath "$.width" == 800
jsonpath "$.height" == 450
jsonpath "$.size" isInteger
jsonpath "$.size" > 0
jsonpath "$.modified" matches /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}$/
jsonpath "$.url" == "/public/rice-pudding.png"
jsonpath "$.thumbUrl" == "/public/rice-pudding-thumb.png"

# The stored files are delivered on the public entrypoint.

GET {{WEB_API}}/public/rice-pudding.png
HTTP 200
Content-Type: image/png
[Asserts]
bytes startsWith hex,89504e470d0a1a0a;

GET {{WEB_API}}/public/rice-pudding-thumb.png
HTTP 200
[Asserts]
bytes startsWith hex,89504e470d0a1a0a;

# Uploading again replaces both files.

POST {{REST_API}}/images/rice-pudding
Content-Type: image/png
file,fixtures/portrait.png;
HTTP 201

GET {{REST_API}}/images/rice-pudding/meta
HTTP 200
[Asserts]
jsonpath "$.width" == 480
jsonpath "$.height" == 640

DELETE {{REST_API}}/images/rice-pudding
HTTP 204

GET {{REST_API}}/images/rice-pudding/meta
HTTP 404

GET {{WEB_API}}/public/rice-pudding.png
HTTP 404

GET {{WEB_API}}/public/rice-pudding-thumb.png
HTTP 404

DELETE {{REST_API}}/images/rice-pudding
HTTP 404

# The testing wipe also answers on the trailing slash form used by the API gateway.

POST {{REST_API}}/images/apple-pie
Content-Type: image/jpeg
file,fixtures/landscape.jpg;
HTTP 201

DELETE {{REST_API}}/images/
HTTP 204

GET {{REST_API}}/images/apple-pie/meta
HTTP 404
