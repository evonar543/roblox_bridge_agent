# Integration setup

RBA has one integration registry shared by its MCP tools and dashboard. Run
`rba_list_integrations` for the authoritative live view; it distinguishes source
availability from a connector that is actually running.

| Integration | Support | Detection |
| --- | --- | --- |
| RBA Core | Built in | websocket/proxy health |
| Roblox Instance Manager | First-class companion | loopback loader endpoint, client advertisement, pinned source |
| Potassium | Autoexec target | file presence and source hash |
| Volt | Autoexec target | file presence and source hash |
| Codex MCP | Built in | active RBA MCP process |

## Full Windows setup

Requirements are Node.js 20+, Git, and PowerShell 7 or Windows PowerShell 5.1.

```powershell
git clone --recurse-submodules https://github.com/evonar543/roblox_bridge_agent.git
Set-Location roblox_bridge_agent
./scripts/setup-integrations.ps1
npm test
```

The setup script is safe to rerun. It labels already-installed dependencies,
rebuilds both projects, validates required tools, initializes the pinned source,
and stops with the exact failed step if anything goes wrong. Use `-ForceInstall`
to refresh dependency folders or `-StartInstanceManager` to launch the companion
in a hidden background process after a successful build.

If RBA was cloned without submodules, the setup script initializes them. Start
the companion Instance Manager separately:

```powershell
npm start --prefix integrations/roblox-instance-manager-src
```

The pinned upstream release references a `scripts/copy-assets.mjs` file that is
not present in its repository. RBA's setup wrapper works around that upstream
packaging defect transparently: it installs with lifecycle scripts disabled,
compiles TypeScript, and copies only the checked-in dashboard assets into `dist`.
The submodule itself remains unmodified.

It serves its loader at `http://127.0.0.1:16384/script.luau`. RBA refuses a
non-loopback Instance Manager URL. The unified RBA loader can start that local
companion automatically, or you can use the upstream-compatible loader directly:

```lua
local bridgeUrl = getgenv().BridgeURL or "localhost:16384"
loadstring(game:HttpGet("http://" .. bridgeUrl .. "/script.luau"))()
```

Use only in development clients and experiences you own or are authorized to test.

## Executor autoexec

The checked-in `lua/rba_autoloader.lua` is the single unified loader. RBA can
discover and synchronize configured autoexec destinations for Potassium and Volt.
Use `rba_sync_autoexec`, then verify with `rba_unified_status`. Existing files are
backed up before replacement.

Windows users can also build or run the standalone **RBA Autoexec Manager** in
`tools/RbaAutoexecManager`. Its GUI detects enabled, disabled, and outdated
states for Volt, Potassium, or a custom folder. The executable embeds this same
checked-in loader, updates it atomically, and preserves recoverable backup or
disabled copies in the manager's Local AppData storage outside `autoexec`. Only
the one active `rba_autoloader.lua` is ever left in `autoexec` while enabled;
disabling evacuates every RBA-managed loader, backup, and temporary file.

To run RBA without the companion connector:

```lua
getgenv().RBA_MODE = "rba-only"
-- or
getgenv().RBA_ENABLE_INSTANCE_MANAGER = false
```

## Codex MCP configuration

Build RBA, then point the MCP entry to this repository's compiled server:

```json
{
  "mcpServers": {
    "roblox_bridge_agent": {
      "command": "node",
      "args": ["C:\\path\\to\\roblox_bridge_agent\\dist\\index.js"],
      "env": {
        "RBA_ROOT": "C:\\path\\to\\roblox_bridge_agent",
        "RBA_AUTO_START_WS": "true"
      }
    }
  }
}
```

Restart the MCP host after changing its configuration. Confirm the setup with
`rba_list_integrations`, `rba_integration_status`, or the Connected Workflow
section of `rba_dashboard_start`.

## Local Setup Center

Start `rba_dashboard_start` and open `http://127.0.0.1:33883/`. The Setup Center
lets a less-technical user paste an executor's `autoexec` folder, persist it in
the local `rba-settings.json`, see exactly what RBA detected, and synchronize all
configured targets. RBA controls the destination filename, rejects drive roots,
backs up changed loaders, and never commits machine-specific settings.

## Source provenance

The companion source is not silently copied or rewritten. It is retained as a
pinned Git submodule, so its upstream authorship, license, and commit history are
visible and upgrades can be reviewed as explicit submodule changes.
