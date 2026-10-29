package tags

import spock.lang.Unroll

class TagHttpContractSpec extends TagsApiSpec {
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
}
