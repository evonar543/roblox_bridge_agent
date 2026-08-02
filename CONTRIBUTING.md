# Contributing

## Local setup

```powershell
npm install
npm test
```

## Pull requests

- Keep changes focused and explain the developer impact.
- Preserve loopback-only defaults and workspace path validation.
- Add or update tests for protocol, lifecycle, permission, or persistence changes.
- Run `npm test` and `npm pack --dry-run` before opening a pull request.
- Do not commit generated runtime state, logs, screenshots, capsule snapshots, credentials, or unrelated game automation.

## Code style

Use strict TypeScript, explicit names, bounded resource usage, and actionable error messages. Avoid silent failures and unbounded loops. Luau additions should include a reload/cleanup lifecycle when they create connections or background work.
