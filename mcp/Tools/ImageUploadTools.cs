using System.ComponentModel;
using System.Text.Json;
using Mcp.GraphQL;
using ModelContextProtocol;
using ModelContextProtocol.Server;
using StrawberryShake;

namespace Mcp.Tools;

[McpServerToolType]
public class ImageUploadTools(
    IMcpClient client, ImageUploadStaging staging, ILogger<ImageUploadTools>? logger = null)
{
    [McpServerTool(Name = "image_upload_start")]
    [Description("Starts an isolated image upload for a recipe. Declare the original decoded file byteLength (1–5242880), image mediaType and original-file SHA-256 (64 hex digits), not a hash of base64. Reserves capacity atomically within 104857600 staged bytes. Every call checks current GraphQL image-management permission; any permitted caller with the opaque uploadHandle can continue. No expiry; Pod teardown invalidates handles.")]
    public async Task<string> Start(
        [Description("Recipe ID whose current single image will be replaced on finish")] string recipeId,
        [Description("Original decoded file byte length, maximum 5242880")] long byteLength,
        [Description("Original image media type, e.g. image/jpeg; backend validates actual content")] string mediaType,
        [Description("SHA-256 of the complete original file, 64 hexadecimal digits")] string sha256)
    {
        await CheckPermission();
        return Serialize(staging.Start(recipeId, byteLength, mediaType, sha256));
    }

    [McpServerTool(Name = "image_upload_chunk")]
    [Description("Appends the next zero-based chunk after checking current image-management permission. Independently base64-encode each chunk of 262144 decoded bytes; only the final chunk may be shorter. Use nextChunkNumber from status to recover lost acknowledgments. An identical retry of only the latest accepted chunk is safe and does not append; conflicting or out-of-order chunks fail unchanged.")]
    public async Task<string> Chunk(
        [Description("Opaque uploadHandle returned by start")] string uploadHandle,
        [Description("Sequential zero-based chunk number")] int chunkNumber,
        [Description("Canonical independent base64 encoding of this decoded chunk; no whitespace")] string base64)
    {
        await CheckPermission();
        return Serialize(staging.Chunk(uploadHandle, chunkNumber, base64));
    }

    [McpServerTool(Name = "image_upload_finish")]
    [Description("Checks current permission and verifies exact original file byte length and SHA-256 before setImage through trusted GraphQL. Replaces the recipe's current single image; does not add a collection. Backend validates image content. Assignment is attempted at most once: repeated finish returns assigning, a saved finished receipt, failed or uncertain, never replays. For uncertain outcomes inspect get_recipe or the normal UI before another upload. Receipt/deletion faults are explicit; staged bytes remain reserved until confirmed deletion.")]
    public async Task<string> Finish([Description("Opaque uploadHandle returned by start")] string uploadHandle)
    {
        await CheckPermission();
        var recipeId = staging.Status(uploadHandle).RecipeId;
        return Serialize(await staging.Finish(uploadHandle, async (stream, source) =>
        {
            var response = await client.SetImage.ExecuteAsync(recipeId, new Upload(stream, "image", source.MediaType));
            if (response.Errors.Count > 0)
            {
                if (response.Errors.Any(error => error.Exception is not null))
                    return new AssignmentResult(null, new("assignment-uncertain", "Image assignment transport or response decoding failed"), true);
                // The HTTP transport can synthesize message-only errors without attaching its exception.
                var confirmedErrors = response.Errors
                    .Where(error => !string.IsNullOrWhiteSpace(error.Extensions?.GetValueOrDefault("code")?.ToString()))
                    .ToArray();
                if (confirmedErrors.Length == 0)
                    return new AssignmentResult(null, new("assignment-uncertain", "No confirmed image assignment response was received"), true);
                var uncertain = response.Data?.SetImage is not null
                    || confirmedErrors.Length != response.Errors.Count
                    || response.Errors.Any(error => error.Extensions?.GetValueOrDefault("outcome")?.ToString() is "unknown" or "partial");
                var errors = confirmedErrors.Select(error => new UploadError(
                    error.Extensions?.GetValueOrDefault("code")?.ToString() ?? error.Code ?? "image-assignment-rejected",
                    error.Message,
                    error.Extensions?.GetValueOrDefault("field")?.ToString(),
                    error.Extensions?.GetValueOrDefault("status"))).ToArray();
                return new AssignmentResult(null, errors[0], uncertain, errors);
            }
            var image = response.Data?.SetImage;
            return image is null
                ? new AssignmentResult(null, new("assignment-uncertain", "No confirmed image result was returned"), true)
                : new AssignmentResult(new(image.Url, image.ThumbUrl, image.Width, image.Height, image.Size));
        }));
    }

    [McpServerTool(Name = "image_upload_status")]
    [Description("Checks current image-management permission and reports uploadHandle, receivedBytes, nextChunkNumber and receiving/assigning/finished/failed/uncertain state. Finished includes saved original-source verification and image metadata. Use this after interruption or lost replies; assigning/failed/uncertain must never be replayed. Unknown or Pod-invalidated handles fail explicitly. No caller/session binding or expiry; restart recovery is deferred.")]
    public async Task<string> Status([Description("Opaque uploadHandle returned by start")] string uploadHandle)
    {
        await CheckPermission();
        return Serialize(staging.Status(uploadHandle));
    }

    private async Task CheckPermission()
    {
        IOperationResult<IImageUploadCapabilitiesResult> response;
        try { response = await client.ImageUploadCapabilities.ExecuteAsync(); }
        catch (McpException) { throw; }
        catch (Exception error)
        {
            logger?.LogWarning("Image-management capability check failed ({FailureType})", error.GetType().Name);
            throw new McpException("image-permission-unavailable: Image-management permission could not be checked");
        }
        if (response.Errors.Any(error => error.Exception is not null))
        {
            foreach (var error in response.Errors.Where(error => error.Exception is not null))
                logger?.LogWarning("Image-management capability response failed ({FailureType})", error.Exception!.GetType().Name);
            throw new McpException("image-permission-unavailable: Image-management permission could not be checked");
        }
        if (response.Errors.Any(error => string.IsNullOrWhiteSpace(error.Extensions?.GetValueOrDefault("code")?.ToString())))
            throw new McpException("image-permission-unavailable: No confirmed image-management permission response was received");
        if (response.Errors.Count > 0) throw RecipeTools.GraphQLError(response.Errors);
        if (response.Data is null) throw new McpException("image-permission-unavailable: No image-management permission data was returned");
        if (!response.Data.MyCapabilities.CanManageImages)
            throw new McpException("image-permission-denied: Image-management permission is required");
    }

    private static string Serialize(UploadResult result) => JsonSerializer.Serialize(result, ImageUploadStaging.JsonOptions);
}
