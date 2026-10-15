import json
import uuid

from behave import given, then, when

from search_support import REST, publish, request, wait_for


def recipe_ids(context, recipes):
    return [context.recipes[name.strip()] for name in recipes.split(",")]


def search(context, **options):
    context.options = options
    context.result = context.client.search(**options)


def eventually(context, predicate):
    def matches():
        context.result = context.client.search(**context.options)
        return predicate(context.result["recipeIds"])

    try:
        wait_for(matches)
    except AssertionError as error:
        raise AssertionError(f"{error}; last search response: {context.result!r}") from error


@given("the search service is ready")
def service_ready(context):
    wait_for(lambda: context.client.status()["ready"])


@given("these recipes exist in an isolated test scope:")
@when("these recipes exist in an isolated test scope:")
def create_recipes(context):
    for row in context.table:
        context.recipes[row["recipe"]] = context.client.create(
            row["name"], row["ingredient"], int(row["rating"]))


@given("all scoped recipes have been indexed")
def recipes_indexed(context):
    wait_for(lambda: set(context.client.search()["recipeIds"]) == set(context.client.ids))


@when('I search for "{query}"')
def search_query(context, query):
    search(context, q=query)


@when("I search with options:")
def search_options(context):
    search(context, **json.loads(context.text))


@when("I search all scoped recipes")
def search_all(context):
    search(context)


@when("I search for scoped recipes with images")
def search_with_images(context):
    search(context, filter_by=context.client.filter + " && has_image:=true")


@when("I search for scoped recipes without images")
def search_without_images(context):
    search(context, filter_by=context.client.filter + " && has_image:=false")


@then('the results are exactly "{recipes}"')
def results_exactly(context, recipes):
    expected = recipe_ids(context, recipes)
    assert context.result["recipeIds"] == expected, (context.result, expected)


@then("the results are empty")
def results_empty(context):
    assert context.result["recipeIds"] == [], context.result


@then('the results contain exactly "{recipes}" in any order')
def results_unordered(context, recipes):
    expected = recipe_ids(context, recipes)
    actual = context.result["recipeIds"]
    assert sorted(actual) == sorted(expected), (context.result, expected)


@then('eventually the results are exactly "{recipes}"')
def eventually_exactly(context, recipes):
    expected = recipe_ids(context, recipes)
    eventually(context, lambda actual: actual == expected)


@then("eventually the results are empty")
def eventually_empty(context):
    eventually(context, lambda actual: actual == [])


@then('eventually the results contain none of "{recipes}"')
def eventually_excludes(context, recipes):
    excluded = set(recipe_ids(context, recipes))
    eventually(context, lambda actual: excluded.isdisjoint(actual))


@then('eventually the results include "{recipes}"')
def eventually_includes(context, recipes):
    expected = set(recipe_ids(context, recipes))
    eventually(context, lambda actual: expected.issubset(actual))


@then("the response has exactly these fields:")
def response_fields(context):
    expected = {row["field"] for row in context.table}
    assert set(context.result) == expected, (context.result, expected)


@then("the response contains:")
def response_contains(context):
    for field, expected in json.loads(context.text).items():
        assert context.result[field] == expected, (field, context.result, expected)


@then("outOf is at least {minimum:d}")
def response_out_of(context, minimum):
    assert context.result["outOf"] >= minimum, context.result


@then('the ingredient facet counts "{ingredient}" {count:d} times')
def ingredient_facet(context, ingredient, count):
    facet, = context.result["facetCounts"]
    assert facet["field_name"] == "ingredients", facet
    counts = {entry["value"]: entry["count"] for entry in facet["counts"]}
    assert counts[ingredient] == count, counts


@then("the response contains no highlights")
def no_highlights(context):
    assert "highlights" not in json.dumps(context.result), context.result


@when('I update "{recipe}" through GraphQL:')
def update_recipe(context, recipe):
    context.client.update(context.recipes[recipe], json.loads(context.text))


@when('I delete "{recipe}" through GraphQL')
def delete_recipe(context, recipe):
    assert context.client.delete(context.recipes[recipe]), recipe


@when('I publish the same change event twice for "{recipe}"')
def duplicate_event(context, recipe):
    event_id = str(uuid.uuid4())
    publish(context.recipes[recipe], event_id=event_id)
    publish(context.recipes[recipe], event_id=event_id)


@when('I publish a new change event for "{recipe}"')
def change_event(context, recipe):
    publish(context.recipes[recipe])


@when('I publish a deletion event for the existing recipe "{recipe}"')
def deletion_event(context, recipe):
    publish(context.recipes[recipe], "recipe.deleted")


@when("all search events have been acknowledged")
def events_acknowledged(context):
    def drained():
        status = context.client.status()
        return status["pendingMessages"] == 0 and status["outstandingAcks"] == 0
    wait_for(drained)


@when('I give "{recipe}" a unique inspiration URL')
def add_inspiration(context, recipe):
    context.inspiration_url = "https://example.org/" + context.client.scope
    context.client.update(context.recipes[recipe], {"inspirations": [context.inspiration_url]})


@when("I search for that inspiration URL")
def search_inspiration(context):
    search(context, q=context.inspiration_url, query_by="inspiration_urls")


@when('I upload the fixture image to "{recipe}" through GraphQL')
def upload_image(context, recipe):
    context.client.upload_image(context.recipes[recipe])


@when('I update "{recipe}" directly through REST:')
def rest_update(context, recipe):
    status, raw, _ = request(REST + "/recipes/" + context.recipes[recipe], "PATCH",
                             json.loads(context.text), "application/merge-patch+json")
    assert status == 200, (status, raw)


@when('I delete "{recipe}" directly through REST')
def rest_delete(context, recipe):
    status, raw, _ = request(REST + "/recipes/" + context.recipes[recipe], "DELETE")
    assert status == 204, (status, raw)


@when('I create "{recipe}" directly through REST:')
def rest_create(context, recipe):
    value = json.loads(context.text)
    value.setdefault("ingredients", []).append({"name": context.client.scope})
    status, raw, _ = request(REST + "/recipes", "POST", value)
    assert status == 201, (status, raw)
    recipe_id = json.loads(raw)["id"]
    context.client.ids.append(recipe_id)
    context.recipes[recipe] = recipe_id


@when("I start rebuilding the search index")
def start_rebuild(context):
    context.first_job = context.client.start_rebuild()


@when("I rebuild the search index successfully")
def rebuild(context):
    context.client.finish_rebuild(context.client.start_rebuild())


@when("the first rebuild finishes successfully")
def first_rebuild_completed(context):
    context.client.finish_rebuild(context.first_job)


@when("I send a search request with invalid options:")
def invalid_search(context):
    context.status, raw, context.headers = request(
        REST + "/search", "POST", json.loads(context.text))
    context.result = json.loads(raw)


@then('the response is HTTP {status:d} with content type "{content_type}"')
def response_status(context, status, content_type):
    assert context.status == status, (context.status, context.result)
    assert context.headers["Content-Type"] == content_type, context.headers
