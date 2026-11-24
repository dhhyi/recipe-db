FROM golang:trixie@sha256:c65ecfe613b539ac74c62a4c3b2c27e8f8a6076384c8f27e8a3c0f3be17cc385 AS builder

ARG TARGETARCH
ARG SKY_VERSION=0.31.2
RUN case "$TARGETARCH" in \
      amd64) arch=x64; checksum=4088d283efa645d357ee1d0dc307d8f1662c4f3be1b3c320efd2155c76bd57a4 ;; \
      arm64) arch=arm64; checksum=ef31b9619233c21335bb47db720ad72b7d25058ed06c2d07f767444a79060a88 ;; \
      *) echo "Unsupported Sky architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/anzellai/sky/releases/download/v${SKY_VERSION}/sky-linux-${arch}.tar.gz" -o /tmp/sky.tar.gz \
    && echo "$checksum  /tmp/sky.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/sky.tar.gz -C /tmp \
    && install "/tmp/sky-linux-${arch}" /usr/local/bin/sky \
    && rm /tmp/sky.tar.gz "/tmp/sky-linux-${arch}" "/tmp/sky-ffi-inspect-sky-linux-${arch}"

WORKDIR /ws
COPY sky.toml ./
COPY src ./src
RUN --mount=type=cache,id=sky-experiment-go-mod,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,id=sky-experiment-go-build-${TARGETARCH},target=/root/.cache/go-build,sharing=locked \
    CGO_ENABLED=0 sky build src/Main.sky

FROM scratch
WORKDIR /app
ENV ENV=production \
    SKY_LIVE_BASE_PATH=/sky-experiment
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /ws/sky-out/app /app/app
USER 65532:65532
EXPOSE 8000
CMD ["/app/app"]
