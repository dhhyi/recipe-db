    @parallel=false
Feature: Basic test for setting ratings

  Background:
    * def backend = java.lang.System.getenv('REST_API')
    * print 'using backend: ', backend
    * url backend
    * path 'ratings'
    * method delete
    * status 204

  Scenario: adding rating without rating should fail
    * url backend
    * path 'ratings/1'
    * method put
    * status 400
    * match response == "Missing rating"

  Scenario: adding rating without login should fail
    * url backend
    * path 'ratings/1'
    * form field rating = 5
    * method put
    # * status 400
    * match response == "Missing login"

  Scenario Outline: adding "<rating>" as rating should fail
    * url backend
    * path 'ratings/1'
    * form field rating = <rating>
    * form field login = 'test'
    * method put
    * status 400
    * match response == "Invalid rating"

    Examples:
      | rating |
      | 0      |
      | -1     |
      | 6      |
      | 1.5    |
      | 'A'    |
      | ' '    |
