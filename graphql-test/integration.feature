@parallel=false
Feature: integration

  Background:
    * def graphqlApi = java.lang.System.getenv('GRAPHQL_API')
    * url graphqlApi
    * request { query: '#(read("graphql/delete-recipes-for-testing.graphql"))' }
    * method post
    * status 200
    * request { query: '#(read("graphql/delete-ratings-for-testing.graphql"))' }
    * method post
    * status 200

  Scenario: should be possible to have a recipe without rating
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'Rice Pudding' } } }
    * method post
    * status 200

    * request { query: '#(read("graphql/all-recipes-with-rating.graphql"))' }
    * method post
    * status 200
    * match response.data ==
      """
      {
        recipes: [
          { name: 'Rice Pudding', rating: { average: 0, count: 0 } }
        ]
      }
      """

  Scenario: should be possible to have a recipe with ratings
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'Beetroot Soup' } } }
    * method post
    * status 200
    * def recipeId = response.data.createRecipe.id
    * match recipeId == '#present'

    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '#(recipeId)', login: 'user1', rating: 5 } }
    * method post
    * status 200

    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '#(recipeId)', login: 'user2', rating: 4 } }
    * method post
    * status 200

    * request { query: '#(read("graphql/all-recipes-with-rating.graphql"))' }
    * method post
    * status 200
    * match response.data ==
      """
      {
        recipes: [
          { name: 'Beetroot Soup', rating: { average: 4.5, count: 2 } }
        ]
      }
      """
