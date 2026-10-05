ARG TARGETARCH
ARG HURL_VERSION

FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS downloader
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl tar \
  && rm -rf /var/lib/apt/lists/*

FROM downloader AS download-amd64
ARG HURL_VERSION
RUN curl -fsSL "https://github.com/Orange-OpenSource/hurl/releases/download/${HURL_VERSION}/hurl-${HURL_VERSION}-x86_64-unknown-linux-gnu.tar.gz" -o /tmp/hurl.tar.gz \
  && tar -xzf /tmp/hurl.tar.gz -C /tmp \
  && cp "/tmp/hurl-${HURL_VERSION}-x86_64-unknown-linux-gnu/bin/hurl" /tmp/hurl

FROM downloader AS download-arm64
ARG HURL_VERSION
RUN curl -fsSL "https://github.com/Orange-OpenSource/hurl/releases/download/${HURL_VERSION}/hurl-${HURL_VERSION}-aarch64-unknown-linux-gnu.tar.gz" -o /tmp/hurl.tar.gz \
  && tar -xzf /tmp/hurl.tar.gz -C /tmp \
  && cp "/tmp/hurl-${HURL_VERSION}-aarch64-unknown-linux-gnu/bin/hurl" /tmp/hurl

FROM download-${TARGETARCH} AS download

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libcurl4 libxml2 libssl3 \
  && rm -rf /var/lib/apt/lists/*
COPY --from=download /tmp/hurl /usr/local/bin/hurl
RUN chmod 755 /usr/local/bin/hurl
WORKDIR /app
COPY *.hurl ./
COPY fixtures ./fixtures
COPY hurl-run ./hurl-run
ENTRYPOINT []
CMD ["sh", "hurl-run"]
