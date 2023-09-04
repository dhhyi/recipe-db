using PackageCompiler, Pkg

excludedDeps = ["PackageCompiler", "JSON", "JuliaFormatter"]

deps = keys(Pkg.project().dependencies)
deps = filter(x -> !(x in excludedDeps), deps)

@show deps

ENV["PRECOMPILE"] = "true"

create_sysimage(
    collect(deps),
    sysimage_path = "sysimage.so",
    precompile_execution_file = "server.jl",
)
