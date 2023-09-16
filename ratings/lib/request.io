Request := Map clone

Request setMethod := method(method,
    self atPut("method", method)
)

Request setPath := method(path,
    self atPut("path", path split("/") slice(1))
)

Request setQuery := method(query,
    self atPut("query", CGI parseString(query))
)

Request setPayload := method(payload,
    self atPut("payload", CGI parseString(payload))
)

Request prettyPath := method(
    path := self at("path")
    return if (path == nil, "", "/" .. path join("/"))
)

Request verbose := System getEnvironmentVariable("VERBOSE") == "true"

Request send := method(code, message, data,
    if (verbose,
        writeln((self at("method")) .. " " .. (self prettyPath) .. " ".. code .. " " .. message)
    )

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
