doFile("lib/db.io")
doFile("lib/request.io")
doFile("lib/api.io")

db := DB clone
db initialize

writeln("Starting server on port 8456")

if (System getEnvironmentVariable("TESTING") == "true",
    writeln("TESTING MODE")
)

server := Server clone setPort(8456)

server handleSocket := method(aSocket,
    RESTAPI clone @handleSocketFromServer(aSocket, self, db)
)

server start
