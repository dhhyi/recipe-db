FROM mcr.microsoft.com/dotnet/sdk:9.0-bookworm-slim@sha256:01fabc4758d1d74e39eda700c8463dae6241a61481f973683692ddcb59a5eeb7 AS builder

WORKDIR /ws

COPY mcp.csproj /ws/
RUN dotnet restore

COPY .graphqlrc.json operations.graphql recipe-db.graphqls *.cs /ws/
COPY Tools /ws/Tools
RUN dotnet publish -c Release -o /app

FROM mcr.microsoft.com/dotnet/aspnet:9.0-bookworm-slim@sha256:2680706c9656fafe34876446d694fd25077fd0b5da478f38d56073ac6c21d37e

WORKDIR /app
COPY --from=builder /app /app

EXPOSE 5000
ENV ASPNETCORE_URLS=http://+:5000

CMD ["dotnet", "mcp.dll"]
