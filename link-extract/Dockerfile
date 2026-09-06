FROM crystallang/crystal:1.17-alpine AS builder
WORKDIR /link-extract
COPY main.cr shard.yml /link-extract/
RUN crystal build --release -o link-extract main.cr

FROM alpine:3.22
RUN apk --no-cache add ca-certificates gc libcrypto3 libevent libssl3 libxml2 pcre2 tini
COPY --from=builder /link-extract/link-extract /
EXPOSE 8081
ENTRYPOINT [ "tini", "--" ]
CMD [ "/link-extract" ]
