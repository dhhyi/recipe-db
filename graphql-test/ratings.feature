Feature: ratings

  Background:
    * def graphqlApi = java.lang.System.getenv('GRAPHQL_API')
    * url graphqlApi
    * request { query: '#(read("graphql/delete-ratings-for-testing.graphql"))' }
    * method post
    * status 200

  Scenario: should have no rating
    * request { query: '#(read("graphql/rating-by-id.graphql"))', variables: { id: '1' } }
    * method post
    * status 200
    * match response.data == { rating: { average: 0, count: 0 } }

  Scenario: should execute rate
    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '1', rating: 2, login: 'test' } }
    * method post
    * status 200
    * match response.data == { rate: 2 }

  Scenario: should have rating after multiple rates
    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '1', rating: 2, login: 'test1' } }
    * method post
    * status 200

    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '1', rating: 3, login: 'test2' } }
    * method post
    * status 200

    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '1', rating: 5, login: 'test3' } }
    * method post
    * status 200

    * request { query: '#(read("graphql/rating-by-id.graphql"))', variables: { id: '1' } }
    * method post
    * status 200
    * match response.data == { rating: { average: 3.5, count: 3 } }
