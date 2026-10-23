# images

Image server for recipe-db, implemented in [Nim](https://nim-lang.org/) using [Jester](https://github.com/dom96/jester) and [Pixie](https://github.com/treeform/pixie).

An uploaded image is decoded, center-cropped to 4:3, and resized to a 650x488 normal image and a 300x225 thumbnail. Each output is encoded once as PNG and independently SHA-256 hashed. Public filenames are `<recipe-id>-<64 lowercase hex hash>.png` and `<recipe-id>-<64 lowercase hex hash>-thumb.png`, served under `/public/`.

Both complete outputs are stored in the data root's `public` directory before atomically replacing a private per-recipe JSON manifest in its `manifests` directory. The manifest preserves the current URLs and metadata across restarts. Identical output reuses existing files without changing their bytes or modification times. Superseded versions remain readable until explicit recipe deletion or a non-production wipe; retained versions intentionally consume disk space. Deletion cannot revoke copies already cached by browsers or CDNs.

Errors use Problem Details (RFC 9457).

Integration testing (in [`images-test`](../images-test)) uses [Hurl](https://hurl.dev/). Deterministic storage tests run with `mise run --raw in-devcontainer images nimble test`.

## API

| Route | Description |
| --- | --- |
| `POST /images/:recipeId` | Raw image body, `Content-Type` must be `image/jpeg`, `image/jpg` or `image/png`. Returns `201` with the published metadata as JSON, `400` for an unsupported or mismatching type, undecodable data or an oversized image, or `500` on storage failure. |
| `GET /images/:recipeId/meta` | Current metadata with `Cache-Control: no-store`, or `404` for no manifest. Malformed manifests or missing/corrupt outputs produce a logged `500` Problem Details response. Fields remain `recipeId`, `width`, `height`, `size` (normal PNG bytes), `modified` (last successful publication), `url`, and `thumbUrl`. |
| `DELETE /images/:recipeId` | Removes the manifest and all retained versions of exactly that recipe. Returns `204`, or `404`. |
| `DELETE /images` | Removes all manifests and versions. Only available outside production. |
| `GET /public/:file` | Only hash-named PNGs are public. Successful responses and conditional `304` responses use `Cache-Control: public, max-age=31536000, immutable` and a content-hash ETag; errors do not. |
| `GET /health` | Returns `204`. |

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `8000` | Port to listen on. |
| `DATA_LOCATION` | `public` | Persistent data root containing the public PNGs in `public` and private manifests in `manifests`. |
| `MAX_UPLOAD_BYTES` | `10485760` | Rejected request bodies above this size. |
| `MAX_PIXELS` | `40000000` | Rejected images above this pixel count. |
| `PRODUCTION` | unset | Set to `true` to disable `DELETE /images`. |
| `VERBOSE` | unset | Set to `true` for info level logging. |

## Development

```sh
nimble install -d -y
nimble build -d:release -y --threads:off
./server
```

The production image compiles a statically linked binary against musl and ships it in a `scratch` image.
