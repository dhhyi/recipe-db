FROM --platform=$BUILDPLATFORM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 AS download
ARG TARGETARCH
ARG VENOM_VERSION
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://github.com/intercloud/venom/releases/download/${VENOM_VERSION}/venom.linux-${TARGETARCH}" -o /tmp/venom \
  && chmod 755 /tmp/venom

FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY --from=download /tmp/venom /usr/local/bin/venom
WORKDIR /app
COPY *.yml ./
COPY venom-run ./venom-run
CMD ["sh", "venom-run"]
