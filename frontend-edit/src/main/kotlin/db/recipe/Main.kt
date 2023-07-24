package db.recipe

import com.github.mvysny.vaadinboot.VaadinBoot
import com.vaadin.flow.component.page.AppShellConfigurator
import com.vaadin.flow.theme.Theme

@Theme("my-theme") class Main : AppShellConfigurator

fun main() {
  val port = System.getenv("PORT")?.toInt() ?: 4000
  val boot = VaadinBoot().setPort(port).openBrowserInDevMode(false)
  val contextPath = System.getenv("CONTEXT_PATH")
  if (contextPath != null) {
    boot.withContextRoot(contextPath).run()
  } else {
    boot.run()
  }
}
