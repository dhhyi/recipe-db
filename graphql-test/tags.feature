Feature: tags

  Background:
    * def graphqlApi = java.lang.System.getenv('GRAPHQL_API')
    * call read('graphql/reset-testing-data.feature')
    * url graphqlApi
    * configure headers = { Authorization: '#(ownerAuthorization)' }

  Scenario: OTHER tags can be created, filtered, assigned, and returned through GraphQL
    * def tagName = 'Other category ' + java.util.UUID.randomUUID()
    * request
      """
      {
        query: 'mutation($category: TagCategory!, $name: String!) { createTag(category: $category, name: $name) { id category name } }',
        variables: { category: 'OTHER', name: '#(tagName)' }
      }
      """
    * method post
    * status 200
    * match response.data.createTag == { id: '#present', category: 'OTHER', name: '#(tagName)' }
    * def otherTag = response.data.createTag

    * request
      """
      {
        query: 'query($category: TagCategory) { tags(category: $category) { id category name } }',
        variables: { category: 'OTHER' }
      }
      """
    * method post
    * status 200
    * assert response.data.tags.some(tag => tag.id == otherTag.id)
    * assert response.data.tags.every(tag => tag.category == 'OTHER')

    * def recipeName = 'OTHER category recipe ' + java.lang.System.nanoTime()
    * request
      """
      {
        query: 'mutation($value: RecipeInput!) { createRecipe(value: $value) { id } }',
        variables: { value: { name: '#(recipeName)' } }
      }
      """
    * method post
    * status 200
    * def recipeId = response.data.createRecipe.id

    * request
      """
      {
        query: 'mutation($recipeId: ID!, $tagId: ID!) { addRecipeTag(recipeId: $recipeId, tagId: $tagId) }',
        variables: { recipeId: '#(recipeId)', tagId: '#(otherTag.id)' }
      }
      """
    * method post
    * status 200
    * match response.data.addRecipeTag == true

    * request
      """
      {
        query: 'mutation($recipeId: ID!, $value: RecipeInput!) { updateRecipe(id: $recipeId, value: $value) { id name } }',
        variables: { recipeId: '#(recipeId)', value: { name: 'Edited OTHER category recipe' } }
      }
      """
    * method post
    * status 200
    * match response.data.updateRecipe == { id: '#(recipeId)', name: 'Edited OTHER category recipe' }

    * request
      """
      {
        query: 'query($id: ID!) { recipe(id: $id) { tags { id category name } } }',
        variables: { id: '#(recipeId)' }
      }
      """
    * method post
    * status 200
    * match response.data.recipe.tags == [{ id: '#(otherTag.id)', category: 'OTHER', name: '#(tagName)' }]

    * def untaggedRecipeName = 'Untagged recipe ' + java.lang.System.nanoTime()
    * request
      """
      {
        query: 'mutation($value: RecipeInput!) { createRecipe(value: $value) { id } }',
        variables: { value: { name: '#(untaggedRecipeName)' } }
      }
      """
    * method post
    * status 200
    * def untaggedRecipeId = response.data.createRecipe.id

    * request
      """
      {
        query: 'query($id: ID!) { recipe(id: $id) { tags { id category name } } }',
        variables: { id: '#(untaggedRecipeId)' }
      }
      """
    * method post
    * status 200
    * match response.data.recipe.tags == []
