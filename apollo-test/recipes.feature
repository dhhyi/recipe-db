Feature: recipes

  Background:
    * def graphqlApi = java.lang.System.getenv('GRAPHQL_API')
    * url graphqlApi
    * request { query: '#(read("graphql/delete-recipes-for-testing.graphql"))' }
    * method post
    * status 200

  Scenario: should have no recipe
    * request { query: '#(read("graphql/all-recipes.graphql"))' }
    * method post
    * status 200
    * match response.data == { recipes: [] }

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
    * match response.data.createRecipe == { id: '#string', name: 'test' }
    * def recipeId = response.data.createRecipe.id

    * request { query: '#(read("graphql/recipe-by-id.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data.recipe == { id: '#string', name: 'test', method: '#string', ingredients: '#array' }

    * request { query: '#(read("graphql/all-recipes.graphql"))' }
    * method post
    * status 200
    * match response.data.recipes == '#[1]'

  Scenario: should be able to edit a recipe
    * request { query: '#(read("graphql/create-recipe.graphql"))', variables: { value: { name: 'test' } } }
    * method post
    * status 200
    * def recipeId = response.data.createRecipe.id
    * match recipeId == '#present'

    * request { query: '#(read("graphql/recipe-by-id.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data.recipe.name == 'test'
    * match response.data.recipe.method == null

    * request { query: '#(read("graphql/update-recipe.graphql"))', variables: { id: '#(recipeId)', value: { name: 'test2', method: 'cook it' } } }
    * method post
    * status 200

    * request { query: '#(read("graphql/recipe-by-id.graphql"))', variables: { id: '#(recipeId)' } }
    * method post
    * status 200
    * match response.data.recipe.name == 'test2'
    * match response.data.recipe.method == 'cook it'

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
    * match response.errors[0].message == '400: Bad Request'
    * match response.errors[0].extensions.response.body.message == 'Missing field value for name'
    * match response.errors[0].extensions.response.url contains '/recipes'

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
    * match response.errors[0].message == '400: Bad Request'
    * match response.errors[0].extensions.response.body.message == 'Missing field value for name'
    * match response.errors[0].extensions.response.url contains '/recipes'

    Examples:
      | name |
      | ''   |
      | null |
