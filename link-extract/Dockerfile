FROM denoland/deno:debian as builder
WORKDIR /app
COPY main.ts deno.jsonc /app/
RUN deno task build

FROM frolvlad/alpine-glibc
# RUN apk --no-cache add ca-certificates
RUN apk --no-cache add tini
COPY --from=builder /app/app /
EXPOSE 8081
ENTRYPOINT [ "tini", "--" ]
CMD [ "/app" ]
