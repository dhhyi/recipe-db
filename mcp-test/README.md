# MCP Integration Tests

Integration tests for the `mcp` server, implemented in Python with pytest and the official [MCP SDK](https://github.com/modelcontextprotocol/python-sdk) client, talking real Streamable HTTP to exercise the protocol end-to-end (tool listing, recipe creation/validation, image upload, rating).

Image uploads use the shared fixture service. Run this suite against a ready development stack with `mise run integration-tests -- --development mcp-test`.
