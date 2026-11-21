DB := SQLite3 clone

DB clone := DB

DB checkNoError := method(
    if (error,
        writeln("ERROR " .. error)
        System exit(1)
    )
)

DB databaseLocation := method(
    location := System getEnvironmentVariable("DATA_LOCATION")
    if (location,
        if (location endsWithSeq(".sqlite"), return location)
        return location .. "/db.sqlite"
    )
    return "data/db.sqlite"
)

DB shellQuote := method(value,
    "'" .. value asString asMutable replaceSeq("'", "'\\''") .. "'"
)

DB openOrCreate := method(
    location := databaseLocation

    dbFile := File clone setPath(location)

    writeln("DB Location: " .. dbFile path)

    if (System getEnvironmentVariable("MODE") == "backup",
        if (dbFile exists == false,
            writeln("ERROR database missing; backup mode cannot initialize")
            System exit(1)
        )
    ,
        if (dbFile exists,
            writeln("Found existing database")
        ,
            writeln("Creating new database")
            Directory with(dbFile parentDirectory path) createIfAbsent
        )
    )

    setPath(dbFile path)
    open
    checkNoError
)

DB initialize := method(
    openOrCreate

    tables := exec("SELECT name FROM sqlite_master WHERE type='table' AND name='Ratings';")
    checkNoError
    if (tables size > 0,
        hasUserId := false
        exec("PRAGMA table_info(Ratings);") foreach(row,
            if (row at("name") == "userId", hasUserId = true)
        )
        checkNoError
        if (hasUserId == false,
            writeln("ERROR incompatible Ratings schema: missing userId")
            System exit(1)
        )
    )
    if (tables size == 0,
        if (System getEnvironmentVariable("MODE") == "backup",
            writeln("ERROR Ratings table missing; backup mode cannot initialize")
            System exit(1)
        )
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
    exec("DELETE FROM Ratings;")
    if (error, return error)
    return nil
)

DB getAllRecipeIds := method(
    result := exec("SELECT DISTINCT key FROM Ratings ORDER BY key;")
    if (error, return error)
    return result map(row, row at("key"))
)

DB deleteRecipeRatings := method(id,
    safeId := id asString asMutable replaceSeq("'", "''")
    exec("DELETE FROM Ratings WHERE key='" .. safeId .. "';")
    return error
)

DB getAverageRating := method(id,
    safeId := id asString asMutable replaceSeq("'", "''")
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
    safeId := id asString asMutable replaceSeq("'", "''")
    safeUserId := userId asString asMutable replaceSeq("'", "''")
    result := exec("SELECT value FROM Ratings WHERE key='" .. safeId .. "' AND userId='" .. safeUserId .. "';")
    checkNoError
    return if (result size == 0, nil, result at(0) at("value") asNumber)
)

DB addRating := method(id, rating, userId,
    safeId := id asString asMutable replaceSeq("'", "''")
    safeUserId := userId asString asMutable replaceSeq("'", "''")
    exec("INSERT OR REPLACE INTO Ratings (key, userId, value)
          VALUES ('" .. safeId .. "', '" .. safeUserId .. "', " .. rating .. ");")
    checkNoError
    return getAverageRating(id)
)
