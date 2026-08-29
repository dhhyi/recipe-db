FROM denoland/deno:debian AS builder
WORKDIR /link-extract
COPY main.ts deno.jsonc /link-extract/
RUN deno task build

FROM frolvlad/alpine-glibc
# RUN apk --no-cache add ca-certificates
RUN apk --no-cache add tini libgcc
COPY --from=builder /link-extract/link-extract /
EXPOSE 8081
ENTRYPOINT [ "tini", "--" ]
CMD [ "/link-extract" ]
