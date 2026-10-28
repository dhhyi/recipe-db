using System.Net.Http.Headers;
using ModelContextProtocol;
using ModelContextProtocol.AspNetCore;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddHttpContextAccessor();
builder.Services.AddTransient<ForwardAuthorizationHandler>();

builder.Services.AddHttpClient()
    .ConfigureHttpClientDefaults(client => client.ConfigurePrimaryHttpMessageHandler(
        () => new HttpClientHandler { UseCookies = false }
    ));

builder.Services.AddMcpClient()
    .ConfigureHttpClient(
        client => client.BaseAddress = new Uri("http://traefik/graphql"),
        client => client
            .AddHttpMessageHandler<ForwardAuthorizationHandler>()
            .ConfigurePrimaryHttpMessageHandler(
                () => new HttpClientHandler { UseCookies = false, AllowAutoRedirect = false }
            )
    );

builder.Services.AddMcpServer()
    .WithHttpTransport(options => options.SessionMode = HttpServerSessionMode.Stateless)
    .WithToolsFromAssembly();

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
        // This server-to-server request uses the trusted GraphQL destination, not a browser origin.
        request.Headers.Remove("Origin");
        request.Headers.TryAddWithoutValidation("Origin", request.RequestUri!.GetLeftPart(UriPartial.Authority));
        request.Headers.Authorization = null;
        if (contextAccessor.HttpContext is { } httpContext
            && httpContext.Request.Headers.TryGetValue("Authorization", out var authorization))
        {
            if (authorization.Count != 1
                || !AuthenticationHeaderValue.TryParse(authorization[0], out var bearer)
                || !bearer.Scheme.Equals("Bearer", StringComparison.OrdinalIgnoreCase)
                || string.IsNullOrEmpty(bearer.Parameter)
                || bearer.Parameter.Contains(','))
            {
                throw new McpException("invalid-credentials: Invalid bearer credentials");
            }

            request.Headers.Authorization = bearer;
        }

        return base.SendAsync(request, cancellationToken);
    }
}
