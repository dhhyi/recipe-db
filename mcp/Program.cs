var builder = WebApplication.CreateBuilder(args);

builder.Services.AddHttpContextAccessor();
builder.Services.AddTransient<ForwardAuthorizationHandler>();

builder.Services
    .AddHttpClient("McpClient", c => c.BaseAddress = new Uri("http://traefik/graphql"))
    .AddHttpMessageHandler<ForwardAuthorizationHandler>();

builder.Services.AddMcpClient();

builder.Services.AddMcpServer().WithHttpTransport().WithToolsFromAssembly();

var app = builder.Build();

app.MapGet("/health", () => Results.Ok());
app.MapMcp("/mcp");

app.Run();

sealed class ForwardAuthorizationHandler(IHttpContextAccessor contextAccessor) : DelegatingHandler
{
    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken
    )
    {
        if (contextAccessor.HttpContext is { } httpContext && request.Headers.Authorization is null)
        {
            var authorization = httpContext.Request.Headers["Authorization"];
            if (authorization.Count == 1)
            {
                request.Headers.TryAddWithoutValidation("Authorization", authorization[0]);
            }
        }

        return base.SendAsync(request, cancellationToken);
    }
}
