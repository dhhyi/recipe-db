function fn(endpoint, firstAuthorization, secondAuthorization, recipeId) {
  var HttpClient = Java.type("java.net.http.HttpClient");
  var HttpRequest = Java.type("java.net.http.HttpRequest");
  var BodyPublishers = Java.type("java.net.http.HttpRequest$BodyPublishers");
  var BodyHandlers = Java.type("java.net.http.HttpResponse$BodyHandlers");
  var URI = Java.type("java.net.URI");
  var Duration = Java.type("java.time.Duration");
  var client = HttpClient.newBuilder()
    .connectTimeout(Duration.ofSeconds(5))
    .build();
  var query =
    "mutation($id: ID!, $rating: Int!) { rate(id: $id, rating: $rating) { average count myRating } }";
  var pending = [];

  for (var i = 0; i < 8; i++) {
    var first = i < 4;
    var body = JSON.stringify({
      query: query,
      variables: { id: recipeId, rating: first ? 2 : 4 },
    });
    var request = HttpRequest.newBuilder(URI.create(endpoint))
      .timeout(Duration.ofSeconds(15))
      .header("Content-Type", "application/json")
      .header("Authorization", first ? firstAuthorization : secondAuthorization)
      .POST(BodyPublishers.ofString(body))
      .build();
    pending.push(client.sendAsync(request, BodyHandlers.ofString()));
  }

  return pending.map(function (future) {
    var response = future.join();
    return { status: response.statusCode(), body: JSON.parse(response.body()) };
  });
}
