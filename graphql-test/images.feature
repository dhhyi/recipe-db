Feature: images

  Background:
    * def graphqlApi = java.lang.System.getenv('GRAPHQL_API')
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
        "query": "mutation($id: ID!, $file: Upload!) { setImage(recipeId: $id, file: $file) }",
        "variables": { "id": "#(recipeId)", "file": null }
      }
      """
    * multipart field operations = operations
    * multipart field map = '{"0":["variables.file"]}'
    * multipart file 0 = { read: 'fixtures/test.jpg', filename: 'test.jpg', contentType: 'image/jpeg' }
    * method post
    * status 200
    * match response.data == { setImage: true }

    * request { query: '#(read("graphql/recipe-image-by-id.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data.recipe.image ==
      """
      {
        url: '#string',
        thumbUrl: '#string',
        width: '#number',
        height: '#number',
        size: '#number'
      }
      """
