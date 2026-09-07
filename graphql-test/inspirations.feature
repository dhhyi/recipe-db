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

  Scenario: should have a recipe with extracted inspirations after adding one
    * def fixtureApi = java.lang.System.getenv('INSPIRATION_FIXTURE_API')
    * def pageUrl = fixtureApi + '/page'
    * def canonicalUrl = fixtureApi + '/canonical'
    * def faviconUrl = fixtureApi + '/favicon.ico'
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'test', inspirations: ['#(pageUrl)'] } } }
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
              url: '#(pageUrl)',
              extracted: {
                canonical: '#(canonicalUrl)',
                description: 'Fixture page for GraphQL inspiration extraction',
                favicon: '#(faviconUrl)',
                inlinedFavicon: 'data:image/x-icon;base64,aWNvbg==',
                title: 'GraphQL Inspiration Fixture'
              }
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
