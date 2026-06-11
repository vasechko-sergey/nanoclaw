---
name: vercel-cli
description: Deploy apps to Vercel. Use when asked to deploy, ship, or publish a web application, or manage Vercel projects, domains, and environment variables.
---

# Vercel CLI

You can deploy web applications to Vercel using the `vercel` CLI.

**HARD RULE: You MUST NOT write HTML, CSS, or JavaScript yourself. When asked to build a website or web app, you MUST delegate to a Frontend Engineer subagent (see "Building Websites" section below). This is not optional. Violation wastes your context window on code that belongs in a separate agent.**

## Auth

The Vercel token lives in `.env` as `VERCEL_TOKEN`. Pass it explicitly on every command via `--token "$VERCEL_TOKEN"`.

Before any Vercel operation, verify auth:

```bash
vercel whoami --token "$VERCEL_TOKEN"
```

If `$VERCEL_TOKEN` is empty or `vercel whoami` returns an auth error, tell Sergei the env var is missing/invalid. He can create a token at https://vercel.com/account/tokens and add `VERCEL_TOKEN=...` to `/workspace/agent/scripts/.env`. After the container restarts (`ncl groups restart`), retry.

## Deploying

Always use `--yes` to skip interactive prompts and `--token "$VERCEL_TOKEN"` for auth.

```bash
# Deploy to production
vercel deploy --yes --prod --token "$VERCEL_TOKEN"

# Deploy from a specific directory
vercel deploy --yes --prod --token "$VERCEL_TOKEN" --cwd /path/to/project

# Preview deployment (not production)
vercel deploy --yes --token "$VERCEL_TOKEN"
```

After deploying, verify the live URL:

```bash
# Check deployment status
vercel inspect <deployment-url> --token "$VERCEL_TOKEN"
```

If you have `agent-browser` available, open the deployed URL and take a screenshot to visually verify.

## Project Management

```bash
# Link to an existing Vercel project (non-interactive)
vercel link --yes --token "$VERCEL_TOKEN"

# List recent deployments
vercel ls --token "$VERCEL_TOKEN"

# List all projects
vercel project ls --token "$VERCEL_TOKEN"
```

## Domains

```bash
# List domains
vercel domains ls --token "$VERCEL_TOKEN"

# Add a domain to the current project
vercel domains add example.com --token "$VERCEL_TOKEN"
```

## Environment Variables

```bash
# Pull env vars from Vercel to local .env
vercel env pull --token "$VERCEL_TOKEN"

# Add an env var (use echo to pipe the value — avoids interactive prompt)
echo "value" | vercel env add VAR_NAME production --token "$VERCEL_TOKEN"
```

## Common Errors

| Error | Fix |
|-------|-----|
| `Error: No framework detected` | Ensure the project has a `package.json` with a `build` script, or set the framework in `vercel.json` |
| `Error: Rate limited` | Wait and retry. Don't loop — report to user |
| `Error: You have reached your project limit` | User needs to upgrade Vercel plan or delete unused projects |
| `ENOTFOUND api.vercel.com` | Network issue. Check proxy connectivity |
| Auth error after `vercel whoami` | `VERCEL_TOKEN` is missing or expired. Tell Sergei to refresh it in `/workspace/agent/scripts/.env`, then `ncl groups restart` |

## Building Websites — Delegate to Frontend Engineer

When asked to **build, create, or redesign** a website or web app, do NOT build it yourself. You MUST delegate to a Frontend Engineer agent. This is a two-step process and **both steps are required**:

**Step 1 — Create the agent** (skip if you already have a "frontend-engineer" destination):

```
create_agent({
  name: "Frontend Engineer",
  instructions: "You are a dedicated frontend engineer. Your frontend-engineer skill has your full workflow. Build what is requested, test it visually with agent-browser, deploy to Vercel, and send back the live URL + screenshots to your parent agent when done."
})
```

**Step 2 — Send the build request** (MANDATORY — do this immediately after step 1):

```
send_message(to: "frontend-engineer", text: "<full description of what to build, including design requirements, content, colors, and any assets>")
```

⚠️ **CRITICAL**: If you skip step 2, nothing happens. The agent exists but has no work. You MUST send the message. Do NOT tell the user "it's working on it" until you have actually called send_message.

After sending, tell the user you've handed it off and will share the result when it comes back. The Frontend Engineer will send you the live URL + screenshots when done — forward those to the user.

**When to delegate vs do it yourself:**
- **Delegate**: building new sites, redesigns, multi-page apps, anything that needs visual testing
- **Do yourself**: simple `vercel deploy` of an existing project, checking deployment status, managing domains/env vars

## Best Practices

- Run `pnpm run build` locally before deploying to catch build errors early
- Use `--cwd` instead of `cd` to keep your working directory stable
- For Next.js projects, `vercel deploy` auto-detects the framework — no extra config needed
- Use `vercel.json` only when you need custom build settings, rewrites, or headers
