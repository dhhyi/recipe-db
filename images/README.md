# images

Image server for recipe-db, implemented in [Nim](https://nim-lang.org/) using [Jester](https://github.com/dom96/jester) and [Pixie](https://github.com/treeform/pixie).

An uploaded image is normalized for EXIF orientation, cropped once in oriented source coordinates, and independently resized to a 648x486 normal image and a 300x225 thumbnail, preserving PNG transparency. Omitted crops use centered automatic cropping, including for small legacy sources. Originals are discarded. Existing 650x488 images remain readable after migration. Each output is encoded once as PNG and independently SHA-256 hashed. Public filenames are `<recipe-id>-<64 lowercase hex hash>.png` and `<recipe-id>-<64 lowercase hex hash>-thumb.png`, served under `/public/`.

The `storage-version` marker in the data root is `2`. Each private `manifests/<recipe-id>.json` is an ordered JSON array of metadata entries; the first entry is the default, and an empty array has no default. Each entry's `id` is the full image's lowercase SHA-256 digest. Uploads prepend, deduplicate by that identity, and retain at most ten entries. Existing version-1 object manifests are converted only by the release-time [`images` 1-to-2 migrator](../migrators/images-1-to-2/); normal service reads reject them.

Both complete outputs are stored in the data root's `public` directory before atomically replacing the complete manifest. Entries preserve their URLs and metadata across restarts. Identical full-image output reuses existing bytes; a re-upload may update its thumbnail while keeping the same image identity. Individual collection deletion only removes the manifest entry; backup-mode compaction later removes files unreferenced by any remaining entry. Whole-recipe deletion removes every retained version, and a testing-only wipe removes all image data. Retained versions intentionally consume disk space until explicit deletion or compaction. Deletion cannot revoke copies already cached by browsers or CDNs.

Errors use Problem Details (RFC 9457).

Integration testing (in [`images-test`](../images-test)) uses [Hurl](https://hurl.dev/). Deterministic storage tests run with `mise run --raw in-devcontainer images nimble test`.

## API

| Route | Description |
| --- | --- |
| `POST /images/:recipeId` | Raw image body, `Content-Type` must be `image/jpeg`, `image/jpg` or `image/png`. Optional query parameters `cropX`, `cropY`, `cropWidth`, `cropHeight` must occur once each, all together, as nonnegative decimal integers. Dimensions must be positive, in bounds in oriented source pixels, exact 4:3 and at least 300x225. Invalid crops return `400` with codes `invalid-crop` (and the offending/missing `field`), `invalid-crop-aspect-ratio`, `crop-out-of-bounds`, or `crop-too-small`; they never fall back to automatic cropping. Returns `201` with the published metadata as JSON, including `id`, or `400` for an unsupported or mismatching type, undecodable data or excessive pixel count, `409 image-limit-reached` for a new eleventh image, `413` for excessive encoded bytes, or `500` on storage failure. |
| `GET /images/:recipeId/meta` | The ordered metadata array, or `[]` when the recipe has no images; supports a trailing slash. Successful responses use `Cache-Control: no-store`. Malformed manifests or missing/corrupt outputs produce a logged `500` Problem Details response. Each entry has `recipeId`, `id`, `width`, `height`, `size` (normal PNG bytes), `modified` (last successful publication), `url`, and `thumbUrl`. |
| `GET /images/:recipeId/meta/0` | The first/default metadata entry, or `404 image-not-found` when the collection is empty. Supports a trailing slash and validates only the default image files. |
| `DELETE /images/:recipeId/:imageId` | Removes the matching metadata entry by its full-image SHA-256 `id`; supports a trailing slash. Returns `204`, `404 image-not-found` if absent, or `400 invalid-image-id` for a malformed ID. Output files remain until backup-mode compaction. |
| `DELETE /images/:recipeId` | Removes the manifest and every retained or orphaned output of exactly that recipe. Returns `204`, or `404`. |
| `DELETE /images` or `DELETE /images/` | Removes all manifests and versions. Only available with explicit `MODE=testing`. |
| `GET /public/:file` | Only hash-named PNGs are public. Successful responses and conditional `304` responses use `Cache-Control: public, max-age=31536000, immutable` and a content-hash ETag; errors do not. |
| `GET /health` | Returns `204`. |

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `8000` | Port to listen on. |
| `DATA_LOCATION` | `public` | Persistent data root containing the public PNGs in `public` and private manifests in `manifests`. |
| `MAX_UPLOAD_BYTES` | `10485760` | Rejected request bodies above this size. |
| `MAX_PIXELS` | `40000000` | Rejected images above this pixel count. |
| `MODE` | `production` | Set to `testing` to enable `DELETE /images` for isolated tests. Empty or unsupported values fail startup. |
| `VERBOSE` | unset | Set to `true` for info level logging. |

## Development

```sh
nimble install -d -y
nimble build -d:release -y --threads:off
./server
```

The production image compiles a statically linked binary against musl and ships it in a `scratch` image.
