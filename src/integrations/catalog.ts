export const integrationIds = [
  "rba-core",
  "roblox-instance-manager",
  "potassium",
  "volt",
  "codex-mcp"
] as const;

export type IntegrationId = typeof integrationIds[number];

export type IntegrationDescriptor = {
  id: IntegrationId;
  name: string;
  kind: "core" | "companion" | "executor" | "agent";
  summary: string;
  support: "built-in" | "bundled-source" | "autoexec" | "configuration";
  source?: {
    repository: string;
    release?: string;
    commit?: string;
    localPath?: string;
    license?: string;
  };
  setup: string[];
};

export const integrationCatalog: readonly IntegrationDescriptor[] = [
  {
    id: "rba-core",
    name: "Roblox Bridge Agent",
    kind: "core",
    summary: "The local MCP server, shared websocket bridge, Script Capsules, dashboard, diagnostics, backups, and live-edit workflow.",
    support: "built-in",
    source: {
      repository: "https://github.com/evonar543/roblox_bridge_agent",
      localPath: ".",
      license: "MIT"
    },
    setup: [
      "npm ci",
      "npm run build",
      "Register dist/index.js in the MCP client with RBA_ROOT set to this repository."
    ]
  },
  {
    id: "roblox-instance-manager",
    name: "Roblox Instance Manager",
    kind: "companion",
    summary: "The pinned Roblox-MCP companion server used for instance inspection, script/source tooling, console streaming, multi-client routing, and its port-16384 dashboard.",
    support: "bundled-source",
    source: {
      repository: "https://github.com/Muhammad-Tanvirul-Islam-Shayeem/Roblox-MCP",
      release: "v1.0.1 (Minor-Changes)",
      commit: "3a2456a871e1e1330790e964b17826518deabc80",
      localPath: "integrations/roblox-instance-manager-src",
      license: "MIT"
    },
    setup: [
      "git submodule update --init --recursive",
      "Run scripts/setup-integrations.ps1 (it works around the pinned upstream release's missing asset-copy helper without modifying its source).",
      "npm start --prefix integrations/roblox-instance-manager-src"
    ]
  },
  {
    id: "potassium",
    name: "Potassium",
    kind: "executor",
    summary: "Supported autoexec target for the unified RBA and Instance Manager Luau loader.",
    support: "autoexec",
    setup: [
      "Set RBA_AUTOEXEC_INCLUDE_DEFAULTS=true, or add the Potassium autoexec path to RBA_AUTOEXEC_PATHS.",
      "Run rba_sync_all_autoexec or rba_sync_autoexec."
    ]
  },
  {
    id: "volt",
    name: "Volt",
    kind: "executor",
    summary: "Supported autoexec target for the unified RBA and Instance Manager Luau loader.",
    support: "autoexec",
    setup: [
      "Set RBA_AUTOEXEC_INCLUDE_DEFAULTS=true, or add the Volt autoexec path to RBA_AUTOEXEC_PATHS.",
      "Run rba_sync_all_autoexec or rba_sync_autoexec."
    ]
  },
  {
    id: "codex-mcp",
    name: "Codex MCP",
    kind: "agent",
    summary: "Supported MCP host configuration for exposing every RBA tool to Codex while the websocket bridge remains shared across sessions.",
    support: "configuration",
    setup: [
      "Point the MCP command at node and dist/index.js.",
      "Set RBA_ROOT to the absolute roblox_bridge_agent repository path.",
      "Restart Codex after changing MCP configuration."
    ]
  }
] as const;

export function integrationDescriptor(id: IntegrationId): IntegrationDescriptor {
  const descriptor = integrationCatalog.find((entry) => entry.id === id);
  if (!descriptor) {
    throw new Error(`Unknown integration: ${id}`);
  }
  return descriptor;
}
