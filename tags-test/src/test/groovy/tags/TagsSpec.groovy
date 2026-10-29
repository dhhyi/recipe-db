package tags

import io.restassured.RestAssured
import io.restassured.response.Response
import spock.lang.Specification
import spock.lang.Unroll

import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

class TagsSpec extends Specification {
	static String api
	static String productionApi
	static String fixtureApi
	static String recipesApi

	def setupSpec() {
		api = requiredEnvironment('TAGS_API')
		productionApi = requiredEnvironment('TAGS_PRODUCTION_API')
		fixtureApi = requiredEnvironment('FIXTURE_API')
		recipesApi = requiredEnvironment('TAGS_RECIPES_API')
		waitForHealth(api)
		waitForHealth(productionApi)
		waitForHealth(recipesApi)
		waitForStatus("${fixtureApi}/tags.json", 200)
	}

	def setup() {
		assert http('DELETE', "${api}/tags").statusCode() == 204
		assert http('DELETE', "${api}/tags/").statusCode() == 204
	}

	private static Response http(String method, String url, Object body = null, String contentType = 'application/json') {
		def request = RestAssured.with().contentType(contentType)
		if (body != null) {
			request.body(body)
		}
		request.request(method, url)
	}

	private static String requiredEnvironment(String name) {
		String value = System.getenv(name)
		assert value != null && !value.isBlank(): "${name} must explicitly target an isolated test stack"
		value
	}

	private static void waitForHealth(String endpoint) {
		waitForStatus("${endpoint}/health", 204)
	}

	private static void waitForStatus(String endpoint, int expectedStatus) {
		long deadline = System.nanoTime() + 30_000_000_000L
		String lastResult = 'no response'
		while (System.nanoTime() < deadline) {
			try {
				int status = http('GET', endpoint).statusCode()
				lastResult = "HTTP ${status}"
				if (status == expectedStatus) {
					return
				}
			} catch (java.net.ConnectException error) {
				lastResult = error.message
			}
			Thread.sleep(250)
		}
		throw new AssertionError("Tags service did not become ready at ${endpoint}: ${lastResult}")
	}

	private static String segment(String value) {
		URLEncoder.encode(value, StandardCharsets.UTF_8).replace('+', '%20')
	}

	private static Response create(String category, String name, String base = api) {
		http('POST', "${base}/tags", [category: category, name: name])
	}

	private static Map seedProductionAssignment() {
		Response tag = create('course', 'Production seed', productionApi)
		assert tag.statusCode() == 201
		Map data = tag.jsonPath().getMap('')
		assert http('PUT', "${productionApi}/tags/recipes/production-recipe/assignments/${data.id}").statusCode() == 204
		data
	}

	def 'health and inventory responses use the documented shape and category order'() {
		given:
		def fixtureResponse = http('GET', "${fixtureApi}/tags.json")
		assert fixtureResponse.statusCode() == 200
		assert fixtureResponse.contentType().startsWith('application/json')
		fixtureResponse.jsonPath().getList('tags').each { Map entry ->
			assert create(entry.category as String, entry.name as String).statusCode() == 201
		}

		when:
		def health = http('GET', "${api}/health")
		def inventory = http('GET', "${api}/tags")
		def filtered = http('GET', "${api}/tags?category=dietary-style")
		def invalidFilter = http('GET', "${api}/tags?category=unknown")

		then:
		health.statusCode() == 204
		inventory.statusCode() == 200
		inventory.contentType().startsWith('application/json')
		inventory.jsonPath().getList('category') == [
			'cuisine',
			'dietary-style',
			'course'
		]
		inventory.jsonPath().getList('id').every { it ==~ /^(cuisine|dietary-style|course)-[a-z0-9]+$/ }
		inventory.jsonPath().getList('name').containsAll([
			'Thai',
			'Gluten-free',
			'Crème brûlée'
		])
		filtered.statusCode() == 200
		filtered.jsonPath().getList('category').every { it == 'dietary-style' }
		invalidFilter.statusCode() == 422
		invalidFilter.contentType().startsWith('application/problem+json')
		invalidFilter.jsonPath().getString('code') == 'invalid-category'
		invalidFilter.jsonPath().getString('field') == 'category'
	}

	@Unroll
	def 'normalized duplicate #existing and #duplicate returns collision without changing spelling'() {
		given:
		assert create('dietary-style', existing).statusCode() == 201

		when:
		def rejected = create('dietary-style', duplicate)
		def stored = http('GET', "${api}/tags").jsonPath().getList('')

		then:
		rejected.statusCode() == 409
		rejected.contentType().startsWith('application/problem+json')
		rejected.jsonPath().getString('code') == 'tag-collision'
		rejected.jsonPath().getString('field') == 'name'
		stored.size() == 1
		stored[0].name == existing
		stored[0].id == "dietary-style-${key}"
		stored[0].id.substring('dietary-style-'.length()) ==~ /^[a-z0-9]+$/

		where:
		existing       | duplicate      | key
		'Gluten-free'  | 'Gluten-free'  | 'glutenfree'
		'Gluten-free'  | 'gluten free'  | 'glutenfree'
		'Gluten_Free'  | 'glutenfree'   | 'glutenfree'
		'Straße'       | 'Strasse'      | 'strasse'
		'Crème brûlée' | 'Creme Brulee' | 'cremebrulee'
		'Café'         | 'Cafe\u0301'   | 'cafe'
	}

	def 'same identity key in different categories creates independent tags'() {
		when:
		def first = create('cuisine', 'Soup')
		def second = create('course', 'Soup')

		then:
		first.statusCode() == 201
		second.statusCode() == 201
		first.jsonPath().getString('id') == 'cuisine-soup'
		second.jsonPath().getString('id') == 'course-soup'
	}

	@Unroll
	def 'invalid display name #name is rejected without creating inventory'() {
		when:
		def response = create('course', name)

		then:
		response.statusCode() == 422
		response.contentType().startsWith('application/problem+json')
		response.jsonPath().getString('code') == 'invalid-tag-name'
		response.jsonPath().getString('field') == 'name'
		http('GET', "${api}/tags").jsonPath().getList('').isEmpty()

		where:
		name << [
			'',
			' \u00a0 ',
			'a' * 101,
			'!!!',
			'\u0301',
			'ø',
			'漢字',
			'caféø',
			'a\nb'
		]
	}

	def 'display names normalize Unicode whitespace and NFC while inventory sorts by display'() {
		when:
		def normalized = create('course', '\u00a0Cafe\u0301\u00a0')
		def punctuated = create('course', 'A-y')
		def symbol = create('course', 'A!z')
		def cuisine = create('cuisine', 'Thai')

		then:
		normalized.statusCode() == 201
		normalized.jsonPath().getString('name') == 'Café'
		normalized.jsonPath().getString('id') == 'course-cafe'
		punctuated.statusCode() == 201
		symbol.statusCode() == 201
		cuisine.statusCode() == 201
		http('GET', "${api}/tags").jsonPath().getList('name') == ['Thai', 'A!z', 'A-y', 'Café']
	}

	@Unroll
	def 'invalid bulk payload #payload preserves confirmed assignments'() {
		given:
		def tag = create('course', 'Kept').jsonPath().getMap('')
		String path = "${api}/tags/recipes/invalid-bulk"
		assert http('PUT', "${path}/assignments/${tag.id}").statusCode() == 204

		when:
		def rejected = http('PATCH', path, payload)

		then:
		rejected.statusCode() == 422
		rejected.contentType().startsWith('application/problem+json')
		rejected.jsonPath().getString('code') == code
		http('GET', path).jsonPath().getList('id') == [tag.id]

		when:
		def unchanged = http('PATCH', path, '{}')

		then:
		unchanged.statusCode() == 200
		unchanged.jsonPath().getList('id') == [tag.id]

		where:
		payload                                  | code
		'[]'                                     | 'invalid-request'
		'{"addTagIds":null}'                      | 'invalid-tag-ids'
		'{"addTagIds":"course-kept"}'              | 'invalid-tag-ids'
		'{"addTagIds":[1]}'                       | 'invalid-tag-ids'
		'{"removeTagIds":[""]}'                   | 'invalid-tag-ids'
		'{"removeTagIds":["course-missing"]}'     | 'unknown-tag'
		'{"addTagIds":[],"addTagIds":["bad"]}'     | 'invalid-request'
	}

	@Unroll
	def '#method #path rejects malformed input with #code'() {
		when:
		def response = http(method, "${api}${path}", body, mediaType)

		then:
		response.statusCode() == status
		response.contentType().startsWith('application/problem+json')
		response.jsonPath().getString('code') == code
		response.jsonPath().getString('field') == field

		where:
		method  | path              | body                                              | mediaType          | status | code                     | field
		'POST'  | '/tags'           | '{'                                               | 'application/json' | 400    | 'invalid-json'           | null
		'POST'  | '/tags'           | '{}'                                              | 'text/plain'       | 415    | 'unsupported-media-type' | null
		'POST'  | '/tags'           | [category: 'course']                              | 'application/json' | 422    | 'invalid-request'        | 'name'
		'POST'  | '/tags'           | [category: 'course', name: 'Pie', extra: true]      | 'application/json' | 422    | 'invalid-request'        | 'extra'
		'PATCH' | '/tags/recipes/r' | [addTagIds: null]                                 | 'application/json' | 422    | 'invalid-tag-ids'        | 'addTagIds'
		'PATCH' | '/tags/recipes/r' | [addTagIds: ['']]                                 | 'application/json' | 422    | 'invalid-tag-ids'        | 'addTagIds'
		'PATCH' | '/tags/recipes/r' | '{}'                                              | 'text/plain'       | 415    | 'unsupported-media-type' | null
		'PATCH' | '/tags/recipes/r' | [unexpected: true]                                | 'application/json' | 422    | 'invalid-request'        | 'unexpected'
	}

	def 'unknown routes and unsupported methods produce Problem Details'() {
		when:
		def unknown = http('POST', "${api}/unknown")
		def methodNotAllowed = http('PATCH', "${api}/tags")

		then:
		unknown.statusCode() == 404
		unknown.contentType().startsWith('application/problem+json')
		unknown.jsonPath().getString('code') == 'not-found'
		methodNotAllowed.statusCode() == 405
		methodNotAllowed.contentType().startsWith('application/problem+json')
		methodNotAllowed.header('Allow').contains('GET')
		methodNotAllowed.jsonPath().getString('code') == 'method-not-allowed'
	}

	def 'assignments support safely encoded opaque recipe IDs and idempotent changes'() {
		given:
		def tag = create('course', 'Main').jsonPath().getMap('')
		String recipeId = 'opaque recipe/with#symbols'
		String path = "${api}/tags/recipes/${segment(recipeId)}"
		String assignment = "${path}/assignments/${tag.id}"

		expect:
		http('PUT', assignment).statusCode() == 204
		http('PUT', assignment).statusCode() == 204

		when:
		def assigned = http('GET', path)

		then:
		assigned.statusCode() == 200
		assigned.jsonPath().getList('id') == [tag.id]
		http('DELETE', "${path}/assignments/course-missing").statusCode() == 204
		http('DELETE', assignment).statusCode() == 204
		http('DELETE', assignment).statusCode() == 204

		when:
		def empty = http('GET', path)
		def missing = http('PUT', "${path}/assignments/course-missing")

		then:
		empty.statusCode() == 200
		empty.jsonPath().getList('').isEmpty()
		missing.statusCode() == 404
		missing.jsonPath().getString('code') == 'tag-not-found'
		missing.jsonPath().getString('field') == 'tagId'
	}

	def 'bulk deltas are deduplicated atomic and return the full assignment set'() {
		given:
		def one = create('course', 'First').jsonPath().getMap('')
		def two = create('course', 'Second').jsonPath().getMap('')
		def path = "${api}/tags/recipes/recipe"

		when:
		def added = http('PATCH', path, [addTagIds: [one.id, one.id, two.id]])

		then:
		added.statusCode() == 200
		added.jsonPath().getList('id').toSet() == [one.id, two.id] as Set

		when:
		def failed = http('PATCH', path, [addTagIds: ['course-unknown'], removeTagIds: [one.id]])

		then:
		failed.statusCode() == 422
		failed.jsonPath().getString('code') == 'unknown-tag'
		failed.jsonPath().getString('field') == 'addTagIds'
		http('GET', path).jsonPath().getList('id').toSet() == [one.id, two.id] as Set

		when:
		def conflict = http('PATCH', path, [addTagIds: [one.id], removeTagIds: [one.id]])

		then:
		conflict.statusCode() == 422
		conflict.jsonPath().getString('code') == 'conflicting-tag-change'

		when:
		def removed = http('PATCH', path, [removeTagIds: [one.id, one.id, two.id]])

		then:
		removed.statusCode() == 200
		removed.jsonPath().getList('').isEmpty()
	}

	def 'delete rejects assigned inventory tags and succeeds when unused'() {
		given:
		def tag = create('cuisine', 'Thai').jsonPath().getMap('')
		assert http('PUT', "${api}/tags/recipes/r/assignments/${tag.id}").statusCode() == 204

		when:
		def inUse = http('DELETE', "${api}/tags/${tag.id}")
		def missing = http('DELETE', "${api}/tags/missing")

		then:
		inUse.statusCode() == 409
		inUse.jsonPath().getString('code') == 'tag-in-use'
		inUse.jsonPath().getString('field') == 'tagId'
		missing.statusCode() == 404
		missing.jsonPath().getString('code') == 'tag-not-found'
		http('DELETE', "${api}/tags/recipes/r/assignments/${tag.id}").statusCode() == 204
		http('DELETE', "${api}/tags/${tag.id}").statusCode() == 204
	}

	def 'ordinary recipe create and edit leave independent tag assignments unchanged'() {
		given:
		def created = http('POST', "${recipesApi}/recipes", [name: 'Tagged recipe', servings: 2])
		assert created.statusCode() == 201
		def recipe = created.jsonPath().getMap('')
		def tag = create('course', 'Main').jsonPath().getMap('')
		String assignments = "${api}/tags/recipes/${recipe.id}"
		assert http('PUT', "${assignments}/assignments/${tag.id}").statusCode() == 204

		when:
		def edited = http('PATCH', "${recipesApi}/recipes/${recipe.id}",
				[name: 'Edited recipe', servings: 4], 'application/merge-patch+json')
		def untagged = http('POST', "${recipesApi}/recipes", [name: 'Untagged recipe', servings: 1])
		def untaggedId = untagged.jsonPath().getString('id')

		then:
		edited.statusCode() == 200
		untagged.statusCode() == 201
		http('GET', assignments).jsonPath().getList('id') == [tag.id]
		http('GET', "${api}/tags/recipes/${untaggedId}").jsonPath().getList('').isEmpty()

		cleanup:
		if (recipe?.id) {
			assert http('DELETE', "${recipesApi}/recipes/${recipe.id}").statusCode() == 204
		}
		if (untaggedId) {
			assert http('DELETE', "${recipesApi}/recipes/${untaggedId}").statusCode() == 204
		}
	}

	def 'test reset clears inventory and assignments and production reset preserves data'() {
		given:
		def tag = create('course', 'Reset me').jsonPath().getMap('')
		assert http('PUT', "${api}/tags/recipes/r/assignments/${tag.id}").statusCode() == 204
		Map productionTag = seedProductionAssignment()

		expect:
		http('DELETE', "${api}/tags/").statusCode() == 204
		http('GET', "${api}/tags").jsonPath().getList('').isEmpty()
		http('GET', "${api}/tags/recipes/r").jsonPath().getList('').isEmpty()
		http('DELETE', "${api}/tags").statusCode() == 204

		when:
		def deniedTrailing = http('DELETE', "${productionApi}/tags/")
		def denied = http('DELETE', "${productionApi}/tags")

		then:
		deniedTrailing.statusCode() == 404
		deniedTrailing.contentType().startsWith('application/problem+json')
		deniedTrailing.jsonPath().getString('code') == 'not-found'
		denied.statusCode() == 404
		denied.jsonPath().getString('code') == 'not-found'
		http('GET', "${productionApi}/tags").jsonPath().getList('id') == [productionTag.id]
		http('GET', "${productionApi}/tags/recipes/production-recipe").jsonPath().getList('id') == [productionTag.id]

		cleanup:
		if (productionTag?.id) {
			assert http('DELETE', "${productionApi}/tags/recipes/production-recipe/assignments/${productionTag.id}").statusCode() == 204
			assert http('DELETE', "${productionApi}/tags/${productionTag.id}").statusCode() == 204
		}
	}

	def 'simultaneous normalized creates yield exactly one winner'() {
		given:
		def pool = Executors.newFixedThreadPool(12)
		def start = new CountDownLatch(1)
		def requests = (1..12).collect {
			pool.submit({
				start.await()
				create('dietary-style', 'Gluten-free').statusCode()
			} as Callable<Integer>)
		}

		when:
		start.countDown()
		def statuses = requests.collect { it.get() }
		pool.shutdown()

		then:
		statuses.count { it == 201 } == 1
		statuses.count { it == 409 } == 11
		http('GET', "${api}/tags").jsonPath().getList('').size() == 1

		cleanup:
		pool.shutdownNow()
	}

	def 'assignment and delete races never create dangling assignments'() {
		given:
		def tag = create('course', 'Race').jsonPath().getMap('')
		def pool = Executors.newFixedThreadPool(2)
		def start = new CountDownLatch(1)

		when:
		def assignment = pool.submit({
			start.await()
			http('PUT', "${api}/tags/recipes/race-recipe/assignments/${tag.id}").statusCode()
		} as Callable<Integer>)
		def deletion = pool.submit({
			start.await()
			http('DELETE', "${api}/tags/${tag.id}").statusCode()
		} as Callable<Integer>)
		start.countDown()
		int assignmentStatus = assignment.get()
		int deletionStatus = deletion.get()
		pool.shutdown()

		then:
		(assignmentStatus == 204 && deletionStatus == 409) ||
				(assignmentStatus == 404 && deletionStatus == 204)
		if (deletionStatus == 409) {
			assert http('GET', "${api}/tags/recipes/race-recipe").jsonPath().getList('id') == [tag.id]
		} else {
			assert http('GET', "${api}/tags/recipes/race-recipe").jsonPath().getList('').isEmpty()
		}

		cleanup:
		pool.shutdownNow()
	}
}
