doFile("lib/request.io")
doFile("lib/db.io")
doFile("lib/api.io")

RatingsMaintenanceTest := UnitTest clone do(
    requestFor := method(methodName, target,
        request := Request clone
        request setMethod(methodName)
        request setTarget(target)
        request setHeaders(Map clone)
        request
    )

    setUp := method(
        self fakeDb := Map clone
        fakeDb atPut("ids", list("opaque/recipe id", "second"))
        fakeDb atPut("deleted", list())
        fakeDb atPut("resets", 0)
        fakeDb clear := method(
            self atPut("resets", self at("resets") + 1)
            nil
        )
        fakeDb getAllRecipeIds := method(self at("ids"))
        fakeDb deleteRecipeRatings := method(id,
            self at("deleted") append(id)
            nil
        )

        self api := RESTAPI clone
        api runtimeMode := "backup"
        api db := fakeDb
    )

    testModeValidationAndContentLength := method(
        assertTrue(RESTAPI validRuntimeMode("production"))
        assertTrue(RESTAPI validRuntimeMode("testing"))
        assertTrue(RESTAPI validRuntimeMode("backup"))
        assertTrue(RESTAPI validRuntimeMode("") == false)
        assertTrue(RESTAPI validRuntimeMode("unknown") == false)
        assertTrue(api contentLength(Map clone atPut("content-length", "12")) == 12)
        assertTrue(api contentLength(Map clone atPut("content-length", "invalid")) == nil)
    )

    testHealthInAllModes := method(
        list("production", "testing", "backup") foreach(mode,
            writeln("Checking health in mode: ", mode)
            api runtimeMode := mode
            health := api get(requestFor("GET", "/health"))
            assertTrue(health containsSeq("HTTP/1.1 204 No Content"))
        )
    )

    testBackupMaintenanceAndPrivacy := method(
        status := api get(requestFor("GET", "/maintenance/status"))
        assertTrue(status containsSeq("HTTP/1.1 200 OK"))
        assertTrue(status containsSeq("\"service\":\"ratings\""))

        ids := api get(requestFor("GET", "/maintenance/recipe-ids"))
        assertTrue(ids containsSeq("\"recipeIds\""))
        assertTrue(ids findSeq("opaque") < ids findSeq("second"))

        purgeRequest := requestFor("POST", "/maintenance/recipes/purge")
        purgeRequest setHeaders(Map clone atPut("content-type", "application/json"))
        purgeRequest setPayload("{\"recipeId\":\"opaque/recipe id\"}")
        purgeResponse := api post(purgeRequest)
        assertTrue(purgeResponse containsSeq("HTTP/1.1 204 No Content"))
        assertTrue(fakeDb at("deleted") at(0) == "opaque/recipe id")

        repeatedPurge := requestFor("POST", "/maintenance/recipes/purge")
        repeatedPurge setHeaders(Map clone atPut("content-type", "application/json"))
        repeatedPurge setPayload("{\"recipeId\":\"opaque/recipe id\"}")
        assertTrue((api post(repeatedPurge)) containsSeq("HTTP/1.1 204 No Content"))

        wrongType := requestFor("POST", "/maintenance/recipes/purge")
        wrongType setHeaders(Map clone atPut("content-type", "text/plain"))
        wrongType setPayload("{}")
        assertTrue((api post(wrongType)) containsSeq("HTTP/1.1 415"))

        invalidBody := requestFor("POST", "/maintenance/recipes/purge")
        invalidBody setHeaders(Map clone atPut("content-type", "application/json"))
        invalidBody setPayload("{")
        assertTrue((api post(invalidBody)) containsSeq("HTTP/1.1 400"))

        blockedWrite := requestFor("PUT", "/ratings/opaque")
        assertTrue((api put(blockedWrite)) containsSeq("HTTP/1.1 503"))
        blockedReset := requestFor("DELETE", "/ratings")
        assertTrue((api delete(blockedReset)) containsSeq("HTTP/1.1 503"))

        api runtimeMode := "production"
        unavailable := api get(requestFor("GET", "/maintenance/status"))
        assertTrue(unavailable containsSeq("HTTP/1.1 404"))
        api runtimeMode := "testing"
        assertTrue((api get(requestFor("GET", "/maintenance/status"))) containsSeq("HTTP/1.1 404"))
        assertTrue((api get(requestFor("GET", "/maintenance/recipe-ids"))) containsSeq("HTTP/1.1 404"))
        assertTrue(fakeDb at("deleted") size == 2)
    )

    testResetAndAvailabilityBoundaries := method(
        list("production", "backup") foreach(mode,
            writeln("Checking reset denial in mode: ", mode)
            api runtimeMode := mode
            list("/ratings", "/ratings/") foreach(target,
                response := api delete(requestFor("DELETE", target))
                expected := if(mode == "backup", "HTTP/1.1 503", "HTTP/1.1 405")
                assertTrue(response containsSeq(expected))
                assertTrue(fakeDb at("resets") == 0)
            )
        )
        api runtimeMode := "testing"
        head := api routeRequest(requestFor("HEAD", "/ratings"))
        assertTrue(head containsSeq("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"))
        assertTrue(fakeDb at("resets") == 0)
        list("production", "backup") foreach(mode,
            api runtimeMode := mode
            assertTrue((api routeRequest(requestFor("HEAD", "/ratings"))) containsSeq(
                "HTTP/1.1 405 Method Not Allowed"))
        )
        api runtimeMode := "testing"
        list("/ratings", "/ratings/") foreach(target,
            response := api delete(requestFor("DELETE", target))
            assertTrue(response containsSeq("HTTP/1.1 204"))
        )
        assertTrue(fakeDb at("resets") == 2)
    )
)
