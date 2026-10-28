doFile("lib/db.io")
doFile("lib/request.io")
doFile("lib/api.io")

mode := System getEnvironmentVariable("MODE")
if (mode == nil, mode = "production")
if (mode != "production" and mode != "testing",
    writeln("Invalid MODE: expected production or testing")
    System exit(1)
)
RESTAPI runtimeMode := mode

db := DB clone
db initialize

writeln("Starting server on port 8456")

if (mode == "production",
    writeln("Production mode")
)

server := Server clone setPort(8456)

server handleSocket := method(aSocket,
    RESTAPI clone @handleSocketFromServer(aSocket, self, db)
)

server start
