#!/bin/sh
set -eu

if [ -f /app/mcp/mcp.dll ]; then
  export MCP_UPLOAD_ASSEMBLY=/app/mcp/mcp.dll
else
  cd ../mcp
  dotnet publish -c Release -o ../mcp-test/target/mcp
  cd ../mcp-test
  export MCP_UPLOAD_ASSEMBLY=target/mcp/mcp.dll
fi

exec pytest -p no:cacheprovider --junitxml=target/junit.xml "$@"
