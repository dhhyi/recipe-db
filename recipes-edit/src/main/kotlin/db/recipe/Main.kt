package db.recipe

import org.springframework.boot.Banner
import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.runApplication

@SpringBootApplication open class Main

fun main(args: Array<String>) {
  val port = System.getenv("PORT") ?: "4000"

  val contextPath = System.getenv("CONTEXT_PATH")
  if (contextPath != null) {
    System.setProperty("vaadin.urlMapping", "$contextPath/*")
  }

  runApplication<Main>(*args) {
    setBannerMode(Banner.Mode.OFF)
    setDefaultProperties(mapOf("server.port" to port))
  }
}
