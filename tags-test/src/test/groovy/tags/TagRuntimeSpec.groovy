package tags

import io.restassured.response.Response

class TagRuntimeSpec extends TagsApiSpec {
	static String productionApi

	def setupSpec() {
		productionApi = requiredEnvironment('TAGS_PRODUCTION_API')
		waitForHealth(productionApi)
	}

	private static Map seedProductionAssignment() {
		Response tag = create('course', 'Production seed', productionApi)
		assert tag.statusCode() == 201
		Map data = tag.jsonPath().getMap('')
		assert http('PUT', "${productionApi}/tags/recipes/production-recipe/assignments/${data.id}").statusCode() == 204
		data
	}

	def 'test reset clears inventory and assignments and production reset preserves data'() {
		given:
		def tag = create('course', 'Reset me').jsonPath().getMap('')
		assert http('PUT', "${api}/tags/recipes/r/assignments/${tag.id}").statusCode() == 204
		Map productionTag = seedProductionAssignment()

		expect:
		http('GET', "${api}/health").statusCode() == 204
		http('GET', "${productionApi}/health").statusCode() == 204
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
}
