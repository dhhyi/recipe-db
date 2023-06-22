    @parallel=false
Feature: All Ratings Endpoint

  Background:
    * def backend = java.lang.System.getenv('REST_API')
    * print 'using backend: ', backend
    * url backend
    * path 'ratings'
    * method delete
    * status 204

  Scenario: adding rating should always be rounded to half stars
    * url backend

    * path 'ratings/1'
    * form field rating = 4
    * form field login = 'user1'
    * method put
    * status 200

    * path 'ratings/1'
    * form field rating = 3
    * form field login = 'user2'
    * method put
    * status 200

    * path 'ratings/2'
    * form field rating = 5
    * form field login = 'user1'
    * method put
    * status 200

    * path 'ratings/3'
    * form field rating = 3
    * form field login = 'user2'
    * method put
    * status 200

    * path 'ratings'
    * method get
    * status 200
    * match response contains {id: "1", rating: 3.5, count: 2}
    * match response contains {id: "2", rating: 5, count: 1}
    * match response contains {id: "3", rating: 3, count: 1}
