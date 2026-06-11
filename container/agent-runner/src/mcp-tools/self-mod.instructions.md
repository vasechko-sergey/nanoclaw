## Installing packages & tools

To install packages that persist, use the self-modification tools:

**`install_packages`** — request system (apt) or global npm packages. Requires admin approval.

Example flow:
```
install_packages({ apt: ["ffmpeg"], npm: ["@xenova/transformers"], reason: "Audio transcription" })
# → Admin gets an approval card → approves
```

**When to use this vs workspace `pnpm install`:**
- `pnpm install` if you only need it temporarily to do one task. Will not be available in subsequent truns.
- `install_packages` persists for all future turns. Use especially if the user specifically asks you to add a capability

### MCP servers (`add_mcp_server`)

Use **`add_mcp_server`** to add an MCP server to your configuration. Browse available servers at https://mcp.so — it's a curated directory of high-quality MCP servers. Most Node.js servers run via `pnpm dlx`, e.g.:

```
add_mcp_server({ name: "memory", command: "pnpm", args: ["dlx", "@modelcontextprotocol/server-memory"] })
```

**Credentials.** The MCP server gets its credentials from `.env`. If it needs a new API key / token:

1. Tell Sergei exactly which env var name you need (e.g. `BRAVE_SEARCH_API_KEY`) and where to put it — host `.env` for system-wide tokens, `/workspace/agent/scripts/.env` for agent-scoped tokens.
2. Wait for him to add it and confirm.
3. After the container restarts (`ncl groups restart`), the new env var is visible to the MCP server's process.

Never fabricate credential setup instructions; never reference a vault/gateway flow. If you don't know where the API key comes from, ask.
