package db.recipe

import com.vaadin.flow.server.InputStreamFactory
import com.vaadin.flow.server.StreamResource

fun getInputStreamFactory(path: String): InputStreamFactory {
  return InputStreamFactory { Main::class.java.getResourceAsStream(path) }
}

val deleteIcon = StreamResource("trash.svg", getInputStreamFactory("/icons/trash.svg"))

val addIcon = StreamResource("plus.svg", getInputStreamFactory("/icons/plus.svg"))
