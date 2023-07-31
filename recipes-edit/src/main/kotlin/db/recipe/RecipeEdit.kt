package db.recipe

import com.apollographql.apollo3.api.Optional
import com.github.mvysny.karibudsl.v10.*
import com.github.mvysny.kaributools.setPrimary
import com.vaadin.flow.component.button.Button
import com.vaadin.flow.component.notification.Notification
import com.vaadin.flow.component.notification.NotificationVariant
import com.vaadin.flow.component.textfield.TextArea
import com.vaadin.flow.component.textfield.TextField
import com.vaadin.flow.router.BeforeEvent
import com.vaadin.flow.router.HasUrlParameter
import com.vaadin.flow.router.Route
import db.recipe.backend.Interactions
import db.recipe.type.RecipeInput

@Route("")
class RecipeEdit : KComposite(), HasUrlParameter<String> {
  private val interaction = Interactions()

  private lateinit var idField: TextField
  private lateinit var nameField: TextField
  private val ingredients = Ingredients()
  private lateinit var methodField: TextArea
  private val inspirations = Inspirations()

  private lateinit var saveButton: Button
  private lateinit var cancelButton: Button

  private val root = ui {
    verticalLayout(classNames = "container") {
      idField =
          textField("ID") {
            addClassName("w-full")
            setReadOnly(true)
          }

      nameField = textField("Name") { addClassName("w-full") }

      add(ingredients)

      methodField = textArea("Anleitung") { addClassName("w-full") }

      add(inspirations)

      horizontalLayout {
        saveButton = button("Speichern") { setPrimary() }
        cancelButton = button("Abbrechen")
      }
    }
  }

  private fun objectToForm(recipe: RecipeByIdQuery.Recipe?) {
    if (recipe == null) {
      return
    }

    nameField.value = recipe.name
    ingredients.setIngredients(recipe.ingredients)
    methodField.value = recipe.method ?: ""
    inspirations.setInspirations(recipe.inspirations)
  }

  private fun formToObject(): RecipeInput {
    val nameRaw = nameField.value
    require(nameRaw != "") { "Fehler: Name darf nicht leer sein!" }
    val name = Optional.present(nameRaw)

    val methodField = if (methodField.value == "") null else methodField.value
    val method = Optional.presentIfNotNull(methodField)

    val inspirationsRaw = inspirations.getInspirations()
    val inspirations = Optional.present(inspirationsRaw)

    val ingredientsRaw = ingredients.getIngredients()
    val ingredients = Optional.present(ingredientsRaw)

    return RecipeInput(
        name = name, method = method, inspirations = inspirations, ingredients = ingredients)
  }

  override fun setParameter(event: BeforeEvent, recipeId: String?) {
    if (isCreate(recipeId)) {
      idField.setVisible(false)
      return
    } else {
      idField.value = recipeId
    }

    interaction.getRecipe(idField.value, { objectToForm(it) }, { showError("Error: $it") })
  }

  private fun isCreate(recipeId: String?): Boolean {
    return recipeId == "new" || recipeId == null || recipeId == ""
  }

  private fun getRedirectLocation(recipeId: String?): String {
    return if (isCreate(recipeId)) "/" else "/recipe/$recipeId"
  }

  private fun showError(message: String, duration: Int = 5000) {
    val n = Notification.show(message, duration, Notification.Position.MIDDLE)
    n.addThemeVariants(NotificationVariant.LUMO_ERROR)
  }

  private fun redirectBack(recipeId: String? = null) {
    ui.ifPresent { it.getPage().setLocation(getRedirectLocation(recipeId ?: idField.value)) }
  }

  private fun persistForm() {
    try {
      val value = formToObject()

      if (isCreate(idField.value)) {
        interaction.createRecipe(value, { redirectBack(it) }, { showError("Error: $it") })
      } else {
        interaction.updateRecipe(
            idField.value, value, { redirectBack(it) }, { showError("Error: $it") })
      }
    } catch (e: Exception) {
      showError(e.message ?: "Unbekannter Fehler der Klasse ${e.javaClass}")
    }
  }

  init {
    saveButton.onLeftClick { persistForm() }
    cancelButton.onLeftClick { redirectBack() }
  }
}
