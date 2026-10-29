package tags

import spock.lang.Unroll

class TagInventorySpec extends TagsApiSpec {
	static String fixtureApi

	def setupSpec() {
		fixtureApi = requiredEnvironment('FIXTURE_API')
		waitForStatus("${fixtureApi}/tags.json", 200)
	}

	def 'inventory responses use the documented shape and category order'() {
		given:
		def fixtureResponse = http('GET', "${fixtureApi}/tags.json")
		assert fixtureResponse.statusCode() == 200
		assert fixtureResponse.contentType().startsWith('application/json')
		fixtureResponse.jsonPath().getList('tags').each { Map entry ->
			assert create(entry.category as String, entry.name as String).statusCode() == 201
		}

		when:
		def inventory = http('GET', "${api}/tags")
		def filtered = http('GET', "${api}/tags?category=dietary-style")
		def invalidFilter = http('GET', "${api}/tags?category=unknown")

		then:
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
}
