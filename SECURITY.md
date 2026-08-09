# Security policy

Roblox Bridge Agent is designed for local, authorized development workflows.

## Supported version

Security fixes target the latest commit on `main`.

## Reporting a vulnerability

Do not publish secrets, exploit payloads, or private environment details in a public issue. Use GitHub's private vulnerability reporting for this repository when available. Include the affected version, reproduction conditions, expected impact, and the smallest safe reproduction.

## Verifying Windows release downloads

RBA Autoexec Manager release assets include a SHA-256 checksum and JSON manifest.
Compare the downloaded EXE with the checksum published both in the GitHub release
and the repository README before running it. A checksum proves that the file you
downloaded is byte-for-byte identical to the published artifact; it does not by
itself prove that software is safe.

Release 1.0.2 is not Authenticode-signed, so Windows may show an unknown-publisher
warning. Its source and build script are under `tools/RbaAutoexecManager`, and the
release page publishes the exact SHA-256. Never reuse a VirusTotal report from a
different hash; treat scanner results as one security signal rather than an
absolute guarantee.

## Deployment boundary

- Keep `RBA_WS_HOST` and the dashboard host on loopback.
- Do not expose the websocket or dashboard directly to an untrusted network.
- Treat every dispatched script as code execution in the connected client.
- Treat Script Capsules as a source-policy and lifecycle boundary, not an OS sandbox.
- Review explicit capsule permissions before execution.
- Keep GitHub, MCP, executor, and operating-system credentials outside the repository.
