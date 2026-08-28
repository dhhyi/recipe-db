FROM alpine:3.21 AS build
RUN apk add --no-cache nim nimble gcc musl-dev git
WORKDIR /app
COPY images.nimble /app/
RUN nimble install -d -y
COPY server.nim /app/
RUN nimble build -d:release -y --threads:off --passL:"-static" \
  && strip server \
  && mkdir -p /data/public \
  && chown -R 65534:65534 /data

FROM scratch
COPY --from=build /app/server /server
COPY --from=build --chown=65534:65534 /data /data
USER 65534:65534
ENV PORT=8000 DATA_LOCATION=/data
EXPOSE 8000
ENTRYPOINT ["/server"]
