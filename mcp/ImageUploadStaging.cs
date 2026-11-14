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
    UploadedImage? Image = null, UploadError? Error = null, string? Recovery = null,
    IReadOnlyList<UploadError>? Errors = null);
public record UploadReceipt(string UploadHandle, string RecipeId, UploadSource Source, UploadedImage Image);

internal static class McpRuntime
{
    public static bool ImageUploadsEnabled(string mode, string? testingSwitch) =>
        mode == "production" || mode == "testing" && testingSwitch == "1";
}

internal record UploadMetadata(
    int Version, string UploadHandle, string RecipeId, UploadSource Source,
    string State, long ReceivedBytes, int NextChunkNumber,
    UploadedImage? Image, UploadError? Error, IReadOnlyList<UploadError>? Errors);

public class ImageUploadFiles(string root)
{
    private const string MetadataSuffix = ".upload.json";
    private const string ReceiptSuffix = ".receipt.json";
    private const string PhotoSuffix = ".photo";
    private const string PendingSuffix = ".pending";
    private readonly string directory = Path.GetFullPath(root);

    public virtual void Create(string handle)
    {
        Directory.CreateDirectory(directory);
        using var file = new FileStream(Photo(handle), FileMode.CreateNew, FileAccess.Write, FileShare.None);
        file.Flush(true);
    }

    public virtual void Append(string handle, byte[] bytes)
    {
        using var file = new FileStream(Photo(handle), FileMode.Open, FileAccess.Write, FileShare.None);
        var length = file.Length;
        file.Position = length;
        try
        {
            file.Write(bytes);
            file.Flush(true);
        }
        catch
        {
            file.SetLength(length);
            file.Flush(true);
            throw;
        }
    }

    public virtual Stream Read(string handle) =>
        new FileStream(Photo(handle), FileMode.Open, FileAccess.Read, FileShare.Read);

    public virtual long Length(string handle) => new FileInfo(Photo(handle)).Length;

    public virtual bool PhotoExists(string handle) => File.Exists(Photo(handle));

    public virtual byte[] ReadRange(string handle, long offset, int length)
    {
        using var file = new FileStream(Photo(handle), FileMode.Open, FileAccess.Read, FileShare.Read);
        file.Position = offset;
        var bytes = new byte[length];
        file.ReadExactly(bytes);
        return bytes;
    }

    public virtual void Truncate(string handle, long length)
    {
        using var file = new FileStream(Photo(handle), FileMode.Open, FileAccess.Write, FileShare.None);
        file.SetLength(length);
        file.Flush(true);
    }

    internal virtual void SaveMetadata(UploadMetadata metadata) =>
        WriteAtomic(Metadata(metadata.UploadHandle), JsonSerializer.SerializeToUtf8Bytes(metadata, ImageUploadStaging.JsonOptions));

    internal virtual UploadMetadata[] ReadMetadata() =>
        ReadDocuments<UploadMetadata>(MetadataSuffix, metadata => metadata.UploadHandle);

    internal virtual void SaveReceipt(UploadReceipt receipt) =>
        WriteAtomic(Receipt(receipt.UploadHandle), JsonSerializer.SerializeToUtf8Bytes(receipt, ImageUploadStaging.JsonOptions));

    internal virtual UploadReceipt[] ReadReceipts() =>
        ReadDocuments<UploadReceipt>(ReceiptSuffix, receipt => receipt.UploadHandle);

    public virtual string[] PhotoHandles()
    {
        if (!Directory.Exists(directory)) return [];
        return Directory.EnumerateFiles(directory, "*" + PhotoSuffix)
            .Select(path => Path.GetFileName(path)[..^PhotoSuffix.Length])
            .ToArray();
    }

    public virtual void DeletePhoto(string handle)
    {
        File.Delete(Photo(handle));
        if (File.Exists(Photo(handle))) throw new IOException("Photo deletion was not confirmed");
    }

    public virtual void RemovePendingFiles()
    {
        if (!Directory.Exists(directory)) return;
        foreach (var pending in Directory.EnumerateFiles(directory, "*" + PendingSuffix))
            File.Delete(pending);
    }

    private T[] ReadDocuments<T>(string suffix, Func<T, string> getHandle) where T : class
    {
        if (!Directory.Exists(directory)) return [];
        var documents = new List<T>();
        foreach (var path in Directory.EnumerateFiles(directory, "*" + suffix))
        {
            var document = JsonSerializer.Deserialize<T>(File.ReadAllBytes(path), ImageUploadStaging.JsonOptions)
                ?? throw new InvalidDataException($"Staging document is empty: {Path.GetFileName(path)}");
            var handle = Path.GetFileName(path)[..^suffix.Length];
            if (!string.Equals(handle, getHandle(document), StringComparison.Ordinal))
                throw new InvalidDataException($"Staging document handle does not match its file: {Path.GetFileName(path)}");
            documents.Add(document);
        }
        return documents.ToArray();
    }

    private void WriteAtomic(string path, byte[] contents)
    {
        Directory.CreateDirectory(directory);
        var pending = path + PendingSuffix;
        using (var file = new FileStream(pending, FileMode.Create, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
        {
            file.Write(contents);
            file.Flush(true);
        }
        File.Move(pending, path, true);
    }

    private string Photo(string handle) => Path.Combine(directory, handle + PhotoSuffix);
    private string Metadata(string handle) => Path.Combine(directory, handle + MetadataSuffix);
    private string Receipt(string handle) => Path.Combine(directory, handle + ReceiptSuffix);
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
    private bool stopping;

    public ImageUploadStaging() : this(new ImageUploadFiles(
        Environment.GetEnvironmentVariable("MCP_IMAGE_UPLOAD_DIRECTORY")
            ?? Path.Combine(AppContext.BaseDirectory, "upload-staging")))
    { }

    public ImageUploadStaging(ImageUploadFiles files)
    {
        this.files = files;
        Recover();
    }

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
            if (stopping) throw Invalid("staging-shutting-down", "Image upload staging is shutting down");
            if (byteLength > Capacity - reservedBytes)
                throw Invalid("upload-capacity-exceeded", "Staged upload capacity is unavailable; existing uploads are retained");
            var handle = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
            var entry = new Entry(handle, recipeId, new(byteLength, type.ToLowerInvariant(), sha256.ToLowerInvariant()))
            {
                Reserved = true
            };
            reservedBytes += byteLength;
            try
            {
                files.Create(handle);
                files.SaveMetadata(ToMetadata(entry));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                try
                {
                    files.DeletePhoto(handle);
                    entries.Remove(handle);
                    reservedBytes -= byteLength;
                    throw Invalid("staging-write-failed", "Could not create durable upload metadata and staged photo bytes");
                }
                catch (Exception cleanupError) when (cleanupError is IOException or UnauthorizedAccessException)
                {
                    entry.State = "failed";
                    entry.Error = new("staging-write-failed", "Could not create upload state; staged capacity remains reserved");
                    entries.Add(handle, entry);
                    try { files.SaveMetadata(ToMetadata(entry)); }
                    catch (Exception metadataError) when (metadataError is IOException or UnauthorizedAccessException) { }
                    throw Invalid("staging-write-failed", "Could not create upload state; staged capacity remains reserved");
                }
            }
            entries.Add(handle, entry);
            return Snapshot(entry);
        }
    }

    public UploadResult Chunk(string uploadHandle, int chunkNumber, string base64)
    {
        var entry = Find(uploadHandle);
        var bytes = Decode(base64);
        lock (entry.Gate)
        {
            EnsureRunning();
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

            var previousLength = entry.ReceivedBytes;
            var previousMetadata = ToMetadata(entry);
            try { files.Append(entry.Handle, bytes); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                entry.State = "failed";
                entry.Error = new("staging-write-failed", "Staged photo write failed; this upload cannot continue");
                SaveMetadataBestEffort(entry);
                return Snapshot(entry);
            }

            entry.ReceivedBytes += bytes.Length;
            entry.NextChunkNumber++;
            try { files.SaveMetadata(ToMetadata(entry)); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                entry.ReceivedBytes = previousLength;
                entry.NextChunkNumber--;
                try
                {
                    files.Truncate(entry.Handle, previousLength);
                }
                catch (Exception rollbackError) when (rollbackError is IOException or UnauthorizedAccessException)
                {
                    entry.State = "failed";
                    entry.Error = new("staging-write-failed", "Upload metadata could not be saved or reconciled; capacity remains reserved");
                    SaveMetadataBestEffort(entry);
                    return Snapshot(entry);
                }
                try { files.SaveMetadata(previousMetadata); }
                catch (Exception restoreError) when (restoreError is IOException or UnauthorizedAccessException)
                {
                    entry.State = "failed";
                    entry.Error = new("staging-metadata-write-failed", "Chunk was rolled back, but saved progress could not be reconciled; capacity remains reserved");
                    SaveMetadataBestEffort(entry);
                    return Snapshot(entry);
                }
                throw Invalid("staging-metadata-write-failed", "Chunk was not accepted because its progress could not be saved; retry the same chunk");
            }
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
        Stream? stream = null;
        lock (entry.Gate)
        {
            if (entry.Receipt is not null || entry.State != "receiving") return Snapshot(entry);
            EnsureRunning();
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
                    SaveMetadataBestEffort(entry);
                    return Snapshot(entry);
                }
                stream.Position = 0;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                stream?.Dispose();
                entry.State = "failed";
                entry.Error = new("staging-read-failed", "Could not verify staged photo bytes");
                SaveMetadataBestEffort(entry);
                return Snapshot(entry);
            }
            entry.State = "assigning";
            try { files.SaveMetadata(ToMetadata(entry)); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                entry.State = "uncertain";
                entry.Error = new("staging-metadata-write-failed", "Assignment was not started because its state could not be saved; inspect the recipe before another upload");
                SaveMetadataBestEffort(entry);
                stream.Dispose();
                return Snapshot(entry);
            }
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
                entry.Errors = assigned.Errors;
                SaveMetadataBestEffort(entry);
                return Snapshot(entry);
            }

            entry.Image = assigned.Image;
            entry.State = "finished";
            entry.Error = null;
            var receipt = new UploadReceipt(entry.Handle, entry.RecipeId, entry.Source, assigned.Image);
            try { files.SaveReceipt(receipt); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                entry.State = "uncertain";
                entry.Error = new("receipt-save-failed", "Image was assigned, but its success receipt could not be saved. Inspect the recipe; assignment will not be replayed");
                SaveMetadataBestEffort(entry);
                return Snapshot(entry);
            }

            entry.Receipt = ToResult(receipt);
            try
            {
                files.DeletePhoto(entry.Handle);
                ReleaseReservation(entry);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                entry.Error = new("staging-delete-failed", "Image was assigned and its receipt saved, but photo deletion was not confirmed. Capacity remains reserved; assignment will not be replayed");
                SaveMetadataBestEffort(entry);
            }
            return Snapshot(entry);
        }
    }

    public void Flush()
    {
        Entry[] snapshot;
        lock (capacityLock)
        {
            stopping = true;
            snapshot = entries.Values.ToArray();
        }
        foreach (var entry in snapshot)
        {
            lock (entry.Gate)
            {
                if (entry.Reserved && files.PhotoExists(entry.Handle))
                {
                    var length = files.Length(entry.Handle);
                    if (length < entry.ReceivedBytes)
                        throw new IOException("Staged photo is shorter than its saved progress");
                    if (length > entry.ReceivedBytes && entry.Receipt is null)
                        files.Truncate(entry.Handle, entry.ReceivedBytes);
                }
                if (entry.Receipt is null) files.SaveMetadata(ToMetadata(entry));
            }
        }
    }

    private void Recover()
    {
        files.RemovePendingFiles();
        foreach (var receipt in files.ReadReceipts())
        {
            ValidateHandle(receipt.UploadHandle);
            ValidateSource(receipt.Source);
            if (string.IsNullOrWhiteSpace(receipt.RecipeId) || receipt.Image is null)
                throw new InvalidDataException("A saved upload receipt is invalid");
            var entry = FromReceipt(receipt);
            if (!entries.TryAdd(entry.Handle, entry))
                throw new InvalidDataException("Duplicate upload receipt handle");
            if (files.PhotoExists(entry.Handle))
            {
                ReserveRecovered(entry);
                try
                {
                    files.DeletePhoto(entry.Handle);
                    ReleaseReservation(entry);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    entry.Error = new("staging-delete-failed", "Saved upload receipt is valid, but staged photo deletion remains unconfirmed; capacity stays reserved");
                }
            }
        }

        foreach (var metadata in files.ReadMetadata())
        {
            ValidateMetadata(metadata);
            if (entries.ContainsKey(metadata.UploadHandle)) continue;
            if (!files.PhotoExists(metadata.UploadHandle))
                throw new InvalidDataException("Upload metadata exists without its staged photo");
            var length = files.Length(metadata.UploadHandle);
            if (length < metadata.ReceivedBytes)
                throw new InvalidDataException("Staged photo is shorter than its saved progress");
            if (length > metadata.ReceivedBytes)
                files.Truncate(metadata.UploadHandle, metadata.ReceivedBytes);

            var entry = FromMetadata(metadata);
            if (entry.State is "assigning" or "finished")
            {
                entry.State = "uncertain";
                entry.Error = new("assignment-uncertain", "Assignment was interrupted without a saved result; inspect the recipe before starting another upload");
                files.SaveMetadata(ToMetadata(entry));
            }
            if (entry.State == "receiving" && entry.ReceivedBytes > 0)
            {
                var lastChunkLength = (int)Math.Min(ChunkLimit,
                    entry.ReceivedBytes % ChunkLimit == 0 ? ChunkLimit : entry.ReceivedBytes % ChunkLimit);
                entry.LatestChunk = files.ReadRange(
                    entry.Handle, entry.ReceivedBytes - lastChunkLength, lastChunkLength);
            }
            ReserveRecovered(entry);
            if (!entries.TryAdd(entry.Handle, entry))
                throw new InvalidDataException("Duplicate upload metadata handle");
        }

        foreach (var handle in files.PhotoHandles())
        {
            ValidateHandle(handle);
            if (entries.ContainsKey(handle)) continue;
            files.DeletePhoto(handle);
        }
    }

    private void ReserveRecovered(Entry entry)
    {
        if (entry.Reserved) return;
        if (entry.Source.ByteLength > Capacity - reservedBytes)
            throw new InvalidDataException("Recovered staged uploads exceed the declared capacity");
        reservedBytes += entry.Source.ByteLength;
        entry.Reserved = true;
    }

    private static void ValidateMetadata(UploadMetadata metadata)
    {
        ValidateHandle(metadata.UploadHandle);
        ValidateSource(metadata.Source);
        if (metadata.Version != 1
            || string.IsNullOrWhiteSpace(metadata.RecipeId)
            || metadata.ReceivedBytes < 0 || metadata.ReceivedBytes > metadata.Source.ByteLength
            || (metadata.ReceivedBytes < metadata.Source.ByteLength && metadata.ReceivedBytes % ChunkLimit != 0)
            || metadata.NextChunkNumber != (metadata.ReceivedBytes == 0 ? 0 : (metadata.ReceivedBytes - 1) / ChunkLimit + 1)
            || metadata.State is not ("receiving" or "assigning" or "uncertain" or "failed" or "finished"))
            throw new InvalidDataException("Recovered upload metadata is invalid");
    }

    private static void ValidateSource(UploadSource source)
    {
        if (source is null
            || source.ByteLength is <= 0 or > FileLimit
            || source.Sha256 is null || source.Sha256.Length != 64 || !source.Sha256.All(Uri.IsHexDigit)
            || !MediaTypeHeaderValue.TryParse(source.MediaType, out var parsed)
            || parsed.Parameters.Count != 0 || parsed.MediaType is not { } mediaType
            || !mediaType.StartsWith("image/", StringComparison.OrdinalIgnoreCase) || mediaType.Contains('*'))
            throw new InvalidDataException("Recovered upload source metadata is invalid");
    }

    private static void ValidateHandle(string handle)
    {
        if (handle is null || handle.Length != 64 || !handle.All(Uri.IsHexDigit))
            throw new InvalidDataException("Recovered upload handle is invalid");
    }

    private static UploadMetadata ToMetadata(Entry entry) => new(
        1, entry.Handle, entry.RecipeId, entry.Source, entry.State, entry.ReceivedBytes,
        entry.NextChunkNumber, entry.Image, entry.Error, entry.Errors);

    private static Entry FromMetadata(UploadMetadata metadata) => new(
        metadata.UploadHandle, metadata.RecipeId, metadata.Source)
    {
        State = metadata.State,
        ReceivedBytes = metadata.ReceivedBytes,
        NextChunkNumber = metadata.NextChunkNumber,
        Image = metadata.Image,
        Error = metadata.Error,
        Errors = metadata.Errors
    };

    private static Entry FromReceipt(UploadReceipt receipt) => new(
        receipt.UploadHandle, receipt.RecipeId, receipt.Source)
    {
        State = "finished",
        ReceivedBytes = receipt.Source.ByteLength,
        NextChunkNumber = (int)((receipt.Source.ByteLength - 1) / ChunkLimit + 1),
        Image = receipt.Image,
        Receipt = ToResult(receipt)
    };

    private static UploadResult ToResult(UploadReceipt receipt) => new(
        receipt.UploadHandle, receipt.RecipeId, "finished", receipt.Source.ByteLength,
        (int)((receipt.Source.ByteLength - 1) / ChunkLimit + 1), ChunkLimit,
        receipt.Source, receipt.Image);

    private void SaveMetadataBestEffort(Entry entry)
    {
        try { files.SaveMetadata(ToMetadata(entry)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    private void ReleaseReservation(Entry entry)
    {
        lock (capacityLock)
        {
            if (!entry.Reserved) return;
            reservedBytes -= entry.Source.ByteLength;
            entry.Reserved = false;
        }
    }

    private Entry Find(string handle)
    {
        lock (capacityLock)
        {
            if (stopping) throw Invalid("staging-shutting-down", "Image upload staging is shutting down");
            if (handle is { Length: 64 } && entries.TryGetValue(handle, out var entry)) return entry;
        }
        throw Invalid("unknown-upload-handle", "Upload handle is unknown or invalidated by Pod teardown");
    }

    private void EnsureRunning()
    {
        lock (capacityLock)
        {
            if (stopping) throw Invalid("staging-shutting-down", "Image upload staging is shutting down");
        }
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

    private static UploadResult Snapshot(Entry entry)
    {
        if (entry.Receipt is { } receipt) return receipt with { Error = entry.Error };
        return new(
            entry.Handle, entry.RecipeId, entry.State, entry.ReceivedBytes, entry.NextChunkNumber,
            ChunkLimit, entry.Image is null ? null : entry.Source, entry.Image, entry.Error,
            entry.State == "uncertain"
                ? "Inspect the recipe through get_recipe or the normal UI before starting another upload; this mutation will never be replayed"
                : null,
            entry.Errors);
    }

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
        public IReadOnlyList<UploadError>? Errors { get; set; }
        public UploadResult? Receipt { get; set; }
        public bool Reserved { get; set; }
    }
}

public record AssignmentResult(
    UploadedImage? Image, UploadError? Error = null, bool Uncertain = false,
    IReadOnlyList<UploadError>? Errors = null);
