# MCP Integration Tests

Integration tests for the `mcp` server, implemented in Python with pytest and the official [MCP SDK](https://github.com/modelcontextprotocol/python-sdk) client, talking real stateless Streamable HTTP to exercise the protocol end-to-end (tool listing, recipe creation/validation, image upload, rating, and per-request authorization).

Image uploads use the shared fixture service. Prepare owner and two member tokens with `mise run create-auth-test-fixture` before starting the development stack, then run `mise run integration-tests -- --development mcp-test`; the runner supplies the ignored fixture as `E2E_AUTH_TOKENS`.
