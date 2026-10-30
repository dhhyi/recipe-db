doFile("lib/request.io")
doFile("lib/db.io")
doFile("lib/api.io")

assert := method(condition, message,
    if (condition == false, Exception raise(message))
)

requestFor := method(methodName, target,
    request := Request clone
    request setMethod(methodName)
    request setTarget(target)
    request setHeaders(Map clone)
    request
)

fakeDb := Map clone
fakeDb atPut("ids", list("opaque/recipe id", "second"))
fakeDb atPut("deleted", list())
fakeDb getAllRecipeIds := method(self at("ids"))
fakeDb deleteRecipeRatings := method(id,
    self at("deleted") append(id)
    nil
)

api := RESTAPI clone
api runtimeMode := "backup"
api db := fakeDb

assert(RESTAPI validRuntimeMode("production"), "production mode is accepted")
assert(RESTAPI validRuntimeMode("testing"), "testing mode is accepted")
assert(RESTAPI validRuntimeMode("backup"), "backup mode is accepted")
assert(RESTAPI validRuntimeMode("") == false, "empty mode is rejected")
assert(RESTAPI validRuntimeMode("unknown") == false, "unknown mode is rejected")
assert(api contentLength(Map clone atPut("content-length", "12")) == 12, "lowercase content-length is accepted")
assert(api contentLength(Map clone atPut("content-length", "invalid")) == nil, "invalid content-length is ignored")

status := api get(requestFor("GET", "/maintenance/status"))
assert(status containsSeq("HTTP/1.1 200 OK"), "backup status response")
assert(status containsSeq("\"service\":\"ratings\""), "backup status service")

ids := api get(requestFor("GET", "/maintenance/recipe-ids"))
assert(ids containsSeq("\"recipeIds\""), "recipe ID response field")
assert(ids findSeq("opaque") < ids findSeq("second"), "ordered recipe IDs")

purgeRequest := requestFor("POST", "/maintenance/recipes/purge")
purgeRequest setHeaders(Map clone atPut("content-type", "application/json"))
purgeRequest setPayload("{\"recipeId\":\"opaque/recipe id\"}")
purgeResponse := api post(purgeRequest)
assert(purgeResponse containsSeq("HTTP/1.1 204 No Content"), "purge response")
assert(fakeDb at("deleted") at(0) == "opaque/recipe id", "purge uses the exact opaque ID")

repeatedPurge := requestFor("POST", "/maintenance/recipes/purge")
repeatedPurge setHeaders(Map clone atPut("content-type", "application/json"))
repeatedPurge setPayload("{\"recipeId\":\"opaque/recipe id\"}")
assert((api post(repeatedPurge)) containsSeq("HTTP/1.1 204 No Content"), "repeated purge")

wrongType := requestFor("POST", "/maintenance/recipes/purge")
wrongType setHeaders(Map clone atPut("content-type", "text/plain"))
wrongType setPayload("{}")
assert((api post(wrongType)) containsSeq("HTTP/1.1 415"), "content type validation")

invalidBody := requestFor("POST", "/maintenance/recipes/purge")
invalidBody setHeaders(Map clone atPut("content-type", "application/json"))
invalidBody setPayload("{")
assert((api post(invalidBody)) containsSeq("HTTP/1.1 400"), "invalid JSON response")

blockedWrite := requestFor("PUT", "/ratings/opaque")
assert((api put(blockedWrite)) containsSeq("HTTP/1.1 503"), "ratings writes are blocked")
blockedReset := requestFor("DELETE", "/ratings")
assert((api delete(blockedReset)) containsSeq("HTTP/1.1 503"), "test reset is blocked")

api runtimeMode := "production"
unavailable := api get(requestFor("GET", "/maintenance/status"))
assert(unavailable containsSeq("HTTP/1.1 404"), "maintenance is private to backup mode")
assert(fakeDb at("deleted") size == 2, "denied operations do not purge data")
