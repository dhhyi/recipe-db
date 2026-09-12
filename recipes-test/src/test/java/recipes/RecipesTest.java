package recipes;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.equalTo;
import static org.hamcrest.Matchers.hasItem;
import static org.hamcrest.Matchers.hasSize;
import static org.hamcrest.Matchers.matchesPattern;
import static org.hamcrest.Matchers.nullValue;
import static org.hamcrest.Matchers.startsWith;

import io.restassured.RestAssured;
import io.restassured.http.ContentType;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class RecipesTest {
  private static final String JSON = "application/json";
  private static final String MERGE_PATCH = "application/merge-patch+json";
  private static final String UUID_V4 = "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}";

  @BeforeAll
  static void configureApi() {
    RestAssured.baseURI = System.getenv()
        .getOrDefault("REST_API", "http://localhost:3000");
  }

  @BeforeEach
  void clearRecipes() {
    given().header("Connection", "close")
        .delete("/recipes")
        .then()
        .statusCode(204);

    given().header("Connection", "close")
        .get("/recipes")
        .then()
        .statusCode(200)
        .body("", hasSize(0));
  }

  private static String createRecipe(String body) {
    return given().header("Connection", "close")
        .contentType(ContentType.JSON)
        .body(body)
        .post("/recipes")
        .then()
        .statusCode(201)
        .contentType(startsWith("application/json"))
        .body("id", matchesPattern(UUID_V4))
        .extract()
        .path("id");
  }

  @Test
  void rejectsInvalidCreateRequests() {
    given().header("Connection", "close")
        .contentType(ContentType.JSON)
        .body("""
            {
              "id": "123",
              "name": "Rice Pudding",
              "servings": 4
            }
            """)
        .post("/recipes")
        .then()
        .statusCode(422)
        .contentType(startsWith("application/problem+json"))
        .body("status", equalTo(422))
        .body("code", equalTo("reserved-field"))
        .body("field", equalTo("id"));

    given().header("Connection", "close")
        .contentType(ContentType.JSON)
        .body("[\"Rice Pudding\"]")
        .post("/recipes")
        .then()
        .statusCode(400)
        .contentType(startsWith("application/problem+json"))
        .body("status", equalTo(400))
        .body("code", equalTo("invalid-json-object"));

    given().header("Connection", "close")
        .contentType(ContentType.JSON)
        .body("""
            {
              "name": "",
              "servings": 4
            }
            """)
        .post("/recipes")
        .then()
        .statusCode(422)
        .contentType(startsWith("application/problem+json"))
        .body("status", equalTo(422))
        .body("detail", equalTo("Missing field value for name"))
        .body("code", equalTo("required-field"))
        .body("field", equalTo("name"));

    given().header("Connection", "close")
        .contentType(ContentType.JSON)
        .body("{\"servings\":4}")
        .post("/recipes")
        .then()
        .statusCode(422)
        .contentType(startsWith("application/problem+json"))
        .body("status", equalTo(422))
        .body("detail", equalTo("Missing field value for name"))
        .body("code", equalTo("required-field"))
        .body("field", equalTo("name"));
  }

  @Test
  void appliesMergePatchAndValidatesPatchRequests() {
    String recipeId = createRecipe("""
        {
          "name": "Rice Pudding",
          "servings": 4,
          "metadata": {
            "source": "family",
            "season": "winter"
          }
        }
        """);

    given().header("Connection", "close")
        .contentType(MERGE_PATCH)
        .body("""
            {
              "id": "123",
              "servings": 6
            }
            """)
        .patch("/recipes/{id}", recipeId)
        .then()
        .statusCode(422)
        .contentType(startsWith("application/problem+json"))
        .body("status", equalTo(422))
        .body("code", equalTo("reserved-field"))
        .body("field", equalTo("id"));

    given().header("Connection", "close")
        .contentType(MERGE_PATCH)
        .body("{\"name\":\"\"}")
        .patch("/recipes/{id}", recipeId)
        .then()
        .statusCode(422)
        .contentType(startsWith("application/problem+json"))
        .body("status", equalTo(422))
        .body("detail", equalTo("Missing field value for name"))
        .body("code", equalTo("required-field"))
        .body("field", equalTo("name"));

    given().header("Connection", "close")
        .contentType(MERGE_PATCH)
        .body("{\"servings\":6}")
        .patch("/recipes/{id}", recipeId)
        .then()
        .statusCode(200)
        .body("name", equalTo("Rice Pudding"))
        .body("servings", equalTo(6));
  }

  @Test
  void createsReadsAndUpdatesARecipe() {
    String recipeId = createRecipe("""
        {
          "name": "Rice Pudding",
          "servings": 4,
          "metadata": {
            "source": "family",
            "season": "winter"
          }
        }
        """);

    given().header("Connection", "close")
        .get("/recipes")
        .then()
        .statusCode(200)
        .body("", hasSize(1))
        .body("name", hasItem("Rice Pudding"));

    given().header("Connection", "close")
        .get("/recipes/{id}", recipeId)
        .then()
        .statusCode(200)
        .body("id", equalTo(recipeId))
        .body("name", equalTo("Rice Pudding"))
        .body("servings", equalTo(4));

    given().header("Connection", "close")
        .contentType(MERGE_PATCH)
        .body("""
            {
              "name": "Rice Pudding with Cinnamon",
              "servings": null,
              "metadata": {
                "season": "autumn"
              },
              "steps": [
                "Make the rice pudding",
                "Add the cinnamon"
              ]
            }
            """)
        .patch("/recipes/{id}", recipeId)
        .then()
        .statusCode(200)
        .body("name", equalTo("Rice Pudding with Cinnamon"))
        .body("servings", nullValue())
        .body("metadata.source", equalTo("family"))
        .body("metadata.season", equalTo("autumn"))
        .body("steps", hasSize(2));

    given().header("Connection", "close")
        .get("/recipes/{id}", recipeId)
        .then()
        .statusCode(200)
        .body("name", equalTo("Rice Pudding with Cinnamon"))
        .body("servings", nullValue())
        .body("metadata.source", equalTo("family"))
        .body("metadata.season", equalTo("autumn"))
        .body("steps", hasSize(2));
  }

  @Test
  void deletesARecipe() {
    String recipeId = createRecipe("{\"name\":\"Rice Pudding\"}");

    given().header("Connection", "close")
        .delete("/recipes/{id}", recipeId)
        .then()
        .statusCode(204);

    given().header("Connection", "close")
        .get("/recipes/{id}", recipeId)
        .then()
        .statusCode(404)
        .contentType(startsWith("application/problem+json"))
        .body("code", equalTo("recipe-not-found"));

    given().header("Connection", "close")
        .get("/recipes")
        .then()
        .statusCode(200)
        .body("", hasSize(0));

    given().header("Connection", "close")
        .delete("/recipes/{id}", "unknown")
        .then()
        .statusCode(404)
        .body("code", equalTo("recipe-not-found"));
  }

}
