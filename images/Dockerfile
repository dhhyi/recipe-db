FROM alpine:3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a AS build
RUN apk add --no-cache nim nimble gcc musl-dev git
WORKDIR /app
COPY images.nimble /app/
RUN nimble install -d -y
COPY server.nim storage.nim processing.nim /app/
RUN nimble build -d:release -y --threads:off --passL:"-static" \
  && strip server \
  && mkdir -p /data/public \
  && chown -R 65534:65534 /data

FROM scratch
COPY --from=build /app/server /server
COPY --from=build --chown=65534:65534 /data /data
ENV PORT=8000 DATA_LOCATION=/data
EXPOSE 8000
ENTRYPOINT ["/server"]
