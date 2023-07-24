package db.recipe

import com.apollographql.apollo3.api.Optional
import com.github.mvysny.karibudsl.v10.*
import com.vaadin.flow.component.button.Button
import com.vaadin.flow.component.checkbox.Checkbox
import com.vaadin.flow.component.orderedlayout.FlexLayout
import com.vaadin.flow.component.orderedlayout.VerticalLayout
import com.vaadin.flow.component.textfield.TextField
import db.recipe.type.IngredientInput
import kotlin.require

class Ingredients : VerticalLayout() {
  fun setIngredients(ingredients: List<RecipeByIdQuery.Ingredient>?) {
    if (ingredients == null || ingredients.isEmpty()) {
      addRow()
    } else {
      ingredients.forEach { addRow(it) }
    }
  }

  class Row : FlexLayout() {
    var deleteButton: Button
    private var amount: TextField
    private var unit: TextField
    private var name: TextField
    private var optional: Checkbox

    init {
      addClassName("ingredients")
      amount = textField { addClassName("ingredients-amount") }
      unit = textField { addClassName("ingredients-unit") }
      name = textField { addClassName("ingredients-ingredient") }
      optional = checkBox { addClassName("ingredients-optional") }
      deleteButton =
          iconButton(image("icons/trash.svg") { setWidth("24px") }) {
            addClassName("ingredients-remove")
            setThemeName("tertiary")
          }
    }

    fun setIngredient(data: RecipeByIdQuery.Ingredient) {
      amount.value = data.amount?.toString() ?: ""
      unit.value = data.unit ?: ""
      name.value = data.name
      optional.value = data.optional ?: false
    }

    fun getIngredient(): IngredientInput {
      require(name.value.isNotEmpty()) { "Name der Zutat darf nicht leer sein" }

      return IngredientInput(
          amount = Optional.presentIfNotNull(if (amount.value == "") null else amount.value),
          unit = Optional.presentIfNotNull(if (unit.value == "") null else unit.value),
          name = name.value,
          optional = Optional.presentIfNotNull(optional.value))
    }

    fun isEmpty(): Boolean = name.value.isEmpty()
  }

  private fun getRows(): List<Row> = children.filter { it is Row }.map { it as Row }.toList()

  private fun addRow(ingredient: RecipeByIdQuery.Ingredient? = null) {
    if (ingredient == null && getRows().any { it.isEmpty() }) {
      return
    }

    val row = Row()
    row.deleteButton.onLeftClick { remove(row) }
    if (ingredient != null) row.setIngredient(ingredient)
    add(row)
  }

  init {
    isPadding = false
    isSpacing = false
    nativeLabel("Zutaten")
    flexLayout {
      addClassName("ingredients")
      addClassName("ingredients-header")
      nativeLabel("Menge") { addClassName("ingredients-amount") }
      nativeLabel("Einheit") { addClassName("ingredients-unit") }
      nativeLabel("Zutat") { addClassName("ingredients-ingredient") }
      nativeLabel("Optional") { addClassName("ingredients-optional") }
      iconButton(image("icons/plus.svg") { setWidth("24px") }) {
        addClassName("ingredients-add")
        setThemeName("tertiary")
        onLeftClick { addRow() }
      }
    }
  }

  fun getIngredients(): List<IngredientInput> =
      getRows().filter { !it.isEmpty() }.map { it.getIngredient() }
}
