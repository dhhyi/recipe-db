# images

Image server for recipe-db, implemented in [Nim](https://nim-lang.org/) using
[Jester](https://github.com/dom96/jester) and [Pixie](https://github.com/treeform/pixie).

An uploaded image is decoded, stored at its original size, then center-cropped to
4:3 and resized to a 600x450 thumbnail. Both files are written as PNG into the data
folder and served statically under `/public`.

Testing (in [`images-test`](../images-test)) is done using [Hurl](https://hurl.dev/).

## API

| Route                        | Description                                                                                                                                                                              |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /images/:recipeId`     | Raw image body, `Content-Type` must be `image/jpeg`, `image/jpg` or `image/png`. Returns `201`, or `400` for an unsupported or mismatching type, undecodable data or an oversized image. |
| `GET /images/:recipeId/meta` | Metadata of the stored image, or `404`.                                                                                                                                                  |
| `DELETE /images/:recipeId`   | Removes the image and its thumbnail. Returns `204`, or `404`.                                                                                                                            |
| `DELETE /images`             | Removes all images. Only available when `TESTING` is set.                                                                                                                                |
| `GET /public/:file`          | Static delivery of the stored images.                                                                                                                                                    |
| `GET /health`                | Returns `204`.                                                                                                                                                                           |

## Configuration

| Variable           | Default    | Description                                                 |
| ------------------ | ---------- | ----------------------------------------------------------- |
| `PORT`             | `8000`     | Port to listen on.                                          |
| `DATA_LOCATION`    | `public`   | Document root, images are stored in its `public` subfolder. |
| `MAX_UPLOAD_BYTES` | `10485760` | Rejected request bodies above this size.                    |
| `MAX_PIXELS`       | `40000000` | Rejected images above this pixel count.                     |
| `TESTING`          | unset      | Enables `DELETE /images`.                                   |
| `VERBOSE`          | unset      | Set to `true` for info level logging.                       |

## Development

```sh
nimble install -d -y
nimble build -d:release -y --threads:off
./server
```

The production image compiles a statically linked binary against musl and ships it
in a `scratch` image.
