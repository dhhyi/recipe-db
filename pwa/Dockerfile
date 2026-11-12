FROM debian:bookworm-slim AS icon-builder
RUN apt-get update \
  && apt-get install -y --no-install-recommends librsvg2-bin \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /pwa
COPY chef-hat.svg maskable.svg generate-icons.sh ./
RUN mkdir -p icons && ./generate-icons.sh

FROM nginx:stable-alpine@sha256:0e52bd054126cdc040b1276c0af347aeb02a41b9cfe305d6094767ac30e97949
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY manifest.webmanifest /usr/share/nginx/html/pwa/manifest.webmanifest
COPY --from=icon-builder /pwa/icons/ /usr/share/nginx/html/pwa/icons/
