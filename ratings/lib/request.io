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

Request setTarget := method(target,
    separator := target findSeq("?")
    if (separator,
        setPath(target slice(0, separator))
        setQuery(target slice(separator + 1)),
        setPath(target)
        setQuery("")
    )
)

Request setPayload := method(payload,
    self atPut("payload", CGI parseString(payload))
)

Request prettyPath := method(
    path := self at("path")
    return if (path == nil, "", "/" .. path join("/"))
)

Request verbose := System getEnvironmentVariable("VERBOSE") == "true"

Request send := method(code, message, data, contentType,
    if (verbose,
        writeln((self at("method")) .. " " .. (self prettyPath) .. " ".. code .. " " .. message)
    )

    ct := if (contentType == nil, "application/json", contentType)
    return "HTTP/1.1 " .. code .. " " .. message .. "\r\nConnection: close\r\n" .. if (data == nil, "\r\n", "Content-type: " .. ct .. "\r\nContent-Length: " .. data size .. "\r\n\r\n" .. data)
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

Request errorBadRequest := method(detail, code, field,
    ## RFC 9457 Problem Details body, mirroring the recipes service's error shape.
    problem := Map clone atPut("type", "about:blank") atPut("title", "Bad Request") atPut("status", 400) atPut("detail", detail) atPut("code", code)
    if (field != nil, problem atPut("field", field))
    return self send("400", "Bad Request", problem asJson, "application/problem+json")
)

Request errorNotFound := method(
    problem := Map clone atPut("type", "about:blank") atPut("title", "Not Found") atPut("status", 404) atPut("detail", "Route not found") atPut("code", "not-found")
    return self send("404", "Not Found", problem asJson, "application/problem+json")
)

Request errorMethodNotAllowed := method(
    problem := Map clone atPut("type", "about:blank") atPut("title", "Method Not Allowed") atPut("status", 405) atPut("detail", "Method not allowed") atPut("code", "method-not-allowed")
    return self send("405", "Method Not Allowed", problem asJson, "application/problem+json")
)

Request errorInternalServerError := method(
    problem := Map clone atPut("type", "about:blank") atPut("title", "Internal Server Error") atPut("status", 500) atPut("detail", "The request could not be completed") atPut("code", "internal-server-error")
    return self send("500", "Internal Server Error", problem asJson, "application/problem+json")
)
