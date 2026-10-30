FROM nickblah/lua:5.4-luarocks-trixie@sha256:c9ccaeb9589bb0725f926713a1ad42ca2c877bfa6e1f0a1e6d7efc58d564640c AS builder
RUN apt-get update && apt-get install -y build-essential git libssl-dev m4
WORKDIR /build
COPY *.rockspec *.lua /build/
RUN luarocks make --tree lua_modules
RUN luarocks install https://raw.githubusercontent.com/dhhyi/Milua/main/milua-0.1-1.rockspec --tree lua_modules

FROM nickblah/lua:5.4-trixie@sha256:42e801f11377fce163a243e721d867b46f08f54efd4ff736ba1d969e4636a8ca
RUN apt-get update \
  && apt-get install -y \
    libssl3t64 \
    tini \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/lua_modules/share/lua /usr/local/share/lua/
COPY --from=builder /build/lua_modules/lib/lua /usr/local/lib/lua/
EXPOSE 8800
WORKDIR /app
ENTRYPOINT [ "tini", "--" ]
CMD [ "lua", "/usr/local/share/lua/5.4/inspirations_server.lua" ]
