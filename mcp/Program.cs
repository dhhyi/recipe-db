using System.Net.Http.Headers;
using ModelContextProtocol;
using ModelContextProtocol.AspNetCore;
using Mcp.Tools;
using Mcp;

var builder = WebApplication.CreateBuilder(args);
var mode = Environment.GetEnvironmentVariable("MODE") ?? "production";
if (mode is not ("production" or "testing" or "backup"))
{
    throw new InvalidOperationException("MODE must be production, testing, or backup");
}
var enableImageUploads = mode == "testing"
    && Environment.GetEnvironmentVariable("MCP_IMAGE_UPLOAD_TESTING") == "1";

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

var mcpServer = builder.Services.AddMcpServer()
    .WithHttpTransport(options => options.SessionMode = HttpServerSessionMode.Stateless)
    .WithTools<RecipeTools>();
if (enableImageUploads)
{
    builder.Services.AddSingleton<ImageUploadStaging>();
    mcpServer.WithTools<ImageUploadTools>();
}

var app = builder.Build();

app.Use(async (context, next) =>
{
    if (context.Request.Path.StartsWithSegments("/mcp"))
    {
        const long limit = 524288;
        var bodySize = context.Features.Get<Microsoft.AspNetCore.Http.Features.IHttpMaxRequestBodySizeFeature>();
        if (bodySize is { IsReadOnly: false })
        {
            bodySize.MaxRequestBodySize = limit;
        }
        if (context.Request.ContentLength > limit)
        {
            context.Response.StatusCode = StatusCodes.Status413PayloadTooLarge;
            return;
        }
    }
    await next(context);
});

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
