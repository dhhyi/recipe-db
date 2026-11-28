package recipes;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.equalTo;
import static org.hamcrest.Matchers.hasItem;
import static org.hamcrest.Matchers.hasKey;
import static org.hamcrest.Matchers.hasSize;
import static org.hamcrest.Matchers.matchesPattern;
import static org.hamcrest.Matchers.not;
import static org.hamcrest.Matchers.nullValue;
import static org.hamcrest.Matchers.startsWith;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.restassured.RestAssured;
import io.restassured.http.ContentType;
import java.time.Instant;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class RecipesTest {
  private static final String JSON = "application/json";
  private static final String MERGE_PATCH = "application/merge-patch+json";
  private static final String UUID_V4 = "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}";
  private static final String RFC3339_MICROSECONDS = "\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{6}Z";

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

  @Test
  void collectionHeadIsEmptyAndDoesNotLoadOrChangeRecipes() {
    given().header("Connection", "close")
        .head("/recipes")
        .then()
        .statusCode(204)
        .body(equalTo(""));

    given().header("Connection", "close")
        .get("/recipes")
        .then()
        .statusCode(200)
        .body("", hasSize(0));
  }

  @Test
  void collectionCreateAndTestingResetSupportBothRoutes() {
    for (String resetPath : new String[]{"/recipes", "/recipes/"}) {
      given().header("Connection", "close")
          .contentType(ContentType.JSON)
          .body("{\"name\":\"Rice Pudding\"}")
          .post("/recipes/")
          .then()
          .statusCode(201)
          .body("name", equalTo("Rice Pudding"));

      given().header("Connection", "close")
          .delete(resetPath)
          .then()
          .statusCode(204);

      given().header("Connection", "close")
          .get("/recipes")
          .then()
          .statusCode(200)
          .body("", hasSize(0));
    }
  }

  private static String createRecipe(String body) {
    var response = given().header("Connection", "close")
        .contentType(ContentType.JSON)
        .body(body)
        .post("/recipes")
        .then()
        .statusCode(201)
        .contentType(startsWith("application/json"))
        .body("id", matchesPattern(UUID_V4))
        .body("createdAt", matchesPattern(RFC3339_MICROSECONDS))
        .body("updatedAt", matchesPattern(RFC3339_MICROSECONDS))
        .extract()
        .response();
    assertEquals(response.jsonPath()
        .getString("createdAt"),
        response.jsonPath()
            .getString("updatedAt"));
    return response.path("id");
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

    for (String invalidName : new String[]{"\"  \"", "42"}) {
      given().header("Connection", "close")
          .contentType(ContentType.JSON)
          .body("{\"name\":" + invalidName + "}")
          .post("/recipes")
          .then()
          .statusCode(422)
          .contentType(startsWith("application/problem+json"))
          .body("code", equalTo("required-field"))
          .body("field", equalTo("name"));
    }

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
  void preservesNonStringIngredientAmountsForDirectCallers() {
    String recipeId = given().header("Connection", "close")
        .contentType(ContentType.JSON)
        .body("""
            {
              "name": "Schemaless amounts",
              "ingredients": [
                {"name": "numeric", "amount": 2},
                {"name": "object", "amount": {"quantity": 1}},
                {"name": "boolean", "amount": true}
              ]
            }
            """)
        .post("/recipes")
        .then()
        .statusCode(201)
        .body("ingredients[0].amount", equalTo(2))
        .body("ingredients[1].amount.quantity", equalTo(1))
        .body("ingredients[2].amount", equalTo(true))
        .extract()
        .path("id");

    given().header("Connection", "close")
        .contentType(MERGE_PATCH)
        .body("""
            {
              "ingredients": [
                {"name": "fraction", "amount": 0.5}
              ]
            }
            """)
        .patch("/recipes/{id}", recipeId)
        .then()
        .statusCode(200)
        .body("ingredients[0].amount", equalTo(0.5f));

    given().header("Connection", "close")
        .get("/recipes/{id}", recipeId)
        .then()
        .statusCode(200)
        .body("ingredients[0].amount", equalTo(0.5f));
  }

  @Test
  void rejectsClientSuppliedServerOwnedFieldsIncludingNull() {
    for (String field : new String[]{"createdAt", "updatedAt", "nameSortKey"}) {
      for (String value : new String[]{"null", "\"client value\""}) {
        given().header("Connection", "close")
            .contentType(ContentType.JSON)
            .body("{\"name\":\"Rice Pudding\",\"" + field + "\":" + value + "}")
            .post("/recipes")
            .then()
            .statusCode(422)
            .contentType(startsWith("application/problem+json"))
            .body("code", equalTo("reserved-field"))
            .body("field", equalTo(field));

        String recipeId = createRecipe("{\"name\":\"Rice Pudding\"}");
        var before = given().header("Connection", "close")
            .get("/recipes/{id}", recipeId)
            .then().statusCode(200).extract().jsonPath().getMap("$");
        given().header("Connection", "close")
            .contentType(MERGE_PATCH)
            .body("{\"" + field + "\":" + value + "}")
            .patch("/recipes/{id}", recipeId)
            .then()
            .statusCode(422)
            .contentType(startsWith("application/problem+json"))
            .body("code", equalTo("reserved-field"))
            .body("field", equalTo(field));
        assertEquals(before, given().header("Connection", "close")
            .get("/recipes/{id}", recipeId)
            .then().statusCode(200).extract().jsonPath().getMap("$"));
      }
    }
  }

  @Test
  void advancesUpdatedAtOnlyForEffectiveCoreChanges() throws InterruptedException {
    String recipeId = createRecipe("""
        {"name":"Rice Pudding","method":"Cook",
         "ingredients":[{"name":"Rice"},{"name":"Milk"}]}
        """);
    var created = given().header("Connection", "close")
        .get("/recipes/{id}", recipeId)
        .then().statusCode(200).extract().response();
    Thread.sleep(2);
    given().header("Connection", "close")
        .contentType(MERGE_PATCH)
        .body("{\"name\":\"Rice Pudding\",\"method\":\"Cook\",\"metadata\":{\"source\":\"family\"}}")
        .patch("/recipes/{id}", recipeId)
        .then().statusCode(200)
        .body("updatedAt", equalTo(created.path("updatedAt")));

    Thread.sleep(2);
    var reordered = given().header("Connection", "close")
        .contentType(MERGE_PATCH)
        .body("{\"ingredients\":[{\"name\":\"Milk\"},{\"name\":\"Rice\"}]}")
        .patch("/recipes/{id}", recipeId)
        .then().statusCode(200)
        .body("createdAt", equalTo(created.path("createdAt")))
        .extract().response();
    assertNotEquals(created.jsonPath().getString("updatedAt"),
        reordered.jsonPath().getString("updatedAt"));
    assertTrue(Instant.parse(reordered.jsonPath().getString("updatedAt"))
        .isAfter(Instant.parse(created.jsonPath().getString("updatedAt"))));

    Thread.sleep(2);
    var changed = given().header("Connection", "close")
        .contentType(MERGE_PATCH)
        .body("{\"ingredients\":[{\"name\":\"Milk\",\"optional\":true},{\"name\":\"Rice\"}]}")
        .patch("/recipes/{id}", recipeId)
        .then().statusCode(200).extract().response();
    assertNotEquals(reordered.jsonPath().getString("updatedAt"),
        changed.jsonPath().getString("updatedAt"));

    Thread.sleep(2);
    var cleared = given().header("Connection", "close")
        .contentType(MERGE_PATCH)
        .body("{\"method\":null}")
        .patch("/recipes/{id}", recipeId)
        .then().statusCode(200)
        .body("$", not(hasKey("method")))
        .body("createdAt", equalTo(created.path("createdAt")))
        .extract().response();
    assertNotEquals(changed.jsonPath().getString("updatedAt"),
        cleared.jsonPath().getString("updatedAt"));
  }

  @Test
  void rejectsUnsupportedWritesAndPreservesTheRecipe() {
    String recipeId = createRecipe("""
        {"name":"Rice Pudding","servings":4,"metadata":{"source":"family"}}
        """);
    var before = given().header("Connection", "close")
        .get("/recipes/{id}", recipeId)
        .then().statusCode(200).extract().jsonPath().getMap("$");

    given().header("Connection", "close")
        .contentType(ContentType.JSON)
        .body("{\"name\":\"Updated\"}")
        .patch("/recipes/{id}", recipeId)
        .then()
        .statusCode(415)
        .contentType(startsWith("application/problem+json"))
        .body("code", equalTo("unsupported-media-type"));
    assertEquals(before, given().header("Connection", "close")
        .get("/recipes/{id}", recipeId)
        .then().statusCode(200).extract().jsonPath().getMap("$"));

    given().header("Connection", "close")
        .contentType(ContentType.JSON)
        .body("{\"name\":\"Updated\"}")
        .put("/recipes/{id}", recipeId)
        .then()
        .statusCode(405)
        .header("Allow", equalTo("GET, PATCH, DELETE"))
        .contentType(startsWith("application/problem+json"))
        .body("code", equalTo("method-not-allowed"));
    assertEquals(before, given().header("Connection", "close")
        .get("/recipes/{id}", recipeId)
        .then().statusCode(200).extract().jsonPath().getMap("$"));
  }

  @Test
  void derivesNormalizedNameSortKeyWithoutChangingTimestamps() {
    String recipeId = createRecipe("{\"name\":\"  A\\u0308pfel ÖL Straße  \"}");
    var initial = given().header("Connection", "close")
        .get("/recipes/{id}", recipeId)
        .then()
        .statusCode(200)
        .body("name", equalTo("  A\u0308pfel ÖL Straße  "))
        .body("nameSortKey", equalTo("apfel ol strasse"))
        .extract()
        .response();

    given().header("Connection", "close")
        .get("/recipes")
        .then()
        .statusCode(200)
        .body("[0].nameSortKey", equalTo("apfel ol strasse"));

    given().header("Connection", "close")
        .contentType(MERGE_PATCH)
        .body("{\"metadata\":{\"source\":\"family\"}}")
        .patch("/recipes/{id}", recipeId)
        .then()
        .statusCode(200)
        .body("nameSortKey", equalTo("apfel ol strasse"))
        .body("createdAt", equalTo(initial.path("createdAt")))
        .body("updatedAt", equalTo(initial.path("updatedAt")));

    given().header("Connection", "close")
        .contentType(MERGE_PATCH)
        .body("{\"nameSortKey\":\"override\"}")
        .patch("/recipes/{id}", recipeId)
        .then()
        .statusCode(422)
        .body("code", equalTo("reserved-field"))
        .body("field", equalTo("nameSortKey"));

    given().header("Connection", "close")
        .get("/recipes/{id}", recipeId)
        .then()
        .statusCode(200)
        .body("nameSortKey", equalTo("apfel ol strasse"))
        .body("updatedAt", equalTo(initial.path("updatedAt")));
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

    var before = given().header("Connection", "close")
        .get("/recipes/{id}", recipeId)
        .then().statusCode(200).extract().jsonPath().getMap("$");

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
    assertEquals(before, given().header("Connection", "close")
        .get("/recipes/{id}", recipeId)
        .then().statusCode(200).extract().jsonPath().getMap("$"));

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
    assertEquals(before, given().header("Connection", "close")
        .get("/recipes/{id}", recipeId)
        .then().statusCode(200).extract().jsonPath().getMap("$"));

    given().header("Connection", "close")
        .contentType(MERGE_PATCH)
        .body("{\"name\":null,\"metadata\":{\"source\":\"changed\"}}")
        .patch("/recipes/{id}", recipeId)
        .then()
        .statusCode(422)
        .contentType(startsWith("application/problem+json"))
        .body("code", equalTo("required-field"))
        .body("field", equalTo("name"));
    assertEquals(before, given().header("Connection", "close")
        .get("/recipes/{id}", recipeId)
        .then().statusCode(200).extract().jsonPath().getMap("$"));

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
          },
          "steps": ["Original step", "Another step"]
        }
        """);

    var initial = given().header("Connection", "close")
        .get("/recipes/{id}", recipeId)
        .then()
        .statusCode(200)
        .body("createdAt", matchesPattern(RFC3339_MICROSECONDS))
        .body("updatedAt", matchesPattern(RFC3339_MICROSECONDS))
        .extract()
        .response();

    given().header("Connection", "close")
        .contentType(MERGE_PATCH)
        .body("{\"metadata\":{\"season\":\"autumn\"}}")
        .patch("/recipes/{id}", recipeId)
        .then()
        .statusCode(200)
        .body("createdAt", equalTo(initial.path("createdAt")))
        .body("updatedAt", equalTo(initial.path("updatedAt")));

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
        .body("createdAt", equalTo(initial.path("createdAt")))
        .body("updatedAt", equalTo(initial.path("updatedAt")))
        .body("servings", equalTo(4));

    var changed = given().header("Connection", "close")
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
        .body("createdAt", equalTo(initial.path("createdAt")))
        .body("updatedAt", matchesPattern(RFC3339_MICROSECONDS))
        .body("servings", nullValue())
        .body("$", not(hasKey("servings")))
        .body("metadata.source", equalTo("family"))
        .body("metadata.season", equalTo("autumn"))
        .body("steps", hasSize(2))
        .body("steps[0]", equalTo("Make the rice pudding"))
        .body("steps[1]", equalTo("Add the cinnamon"))
        .extract()
        .response();
    assertNotEquals(initial.jsonPath()
        .getString("updatedAt"),
        changed.jsonPath()
            .getString("updatedAt"));

    given().header("Connection", "close")
        .get("/recipes/{id}", recipeId)
        .then()
        .statusCode(200)
        .body("name", equalTo("Rice Pudding with Cinnamon"))
        .body("servings", nullValue())
        .body("metadata.source", equalTo("family"))
        .body("metadata.season", equalTo("autumn"))
        .body("createdAt", equalTo(initial.path("createdAt")))
        .body("updatedAt", equalTo(changed.path("updatedAt")))
        .body("steps", hasSize(2));

    var listed = given().header("Connection", "close")
        .get("/recipes")
        .then()
        .statusCode(200)
        .body("", hasSize(1))
        .extract().response();
    assertEquals(changed.jsonPath().getMap("$"), listed.jsonPath().getMap("[0]"));
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
