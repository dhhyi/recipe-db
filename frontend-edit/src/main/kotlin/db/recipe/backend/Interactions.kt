package db.recipe.backend

import com.apollographql.apollo3.ApolloClient
import com.apollographql.apollo3.api.Error
import db.recipe.CreateRecipeMutation
import db.recipe.RecipeByIdQuery
import db.recipe.UpdateRecipeMutation
import db.recipe.type.RecipeInput
import kotlinx.coroutines.runBlocking

class Interactions {
  class ConfigurationException(message: String) : RuntimeException(message)

  class NoIDReturnedException : RuntimeException("No id returned")

  private var apolloClient: ApolloClient

  init {
    var endpoint = System.getenv("GRAPHQL_ENDPOINT")
    if (endpoint == null) {
      throw ConfigurationException("Please set the GRAPHQL_ENDPOINT system property")
    }
    apolloClient = ApolloClient.Builder().serverUrl(endpoint).build()
  }

  fun getRecipe(
      id: String,
      callback: (RecipeByIdQuery.Recipe?) -> Unit,
      errors: (List<Error>?) -> Unit
  ) {
    runBlocking<Unit> {
      val response = apolloClient.query(RecipeByIdQuery(id = id)).execute()

      if (response.hasErrors()) {
        errors(response.errors)
      } else {
        callback(response.data?.recipe)
      }
    }
  }

  fun createRecipe(
      recipe: RecipeInput,
      callback: (id: String) -> Unit,
      errors: (List<Error>?) -> Unit
  ) {
    runBlocking<Unit> {
      val response = apolloClient.mutation(CreateRecipeMutation(recipe)).execute()

      if (response.hasErrors()) {
        errors(response.errors)
      } else {
        callback(response.data?.createRecipe?.id ?: throw NoIDReturnedException())
      }
    }
  }

  fun updateRecipe(
      id: String,
      recipe: RecipeInput,
      callback: (id: String) -> Unit,
      errors: (List<Error>?) -> Unit
  ) {
    runBlocking<Unit> {
      val response = apolloClient.mutation(UpdateRecipeMutation(id, recipe)).execute()

      if (response.hasErrors()) {
        errors(response.errors)
      } else {
        callback(response.data?.updateRecipe?.id ?: throw NoIDReturnedException())
      }
    }
  }
}
