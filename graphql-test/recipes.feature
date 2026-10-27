Feature: recipes

  Background:
    * def graphqlApi = java.lang.System.getenv('GRAPHQL_API')
    * url graphqlApi
    * configure headers = { Authorization: '#(ownerAuthorization)' }
    * request { query: '#(read("graphql/delete-recipes-for-testing.graphql"))' }
    * method post
    * status 200

  Scenario: should have no recipe
    * request { query: '#(read("graphql/all-recipes.graphql"))' }
    * method post
    * status 200
    * match response.data == { recipes: [] }

  Scenario: should expose a derived read-only name sort key
    * request { query: 'mutation { createRecipe(value: {name: "  A\\u0308pfel ÖL Straße  "}) { id name nameSortKey createdAt updatedAt } }' }
    * method post
    * status 200
    * match response.errors == '#notpresent'
    * def recipe = response.data.createRecipe
    * match recipe.name == '  A\u0308pfel ÖL Straße  '
    * match recipe.nameSortKey == 'apfel ol strasse'
    * match recipe.updatedAt == recipe.createdAt

    * request { query: 'query($id: ID!) { recipe(id: $id) { nameSortKey createdAt updatedAt } recipes { nameSortKey } }', variables: { id: '#(recipe.id)' } }
    * method post
    * status 200
    * match response.data.recipe == { nameSortKey: 'apfel ol strasse', createdAt: '#(recipe.createdAt)', updatedAt: '#(recipe.updatedAt)' }
    * match response.data.recipes == [{ nameSortKey: 'apfel ol strasse' }]

    * request { query: 'mutation($id: ID!) { updateRecipe(id: $id, value: {}) { nameSortKey createdAt updatedAt } }', variables: { id: '#(recipe.id)' } }
    * method post
    * status 200
    * match response.data.updateRecipe == { nameSortKey: 'apfel ol strasse', createdAt: '#(recipe.createdAt)', updatedAt: '#(recipe.updatedAt)' }

    * request { query: 'mutation { createRecipe(value: {name: "test", nameSortKey: "override"}) { id } }' }
    * method post
    * status 200
    * match response.errors[0].message contains 'nameSortKey'
    * match response.errors[0].message contains 'RecipeInput'

  Scenario: should have a recipe after adding one
    * def variables =
      """
      {
        value: {
          name: 'test',
          method: 'cook it',
          ingredients: [
            { name: 'ingredient', amount: 1 },
            { name: 'opt', optional: true }
          ]
        }
      }
      """
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: '#(variables)' }
    * method post
    * status 200
    * match response.data.createRecipe.id == '#string'
    * match response.data.createRecipe.name == 'test'
    * match response.data.createRecipe.createdAt == '#regex \\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{6}Z'
    * match response.data.createRecipe.updatedAt == response.data.createRecipe.createdAt
    * def recipeId = response.data.createRecipe.id
    * def createdAt = response.data.createRecipe.createdAt
    * def updatedAt = response.data.createRecipe.updatedAt
    * match recipeId == '#regex [0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'

    * request { query: '#(read("graphql/recipe-by-id.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data.recipe.id == '#string'
    * match response.data.recipe.name == 'test'
    * match response.data.recipe.method == '#string'
    * match response.data.recipe.ingredients == '#array'
    * match response.data.recipe.createdAt == createdAt
    * match response.data.recipe.updatedAt == updatedAt

    * request { query: '#(read("graphql/all-recipes.graphql"))' }
    * method post
    * status 200
    * match response.data.recipes == '#[1]'
    * match response.data.recipes[0].createdAt == createdAt
    * match response.data.recipes[0].updatedAt == updatedAt

  Scenario: should be able to edit a recipe
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'test', method: 'cook it', ingredients: [{ name: 'ingredient', amount: 1 }] } } }
    * method post
    * status 200
    * def recipeId = response.data.createRecipe.id
    * def createdAt = response.data.createRecipe.createdAt
    * def initialUpdatedAt = response.data.createRecipe.updatedAt
    * match recipeId == '#present'

    * request { query: '#(read("graphql/recipe-by-id.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data.recipe.name == 'test'
    * match response.data.recipe.method == 'cook it'
    * match response.data.recipe.ingredients == '#[1]'
    * match response.data.recipe.createdAt == createdAt
    * match response.data.recipe.updatedAt == initialUpdatedAt

    * request { query: '#(read("graphql/update-recipe.graphql"))', variables: { id: '#(recipeId)', value: { name: 'test2' } } }
    * method post
    * status 200
    * match response.data.updateRecipe.createdAt == createdAt
    * match response.data.updateRecipe.updatedAt == '#regex \\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{6}Z'
    * def changedAt = response.data.updateRecipe.updatedAt
    * match changedAt != initialUpdatedAt

    * request { query: '#(read("graphql/recipe-by-id.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data.recipe.name == 'test2'
    * match response.data.recipe.method == 'cook it'
    * match response.data.recipe.ingredients == '#[1]'
    * match response.data.recipe.createdAt == createdAt
    * match response.data.recipe.updatedAt == changedAt

    * request { query: '#(read("graphql/update-recipe.graphql"))', variables: { id: '#(recipeId)', value: { method: null } } }
    * method post
    * status 200
    * match response.data.updateRecipe.createdAt == createdAt
    * match response.data.updateRecipe.updatedAt == '#regex \\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{6}Z'
    * match response.data.updateRecipe.updatedAt != changedAt
    * def clearedMethodAt = response.data.updateRecipe.updatedAt

    * request { query: '#(read("graphql/recipe-by-id.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data.recipe.name == 'test2'
    * match response.data.recipe.method == null
    * match response.data.recipe.ingredients == '#[1]'
    * match response.data.recipe.createdAt == createdAt
    * match response.data.recipe.updatedAt == clearedMethodAt

  Scenario: should be able to delete a recipe
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'test' } } }
    * method post
    * status 200
    * def recipeId = response.data.createRecipe.id
    * match recipeId == '#present'

    * request { query: '#(read("graphql/all-recipes.graphql"))' }
    * method post
    * status 200
    * match response.data.recipes == '#[1]'

    * request { query: '#(read("graphql/delete-recipe.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data == { deleteRecipe: true }

    * request { query: '#(read("graphql/all-recipes.graphql"))' }
    * method post
    * status 200
    * match response.data.recipes == '#[0]'

  Scenario: should not be able to delete an unknown recipe
    * request { query: '#(read("graphql/delete-recipe.graphql"))', variables: { id: 'unknown' } }
    * method post
    * status 200
    * match response.data == { deleteRecipe: false }

  Scenario Outline: should not be able to add a recipe with <name> name
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: <name> } } }
    * method post
    * status 200
    * match response.data.createRecipe == null
    * match response.errors[0].message == 'Missing field value for name'
    * match response.errors[0].extensions.code == 'required-field'
    * match response.errors[0].extensions.field == 'name'

    Examples:
      | name |
      | ''   |
      | null |

  Scenario Outline: should not be able to change the name of recipe to <name>
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'test' } } }
    * method post
    * status 200
    * def recipeId = response.data.createRecipe.id
    * match recipeId == '#present'

    * request { query: '#(read("graphql/update-recipe.graphql"))', variables: { id: '#(recipeId)', value: { name: <name> } } }
    * method post
    * status 200
    * match response.data.updateRecipe == null
    * match response.errors[0].message == 'Missing field value for name'
    * match response.errors[0].extensions.code == 'required-field'
    * match response.errors[0].extensions.field == 'name'

    Examples:
      | name |
      | ''   |
      | null |
