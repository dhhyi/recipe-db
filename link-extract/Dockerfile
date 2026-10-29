# When updating this image pin, align the Crystal version in .project.yaml with Alpine's package.
FROM alpine:3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a AS builder
RUN apk --no-cache add crystal libevent-dev libxml2-dev openssl-dev
WORKDIR /link-extract
COPY main.cr shard.yml /link-extract/
RUN crystal build --release -o link-extract main.cr

FROM alpine:3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a
RUN apk --no-cache add ca-certificates gc libcrypto3 libevent libssl3 libxml2 pcre2 tini
COPY --from=builder /link-extract/link-extract /
EXPOSE 8081
ENTRYPOINT [ "tini", "--" ]
CMD [ "/link-extract" ]
