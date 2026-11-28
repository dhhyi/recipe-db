package tags

import groovy.json.JsonSlurper
import spock.lang.Unroll

class TagHttpContractSpec extends TagsApiSpec {
	@Unroll
	def '#method #path rejects malformed input with #code'() {
		when:
		def response = http(method, "${api}${path}", body, mediaType)

		then:
		response.statusCode() == status
		response.contentType().startsWith('application/problem+json')
		response.jsonPath().getString('type') == 'about:blank'
		response.jsonPath().getInt('status') == status
		response.jsonPath().getString('code') == code
		response.jsonPath().getString('field') == field

		where:
		method  | path              | body                                              | mediaType          | status | code                     | field
		'POST'  | '/tags'           | '{'                                               | 'application/json' | 400    | 'invalid-json'           | null
		'POST'  | '/tags'           | '{"category":"course","name":"A","name":"B"}'     | 'application/json' | 422    | 'invalid-request'        | 'name'
		'POST'  | '/tags'           | '{}'                                              | 'text/plain'       | 415    | 'unsupported-media-type' | null
		'POST'  | '/tags'           | [category: 'course']                              | 'application/json' | 422    | 'invalid-request'        | 'name'
		'POST'  | '/tags'           | [category: 'course', name: 'Pie', extra: true]      | 'application/json' | 422    | 'invalid-request'        | 'extra'
		'PATCH' | '/tags/recipes/r' | [addTagIds: null]                                 | 'application/json' | 422    | 'invalid-tag-ids'        | 'addTagIds'
		'PATCH' | '/tags/recipes/r' | [addTagIds: ['']]                                 | 'application/json' | 422    | 'invalid-tag-ids'        | 'addTagIds'
		'PATCH' | '/tags/recipes/r' | '{}'                                              | 'text/plain'       | 415    | 'unsupported-media-type' | null
		'PATCH' | '/tags/recipes/r' | [unexpected: true]                                | 'application/json' | 422    | 'invalid-request'        | 'unexpected'
	}

	@Unroll
	def 'GET rejects malformed encoded path #suffix'() {
		given:
		def endpoint = new URI(api)
		assert endpoint.scheme == 'http'
		int port = endpoint.port == -1 ? 80 : endpoint.port
		String basePath = endpoint.rawPath.replaceAll('/+$', '')

		when:
		// REST Assured encodes invalid percent escapes before sending.
		def response = new Socket().withCloseable { socket ->
			socket.connect(new InetSocketAddress(endpoint.host, port), 5000)
			socket.soTimeout = 5000
			socket.outputStream.write(("GET ${basePath}/tags/recipes/${suffix} HTTP/1.1\r\n" +
					"Host: ${endpoint.host}:${port}\r\nConnection: close\r\n\r\n").getBytes('US-ASCII'))
			socket.outputStream.flush()
			socket.inputStream.getText('UTF-8').split('\r\n\r\n', 2)
		}

		then:
		response[0].startsWith('HTTP/1.1 422 ')
		response[0].toLowerCase().contains('content-type: application/problem+json')
		def problem = new JsonSlurper().parseText(response[1])
		problem.type == 'about:blank'
		problem.status == 422
		problem.code == 'invalid-request'
		problem.detail == 'The URL contains an invalid encoded path segment.'

		where:
		suffix << ['%', '%GG', '%+1']
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
