package = "inspirations"
version = "dev-1"
source = {
    url = "git+ssh://git@github.com/dhhyi/recipe-db.git"
}
dependencies = {
    "lua ~> 5.4",
    "dkjson ~> 2.6"
}
build = {
    type = "builtin",
    modules = {
        inspirations_server = "server.lua"
    }
}
