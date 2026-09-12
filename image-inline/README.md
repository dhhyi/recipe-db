# Image Inline

Convert an image URL to an inlined image.
Implemented in [Haskell](https://www.haskell.org/) using [Scotty](https://hackage.haskell.org/package/scotty) for the REST API setup.
Errors use Problem Details (RFC 9457).
The production image is built statically against musl (via [benz0li/ghc-musl](https://github.com/benz0li/ghc-musl)) and deployed `FROM scratch`.
