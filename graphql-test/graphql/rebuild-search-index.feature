Feature: Rebuild the search index for isolated tests

  Scenario: rebuild search index
    * url 'http://traefik:3000/search/reindex'
    * method post
    * status 202
    * def rebuildJobId = response.jobId
    * configure retry = { count: 60, interval: 1000 }
    * url 'http://traefik:3000/search/reindex/' + rebuildJobId
    * retry until responseStatus != 202
    * method get
    * status 200
    * match response.status == 'succeeded'
