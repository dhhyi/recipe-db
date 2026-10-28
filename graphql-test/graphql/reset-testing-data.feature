Feature: Reset application data through private testing APIs

  Scenario: reset all application data
    * url 'http://traefik:3000/recipes'
    * method delete
    * status 204
    * url 'http://traefik:3000/ratings'
    * method delete
    * status 204
    * url 'http://traefik:3000/images'
    * method delete
    * status 204
    * url 'http://traefik:3000/inspirations'
    * method delete
    * status 204
