Regex clone

RESTAPI := Object clone

RESTAPI validRuntimeMode := method(mode,
    mode == "production" or mode == "testing" or mode == "backup"
)

RESTAPI get := method(request,
    path := request at("path")

    if (path at(0) == "health",
        return request sendNoContent
    )

    if (path at(0) == "maintenance",
        if (runtimeMode != "backup", return request errorNotFound)
        if (path size == 2 and path at(1) == "status",
            return request sendData("{\"version\":1,\"service\":\"ratings\",\"mode\":\"backup\"}")
        )
        if (path size == 2 and path at(1) == "recipe-ids",
            recipeIds := db getAllRecipeIds
            if (recipeIds type != "List",
                writeln("Rating maintenance enumeration failed")
                return request errorStorage
            )
            return request sendData("{\"recipeIds\":" .. recipeIds asJson .. "}")
        )
        return request errorNotFound
    )

    if (path at(0) == "ratings",
        if (path size == 1,
            allRatings := db getAllAverageRatings
            return request sendData(allRatings asJson)
        )
        if (path size == 2,
            id := path at(1)
            userId := request at("query") at("userId")
            if (userId != nil,
                rating := db getUserRating(id, userId)
                if (rating == nil, return request sendData("{\"rating\":null}"))
                return request sendData(Map clone atPut("rating", rating) asJson)
            )
            rating := db getAverageRating(id)
            return request sendData(rating asJson)
        )
    )

    return request errorNotFound
)

RESTAPI put := method(request,
    if (runtimeMode == "backup", return request errorMaintenanceMode)
    if (request at("path") at(0) == "ratings",
        id := request at("path") at(1)
        if (id != nil,
        if (request at("payload") != nil,
            if (request at("payload") at("rating") == nil, return request errorBadRequest("Missing rating", "missing-field", "rating"))
            if (request at("payload") at("userId") == nil, return request errorBadRequest("Missing userId", "missing-field", "userId"))

            rating := request at("payload") at("rating") asNumber
            if (list(1, 2, 3, 4, 5) contains(rating) == false, return request errorBadRequest("Invalid rating", "invalid-field", "rating"))

            userId := request at("payload") at("userId")
            data := db addRating(id, rating, userId) asJson
            return request sendData(data)
            )
        )
        return request errorBadRequest("Missing rating", "missing-field", "rating")
    )

    return request errorNotFound
)

RESTAPI post := method(request,
    path := request at("path")
    if (runtimeMode != "backup" or path size != 3 or
        path at(0) != "maintenance" or path at(1) != "recipes" or
        path at(2) != "purge",
        return request errorNotFound
    )
    contentType := request at("headers") at("content-type")
    if (contentType == nil or
        contentType split(";") at(0) asLowercase != "application/json",
        return request errorUnsupportedContentType
    )
    payload := nil
    parseError := try(payload = request at("rawPayload") parseJson)
    if (parseError != nil,
        return request errorBadRequest("Invalid JSON", "invalid-input", nil)
    )
    if (payload == nil or payload type != "Map",
        return request errorBadRequest("Expected a JSON object", "invalid-input", nil)
    )
    if (payload at("recipeId") == nil or payload at("recipeId") type != "Sequence" or
        payload at("recipeId") size == 0,
        return request errorBadRequest("Expected a non-empty recipeId", "invalid-input", "recipeId")
    )
    if (payload at("recipeId") containsSeq("\0"),
        return request errorBadRequest("Invalid recipeId", "invalid-input", "recipeId")
    )
    payload keys foreach(key,
        if (key != "recipeId",
            return request errorBadRequest("Unknown field", "invalid-input", key)
        )
    )
    error := db deleteRecipeRatings(payload at("recipeId"))
    if (error,
        writeln("Rating maintenance purge failed")
        return request errorStorage
    )
    return request sendNoContent
)

RESTAPI delete := method(request,
    path := request at("path")
    if (runtimeMode == "backup", return request errorMaintenanceMode)
    collection := path size == 1 or (path size == 2 and path at(1) == "")
    if (runtimeMode == "testing",
    if (collection,
    if (path at(0) == "ratings",
        error := db clear
        if (error,
            writeln("Rating reset failed: ", error)
            return request errorInternalServerError
        )
        return request sendNoContent
    )))

    return request errorMethodNotAllowed
)

RESTAPI routeRequest := method(request,
    httpMethod := request at("method") asLowercase
    if (self getSlot(httpMethod) == nil,
        return request errorMethodNotAllowed,
        return self getSlot(httpMethod) call(request)
    )
)

RESTAPI parseRequest := method(aSocket,
    requestData := aSocket readUntilSeq("\r\n\r\n")

    header := requestData split("\r\n") at(0) split(" ")
    httpMethod := header at(0)

    request := Request clone
    request setMethod (httpMethod)
    request setTarget (header at(1))

    headers := Map clone
    headerRegex := "([^:\r\n]+):\\s*([^\r\n]*)" asRegex
    requestData split("\r\n") foreach(line,
        matches := line allMatchesOfRegex(headerRegex)
        if (matches size > 0,
            values := matches at(0)
            headers atPut(values at(1) asLowercase, values at(2))
        )
    )
    request setHeaders(headers)

    contentLength := self contentLength(headers)
    if (contentLength != nil,
        payload := aSocket readBytes(contentLength)
        request setPayload (payload asString)
    )

    return request
)

RESTAPI contentLength := method(headers,
    value := headers at("content-length")
    if (value == nil, return nil)
    matches := value allMatchesOfRegex("^\\s*(\\d+)\\s*$" asRegex)
    if (matches size == 0, return nil)
    matches at(0) at(1) asNumber
)

RESTAPI verbose := System getEnvironmentVariable("VERBOSE") == "true"

RESTAPI handleSocketFromServer := method(aSocket, aServer, db,
    self db := db

    db formatSingle := method(id, rating, count,
        roundedRating := ((rating * 2) round) / 2
        return Map clone atPut("id", id) atPut("rating", roundedRating) atPut("count", count)
    )

    while(aSocket isOpen,
        request := parseRequest(aSocket)
        if (verbose,
            writeln(request at("method") .. " " .. request prettyPath)
        )

        e := try(
            data := routeRequest(request)
            if (data != nil, aSocket write(data))
        )
        e catch(Exception,
            writeln("Exception: " .. e showStack)
            aSocket write(Request errorInternalServerError)
        )

        aSocket readBuffer empty
        aSocket close
    )
)
