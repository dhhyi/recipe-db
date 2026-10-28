@parallel=false
Feature: HTTP Connection Handling

  Scenario: server advertises that it closes each connection
    * url 'http://ratings:8456'
    * path 'ratings'
    * method get
    * status 200
    * match karate.response.header('Connection') == 'close'

  Scenario: testing reset clears all ratings and can be repeated
    * url 'http://ratings:8456'
    * path 'ratings'
    * method delete
    * status 204
    * path 'ratings', 'issue-81-reset'
    * header Content-Type = 'application/x-www-form-urlencoded'
    * request 'rating=5&userId=issue-81-test'
    * method put
    * status 200
    * path 'ratings'
    * method get
    * match response == '#[1]'
    * path 'ratings/'
    * method delete
    * status 204
    * path 'ratings'
    * method get
    * match response == []
    * path 'ratings'
    * method delete
    * status 204
