FROM denoland/deno as builder
WORKDIR /app
COPY main.ts deno.jsonc /app/
RUN deno task build

FROM frolvlad/alpine-glibc
# RUN apk --no-cache add ca-certificates
WORKDIR /app
COPY --from=builder /app/link-extract .
EXPOSE 8081
CMD ["/app/link-extract"]

# esbuild
# FROM debian AS esbuild
# RUN apt-get update && apt-get install -y curl
# RUN curl -fsSL https://esbuild.github.io/dl/v0.18.14 | sh

# FROM denoland/deno as builder
# WORKDIR /app
# COPY main.ts /app/
# COPY --from=esbuild /esbuild /usr/local/bin/esbuild
# RUN deno bundle main.ts  | esbuild --minify > link-extract.min.js

# FROM denoland/deno:alpine
# # RUN apk --no-cache add ca-certificates
# WORKDIR /app
# COPY --from=builder /app/link-extract.min.js .
# EXPOSE 8081
# CMD ["run", "--allow-net", "/app/link-extract.min.js"]
