# check=skip=InvalidDefaultArgInFrom

# Versions are supplied by the generated Compose build arguments.
ARG PYTHON_VERSION
FROM mcr.microsoft.com/dotnet/sdk:9.0-bookworm-slim@sha256:7e3a4bd66701a451823db2028154ae16ff191bc452596ba618ef4d0c58f9cd01 AS mcp-builder
WORKDIR /source/mcp
COPY mcp/mcp.csproj ./
RUN --mount=type=cache,id=mcp-nuget-http,target=/root/.local/share/NuGet/http-cache,sharing=locked dotnet restore
COPY mcp/.graphqlrc.json mcp/operations.graphql mcp/recipe-db.graphqls mcp/*.cs ./
COPY mcp/Tools ./Tools
RUN --mount=type=cache,id=mcp-nuget-http,target=/root/.local/share/NuGet/http-cache,sharing=locked dotnet publish -c Release -o /published

FROM mcr.microsoft.com/dotnet/aspnet:9.0-bookworm-slim@sha256:8bbd3f6fcc157792d96f0932107d9d435df814a2c058ce2891a267fe341dea1a AS mcp-runtime

FROM python:${PYTHON_VERSION}-slim-trixie@sha256:94d3426f1def7db4a106a232ac121bfd975393e5dfd40a619b955fae45fe7913

WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential && rm -rf /var/lib/apt/lists/*
COPY --from=mcp-runtime /usr/share/dotnet /usr/share/dotnet
RUN ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet
COPY --from=mcp-builder /published /app/mcp
COPY mcp-test/requirements.txt ./
RUN pip install --no-cache-dir --requirement requirements.txt
COPY mcp-test/pyproject.toml mcp-test/test_*.py mcp-test/upload_fixture.py mcp-test/image_fixture.py mcp-test/run_tests.sh ./
CMD ["pytest", "-p", "no:cacheprovider", "--junitxml=target/junit.xml"]
