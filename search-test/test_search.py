"""Non-disruptive search integration tests against the deployed development stack."""
import datetime
import json
import os
import socket
import time
import unittest
import urllib.error
import urllib.request
import uuid

GRAPHQL = os.environ["GRAPHQL_API"]
REST = os.environ["REST_API"].rstrip("/")
FIXTURE = os.environ["FIXTURE_API"].rstrip("/")
NATS_HOST = os.environ.get("NATS_HOST", "nats")


def request(url, method="GET", body=None, content_type="application/json"):
    data = json.dumps(body).encode() if body is not None else None
    return raw_request(url, method, data, content_type)


def raw_request(url, method, data, content_type):
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": content_type})
    try:
        response = urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        body = response.read()
        return response.status, body, response.headers


def gql(query, variables=None):
    status, raw, _ = request(GRAPHQL, "POST", {"query": query, "variables": variables or {}})
    result = json.loads(raw)
    if status != 200 or result.get("errors"):
        raise AssertionError(f"GraphQL request failed: HTTP {status}, {result!r}")
    return result["data"]


def wait_for(fn, timeout=45):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = fn()
        if last:
            return last
        time.sleep(0.2)
    raise AssertionError(f"condition did not converge within {timeout}s: {last!r}")


def publish(recipe_id, kind="recipe.changed", event_id=None):
    payload = json.dumps({
        "version": 1, "eventId": event_id or str(uuid.uuid4()),
        "occurredAt": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
        "recipeId": recipe_id, "kind": kind,
    }).encode()
    with socket.create_connection((NATS_HOST, 4222), timeout=5) as sock:
        stream = sock.makefile("rb")
        if not stream.readline().startswith(b"INFO "):
            raise AssertionError("NATS handshake failed")
        inbox = f"_INBOX.search_test.{uuid.uuid4().hex}"
        sock.sendall(
            b'CONNECT {"verbose":false,"pedantic":false}\r\n'
            + f"SUB {inbox} 1\r\nPUB recipes.events.v1 {inbox} {len(payload)}\r\n".encode()
            + payload + b"\r\n"
        )
        while True:
            line = stream.readline()
            if line == b"PING\r\n":
                sock.sendall(b"PONG\r\n")
            elif line.startswith(b"MSG "):
                result = json.loads(stream.read(int(line.split()[-1])))
                if stream.read(2) != b"\r\n" or "error" in result:
                    raise AssertionError(result)
                return result["seq"]
            elif line.startswith(b"-ERR") or not line:
                raise AssertionError(line)


class SearchIntegration(unittest.TestCase):
    def setUp(self):
        self.ids = []
        self.addCleanup(self.cleanup)
        self.scope = "searchtest" + uuid.uuid4().hex
        self.filter = f"ingredients:={self.scope}"
        wait_for(lambda: self.status()["ready"])
        self.soup = self.create("Kartoffelsuppe", "Kartoffeln", 5)
        self.salad = self.create("Kartoffelsalat", "Kartoffeln", 3)
        self.cake = self.create("Apfelkuchen", "Äpfel", 4)
        wait_for(lambda: set(self.search()["recipeIds"]) == set(self.ids))

    def status(self):
        status, raw, _ = request(REST + "/search/reindex")
        self.assertEqual(status, 200, raw)
        return json.loads(raw)

    def create(self, name, ingredient, rating):
        value = {
            "name": name, "method": "Mit Öl und Zwiebeln kochen.",
            "ingredients": [{"name": ingredient, "unit": "g", "amount": 100},
                            {"name": self.scope}],
            "inspirations": [],
        }
        result = gql("mutation($value: RecipeInput!) { createRecipe(value: $value) { id } }",
                     {"value": value})
        recipe_id = result["createRecipe"]["id"]
        self.ids.append(recipe_id)
        gql("mutation($id: ID!, $rating: Int!) { rate(id: $id, rating: $rating, login: \"search-test\") { count } }",
            {"id": recipe_id, "rating": rating})
        return recipe_id

    def update(self, recipe_id, value):
        gql("mutation($id: ID!, $value: RecipeInput!) { updateRecipe(id: $id, value: $value) { id } }",
            {"id": recipe_id, "value": value})

    def delete(self, recipe_id):
        return gql("mutation($id: ID!) { deleteRecipe(id: $id) }", {"id": recipe_id})["deleteRecipe"]

    def cleanup(self):
        for recipe_id in self.ids:
            self.delete(recipe_id)
            for service in ("images", "inspirations"):
                status, raw, _ = request(REST + f"/{service}/{recipe_id}", "DELETE")
                self.assertIn(status, (204, 404), raw)
        if self.ids:
            wait_for(lambda: not self.search()["recipeIds"])

    def search(self, **options):
        status, raw, _ = request(REST + "/search", "POST",
                                {"q": "*", "filter_by": self.filter, **options})
        # The deployed worker can be reconciling in response to another test's reset.
        if status == 503:
            wait_for(lambda: self.status()["ready"])
            status, raw, _ = request(REST + "/search", "POST",
                                    {"q": "*", "filter_by": self.filter, **options})
        self.assertEqual(status, 200, raw)
        return json.loads(raw)

    def rebuild(self):
        status, raw, _ = request(REST + "/search/reindex", "POST")
        self.assertEqual(status, 202, raw)
        job_id = json.loads(raw)["jobId"]
        def completed():
            status, raw, _ = request(REST + f"/search/reindex/{job_id}")
            self.assertIn(status, (200, 202), raw)
            result = json.loads(raw)
            return result if status == 200 else None
        self.assertEqual(wait_for(completed, 90)["status"], "succeeded")
        return job_id

    def test_german_search_typos_and_order(self):
        self.assertEqual(self.search(q="Kartofelsuppe")["recipeIds"], [self.soup])
        self.assertEqual(self.search(q="Äpfel")["recipeIds"], [self.cake])
        self.assertEqual(self.search(q="Kartofelsuppe", num_typos=0)["recipeIds"], [])
        wait_for(lambda: self.search(q="Kartoffel", sort_by="_text_match:desc,rating_average:desc")["recipeIds"]
                 == [self.soup, self.salad])

    def test_composed_options_facets_pagination_and_grouping(self):
        wait_for(lambda: self.search(sort_by="rating_average:desc")["recipeIds"]
                 == [self.soup, self.cake, self.salad])
        result = self.search(query_by="method", q="Zwiebeln", sort_by="rating_average:desc",
                             facet_by="ingredients", page=2, per_page=1,
                             include_fields="*", highlight_fields="*")
        self.assertEqual(set(result), {"recipeIds", "facetCounts", "found", "outOf", "page", "perPage"})
        self.assertEqual(result["recipeIds"], [self.cake])
        self.assertEqual((result["found"], result["page"], result["perPage"]), (3, 2, 1))
        self.assertGreaterEqual(result["outOf"], 3)
        counts = {c["value"]: c["count"] for c in result["facetCounts"][0]["counts"]}
        self.assertEqual(counts["Kartoffeln"], 2)
        self.assertNotIn("highlights", json.dumps(result))
        self.assertEqual(self.search(group_by="rating_average", group_limit=1,
                                     sort_by="rating_average:desc")["recipeIds"],
                         [self.soup, self.cake, self.salad])

    def test_graphql_updates_deletions_and_duplicate_events(self):
        self.update(self.soup, {"name": "Linsensuppe"})
        wait_for(lambda: self.search(q="Linsensuppe")["recipeIds"] == [self.soup])
        event_id = str(uuid.uuid4())
        publish(self.soup, event_id=event_id)
        publish(self.soup, event_id=event_id)
        # Distinct envelopes also exercise repeated delivery beyond publisher deduplication.
        publish(self.soup)
        wait_for(lambda: self.status()["pendingMessages"] == 0 and self.status()["outstandingAcks"] == 0)
        self.assertEqual(self.search(q="Linsensuppe")["recipeIds"], [self.soup])
        self.assertTrue(self.delete(self.salad))
        wait_for(lambda: self.salad not in self.search()["recipeIds"])
        publish(self.soup, "recipe.deleted")
        wait_for(lambda: self.status()["pendingMessages"] == 0 and self.status()["outstandingAcks"] == 0)
        self.assertEqual(self.search(q="Linsensuppe")["recipeIds"], [self.soup])

    def test_optional_values_clear(self):
        url = "https://example.org/" + self.scope
        self.update(self.soup, {"inspirations": [url]})
        wait_for(lambda: self.search(q=url, query_by="inspiration_urls")["recipeIds"] == [self.soup])
        self.update(self.soup, {"inspirations": [], "method": None})
        wait_for(lambda: not self.search(q=url, query_by="inspiration_urls")["recipeIds"])
        wait_for(lambda: self.soup not in self.search(q="Zwiebeln", query_by="method")["recipeIds"])

    def test_image_presence(self):
        self.assertEqual(self.search(filter_by=self.filter + " && has_image:=true")["recipeIds"], [])
        status, image, _ = raw_request(FIXTURE + "/test.jpg", "GET", None, "image/jpeg")
        self.assertEqual(status, 200)
        boundary = uuid.uuid4().hex
        parts = []
        for name, content in (
            ("operations", json.dumps({
                "query": "mutation($id: ID!, $file: Upload!) { setImage(recipeId: $id, file: $file) }",
                "variables": {"id": self.soup, "file": None},
            }).encode()),
            ("map", b'{"0":["variables.file"]}'),
        ):
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'.encode()
                         + content + b"\r\n")
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="0"; filename="test.jpg"\r\nContent-Type: image/jpeg\r\n\r\n'.encode()
                     + image + f"\r\n--{boundary}--\r\n".encode())
        status, raw, _ = raw_request(GRAPHQL, "POST", b"".join(parts),
                                    f"multipart/form-data; boundary={boundary}")
        self.assertEqual(status, 200, raw)
        result = json.loads(raw)
        self.assertFalse(result.get("errors"), result)
        self.assertTrue(result["data"]["setImage"])
        wait_for(lambda: self.search(filter_by=self.filter + " && has_image:=true")["recipeIds"] == [self.soup])
        self.assertEqual(set(self.search(filter_by=self.filter + " && has_image:=false")["recipeIds"]),
                         {self.salad, self.cake})
        self.rebuild()
        self.assertEqual(self.search(filter_by=self.filter + " && has_image:=true")["recipeIds"], [self.soup])

    def test_rebuild_recovers_writes_without_events(self):
        status, raw, _ = request(REST + "/recipes/" + self.soup, "PATCH",
                                {"name": "Unveröffentlichte Möhrensuppe"},
                                "application/merge-patch+json")
        self.assertEqual(status, 200, raw)
        status, raw, _ = request(REST + "/recipes/" + self.salad, "DELETE")
        self.assertEqual(status, 204, raw)
        value = {"name": "Unveröffentlichter Kuchen", "ingredients": [{"name": self.scope}]}
        status, raw, _ = request(REST + "/recipes", "POST", value)
        self.assertEqual(status, 201, raw)
        added = json.loads(raw)["id"]
        self.ids.append(added)
        self.rebuild()
        self.assertEqual(self.search(q="Möhrensuppe")["recipeIds"], [self.soup])
        self.assertEqual(set(self.search()["recipeIds"]), {self.soup, self.cake, added})

    def test_rebuild_converges_with_queued_writes_and_overlapping_requests(self):
        status, raw, _ = request(REST + "/search/reindex", "POST")
        self.assertEqual(status, 202, raw)
        self.update(self.soup, {"name": "Birnensuppe"})
        added = self.create("Käsekuchen", "Käse", 2)
        self.rebuild()
        wait_for(lambda: self.search(q="Birnensuppe")["recipeIds"] == [self.soup])
        wait_for(lambda: added in self.search()["recipeIds"])

    def test_invalid_search_options_report_problem_details(self):
        for options in ({"q": []}, {"q": "*", "filter_by": "missing:=1"}):
            status, raw, headers = request(REST + "/search", "POST", options)
            self.assertEqual(status, 400, raw)
            result = json.loads(raw)
            self.assertEqual(headers["Content-Type"], "application/problem+json")
            self.assertEqual(result["type"], "about:blank")
            self.assertEqual(result["code"], "invalid-search-options")
            self.assertEqual(result["status"], 400)
