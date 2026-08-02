# Security policy

Roblox Bridge Agent is designed for local, authorized development workflows.

## Supported version

Security fixes target the latest commit on `main`.

## Reporting a vulnerability

Do not publish secrets, exploit payloads, or private environment details in a public issue. Use GitHub's private vulnerability reporting for this repository when available. Include the affected version, reproduction conditions, expected impact, and the smallest safe reproduction.

## Deployment boundary

- Keep `RBA_WS_HOST` and the dashboard host on loopback.
- Do not expose the websocket or dashboard directly to an untrusted network.
- Treat every dispatched script as code execution in the connected client.
- Treat Script Capsules as a source-policy and lifecycle boundary, not an OS sandbox.
- Review explicit capsule permissions before execution.
- Keep GitHub, MCP, executor, and operating-system credentials outside the repository.
