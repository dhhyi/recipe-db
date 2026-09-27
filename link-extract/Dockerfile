FROM crystallang/crystal:1.17-alpine@sha256:1d880b289d76091d6c252676f401183d1003700cf88afc0d586570ef216235fc AS builder
WORKDIR /link-extract
COPY main.cr shard.yml /link-extract/
RUN crystal build --release -o link-extract main.cr

FROM alpine:3@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
RUN apk --no-cache add ca-certificates gc libcrypto3 libevent libssl3 libxml2 pcre2 tini
COPY --from=builder /link-extract/link-extract /
EXPOSE 8081
ENTRYPOINT [ "tini", "--" ]
CMD [ "/link-extract" ]
