package tags

import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

class TagConcurrencySpec extends TagsApiSpec {
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
