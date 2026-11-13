using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using ModelContextProtocol;

namespace Mcp;

public record UploadSource(long ByteLength, string MediaType, string Sha256);
public record UploadedImage(string Url, string ThumbUrl, int Width, int Height, long Size);
public record UploadError(string Code, string Message, string? Field = null, object? Status = null);
public record UploadResult(
    string UploadHandle, string RecipeId, string State, long ReceivedBytes,
    int NextChunkNumber, int ChunkLimit, UploadSource? Source = null,
    UploadedImage? Image = null, UploadError? Error = null, string? Recovery = null);

// Only the files survive a container restart; recovery of metadata belongs to the lifecycle child.
public class ImageUploadFiles(string root)
{
    public virtual void Create(string handle)
    {
        Directory.CreateDirectory(root);
        using var file = new FileStream(Photo(handle), FileMode.CreateNew, FileAccess.Write, FileShare.None);
    }
    public virtual void Append(string handle, byte[] bytes)
    {
        using var file = new FileStream(Photo(handle), FileMode.Open, FileAccess.Write, FileShare.None);
        var length = file.Length;
        file.Position = length;
        try
        {
            file.Write(bytes);
            file.Flush();
        }
        catch
        {
            file.SetLength(length);
            throw;
        }
    }
    public virtual Stream Read(string handle) => new FileStream(Photo(handle), FileMode.Open, FileAccess.Read, FileShare.Read);
    public virtual void SaveReceipt(string handle, UploadResult result)
    {
        var pending = Path.Combine(root, handle + ".receipt.pending");
        File.WriteAllText(pending, JsonSerializer.Serialize(result, ImageUploadStaging.JsonOptions));
        File.Move(pending, Path.Combine(root, handle + ".receipt.json"), true);
    }
    public virtual void DeletePhoto(string handle)
    {
        File.Delete(Photo(handle));
        if (File.Exists(Photo(handle))) throw new IOException("Photo deletion was not confirmed");
    }
    private string Photo(string handle) => Path.Combine(root, handle + ".photo");
}

public class ImageUploadStaging
{
    public const int ChunkLimit = 262144;
    public const long FileLimit = 5242880;
    public const long Capacity = 104857600;
    internal static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private readonly object capacityLock = new();
    private readonly Dictionary<string, Entry> entries = new(StringComparer.Ordinal);
    private readonly ImageUploadFiles files;
    private long reservedBytes;

    public ImageUploadStaging() : this(new ImageUploadFiles(Path.Combine(AppContext.BaseDirectory, "upload-staging"))) { }
    public ImageUploadStaging(ImageUploadFiles files) => this.files = files;

    public UploadResult Start(string recipeId, long byteLength, string mediaType, string sha256)
    {
        if (string.IsNullOrWhiteSpace(recipeId) || recipeId.Length > 1024)
            throw Invalid("invalid-recipe-id", "A recipe ID is required");
        if (byteLength <= 0 || byteLength > FileLimit)
            throw Invalid("invalid-byte-length", $"Byte length must be between 1 and {FileLimit}");
        if (mediaType is null || mediaType.Length > 127 || !MediaTypeHeaderValue.TryParse(mediaType, out var parsed)
            || parsed.Parameters.Count != 0 || parsed.MediaType is not { } type
            || !type.StartsWith("image/", StringComparison.OrdinalIgnoreCase) || type.Contains('*'))
            throw Invalid("invalid-media-type", "A valid image media type without parameters is required");
        if (sha256 is null || sha256.Length != 64 || !sha256.All(Uri.IsHexDigit))
            throw Invalid("invalid-sha256", "SHA-256 must be the 64 hexadecimal digits of the original file");

        lock (capacityLock)
        {
            if (byteLength > Capacity - reservedBytes)
                throw Invalid("upload-capacity-exceeded", "Staged upload capacity is unavailable; existing uploads are retained");
            var handle = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
            reservedBytes += byteLength;
            var entry = new Entry(handle, recipeId, new(byteLength, type.ToLowerInvariant(), sha256.ToLowerInvariant()));
            entries.Add(handle, entry);
            try { files.Create(handle); }
            catch
            {
                entry.State = "failed";
                entry.Error = new("staging-write-failed", "Could not create staged photo bytes; capacity remains reserved");
                throw Invalid(entry.Error.Code, entry.Error.Message);
            }
            return Snapshot(entry);
        }
    }

    public UploadResult Chunk(string uploadHandle, int chunkNumber, string base64)
    {
        var entry = Find(uploadHandle);
        var bytes = Decode(base64);
        lock (entry.Gate)
        {
            if (entry.State != "receiving") throw Invalid("upload-not-receiving", "This upload no longer accepts chunks");
            if (chunkNumber == entry.NextChunkNumber - 1 && entry.LatestChunk is { } latest)
            {
                if (!bytes.AsSpan().SequenceEqual(latest))
                    throw Invalid("conflicting-chunk", "The retry differs from the latest accepted chunk");
                return Snapshot(entry);
            }
            if (chunkNumber != entry.NextChunkNumber)
                throw Invalid("unexpected-chunk-number", "Use the next expected chunk number reported by status");
            var remaining = entry.Source.ByteLength - entry.ReceivedBytes;
            if (bytes.Length != Math.Min(ChunkLimit, remaining))
                throw Invalid("invalid-chunk-length", "Chunks must fill the decoded chunk limit; only the final chunk may be shorter");
            try { files.Append(entry.Handle, bytes); }
            catch
            {
                entry.State = "failed";
                entry.Error = new("staging-write-failed", "Staged photo write failed; this upload cannot continue");
                return Snapshot(entry);
            }
            entry.ReceivedBytes += bytes.Length;
            entry.NextChunkNumber++;
            entry.LatestChunk = bytes;
            return Snapshot(entry);
        }
    }

    public UploadResult Status(string uploadHandle)
    {
        var entry = Find(uploadHandle);
        lock (entry.Gate) return Snapshot(entry);
    }

    public async Task<UploadResult> Finish(string uploadHandle, Func<Stream, UploadSource, Task<AssignmentResult>> assign)
    {
        var entry = Find(uploadHandle);
        Stream stream;
        lock (entry.Gate)
        {
            if (entry.State != "receiving") return Snapshot(entry);
            if (entry.ReceivedBytes != entry.Source.ByteLength)
                throw Invalid("upload-incomplete", "Continue uploading chunks before finishing");
            try
            {
                stream = files.Read(entry.Handle);
                var valid = stream.Length == entry.Source.ByteLength
                    && Convert.ToHexString(SHA256.HashData(stream)).Equals(entry.Source.Sha256, StringComparison.OrdinalIgnoreCase);
                if (!valid)
                {
                    stream.Dispose();
                    entry.State = "failed";
                    entry.Error = new("upload-integrity-failed", "Original file byte length or SHA-256 does not match");
                    return Snapshot(entry);
                }
                stream.Position = 0;
            }
            catch
            {
                entry.State = "failed";
                entry.Error = new("staging-read-failed", "Could not verify staged photo bytes");
                return Snapshot(entry);
            }
            entry.State = "assigning";
            entry.LatestChunk = null;
        }

        AssignmentResult assigned;
        try
        {
            using (stream) assigned = await assign(stream, entry.Source);
        }
        catch
        {
            assigned = new(null, new("assignment-uncertain", "The image assignment outcome could not be confirmed"), true);
        }
        lock (entry.Gate)
        {
            if (assigned.Image is null)
            {
                entry.State = assigned.Uncertain ? "uncertain" : "failed";
                entry.Error = assigned.Error ?? new("assignment-failed", "Image assignment was rejected");
                return Snapshot(entry);
            }
            entry.Image = assigned.Image;
            var receipt = Snapshot(entry) with { State = "finished", Source = entry.Source };
            try { files.SaveReceipt(entry.Handle, receipt); }
            catch
            {
                entry.State = "failed";
                entry.Error = new("receipt-save-failed", "Image was assigned, but its success receipt could not be saved. Inspect the recipe; assignment will not be replayed");
                return Snapshot(entry);
            }
            try { files.DeletePhoto(entry.Handle); }
            catch
            {
                entry.State = "failed";
                entry.Error = new("staging-delete-failed", "Image was assigned and its receipt saved, but photo deletion was not confirmed. Capacity remains reserved; assignment will not be replayed");
                return Snapshot(entry);
            }
            lock (capacityLock) reservedBytes -= entry.Source.ByteLength;
            entry.State = "finished";
            return Snapshot(entry);
        }
    }

    private Entry Find(string handle)
    {
        lock (capacityLock)
        {
            if (handle is not null && entries.TryGetValue(handle, out var entry)) return entry;
        }
        throw Invalid("unknown-upload-handle", "Upload handle is unknown or invalidated by Pod teardown");
    }
    private static byte[] Decode(string value)
    {
        const int encodedLimit = ((ChunkLimit + 2) / 3) * 4;
        if (string.IsNullOrEmpty(value) || value.Length > encodedLimit || value.Length % 4 != 0)
            throw Invalid("invalid-base64", "Chunk must be bounded, independently encoded base64");
        var padding = value.EndsWith("==", StringComparison.Ordinal) ? 2 : value.EndsWith('=') ? 1 : 0;
        var length = value.Length / 4 * 3 - padding;
        if (length <= 0 || length > ChunkLimit)
            throw Invalid("invalid-chunk-length", "Decoded chunk exceeds the chunk limit");
        for (var i = 0; i < value.Length - padding; i++)
        {
            var c = value[i];
            if (!(c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '+' or '/'))
                throw Invalid("invalid-base64", "Chunk contains invalid base64");
        }
        var bytes = new byte[length];
        if (!Convert.TryFromBase64String(value, bytes, out var written) || written != length
            || Convert.ToBase64String(bytes) != value)
            throw Invalid("invalid-base64", "Chunk must use canonical base64 with no whitespace");
        return bytes;
    }
    private static McpException Invalid(string code, string message) => new($"{code}: {message}");
    private static UploadResult Snapshot(Entry e) => new(
        e.Handle, e.RecipeId, e.State, e.ReceivedBytes, e.NextChunkNumber, ChunkLimit,
        e.Image is null ? null : e.Source, e.Image, e.Error,
        e.State == "uncertain" ? "Inspect the recipe through get_recipe or the normal UI before starting another upload; this mutation will never be replayed" : null);
    private sealed class Entry(string handle, string recipeId, UploadSource source)
    {
        public object Gate { get; } = new();
        public string Handle { get; } = handle;
        public string RecipeId { get; } = recipeId;
        public UploadSource Source { get; } = source;
        public string State { get; set; } = "receiving";
        public long ReceivedBytes { get; set; }
        public int NextChunkNumber { get; set; }
        public byte[]? LatestChunk { get; set; }
        public UploadedImage? Image { get; set; }
        public UploadError? Error { get; set; }
    }
}

public record AssignmentResult(UploadedImage? Image, UploadError? Error = null, bool Uncertain = false);
