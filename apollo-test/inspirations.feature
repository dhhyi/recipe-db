Feature: inspirations

  Background:
    * def graphqlApi = java.lang.System.getenv('GRAPHQL_API')
    * url graphqlApi
    * request { query: '#(read("graphql/delete-recipes-for-testing.graphql"))' }
    * method post
    * status 200
    * request { query: '#(read("graphql/delete-inspirations-for-testing.graphql"))' }
    * method post
    * status 200

  Scenario: should have no recipe
    * request { query: '#(read("graphql/all-recipes.graphql"))' }
    * method post
    * status 200
    * match response.data == { recipes: [] }

  Scenario: should have a recipe with inspirations after adding one
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'test', inspirations: ['https://example.com', 'https://google.com'] } } }
    * method post
    * status 200
    * match response.data.createRecipe == { id: '#string', name: 'test' }
    * def recipeId = response.data.createRecipe.id

    * request { query: '#(read("graphql/recipe-by-id-with-inspirations.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data ==
      """
      {
        recipe: {
          name: 'test',
          inspirations: [
            {
              url: 'https://example.com',
              extracted: { canonical: 'https://example.com', description: null, favicon: null, title: 'Example Domain' }
            },
            {
              url: 'https://google.com',
              extracted: { canonical: 'https://google.com', description: null, favicon: 'https://google.com/favicon.ico', title: 'Google' }
            }
          ]
        }
      }
      """

  Scenario Outline: should be able to remove inspirations from recipe by sending <value>
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'test', inspirations: ['https://example.com'] } } }
    * method post
    * status 200
    * def recipeId = response.data.createRecipe.id
    * match recipeId == '#present'

    * request { query: '#(read("graphql/recipe-inspirations-by-id.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data.recipe.inspirations == '#[1]'

    * request { query: '#(read("graphql/update-recipe.graphql"))', variables: { id: '#(recipeId)', value: { inspirations: <value> } } }
    * method post
    * status 200
    * match response.data.updateRecipe.id == '#present'

    * request { query: '#(read("graphql/recipe-inspirations-by-id.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data.recipe.inspirations == '#[0]'

    Examples:
      | value |
      | null  |
      | []    |
