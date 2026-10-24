@parallel=false
Feature: HTTP Connection Handling

  Scenario: server advertises that it closes each connection
    * url 'http://ratings:8456'
    * path 'ratings'
    * method get
    * status 200
    * match karate.response.header('Connection') == 'close'
