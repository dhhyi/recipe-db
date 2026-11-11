doFile("lib/storage_version_generated.io")

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

DB storageVersion := method(
    StorageVersionGenerated
)

DB shellQuote := method(value,
    "'" .. value asString asMutable replaceSeq("'", "'\\''") .. "'"
)

DB storageFailure := method(marker, reason,
    writeln("ratings storage version failure at " .. marker ..
        ": expected " .. storageVersion asString .. ", " .. reason)
    System exit(1)
)

DB checkStorageVersion := method(
    database := databaseLocation
    root := File clone setPath(database) parentDirectory path
    marker := root .. "/storage-version"
    markerFile := File clone setPath(marker)
    version := nil
    if (System system("test -L " .. shellQuote(marker)) == 0,
        storageFailure(marker, "unsafe marker file type")
    )
    rootFile := File clone setPath(root)
    if (rootFile exists and rootFile isDirectory == false,
        storageFailure(marker, "data root is not a directory")
    )
    if (markerFile exists,
        if (System system("test -f " .. shellQuote(marker)) != 0,
            storageFailure(marker, "unsafe marker file type")
        )
        contents := nil
        readError := try(contents = markerFile contents)
        if (readError != nil,
            storageFailure(marker, "cannot read marker: " .. readError asString)
        )
        if (contents endsWithSeq("\n") == false or
            contents size < 2 or contents exSlice(0, contents size - 1) asNumber asString !=
            contents exSlice(0, contents size - 1),
            storageFailure(marker, "invalid marker contents")
        )
        version = contents exSlice(0, contents size - 1) asNumber
        if (version != storageVersion,
            storageFailure(marker, "actual " .. version asString)
        )
    )

    entries := list()
    rootDirectory := Directory with(root)
    if (rootDirectory exists,
        rootDirectory files foreach(entry,
            if (entry name != "storage-version", entries append(entry name))
        )
        rootDirectory directories foreach(entry,
            entries append(entry name)
        )
    )
    fresh := entries size == 0
    if (version == nil and fresh == false,
        storageFailure(marker, "marker missing; existing data found")
    )
    if (version == nil or fresh,
        if (System getEnvironmentVariable("MODE") == "backup",
            storageFailure(marker, "application data missing or unversioned; backup mode cannot initialize")
        )
        return version == nil
    )
    if (File clone setPath(database) exists == false,
        storageFailure(marker, "database missing; existing data found")
    )
    false
)

DB publishStorageVersion := method(
    database := databaseLocation
    root := File clone setPath(database) parentDirectory path
    marker := root .. "/storage-version"
    temporary := marker .. ".pending"
    writeStatus := System system("printf '%s\\n' " ..
        shellQuote(storageVersion asString) .. " > " .. shellQuote(temporary))
    if (writeStatus != 0, storageFailure(marker, "cannot write temporary marker"))
    status := System system("ln -T -- " .. shellQuote(temporary) .. " " .. shellQuote(marker))
    System system("rm -f -- " .. shellQuote(temporary))
    if (status != 0, storageFailure(marker, "cannot atomically publish marker"))
)

DB openOrCreate := method(
    location := databaseLocation

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
    freshStorage := checkStorageVersion
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
    if (freshStorage, publishStorageVersion)
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
