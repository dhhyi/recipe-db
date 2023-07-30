import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
  kotlin("jvm") version "1.9.0"
  id("application")
  id("com.vaadin") version "24.1.3"
  id("com.apollographql.apollo3") version "3.8.2"
  id("io.gitlab.arturbosch.detekt") version "1.23.0"
  id("org.springframework.boot") version "3.0.2"
}

val karibudsl_version = "2.0.1"
val vaadin_version = "24.1.3"

defaultTasks("clean", "build")

repositories { mavenCentral() }

dependencies {
  implementation("com.github.mvysny.karibudsl:karibu-dsl-v23:$karibudsl_version")

  implementation("com.vaadin:vaadin-core:${vaadin_version}") {
    afterEvaluate {
      if (vaadin.productionMode) {
        exclude(module = "vaadin-dev")
      }
    }
  }
  implementation("com.vaadin:vaadin-spring-boot-starter:${vaadin_version}")
  developmentOnly("org.springframework.boot:spring-boot-devtools:3.0.2")
  implementation("org.springframework.boot:spring-boot-starter-actuator:3.0.2")

  implementation(kotlin("stdlib-jdk8"))

  implementation("com.apollographql.apollo3:apollo-runtime:3.8.2")
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
