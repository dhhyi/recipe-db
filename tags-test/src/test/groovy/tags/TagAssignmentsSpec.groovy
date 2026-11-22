package tags

import spock.lang.Unroll

class TagAssignmentsSpec extends TagsApiSpec {
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

	def 'OTHER tags can be assigned and returned for recipes'() {
		given:
		def tag = create('other', 'General').jsonPath().getMap('')
		String path = "${api}/tags/recipes/other-category"

		when:
		def assigned = http('PUT', "${path}/assignments/${tag.id}")
		def recipeTags = http('GET', path)

		then:
		assigned.statusCode() == 204
		recipeTags.statusCode() == 200
		recipeTags.jsonPath().getList('id') == [tag.id]
		recipeTags.jsonPath().getString('category[0]') == 'other'
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
}
