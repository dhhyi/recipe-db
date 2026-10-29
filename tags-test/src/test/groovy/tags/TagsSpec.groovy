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

import static io.restassured.RestAssured.given
import static org.hamcrest.Matchers.*

class TagsSpec extends Specification {
	static String api
	static String productionApi
	static String fixtureApi

	def setupSpec() {
		api = requiredEnvironment('TAGS_API')
		productionApi = requiredEnvironment('TAGS_PRODUCTION_API')
		fixtureApi = requiredEnvironment('FIXTURE_API')
		RestAssured.enableLoggingOfRequestAndResponseIfValidationFails()
		waitForHealth(api)
		waitForHealth(productionApi)
		waitForStatus("${fixtureApi}/tags.json", 200)
	}

	def setup() {
		given().delete("${api}/tags").then().statusCode(204)
		given().delete("${api}/tags/").then().statusCode(204)
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
		while (System.nanoTime() < deadline) {
			try {
				if (given().get(endpoint).statusCode() == expectedStatus) {
					return
				}
			} catch (Exception ignored) {
			}
			Thread.sleep(250)
		}
		throw new AssertionError("Tags service did not become ready at ${endpoint}")
	}

	private static String segment(String value) {
		URLEncoder.encode(value, StandardCharsets.UTF_8).replace('+', '%20')
	}

	private static Response create(String category, String name, String base = api) {
		given()
				.contentType('application/json')
				.body([category: category, name: name])
				.post("${base}/tags")
	}

	private static Map seedProductionAssignment() {
		Response tag = create('course', 'Production seed', productionApi)
		assert tag.statusCode() == 201
		Map data = tag.jsonPath().getMap('')
		assert given()
		.put("${productionApi}/tags/recipes/production-recipe/assignments/${data.id}")
		.statusCode() == 204
		data
	}

	def 'health and inventory responses use the documented shape and category order'() {
		given().get("${api}/health").then().statusCode(204)

		def fixture = given().get("${fixtureApi}/tags.json")
				.then().statusCode(200).contentType('application/json')
				.extract().jsonPath().getList('tags')

		fixture.each { Map entry ->
			assert create(entry.category as String, entry.name as String).statusCode() == 201
		}

		given().get("${api}/tags").then()
				.statusCode(200)
				.contentType('application/json')
				.body('category', [
					'cuisine',
					'dietary-style',
					'course'
				])
				.body('id', everyItem(matchesPattern('^(cuisine|dietary-style|course)-[a-z0-9]+$')))
				.body('name', hasItems('Thai', 'Gluten-free', 'Crème brûlée'))
		given().get("${api}/tags?category=dietary-style").then()
				.statusCode(200)
				.body('category', everyItem(equalTo('dietary-style')))
		given().get("${api}/tags?category=unknown").then()
				.statusCode(422)
				.contentType('application/problem+json')
				.body('code', equalTo('invalid-category'))
				.body('field', equalTo('category'))
	}

	@Unroll
	def 'normalized duplicate #existing and #duplicate returns collision without changing spelling'() {
		expect:
		create('dietary-style', existing).statusCode() == 201
		def rejected = create('dietary-style', duplicate)
		rejected.statusCode() == 409
		rejected.contentType().startsWith('application/problem+json')
		rejected.jsonPath().getString('code') == 'tag-collision'
		rejected.jsonPath().getString('field') == 'name'
		def stored = given().get("${api}/tags").jsonPath().getList('')
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
		given().get("${api}/tags").jsonPath().getList('').isEmpty()

		where:
		name << [
			'!!!',
			'\u0301',
			'ø',
			'漢字',
			'caféø',
			'a\nb'
		]
	}

	def 'malformed JSON media type and object shapes produce Problem Details'() {
		expect:
		given().contentType('application/json').body('{').post("${api}/tags").then()
				.statusCode(400).contentType('application/problem+json').body('code', equalTo('invalid-json'))
		given().contentType('text/plain').body('{}').post("${api}/tags").then()
				.statusCode(415).body('code', equalTo('unsupported-media-type'))
		given().contentType('application/json').body([category: 'course']).post("${api}/tags").then()
		.statusCode(422).body('code', equalTo('invalid-request')).body('field', equalTo('name'))
		given().contentType('application/json').body([category: 'course', name: 'Pie', extra: true]).post("${api}/tags").then()
		.statusCode(422).body('field', equalTo('extra'))
		given().contentType('application/json').body([category: 'course', name: 'Pie']).post("${api}/tags").statusCode() == 201
		given().contentType('application/json').body([addTagIds: null]).patch("${api}/tags/recipes/r").then()
		.statusCode(422).body('code', equalTo('invalid-tag-ids')).body('field', equalTo('addTagIds'))
		given().contentType('application/json').body([addTagIds: ['']]).patch("${api}/tags/recipes/r").then()
		.statusCode(422).body('code', equalTo('invalid-tag-ids')).body('field', equalTo('addTagIds'))
		given().contentType('text/plain').body('{}').patch("${api}/tags/recipes/r").then()
				.statusCode(415).body('code', equalTo('unsupported-media-type'))
		given().contentType('application/json').body([unexpected: true]).patch("${api}/tags/recipes/r").then()
		.statusCode(422).body('code', equalTo('invalid-request'))
		given().post("${api}/unknown").then().statusCode(404)
				.contentType('application/problem+json').body('code', equalTo('not-found'))
		def methodNotAllowed = given().patch("${api}/tags")
		methodNotAllowed.then()
				.statusCode(405)
				.contentType('application/problem+json')
				.header('Allow', containsString('GET'))
				.body('code', equalTo('method-not-allowed'))
	}

	def 'assignments support safely encoded opaque recipe IDs and idempotent changes'() {
		given:
		def tag = create('course', 'Main').jsonPath().getMap('')
		String recipeId = 'opaque recipe/with#symbols'
		String path = "${api}/tags/recipes/${segment(recipeId)}"
		String assignment = "${path}/assignments/${tag.id}"

		expect:
		given().put(assignment).statusCode() == 204
		given().put(assignment).statusCode() == 204
		given().get(path).then().statusCode(200).body('id', contains(tag.id))
		given().delete("${path}/assignments/course-missing").statusCode() == 204
		given().delete(assignment).statusCode() == 204
		given().delete(assignment).statusCode() == 204
		given().get(path).then().statusCode(200).body('', empty())
		given().put("${path}/assignments/course-missing").then()
				.statusCode(404).body('code', equalTo('tag-not-found')).body('field', equalTo('tagId'))
	}

	def 'bulk deltas are deduplicated atomic and return the full assignment set'() {
		given:
		def one = create('course', 'First').jsonPath().getMap('')
		def two = create('course', 'Second').jsonPath().getMap('')
		def path = "${api}/tags/recipes/recipe"

		when:
		def added = given().contentType('application/json')
				.body([addTagIds: [one.id, one.id, two.id]])
				.patch(path)

		then:
		added.statusCode() == 200
		added.jsonPath().getList('id').toSet() == [one.id, two.id] as Set

		when:
		def failed = given().contentType('application/json')
				.body([addTagIds: ['course-unknown'], removeTagIds: [one.id]])
				.patch(path)

		then:
		failed.statusCode() == 422
		failed.jsonPath().getString('code') == 'unknown-tag'
		failed.jsonPath().getString('field') == 'addTagIds'
		given().get(path).jsonPath().getList('id').toSet() == [one.id, two.id] as Set

		when:
		def conflict = given().contentType('application/json')
				.body([addTagIds: [one.id], removeTagIds: [one.id]])
				.patch(path)

		then:
		conflict.statusCode() == 422
		conflict.jsonPath().getString('code') == 'conflicting-tag-change'

		when:
		def removed = given().contentType('application/json')
				.body([removeTagIds: [one.id, one.id, two.id]])
				.patch(path)

		then:
		removed.statusCode() == 200
		removed.jsonPath().getList('').isEmpty()
	}

	def 'delete rejects assigned inventory tags and succeeds when unused'() {
		given:
		def tag = create('cuisine', 'Thai').jsonPath().getMap('')
		given().put("${api}/tags/recipes/r/assignments/${tag.id}").statusCode() == 204

		expect:
		given().delete("${api}/tags/${tag.id}").then()
				.statusCode(409).body('code', equalTo('tag-in-use')).body('field', equalTo('tagId'))
		given().delete("${api}/tags/missing").then()
				.statusCode(404).body('code', equalTo('tag-not-found'))
		given().delete("${api}/tags/recipes/r/assignments/${tag.id}").statusCode() == 204
		given().delete("${api}/tags/${tag.id}").statusCode() == 204
	}

	def 'test reset clears inventory and assignments and production reset preserves data'() {
		given:
		def tag = create('course', 'Reset me').jsonPath().getMap('')
		given().put("${api}/tags/recipes/r/assignments/${tag.id}").statusCode() == 204
		Map productionTag = seedProductionAssignment()

		expect:
		given().delete("${api}/tags/").statusCode() == 204
		given().get("${api}/tags").jsonPath().getList('').isEmpty()
		given().get("${api}/tags/recipes/r").jsonPath().getList('').isEmpty()
		given().delete("${api}/tags").statusCode() == 204

		def denied = given().delete("${productionApi}/tags/")
		denied.statusCode() == 404
		denied.contentType().startsWith('application/problem+json')
		denied.jsonPath().getString('code') == 'not-found'
		given().delete("${productionApi}/tags").then()
				.statusCode(404).body('code', equalTo('not-found'))
		given().get("${productionApi}/tags").jsonPath().getList('id') == [productionTag.id]
		given().get("${productionApi}/tags/recipes/production-recipe")
				.jsonPath().getList('id') == [productionTag.id]
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
		given().get("${api}/tags").jsonPath().getList('').size() == 1
	}

	def 'assignment and delete races never create dangling assignments'() {
		given:
		def tag = create('course', 'Race').jsonPath().getMap('')
		def pool = Executors.newFixedThreadPool(2)
		def start = new CountDownLatch(1)

		when:
		def assignment = pool.submit({
			start.await()
			given().put("${api}/tags/recipes/race-recipe/assignments/${tag.id}").statusCode()
		} as Callable<Integer>)
		def deletion = pool.submit({
			start.await()
			given().delete("${api}/tags/${tag.id}").statusCode()
		} as Callable<Integer>)
		start.countDown()
		int assignmentStatus = assignment.get()
		int deletionStatus = deletion.get()
		pool.shutdown()

		then:
		(assignmentStatus == 204 && deletionStatus == 409) ||
				(assignmentStatus == 404 && deletionStatus == 204)
		if (deletionStatus == 409) {
			given().get("${api}/tags/recipes/race-recipe").jsonPath().getList('id') == [tag.id]
		} else {
			given().get("${api}/tags/recipes/race-recipe").jsonPath().getList('').isEmpty()
		}
	}
}
