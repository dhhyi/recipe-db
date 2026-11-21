list("tests/maintenance.io", "tests/startup.io") foreach(path,
    failure := try(doFile(path))
    if (failure,
        failure showStack
        System exit(1)
    )
)
