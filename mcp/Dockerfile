FROM mcr.microsoft.com/dotnet/sdk:9.0-bookworm-slim AS builder

WORKDIR /ws

COPY mcp.csproj /ws/
RUN dotnet restore

COPY .graphqlrc.json operations.graphql recipe-db.graphqls *.cs /ws/
COPY Tools /ws/Tools
RUN dotnet publish -c Release -o /app

FROM mcr.microsoft.com/dotnet/aspnet:9.0-bookworm-slim

WORKDIR /app
COPY --from=builder /app /app

EXPOSE 5000
ENV ASPNETCORE_URLS=http://+:5000

CMD ["dotnet", "mcp.dll"]
