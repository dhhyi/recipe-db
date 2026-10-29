FROM mcr.microsoft.com/dotnet/sdk:9.0-bookworm-slim@sha256:7e3a4bd66701a451823db2028154ae16ff191bc452596ba618ef4d0c58f9cd01 AS builder

WORKDIR /ws

COPY mcp.csproj /ws/
RUN dotnet restore

COPY .graphqlrc.json operations.graphql recipe-db.graphqls *.cs /ws/
COPY Tools /ws/Tools
RUN dotnet publish -c Release -o /app

FROM mcr.microsoft.com/dotnet/aspnet:9.0-bookworm-slim@sha256:8bbd3f6fcc157792d96f0932107d9d435df814a2c058ce2891a267fe341dea1a

WORKDIR /app
COPY --from=builder /app /app

EXPOSE 5000
ENV ASPNETCORE_URLS=http://+:5000

CMD ["dotnet", "mcp.dll"]
