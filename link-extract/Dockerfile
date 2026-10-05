# When updating this image pin, align the Crystal version in .project.yaml with Alpine's package.
FROM alpine:3@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 AS builder
RUN apk --no-cache add crystal libevent-dev libxml2-dev openssl-dev
WORKDIR /link-extract
COPY main.cr shard.yml /link-extract/
RUN crystal build --release -o link-extract main.cr

FROM alpine:3@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
RUN apk --no-cache add ca-certificates gc libcrypto3 libevent libssl3 libxml2 pcre2 tini
COPY --from=builder /link-extract/link-extract /
EXPOSE 8081
ENTRYPOINT [ "tini", "--" ]
CMD [ "/link-extract" ]
