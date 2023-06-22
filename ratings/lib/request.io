Request := Map clone

Request parse := method(httpData,

    request := Request clone

    methodAndPath := httpData split("\n") at(0)
    payload := httpData split("\r\n\r\n") at(1)

    if (methodAndPath != nil,
        httpMethod := methodAndPath split(" ") at(0)

        request atPut("method", httpMethod)

        path := methodAndPath split(" ") at(1) split("?") at(0)
        request atPut("path", path split("/") slice(1))

        query := methodAndPath split(" ") at(1) split("?") at(1)
        request atPut("query", CGI parseString(query))

        if (payload != nil,
            request atPut("payload", CGI parseString(payload))
        )
    )

    return request
)

Request prettyPath := method(
    path := self at("path")
    return if (path == nil, "", "/" .. path join("/"))
)

Request send := method(code, message, data,
    writeln((self at("method")) .. " " .. (self prettyPath) .. " ".. code .. " " .. message)

    return "HTTP/1.1 " .. code .. " " .. message .. "\r\n" .. if (data == nil, "\r\n", "Content-type: application/json\r\n\r\n" .. data)
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
