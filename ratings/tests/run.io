failure := try(
    list("tests/maintenance.io", "tests/startup.io") foreach(path, doFile(path))
    failures := FileCollector run
)
if (failure,
    failure showStack
    System exit(1)
)
System exit(if(failures isEmpty, 0, 1))
