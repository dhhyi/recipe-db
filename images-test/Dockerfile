ARG TARGETARCH
ARG HURL_VERSION

FROM --platform=$BUILDPLATFORM debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS downloader
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

FROM debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4
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
