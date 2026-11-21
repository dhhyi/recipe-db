doFile("lib/db.io")

root := "tests/storage-version-fixture"
System system("rm -rf -- " .. root)
System system("mkdir -p -- " .. root .. "/unknown-directory")
result := System system("timeout 1s env MODE=testing DATA_LOCATION=" ..
    root .. " io main.io")
if (result == 0 or result == 124,
    Exception raise("Unknown ratings data-root directory was accepted")
)

System system("rm -rf -- " .. root)
System system("mkdir -p -- " .. root)
System system("printf 'existing' > " .. root .. "/db.sqlite")

result = System system("MODE=testing DATA_LOCATION=" .. root .. " io main.io")
if (result == 0,
    Exception raise("Unversioned ratings data was accepted")
)
if (File clone setPath(root .. "/db.sqlite") exists == false,
    Exception raise("Rejected ratings storage was modified")
)

list("0", "-1", "1.5") foreach(invalid,
    System system("printf '%s\\n' '" .. invalid .. "' > " .. root .. "/storage-version")
    result = System system("timeout 2s env MODE=testing DATA_LOCATION=" .. root .. " io main.io")
    if (result == 0 or result == 124,
        Exception raise("Malformed ratings marker was accepted")
    )
)

System system("rm -f -- " .. root .. "/db.sqlite")
System system("printf '2\\n' > " .. root .. "/storage-version")
DB setPath(root .. "/db.sqlite")
DB open
DB exec("CREATE TABLE Ratings (key TEXT, value INTEGER)")
DB exec("INSERT INTO Ratings VALUES ('preserve', 5)")
DB close
list("production", "testing", "backup") foreach(mode,
    result = System system("timeout 2s env MODE=" .. mode .. " DATA_LOCATION=" .. root .. " io main.io")
    if (result == 0 or result == 124, Exception raise("Incompatible Ratings schema was accepted"))
)
DB open
rows := DB exec("SELECT key, value FROM Ratings")
if (rows size != 1 or (rows at(0) at("key")) != "preserve",
    Exception raise("Incompatible Ratings schema lost data")
)
DB close

System system("rm -f -- " .. root .. "/db.sqlite")
DB open
DB exec("CREATE TABLE unrelated (value TEXT)")
DB close
result = System system("timeout 2s env MODE=backup DATA_LOCATION=" .. root .. " io main.io")
if (result == 0 or result == 124, Exception raise("Backup initialized missing Ratings table"))
DB open
tables := DB exec("SELECT name FROM sqlite_master WHERE name='Ratings'")
if (tables size != 0, Exception raise("Backup created missing Ratings table"))
DB close

System system("rm -rf -- " .. root)
result = System system("MODE=backup DATA_LOCATION=" .. root .. " io main.io")
if (result == 0 or Directory with(root) exists,
    Exception raise("Backup mode initialized missing ratings storage")
)
System system("rm -rf -- " .. root)
System system("mkdir -p -- " .. root)
result = System system("timeout 1s env MODE=testing DATA_LOCATION=" ..
    root .. " io main.io")
if (result != 124,
    Exception raise("Fresh ratings storage did not initialize and serve")
)
if ((File clone setPath(root .. "/storage-version") contents) != "1\n",
    Exception raise("Fresh ratings storage did not publish its marker")
)
result = System system("timeout 1s env MODE=backup DATA_LOCATION=" ..
    root .. " io main.io")
if (result != 124,
    Exception raise("Versioned ratings storage did not start in backup mode")
)
if ((File clone setPath(root .. "/storage-version") contents) != "1\n",
    Exception raise("Backup startup changed the storage marker")
)
System system("rm -rf -- " .. root)
writeln("Ratings storage version startup gates passed")
