DB := SQLite3 clone

DB clone := DB

DB checkNoError := method(
    if (error,
        writeln("ERROR " .. error)
        System exit(1)
    )
)

DB openOrCreate := method(
    location := System getEnvironmentVariable("DATA_LOCATION")
    if (location, if (location endsWithSeq(".sqlite"), location, location := location .. "/db.sqlite"))
    if (location == nil, location = "db.sqlite")

    dbFile := File clone setPath(location)

    writeln("DB Location: " .. dbFile path)

    if (dbFile exists,
        writeln("Found existing database"),
        writeln("Creating new database")
        Directory with(dbFile parentDirectory path) createIfAbsent
    )

    setPath(dbFile path)
    open
    checkNoError
)

DB initialize := method(
    openOrCreate

    tables := exec("SELECT name FROM sqlite_master WHERE type='table' AND name='Ratings';")
    if (tables size > 0,
        hasUserId := false
        exec("PRAGMA table_info(Ratings);") foreach(row,
            if (row at("name") == "userId", hasUserId = true)
        )
        if (hasUserId == false,
            writeln("Recreating ratings with stable user IDs")
            exec("DROP TABLE Ratings;")
        )
    )
    if (exec("SELECT name FROM sqlite_master WHERE type='table' AND name='Ratings';") size == 0,
        exec("CREATE TABLE Ratings (
                key varchar(100) NOT NULL,
                userId varchar(500) NOT NULL,
                value int NOT NULL,
                CONSTRAINT pk PRIMARY KEY (key, userId)
        );")
        checkNoError
    )
)

DB clear := method(
    exec("DROP TABLE Ratings;")
    checkNoError
    close
    initialize
)

DB getAverageRating := method(id,
    safeId := id asString replaceSeq("'", "''")
    result := exec("SELECT AVG(value), COUNT(value) FROM Ratings WHERE key='" .. safeId .. "';") at(0)
    checkNoError
    count := result at("COUNT(value)") asNumber
    rawRating := result at("AVG(value)")
    average := if (rawRating == "NULL", 0, rawRating asNumber)
    return formatSingle(id, average, count)
)

DB getAllAverageRatings := method(
    result := exec("SELECT key, AVG(value), COUNT(value) FROM Ratings GROUP BY key;")
    checkNoError
    return result map(row, formatSingle(row at("key"), row at("AVG(value)") asNumber, row at("COUNT(value)") asNumber))
)

DB getUserRating := method(id, userId,
    safeId := id asString replaceSeq("'", "''")
    safeUserId := userId asString replaceSeq("'", "''")
    result := exec("SELECT value FROM Ratings WHERE key='" .. safeId .. "' AND userId='" .. safeUserId .. "';")
    checkNoError
    return if (result size == 0, nil, result at(0) at("value") asNumber)
)

DB addRating := method(id, rating, userId,
    safeId := id asString replaceSeq("'", "''")
    safeUserId := userId asString replaceSeq("'", "''")
    exec("INSERT OR REPLACE INTO Ratings (key, userId, value)
          VALUES ('" .. safeId .. "', '" .. safeUserId .. "', " .. rating .. ");")
    checkNoError
    return getAverageRating(id)
)
