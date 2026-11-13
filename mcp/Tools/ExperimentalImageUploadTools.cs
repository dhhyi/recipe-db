using System.ComponentModel;
using System.Security.Cryptography;
using System.Text.Json;
using Mcp.GraphQL;
using ModelContextProtocol;
using ModelContextProtocol.Server;
using StrawberryShake;

namespace Mcp.Tools;

// One process-local slot bounds the experiment, including abandoned and finished uploads.
public sealed class ExperimentalUploadStore
{
    public const int ChunkLimit = 262_144;
    public const int FileLimit = 5 * 1024 * 1024;
    public SemaphoreSlim Gate { get; } = new(1, 1);
    public ExperimentalUpload? Current { get; set; }
}

public sealed class ExperimentalUpload(string recipeId, int length, string mediaType, string sha256)
{
    public string Handle { get; } = Guid.NewGuid().ToString("N");
    public string RecipeId { get; } = recipeId;
    public int Length { get; } = length;
    public string MediaType { get; } = mediaType;
    public string Sha256 { get; } = sha256;
    public MemoryStream Bytes { get; } = new(length);
    public int NextChunk { get; set; }
    public byte[]? LastChunk { get; set; }
    public bool Sealed { get; set; }
}

[McpServerToolType]
public sealed class ExperimentalImageUploadTools(IMcpClient client, ExperimentalUploadStore store)
{
    private static string Json(object value) => JsonSerializer.Serialize(value);

    private async Task RequirePermission()
    {
        var response = await client.ImageUploadCapabilities.ExecuteAsync();
        if (response.Errors.Count > 0)
        {
            throw RecipeTools.GraphQLError(response.Errors);
        }
        if (response.Data?.MyCapabilities.CanManageImages != true)
        {
            throw new McpException("forbidden: Image-management permission is required");
        }
    }

    [McpServerTool(Name = "start_image_upload")]
    [Description("EXPERIMENT ONLY: start one local image upload. Requires image-management permission on every call. Supply original decoded byte length (1..5242880), image media type and SHA-256 (64 hex digits). Returns uploadHandle and decoded chunkLimit. Send independently base64-encoded sequential 262144-byte chunks, with a shorter final chunk, then finish_image_upload. Restart loses all handles; discard_image_upload explicitly clears the single slot.")]
    public async Task<string> Start(
        [Description("Target recipe ID, at most 256 characters")] string recipeId,
        [Description("Original decoded file length, 1..5242880 bytes")] int byteLength,
        [Description("Image media type: image/jpeg, image/png or image/webp")] string mediaType,
        [Description("SHA-256 of original decoded file bytes, 64 hexadecimal digits")] string sha256)
    {
        await RequirePermission();
        if (string.IsNullOrWhiteSpace(recipeId) || recipeId.Length > 256
            || byteLength < 1 || byteLength > ExperimentalUploadStore.FileLimit
            || mediaType is not ("image/jpeg" or "image/png" or "image/webp")
            || sha256.Length != 64 || !sha256.All(Uri.IsHexDigit))
        {
            throw new McpException("invalid-upload: Invalid recipe ID, length, media type or SHA-256");
        }

        await store.Gate.WaitAsync();
        try
        {
            if (store.Current is not null)
                throw new McpException("upload-slot-full: Discard the existing experiment upload first");
            var upload = new ExperimentalUpload(recipeId, byteLength, mediaType, sha256.ToLowerInvariant());
            store.Current = upload;
            return Json(new { uploadHandle = upload.Handle, chunkLimit = ExperimentalUploadStore.ChunkLimit });
        }
        finally { store.Gate.Release(); }
    }

    private ExperimentalUpload Find(string uploadHandle)
    {
        if (uploadHandle.Length != 32 || store.Current is not { } upload || upload.Handle != uploadHandle)
            throw new McpException("unknown-upload: No such experiment upload");
        return upload;
    }

    [McpServerTool(Name = "send_image_chunk")]
    [Description("EXPERIMENT ONLY: send an independently base64-encoded chunk (maximum 349528 characters / 262144 decoded bytes). Use zero-based sequential chunkNumber. Only the final chunk may be shorter. Returns nextChunkNumber. Retrying the latest accepted chunk with identical decoded bytes acknowledges it without appending; all other retries/order conflicts fail without appending.")]
    public async Task<string> SendChunk(
        [Description("Opaque uploadHandle from start_image_upload")] string uploadHandle,
        [Description("Zero-based sequential chunk number")] int chunkNumber,
        [Description("This chunk's independently encoded base64 bytes, not a file path")] string base64)
    {
        await RequirePermission();
        await store.Gate.WaitAsync();
        try
        {
            var upload = Find(uploadHandle);
            if (upload.Sealed) throw new McpException("upload-sealed: Discard and start a new upload");
            if (base64.Length > 349_528)
                throw new McpException("chunk-too-large: Encoded chunk exceeds the limit");
            byte[] bytes;
            try { bytes = Convert.FromBase64String(base64); }
            catch (FormatException) { throw new McpException("invalid-base64: Chunk is not valid base64"); }
            if (bytes.Length == 0 || bytes.Length > ExperimentalUploadStore.ChunkLimit)
                throw new McpException("invalid-chunk-size: Decoded chunk must contain 1..262144 bytes");

            if (chunkNumber == upload.NextChunk - 1 && upload.LastChunk is not null)
            {
                if (!bytes.AsSpan().SequenceEqual(upload.LastChunk))
                    throw new McpException("conflicting-chunk: Latest accepted chunk has different bytes");
                return Json(new { nextChunkNumber = upload.NextChunk });
            }
            if (chunkNumber != upload.NextChunk)
                throw new McpException("unexpected-chunk: Chunk number is not the next expected number");
            if (upload.Bytes.Length + bytes.Length > upload.Length)
            {
                upload.Sealed = true;
                throw new McpException("excess-bytes: Declared length exceeded; upload cannot continue");
            }
            if (bytes.Length != ExperimentalUploadStore.ChunkLimit
                && upload.Bytes.Length + bytes.Length != upload.Length)
                throw new McpException("invalid-chunk-size: Only the final chunk may be shorter");

            upload.Bytes.Write(bytes);
            upload.LastChunk = bytes;
            upload.NextChunk++;
            return Json(new { nextChunkNumber = upload.NextChunk });
        }
        finally { store.Gate.Release(); }
    }

    [McpServerTool(Name = "finish_image_upload")]
    [Description("EXPERIMENT ONLY: verify exact byte count and SHA-256, then submit once through trusted GraphQL setImage. Returns success, verified source length/SHA-256 and image metadata, or explicit error. A checksum is not image validation; GraphQL must accept the image. Never retry a failed/uncertain assignment: inspect the recipe instead. Once attempted, finish cannot execute the mutation again.")]
    public async Task<string> Finish(
        [Description("Opaque uploadHandle from start_image_upload")] string uploadHandle)
    {
        await RequirePermission();
        await store.Gate.WaitAsync();
        try
        {
            var upload = Find(uploadHandle);
            if (upload.Sealed) throw new McpException("upload-sealed: Finish is not replayable; inspect the recipe");
            upload.Sealed = true;
            if (upload.Bytes.Length != upload.Length)
                throw new McpException("length-mismatch: Staged byte count differs from the declared length");
            var sha256 = Convert.ToHexStringLower(SHA256.HashData(upload.Bytes.GetBuffer().AsSpan(0, upload.Length)));
            if (sha256 != upload.Sha256)
                throw new McpException("checksum-mismatch: Staged SHA-256 differs from the original");

            upload.Bytes.Position = 0;
            try
            {
                var response = await client.SetImage.ExecuteAsync(
                    upload.RecipeId, new Upload(upload.Bytes, "experiment-image", upload.MediaType));
                if (response.Errors.Count > 0) throw RecipeTools.GraphQLError(response.Errors);
                if (response.Data?.SetImage is not { } image)
                    throw new McpException("upstream-failure: GraphQL returned no image");
                return Json(new { success = true, byteLength = upload.Length, sha256, image });
            }
            catch (Exception error)
            {
                // Do not echo transport details or replay an assignment with an uncertain result.
                var detail = error is McpException ? error.Message : "GraphQL transport failed";
                throw new McpException($"assignment-failed-or-uncertain: {detail}; not retried. Inspect the recipe.");
            }
        }
        finally { store.Gate.Release(); }
    }

    [McpServerTool(Name = "discard_image_upload")]
    [Description("EXPERIMENT ONLY: explicitly clear this process's one staged upload and invalidate its handle. Does not delete or change an assigned recipe image. Requires current image-management permission. Restart also clears this non-durable staging.")]
    public async Task<string> Discard(
        [Description("Opaque uploadHandle from start_image_upload")] string uploadHandle)
    {
        await RequirePermission();
        await store.Gate.WaitAsync();
        try
        {
            var upload = Find(uploadHandle);
            upload.Bytes.Dispose();
            store.Current = null;
            return Json(new { discarded = true });
        }
        finally { store.Gate.Release(); }
    }
}
