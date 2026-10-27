@parallel=false
Feature: search recipes

  Background:
    * def graphqlApi = java.lang.System.getenv('GRAPHQL_API')
    * url graphqlApi
    * configure retry = { count: 30, interval: 1000 }
    * request { query: '#(read("graphql/delete-recipes-for-testing.graphql"))' }
    * method post
    * status 200
    * match response.data.deleteRecipesForTesting == true

    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'Kartoffelsuppe', method: 'Kartoffeln mit Zwiebeln kochen.', ingredients: [{ name: 'Kartoffeln', amount: 500, unit: 'g' }] } } }
    * method post
    * status 200
    * def soupId = response.data.createRecipe.id
    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '#(soupId)', rating: 5 } }
    * method post
    * status 200
    * match response.data.rate.average == 5

    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'Kartoffelsalat', ingredients: [{ name: 'Kartoffeln' }] } } }
    * method post
    * status 200
    * def saladId = response.data.createRecipe.id
    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '#(saladId)', rating: 3 } }
    * method post
    * status 200
    * match response.data.rate.average == 3

    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'Apfelkuchen', ingredients: [{ name: 'Apfel' }] } } }
    * method post
    * status 200
    * def cakeId = response.data.createRecipe.id
    * request { query: '#(read("graphql/rate.graphql"))', variables: { id: '#(cakeId)', rating: 4 } }
    * method post
    * status 200
    * match response.data.rate.average == 4

  Scenario: German search returns ordered recipes with full GraphQL fields
    * request { query: '#(read("graphql/search-recipes.graphql"))', variables: { options: { q: 'Kartoffel', query_by: 'name', sort_by: '_text_match:desc,rating_average:desc' } } }
    * retry until response.data != null && response.data.searchRecipes.found == 2 && response.data.searchRecipes.recipes.length == 2 && response.data.searchRecipes.recipes[0].id == soupId && response.data.searchRecipes.recipes[1].id == saladId
    * method post
    * status 200
    * match response.errors == '#notpresent'
    * match response.data.searchRecipes.recipes[0] ==
      """
      {
        id: '#(soupId)',
        name: 'Kartoffelsuppe',
        method: 'Kartoffeln mit Zwiebeln kochen.',
        ingredients: [{ name: 'Kartoffeln', amount: '500', unit: 'g', optional: null }],
        rating: { average: 5, count: 1 },
        image: null,
        inspirations: []
      }
      """
    * match response.data.searchRecipes.recipes[1].name == 'Kartoffelsalat'

  Scenario: a misspelled query finds the intended recipe
    * request { query: '#(read("graphql/search-recipes.graphql"))', variables: { options: { q: 'Kartofelsuppe' } } }
    * retry until response.data != null && response.data.searchRecipes.found == 1 && response.data.searchRecipes.recipes.length == 1 && response.data.searchRecipes.recipes[0].id == soupId
    * method post
    * status 200
    * match response.errors == '#notpresent'
    * match response.data.searchRecipes.recipes[0].name == 'Kartoffelsuppe'

  Scenario: pagination and facets preserve search metadata
    * request { query: '#(read("graphql/search-recipes-with-facets.graphql"))', variables: { options: { q: '*', sort_by: 'rating_average:desc', page: 2, per_page: 1, facet_by: 'ingredients' } } }
    * retry until response.data != null && response.data.searchRecipes.found == 3 && response.data.searchRecipes.recipes.length == 1 && response.data.searchRecipes.recipes[0].id == cakeId
    * method post
    * status 200
    * match response.errors == '#notpresent'
    * match response.data.searchRecipes contains { found: 3, page: 2, perPage: 1, recipes: [{ id: '#(cakeId)', name: 'Apfelkuchen' }] }
    * match response.data.searchRecipes.facets == '#[1]'
    * match response.data.searchRecipes.facets[0] contains { field_name: 'ingredients', counts: '#array' }
    * match response.data.searchRecipes.facets[0].counts contains { value: 'Kartoffeln', count: 2, highlighted: 'Kartoffeln' }
    * match response.data.searchRecipes.facets[0].counts contains { value: 'Apfel', count: 1, highlighted: 'Apfel' }

  Scenario: a deleted recipe disappears from search
    * request { query: '#(read("graphql/search-recipes.graphql"))', variables: { options: { q: 'Kartoffelsuppe' } } }
    * retry until response.data != null && response.data.searchRecipes.found == 1 && response.data.searchRecipes.recipes.length == 1 && response.data.searchRecipes.recipes[0].id == soupId
    * method post
    * status 200

    * request { query: '#(read("graphql/delete-recipe.graphql"))', variables: { id: '#(soupId)' } }
    * method post
    * status 200
    * match response.data.deleteRecipe == true

    * request { query: '#(read("graphql/search-recipes.graphql"))', variables: { options: { q: 'Kartoffelsuppe' } } }
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
