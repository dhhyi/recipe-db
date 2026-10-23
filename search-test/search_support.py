"""Non-disruptive search integration tests against the deployed development stack."""
import datetime
import json
import os
import socket
import time
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


class SearchSession:
    def __init__(self):
        self.ids = []
        self.scope = "searchtest" + uuid.uuid4().hex
        self.filter = f"ingredients:={self.scope}"

    def status(self):
        status, raw, _ = request(REST + "/search/reindex")
        assert status == 200, (status, raw)
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
                assert status in (204, 404), (status, raw)
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
        assert status == 200, (status, raw)
        return json.loads(raw)

    def start_rebuild(self):
        status, raw, _ = request(REST + "/search/reindex", "POST")
        assert status == 202, (status, raw)
        return json.loads(raw)["jobId"]

    def finish_rebuild(self, job_id):
        def completed():
            status, raw, _ = request(REST + f"/search/reindex/{job_id}")
            assert status in (200, 202), (status, raw)
            result = json.loads(raw)
            return result if status == 200 else None
        result = wait_for(completed, 90)
        assert result["status"] == "succeeded", result

    def upload_image(self, recipe_id):
        status, image, _ = raw_request(FIXTURE + "/test.jpg", "GET", None, "image/jpeg")
        assert status == 200, (status, image)
        boundary = uuid.uuid4().hex
        parts = []
        for name, content in (
            ("operations", json.dumps({
                "query": "mutation($id: ID!, $file: Upload!) { setImage(recipeId: $id, file: $file) { url thumbUrl width height size } }",
                "variables": {"id": recipe_id, "file": None},
            }).encode()),
            ("map", b'{"0":["variables.file"]}'),
        ):
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'.encode()
                         + content + b"\r\n")
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="0"; filename="test.jpg"\r\nContent-Type: image/jpeg\r\n\r\n'.encode()
                     + image + f"\r\n--{boundary}--\r\n".encode())
        status, raw, _ = raw_request(GRAPHQL, "POST", b"".join(parts),
                                    f"multipart/form-data; boundary={boundary}")
        assert status == 200, (status, raw)
        result = json.loads(raw)
        assert not result.get("errors"), result
        assert result["data"]["setImage"]["url"], result
