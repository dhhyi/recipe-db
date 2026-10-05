FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS download
ARG TARGETARCH
ARG VENOM_VERSION
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://github.com/intercloud/venom/releases/download/${VENOM_VERSION}/venom.linux-${TARGETARCH}" -o /tmp/venom \
  && chmod 755 /tmp/venom

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY --from=download /tmp/venom /usr/local/bin/venom
WORKDIR /app
COPY *.yml ./
COPY venom-run ./venom-run
CMD ["sh", "venom-run"]
