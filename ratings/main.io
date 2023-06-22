ratings := Map clone

Request := Map clone

Request send := method(code, message, data,
    writeln((self at("method")) .. " /" .. (self at("path") join("/")) .. " ".. code .. " " .. message)

    response := "HTTP/1.1 " .. code .. " " .. message .. "\r\n"
    if (data == nil, return response .. "\r\n",
        return response .. "Content-type: application/json\r\n\r\n" .. (data asJson) .. "\r\n"
    )
)

Request sendData := method(data,
    return self send("200", "OK", data)
)

Request sendNoContent := method(
    return self send("204", "No Content", nil)
)

Request error := method(code, message,
    self send(code, message, nil)
)

Request errorBadRequest := method(message,
    return self send("400", "Bad Request", message)
)

Request errorNotFound := method(
    return self error("404", "Not Found")
)

Request errorMethodNotAllowed := method(
    return self error("405", "Method Not Allowed")
)

Request errorInternalServerError := method(
    return self error("500", "Internal Server Error")
)

RESTAPI := Object clone

RESTAPI get := method(request,
    path := request at("path")

    if (path at(0) == "ratings",
        if (path size == 1,
            allRatings := ratings asList map(e, Map clone atPut("id", e first) atPut("rating", e last))
            return request sendData(allRatings)
        )
        if (path size == 2,
            id := path at(1)
            rating := ratings at(id)
            return if (rating != nil,
                request sendData(Map clone atPut("rating", rating) atPut("id", id)),
                request sendNoContent
            )
        )
    )

    return request errorNotFound
)

RESTAPI put := method(request,
    if (request at("path") at(0) == "ratings",
        id := request at("path") at(1)
        if (id != nil,
        if (request at("payload") != nil,
        if (request at("payload") at("rating") != nil,
            rating := request at("payload") at("rating") fromBase(10)
            ratings atPut(id, rating)
            return request sendData(Map clone atPut("rating", rating) atPut("id", id)))
        ))
        return request errorBadRequest("Missing rating")
    )

    return request errorNotFound
)

RESTAPI delete := method(request,
    if (System getEnvironmentVariable("TESTING") == "true",
    if (request at("path") size == 1,
    if (request at("path") at(0) == "ratings",
        ratings empty
        return request sendNoContent
    )))

    return request errorMethodNotAllowed
)

RESTAPI routeRequest := method(httpData,
    // "---------------" println
    // httpData println
    // "---------------" println

    methodAndPath := httpData split("\n") at(0)
    payload := httpData split("\r\n\r\n") at(1)

    if (methodAndPath != nil,
        httpMethod := methodAndPath split(" ") at(0)

        request := Request clone
        request atPut("method", httpMethod)

        path := methodAndPath split(" ") at(1) split("?") at(0)
        request atPut("path", path split("/") slice(1))

        query := methodAndPath split(" ") at(1) split("?") at(1)
        request atPut("query", CGI parseString(query))

        if (payload != nil,
            request atPut("payload", CGI parseString(payload))
        )

        writeln(httpMethod .. " " .. path)

        if (self getSlot(httpMethod asLowercase) == nil,
            return request errorMethodNotAllowed,
            return self getSlot(httpMethod asLowercase) call(request)
        )
    )
    return nil
)

RESTAPI handleSocketFromServer := method(aSocket, aServer,
    while(aSocket isOpen,
        if (aSocket read,
            data := routeRequest(aSocket readBuffer asString)
            if (data != nil, aSocket write(data))
        )

        aSocket readBuffer empty
        aSocket close
    )
)

writeln("Starting server on port 8456")

if (System getEnvironmentVariable("TESTING") == "true",
    writeln("TESTING MODE")
)

server := Server clone setPort(8456)

server handleSocket := method(aSocket,
    RESTAPI clone @handleSocketFromServer(aSocket, self)
)

server start
