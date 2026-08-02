# Architecture

Roblox Bridge Agent has three runtime layers and two local persistence layers.

## Runtime layers

1. **MCP server** — `src/index.ts` registers tools, validates inputs, owns workspace boundaries, and coordinates higher-level workflows.
2. **Shared websocket bridge** — one process binds a loopback port, publishes connection state, tracks clients, applies payload/rate/backpressure limits, and proxies secondary MCP sessions through a control connection.
3. **Luau autoloader** — `lua/rba_autoloader.lua` discovers the bridge, manages reconnect and single-instance lifecycle state, executes bounded requests, and returns correlated results and events.

## Local persistence

- `rba-connection.json` and `lua/rba_connection.lua` publish the active local endpoint atomically.
- `.rba-backups/`, `.rba-capsules/`, logs, and screenshots store local operational state and are ignored by Git.

## Script Capsule lifecycle

```text
register source
      │
      ▼
static preflight ── missing permission ──► blocked event
      │
      ▼
automatic snapshot
      │
      ▼
bridge dispatch ──► structured result / runtime event
      │
      ▼
optional rollback (with a safety snapshot first)
```

The static permission detector intentionally errs on the side of transparency. It identifies capability-shaped source patterns; it does not claim to prove the runtime behavior of arbitrary dynamic Lua.

## Failure containment

- Protocol messages have hard size and rate ceilings.
- The server refuses websocket sends while client buffers exceed the configured limit.
- Eval requests have correlated identifiers, duplicate protection, queue limits, and timeouts.
- Event logs are batched and rotated.
- Workspace paths are resolved and rejected if they escape `RBA_ROOT`.
- Restart logic verifies the executable basename and stops only `RobloxPlayerBeta.exe`.
- Git synchronization requires an explicit file list and a clean staging index.

## Extension points

- Add built-in presets to the `luaPresets` registry.
- Add multi-step workflows through `rba-profiles.json`.
- Extend capsule permission detection alongside documentation and tests.
- Add MCP tools as small composable operations; keep side effects explicit in names and descriptions.
