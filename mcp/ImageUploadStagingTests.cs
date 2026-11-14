using System.Security.Cryptography;
using ModelContextProtocol;

namespace Mcp;

internal static class ImageUploadStagingTests
{
    public static async Task Main()
    {
        await Run("upload tools remain production-only", UploadRuntimeBoundary);
        await Run("partial upload and success receipt survive same-Pod restart", RestartPreservesState);
        await Run("interrupted assignment recovers as uncertain", InterruptedAssignmentIsUncertain);
        await Run("interrupted chunk metadata update does not claim unaccepted bytes", ChunkMetadataFailureRollsBack);
        await Run("receipt failure cannot replay assignment or release capacity", ReceiptFailureDoesNotReplay);
        await Run("photo deletion failure retains capacity and saved success", DeletionFailureRetainsCapacity);
        await Run("confirmed photo deletion releases reserved capacity", DeletionReleasesCapacity);
    }

    private static Task UploadRuntimeBoundary()
    {
        Equal(true, McpRuntime.ImageUploadsEnabled("production", null));
        Equal(true, McpRuntime.ImageUploadsEnabled("production", "0"));
        Equal(false, McpRuntime.ImageUploadsEnabled("backup", "1"));
        Equal(false, McpRuntime.ImageUploadsEnabled("testing", null));
        Equal(true, McpRuntime.ImageUploadsEnabled("testing", "1"));
        return Task.CompletedTask;
    }

    private static async Task Run(string name, Func<Task> test)
    {
        await test();
        Console.WriteLine($"PASS {name}");
    }

    private static async Task RestartPreservesState()
    {
        await WithRoot(async root =>
        {
            var data = new byte[] { 1, 2, 3, 4, 5 };
            var source = Source(data);
            var first = new ImageUploadStaging(new ImageUploadFiles(root));
            var started = first.Start("recipe", data.Length, "image/png", source.Sha256);
            var handle = started.UploadHandle;
            first.Chunk(handle, 0, Convert.ToBase64String(data));

            var restarted = new ImageUploadStaging(new ImageUploadFiles(root));
            var recovered = restarted.Status(handle);
            Equal("receiving", recovered.State);
            Equal((long)data.Length, recovered.ReceivedBytes);
            Equal(1, recovered.NextChunkNumber);
            Equal(recovered, restarted.Chunk(handle, 0, Convert.ToBase64String(data)));

            var calls = 0;
            var finished = await restarted.Finish(handle, async (stream, _) =>
            {
                calls++;
                using var result = new MemoryStream();
                await stream.CopyToAsync(result);
                Sequence(data, result.ToArray());
                return new AssignmentResult(new("image", "thumbnail", 1, 1, data.Length));
            });
            Equal(1, calls);
            Equal("finished", finished.State);
            True(!File.Exists(Path.Combine(root, handle + ".photo")));

            var afterRestart = new ImageUploadStaging(new ImageUploadFiles(root));
            Equal(finished, afterRestart.Status(handle));
            var repeated = await afterRestart.Finish(handle, (_, _) =>
            {
                calls++;
                throw new InvalidOperationException("saved success must not call assignment again");
            });
            Equal(finished, repeated);
            Equal(1, calls);
        });
    }

    private static async Task InterruptedAssignmentIsUncertain()
    {
        await WithRoot(async root =>
        {
            var data = new byte[] { 8, 9 };
            var source = Source(data);
            var files = new ImageUploadFiles(root);
            var staging = new ImageUploadStaging(files);
            var started = staging.Start("recipe", data.Length, "image/png", source.Sha256);
            staging.Chunk(started.UploadHandle, 0, Convert.ToBase64String(data));
            files.SaveMetadata(new(
                1, started.UploadHandle, "recipe", source, "assigning", data.Length, 1, null, null, null));

            var restarted = new ImageUploadStaging(new ImageUploadFiles(root));
            var recovered = restarted.Status(started.UploadHandle);
            Equal("uncertain", recovered.State);
            var calls = 0;
            var repeated = await restarted.Finish(started.UploadHandle, (_, _) =>
            {
                calls++;
                throw new InvalidOperationException("uncertain assignment must not be replayed");
            });
            Equal("uncertain", repeated.State);
            Equal(0, calls);
        });
    }

    private static Task ChunkMetadataFailureRollsBack()
    {
        return WithRoot(root =>
        {
            var data = new byte[] { 10, 11 };
            var files = new FaultInjectingFiles(root);
            var staging = new ImageUploadStaging(files);
            var started = staging.Start("recipe", data.Length, "image/png", Source(data).Sha256);
            files.FailNextMetadataWrite = true;

            try
            {
                staging.Chunk(started.UploadHandle, 0, Convert.ToBase64String(data));
                throw new InvalidOperationException("chunk should fail when progress cannot be saved");
            }
            catch (McpException error)
            {
                True(error.Message.Contains("staging-metadata-write-failed", StringComparison.Ordinal));
            }

            var restarted = new ImageUploadStaging(new ImageUploadFiles(root));
            var progress = restarted.Status(started.UploadHandle);
            Equal(0L, progress.ReceivedBytes);
            Equal(0, progress.NextChunkNumber);
            var accepted = restarted.Chunk(started.UploadHandle, 0, Convert.ToBase64String(data));
            Equal((long)data.Length, accepted.ReceivedBytes);
            return Task.CompletedTask;
        });
    }

    private static async Task ReceiptFailureDoesNotReplay()
    {
        await WithRoot(async root =>
        {
            var files = new FaultInjectingFiles(root) { FailReceiptWrites = true };
            var staging = new ImageUploadStaging(files);
            var handle = FillReservationsAndStageOne(staging, 1);
            var calls = 0;
            var result = await staging.Finish(handle, (_, _) =>
            {
                calls++;
                return Task.FromResult(new AssignmentResult(new("image", "thumbnail", 1, 1, ImageUploadStaging.FileLimit)));
            });
            Equal("uncertain", result.State);
            Equal("receipt-save-failed", result.Error?.Code);

            var restarted = new ImageUploadStaging(new ImageUploadFiles(root));
            Equal("uncertain", restarted.Status(handle).State);
            var repeated = await restarted.Finish(handle, (_, _) =>
            {
                calls++;
                throw new InvalidOperationException("assignment must not be replayed");
            });
            Equal("uncertain", repeated.State);
            Equal(1, calls);
            CapacityIsFull(restarted);
        });
    }

    private static async Task DeletionFailureRetainsCapacity()
    {
        await WithRoot(async root =>
        {
            var files = new FaultInjectingFiles(root) { FailPhotoDeletion = true };
            var staging = new ImageUploadStaging(files);
            var handle = FillReservationsAndStageOne(staging, 1);
            var result = await staging.Finish(handle, (_, _) =>
                Task.FromResult(new AssignmentResult(new("image", "thumbnail", 1, 1, ImageUploadStaging.FileLimit))));
            Equal("finished", result.State);
            Equal("staging-delete-failed", result.Error?.Code);
            True(File.Exists(Path.Combine(root, handle + ".photo")));

            var restarted = new ImageUploadStaging(new FaultInjectingFiles(root) { FailPhotoDeletion = true });
            Equal("finished", restarted.Status(handle).State);
            Equal("staging-delete-failed", restarted.Status(handle).Error?.Code);
            CapacityIsFull(restarted);
        });
    }

    private static async Task DeletionReleasesCapacity()
    {
        await WithRoot(async root =>
        {
            var staging = new ImageUploadStaging(new ImageUploadFiles(root));
            var handle = FillReservationsAndStageOne(staging, 1);
            var result = await staging.Finish(handle, (_, _) =>
                Task.FromResult(new AssignmentResult(new("image", "thumbnail", 1, 1, ImageUploadStaging.FileLimit))));
            Equal("finished", result.State);
            True(!File.Exists(Path.Combine(root, handle + ".photo")));

            var next = staging.Start(
                "after-delete", ImageUploadStaging.FileLimit, "image/png", Hash(new byte[] { 1 }));
            True(!string.IsNullOrEmpty(next.UploadHandle));
        });
    }

    private static string FillReservationsAndStageOne(ImageUploadStaging staging, int uploadToStage)
    {
        UploadResult? selected = null;
        for (var i = 0; i < ImageUploadStaging.Capacity / ImageUploadStaging.FileLimit; i++)
        {
            var data = i == uploadToStage ? new byte[checked((int)ImageUploadStaging.FileLimit)] : [];
            if (i == uploadToStage) Array.Fill(data, (byte)42);
            var hash = i == uploadToStage ? Hash(data) : Hash(new byte[] { 1 });
            var started = staging.Start($"recipe-{i}", ImageUploadStaging.FileLimit, "image/png", hash);
            if (i != uploadToStage) continue;

            selected = started;
            for (var chunk = 0; chunk < data.Length; chunk += ImageUploadStaging.ChunkLimit)
            {
                var part = data.AsSpan(chunk, Math.Min(ImageUploadStaging.ChunkLimit, data.Length - chunk)).ToArray();
                selected = staging.Chunk(
                    started.UploadHandle, chunk / ImageUploadStaging.ChunkLimit, Convert.ToBase64String(part));
            }
        }
        return selected?.UploadHandle ?? throw new InvalidOperationException("Selected upload was not created");
    }

    private static void CapacityIsFull(ImageUploadStaging staging)
    {
        try
        {
            staging.Start("one-too-many", 1, "image/png", Hash(new byte[] { 1 }));
            throw new InvalidOperationException("full staging capacity must reject another upload");
        }
        catch (McpException error)
        {
            True(error.Message.Contains("upload-capacity-exceeded", StringComparison.Ordinal));
        }
    }

    private static UploadSource Source(byte[] data) =>
        new(data.Length, "image/png", Hash(data));

    private static string Hash(byte[] data) =>
        Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    private static async Task WithRoot(Func<string, Task> test)
    {
        var root = Path.Combine(Path.GetTempPath(), $"mcp-staging-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try { await test(root); }
        finally { Directory.Delete(root, true); }
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"Expected {expected}, got {actual}");
    }

    private static void Sequence(byte[] expected, byte[] actual)
    {
        if (!expected.AsSpan().SequenceEqual(actual))
            throw new InvalidOperationException("Byte sequence differs");
    }

    private static void True(bool value)
    {
        if (!value) throw new InvalidOperationException("Assertion failed");
    }

    private sealed class FaultInjectingFiles(string root) : ImageUploadFiles(root)
    {
        public bool FailNextMetadataWrite { get; set; }
        public bool FailReceiptWrites { get; set; }
        public bool FailPhotoDeletion { get; set; }

        internal override void SaveMetadata(UploadMetadata metadata)
        {
            if (FailNextMetadataWrite)
            {
                FailNextMetadataWrite = false;
                throw new IOException("injected metadata failure");
            }
            base.SaveMetadata(metadata);
        }

        internal override void SaveReceipt(UploadReceipt receipt)
        {
            if (FailReceiptWrites) throw new IOException("injected receipt failure");
            base.SaveReceipt(receipt);
        }

        public override void DeletePhoto(string handle)
        {
            if (FailPhotoDeletion) throw new IOException("injected deletion failure");
            base.DeletePhoto(handle);
        }
    }
}
