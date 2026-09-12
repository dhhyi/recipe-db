@parallel=false
Feature: Basic test for setting errornous ratings

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
    * match response.detail == "Missing rating"
    * match response.code == "missing-field"
    * match response.field == "rating"

  Scenario: adding rating without login should fail
    * url backend
    * path 'ratings/1'
    * form field rating = 5
    * method put
    # * status 400
    * match response.detail == "Missing login"
    * match response.code == "missing-field"
    * match response.field == "login"

  Scenario Outline: adding "<rating>" as rating should fail
    * url backend
    * path 'ratings/1'
    * form field rating = <rating>
    * form field login = 'test'
    * method put
    * status 400
    * match response.detail == "Invalid rating"
    * match response.code == "invalid-field"
    * match response.field == "rating"

    Examples:
      | rating |
      | 0      |
      | -1     |
      | 6      |
      | 1.5    |
      | 'A'    |
      | ' '    |
