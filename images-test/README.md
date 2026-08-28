https://hurl.dev/

https://github.com/Orange-OpenSource/hurl

The images service is reached on two Traefik entrypoints, so the tests use two
variables: `REST_API` for `/images` on `rest-internal` and `WEB_API` for `/public`
on `web`.

Thumbnail dimensions are asserted on the raw PNG bytes. After the 8 byte
signature the IHDR chunk follows, whose payload starts with width and height as
32 bit big endian integers, so a single `bytes startsWith hex,...;` covers both.
