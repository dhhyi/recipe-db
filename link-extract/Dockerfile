FROM denoland/deno:debian as builder
WORKDIR /app
COPY main.ts deno.jsonc /app/
RUN deno task build

FROM frolvlad/alpine-glibc
# RUN apk --no-cache add ca-certificates
RUN apk --no-cache add tini
WORKDIR /app
COPY --from=builder /app/link-extract .
EXPOSE 8081
ENTRYPOINT [ "tini", "--" ]
CMD [ "/app/link-extract" ]
