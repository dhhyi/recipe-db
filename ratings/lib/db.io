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

    if (exec("SELECT name FROM sqlite_master WHERE type='table' AND name='Ratings';") size == 0,
        exec("CREATE TABLE Ratings (
                key varchar(100) NOT NULL,
                login varchar(100) NOT NULL,
                value int NOT NULL,
                CONSTRAINT pk PRIMARY KEY (key, login)
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
    result := exec("SELECT AVG(value), COUNT(value) FROM Ratings WHERE key='" .. id .. "';") at(0)
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

DB addRating := method(id, rating, login,
    exec("INSERT OR REPLACE INTO Ratings (key, login, value)
          VALUES ('" .. id .. "', '" .. login .. "', " .. rating .. ");")
    checkNoError
    return getAverageRating(id)
)
