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

Request error := method(code, message,
    self send(code, message, nil)
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
    // return request sendData(request)
    if (request at("path") at(0) == "ratings",
        id := request at("path") at(1)
        if (id != nil,
            return request sendData(Map clone atPut("rating", 5) atPut("id", id))
        )
    )

    return request errorNotFound
)

RESTAPI routeRequest := method(httpData,
    methodAndPath := httpData split("\n") at(0)
    if (methodAndPath != nil,
        httpMethod := methodAndPath split(" ") at(0)

        request := Request clone
        request atPut("method", httpMethod)

        path := methodAndPath split(" ") at(1) split("?") at(0)
        request atPut("path", path split("/") slice(1))

        query := methodAndPath split(" ") at(1) split("?") at(1)
        request atPut("query", CGI parseString(query))

        writeln(httpMethod .. " " .. path)

        if(self getSlot(httpMethod asLowercase) == nil,
            return request errorMethodNotAllowed,
            return self getSlot(httpMethod asLowercase) call(request)
        )
    )
    return nil
)

RESTAPI handleSocketFromServer := method(aSocket, aServer,
    while(aSocket isOpen,
        if(aSocket read,
            data := routeRequest(aSocket readBuffer asString)
            if (data != nil, aSocket write(data))
        )

        aSocket readBuffer empty
        aSocket close
    )
)

writeln("Starting server on port 8456")

server := Server clone setPort(8456)

server handleSocket := method(aSocket,
    RESTAPI clone @handleSocketFromServer(aSocket, self)
)

server start
