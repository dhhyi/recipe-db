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

System system("printf '2\\n' > " .. root .. "/storage-version")
result = System system("MODE=testing DATA_LOCATION=" .. root .. " io main.io")
if (result == 0,
    Exception raise("Mismatched ratings marker was accepted")
)
if ((File clone setPath(root .. "/storage-version") contents) != "2\n",
    Exception raise("Rejected ratings marker was modified")
)

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
