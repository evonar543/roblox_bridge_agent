<p align="center">
  <img src="assets/rba-logo.png" width="168" alt="Roblox Bridge Agent logo">
</p>

<h1 align="center">Roblox Bridge Agent</h1>

<p align="center">
  <strong>RBA</strong> is a local-first MCP bridge and script operations layer for authorized Roblox development.
</p>

<p align="center">
  <img alt="Node 20+" src="https://img.shields.io/badge/Node.js-20%2B-5FA04E?style=flat-square">
  <img alt="TypeScript" src="https://img.shields.io/badge/TypeScript-strict-3178C6?style=flat-square">
  <img alt="Protocol" src="https://img.shields.io/badge/RBA_protocol-v4-8B7CFF?style=flat-square">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-35D6A4?style=flat-square">
</p>

RBA connects an MCP-capable coding agent to local Luau development clients through a bounded websocket protocol. It combines live execution, structured results, file watching, diagnostics, source snapshots, permission-gated script capsules, crash detection, autoexec synchronization, and a realtime browser dashboard.

> Use RBA only in experiences and local environments you own or are explicitly authorized to test. Keep its websocket and dashboard bound to loopback unless you deliberately build a secure remote deployment around them.

## Why RBA exists

Editing a script and running it are only two pieces of a dependable workflow. RBA adds the missing operational layer:

- one shared local bridge that multiple MCP sessions can discover instead of fighting over ports;
- structured eval responses, correlated errors, bounded queues, heartbeats, and backpressure protection;
- live file and profile workflows with source validation before dispatch;
- Script Capsules with explicit permissions, automatic snapshots, and reversible rollback;
- a polished local command center with live clients, events, profiles, watchers, screenshots, and capsule controls;
- Roblox process and heartbeat diagnostics, plus a narrowly scoped restart tool;
- guarded Git helpers that stage only named files and never silently sweep the workspace;
- unified autoloader synchronization for configured executor autoexec locations.

## Script OS model

RBA behaves like a small operations system around scripts:

```text
MCP client
   │
   ▼
RBA server ─── dashboard / logs / snapshots / Git status
   │
   ├── script capsule policy + preflight + rollback
   │
   ▼
local websocket bridge
   │
   ▼
RBA Luau autoloader ─── authorized Roblox development client
```

Capsules are an honest policy boundary, not a fake security claim. RBA can block dispatch based on static capabilities, manage source history, and control lifecycle state. It cannot provide OS-grade isolation after arbitrary Lua reaches an executor.

## Quick start

Requirements:

- Windows, macOS, or Linux for the Node server (Windows-only helpers are clearly scoped);
- Node.js 20 or newer;
- an MCP-capable client;
- a compatible local websocket-capable Luau environment for the client loader.

Install and verify:

```powershell
git clone --recurse-submodules https://github.com/evonar543/roblox_bridge_agent.git
Set-Location roblox_bridge_agent
npm install
npm test
```

Add the built server to your MCP configuration, replacing the example paths:

```json
{
  "mcpServers": {
    "roblox_bridge_agent": {
      "command": "node",
      "args": ["C:\\path\\to\\roblox_bridge_agent\\dist\\index.js"],
      "env": {
        "RBA_ROOT": "C:\\path\\to\\roblox_bridge_agent",
        "RBA_WS_HOST": "127.0.0.1",
        "RBA_WS_PORT": "33882",
        "RBA_WS_PORT_RANGE": "33882-33920",
        "RBA_AUTO_START_WS": "true"
      }
    }
  }
}
```

Then run the checked-in loader in your authorized development client:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/evonar543/roblox_bridge_agent/main/lua/rba_autoloader.lua"))()
```

For a pinned or offline workflow, use [`lua/rba_autoloader.lua`](lua/rba_autoloader.lua) directly instead of loading the moving `main` branch.

## Autoloader behavior

The protocol-v4 loader:

- uses a single-instance lifecycle and stops an older RBA generation on reload;
- discovers the active websocket endpoint from a bounded local port range;
- reconnects with exponential backoff and avoids connection-attempt bursts;
- enforces incoming payload, queued evaluation, queued byte, duplicate request, and execution-time limits;
- emits client heartbeats and structured traffic counters;
- exposes `_G.RBA.send`, `_G.RBA.log`, `_G.RBA.trace`, `_G.RBA.snapshot`, `_G.RBA.health`, `_G.RBA.showStatus`, and `_G.RBA.stop`;
- displays a compact connection panel that fades after successful status updates and reappears on errors;
- can start the separately installed local Instance Manager connector from a loopback-only URL.

To keep RBA separate from Instance Manager, set either value before the loader starts:

```lua
getgenv().RBA_MODE = "rba-only"
-- or
getgenv().RBA_ENABLE_INSTANCE_MANAGER = false
```

## Supported integrations

RBA now has a first-class integration registry shown by `rba_list_integrations`
and the dashboard's **Connected Workflow** panel. It reports live status for RBA
Core, the Roblox Instance Manager companion, Potassium and Volt autoexec targets,
and the active Codex MCP server.

The Roblox Instance Manager source is included as a pinned, attributed Git
submodule under `integrations/roblox-instance-manager-src`. Run
`scripts/setup-integrations.ps1` to initialize and build both projects. See
[`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md) for the full source, autoexec, MCP,
and troubleshooting workflow.

The same localhost dashboard now includes a **Setup Center** where users can add
autoexec folders, see whether each loader is current, and synchronize every
configured target without editing environment variables by hand. The guided
PowerShell installer is idempotent and explains every install, reuse, build, and
failure step.

### RBA Autoexec Manager for Windows

The standalone **RBA Autoexec Manager** provides a simple GUI for Volt,
Potassium, and custom `autoexec` folders. It reports whether
`rba_autoloader.lua` is disabled, current, or outdated. **Enable** installs the
exact loader embedded from this repository. **Disable safely** moves the active
loader and every RBA-managed sidecar completely out of `autoexec` into private
manager storage under Local AppData. Updating a different loader also preserves
it outside `autoexec`, so the executor cannot accidentally run a backup or
disabled copy.

**[Download RBA Autoexec Manager 1.0.2](https://github.com/evonar543/roblox_bridge_agent/releases/download/rba-autoexec-manager-v1.0.2/RBA.Autoexec.Manager.exe)**

#### Release safety and verification

| Check | Release 1.0.2 |
| --- | --- |
| SHA-256 | `59ed541ba09851c876c8091f84810712359229a1b6475aa82ab32677240cdb3b` |
| Checksum file | [RBA.Autoexec.Manager.v1.0.2.sha256](tools/RbaAutoexecManager/releases/RBA.Autoexec.Manager.v1.0.2.sha256) |
| Release manifest | [RBA.Autoexec.Manager.v1.0.2.manifest.json](tools/RbaAutoexecManager/releases/RBA.Autoexec.Manager.v1.0.2.manifest.json) |
| Windows signature | Unsigned; Windows may show an unknown-publisher warning |

Verify the downloaded file locally before running it:

```powershell
Get-FileHash -Algorithm SHA256 ".\RBA.Autoexec.Manager.exe"
```

The output must exactly match the SHA-256 above. A VirusTotal link for another
hash does not apply to this build. Scanner results are additional signals, not a
guarantee that any file is safe. The app's full source, embedded Lua loader, icon
generator, and build script are available in this repository for inspection.

Build a self-contained Windows x64 executable with .NET 10:

```powershell
powershell -ExecutionPolicy Bypass -File tools\RbaAutoexecManager\build.ps1
```

The executable is written to
`artifacts\rba-autoexec-manager\win-x64\RBA Autoexec Manager.exe`. It includes
the Lua loader and does not require a separately installed .NET runtime. The SVG
icon source is in `tools/RbaAutoexecManager/assets/rba-autoexec-manager.svg`.
For scripted setup, the same executable also accepts `--enable`, `--disable`, or
`--status` with `--target Volt`, `--target Potassium`, or `--directory <path>`.

## Script Capsules

A capsule manages one workspace Lua file with a stable id, display name, explicit permissions, timestamps, and source history.

Available permissions:

| Permission | Static capability covered |
| --- | --- |
| `http` | `HttpGet`, executor request functions, and `HttpService` requests |
| `filesystem` | executor file APIs such as `readfile` and `writefile` |
| `remotes` | `FireServer` and `InvokeServer` |
| `dynamic_code` | dynamic source/environment APIs such as `loadstring` |
| `transform` | direct `CFrame` and `PivotTo` writes |
| `frame_loop` | unbounded or frame/update loops |

Typical flow:

1. `rba_create_script_capsule`
2. `rba_script_preflight`
3. `rba_set_script_capsule_permissions`
4. `rba_capsule_snapshot`
5. `rba_run_script_capsule`
6. `rba_rollback_script_capsule` if the experiment needs to be reversed

Snapshots live under `.rba-capsules/` and are ignored by Git. Rollback captures the current source first, making the rollback itself reversible.

## Dashboard

Start the loopback dashboard with `rba_dashboard_start`. The default address is `http://127.0.0.1:33883/`.

The RBA Script OS dashboard provides:

- animated bridge health and live activity state;
- connected client and selected-target visibility;
- direct send/eval controls;
- profiles and file watchers;
- capsule creation, snapshot, and run actions;
- recent events, screenshots, and context snapshots;
- responsive layout and non-blocking success/error notifications.

## Tool families

RBA exposes tools in focused families instead of one oversized command:

- **Bridge:** `rba_ws_start`, `rba_ws_stop`, `rba_ws_status`, `rba_connection_info`, `rba_clients`, `rba_events`
- **Execution:** `rba_send_lua`, `rba_eval_lua`, `rba_execute_file`, `rba_execute_bundle`, `rba_lua_syntax_check`, `rba_script_preflight`
- **Capsules:** `rba_create_script_capsule`, `rba_list_script_capsules`, `rba_set_script_capsule_permissions`, `rba_capsule_snapshot`, `rba_list_capsule_snapshots`, `rba_rollback_script_capsule`, `rba_run_script_capsule`
- **Live development:** `rba_watch_file`, `rba_start_live_session`, `rba_list_script_profiles`, `rba_set_autorun`
- **Observability:** `rba_ping_clients`, `rba_probe_runtime`, `rba_context_snapshot`, console mirroring, screenshots, and structured event logs
- **Recovery:** `rba_health_check`, `rba_detect_roblox_crash`, `rba_restart_roblox`, `rba_development_snapshot`
- **Source safety:** workspace backups, restore, batch file operations, bounded reads, and search
- **Workflow:** autoexec install/sync/verification, unified status, `rba_git_status`, and `rba_git_sync_files`

Use `tools/list` from the MCP client for the authoritative schema and descriptions.

## Experimental workspace

The repository also preserves the development scripts created alongside RBA, including the goalkeeper, solo-player, Chicken Farm, and Luarmor analysis helpers under `lua/`. They remain source-visible for rollback and continued local work, but they are not part of the RBA runtime, are not included in the npm package, and must only be used in environments you own or are authorized to test.

Keeping them outside the published package gives the Git repository a complete project history without making experience-specific experiments part of the bridge's supported API.

## Safety defaults

- Websocket and dashboard hosts default to `127.0.0.1`.
- Workspace file tools reject traversal outside `RBA_ROOT`.
- Instance Manager probes and loader overrides accept loopback addresses only.
- Payload size, rate, buffered-byte, event-memory, log-file, and evaluation limits are bounded.
- Git sync requires explicit file paths, refuses a pre-staged index, and never uses `git add --all`.
- Roblox restart discovers and validates `RobloxPlayerBeta.exe`, then stops only processes with that exact executable name.
- Autoexec replacement makes a backup before overwriting changed content.

## Development

```powershell
npm run dev
npm run build
npm test
npm pack --dry-run
```

The test suite compiles TypeScript, parses the full Luau loader, validates lifecycle and protocol guardrails, exercises normal and oversized websocket traffic, verifies autoexec synchronization, and smoke-tests capsule creation and snapshots through MCP.

Architecture notes live in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Security reports should follow [`SECURITY.md`](SECURITY.md).

## License

MIT. See [`LICENSE`](LICENSE).
