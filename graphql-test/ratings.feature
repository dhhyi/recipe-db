Feature: ratings

  Background:
    * def graphqlApi = java.lang.System.getenv('GRAPHQL_API')
    * call read('graphql/reset-testing-data.feature')
    * url graphqlApi
    * configure headers = { Authorization: '#(ownerAuthorization)' }

  Scenario: should have no rating
    * request { query: '#(read("graphql/rating-by-id.graphql"))', variables: { id: '1' } }
    * method post
    * status 200
    * match response.data == { rating: { recipeId: '1', average: 0, count: 0 } }

  Scenario: should execute rate
    * configure headers = { Authorization: '#(memberOneAuthorization)' }
    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '1', rating: 2 } }
    * method post
    * status 200
    * match response.data == { rate: { average: 2, count: 1 } }

  Scenario: should have rating after multiple rates
    * configure headers = { Authorization: '#(memberOneAuthorization)' }
    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '1', rating: 2 } }
    * method post
    * status 200

    * configure headers = { Authorization: '#(memberTwoAuthorization)' }
    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '1', rating: 3 } }
    * method post
    * status 200

    * configure headers = { Authorization: '#(ownerAuthorization)' }
    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '1', rating: 5 } }
    * method post
    * status 200

    * request { query: '#(read("graphql/rating-by-id.graphql"))', variables: { id: '1' } }
    * method post
    * status 200
    * match response.data == { rating: { recipeId: '1', average: 3.5, count: 3 } }
