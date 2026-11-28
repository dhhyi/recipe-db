doFile("lib/db.io")

RatingsStartupTest := UnitTest clone do(
    root := "tests/startup-fixture"

    setUp := method(
        assertTrue(Directory with(root) exists == false)
        assertTrue(System system("mkdir -p -- " .. DB shellQuote(root)) == 0)
    )

    tearDown := method(
        assertTrue(System system("rm -rf -- " .. DB shellQuote(root)) == 0)
    )

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

    testStorageInitializationAndModeGates := method(
        list("production", "testing") foreach(mode,
            writeln("Checking fresh storage in mode: ", mode)
            location := root .. "/" .. mode .. "/db.sqlite"
            result := runStartup(mode, location, true)
            assertTrue(result == 124)
            assertTrue(databaseHasRatings(location))
        )

        defaultLocation := root .. "/default/db.sqlite"
        result := runStartup(nil, defaultLocation, true)
        assertTrue(result == 124 and databaseHasRatings(defaultLocation))

        list("", "invalid") foreach(mode,
            result = runStartup(mode, defaultLocation, true)
            assertTrue(result != 0 and result != 124)
            assertTrue(databaseHasRatings(defaultLocation))
        )

        missingRoot := root .. "/missing-backup-root"
        result := runStartup("backup", missingRoot, true)
        assertTrue(result != 0 and result != 124)
        assertTrue(Directory with(missingRoot) exists == false)

        missingTable := root .. "/missing-table/db.sqlite"
        prepareDatabase(missingTable, "CREATE TABLE unrelated (value TEXT);",
                        "INSERT INTO unrelated VALUES ('preserve');")
        result = runStartup("backup", missingTable, true)
        assertTrue(result != 0 and result != 124)
        DB setPath(missingTable)
        DB open
        tables := DB exec("SELECT name FROM sqlite_master WHERE type='table' AND name='Ratings';")
        unrelated := DB exec("SELECT value FROM unrelated;")
        DB close
        assertTrue(tables size == 0)
        assertTrue(unrelated size == 1 and unrelated at(0) at("value") == "preserve")

        incompatible := root .. "/incompatible/db.sqlite"
        prepareDatabase(incompatible, incompatibleSchema, incompatibleRows)
        list("production", "testing", "backup") foreach(mode,
            writeln("Checking incompatible storage in mode: ", mode)
            result = runStartup(mode, incompatible, true)
            assertTrue(result != 0 and result != 124)
            DB setPath(incompatible)
            DB open
            rows := DB exec("SELECT key, value FROM Ratings;")
            columns := DB exec("PRAGMA table_info(Ratings);")
            DB close
            assertTrue(rows size == 1 and rows at(0) at("key") == "preserve" and
                   rows at(0) at("value") asNumber == 5)
            assertTrue(columns size == 2 and columns at(0) at("name") == "key" and
                   columns at(1) at("name") == "value")
        )

        corrupt := root .. "/corrupt.sqlite"
        System system("printf 'not a sqlite database' > " .. DB shellQuote(corrupt))
        list("production", "testing", "backup") foreach(mode,
            writeln("Checking corrupt storage in mode: ", mode)
            result = runStartup(mode, corrupt, true)
            assertTrue(result != 0 and result != 124)
            assertTrue((File clone setPath(corrupt) contents) == "not a sqlite database")
        )

        validBackup := root .. "/valid-backup/db.sqlite"
        prepareDatabase(validBackup, validSchema, validRows)
        result = runStartup("backup", validBackup, true)
        assertTrue(result == 124)
        DB setPath(validBackup)
        DB open
        rows := DB exec("SELECT key, userId, value FROM Ratings;")
        DB close
        assertTrue(rows size == 1 and rows at(0) at("key") == "preserve" and
               rows at(0) at("userId") == "user" and rows at(0) at("value") asNumber == 5)
    )
)
