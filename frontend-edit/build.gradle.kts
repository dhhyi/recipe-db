import org.gradle.api.tasks.testing.logging.TestExceptionFormat
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
  kotlin("jvm") version "1.9.0"
  id("application")
  id("com.vaadin") version "24.1.3"
  id("com.apollographql.apollo3") version "3.8.2"
  id("io.gitlab.arturbosch.detekt") version "1.23.0"
}

val karibudsl_version = "2.0.1"
val vaadin_version = "24.1.3"

defaultTasks("clean", "build")

repositories { mavenCentral() }

tasks.withType<Test> {
  useJUnitPlatform()
  testLogging {
    // to see the exceptions of failed tests in Travis-CI console.
    exceptionFormat = TestExceptionFormat.FULL
  }
}

dependencies {
  // Karibu-DSL dependency
  implementation("com.github.mvysny.karibudsl:karibu-dsl-v23:$karibudsl_version")

  // Vaadin
  implementation("com.vaadin:vaadin-core:${vaadin_version}") {
    afterEvaluate {
      if (vaadin.productionMode) {
        exclude(module = "vaadin-dev")
      }
    }
  }
  implementation("com.github.mvysny.vaadin-boot:vaadin-boot:11.3")

  // logging
  // currently we are logging through the SLF4J API to SLF4J-Simple. See
  // src/main/resources/simplelogger.properties file for the logger configuration
  implementation("org.slf4j:slf4j-simple:2.0.6")

  implementation(kotlin("stdlib-jdk8"))

  implementation("com.apollographql.apollo3:apollo-runtime:3.8.2")

  // test support
  testImplementation("com.github.mvysny.kaributesting:karibu-testing-v24:2.1.0")
  testImplementation("com.github.mvysny.dynatest:dynatest:0.24")
}

tasks.withType<KotlinCompile> {
  kotlinOptions.jvmTarget = "17"
  kotlinOptions.allWarningsAsErrors = true
}

java {
  sourceCompatibility = JavaVersion.VERSION_17
  targetCompatibility = JavaVersion.VERSION_17
}

apollo { service("service") { packageName.set("db.recipe") } }

detekt { config.setFrom("detekt.yml") }

application { mainClass.set("db.recipe.MainKt") }
