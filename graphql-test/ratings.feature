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

  Scenario: ratings are associated with the authenticated member
    * def ownRatingQuery = 'query($id: ID!) { rating(id: $id) { average count myRating } }'
    * def rateQuery = 'mutation($id: ID!, $rating: Int!) { rate(id: $id, rating: $rating) { myRating } }'
    * configure headers = { Authorization: '#(memberOneAuthorization)' }
    * request { query: '#(rateQuery)', variables: { id: '1', rating: 5 } }
    * method post
    * status 200
    * match response.data == { rate: { myRating: 5 } }

    * configure headers = { Authorization: '#(memberTwoAuthorization)' }
    * request { query: '#(ownRatingQuery)', variables: { id: '1' } }
    * method post
    * status 200
    * match response.data == { rating: { average: 5, count: 1, myRating: null } }

    * request { query: '#(rateQuery)', variables: { id: '1', rating: 2 } }
    * method post
    * status 200
    * match response.data == { rate: { myRating: 2 } }

    * configure headers = { Authorization: '#(memberOneAuthorization)' }
    * request { query: '#(rateQuery)', variables: { id: '1', rating: 3 } }
    * method post
    * status 200
    * match response.data == { rate: { myRating: 3 } }

    * request { query: '#(ownRatingQuery)', variables: { id: '1' } }
    * method post
    * status 200
    * match response.data == { rating: { average: 2.5, count: 2, myRating: 3 } }

    * configure headers = { Authorization: '#(memberTwoAuthorization)' }
    * request { query: '#(ownRatingQuery)', variables: { id: '1' } }
    * method post
    * status 200
    * match response.data == { rating: { average: 2.5, count: 2, myRating: 2 } }

    * configure headers = { Authorization: '#(ownerAuthorization)' }
    * request { query: '#(rateQuery)', variables: { id: '1', rating: 4 } }
    * method post
    * status 200
    * match response.data == { rate: { myRating: 4 } }

    * request { query: '#(ownRatingQuery)', variables: { id: '1' } }
    * method post
    * status 200
    * match response.data == { rating: { average: 3, count: 3, myRating: 4 } }

  Scenario: concurrent member ratings retain separate identities and exact aggregates
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'Concurrent ratings' } } }
    * method post
    * status 200
    * def recipeId = response.data.createRecipe.id
    * match recipeId == '#present'

    * configure headers = { Authorization: '#(memberOneAuthorization)' }
    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '#(recipeId)', rating: 5 } }
    * method post
    * status 200
    * match response.data == { rate: { average: 5, count: 1 } }

    * def runConcurrent = read('graphql/rating-concurrency.js')
    * def results = runConcurrent(graphqlApi, memberOneAuthorization, memberTwoAuthorization, recipeId)
    * match results == '#[8]'
    * match each results == { status: 200, body: { data: { rate: { average: '#number', count: '#number', myRating: '#number' } } } }

    * def ownRatingQuery = 'query($id: ID!) { rating(id: $id) { average count myRating } }'
    * request { query: '#(ownRatingQuery)', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data == { rating: { average: 3, count: 2, myRating: 2 } }

    * configure headers = { Authorization: '#(memberTwoAuthorization)' }
    * request { query: '#(ownRatingQuery)', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data == { rating: { average: 3, count: 2, myRating: 4 } }

    * configure headers = {}
    * request { query: '#(read("graphql/rating-by-id.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data == { rating: { recipeId: '#(recipeId)', average: 3, count: 2 } }
