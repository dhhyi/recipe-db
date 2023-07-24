package db.recipe

import com.github.mvysny.karibudsl.v10.*
import com.vaadin.flow.component.button.Button
import com.vaadin.flow.component.orderedlayout.FlexLayout
import com.vaadin.flow.component.orderedlayout.VerticalLayout
import com.vaadin.flow.component.textfield.TextField
import kotlin.streams.toList
import org.slf4j.LoggerFactory

class Inspirations : VerticalLayout() {
  private val logger = LoggerFactory.getLogger(Inspirations::class.java)

  fun setInspirations(inspirations: List<RecipeByIdQuery.Inspiration>?) {
    if (inspirations == null || inspirations.isEmpty()) {
      addRow()
    } else {
      inspirations.forEach { addRow(it.url) }
    }
  }

  class Row : FlexLayout() {
    var deleteButton: Button
    var text: TextField

    init {
      addClassName("inspirations")
      text = textField {}
      deleteButton =
          iconButton(image("icons/trash.svg") { setWidth("24px") }) {
            addClassName("inspirations-remove")
            setThemeName("tertiary")
          }
    }

    fun setUrl(url: String?) {
      text.value = url
    }

    fun getUrl(): String = text.value
  }

  private fun getRawData(): List<String> =
      children.filter { it is Row }.map { (it as Row).getUrl() }.toList()

  private fun addRow(url: String? = null) {
    if (url == null && getRawData().any { it.isEmpty() }) {
      return
    }

    val row = Row()
    row.deleteButton.onLeftClick { remove(row) }
    if (url != null) row.setUrl(url)
    add(row)
  }

  init {
    isPadding = false
    isSpacing = false
    flexLayout {
      addClassName("inspirations")
      nativeLabel("Inspirationen")
      iconButton(image("icons/plus.svg") { setWidth("24px") }) {
        addClassName("inspirations-add")
        setThemeName("tertiary")
        onLeftClick { addRow() }
      }
    }
  }

  fun getInspirations(): List<String> = getRawData().filter { it.isNotEmpty() }.map { it.trim() }
}
