Regex clone

RESTAPI := Object clone

RESTAPI get := method(request,
    path := request at("path")

    if (path at(0) == "health",
        return request sendNoContent
    )

    if (path at(0) == "ratings",
        if (path size == 1,
            allRatings := db getAllAverageRatings
            return request sendData(allRatings asJson)
        )
        if (path size == 2,
            id := path at(1)
            rating := db getAverageRating(id)
            return request sendData(rating asJson)
        )
    )

    return request errorNotFound
)

RESTAPI put := method(request,
    if (request at("path") at(0) == "ratings",
        id := request at("path") at(1)
        if (id != nil,
        if (request at("payload") != nil,
            if (request at("payload") at("rating") == nil, return request errorBadRequest("Missing rating"))
            if (request at("payload") at("login") == nil, return request errorBadRequest("Missing login"))

            rating := request at("payload") at("rating") asNumber
            if (list(1, 2, 3, 4, 5) contains(rating) == false, return request errorBadRequest("Invalid rating"))

            login := request at("payload") at("login")
            data := db addRating(id, rating, login) asJson
            return request sendData(data)
            )
        )
        return request errorBadRequest("Missing rating")
    )

    return request errorNotFound
)

RESTAPI delete := method(request,
    if (System getEnvironmentVariable("TESTING") == "true",
    if (request at("path") size == 1,
    if (request at("path") at(0) == "ratings",
        db clear
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
    request setPath (header at(1))

    contentLengthRegex := "Content-Length: (\\d+)" asRegex
    contentLength := requestData allMatchesOfRegex(contentLengthRegex)
    if (contentLength size > 0,
        contentLength := contentLength at(0) at(1) asNumber
        payload := aSocket readBytes(contentLength)
        request setPayload (payload asString)
    )

    return request
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
