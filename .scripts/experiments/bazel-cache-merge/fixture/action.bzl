def _impl(ctx):
    output = ctx.outputs.out
    ctx.actions.run_shell(
        inputs = [ctx.file.src],
        outputs = [output],
        arguments = [ctx.file.src.path, output.path, "755" if ctx.attr.executable else "644"],
        command = 'cat "$1" > "$2"; chmod "$3" "$2"',
        mnemonic = "CacheUnion",
    )
    return [DefaultInfo(files = depset([output]))]

cache_action = rule(
    implementation = _impl,
    attrs = {
        "src": attr.label(allow_single_file = True, mandatory = True),
        "executable": attr.bool(default = False),
    },
    outputs = {"out": "%{name}.out"},
)
