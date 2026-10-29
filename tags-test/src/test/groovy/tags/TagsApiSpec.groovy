package tags

import io.restassured.RestAssured
import io.restassured.response.Response
import spock.lang.Specification

import java.net.URLEncoder
import java.nio.charset.StandardCharsets

abstract class TagsApiSpec extends Specification {
	static String api

	def setupSpec() {
		api = requiredEnvironment('TAGS_API')
		waitForHealth(api)
	}

	def setup() {
		assert http('DELETE', "${api}/tags").statusCode() == 204
		assert http('DELETE', "${api}/tags/").statusCode() == 204
	}

	protected static Response http(String method, String url, Object body = null, String contentType = 'application/json') {
		def request = RestAssured.with().contentType(contentType)
		if (body != null) {
			request.body(body)
		}
		request.request(method, url)
	}

	protected static String requiredEnvironment(String name) {
		String value = System.getenv(name)
		assert value != null && !value.isBlank(): "${name} must explicitly target an isolated test stack"
		value
	}

	protected static void waitForHealth(String endpoint) {
		waitForStatus("${endpoint}/health", 204)
	}

	protected static void waitForStatus(String endpoint, int expectedStatus) {
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

	protected static String segment(String value) {
		URLEncoder.encode(value, StandardCharsets.UTF_8).replace('+', '%20')
	}

	protected static Response create(String category, String name, String base = api) {
		http('POST', "${base}/tags", [category: category, name: name])
	}
}
