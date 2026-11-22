package tags

class TagRuntimeSpec extends TagsApiSpec {
	def 'testing reset clears inventory and assignments'() {
		given:
		def tag = create('course', 'Reset me').jsonPath().getMap('')
		assert http('PUT', "${api}/tags/recipes/r/assignments/${tag.id}").statusCode() == 204

		expect:
		http('GET', "${api}/health").statusCode() == 204
		http('DELETE', "${api}/tags/").statusCode() == 204
		http('GET', "${api}/tags").jsonPath().getList('').isEmpty()
		http('GET', "${api}/tags/recipes/r").jsonPath().getList('').isEmpty()
		http('DELETE', "${api}/tags").statusCode() == 204
	}
}
