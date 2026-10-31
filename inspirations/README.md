# Inspiration

Sources of inspiration web links for a recipe. Implemented in [Lua](https://www.lua.org/) using [Milua](https://github.com/MiguelMJ/Milua) for setting up REST API. Data stored as plain JSON file, initialized to an empty dataset on first startup in production or testing mode; backup mode requires an existing file and does not initialize storage. Errors use Problem Details (RFC 9457).

Testing (in [`inspirations-test`](../inspirations-test)) is done using [Venom](https://github.com/ovh/venom) with [Tavern Executor](https://github.com/intercloud/venom/tree/executor-tavern/executors/tavern).
