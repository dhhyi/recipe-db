    @parallel=false
Feature: Rounding Ratings

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
    * match response.rating == 4

    * path 'ratings/1'
    * form field rating = 3
    * form field login = 'user2'
    * method put
    * status 200
    * match response.rating == 3.5

    * path 'ratings/1'
    * form field rating = 3
    * form field login = 'user3'
    * method put
    * status 200
    * match response.rating == 3.5

    * path 'ratings/1'
    * form field rating = 1
    * form field login = 'user4'
    * method put
    * status 200
    * match response.rating == 3
