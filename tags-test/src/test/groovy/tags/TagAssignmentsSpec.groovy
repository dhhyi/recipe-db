package tags

import spock.lang.Unroll

class TagAssignmentsSpec extends TagsApiSpec {
	static String recipesApi

	def setupSpec() {
		recipesApi = requiredEnvironment('TAGS_RECIPES_API')
		waitForHealth(recipesApi)
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
}
