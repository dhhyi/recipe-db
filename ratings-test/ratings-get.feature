Feature: Basic test for setting ratings

  Background:
    * def backend = java.lang.System.getenv('REST_API')
    * print 'using backend: ', backend
    * url backend
    * path 'ratings/1'
    * request { rating: 5 }
    * method put
    * status 200
    * match response == { id: 1, rating: 5 }

  Scenario: get rating for id 1
    * url backend
    * path 'ratings/1'
    * method get
    * status 200
    * match response == { id: 1, rating: 5 }

  Scenario: get rating for all should contain id 1
    * url backend
    * path 'ratings'
    * method get
    * status 200
    * match response contains { id: 1, rating: 5 }
