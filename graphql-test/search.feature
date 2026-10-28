@parallel=false
Feature: search recipes

  Background:
    * def graphqlApi = java.lang.System.getenv('GRAPHQL_API')
    * call read('graphql/reset-testing-data.feature')
    * url graphqlApi
    * def searchToken = java.util.UUID.randomUUID().toString()
    * configure headers = { Authorization: '#(ownerAuthorization)' }
    * configure retry = { count: 30, interval: 1000 }

    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: '#(searchToken) Kartoffelsuppe', method: 'Kartoffeln mit Zwiebeln kochen.', ingredients: [{ name: 'Kartoffeln', amount: 500, unit: 'g' }] } } }
    * method post
    * status 200
    * def soupId = response.data.createRecipe.id
    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '#(soupId)', rating: 5 } }
    * method post
    * status 200
    * match response.data.rate.average == 5

    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: '#(searchToken) Kartoffelsalat', ingredients: [{ name: 'Kartoffeln' }] } } }
    * method post
    * status 200
    * def saladId = response.data.createRecipe.id
    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '#(saladId)', rating: 3 } }
    * method post
    * status 200
    * match response.data.rate.average == 3

    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: '#(searchToken) Apfelkuchen', ingredients: [{ name: 'Apfel' }] } } }
    * method post
    * status 200
    * def cakeId = response.data.createRecipe.id
    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '#(cakeId)', rating: 4 } }
    * method post
    * status 200
    * match response.data.rate.average == 4

    * call read('graphql/rebuild-search-index.feature')
    * url graphqlApi

  Scenario: German search returns ordered recipes with full GraphQL fields
    * request { query: '#(read("graphql/search-recipes.graphql"))', variables: { options: { q: '#(searchToken) Kartoffel', query_by: 'name', sort_by: '_text_match:desc,rating_average:desc' } } }
    * retry until response.data != null && response.data.searchRecipes.found == 2 && response.data.searchRecipes.recipes.length == 2 && response.data.searchRecipes.recipes[0].id == soupId && response.data.searchRecipes.recipes[1].id == saladId
    * method post
    * status 200
    * match response.errors == '#notpresent'
    * match response.data.searchRecipes.recipes[0] ==
      """
      {
        id: '#(soupId)',
        name: '#(searchToken) Kartoffelsuppe',
        method: 'Kartoffeln mit Zwiebeln kochen.',
        ingredients: [{ name: 'Kartoffeln', amount: '500', unit: 'g', optional: null }],
        rating: { average: 5, count: 1 },
        image: null,
        inspirations: []
      }
      """
    * match response.data.searchRecipes.recipes[1].name == '#(searchToken) Kartoffelsalat'

  Scenario: a misspelled query finds the intended recipe
    * request { query: '#(read("graphql/search-recipes.graphql"))', variables: { options: { q: '#(searchToken) Kartofelsuppe' } } }
    * retry until response.data != null && response.data.searchRecipes.found == 1 && response.data.searchRecipes.recipes.length == 1 && response.data.searchRecipes.recipes[0].id == soupId
    * method post
    * status 200
    * match response.errors == '#notpresent'
    * match response.data.searchRecipes.recipes[0].name == '#(searchToken) Kartoffelsuppe'

  Scenario: pagination and facets preserve search metadata
    * request { query: '#(read("graphql/search-recipes-with-facets.graphql"))', variables: { options: { q: '#(searchToken)', query_by: 'name', sort_by: 'name_sort:asc,recipe_id_sort:asc', page: 2, per_page: 1, facet_by: 'ingredients' } } }
    * retry until response.data != null && response.data.searchRecipes.found == 3 && response.data.searchRecipes.recipes.length == 1 && response.data.searchRecipes.recipes[0].id == saladId
    * method post
    * status 200
    * match response.errors == '#notpresent'
    * match response.data.searchRecipes contains { found: 3, page: 2, perPage: 1, recipes: [{ id: '#(saladId)', name: '#(searchToken) Kartoffelsalat' }] }
    * match response.data.searchRecipes.facets == '#[1]'
    * match response.data.searchRecipes.facets[0] contains { field_name: 'ingredients', counts: '#array' }
    * match response.data.searchRecipes.facets[0].counts contains { value: 'Kartoffeln', count: 2, highlighted: 'Kartoffeln' }
    * match response.data.searchRecipes.facets[0].counts contains { value: 'Apfel', count: 1, highlighted: 'Apfel' }

  Scenario: a deleted recipe disappears from search
    * request { query: '#(read("graphql/search-recipes.graphql"))', variables: { options: { q: '#(searchToken) Kartoffelsuppe' } } }
    * retry until response.data != null && response.data.searchRecipes.found == 1 && response.data.searchRecipes.recipes.length == 1 && response.data.searchRecipes.recipes[0].id == soupId
    * method post
    * status 200

    * request { query: '#(read("graphql/delete-recipe.graphql"))', variables: { id: '#(soupId)' } }
    * method post
    * status 200
    * match response.data.deleteRecipe == true

    * call read('graphql/rebuild-search-index.feature')
    * url graphqlApi
    * request { query: '#(read("graphql/search-recipes.graphql"))', variables: { options: { q: '#(searchToken) Kartoffelsuppe' } } }
    * retry until response.data != null && response.data.searchRecipes.found == 0 && response.data.searchRecipes.recipes.length == 0
    * method post
    * status 200
    * match response.errors == '#notpresent'
    * match response.data.searchRecipes.recipes == []

  Scenario: invalid options forward the search Problem Details
    * request { query: '#(read("graphql/search-recipes.graphql"))', variables: { options: { q: ['x'] } } }
    * retry until response.errors != null && response.errors[0].extensions.code == 'invalid-search-options'
    * method post
    * status 200
    * match response.data == null
    * match response.errors == '#[1]'
    * match response.errors[0].extensions contains { code: 'invalid-search-options', status: 400 }
