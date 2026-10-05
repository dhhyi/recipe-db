FROM --platform=$BUILDPLATFORM debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251 AS download
ARG TARGETARCH
ARG VENOM_VERSION
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://github.com/intercloud/venom/releases/download/${VENOM_VERSION}/venom.linux-${TARGETARCH}" -o /tmp/venom \
  && chmod 755 /tmp/venom

FROM debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY --from=download /tmp/venom /usr/local/bin/venom
WORKDIR /app
COPY *.yml ./
COPY venom-run ./venom-run
CMD ["sh", "venom-run"]
