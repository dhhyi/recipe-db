# MCP Integration Tests

Integration tests for the `mcp` server, implemented in Python with pytest and the official [MCP SDK](https://github.com/modelcontextprotocol/python-sdk) client, talking real stateless Streamable HTTP using protocol `2026-07-28` to exercise the protocol end-to-end (tool listing, recipe creation/validation, image upload, rating, and per-request authorization). Raw HTTP authorization tests also cover the legacy initialization protocol. Repeated fresh sessions verify response delivery through ingress without retries or longer timeouts.

Image uploads use the shared fixture service. Prepare owner and two member tokens with `mise run create-auth-test-fixture` before starting the development stack, then run `mise run integration-tests -- --development mcp-test`; the runner supplies the ignored fixture as `E2E_AUTH_TOKENS`.
