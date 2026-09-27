FROM nickblah/lua:5.4-luarocks-bookworm@sha256:184472eb59e8ed95e0a5f9dc07878a7698406eb04ffd4b0fc38800da8886c219 AS builder
RUN apt-get update && apt-get install -y build-essential git libssl-dev m4
WORKDIR /build
COPY *.rockspec *.lua /build/
RUN luarocks make --tree lua_modules
RUN luarocks install https://raw.githubusercontent.com/dhhyi/Milua/main/milua-0.1-1.rockspec --tree lua_modules

FROM nickblah/lua:5.4-bookworm@sha256:46c3241107a054cbf2af883499c66dabb9cc6dda59e5b4851b7cdbaed7f45eeb
RUN apt-get update \
  && apt-get install -y \
    libssl3 \
    tini \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/lua_modules/share/lua /usr/local/share/lua/
COPY --from=builder /build/lua_modules/lib/lua /usr/local/lib/lua/
EXPOSE 8800
WORKDIR /app
ENTRYPOINT [ "tini", "--" ]
CMD [ "lua", "/usr/local/share/lua/5.4/inspirations_server.lua" ]
