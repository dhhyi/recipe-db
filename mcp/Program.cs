var builder = WebApplication.CreateBuilder(args);

builder
    .Services.AddMcpClient()
    .ConfigureHttpClient(c => c.BaseAddress = new Uri("http://traefik/graphql"));

builder.Services.AddHttpClient();

builder.Services.AddMcpServer().WithHttpTransport().WithToolsFromAssembly();

var app = builder.Build();

app.MapGet("/health", () => Results.Ok());
app.MapMcp("/mcp");

app.Run();
