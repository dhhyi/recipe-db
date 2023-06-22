    @parallel=false
Feature: Rating Progression

  Background:
    * def backend = java.lang.System.getenv('REST_API')
    * print 'using backend: ', backend
    * url backend

  Scenario: clearing database should succeed
    * path 'ratings'
    * method delete
    * status 204

  Scenario: database should be empty
    * path 'ratings'
    * method get
    * status 200
    * match response == []


  Scenario: should have no rating at the beginning
    * path 'ratings/1'
    * method get
    * status 200
    * match response == {id: "1", rating: 0, count: 0}

  Scenario: putting first rating should succeed
    * path 'ratings/1'
    * form field rating = 5
    * form field login = 'user1'
    * method put
    * status 200
    * match response == {id: "1", rating: 5, count: 1}

  Scenario: should have one rating
    * path 'ratings/1'
    * method get
    * status 200
    * match response == {id: "1", rating: 5, count: 1}

  Scenario: putting second rating should succeed
    * path 'ratings/1'
    * form field rating = 4
    * form field login = 'user2'
    * method put
    * status 200
    * match response == {id: "1", rating: 4.5, count: 2}

  Scenario: should have two ratings
    * path 'ratings/1'
    * method get
    * status 200
    * match response == {id: "1", rating: 4.5, count: 2}

  Scenario: putting third rating should succeed
    * path 'ratings/1'
    * form field rating = 3
    * form field login = 'user3'
    * method put
    * status 200
    * match response == {id: "1", rating: 4, count: 3}

  Scenario: should have three ratings
    * path 'ratings/1'
    * method get
    * status 200
    * match response == {id: "1", rating: 4, count: 3}
