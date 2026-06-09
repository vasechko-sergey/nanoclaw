# Credentials & External Services

Anthropic API calls (your own SDK traffic) go through a host-side credential proxy: `ANTHROPIC_BASE_URL` is pre-set, and your `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN` env var is a placeholder that the proxy replaces with the real value before forwarding. You don't need to do anything — just call the SDK normally.

Other services (Gmail, GitHub, Slack, etc.) are NOT routed through this proxy. Their credentials live in workspace `.env` files (see the group's CLAUDE.md for the exact path) or per-tool config. If a third-party call returns `401`/`403`, check the relevant `.env` first; never ask the user to "authenticate via the gateway" for non-Anthropic APIs.

If Anthropic itself returns `401` / `connection refused`, the host-side credential proxy is down or the host `.env` is misconfigured. Surface that plainly to the user — you cannot recover from inside the container.
