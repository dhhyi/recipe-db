FROM julia:1-bookworm as base
WORKDIR /app
ENV JULIA_PROJECT=/app/ JULIA_DEPOT_PATH=/app/.julia
COPY Project.toml /app/
RUN julia -e 'using Pkg; Pkg.instantiate(); Pkg.precompile(["Genie", "Images"]);'
COPY . /app
ENV PORT 8000
EXPOSE 8000

FROM julia:1-bookworm as precompile
RUN apt-get update && apt-get install -y --no-install-recommends \
  build-essential \
  clang
WORKDIR /app/
ENV JULIA_PROJECT=/app/ JULIA_DEPOT_PATH=/app/.julia
COPY --from=base /app /app/
RUN julia precompile.jl

FROM base as production
COPY --from=precompile /app/sysimage.so /app/
ENTRYPOINT ["julia", "-J", "sysimage.so", "server.jl"]

FROM base
ENTRYPOINT ["julia", "server.jl"]
