pub const c = @cImport({
    @cInclude("curl/curl.h");
    @cInclude("nats/nats.h");
    @cInclude("unistd.h");
    @cInclude("grp.h");
    @cInclude("sys/stat.h");
});
