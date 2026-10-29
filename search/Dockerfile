ARG TARGETARCH

FROM --platform=$BUILDPLATFORM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 AS downloader
ARG BUILDARCH
ARG TARGETARCH
RUN test "$BUILDARCH" = "$TARGETARCH" \
  && apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates curl xz-utils pkg-config libc6-dev libcurl4-openssl-dev libnats-dev python3 python3-pip && rm -rf /var/lib/apt/lists/*

FROM downloader AS download-amd64
ENV ZIG_ARCH=x86_64 ZIG_CPU=baseline
ENV ZIG_SHA=24aeeec8af16c381934a6cd7d95c807a8cb2cf7df9fa40d359aa884195c4716c

FROM downloader AS download-arm64
ENV ZIG_ARCH=aarch64 ZIG_CPU=cortex_a53
ENV ZIG_SHA=f7a654acc967864f7a050ddacfaa778c7504a0eca8d2b678839c21eea47c992b

FROM download-${TARGETARCH} AS builder
RUN curl -fsSL "https://ziglang.org/download/0.14.1/zig-${ZIG_ARCH}-linux-0.14.1.tar.xz" -o /tmp/zig.tar.xz \
  && echo "$ZIG_SHA  /tmp/zig.tar.xz" | sha256sum -c - \
  && mkdir /opt/zig \
  && tar -xJf /tmp/zig.tar.xz --strip-components=1 -C /opt/zig
WORKDIR /ws
ENV PATH="/opt/zig:${PATH}"
COPY requirements.txt .
RUN pip install --no-cache-dir --break-system-packages -r requirements.txt
COPY build.zig .
COPY generate_operations.py test_generate_operations.py recipe-db.graphqls ./
COPY src src
ENV PKG_CONFIG_ALLOW_SYSTEM_LIBS=1 PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1
RUN python3 generate_operations.py \
  && python3 -m unittest -v \
  && zig build test -Dcpu="$ZIG_CPU" -Doptimize=ReleaseSafe \
  && zig build -Dcpu="$ZIG_CPU" -Doptimize=ReleaseSafe

FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libcurl4 libnats3.4 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /ws/zig-out/bin/search /app/search
EXPOSE 3000
CMD ["/app/search"]
