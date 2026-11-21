doFile("lib/db.io")

root := "tests/startup-fixture"

assert := method(condition, message,
    if (condition == false, Exception raise(message))
)

assert(Directory with(root) exists == false, "Ratings fixture already exists")
assert(System system("mkdir -p -- " .. DB shellQuote(root)) == 0,
       "Cannot create ratings fixture")

runStartup := method(mode, location, timeout,
    command := if (timeout, "timeout 1s env ", "env ")
    if (mode != nil,
        command = command .. "MODE=" .. DB shellQuote(mode) .. " ",
        command = command .. "-u MODE "
    )
    command = command .. "DATA_LOCATION=" .. DB shellQuote(location) .. " "
    System system(command .. "io main.io")
)

prepareDatabase := method(location, schema, rows,
    System system("mkdir -p -- " ..
        DB shellQuote(File clone setPath(location) parentDirectory path))
    DB setPath(location)
    DB open
    DB checkNoError
    DB exec(schema)
    DB checkNoError
    if (rows,
        DB exec(rows)
        DB checkNoError
    )
    DB close
)

databaseHasRatings := method(location,
    DB setPath(location)
    DB open
    result := DB exec("SELECT name FROM sqlite_master WHERE type='table' AND name='Ratings';")
    DB checkNoError
    DB close
    result size > 0
)

validSchema := "CREATE TABLE Ratings (
    key varchar(100) NOT NULL,
    userId varchar(500) NOT NULL,
    value int NOT NULL,
    CONSTRAINT pk PRIMARY KEY (key, userId)
);"
validRows := "INSERT INTO Ratings (key, userId, value) VALUES ('preserve', 'user', 5);"
incompatibleSchema := "CREATE TABLE Ratings (key TEXT, value INTEGER);"
incompatibleRows := "INSERT INTO Ratings VALUES ('preserve', 5);"

list("production", "testing") foreach(mode,
    location := root .. "/" .. mode .. "/db.sqlite"
    result := runStartup(mode, location, true)
    assert(result == 124, mode .. " did not initialize and serve fresh storage")
    assert(databaseHasRatings(location), mode .. " did not create Ratings")
)

defaultLocation := root .. "/default/db.sqlite"
result := runStartup(nil, defaultLocation, true)
assert(result == 124 and databaseHasRatings(defaultLocation),
       "Unset mode did not initialize storage in production")

list("", "invalid") foreach(mode,
    result = runStartup(mode, defaultLocation, true)
    assert(result != 0 and result != 124, "Invalid runtime mode was accepted")
    assert(databaseHasRatings(defaultLocation), "Invalid mode changed ratings storage")
)

missingRoot := root .. "/missing-backup-root"
result := runStartup("backup", missingRoot, true)
assert(result != 0 and result != 124, "Backup initialized missing ratings storage")
assert(Directory with(missingRoot) exists == false,
       "Backup created the missing ratings data root")

missingTable := root .. "/missing-table/db.sqlite"
prepareDatabase(missingTable, "CREATE TABLE unrelated (value TEXT);",
                "INSERT INTO unrelated VALUES ('preserve');")
result = runStartup("backup", missingTable, true)
assert(result != 0 and result != 124, "Backup accepted a database without Ratings")
DB setPath(missingTable)
DB open
tables := DB exec("SELECT name FROM sqlite_master WHERE type='table' AND name='Ratings';")
unrelated := DB exec("SELECT value FROM unrelated;")
DB close
assert(tables size == 0, "Backup created a missing Ratings table")
assert(unrelated size == 1 and unrelated at(0) at("value") == "preserve",
       "Rejected backup startup changed unrelated data")

incompatible := root .. "/incompatible/db.sqlite"
prepareDatabase(incompatible, incompatibleSchema, incompatibleRows)
list("production", "testing", "backup") foreach(mode,
    result = runStartup(mode, incompatible, true)
    assert(result != 0 and result != 124,
           mode .. " accepted an incompatible Ratings schema")
    DB setPath(incompatible)
    DB open
    rows := DB exec("SELECT key, value FROM Ratings;")
    columns := DB exec("PRAGMA table_info(Ratings);")
    DB close
    assert(rows size == 1 and rows at(0) at("key") == "preserve" and
           rows at(0) at("value") asNumber == 5,
           "Rejected startup changed incompatible-schema data")
    assert(columns size == 2 and columns at(0) at("name") == "key" and
           columns at(1) at("name") == "value",
           "Rejected startup changed the incompatible schema")
)

corrupt := root .. "/corrupt.sqlite"
System system("printf 'not a sqlite database' > " .. DB shellQuote(corrupt))
list("production", "testing", "backup") foreach(mode,
    result = runStartup(mode, corrupt, true)
    assert(result != 0 and result != 124, mode .. " accepted corrupt ratings storage")
    assert((File clone setPath(corrupt) contents) == "not a sqlite database",
           "Rejected startup changed corrupt ratings storage")
)

validBackup := root .. "/valid-backup/db.sqlite"
prepareDatabase(validBackup, validSchema, validRows)
result = runStartup("backup", validBackup, true)
assert(result == 124, "Backup rejected valid ratings storage")
DB setPath(validBackup)
DB open
rows := DB exec("SELECT key, userId, value FROM Ratings;")
DB close
assert(rows size == 1 and rows at(0) at("key") == "preserve" and
       rows at(0) at("userId") == "user" and rows at(0) at("value") asNumber == 5,
       "Valid backup startup changed ratings data")

assert(System system("rm -rf -- " .. DB shellQuote(root)) == 0,
       "Cannot remove ratings fixture")
writeln("Ratings database initialization gates passed")
