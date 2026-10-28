@parallel=false
Feature: integration

  Background:
    * def graphqlApi = java.lang.System.getenv('GRAPHQL_API')
    * url graphqlApi
    * configure headers = { Authorization: '#(ownerAuthorization)' }

  Scenario: should be possible to have a recipe without rating
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'Rice Pudding' } } }
    * method post
    * status 200
    * def recipeId = response.data.createRecipe.id

    * request { query: '#(read("graphql/all-recipes-with-rating.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data ==
      """
      {
        recipe: { name: 'Rice Pudding', rating: { average: 0, count: 0 } }
      }
      """

  Scenario: should be possible to have a recipe with ratings
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'Beetroot Soup' } } }
    * method post
    * status 200
    * def recipeId = response.data.createRecipe.id
    * match recipeId == '#present'

    * configure headers = { Authorization: '#(memberOneAuthorization)' }
    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '#(recipeId)', rating: 5 } }
    * method post
    * status 200

    * configure headers = { Authorization: '#(memberTwoAuthorization)' }
    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '#(recipeId)', rating: 4 } }
    * method post
    * status 200

    * request { query: '#(read("graphql/all-recipes-with-rating.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data ==
      """
      {
        recipe: { name: 'Beetroot Soup', rating: { average: 4.5, count: 2 } }
      }
      """
