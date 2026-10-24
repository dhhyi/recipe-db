Feature: images

  Background:
    * def graphqlApi = java.lang.System.getenv('GRAPHQL_API')
    * def webApi = java.lang.System.getenv('WEB_API') || graphqlApi
    * url graphqlApi
    * request { query: '#(read("graphql/delete-recipes-for-testing.graphql"))' }
    * method post
    * status 200
    * request { query: '#(read("graphql/delete-images-for-testing.graphql"))' }
    * method post
    * status 200

  Scenario: recipe should have no image before one is uploaded
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'test' } } }
    * method post
    * status 200
    * def recipeId = response.data.createRecipe.id
    * match recipeId == '#present'

    * request { query: '#(read("graphql/recipe-image-by-id.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data == { recipe: { image: null } }

  Scenario: should be able to upload an image for a recipe
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'test' } } }
    * method post
    * status 200
    * def recipeId = response.data.createRecipe.id
    * match recipeId == '#present'

    # the GraphQL multipart request spec requires a `null` placeholder for every Upload variable
    # the "map" part then overwrites - see graphql/src/images.rs for the server-side counterpart
    * def operations =
      """
      {
        "query": "mutation($id: ID!, $file: Upload!) { setImage(recipeId: $id, file: $file) { url thumbUrl width height size } }",
        "variables": { "id": "#(recipeId)", "file": null }
      }
      """
    * multipart field operations = operations
    * multipart field map = '{"0":["variables.file"]}'
    * multipart file 0 = { read: 'fixtures/test.jpg', filename: 'test.jpg', contentType: 'image/jpeg' }
    * method post
    * status 200
    * match response.errors == '#notpresent'
    * def uploaded = response.data.setImage
    * match uploaded == { url: '#string', thumbUrl: '#string', width: '#number', height: '#number', size: '#number' }
    * match uploaded.width == 648
    * match uploaded.height == 486
    * match uploaded.size == '#? _ > 0'
    * match uploaded.url == '#regex /public/.+-[0-9a-f]{64}[.]png'
    * match uploaded.thumbUrl == '#regex /public/.+-[0-9a-f]{64}-thumb[.]png'

    * request { query: '#(read("graphql/recipe-image-by-id.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data.recipe.image == uploaded

    * url java.net.URI.create(webApi).resolve(uploaded.url).toString()
    * method get
    * status 200
    * match header Content-Type contains 'image/png'
    * assert responseBytes.length == uploaded.size

    * url java.net.URI.create(webApi).resolve(uploaded.thumbUrl).toString()
    * method get
    * status 200
    * match header Content-Type contains 'image/png'
    * assert responseBytes.length > 0

  Scenario Outline: crop validation errors preserve backend extensions
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'invalid crop' } } }
    * method post
    * status 200
    * def recipeId = response.data.createRecipe.id
    * def operations =
      """
      {
        "query": "mutation($id: ID!, $file: Upload!, $crop: ImageCropInput) { setImage(recipeId: $id, file: $file, crop: $crop) { url } }",
        "variables": { "id": "#(recipeId)", "file": null, "crop": { "x": <x>, "y": 0, "width": <width>, "height": <height> } }
      }
      """
    * multipart field operations = operations
    * multipart field map = '{"0":["variables.file"]}'
    * multipart file 0 = { read: 'fixtures/test.jpg', filename: 'test.jpg', contentType: 'image/jpeg' }
    * method post
    * status 200
    * match response.data == null
    * match response.errors == '#[1]'
    * match response.errors[0].message == '#string'
    * match response.errors[0].extensions == <extensions>

    Examples:
      | x   | width | height | extensions                                            |
      | -1  | 400   | 300    | { code: 'invalid-crop', status: 400, field: 'cropX' } |
      | 0   | 400   | 301    | { code: 'invalid-crop-aspect-ratio', status: 400 }    |
      | 0   | 296   | 222    | { code: 'crop-too-small', status: 400 }               |
      | 401 | 400   | 300    | { code: 'crop-out-of-bounds', status: 400 }           |

  Scenario: explicit crops change the saved composition and failed crops preserve metadata
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'crop test' } } }
    * method post
    * status 200
    * def recipeId = response.data.createRecipe.id
    * def operations =
      """
      {
        "query": "mutation($id: ID!, $file: Upload!, $crop: ImageCropInput) { setImage(recipeId: $id, file: $file, crop: $crop) { url thumbUrl width height size } }",
        "variables": { "id": "#(recipeId)", "file": null, "crop": { "x": 0, "y": 0, "width": 400, "height": 300 } }
      }
      """
    * multipart field operations = operations
    * multipart field map = '{"0":["variables.file"]}'
    * multipart file 0 = { read: 'fixtures/test.jpg', filename: 'test.jpg', contentType: 'image/jpeg' }
    * method post
    * status 200
    * match response.errors == '#notpresent'
    * def first = response.data.setImage
    * match first.width == 648
    * match first.height == 486

    * set operations.variables.crop.x = 400
    * multipart field operations = operations
    * multipart field map = '{"0":["variables.file"]}'
    * multipart file 0 = { read: 'fixtures/test.jpg', filename: 'test.jpg', contentType: 'image/jpeg' }
    * method post
    * status 200
    * match response.errors == '#notpresent'
    * def uploaded = response.data.setImage
    * match uploaded.width == 648
    * match uploaded.height == 486
    * match uploaded.url != first.url
    * match uploaded.thumbUrl != first.thumbUrl

    * set operations.variables.crop.width = 404
    * multipart field operations = operations
    * multipart field map = '{"0":["variables.file"]}'
    * multipart file 0 = { read: 'fixtures/test.jpg', filename: 'test.jpg', contentType: 'image/jpeg' }
    * method post
    * status 200
    * match response.data == null
    * match response.errors[0].extensions.code == 'crop-out-of-bounds'
    * match response.errors[0].extensions.status == 400

    * request { query: '#(read("graphql/recipe-image-by-id.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data.recipe.image == uploaded
