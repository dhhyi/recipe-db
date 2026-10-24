Feature: Search recipes on the deployed stack
  Each scenario owns a unique ingredient scope and removes only its own data.
  Search assertions wait for indexing where eventual consistency is expected.

  Background:
    Given the search service is ready
    And these recipes exist in an isolated test scope:
      | recipe | name           | ingredient | rating |
      | soup   | Kartoffelsuppe | Kartoffeln | 5      |
      | salad  | Kartoffelsalat | Kartoffeln | 3      |
      | cake   | Apfelkuchen    | Äpfel      | 4      |
    And all scoped recipes have been indexed

  Scenario: German text, typo tolerance and relevance ordering
    When I search for "Kartofelsuppe"
    Then the results are exactly "soup"
    When I search for "Äpfel"
    Then the results are exactly "cake"
    When I search with options:
      """
      {"q": "Kartofelsuppe", "num_typos": 0}
      """
    Then the results are empty
    When I search with options:
      """
      {"q": "Kartoffel", "sort_by": "_text_match:desc,rating_average:desc"}
      """
    Then eventually the results are exactly "soup, salad"

  Scenario: Composed options preserve facets, pagination and grouping
    When I search with options:
      """
      {"sort_by": "rating_average:desc"}
      """
    Then eventually the results are exactly "soup, cake, salad"
    When I search with options:
      """
      {
        "query_by": "method", "q": "Zwiebeln",
        "sort_by": "rating_average:desc", "facet_by": "ingredients",
        "page": 2, "per_page": 1, "include_fields": "*", "highlight_fields": "*"
      }
      """
    Then the results are exactly "cake"
    And the response has exactly these fields:
      | field       |
      | recipeIds   |
      | facetCounts |
      | found       |
      | outOf       |
      | page        |
      | perPage     |
    And the response contains:
      """
      {"found": 3, "page": 2, "perPage": 1}
      """
    And outOf is at least 3
    And the ingredient facet counts "Kartoffeln" 2 times
    And the response contains no highlights
    When I search with options:
      """
      {"group_by": "rating_average", "group_limit": 1, "sort_by": "rating_average:desc"}
      """
    Then the results are exactly "soup, cake, salad"

  Scenario: GraphQL writes and repeated events converge to current recipe data
    When I update "soup" through GraphQL:
      """
      {"name": "Linsensuppe"}
      """
    And I search for "Linsensuppe"
    Then eventually the results are exactly "soup"
    When I publish the same change event twice for "soup"
    And I publish a new change event for "soup"
    And all search events have been acknowledged
    And I search for "Linsensuppe"
    Then the results are exactly "soup"
    When I delete "salad" through GraphQL
    And I search all scoped recipes
    Then eventually the results contain none of "salad"
    When I publish a deletion event for the existing recipe "soup"
    And all search events have been acknowledged
    And I search for "Linsensuppe"
    Then the results are exactly "soup"

  Scenario: Clearing optional values removes their indexed content
    When I give "soup" a unique inspiration URL
    And I search for that inspiration URL
    Then eventually the results are exactly "soup"
    When I update "soup" through GraphQL:
      """
      {"inspirations": [], "method": null}
      """
    And I search for that inspiration URL
    Then eventually the results are empty
    When I search with options:
      """
      {"q": "Zwiebeln", "query_by": "method"}
      """
    Then eventually the results contain none of "soup"

  Scenario: Image presence survives a rebuild
    When I search for scoped recipes with images
    Then the results are empty
    When I upload the fixture image to "soup" through GraphQL
    And I search for scoped recipes with images
    Then eventually the results are exactly "soup"
    When I search for scoped recipes without images
    Then the results contain exactly "salad, cake" in any order
    When I rebuild the search index successfully
    And I search for scoped recipes with images
    Then the results are exactly "soup"

  Scenario: A rebuild recovers direct REST writes without events
    When I update "soup" directly through REST:
      """
      {"name": "Unveröffentlichte Möhrensuppe"}
      """
    And I delete "salad" directly through REST
    And I create "added" directly through REST:
      """
      {"name": "Unveröffentlichter Kuchen"}
      """
    And I rebuild the search index successfully
    And I search for "Möhrensuppe"
    Then the results are exactly "soup"
    When I search all scoped recipes
    Then the results contain exactly "soup, cake, added" in any order

  Scenario: Overlapping rebuild requests converge with queued writes
    When I start rebuilding the search index
    And I update "soup" through GraphQL:
      """
      {"name": "Birnensuppe"}
      """
    And these recipes exist in an isolated test scope:
      | recipe | name       | ingredient | rating |
      | added  | Käsekuchen | Käse       | 2      |
    And I rebuild the search index successfully
    And the first rebuild finishes successfully
    And I search for "Birnensuppe"
    Then eventually the results are exactly "soup"
    When I search all scoped recipes
    Then eventually the results include "added"

  Scenario Outline: Invalid search options return Problem Details
    When I send a search request with invalid options:
      """
      <options>
      """
    Then the response is HTTP 400 with content type "application/problem+json"
    And the response contains:
      """
      {"type": "about:blank", "code": "invalid-search-options", "status": 400}
      """

    Examples:
      | options                              |
      | {"q": []}                            |
      | {"q": "*", "filter_by": "missing:=1"} |

  Scenario: German name keys, unrated recipes and every fixed sort
    When I update "soup" through GraphQL:
      """
      {"name": "Äpfelsuppe"}
      """
    And I update "salad" through GraphQL:
      """
      {"name": "Apfel"}
      """
    And I update "cake" through GraphQL:
      """
      {"name": "Banane"}
      """
    And these recipes exist in an isolated test scope:
      | recipe  | name    | ingredient | rating |
      | oil     | Ölsuppe | Öl         |        |
      | street1 | Strasse | Salz       | 4      |
      | street2 | Straße  | Salz       | 4      |
      | onion   | Zwiebel | Zwiebeln   |        |
    And all scoped recipes have been indexed
    Then every explicit sort follows the source metadata and stable ID ties
    When I rebuild the search index successfully
    Then every explicit sort follows the source metadata and stable ID ties

  Scenario: Source timestamp microseconds survive optional events and rebuilds
    When I record the exact source recipe metadata
    And I change only the rating of "soup"
    And I give "soup" a unique inspiration URL
    And I upload the fixture image to "soup" through GraphQL
    And all search events have been acknowledged
    Then indexed timestamps retain the exact recorded source microseconds
    When I rebuild the search index successfully
    Then indexed timestamps retain the exact recorded source microseconds
