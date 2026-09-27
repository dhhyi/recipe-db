FROM benz0li/ghc-musl:9.6.6@sha256:c7cc5628a272cfec03962d412826a810b5e35802409c06dbd723651e3a5e8a0e AS builder
WORKDIR /image-inline
COPY image-inline.cabal /image-inline/
RUN cabal update && cabal build --enable-executable-static --only-dependencies
COPY Main.hs /image-inline/
RUN cabal build --enable-executable-static
RUN cp "$(cabal list-bin image-inline)" /image-inline/image-inline

FROM scratch
WORKDIR /app
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /image-inline/image-inline /app/image-inline
EXPOSE 3000
CMD [ "/app/image-inline" ]
