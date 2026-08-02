#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { WebSocketServer, WebSocket } from "ws";
import { execFile, spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { createServer, type IncomingMessage, type Server as HttpServer, type ServerResponse } from "node:http";
import { watch, type FSWatcher, promises as fs } from "node:fs";
import path from "node:path";
import process from "node:process";
import { promisify } from "node:util";

type ClientRecord = {
  id: number;
  address: string;
  connectedAt: string;
  lastMessageAt?: string;
  lastHeartbeatAt?: string;
  hello?: unknown;
  role: "pending" | "executor" | "control";
  rateWindowStartedAt: number;
  messagesInRateWindow: number;
  socket: WebSocket;
};

type EventRecord = {
  at: string;
  type: string;
  clientId?: number;
  message: string;
  data?: unknown;
};

type ClientTarget = "all" | "first" | number;

type FileWatcherRecord = {
  id: string;
  path: string;
  resolvedPath: string;
  target: ClientTarget;
  mode: "send" | "eval";
  syntaxCheck: boolean;
  timeoutMs: number;
  debounceMs: number;
  createdAt: string;
  sends: number;
  lastSentAt?: string;
  timer?: NodeJS.Timeout;
  watcher: FSWatcher;
};

type ScriptProfileAction = {
  type: "preset" | "file" | "eval" | "lua";
  preset?: keyof typeof luaPresets;
  path?: string;
  script?: string;
  label?: string;
  target?: ClientTarget;
  timeoutMs?: number;
};

type PendingResponse = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timeout: NodeJS.Timeout;
  clientId?: number;
};

type ControlPayload = Record<string, unknown>;

type EventWaiter = {
  resolve: (value: EventRecord) => void;
  timeout: NodeJS.Timeout;
  type?: string;
  clientId?: number;
};

type ConnectionState = {
  version: 1;
  name: "RBA";
  mode: "server" | "proxy";
  host: string;
  port: number;
  url: string;
  portCandidates: number[];
  candidateUrls: string[];
  pid: number;
  workspaceRoot: string;
  updatedAt: string;
  checks: {
    hostValid: boolean;
    portValid: boolean;
    candidateCount: number;
    activeUrlFirst: boolean;
  };
};

type AutorunConfig = {
  enabled: boolean;
  profile?: string;
  files: string[];
  mode: "send" | "eval";
  target: ClientTarget;
  timeoutMs: number;
};

const capsulePermissions = ["http", "filesystem", "remotes", "dynamic_code", "transform", "frame_loop"] as const;
type CapsulePermission = typeof capsulePermissions[number];

type ScriptCapsule = {
  id: string;
  name: string;
  filePath: string;
  permissions: CapsulePermission[];
  createdAt: string;
  updatedAt: string;
  lastSnapshotId?: string;
  lastRunAt?: string;
};

type CapsuleRegistry = {
  version: 1;
  capsules: ScriptCapsule[];
};

const MAX_PORT_CANDIDATES = Number.parseInt(process.env.RBA_MAX_PORT_CANDIDATES ?? "256", 10);
const CONTROL_CONNECT_TIMEOUT_MS = Number.parseInt(process.env.RBA_CONTROL_CONNECT_TIMEOUT_MS ?? "350", 10);
const CONTROL_PROBE_BATCH_SIZE = Number.parseInt(process.env.RBA_CONTROL_PROBE_BATCH_SIZE ?? "8", 10);
const DEFAULT_PORT = Number.parseInt(process.env.RBA_WS_PORT ?? "33882", 10);
const DEFAULT_HOST = process.env.RBA_WS_HOST ?? "127.0.0.1";
const DEFAULT_PORT_CANDIDATES = parsePortCandidates(process.env.RBA_WS_PORT_RANGE ?? "33882-33920", DEFAULT_PORT);
const DEFAULT_DASHBOARD_PORT = Number.parseInt(process.env.RBA_DASHBOARD_PORT ?? "33883", 10);
const EVENT_LIMIT = Number.parseInt(process.env.RBA_EVENT_LIMIT ?? "1000", 10);
const EVENT_LOG_FLUSH_MS = Number.parseInt(process.env.RBA_EVENT_LOG_FLUSH_MS ?? "100", 10);
const EVENT_DATA_MAX_BYTES = Number.parseInt(process.env.RBA_EVENT_DATA_MAX_BYTES ?? "16384", 10);
const MAX_PENDING_LOG_LINES = Number.parseInt(process.env.RBA_MAX_PENDING_LOG_LINES ?? "5000", 10);
const LOG_MAX_FILE_BYTES = Number.parseInt(process.env.RBA_LOG_MAX_FILE_BYTES ?? "10485760", 10);
const LOG_ROTATIONS = Number.parseInt(process.env.RBA_LOG_ROTATIONS ?? "3", 10);
const WS_MAX_PAYLOAD_BYTES = Number.parseInt(process.env.RBA_WS_MAX_PAYLOAD_BYTES ?? "1048576", 10);
const WS_MAX_BUFFERED_BYTES = Number.parseInt(process.env.RBA_WS_MAX_BUFFERED_BYTES ?? "1048576", 10);
const WS_RATE_LIMIT = Number.parseInt(process.env.RBA_WS_RATE_LIMIT ?? "600", 10);
const WS_RATE_WINDOW_MS = Number.parseInt(process.env.RBA_WS_RATE_WINDOW_MS ?? "10000", 10);
const FILE_IO_CONCURRENCY = Number.parseInt(process.env.RBA_FILE_IO_CONCURRENCY ?? "16", 10);
const SEARCH_MAX_FILE_BYTES = Number.parseInt(process.env.RBA_SEARCH_MAX_FILE_BYTES ?? "2097152", 10);
const PROFILE_PATH = process.env.RBA_PROFILES_PATH ?? "rba-profiles.json";
const LOG_DIR = process.env.RBA_LOG_DIR ?? "logs";
const LOG_VALUE_DEPTH = Number.parseInt(process.env.RBA_LOG_VALUE_DEPTH ?? "5", 10);
const BACKUP_DIR = ".rba-backups";
const CAPSULE_DIR = ".rba-capsules";
const CAPSULE_REGISTRY_PATH = process.env.RBA_CAPSULES_PATH ?? "rba-capsules.json";
const AUTOEXEC_FILENAME = "rba_autoloader.lua";
const CONSOLE_EVENT_TYPES = new Set(["client_print", "client_warn", "client_error", "client_console", "client_console_dropped", "log", "trace"]);
const AUTO_SYNC_AUTOEXEC = (process.env.RBA_SYNC_AUTOEXEC ?? "true").toLowerCase() !== "false";
const INSTANCE_MANAGER_SCRIPT_URL = process.env.RBA_INSTANCE_MANAGER_SCRIPT_URL ?? "http://127.0.0.1:16384/script.luau";
const workspaceRoot = path.resolve(process.env.RBA_ROOT ?? process.cwd());
const connectionStatePath = path.join(workspaceRoot, "rba-connection.json");
const luaConnectionStatePath = path.join(workspaceRoot, "lua", "rba_connection.lua");
const includeDefaultAutoexecTargets = (process.env.RBA_AUTOEXEC_INCLUDE_DEFAULTS ?? "true").toLowerCase() !== "false";
const defaultExecutorAutoexecPaths = process.env.LOCALAPPDATA && includeDefaultAutoexecTargets
  ? [
      path.join(process.env.LOCALAPPDATA, "Potassium", "autoexec", AUTOEXEC_FILENAME),
      path.join(process.env.LOCALAPPDATA, "Volt", "autoexec", AUTOEXEC_FILENAME)
    ]
  : [];
const configuredAutoexecPaths = (process.env.RBA_AUTOEXEC_PATHS ?? "")
  .split(";")
  .map((value) => value.trim())
  .filter(Boolean);
const autoexecTargetPaths = Array.from(new Set([
  ...(process.env.RBA_AUTOEXEC_PATH ? [process.env.RBA_AUTOEXEC_PATH] : []),
  ...configuredAutoexecPaths,
  ...defaultExecutorAutoexecPaths
].map((value) => path.resolve(value))));
const defaultAutoexecPath = autoexecTargetPaths[0] ?? "";
const execFileAsync = promisify(execFile);
const clients = new Map<number, ClientRecord>();
const events: EventRecord[] = [];
const pendingResponses = new Map<string, PendingResponse>();
const pendingControlResponses = new Map<string, PendingResponse>();
const eventWaiters: EventWaiter[] = [];
const fileWatchers = new Map<string, FileWatcherRecord>();
const processStartedAt = Date.now();
const pendingEventLogLines: string[] = [];
const pendingConsoleJsonLines: string[] = [];
const pendingConsoleTextLines: string[] = [];
let eventLogFlushTimer: NodeJS.Timeout | undefined;
let eventLogFlushChain = Promise.resolve();
let logDirectoryReady = false;
let socketMessagesReceived = 0;
let socketBytesReceived = 0;
let socketMessagesSent = 0;
let socketBytesSent = 0;
let socketMessagesDropped = 0;
let eventLogLinesDropped = 0;
let autorunConfig: AutorunConfig = {
  enabled: false,
  files: [],
  mode: "send",
  target: "all",
  timeoutMs: 8000
};
let nextClientId = 1;
let webSocketServer: WebSocketServer | undefined;
let wsHost = DEFAULT_HOST;
let wsPort = DEFAULT_PORT;
let selectedClientId: number | undefined;
let bridgeControlSocket: WebSocket | undefined;
let bridgeControlUrl: string | undefined;
let dashboardServer: HttpServer | undefined;
let dashboardHost = "127.0.0.1";
let dashboardPort = DEFAULT_DASHBOARD_PORT;

const DEBUG_RUNTIME_LUA = String.raw`_G.RBA = _G.RBA or {}

local function safeType(value)
    local ok, result = pcall(function()
        return typeof(value)
    end)
    if ok then
        return result
    end
    return type(value)
end

local function inspect(value, depth, seen)
    depth = depth or 4
    seen = seen or {}

    local valueType = safeType(value)
    if value == nil or valueType == "boolean" or valueType == "number" or valueType == "string" then
        return value
    end

    if valueType == "Vector2" then
        return { kind = "Vector2", x = value.X, y = value.Y }
    end
    if valueType == "Vector3" then
        return { kind = "Vector3", x = value.X, y = value.Y, z = value.Z }
    end
    if valueType == "Color3" then
        return { kind = "Color3", r = value.R, g = value.G, b = value.B }
    end
    if valueType == "CFrame" then
        local position = value.Position
        return { kind = "CFrame", position = inspect(position, depth - 1, seen) }
    end
    if valueType == "EnumItem" then
        return { kind = "EnumItem", value = tostring(value) }
    end
    if valueType == "Instance" then
        local fullName = "<unknown>"
        pcall(function()
            fullName = value:GetFullName()
        end)
        return {
            kind = "Instance",
            className = value.ClassName,
            name = value.Name,
            path = fullName
        }
    end

    if type(value) == "table" then
        if seen[value] then
            return { kind = "cycle", value = tostring(value) }
        end
        if depth <= 0 then
            return { kind = "table", value = tostring(value), truncated = true }
        end

        seen[value] = true
        local output = {}
        local count = 0
        for key, child in pairs(value) do
            count = count + 1
            if count > 80 then
                output.__truncated = true
                break
            end
            output[tostring(key)] = inspect(child, depth - 1, seen)
        end
        seen[value] = nil
        return output
    end

    return { kind = valueType, value = tostring(value) }
end

local function collectSnapshot()
    local Players = game:GetService("Players")
    local Stats = game:GetService("Stats")
    local Workspace = game:GetService("Workspace")
    local localPlayer = Players.LocalPlayer
    local character = localPlayer and localPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local camera = Workspace.CurrentCamera

    local memoryMb
    pcall(function()
        memoryMb = Stats:GetTotalMemoryUsageMb()
    end)

    return {
        place = {
            name = game.Name,
            placeId = game.PlaceId,
            gameId = game.GameId,
            jobId = game.JobId,
            creatorId = game.CreatorId,
            creatorType = tostring(game.CreatorType)
        },
        player = localPlayer and {
            name = localPlayer.Name,
            displayName = localPlayer.DisplayName,
            userId = localPlayer.UserId
        } or nil,
        character = character and {
            name = character.Name,
            humanoid = humanoid and {
                health = humanoid.Health,
                maxHealth = humanoid.MaxHealth,
                walkSpeed = humanoid.WalkSpeed,
                jumpPower = humanoid.JumpPower,
                floorMaterial = tostring(humanoid.FloorMaterial),
                moveDirection = inspect(humanoid.MoveDirection, 2)
            } or nil,
            root = root and {
                position = inspect(root.Position, 2),
                velocity = inspect(root.AssemblyLinearVelocity, 2),
                anchored = root.Anchored
            } or nil
        } or nil,
        camera = camera and {
            cameraType = tostring(camera.CameraType),
            cameraSubject = inspect(camera.CameraSubject, 2),
            cframe = inspect(camera.CFrame, 2),
            fieldOfView = camera.FieldOfView
        } or nil,
        players = {
            count = #Players:GetPlayers(),
            maxPlayers = Players.MaxPlayers
        },
        runtime = {
            clock = os.clock(),
            memoryMb = memoryMb,
            hasGetGenv = type(getgenv) == "function",
            hasHookFunction = type(hookfunction) == "function",
            hasWebSocket = WebSocket ~= nil or Websocket ~= nil or websocket ~= nil or (syn and syn.websocket) ~= nil
        }
    }
end

_G.RBA.inspect = inspect
_G.RBA.snapshot = collectSnapshot
_G.RBA.trace = function(label, data)
    if _G.RBA and _G.RBA.send then
        _G.RBA.send({
            type = "trace",
            label = label,
            data = inspect(data, 4),
            at = os.time(),
            clock = os.clock()
        })
    end
end

return {
    installed = true,
    version = 2,
    snapshot = collectSnapshot()
}`;

const DEFAULT_CONSOLE_RATE_LIMIT = 12;

function buildConsoleMirrorLua(maxPerSecond = DEFAULT_CONSOLE_RATE_LIMIT): string {
  const safeLimit = Math.max(1, Math.min(Math.floor(maxPerSecond), 120));
  return String.raw`_G.RBA = _G.RBA or {}
local env = _G
pcall(function()
    if type(getgenv) == "function" then
        env = getgenv()
    end
end)

if not env.__RBA_ORIGINAL_PRINT then
    env.__RBA_ORIGINAL_PRINT = env.print or print
end
if not env.__RBA_ORIGINAL_WARN then
    env.__RBA_ORIGINAL_WARN = env.warn or warn
end

local LOG_DEPTH = 2
local MAX_PER_SECOND = ${safeLimit}
local rate = { windowStarted = os.clock(), sent = 0, dropped = 0 }
env.__RBA_CONSOLE_RATE = rate

local function pack(...)
    local output = {}
    local count = select("#", ...)
    for index = 1, count do
        local value = select(index, ...)
        if _G.RBA and _G.RBA.inspect then
            output[index] = _G.RBA.inspect(value, LOG_DEPTH)
        else
            output[index] = tostring(value)
        end
    end
    output.n = count
    return output
end

local function shouldForward()
    local current = os.clock()
    if current - rate.windowStarted >= 1 then
        if rate.dropped > 0 and _G.RBA and _G.RBA.send then
            pcall(_G.RBA.send, {
                type = "client_console_dropped",
                dropped = rate.dropped,
                rateLimit = MAX_PER_SECOND,
                at = os.time(),
                clock = current
            })
        end
        rate.windowStarted = current
        rate.sent = 0
        rate.dropped = 0
    end
    if rate.sent >= MAX_PER_SECOND then
        rate.dropped = rate.dropped + 1
        return false
    end
    rate.sent = rate.sent + 1
    return true
end

env.print = function(...)
    env.__RBA_ORIGINAL_PRINT(...)
    if shouldForward() and _G.RBA and _G.RBA.send then
        pcall(_G.RBA.send, { type = "client_print", values = pack(...), at = os.time(), clock = os.clock() })
    end
end

env.warn = function(...)
    env.__RBA_ORIGINAL_WARN(...)
    if shouldForward() and _G.RBA and _G.RBA.send then
        pcall(_G.RBA.send, { type = "client_warn", values = pack(...), at = os.time(), clock = os.clock() })
    end
end

return { installed = true, mirrored = { "print", "warn" }, maxPerSecond = MAX_PER_SECOND }`;
}

const CONSOLE_MIRROR_LUA = buildConsoleMirrorLua();

const CONSOLE_MIRROR_UNINSTALL_LUA = String.raw`local env = _G
pcall(function()
    if type(getgenv) == "function" then
        env = getgenv()
    end
end)

local restored = {}
if env.__RBA_ORIGINAL_PRINT then
    env.print = env.__RBA_ORIGINAL_PRINT
    env.__RBA_ORIGINAL_PRINT = nil
    restored.print = true
end
if env.__RBA_ORIGINAL_WARN then
    env.warn = env.__RBA_ORIGINAL_WARN
    env.__RBA_ORIGINAL_WARN = nil
    restored.warn = true
end
env.__RBA_CONSOLE_RATE = nil

return { uninstalled = true, restored = restored }`;

const runtimeProbeScripts = {
  summary: "return _G.RBA and _G.RBA.snapshot and _G.RBA.snapshot() or { error = 'RBA debug runtime is not installed' }",
  character: String.raw`local Players = game:GetService("Players")
local player = Players.LocalPlayer
local character = player and player.Character
local humanoid = character and character:FindFirstChildOfClass("Humanoid")
local root = character and character:FindFirstChild("HumanoidRootPart")
return {
    player = player,
    character = character,
    humanoid = humanoid and {
        health = humanoid.Health,
        maxHealth = humanoid.MaxHealth,
        walkSpeed = humanoid.WalkSpeed,
        jumpPower = humanoid.JumpPower,
        state = tostring(humanoid:GetState()),
        moveDirection = humanoid.MoveDirection
    } or nil,
    root = root and {
        cframe = root.CFrame,
        position = root.Position,
        velocity = root.AssemblyLinearVelocity,
        anchored = root.Anchored
    } or nil
}`,
  camera: String.raw`local camera = workspace.CurrentCamera
return camera and {
    cframe = camera.CFrame,
    cameraType = tostring(camera.CameraType),
    cameraSubject = camera.CameraSubject,
    fieldOfView = camera.FieldOfView,
    viewportSize = camera.ViewportSize
} or nil`,
  players: String.raw`local Players = game:GetService("Players")
local output = {}
for _, player in ipairs(Players:GetPlayers()) do
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    output[#output + 1] = {
        name = player.Name,
        displayName = player.DisplayName,
        userId = player.UserId,
        character = character,
        position = root and root.Position or nil
    }
end
return output`,
  environment: String.raw`local env = _G
pcall(function()
    if type(getgenv) == "function" then
        env = getgenv()
    end
end)
local keys = {}
for key in pairs(env) do
    keys[#keys + 1] = tostring(key)
    if #keys >= 120 then
        break
    end
end
table.sort(keys)
return {
    keys = keys,
    capabilities = {
        getgenv = type(getgenv) == "function",
        getrenv = type(getrenv) == "function",
        hookfunction = type(hookfunction) == "function",
        getgc = type(getgc) == "function",
        firetouchinterest = type(firetouchinterest) == "function",
        request = type(request) == "function" or type(http_request) == "function" or syn and type(syn.request) == "function"
    }
}`,
  datamodel: String.raw`local services = { "Workspace", "Players", "ReplicatedStorage", "ReplicatedFirst", "StarterGui", "StarterPlayer", "Lighting", "SoundService" }
local output = {}
for _, serviceName in ipairs(services) do
    local ok, service = pcall(function()
        return game:GetService(serviceName)
    end)
    output[serviceName] = ok and {
        childCount = #service:GetChildren(),
        path = service:GetFullName()
    } or { error = tostring(service) }
end
return output`
} as const;

const luaPresets = {
  connection_test: {
    description: "Prints in the Roblox output and sends a structured pong back to the MCP websocket server.",
    script: String.raw`local message = "[RBA] Connection test OK"
print(message)
if _G.RBA and _G.RBA.send then
    _G.RBA.send({
        type = "connection_test",
        ok = true,
        message = message,
        placeId = game.PlaceId,
        jobId = game.JobId,
        at = os.time()
    })
end`
  },
  experience_info: {
    description: "Reports current game, place, job, player count, and creator metadata when available.",
    script: String.raw`local Players = game:GetService("Players")
local info = {
    type = "experience_info",
    name = game.Name,
    placeId = game.PlaceId,
    gameId = game.GameId,
    jobId = game.JobId,
    creatorId = game.CreatorId,
    creatorType = tostring(game.CreatorType),
    players = #Players:GetPlayers(),
    maxPlayers = Players.MaxPlayers
}
print("[RBA] Experience:", info.name, "place", info.placeId, "players", info.players .. "/" .. info.maxPlayers)
if _G.RBA and _G.RBA.send then
    _G.RBA.send(info)
end`
  },
  character_position: {
    description: "Returns the local character's current position and CFrame components.",
    script: String.raw`local Players = game:GetService("Players")
local player = Players.LocalPlayer
local character = player and player.Character
local root = character and character:FindFirstChild("HumanoidRootPart")
if not root then
    error("Local character HumanoidRootPart is not available")
end
local components = { root.CFrame:GetComponents() }
return {
    position = root.Position,
    cframe = components,
    placeId = game.PlaceId
}`
  },
  teleport_to_spawn: {
    description: "Teleports the local character to the first SpawnLocation in Workspace and remembers the previous position.",
    script: String.raw`local Players = game:GetService("Players")
local player = Players.LocalPlayer
local character = player and player.Character
local root = character and character:FindFirstChild("HumanoidRootPart")
if not root then
    error("Local character HumanoidRootPart is not available")
end
local spawn = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
if not spawn then
    error("No SpawnLocation exists in Workspace")
end
_G.RBA = _G.RBA or {}
_G.RBA.lastTeleportCFrame = root.CFrame
character:PivotTo(spawn.CFrame * CFrame.new(0, spawn.Size.Y / 2 + 3, 0))
return { ok = true, destination = spawn:GetFullName(), position = root.Position }`
  },
  save_return_point: {
    description: "Saves the local character's current CFrame as the return point for this client session.",
    script: String.raw`local Players = game:GetService("Players")
local character = Players.LocalPlayer and Players.LocalPlayer.Character
local root = character and character:FindFirstChild("HumanoidRootPart")
if not root then
    error("Local character HumanoidRootPart is not available")
end
_G.RBA = _G.RBA or {}
_G.RBA.savedReturnCFrame = root.CFrame
return { ok = true, position = root.Position }`
  },
  return_to_saved_position: {
    description: "Returns the local character to the position saved by save_return_point.",
    script: String.raw`local Players = game:GetService("Players")
local character = Players.LocalPlayer and Players.LocalPlayer.Character
if not character then
    error("Local character is not available")
end
if not (_G.RBA and _G.RBA.savedReturnCFrame) then
    error("No saved return point. Run save_return_point first.")
end
local previous = character:GetPivot()
character:PivotTo(_G.RBA.savedReturnCFrame)
_G.RBA.lastTeleportCFrame = previous
return { ok = true, position = character:GetPivot().Position }`
  },
  heartbeat_once: {
    description: "Sends a single heartbeat event back through the active RBA websocket connection.",
    script: String.raw`if _G.RBA and _G.RBA.send then
    _G.RBA.send({
        type = "heartbeat",
        ok = true,
        placeId = game.PlaceId,
        jobId = game.JobId,
        clock = os.clock()
    })
end`
  },
  client_logger: {
    description: "Installs a tiny _G.RBA.log helper that prints locally and forwards log events to the MCP server.",
    script: String.raw`_G.RBA = _G.RBA or {}
_G.RBA.log = function(...)
    local parts = {}
    for i, value in ipairs({...}) do
        parts[i] = tostring(value)
    end
    local line = table.concat(parts, " ")
    print("[RBA]", line)
    if _G.RBA.send then
        _G.RBA.send({ type = "log", message = line, at = os.time() })
    end
end
_G.RBA.log("client logger installed")`
  },
  debug_runtime: {
    description: "Installs RBA debug helpers such as _G.RBA.inspect, _G.RBA.snapshot, and _G.RBA.trace.",
    script: DEBUG_RUNTIME_LUA
  },
  console_mirror: {
    description: "Mirrors print/warn calls back to RBA as client_print/client_warn events.",
    script: CONSOLE_MIRROR_LUA
  }
} as const;

function compactEventData(data: unknown): unknown {
  if (data === undefined) {
    return undefined;
  }
  try {
    const serialized = JSON.stringify(data);
    const bytes = Buffer.byteLength(serialized);
    if (bytes <= eventDataMaxBytes()) {
      return data;
    }
    return {
      truncated: true,
      bytes,
      preview: serialized.slice(0, Math.min(2048, eventDataMaxBytes()))
    };
  } catch (error) {
    return {
      truncated: true,
      reason: "event data was not serializable",
      error: error instanceof Error ? error.message : String(error)
    };
  }
}

function addEvent(event: EventRecord): void {
  const storedEvent: EventRecord = {
    ...event,
    message: event.message.length > 2000 ? `${event.message.slice(0, 2000)}...` : event.message,
    data: compactEventData(event.data)
  };
  events.push(storedEvent);
  const limit = eventLimit();
  if (events.length > limit) {
    events.splice(0, events.length - limit);
  }

  queueEventLog(storedEvent);

  for (let index = eventWaiters.length - 1; index >= 0; index--) {
    const waiter = eventWaiters[index];
    if (waiter.type && waiter.type !== storedEvent.type) {
      continue;
    }
    if (waiter.clientId !== undefined && waiter.clientId !== storedEvent.clientId) {
      continue;
    }
    clearTimeout(waiter.timeout);
    eventWaiters.splice(index, 1);
    waiter.resolve(storedEvent);
  }
}

function now(): string {
  return new Date().toISOString();
}

function okText(text: string) {
  return {
    content: [{ type: "text" as const, text }]
  };
}

function jsonText(value: unknown) {
  return okText(JSON.stringify(value, null, 2));
}

function logRoot(): string {
  const resolved = path.resolve(workspaceRoot, LOG_DIR);
  if (resolved === workspaceRoot || resolved.startsWith(`${workspaceRoot}${path.sep}`)) {
    return resolved;
  }
  return path.join(workspaceRoot, "logs");
}

function isValidPort(port: unknown): port is number {
  return Number.isInteger(port) && Number(port) > 0 && Number(port) <= 65535;
}

function boundedInteger(value: number, fallback: number, minimum: number, maximum: number): number {
  return Number.isFinite(value) ? Math.max(minimum, Math.min(Math.trunc(value), maximum)) : fallback;
}

function eventLimit(): number {
  return boundedInteger(EVENT_LIMIT, 1000, 100, 10_000);
}

function eventDataMaxBytes(): number {
  return boundedInteger(EVENT_DATA_MAX_BYTES, 16_384, 1024, 256 * 1024);
}

function maxPendingLogLines(): number {
  return boundedInteger(MAX_PENDING_LOG_LINES, 5000, 100, 50_000);
}

function logMaxFileBytes(): number {
  return boundedInteger(LOG_MAX_FILE_BYTES, 10 * 1024 * 1024, 256 * 1024, 1024 * 1024 * 1024);
}

function logRotations(): number {
  return boundedInteger(LOG_ROTATIONS, 3, 1, 20);
}

function websocketMaxPayloadBytes(): number {
  return boundedInteger(WS_MAX_PAYLOAD_BYTES, 1_048_576, 64 * 1024, 16 * 1024 * 1024);
}

function websocketMaxBufferedBytes(): number {
  return boundedInteger(WS_MAX_BUFFERED_BYTES, 1_048_576, 64 * 1024, 16 * 1024 * 1024);
}

function websocketRateLimit(): number {
  return boundedInteger(WS_RATE_LIMIT, 600, 20, 10_000);
}

function websocketRateWindowMs(): number {
  return boundedInteger(WS_RATE_WINDOW_MS, 10_000, 1000, 60_000);
}

function maxPortCandidateCount(): number {
  return isValidPort(MAX_PORT_CANDIDATES) ? Math.max(1, Math.min(MAX_PORT_CANDIDATES, 1024)) : 256;
}

function controlConnectTimeoutMs(): number {
  return Number.isInteger(CONTROL_CONNECT_TIMEOUT_MS) ? Math.max(100, Math.min(CONTROL_CONNECT_TIMEOUT_MS, 5000)) : 350;
}

function controlProbeBatchSize(): number {
  return Number.isInteger(CONTROL_PROBE_BATCH_SIZE) ? Math.max(1, Math.min(CONTROL_PROBE_BATCH_SIZE, 64)) : 8;
}

function normalizeHost(host: string): string {
  const trimmed = host.trim();
  return trimmed || "127.0.0.1";
}

function parsePortCandidates(value: string, preferredPort: number): number[] {
  const ports = new Set<number>();
  const maxCandidates = maxPortCandidateCount();
  if (isValidPort(preferredPort)) {
    ports.add(preferredPort);
  }

  for (const part of value.split(",")) {
    if (ports.size >= maxCandidates) {
      break;
    }
    const trimmed = part.trim();
    if (!trimmed) {
      continue;
    }

    const range = trimmed.match(/^(\d+)\s*-\s*(\d+)$/);
    if (range) {
      const start = Number.parseInt(range[1], 10);
      const end = Number.parseInt(range[2], 10);
      for (let port = Math.min(start, end); port <= Math.max(start, end); port++) {
        if (ports.size >= maxCandidates) {
          break;
        }
        if (isValidPort(port)) {
          ports.add(port);
        }
      }
      continue;
    }

    const port = Number.parseInt(trimmed, 10);
    if (isValidPort(port)) {
      ports.add(port);
    }
  }

  return [...ports];
}

function isAddressInUse(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && (error as { code?: unknown }).code === "EADDRINUSE";
}

function luaString(value: string): string {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\r/g, "\\r").replace(/\n/g, "\\n")}"`;
}

function prioritizePort(port: number, candidates: number[]): number[] {
  return [port, ...candidates.filter((candidate) => candidate !== port)];
}

function luaPortList(ports: number[]): string {
  return ports.join(", ");
}

function uniquePorts(ports: unknown[]): number[] {
  const unique = new Set<number>();
  for (const port of ports) {
    const numeric = typeof port === "string" ? Number.parseInt(port, 10) : Number(port);
    if (isValidPort(numeric)) {
      unique.add(numeric);
    }
  }
  return [...unique];
}

function connectionCandidateUrls(host: string, ports: number[]): string[] {
  const hosts = new Set([normalizeHost(host), "127.0.0.1", "localhost"]);
  const urls: string[] = [];
  const seen = new Set<string>();
  for (const port of ports) {
    for (const candidateHost of hosts) {
      const url = `ws://${candidateHost}:${port}/`;
      if (!seen.has(url)) {
        seen.add(url);
        urls.push(url);
      }
    }
  }
  return urls;
}

function applyConnectionUrl(url: string): void {
  try {
    const parsed = new URL(url);
    const port = Number.parseInt(parsed.port, 10);
    if (parsed.hostname && isValidPort(port)) {
      wsHost = parsed.hostname;
      wsPort = port;
    }
  } catch {
    // Keep the previous host/port if an executor returns a non-standard URL.
  }
}

function currentConnectionState(mode: "server" | "proxy" = webSocketServer ? "server" : "proxy"): ConnectionState {
  const host = normalizeHost(wsHost);
  const portCandidates = prioritizePort(wsPort, DEFAULT_PORT_CANDIDATES);
  const url = `ws://${host}:${wsPort}/`;
  const candidateUrls = connectionCandidateUrls(host, portCandidates);
  return {
    version: 1,
    name: "RBA",
    mode,
    host,
    port: wsPort,
    url,
    portCandidates,
    candidateUrls,
    pid: process.pid,
    workspaceRoot,
    updatedAt: now(),
    checks: {
      hostValid: host.length > 0,
      portValid: isValidPort(wsPort),
      candidateCount: portCandidates.length,
      activeUrlFirst: candidateUrls[0] === url
    }
  };
}

async function updateAutoloaderPortPriority(ports: number[]): Promise<void> {
  const autoloaderPath = path.join(workspaceRoot, "lua", "rba_autoloader.lua");
  const source = await fs.readFile(autoloaderPath, "utf8");
  const nextSource = source.replace(
    /local PORTS = \{[^}]*\}/,
    `local PORTS = { ${luaPortList(ports)} }`
  );

  if (nextSource !== source) {
    await fs.writeFile(autoloaderPath, nextSource, "utf8");
  }
  const syncResult = await syncAutoloaderToAutoexec("port_priority_update");
  if (syncResult.ok && syncResult.changed) {
    addEvent({
      at: now(),
      type: "autoexec_sync",
      message: `Synced unified autoloader to ${syncResult.changedCount} target(s)`,
      data: syncResult
    });
  }
}

async function publishConnectionState(mode: "server" | "proxy" = webSocketServer ? "server" : "proxy"): Promise<ConnectionState> {
  const state = currentConnectionState(mode);

  await fs.writeFile(connectionStatePath, `${JSON.stringify(state, null, 2)}\n`, "utf8");

  const luaPorts = luaPortList(state.portCandidates);
  await fs.writeFile(
    luaConnectionStatePath,
    `return {\n  version = ${state.version},\n  name = ${luaString(state.name)},\n  mode = ${luaString(state.mode)},\n  host = ${luaString(state.host)},\n  port = ${state.port},\n  url = ${luaString(state.url)},\n  portCandidates = { ${luaPorts} },\n  updatedAt = ${luaString(state.updatedAt)},\n  pid = ${state.pid}\n}\n`,
    "utf8"
  );

  await updateAutoloaderPortPriority(state.portCandidates);
  return state;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function activeExecutorClients(): ClientRecord[] {
  return [...clients.values()].filter((client) =>
    client.role === "executor" && client.socket.readyState === WebSocket.OPEN
  );
}

function sendSocketText(socket: WebSocket, text: string): boolean {
  const bytes = Buffer.byteLength(text);
  if (socket.readyState !== WebSocket.OPEN ||
      bytes > websocketMaxPayloadBytes() ||
      socket.bufferedAmount > websocketMaxBufferedBytes()) {
    socketMessagesDropped++;
    return false;
  }
  socket.send(text, (error) => {
    if (error) {
      socketMessagesDropped++;
    }
  });
  socketMessagesSent++;
  socketBytesSent += bytes;
  return true;
}

function sendSocketJson(socket: WebSocket, payload: unknown): boolean {
  try {
    return sendSocketText(socket, JSON.stringify(payload));
  } catch {
    socketMessagesDropped++;
    return false;
  }
}

async function readPublishedConnectionCandidates(): Promise<number[]> {
  try {
    const raw = await fs.readFile(connectionStatePath, "utf8");
    const parsed = JSON.parse(raw) as { portCandidates?: unknown; port?: unknown };
    const candidates = Array.isArray(parsed.portCandidates) ? uniquePorts(parsed.portCandidates) : [];
    if (isValidPort(parsed.port)) {
      return prioritizePort(Number(parsed.port), [...candidates, ...DEFAULT_PORT_CANDIDATES]);
    }
    if (candidates.length > 0) {
      return [...new Set([...candidates, ...DEFAULT_PORT_CANDIDATES])];
    }
  } catch {
    // Missing or stale connection state is normal before the first bridge starts.
  }
  return DEFAULT_PORT_CANDIDATES;
}

async function readPublishedConnectionState(): Promise<ConnectionState | undefined> {
  try {
    const raw = await fs.readFile(connectionStatePath, "utf8");
    const parsed = JSON.parse(raw) as Partial<ConnectionState>;
    if (!parsed || parsed.name !== "RBA" || !isValidPort(parsed.port) || typeof parsed.host !== "string") {
      return undefined;
    }
    return {
      version: 1,
      name: "RBA",
      mode: parsed.mode === "proxy" ? "proxy" : "server",
      host: normalizeHost(parsed.host),
      port: Number(parsed.port),
      url: typeof parsed.url === "string" ? parsed.url : `ws://${normalizeHost(parsed.host)}:${parsed.port}/`,
      portCandidates: prioritizePort(Number(parsed.port), [
        ...uniquePorts(Array.isArray(parsed.portCandidates) ? parsed.portCandidates : []),
        ...DEFAULT_PORT_CANDIDATES
      ]),
      candidateUrls: Array.isArray(parsed.candidateUrls)
        ? parsed.candidateUrls.filter((url): url is string => typeof url === "string" && url.startsWith("ws://"))
        : connectionCandidateUrls(normalizeHost(parsed.host), DEFAULT_PORT_CANDIDATES),
      pid: Number.isInteger(parsed.pid) ? Number(parsed.pid) : 0,
      workspaceRoot: typeof parsed.workspaceRoot === "string" ? parsed.workspaceRoot : workspaceRoot,
      updatedAt: typeof parsed.updatedAt === "string" ? parsed.updatedAt : "",
      checks: {
        hostValid: normalizeHost(parsed.host).length > 0,
        portValid: true,
        candidateCount: Array.isArray(parsed.portCandidates) ? parsed.portCandidates.length : 0,
        activeUrlFirst: Array.isArray(parsed.candidateUrls) ? parsed.candidateUrls[0] === parsed.url : false
      }
    };
  } catch {
    return undefined;
  }
}

function setupBridgeControlSocket(socket: WebSocket, url: string): void {
  bridgeControlSocket = socket;
  bridgeControlUrl = url;

  socket.on("message", (raw) => {
    let data: unknown;
    try {
      data = JSON.parse(raw.toString("utf8"));
    } catch {
      return;
    }
    if (!isRecord(data) || data.type !== "rba_control_response") {
      return;
    }
    const requestId = String(data.requestId ?? "");
    const pending = pendingControlResponses.get(requestId);
    if (!pending) {
      return;
    }
    clearTimeout(pending.timeout);
    pendingControlResponses.delete(requestId);
    if (data.ok === false) {
      pending.reject(new Error(String(data.error ?? "RBA bridge control request failed")));
      return;
    }
    pending.resolve(data.payload);
  });

  socket.on("close", () => {
    if (bridgeControlSocket === socket) {
      bridgeControlSocket = undefined;
      bridgeControlUrl = undefined;
    }
    for (const [requestId, pending] of pendingControlResponses) {
      clearTimeout(pending.timeout);
      pending.reject(new Error("RBA bridge control connection closed"));
      pendingControlResponses.delete(requestId);
    }
  });

  socket.on("error", (error) => {
    addEvent({ at: now(), type: "control_error", message: error.message, data: { url } });
  });
}

function connectControlUrl(url: string, timeoutMs = controlConnectTimeoutMs()): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = new WebSocket(url);
    let settled = false;
    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        socket.close();
        resolve(false);
      }
    }, timeoutMs);

    socket.once("open", () => {
      sendSocketJson(socket, {
        type: "rba_control_hello",
        pid: process.pid,
        workspaceRoot,
        at: now()
      });
    });

    socket.once("message", (raw) => {
      if (settled) {
        return;
      }
      let data: unknown;
      try {
        data = JSON.parse(raw.toString("utf8"));
      } catch {
        data = undefined;
      }
      if (isRecord(data) && data.type === "rba_control_ready") {
        settled = true;
        clearTimeout(timer);
        if (bridgeControlSocket?.readyState === WebSocket.OPEN) {
          socket.close();
          resolve(true);
          return;
        }
        applyConnectionUrl(url);
        setupBridgeControlSocket(socket, url);
        addEvent({ at: now(), type: "control_attach", message: `Attached to shared RBA bridge at ${url}` });
        void publishConnectionState("proxy").catch((error) => {
          addEvent({ at: now(), type: "server_state_error", message: error instanceof Error ? error.message : String(error) });
        });
        resolve(true);
        return;
      }
      settled = true;
      clearTimeout(timer);
      socket.close();
      resolve(false);
    });

    socket.once("error", () => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        resolve(false);
      }
    });
  });
}

async function connectControlUrlsFast(urls: string[]): Promise<boolean> {
  const batchSize = controlProbeBatchSize();
  for (let index = 0; index < urls.length; index += batchSize) {
    if (bridgeControlSocket?.readyState === WebSocket.OPEN) {
      return true;
    }
    const batch = urls.slice(index, index + batchSize);
    const results = await Promise.all(batch.map((url) => connectControlUrl(url)));
    if (results.some(Boolean)) {
      return true;
    }
  }
  return false;
}

async function ensureBridgeControl(): Promise<boolean> {
  if (bridgeControlSocket?.readyState === WebSocket.OPEN) {
    return true;
  }
  const published = await readPublishedConnectionState();
  const ports = await readPublishedConnectionCandidates();
  const urls = new Set<string>();
  if (published?.url) {
    urls.add(published.url);
  }
  for (const url of published?.candidateUrls ?? []) {
    urls.add(url);
  }
  for (const url of connectionCandidateUrls(DEFAULT_HOST, ports)) {
    urls.add(url);
  }
  return connectControlUrlsFast([...urls]);
}

function controlRequest(command: string, payload: ControlPayload = {}, timeoutMs = 10_000): Promise<unknown> {
  return new Promise((resolve, reject) => {
    if (!bridgeControlSocket || bridgeControlSocket.readyState !== WebSocket.OPEN) {
      reject(new Error("No shared RBA bridge control connection is open."));
      return;
    }
    const requestId = `control_${Date.now()}_${randomUUID()}`;
    const timeout = setTimeout(() => {
      pendingControlResponses.delete(requestId);
      reject(new Error(`Timed out waiting for shared RBA bridge command "${command}"`));
    }, timeoutMs);
    pendingControlResponses.set(requestId, { resolve, reject, timeout });
    const sent = sendSocketJson(bridgeControlSocket, {
      type: "rba_control_request",
      requestId,
      command,
      payload
    });
    if (!sent) {
      clearTimeout(timeout);
      pendingControlResponses.delete(requestId);
      reject(new Error(`Could not send shared RBA bridge command "${command}" because the socket is unavailable or backpressured.`));
    }
  });
}

function renderLogValue(value: unknown, depth = LOG_VALUE_DEPTH): string {
  if (value === null || value === undefined) return String(value);
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "boolean" || typeof value === "bigint") return String(value);
  if (depth <= 0) return "[depth limit]";
  if (Array.isArray(value)) return `[${value.map((item) => renderLogValue(item, depth - 1)).join(", ")}]`;
  if (!isRecord(value)) return String(value);

  if (value.kind === "Instance") {
    const className = value.className ? String(value.className) : "Instance";
    const instancePath = value.path ? String(value.path) : String(value.name ?? "<unknown>");
    return `[${className} ${instancePath}]`;
  }
  if (value.kind === "Vector2") return `Vector2(${value.x}, ${value.y})`;
  if (value.kind === "Vector3") return `Vector3(${value.x}, ${value.y}, ${value.z})`;
  if (value.kind === "Color3") return `Color3(${value.r}, ${value.g}, ${value.b})`;
  if (value.kind === "CFrame") return `CFrame(${renderLogValue(value.position, depth - 1)})`;
  if (value.kind === "EnumItem") return String(value.value ?? "EnumItem");

  const entries = Object.entries(value)
    .slice(0, 24)
    .map(([key, child]) => `${key}=${renderLogValue(child, depth - 1)}`);
  if (Object.keys(value).length > 24) entries.push("...");
  return `{ ${entries.join(", ")} }`;
}

function consoleLine(event: EventRecord): string {
  const data = isRecord(event.data) ? event.data : {};
  const level = event.type === "client_warn" ? "WARN" : event.type === "client_error" ? "ERROR" : "INFO";
  const values = Array.isArray(data.values) ? data.values : undefined;
  const body = values
    ? values.map((value) => renderLogValue(value)).join(" ")
    : String(data.message ?? event.message ?? "");
  return `[${event.at}] [client:${event.clientId ?? "-"}] [${level}] ${body}`;
}

function eventLogFlushDelay(): number {
  return Number.isFinite(EVENT_LOG_FLUSH_MS) ? Math.max(10, Math.min(EVENT_LOG_FLUSH_MS, 5000)) : 100;
}

function pushBoundedLogLine(target: string[], line: string): void {
  const limit = maxPendingLogLines();
  if (target.length >= limit) {
    const removeCount = target.length - limit + 1;
    target.splice(0, removeCount);
    eventLogLinesDropped += removeCount;
  }
  target.push(line);
}

function queueEventLog(event: EventRecord): void {
  const serialized = JSON.stringify(event);
  pushBoundedLogLine(pendingEventLogLines, serialized);
  if (CONSOLE_EVENT_TYPES.has(event.type)) {
    pushBoundedLogLine(pendingConsoleJsonLines, serialized);
    pushBoundedLogLine(pendingConsoleTextLines, consoleLine(event));
  }
  if (eventLogFlushTimer) {
    return;
  }
  eventLogFlushTimer = setTimeout(() => {
    eventLogFlushTimer = undefined;
    eventLogFlushChain = eventLogFlushChain
      .then(flushEventLogs)
      .catch((error) => {
        console.error(`[RBA] Could not write log file: ${error instanceof Error ? error.message : String(error)}`);
      });
  }, eventLogFlushDelay());
  eventLogFlushTimer.unref();
}

async function flushEventLogs(): Promise<void> {
  const eventLines = pendingEventLogLines.splice(0);
  const consoleJsonLines = pendingConsoleJsonLines.splice(0);
  const consoleTextLines = pendingConsoleTextLines.splice(0);
  if (eventLines.length === 0) {
    return;
  }
  const root = logRoot();
  if (!logDirectoryReady) {
    await fs.mkdir(root, { recursive: true });
    logDirectoryReady = true;
  }
  const writes: Array<Promise<void>> = [
    appendRotatingLog(path.join(root, "rba-events.ndjson"), `${eventLines.join("\n")}\n`)
  ];
  if (consoleJsonLines.length > 0) {
    writes.push(appendRotatingLog(path.join(root, "roblox-console.ndjson"), `${consoleJsonLines.join("\n")}\n`));
    writes.push(appendRotatingLog(path.join(root, "roblox-console.log"), `${consoleTextLines.join("\n")}\n`));
  }
  await Promise.all(writes);
}

async function appendRotatingLog(filePath: string, content: string): Promise<void> {
  const incomingBytes = Buffer.byteLength(content);
  let currentBytes = 0;
  try {
    currentBytes = (await fs.stat(filePath)).size;
  } catch {
    // A missing log is expected on first use.
  }

  if (currentBytes > 0 && currentBytes + incomingBytes > logMaxFileBytes()) {
    const rotations = logRotations();
    await fs.rm(`${filePath}.${rotations}`, { force: true });
    for (let index = rotations - 1; index >= 1; index--) {
      try {
        await fs.rename(`${filePath}.${index}`, `${filePath}.${index + 1}`);
      } catch {
        // Missing older rotations are normal.
      }
    }
    try {
      await fs.rename(filePath, `${filePath}.1`);
    } catch {
      // Another process may have rotated or removed the file.
    }
  }

  await fs.appendFile(filePath, content, "utf8");
}

function clientSummary(client: ClientRecord) {
  return {
    id: client.id,
    role: client.role,
    address: client.address,
    connectedAt: client.connectedAt,
    lastMessageAt: client.lastMessageAt,
    lastHeartbeatAt: client.lastHeartbeatAt,
    selected: client.id === selectedClientId,
    hello: client.hello
  };
}

function resolveTarget(target: ClientTarget | undefined, fallback: ClientTarget): ClientTarget {
  if (target !== undefined) {
    return target;
  }
  if (selectedClientId !== undefined && clients.has(selectedClientId)) {
    return selectedClientId;
  }
  return fallback;
}

function filterEvents(options: { limit?: number; type?: string; clientId?: number; since?: string; until?: string }): EventRecord[] {
  const sinceMs = options.since ? Date.parse(options.since) : undefined;
  const untilMs = options.until ? Date.parse(options.until) : undefined;
  const filtered = events.filter((event) => {
    if (options.type && event.type !== options.type) {
      return false;
    }
    if (options.clientId !== undefined && event.clientId !== options.clientId) {
      return false;
    }
    if (sinceMs !== undefined || untilMs !== undefined) {
      const eventMs = Date.parse(event.at);
      if (sinceMs !== undefined && eventMs < sinceMs) {
        return false;
      }
      if (untilMs !== undefined && eventMs > untilMs) {
        return false;
      }
    }
    return true;
  });
  const limit = boundedInteger(options.limit ?? 50, 50, 1, eventLimit());
  return filtered.slice(-limit);
}

function parseClientTarget(value: unknown, fallback: ClientTarget): ClientTarget {
  if (value === "all" || value === "first") {
    return value;
  }
  if (typeof value === "number" && Number.isInteger(value) && value > 0) {
    return value;
  }
  return fallback;
}

function luaLongString(value: string): string {
  for (let equalsCount = 0; equalsCount < 10; equalsCount++) {
    const equals = "=".repeat(equalsCount);
    const close = `]${equals}]`;
    if (!value.includes(close)) {
      return `[${equals}[${value}]${equals}]`;
    }
  }
  return JSON.stringify(value);
}

function buildEvalScript(source: string, requestId: string, label: string): string {
  return String.raw`local __rba_request_id = ${luaLongString(requestId)}
local __rba_label = ${luaLongString(label)}
local __rba_source = ${luaLongString(source)}
local __rba_started = os.clock()

local function __rba_type(value)
    local ok, result = pcall(function()
        return typeof(value)
    end)
    if ok then
        return result
    end
    return type(value)
end

local function __rba_inspect(value, depth, seen)
    if _G.RBA and _G.RBA.inspect then
        local ok, inspected = pcall(_G.RBA.inspect, value, depth or 4)
        if ok then
            return inspected
        end
    end

    depth = depth or 4
    seen = seen or {}
    local valueType = __rba_type(value)
    if value == nil or valueType == "boolean" or valueType == "number" or valueType == "string" then
        return value
    end
    if valueType == "Vector2" then
        return { kind = "Vector2", x = value.X, y = value.Y }
    end
    if valueType == "Vector3" then
        return { kind = "Vector3", x = value.X, y = value.Y, z = value.Z }
    end
    if valueType == "CFrame" then
        return { kind = "CFrame", position = __rba_inspect(value.Position, depth - 1, seen) }
    end
    if valueType == "Instance" then
        local fullName = "<unknown>"
        pcall(function()
            fullName = value:GetFullName()
        end)
        return { kind = "Instance", className = value.ClassName, name = value.Name, path = fullName }
    end
    if type(value) == "table" then
        if seen[value] then
            return { kind = "cycle", value = tostring(value) }
        end
        if depth <= 0 then
            return { kind = "table", value = tostring(value), truncated = true }
        end
        seen[value] = true
        local output = {}
        local count = 0
        for key, child in pairs(value) do
            count = count + 1
            if count > 80 then
                output.__truncated = true
                break
            end
            output[tostring(key)] = __rba_inspect(child, depth - 1, seen)
        end
        seen[value] = nil
        return output
    end
    return { kind = valueType, value = tostring(value) }
end

local function __rba_pack(...)
    local output = { n = select("#", ...), values = {} }
    for index = 1, output.n do
        output.values[index] = __rba_inspect(select(index, ...), 4)
    end
    return output
end

local function __rba_send(payload)
    if _G.RBA and _G.RBA.send then
        _G.RBA.send(payload)
        return
    end
    warn("[RBA] Cannot send eval response; _G.RBA.send is missing")
end

local function __rba_run()
    local chunk, compileError = loadstring(__rba_source)
    if not chunk then
        error("compile error: " .. tostring(compileError), 0)
    end
    return __rba_pack(chunk())
end

local ok, result = xpcall(__rba_run, function(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end)

if ok then
    __rba_send({
        type = "rba_response",
        requestId = __rba_request_id,
        label = __rba_label,
        ok = true,
        n = result.n,
        values = result.values,
        durationMs = math.floor((os.clock() - __rba_started) * 1000)
    })
else
    __rba_send({
        type = "rba_response",
        requestId = __rba_request_id,
        label = __rba_label,
        ok = false,
        error = tostring(result),
        durationMs = math.floor((os.clock() - __rba_started) * 1000)
    })
end`;
}

function waitForResponse(requestId: string, timeoutMs: number, clientId?: number): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pendingResponses.delete(requestId);
      reject(new Error(`Timed out waiting for RBA response ${requestId}`));
    }, timeoutMs);

    pendingResponses.set(requestId, { resolve, reject, timeout, clientId });
  });
}

function rejectPendingResponse(requestId: string, error: Error): void {
  const pending = pendingResponses.get(requestId);
  if (!pending) {
    return;
  }
  clearTimeout(pending.timeout);
  pendingResponses.delete(requestId);
  pending.reject(error);
}

function waitForEvent(type: string | undefined, clientId: number | undefined, timeoutMs: number): Promise<EventRecord> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      const index = eventWaiters.findIndex((waiter) => waiter.resolve === resolve);
      if (index >= 0) {
        eventWaiters.splice(index, 1);
      }
      reject(new Error(`Timed out waiting for event${type ? ` "${type}"` : ""}`));
    }, timeoutMs);

    eventWaiters.push({ resolve, timeout, type, clientId });
  });
}

async function imageResult(meta: unknown, imagePath: string, mimeType: string) {
  const buffer = await fs.readFile(imagePath);
  return {
    content: [
      { type: "text" as const, text: JSON.stringify(meta, null, 2) },
      { type: "image" as const, data: buffer.toString("base64"), mimeType }
    ]
  };
}

function assertInsideWorkspace(inputPath: string): string {
  const resolved = path.resolve(workspaceRoot, inputPath);
  const relative = path.relative(workspaceRoot, resolved);
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    throw new Error(`Path must stay inside RBA_ROOT (${workspaceRoot}): ${inputPath}`);
  }
  return resolved;
}

async function pathExists(target: string): Promise<boolean> {
  try {
    await fs.access(target);
    return true;
  } catch {
    return false;
  }
}

function backupRoot(): string {
  return path.join(workspaceRoot, BACKUP_DIR);
}

function backupTimestamp(): string {
  return new Date().toISOString().replace(/[:.]/g, "-");
}

async function backupWorkspaceFile(filePath: string, reason: string): Promise<Record<string, unknown>> {
  const source = assertInsideWorkspace(filePath);
  const stats = await fs.stat(source);
  if (!stats.isFile()) {
    throw new Error(`Only files can be backed up: ${filePath}`);
  }

  const relative = path.relative(workspaceRoot, source);
  if (relative === BACKUP_DIR || relative.startsWith(`${BACKUP_DIR}${path.sep}`)) {
    throw new Error("Backup files cannot be backed up recursively.");
  }

  const backupId = `${backupTimestamp()}-${randomUUID().slice(0, 8)}`;
  const destination = path.join(backupRoot(), backupId, relative);
  await fs.mkdir(path.dirname(destination), { recursive: true });
  await fs.copyFile(source, destination);
  return {
    ok: true,
    backupId,
    reason,
    source: relative,
    backupPath: path.relative(workspaceRoot, destination),
    bytes: stats.size,
    createdAt: now()
  };
}

async function listWorkspaceBackups(filePath?: string): Promise<unknown[]> {
  if (!await pathExists(backupRoot())) {
    return [];
  }
  const filter = filePath ? path.relative(workspaceRoot, assertInsideWorkspace(filePath)) : undefined;
  const files = await walkFiles(backupRoot(), true, 5000);
  const output: Array<Record<string, unknown>> = [];
  for (const absoluteOrRelative of files) {
    const absolute = path.isAbsolute(absoluteOrRelative) ? absoluteOrRelative : path.join(workspaceRoot, absoluteOrRelative);
    let stats;
    try {
      stats = await fs.stat(absolute);
    } catch {
      continue;
    }
    if (!stats.isFile()) {
      continue;
    }
    const relativeToBackups = path.relative(backupRoot(), absolute);
    const [backupId, ...sourceParts] = relativeToBackups.split(path.sep);
    const source = sourceParts.join(path.sep);
    if (filter && source !== filter) {
      continue;
    }
    output.push({
      backupId,
      source,
      backupPath: path.relative(workspaceRoot, absolute),
      bytes: stats.size,
      modifiedAt: stats.mtime.toISOString()
    });
  }
  return output.sort((a, b) => String(b.backupId).localeCompare(String(a.backupId)));
}

async function restoreWorkspaceBackup(backupPath: string, destinationPath?: string): Promise<Record<string, unknown>> {
  const resolvedBackup = assertInsideWorkspace(backupPath);
  const relativeToBackups = path.relative(backupRoot(), resolvedBackup);
  if (relativeToBackups.startsWith("..") || path.isAbsolute(relativeToBackups)) {
    throw new Error(`Backup path must be inside ${BACKUP_DIR}.`);
  }
  const [, ...sourceParts] = relativeToBackups.split(path.sep);
  if (sourceParts.length === 0) {
    throw new Error("Backup path must identify a backed-up file.");
  }
  const destinationRelative = destinationPath ?? sourceParts.join(path.sep);
  const destination = assertInsideWorkspace(destinationRelative);
  const safetyBackup = await pathExists(destination)
    ? await backupWorkspaceFile(destinationRelative, "before_restore")
    : undefined;
  await fs.mkdir(path.dirname(destination), { recursive: true });
  await fs.copyFile(resolvedBackup, destination);
  const stats = await fs.stat(destination);
  return {
    ok: true,
    backupPath: path.relative(workspaceRoot, resolvedBackup),
    restoredTo: path.relative(workspaceRoot, destination),
    safetyBackup,
    bytes: stats.size,
    restoredAt: now()
  };
}

function resolveAutoexecTarget(targetPath: string): string {
  const resolved = path.resolve(targetPath);
  return path.extname(resolved).toLowerCase() === ".lua" ? resolved : path.join(resolved, AUTOEXEC_FILENAME);
}

function sha256(value: string | Buffer): string {
  return createHash("sha256").update(value).digest("hex");
}

async function writeAutoexecFile(options: { targetPath: string; sourcePath?: string; backup: boolean; reason: string }): Promise<Record<string, unknown>> {
  if (!options.targetPath) {
    throw new Error("No autoexec target path configured. Set RBA_AUTOEXEC_PATH/RBA_AUTOEXEC_PATHS or pass targetPath.");
  }
  const source = options.sourcePath ? assertInsideWorkspace(options.sourcePath) : path.join(workspaceRoot, "lua", AUTOEXEC_FILENAME);
  const content = await fs.readFile(source, "utf8");
  const sourceHash = sha256(content);
  const resolvedTarget = resolveAutoexecTarget(options.targetPath);
  await fs.mkdir(path.dirname(resolvedTarget), { recursive: true });
  let backupPath: string | undefined;
  let changed = true;
  let previousHash: string | undefined;
  if (await pathExists(resolvedTarget)) {
    const existing = await fs.readFile(resolvedTarget, "utf8");
    previousHash = sha256(existing);
    changed = previousHash !== sourceHash;
    if (changed && options.backup) {
      backupPath = `${resolvedTarget}.bak.${Date.now()}`;
      await fs.copyFile(resolvedTarget, backupPath);
    }
  }
  if (changed) {
    const temporaryPath = path.join(
      path.dirname(resolvedTarget),
      `.${path.basename(resolvedTarget)}.${process.pid}.${randomUUID()}.tmp`
    );
    try {
      await fs.writeFile(temporaryPath, content, "utf8");
      await fs.rename(temporaryPath, resolvedTarget);
    } catch (error) {
      await fs.rm(temporaryPath, { force: true });
      throw error;
    }
  }
  return {
    ok: true,
    changed,
    reason: options.reason,
    source,
    targetPath: resolvedTarget,
    backupPath,
    bytes: content.length,
    sourceHash,
    previousHash,
    targetHash: sourceHash,
    syncedAt: now()
  };
}

async function autoexecTargetStatus(targetPath: string): Promise<Record<string, unknown>> {
  const sourcePath = path.join(workspaceRoot, "lua", AUTOEXEC_FILENAME);
  const resolvedTarget = resolveAutoexecTarget(targetPath);
  const source = await fs.readFile(sourcePath);
  const sourceHash = sha256(source);
  const exists = await pathExists(resolvedTarget);
  let bytes = 0;
  let targetHash: string | undefined;
  if (exists) {
    const installed = await fs.readFile(resolvedTarget);
    bytes = installed.length;
    targetHash = sha256(installed);
  }
  return {
    targetPath: resolvedTarget,
    executor: path.basename(path.dirname(path.dirname(resolvedTarget))),
    exists,
    matchesSource: targetHash === sourceHash,
    bytes,
    sourceHash,
    targetHash,
    backups: (await listAutoexecBackups(resolvedTarget)).length
  };
}

async function listAutoexecBackups(targetPath: string): Promise<unknown[]> {
  if (!targetPath) {
    throw new Error("No autoexec target path configured. Set RBA_AUTOEXEC_PATH or pass targetPath.");
  }
  const resolvedTarget = resolveAutoexecTarget(targetPath);
  const directory = path.dirname(resolvedTarget);
  if (!await pathExists(directory)) {
    return [];
  }
  const prefix = `${path.basename(resolvedTarget)}.bak.`;
  const entries = await fs.readdir(directory, { withFileTypes: true });
  const backups = await Promise.all(entries
    .filter((entry) => entry.isFile() && entry.name.startsWith(prefix))
    .map(async (entry) => {
      const backupPath = path.join(directory, entry.name);
      const stats = await fs.stat(backupPath);
      return { backupPath, bytes: stats.size, modifiedAt: stats.mtime.toISOString() };
    }));
  return backups.sort((a, b) => b.modifiedAt.localeCompare(a.modifiedAt));
}

async function restoreAutoexecBackup(targetPath: string, backupPath: string): Promise<Record<string, unknown>> {
  if (!targetPath || !backupPath) {
    throw new Error("Both targetPath and backupPath are required.");
  }
  const resolvedTarget = resolveAutoexecTarget(targetPath);
  const resolvedBackup = path.resolve(backupPath);
  const expectedPrefix = `${path.basename(resolvedTarget)}.bak.`;
  if (path.dirname(resolvedBackup) !== path.dirname(resolvedTarget) || !path.basename(resolvedBackup).startsWith(expectedPrefix)) {
    throw new Error("backupPath must be a backup created for the selected autoexec target.");
  }
  const stats = await fs.stat(resolvedBackup);
  if (!stats.isFile()) {
    throw new Error("Autoexec backup is not a file.");
  }
  let safetyBackupPath: string | undefined;
  if (await pathExists(resolvedTarget)) {
    safetyBackupPath = `${resolvedTarget}.bak.${Date.now()}`;
    await fs.copyFile(resolvedTarget, safetyBackupPath);
  }
  await fs.copyFile(resolvedBackup, resolvedTarget);
  return {
    ok: true,
    backupPath: resolvedBackup,
    restoredTo: resolvedTarget,
    safetyBackupPath,
    bytes: stats.size,
    restoredAt: now()
  };
}

type AutoexecSyncSummary = {
  ok: boolean;
  changed: boolean;
  changedCount: number;
  targetCount: number;
  skipped?: boolean;
  results: Record<string, unknown>[];
  errors: { targetPath: string; error: string }[];
};

async function syncAutoloaderToAutoexec(reason: string, backup = true): Promise<AutoexecSyncSummary> {
  if (!AUTO_SYNC_AUTOEXEC || autoexecTargetPaths.length === 0) {
    return {
      ok: true,
      changed: false,
      changedCount: 0,
      targetCount: autoexecTargetPaths.length,
      skipped: true,
      results: [],
      errors: []
    };
  }

  const settled = await Promise.all(autoexecTargetPaths.map(async (targetPath) => {
    try {
      return {
        result: await writeAutoexecFile({ targetPath, backup, reason })
      };
    } catch (error) {
      return {
        error: {
          targetPath,
          error: error instanceof Error ? error.message : String(error)
        }
      };
    }
  }));
  const results = settled.flatMap((entry) => entry.result ? [entry.result] : []);
  const errors = settled.flatMap((entry) => entry.error ? [entry.error] : []);
  for (const error of errors) {
    addEvent({ at: now(), type: "autoexec_sync_error", message: error.error, data: error });
  }
  const changedCount = results.filter((result) => Boolean(result.changed)).length;
  return {
    ok: errors.length === 0,
    changed: changedCount > 0,
    changedCount,
    targetCount: autoexecTargetPaths.length,
    results,
    errors
  };
}

async function luaSyntaxCheck(options: { source?: string; filePath?: string }): Promise<Record<string, unknown>> {
  let tempPath: string | undefined;
  let checkPath: string;

  if (options.filePath) {
    checkPath = assertInsideWorkspace(options.filePath);
  } else {
    const tmpRoot = path.join(workspaceRoot, ".rba-tmp");
    await fs.mkdir(tmpRoot, { recursive: true });
    tempPath = path.join(tmpRoot, `syntax-${Date.now()}-${randomUUID()}.lua`);
    await fs.writeFile(tempPath, options.source ?? "", "utf8");
    checkPath = tempPath;
  }

  try {
    await execFileAsync("luac", ["-p", checkPath], { windowsHide: true });
    return {
      ok: true,
      path: options.filePath ?? tempPath,
      checkedAt: now()
    };
  } catch (error) {
    const err = error as { stderr?: unknown; stdout?: unknown; message?: unknown };
    return {
      ok: false,
      path: options.filePath ?? tempPath,
      error: String(err.stderr || err.stdout || err.message || error),
      checkedAt: now()
    };
  } finally {
    if (tempPath) {
      await fs.rm(tempPath, { force: true });
    }
  }
}

async function installAutoexec(targetPath: string, sourcePath?: string): Promise<Record<string, unknown>> {
  return writeAutoexecFile({ targetPath, sourcePath, backup: true, reason: "manual_install" });
}

async function instanceManagerStatus(timeoutMs = 3000): Promise<Record<string, unknown>> {
  const checkedAt = now();
  let url: URL;
  try {
    url = new URL(INSTANCE_MANAGER_SCRIPT_URL);
  } catch {
    return { ok: false, url: INSTANCE_MANAGER_SCRIPT_URL, checkedAt, error: "Invalid Instance Manager script URL." };
  }
  if (!["localhost", "127.0.0.1", "[::1]", "::1"].includes(url.hostname)) {
    return { ok: false, url: url.toString(), checkedAt, error: "Instance Manager status probes are restricted to loopback hosts." };
  }

  try {
    const response = await fetch(url, {
      method: "GET",
      headers: { Accept: "text/plain" },
      signal: AbortSignal.timeout(Math.max(100, Math.min(timeoutMs, 15_000)))
    });
    const body = await response.text();
    return {
      ok: response.ok,
      url: url.toString(),
      checkedAt,
      statusCode: response.status,
      contentType: response.headers.get("content-type"),
      bytes: Buffer.byteLength(body),
      sha256: sha256(body),
      looksLikeLua: /^\s*--/.test(body) || /\b(local|function)\b/.test(body.slice(0, 1024)),
      error: response.ok ? undefined : `Instance Manager returned HTTP ${response.status}.`
    };
  } catch (error) {
    return {
      ok: false,
      url: url.toString(),
      checkedAt,
      error: error instanceof Error ? error.message : String(error)
    };
  }
}

async function healthCheck(options: { includePing: boolean; timeoutMs: number }): Promise<Record<string, unknown>> {
  const status = await bridgeStatus();
  const clientList = await bridgeClients();
  const publishedConnection = await readPublishedConnectionState();
  const liveConnection = currentConnectionState(webSocketServer ? "server" : bridgeControlSocket?.readyState === WebSocket.OPEN ? "proxy" : "server");
  const autoexecTargets = await Promise.all(autoexecTargetPaths.map(autoexecTargetStatus));
  const result: Record<string, unknown> = {
    status,
    clients: clientList,
    connection: {
      live: liveConnection,
      published: publishedConnection,
      checks: {
        stateFileExists: await pathExists(connectionStatePath),
        activePortKnown: isValidPort(liveConnection.port),
        activeUrlPublished: publishedConnection?.url === liveConnection.url,
        hasCandidateUrls: liveConnection.candidateUrls.length > 0,
        probeBatchSize: controlProbeBatchSize(),
        probeTimeoutMs: controlConnectTimeoutMs()
      }
    },
    local: {
      pid: process.pid,
      workspaceRoot,
      defaultAutoexecPath,
      autoexecTargetPaths,
      autoSyncAutoexec: AUTO_SYNC_AUTOEXEC,
      autoexecTargetPath: defaultAutoexecPath ? resolveAutoexecTarget(defaultAutoexecPath) : "",
      autoexecExists: defaultAutoexecPath ? await pathExists(resolveAutoexecTarget(defaultAutoexecPath)) : false,
      autoexecTargets,
      bridgeControlUrl
    },
    instanceManager: await instanceManagerStatus(options.timeoutMs),
    recentErrors: await bridgeEvents({ limit: 20 })
  };

  if (options.includePing) {
    try {
      result.ping = await pingClients("all", options.timeoutMs);
    } catch (error) {
      result.ping = { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
  }

  return result;
}

type RobloxProcessRecord = {
  processId: number;
  executablePath?: string;
  startTime?: string;
  windowTitle?: string;
};

type RobloxExecutableCandidate = {
  executablePath: string;
  modifiedAt?: string;
};

function parseJsonObject(stdout: string, label: string): Record<string, unknown> {
  const trimmed = stdout.trim();
  if (!trimmed) {
    throw new Error(`${label} returned no JSON output.`);
  }
  const parsed = JSON.parse(trimmed) as unknown;
  if (!isRecord(parsed)) {
    throw new Error(`${label} returned an unexpected payload.`);
  }
  return parsed;
}

function asRobloxProcessRecords(value: unknown): RobloxProcessRecord[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.flatMap((entry) => {
    if (!isRecord(entry) || typeof entry.processId !== "number" || !Number.isInteger(entry.processId) || entry.processId <= 0) {
      return [];
    }
    return [{
      processId: entry.processId,
      executablePath: typeof entry.executablePath === "string" && entry.executablePath ? entry.executablePath : undefined,
      startTime: typeof entry.startTime === "string" && entry.startTime ? entry.startTime : undefined,
      windowTitle: typeof entry.windowTitle === "string" && entry.windowTitle ? entry.windowTitle : undefined
    }];
  });
}

function asRobloxExecutableCandidates(value: unknown): RobloxExecutableCandidate[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.flatMap((entry) => {
    if (!isRecord(entry) || typeof entry.executablePath !== "string" || !entry.executablePath) {
      return [];
    }
    return [{
      executablePath: entry.executablePath,
      modifiedAt: typeof entry.modifiedAt === "string" && entry.modifiedAt ? entry.modifiedAt : undefined
    }];
  });
}

function isRobloxPlayerExecutable(filePath: string): boolean {
  return path.basename(filePath).toLowerCase() === "robloxplayerbeta.exe";
}

async function inspectRobloxProcesses(): Promise<{ processes: RobloxProcessRecord[]; executableCandidates: RobloxExecutableCandidate[] }> {
  const script = String.raw`
$ErrorActionPreference = 'Stop'
$processes = @(
  Get-CimInstance Win32_Process -Filter "Name = 'RobloxPlayerBeta.exe'" -ErrorAction SilentlyContinue |
    ForEach-Object {
      $process = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
      [PSCustomObject]@{
        processId = [int]$_.ProcessId
        executablePath = $_.ExecutablePath
        startTime = if ($process) { $process.StartTime.ToUniversalTime().ToString('o') } else { $null }
        windowTitle = if ($process) { $process.MainWindowTitle } else { $null }
      }
    }
)
$candidateRoot = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Roblox\Versions' } else { $null }
$candidates = @()
if ($candidateRoot -and (Test-Path -LiteralPath $candidateRoot)) {
  $candidates = @(
    Get-ChildItem -LiteralPath $candidateRoot -Filter 'RobloxPlayerBeta.exe' -File -Recurse -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTimeUtc -Descending |
      ForEach-Object {
        [PSCustomObject]@{
          executablePath = $_.FullName
          modifiedAt = $_.LastWriteTimeUtc.ToString('o')
        }
      }
  )
}
@{ processes = @($processes); executableCandidates = @($candidates) } | ConvertTo-Json -Depth 4 -Compress
`;
  const { stdout } = await execFileAsync("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script], {
    windowsHide: true,
    maxBuffer: 2 * 1024 * 1024
  });
  const parsed = parseJsonObject(stdout, "Roblox process inspection");
  return {
    processes: asRobloxProcessRecords(parsed.processes),
    executableCandidates: asRobloxExecutableCandidates(parsed.executableCandidates)
  };
}

function ageMilliseconds(iso: string | undefined, currentMs = Date.now()): number | undefined {
  if (!iso) {
    return undefined;
  }
  const parsed = Date.parse(iso);
  return Number.isFinite(parsed) ? Math.max(0, currentMs - parsed) : undefined;
}

async function robloxCrashStatus(options: { includePing: boolean; timeoutMs: number; staleAfterMs: number; target: ClientTarget }): Promise<Record<string, unknown>> {
  const inspected = await inspectRobloxProcesses();
  const executorClients = activeExecutorClients();
  const currentMs = Date.now();
  const clientHeartbeat = executorClients.map((client) => ({
    clientId: client.id,
    lastHeartbeatAt: client.lastHeartbeatAt,
    heartbeatAgeMs: ageMilliseconds(client.lastHeartbeatAt, currentMs),
    lastMessageAt: client.lastMessageAt,
    messageAgeMs: ageMilliseconds(client.lastMessageAt, currentMs)
  }));
  const staleClients = clientHeartbeat.filter((client) => (client.heartbeatAgeMs ?? Number.POSITIVE_INFINITY) > options.staleAfterMs);
  const reasons: string[] = [];
  let state: "healthy" | "bridge_disconnected" | "likely_crashed" | "not_running";

  if (inspected.processes.length === 0 && executorClients.length > 0) {
    state = "likely_crashed";
    reasons.push("RBA still has an executor connection, but no RobloxPlayerBeta.exe process is present.");
  } else if (inspected.processes.length === 0) {
    state = "not_running";
    reasons.push("No RobloxPlayerBeta.exe process is present.");
  } else if (executorClients.length === 0) {
    state = "bridge_disconnected";
    reasons.push("RobloxPlayerBeta.exe is running, but no RBA executor client is connected.");
  } else if (staleClients.length > 0) {
    state = "likely_crashed";
    reasons.push(`One or more executor heartbeats are older than ${options.staleAfterMs} ms.`);
  } else {
    state = "healthy";
    reasons.push("Roblox process and RBA executor heartbeat are both present.");
  }

  const result: Record<string, unknown> = {
    checkedAt: now(),
    state,
    likelyCrashed: state === "likely_crashed",
    restartRecommended: state === "likely_crashed" || state === "not_running",
    reasons,
    processes: inspected.processes,
    executableCandidates: inspected.executableCandidates,
    clients: clientHeartbeat,
    staleAfterMs: options.staleAfterMs
  };
  if (options.includePing && executorClients.length > 0) {
    try {
      result.ping = await pingClients(options.target, options.timeoutMs);
    } catch (error) {
      result.ping = { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
  }
  return result;
}

async function waitForRobloxProcess(timeoutMs: number): Promise<RobloxProcessRecord[]> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const processes = (await inspectRobloxProcesses()).processes;
    if (processes.length > 0) {
      return processes;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  return [];
}

async function restartRobloxPlayer(options: { restartDelayMs: number; waitForProcessMs: number; closeAll: boolean }): Promise<Record<string, unknown>> {
  const before = await inspectRobloxProcesses();
  const running = before.processes.filter((entry) => entry.executablePath && isRobloxPlayerExecutable(entry.executablePath));
  const selectedPath = running[0]?.executablePath ?? before.executableCandidates.find((entry) => isRobloxPlayerExecutable(entry.executablePath))?.executablePath;
  if (!selectedPath || !isRobloxPlayerExecutable(selectedPath) || !await pathExists(selectedPath)) {
    throw new Error("Could not find a verified RobloxPlayerBeta.exe path. Launch Roblox normally once, then retry.");
  }

  const selectedProcesses = options.closeAll ? running : running.slice(0, 1);
  const processIds = selectedProcesses.map((entry) => entry.processId);
  if (processIds.length > 0) {
    const stopScript = `$ErrorActionPreference = 'Stop'; Stop-Process -Id ${processIds.join(",")} -Force`;
    await execFileAsync("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", stopScript], { windowsHide: true });
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline) {
      const currentIds = new Set((await inspectRobloxProcesses()).processes.map((entry) => entry.processId));
      if (processIds.every((processId) => !currentIds.has(processId))) {
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
  }

  if (options.restartDelayMs > 0) {
    await new Promise((resolve) => setTimeout(resolve, options.restartDelayMs));
  }
  const child = spawn(selectedPath, [], { detached: true, stdio: "ignore", windowsHide: false });
  child.unref();
  const restartedProcesses = await waitForRobloxProcess(options.waitForProcessMs);
  const result = {
    ok: restartedProcesses.length > 0,
    executablePath: selectedPath,
    stoppedProcessIds: processIds,
    launchedPid: child.pid,
    restartedProcesses,
    restartedAt: now()
  };
  addEvent({ at: now(), type: "roblox_restart", message: result.ok ? "Roblox restarted" : "Roblox launch was requested but no process appeared before timeout", data: result });
  return result;
}

type ScriptPreflightFinding = {
  level: "info" | "warning";
  rule: string;
  line?: number;
  message: string;
};

function lineAtOffset(source: string, offset: number): number {
  return source.slice(0, Math.max(0, offset)).split("\n").length;
}

function scriptPreflightFindings(source: string): ScriptPreflightFinding[] {
  const findings: ScriptPreflightFinding[] = [];
  const addPatternFinding = (pattern: RegExp, level: ScriptPreflightFinding["level"], rule: string, message: string): void => {
    const match = pattern.exec(source);
    if (match && match.index !== undefined) {
      findings.push({ level, rule, line: lineAtOffset(source, match.index), message });
    }
  };
  addPatternFinding(/\bwhile\s+true\s+do\b/, "warning", "unbounded-loop", "Found `while true do`; give the loop a stop flag or lifecycle guard.");
  addPatternFinding(/\bloadstring\s*\(/, "info", "dynamic-code", "Uses `loadstring`; validate the loaded source and keep its origin explicit.");
  addPatternFinding(/\bgetgenv\s*\(/, "info", "shared-environment", "Uses `getgenv`; provide a reload/stop guard before installing long-lived state.");
  addPatternFinding(/:(?:FireServer|InvokeServer)\s*\(/, "info", "remote-call", "Contains a Roblox remote call; validate state and arguments before sending it.");
  addPatternFinding(/(?:\.CFrame\s*=|:PivotTo\s*\()/, "warning", "transform-write", "Contains a direct character/object transform write; verify this is intended and safe for the experience.");
  addPatternFinding(/RunService\s*:\s*(?:BindToRenderStep|Heartbeat|RenderStepped|Stepped)/, "info", "frame-loop", "Uses a frame/update loop; disconnect or unbind it during cleanup.");
  if (!/[:.]Disconnect\s*\(/.test(source) && /(\.Connect\s*\(|BindToRenderStep)/.test(source)) {
    findings.push({ level: "warning", rule: "cleanup", message: "Connections are created but no visible `:Disconnect()` call was found." });
  }
  if (/pcall\s*\(\s*previous\.stop/.test(source) || /__RBA_[A-Z0-9_]+/.test(source)) {
    findings.push({ level: "info", rule: "reload-guard", message: "A reload/lifecycle guard was detected." });
  }
  return findings;
}

async function scriptPreflight(options: { source?: string; filePath?: string }): Promise<Record<string, unknown>> {
  if (!options.filePath && options.source === undefined) {
    throw new Error("Provide either path or source.");
  }
  if (options.filePath && options.source !== undefined) {
    throw new Error("Provide a workspace path or source, not both.");
  }
  const source = options.filePath
    ? await fs.readFile(assertInsideWorkspace(options.filePath), "utf8")
    : options.source ?? "";
  const syntax = await luaSyntaxCheck({ source, filePath: options.filePath });
  const lines = source.length === 0 ? 0 : source.split(/\r?\n/).length;
  const longLineCount = source.split(/\r?\n/).filter((line) => line.length > 180).length;
  return {
    ok: syntax.ok === true,
    path: options.filePath,
    metrics: {
      bytes: Buffer.byteLength(source),
      lines,
      longLineCount,
      sha256: sha256(source)
    },
    syntax,
    findings: scriptPreflightFindings(source),
    checkedAt: now()
  };
}

function capsuleRegistryPath(): string {
  return assertInsideWorkspace(CAPSULE_REGISTRY_PATH);
}

function capsuleRoot(id: string): string {
  return assertInsideWorkspace(path.join(CAPSULE_DIR, id));
}

function assertCapsuleId(id: string): string {
  const normalized = id.trim().toLowerCase();
  if (!/^[a-z0-9][a-z0-9_-]{0,63}$/.test(normalized)) {
    throw new Error("Capsule id must use 1-64 lowercase letters, numbers, hyphens, or underscores and start with a letter or number.");
  }
  return normalized;
}

function normalizeCapsulePermissions(value: unknown): CapsulePermission[] {
  if (!Array.isArray(value)) {
    return [];
  }
  const permissions = value.flatMap((item) => typeof item === "string" && capsulePermissions.includes(item as CapsulePermission)
    ? [item as CapsulePermission]
    : []);
  return Array.from(new Set(permissions)).sort();
}

function publicCapsule(capsule: ScriptCapsule): Record<string, unknown> {
  return {
    ...capsule,
    isolation: "policy_envelope",
    sandboxLimit: "Capsules enforce RBA preflight and permission policy before dispatch. They cannot OS-isolate arbitrary executor Lua after it reaches a Roblox client."
  };
}

async function loadCapsuleRegistry(): Promise<CapsuleRegistry> {
  const registryPath = capsuleRegistryPath();
  if (!await pathExists(registryPath)) {
    return { version: 1, capsules: [] };
  }
  const raw = await fs.readFile(registryPath, "utf8");
  const parsed = JSON.parse(raw) as unknown;
  if (!isRecord(parsed) || parsed.version !== 1 || !Array.isArray(parsed.capsules)) {
    throw new Error(`Invalid capsule registry: ${path.relative(workspaceRoot, registryPath)}`);
  }
  const capsules = parsed.capsules.flatMap((entry) => {
    if (!isRecord(entry) || typeof entry.id !== "string" || typeof entry.name !== "string" || typeof entry.filePath !== "string" || typeof entry.createdAt !== "string" || typeof entry.updatedAt !== "string") {
      return [];
    }
    try {
      const id = assertCapsuleId(entry.id);
      const filePath = path.relative(workspaceRoot, assertInsideWorkspace(entry.filePath));
      return [{
        id,
        name: entry.name,
        filePath,
        permissions: normalizeCapsulePermissions(entry.permissions),
        createdAt: entry.createdAt,
        updatedAt: entry.updatedAt,
        lastSnapshotId: typeof entry.lastSnapshotId === "string" ? entry.lastSnapshotId : undefined,
        lastRunAt: typeof entry.lastRunAt === "string" ? entry.lastRunAt : undefined
      } satisfies ScriptCapsule];
    } catch {
      return [];
    }
  });
  return { version: 1, capsules };
}

async function saveCapsuleRegistry(registry: CapsuleRegistry): Promise<void> {
  const registryPath = capsuleRegistryPath();
  await fs.mkdir(path.dirname(registryPath), { recursive: true });
  const temporaryPath = `${registryPath}.${process.pid}.${randomUUID()}.tmp`;
  await fs.writeFile(temporaryPath, `${JSON.stringify(registry, null, 2)}\n`, "utf8");
  await fs.rename(temporaryPath, registryPath);
}

async function findCapsule(id: string): Promise<{ registry: CapsuleRegistry; capsule: ScriptCapsule }> {
  const normalizedId = assertCapsuleId(id);
  const registry = await loadCapsuleRegistry();
  const capsule = registry.capsules.find((entry) => entry.id === normalizedId);
  if (!capsule) {
    throw new Error(`Unknown script capsule: ${normalizedId}`);
  }
  return { registry, capsule };
}

function requiredCapsulePermissions(source: string): CapsulePermission[] {
  const required = new Set<CapsulePermission>();
  if (/\b(?:game\s*:\s*HttpGet|HttpService\s*:\s*(?:GetAsync|PostAsync|RequestAsync)|request|http_request|syn\.request)\b/i.test(source)) required.add("http");
  if (/\b(?:readfile|writefile|appendfile|delfile|listfiles|makefolder|isfile|isfolder)\s*\(/i.test(source)) required.add("filesystem");
  if (/:\s*(?:FireServer|InvokeServer)\s*\(/.test(source)) required.add("remotes");
  if (/\b(?:loadstring|getgenv|setfenv|getfenv)\s*\(/i.test(source)) required.add("dynamic_code");
  if (/(?:\.CFrame\s*=|:\s*PivotTo\s*\()/.test(source)) required.add("transform");
  if (/\bwhile\s+true\s+do\b|\bRunService\s*:\s*(?:BindToRenderStep|Heartbeat|RenderStepped|Stepped)/.test(source)) required.add("frame_loop");
  return [...required].sort();
}

async function createCapsule(options: { id: string; name: string; filePath: string; permissions: CapsulePermission[] }): Promise<Record<string, unknown>> {
  const id = assertCapsuleId(options.id);
  const source = assertInsideWorkspace(options.filePath);
  const stats = await fs.stat(source);
  if (!stats.isFile()) {
    throw new Error(`Capsules can only manage files: ${options.filePath}`);
  }
  const registry = await loadCapsuleRegistry();
  if (registry.capsules.some((capsule) => capsule.id === id)) {
    throw new Error(`A script capsule named ${id} already exists.`);
  }
  const createdAt = now();
  const capsule: ScriptCapsule = {
    id,
    name: options.name.trim() || id,
    filePath: path.relative(workspaceRoot, source),
    permissions: normalizeCapsulePermissions(options.permissions),
    createdAt,
    updatedAt: createdAt
  };
  registry.capsules.push(capsule);
  await saveCapsuleRegistry(registry);
  addEvent({ at: now(), type: "capsule_created", message: `Created script capsule ${id}`, data: publicCapsule(capsule) });
  return { ok: true, capsule: publicCapsule(capsule) };
}

async function snapshotCapsule(id: string, reason: string): Promise<Record<string, unknown>> {
  const { registry, capsule } = await findCapsule(id);
  const source = assertInsideWorkspace(capsule.filePath);
  const stats = await fs.stat(source);
  if (!stats.isFile()) {
    throw new Error(`Capsule source is no longer a file: ${capsule.filePath}`);
  }
  const snapshotId = `${backupTimestamp()}-${randomUUID().slice(0, 8)}`;
  const snapshotDirectory = path.join(capsuleRoot(capsule.id), "snapshots", snapshotId);
  const sourceName = path.basename(source);
  const snapshotPath = path.join(snapshotDirectory, sourceName);
  const sourceText = await fs.readFile(source, "utf8");
  const metadata = {
    snapshotId,
    capsuleId: capsule.id,
    source: capsule.filePath,
    sourceName,
    reason,
    bytes: stats.size,
    sha256: sha256(sourceText),
    createdAt: now()
  };
  await fs.mkdir(snapshotDirectory, { recursive: true });
  await fs.copyFile(source, snapshotPath);
  await fs.writeFile(path.join(snapshotDirectory, "snapshot.json"), `${JSON.stringify(metadata, null, 2)}\n`, "utf8");
  capsule.lastSnapshotId = snapshotId;
  capsule.updatedAt = now();
  await saveCapsuleRegistry(registry);
  addEvent({ at: now(), type: "capsule_snapshot", message: `Captured ${capsule.id} snapshot ${snapshotId}`, data: metadata });
  return { ok: true, ...metadata, snapshotPath: path.relative(workspaceRoot, snapshotPath) };
}

async function listCapsuleSnapshots(id: string): Promise<unknown[]> {
  const { capsule } = await findCapsule(id);
  const snapshotsDirectory = path.join(capsuleRoot(capsule.id), "snapshots");
  if (!await pathExists(snapshotsDirectory)) {
    return [];
  }
  const entries = await fs.readdir(snapshotsDirectory, { withFileTypes: true });
  const snapshots: Array<Record<string, unknown> | undefined> = await Promise.all(entries.filter((entry) => entry.isDirectory()).map(async (entry) => {
    const metadataPath = path.join(snapshotsDirectory, entry.name, "snapshot.json");
    try {
      const metadata = JSON.parse(await fs.readFile(metadataPath, "utf8")) as unknown;
      return isRecord(metadata) ? { ...metadata, snapshotPath: path.relative(workspaceRoot, path.join(snapshotsDirectory, entry.name)) } as Record<string, unknown> : undefined;
    } catch {
      return undefined;
    }
  }));
  return snapshots.filter((snapshot): snapshot is Record<string, unknown> => snapshot !== undefined)
    .sort((a, b) => String(b.createdAt ?? "").localeCompare(String(a.createdAt ?? "")));
}

async function rollbackCapsule(id: string, snapshotId: string): Promise<Record<string, unknown>> {
  const { capsule } = await findCapsule(id);
  const normalizedSnapshotId = snapshotId.trim();
  if (!/^[0-9TZ-]+-[a-z0-9]{8}$/i.test(normalizedSnapshotId)) {
    throw new Error("Invalid capsule snapshot id.");
  }
  const snapshotsDirectory = path.join(capsuleRoot(capsule.id), "snapshots", normalizedSnapshotId);
  const metadataPath = path.join(snapshotsDirectory, "snapshot.json");
  const metadata = JSON.parse(await fs.readFile(metadataPath, "utf8")) as unknown;
  if (!isRecord(metadata) || metadata.capsuleId !== capsule.id || typeof metadata.sourceName !== "string") {
    throw new Error("Capsule snapshot metadata does not match the selected capsule.");
  }
  const snapshotPath = path.join(snapshotsDirectory, metadata.sourceName);
  if (!await pathExists(snapshotPath)) {
    throw new Error("Capsule snapshot source is missing.");
  }
  const safetySnapshot = await snapshotCapsule(capsule.id, "before_rollback");
  const destination = assertInsideWorkspace(capsule.filePath);
  await fs.copyFile(snapshotPath, destination);
  addEvent({ at: now(), type: "capsule_rollback", message: `Rolled ${capsule.id} back to ${normalizedSnapshotId}`, data: { capsuleId: capsule.id, snapshotId: normalizedSnapshotId } });
  return { ok: true, capsuleId: capsule.id, restoredSnapshotId: normalizedSnapshotId, restoredTo: capsule.filePath, safetySnapshot };
}

async function setCapsulePermissions(id: string, permissions: CapsulePermission[]): Promise<Record<string, unknown>> {
  const { registry, capsule } = await findCapsule(id);
  capsule.permissions = normalizeCapsulePermissions(permissions);
  capsule.updatedAt = now();
  await saveCapsuleRegistry(registry);
  addEvent({ at: now(), type: "capsule_permissions", message: `Updated permissions for ${capsule.id}`, data: publicCapsule(capsule) });
  return { ok: true, capsule: publicCapsule(capsule) };
}

async function runCapsule(options: { id: string; mode: "send" | "eval"; target: ClientTarget; syntaxCheck: boolean; timeoutMs: number; snapshotBeforeRun: boolean }): Promise<Record<string, unknown> | unknown[]> {
  const { registry, capsule } = await findCapsule(options.id);
  const source = await fs.readFile(assertInsideWorkspace(capsule.filePath), "utf8");
  const requiredPermissions = requiredCapsulePermissions(source);
  const deniedPermissions = requiredPermissions.filter((permission) => !capsule.permissions.includes(permission));
  const preflight = await scriptPreflight({ source });
  if (preflight.ok !== true || deniedPermissions.length > 0) {
    addEvent({ at: now(), type: "capsule_blocked", message: `Blocked capsule ${capsule.id}`, data: { requiredPermissions, deniedPermissions, preflight } });
    return { ok: false, capsule: publicCapsule(capsule), requiredPermissions, deniedPermissions, preflight };
  }
  const snapshot = options.snapshotBeforeRun ? await snapshotCapsule(capsule.id, "before_run") : undefined;
  if (snapshot && typeof snapshot.snapshotId === "string") {
    capsule.lastSnapshotId = snapshot.snapshotId;
  }
  const result = await executeLuaFile({
    filePath: capsule.filePath,
    mode: options.mode,
    target: options.target,
    syntaxCheck: options.syntaxCheck,
    timeoutMs: options.timeoutMs,
    label: `capsule:${capsule.id}`
  });
  capsule.lastRunAt = now();
  capsule.updatedAt = now();
  await saveCapsuleRegistry(registry);
  addEvent({ at: now(), type: "capsule_run", message: `Dispatched capsule ${capsule.id}`, data: { mode: options.mode, requiredPermissions } });
  return { ok: true, capsule: publicCapsule(capsule), requiredPermissions, snapshot, result };
}

async function gitOutput(args: string[]): Promise<string> {
  const { stdout } = await execFileAsync("git", args, { cwd: workspaceRoot, windowsHide: true, maxBuffer: 2 * 1024 * 1024 });
  return stdout.trim();
}

async function gitRepositoryStatus(): Promise<Record<string, unknown>> {
  try {
    const root = await gitOutput(["rev-parse", "--show-toplevel"]);
    const [branch, origin, porcelain, staged] = await Promise.all([
      gitOutput(["branch", "--show-current"]),
      gitOutput(["remote", "get-url", "origin"]).catch(() => ""),
      gitOutput(["status", "--porcelain=v1", "--branch"]),
      gitOutput(["diff", "--cached", "--name-only"])
    ]);
    const autoloaderPath = path.join(workspaceRoot, "lua", AUTOEXEC_FILENAME);
    const autoloader = await pathExists(autoloaderPath)
      ? { path: path.relative(workspaceRoot, autoloaderPath), sha256: sha256(await fs.readFile(autoloaderPath)), bytes: (await fs.stat(autoloaderPath)).size }
      : { path: path.relative(workspaceRoot, autoloaderPath), missing: true };
    const changedFiles = porcelain.split(/\r?\n/).filter(Boolean).filter((line) => !line.startsWith("##"));
    return {
      ok: true,
      root,
      branch,
      origin: origin || undefined,
      changedFiles,
      stagedFiles: staged.split(/\r?\n/).filter(Boolean),
      autoloader,
      capsuleRegistry: path.relative(workspaceRoot, capsuleRegistryPath()),
      checkedAt: now()
    };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error), checkedAt: now() };
  }
}

async function syncWorkspaceFilesToGit(options: { files: string[]; message: string; remote: string; branch?: string; push: boolean }): Promise<Record<string, unknown>> {
  if (options.files.length === 0) {
    throw new Error("Provide at least one explicit workspace file. RBA never uses git add --all for script sync.");
  }
  const files = await Promise.all(options.files.map(async (filePath) => {
    const absolute = assertInsideWorkspace(filePath);
    if (!await pathExists(absolute)) {
      throw new Error(`Cannot sync a missing file: ${filePath}`);
    }
    return path.relative(workspaceRoot, absolute);
  }));
  const uniqueFiles = Array.from(new Set(files));
  await gitOutput(["rev-parse", "--is-inside-work-tree"]);
  const alreadyStaged = (await gitOutput(["diff", "--cached", "--name-only"])).split(/\r?\n/).filter(Boolean);
  if (alreadyStaged.length > 0) {
    throw new Error(`Refusing to mix this sync with ${alreadyStaged.length} already-staged file(s). Review or commit the existing index first.`);
  }
  await gitOutput(["add", "--", ...uniqueFiles]);
  const stagedFiles = (await gitOutput(["diff", "--cached", "--name-only"])).split(/\r?\n/).filter(Boolean);
  if (stagedFiles.length === 0) {
    return { ok: true, committed: false, pushed: false, files: uniqueFiles, message: "No selected file changes to commit." };
  }
  await gitOutput(["commit", "-m", options.message]);
  let pushResult: string | undefined;
  if (options.push) {
    const branch = options.branch?.trim() || await gitOutput(["branch", "--show-current"]);
    if (!branch) {
      throw new Error("A branch is required before pushing.");
    }
    pushResult = await gitOutput(["push", "--set-upstream", options.remote, branch]);
  }
  const result = { ok: true, committed: true, pushed: options.push, files: uniqueFiles, stagedFiles, pushResult, syncedAt: now() };
  addEvent({ at: now(), type: "git_sync", message: `Committed ${uniqueFiles.length} explicitly selected workspace file(s)`, data: result });
  return result;
}

function defaultScreenshotPath(label: string): string {
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const safeLabel = label.replace(/[^a-z0-9_-]/gi, "_");
  return path.join("screenshots", `${safeLabel}-${timestamp}.png`);
}

function imageMimeType(filePath: string): string {
  const ext = path.extname(filePath).toLowerCase();
  if (ext === ".jpg" || ext === ".jpeg") {
    return "image/jpeg";
  }
  return "image/png";
}

async function listWindows(): Promise<unknown[]> {
  const script = String.raw`
$ErrorActionPreference = 'Stop'
$windows = Get-Process |
  Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle } |
  Sort-Object ProcessName, Id |
  ForEach-Object {
    [PSCustomObject]@{
      processName = $_.ProcessName
      id = $_.Id
      title = $_.MainWindowTitle
      handle = $_.MainWindowHandle.ToInt64()
    }
  }
@($windows) | ConvertTo-Json -Depth 4 -Compress
`;
  const { stdout } = await execFileAsync("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script], {
    windowsHide: true,
    maxBuffer: 5 * 1024 * 1024
  });
  const parsed = JSON.parse(stdout.trim() || "[]");
  return Array.isArray(parsed) ? parsed : [parsed];
}

async function captureProcessWindow(processName: string, outputPath: string, focusWindow: boolean): Promise<unknown> {
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  const script = String.raw`
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public struct RECT {
  public int Left;
  public int Top;
  public int Right;
  public int Bottom;
}

public static class RbaWin32 {
  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

  [DllImport("user32.dll")]
  public static extern bool SetProcessDPIAware();

  [DllImport("user32.dll")]
  public static extern bool IsIconic(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

[void][RbaWin32]::SetProcessDPIAware()
$processName = $env:RBA_SCREENSHOT_PROCESS
$outputPath = $env:RBA_SCREENSHOT_PATH
$focusWindow = $env:RBA_SCREENSHOT_FOCUS -eq 'true'
$process = Get-Process -Name $processName -ErrorAction Stop |
  Where-Object { $_.MainWindowHandle -ne 0 } |
  Sort-Object StartTime -Descending |
  Select-Object -First 1

if (-not $process) {
  throw "No visible window found for process '$processName'."
}

$handle = $process.MainWindowHandle
if ([RbaWin32]::IsIconic($handle)) {
  [void][RbaWin32]::ShowWindow($handle, 9)
  Start-Sleep -Milliseconds 250
}

if ($focusWindow) {
  [void][RbaWin32]::SetForegroundWindow($handle)
  Start-Sleep -Milliseconds 250
}

$rect = New-Object RECT
if (-not [RbaWin32]::GetWindowRect($handle, [ref]$rect)) {
  throw "Could not read window bounds for process '$processName'."
}

$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
if ($width -le 0 -or $height -le 0) {
  throw "Window bounds for process '$processName' are empty."
}

$directory = Split-Path -Parent $outputPath
if ($directory) {
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

$bitmap = New-Object System.Drawing.Bitmap $width, $height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
  $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
  $bitmap.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
  $graphics.Dispose()
  $bitmap.Dispose()
}

@{
  processName = $process.ProcessName
  processId = $process.Id
  windowTitle = $process.MainWindowTitle
  path = $outputPath
  width = $width
  height = $height
  bounds = @{
    left = $rect.Left
    top = $rect.Top
    right = $rect.Right
    bottom = $rect.Bottom
  }
  focused = $focusWindow
  capturedAt = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json -Depth 5 -Compress
`;
  const { stdout, stderr } = await execFileAsync("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script], {
    env: {
      ...process.env,
      RBA_SCREENSHOT_PROCESS: processName,
      RBA_SCREENSHOT_PATH: outputPath,
      RBA_SCREENSHOT_FOCUS: String(focusWindow)
    },
    windowsHide: true,
    maxBuffer: 10 * 1024 * 1024
  });
  if (stderr.trim()) {
    addEvent({ at: now(), type: "screenshot_warning", message: stderr.trim() });
  }
  return JSON.parse(stdout.trim());
}

async function captureDesktopScreen(outputPath: string): Promise<unknown> {
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  const script = String.raw`
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$outputPath = $env:RBA_SCREENSHOT_PATH
$screens = [System.Windows.Forms.Screen]::AllScreens
$left = ($screens | ForEach-Object { $_.Bounds.Left } | Measure-Object -Minimum).Minimum
$top = ($screens | ForEach-Object { $_.Bounds.Top } | Measure-Object -Minimum).Minimum
$right = ($screens | ForEach-Object { $_.Bounds.Right } | Measure-Object -Maximum).Maximum
$bottom = ($screens | ForEach-Object { $_.Bounds.Bottom } | Measure-Object -Maximum).Maximum
$width = $right - $left
$height = $bottom - $top

if ($width -le 0 -or $height -le 0) {
  throw "Desktop bounds are empty."
}

$directory = Split-Path -Parent $outputPath
if ($directory) {
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

$bitmap = New-Object System.Drawing.Bitmap $width, $height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
  $graphics.CopyFromScreen($left, $top, 0, 0, $bitmap.Size)
  $bitmap.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
  $graphics.Dispose()
  $bitmap.Dispose()
}

@{
  captureMode = "desktop"
  path = $outputPath
  width = $width
  height = $height
  bounds = @{
    left = $left
    top = $top
    right = $right
    bottom = $bottom
  }
  capturedAt = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json -Depth 5 -Compress
`;
  const { stdout, stderr } = await execFileAsync("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script], {
    env: {
      ...process.env,
      RBA_SCREENSHOT_PATH: outputPath
    },
    windowsHide: true,
    maxBuffer: 10 * 1024 * 1024
  });
  if (stderr.trim()) {
    addEvent({ at: now(), type: "screenshot_warning", message: stderr.trim() });
  }
  return JSON.parse(stdout.trim());
}

async function captureRobloxOrDesktop(outputPath: string, focusWindow: boolean): Promise<unknown> {
  try {
    return await captureProcessWindow("RobloxPlayerBeta", outputPath, focusWindow);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    addEvent({ at: now(), type: "screenshot_warning", message: `Roblox window capture failed; using desktop fallback. ${message}` });
    const desktopMeta = await captureDesktopScreen(outputPath) as Record<string, unknown>;
    return {
      ...desktopMeta,
      fallbackReason: message
    };
  }
}

async function walkFiles(root: string, recursive: boolean, maxEntries: number): Promise<string[]> {
  const output: string[] = [];
  async function visit(current: string): Promise<void> {
    if (output.length >= maxEntries) {
      return;
    }
    const entries = await fs.readdir(current, { withFileTypes: true });
    for (const entry of entries) {
      if (output.length >= maxEntries) {
        break;
      }
      const fullPath = path.join(current, entry.name);
      const relPath = path.relative(workspaceRoot, fullPath);
      output.push(entry.isDirectory() ? `${relPath}${path.sep}` : relPath);
      if (recursive && entry.isDirectory() && entry.name !== "node_modules" && entry.name !== "dist" && !entry.name.startsWith(".")) {
        await visit(fullPath);
      }
    }
  }
  await visit(root);
  return output;
}

function fileIoConcurrency(): number {
  return Number.isFinite(FILE_IO_CONCURRENCY) ? Math.max(1, Math.min(FILE_IO_CONCURRENCY, 64)) : 16;
}

function searchMaxFileBytes(): number {
  return Number.isFinite(SEARCH_MAX_FILE_BYTES) ? Math.max(1024, Math.min(SEARCH_MAX_FILE_BYTES, 50_000_000)) : 2_097_152;
}

async function searchWorkspaceFiles(options: {
  start: string;
  query: string;
  extensions: string[];
  maxResults: number;
}): Promise<Array<{ path: string; line: number; text: string }>> {
  const files = (await walkFiles(options.start, true, 5000)).filter((entry) => !entry.endsWith(path.sep));
  const normalizedExts = new Set(options.extensions.map((ext) => (ext.startsWith(".") ? ext : `.${ext}`).toLowerCase()));
  const candidates = normalizedExts.size === 0
    ? files
    : files.filter((entry) => normalizedExts.has(path.extname(entry).toLowerCase()));
  const results: Array<{ path: string; line: number; text: string }> = [];
  const concurrency = fileIoConcurrency();

  for (let offset = 0; offset < candidates.length && results.length < options.maxResults; offset += concurrency) {
    const batch = candidates.slice(offset, offset + concurrency);
    const batchMatches = await Promise.all(batch.map(async (relFile) => {
      try {
        const buffer = await fs.readFile(assertInsideWorkspace(relFile));
        if (buffer.byteLength > searchMaxFileBytes() || buffer.includes(0)) {
          return [];
        }
        const matches: Array<{ path: string; line: number; text: string }> = [];
        const lines = buffer.toString("utf8").split(/\r?\n/);
        for (let index = 0; index < lines.length; index++) {
          if (lines[index].includes(options.query)) {
            matches.push({ path: relFile, line: index + 1, text: lines[index] });
          }
        }
        return matches;
      } catch {
        return [];
      }
    }));

    for (const matches of batchMatches) {
      for (const match of matches) {
        results.push(match);
        if (results.length >= options.maxResults) {
          return results;
        }
      }
    }
  }
  return results;
}

function getClientTargets(target: ClientTarget): ClientRecord[] {
  const openClients = activeExecutorClients();
  if (target === "all") {
    return openClients;
  }
  if (target === "first") {
    return openClients.slice(0, 1);
  }
  return openClients.filter((client) => client.id === target);
}

function sendLuaToClients(script: string, target: ClientTarget): number {
  const targets = getClientTargets(target);
  let sent = 0;
  for (const client of targets) {
    if (!sendSocketText(client.socket, script)) {
      addEvent({
        at: now(),
        type: "send_dropped",
        clientId: client.id,
        message: `Dropped ${script.length} byte Lua send because the socket was unavailable, oversized, or backpressured`,
        data: { bytes: script.length, target }
      });
      continue;
    }
    sent++;
    addEvent({
      at: now(),
      type: "send_lua",
      clientId: client.id,
      message: `Sent ${script.length} bytes`,
      data: { bytes: script.length, target }
    });
  }
  return sent;
}

function sendProtocolToClients(payload: Record<string, unknown>, target: ClientTarget): number {
  const targets = getClientTargets(target);
  const text = JSON.stringify(payload);
  let sent = 0;
  for (const client of targets) {
    if (!sendSocketText(client.socket, text)) {
      addEvent({
        at: now(),
        type: "send_dropped",
        clientId: client.id,
        message: `Dropped protocol message ${String(payload.type ?? "unknown")} because the socket was unavailable, oversized, or backpressured`,
        data: { target, bytes: Buffer.byteLength(text), protocolType: payload.type }
      });
      continue;
    }
    sent++;
    addEvent({
      at: now(),
      type: String(payload.type ?? "protocol_message"),
      clientId: client.id,
      message: `Sent protocol message ${String(payload.type ?? "unknown")}`,
      data: { target, bytes: Buffer.byteLength(text), protocolType: payload.type }
    });
  }
  return sent;
}

async function sendProtocol(payload: Record<string, unknown>, target: ClientTarget): Promise<number> {
  if (!webSocketServer && await ensureBridgeControl()) {
    const result = await controlRequest("protocol", { payload, target }, 10_000) as { sent?: unknown };
    return Number(result.sent ?? 0);
  }
  return sendProtocolToClients(payload, target);
}

async function sendLua(script: string, target: ClientTarget): Promise<number> {
  if (!webSocketServer && await ensureBridgeControl()) {
    const result = await controlRequest("send_lua", { script, target }, 10_000) as { sent?: unknown };
    return Number(result.sent ?? 0);
  }
  return sendLuaToClients(script, target);
}

async function requestEvalFromClients(source: string, target: ClientTarget, timeoutMs: number, label: string): Promise<unknown[]> {
  const targets = getClientTargets(target);
  if (targets.length === 0) {
    throw new Error("No connected RBA websocket clients.");
  }

  const requests = targets.map(async (client) => {
    const requestId = `rba_${Date.now()}_${randomUUID()}`;
    const sentAt = Date.now();
    const responsePromise = waitForResponse(requestId, timeoutMs, client.id);
    const sent = sendSocketJson(client.socket, {
        type: "eval",
        requestId,
        label,
        source,
        timeoutMs
      });
    if (!sent) {
      rejectPendingResponse(
        requestId,
        new Error(`Could not send eval "${label}" to client ${client.id} because the socket was unavailable, oversized, or backpressured.`)
      );
    }
    addEvent({
      at: now(),
      type: sent ? "eval_lua" : "send_dropped",
      clientId: client.id,
      message: sent
        ? `Sent eval "${label}" (${source.length} bytes, request ${requestId})`
        : `Dropped eval "${label}" (${source.length} bytes, request ${requestId})`,
      data: { label, requestId, bytes: source.length, target }
    });
    const response = await responsePromise;
    return {
      requestId,
      clientId: client.id,
      roundTripMs: Date.now() - sentAt,
      response
    };
  });

    return Promise.all(requests);
  }

async function requestEval(source: string, target: ClientTarget, timeoutMs: number, label: string): Promise<unknown[]> {
  if (!webSocketServer && await ensureBridgeControl()) {
    return await controlRequest("eval_lua", { source, target, timeoutMs, label }, timeoutMs + 2_000) as unknown[];
  }
  return requestEvalFromClients(source, target, timeoutMs, label);
}

async function pingClients(target: ClientTarget, timeoutMs: number): Promise<unknown[]> {
  const source = String.raw`return {
    pong = true,
    clock = os.clock(),
    serverTimeSeen = os.time(),
    placeId = game.PlaceId,
    jobId = game.JobId
}`;
  return requestEval(source, target, timeoutMs, "ping");
}

function characterPositionScript(): string {
  return luaPresets.character_position.script;
}

function teleportToPositionScript(options: { x: number; y: number; z: number; yawDegrees: number }): string {
  return String.raw`local Players = game:GetService("Players")
local character = Players.LocalPlayer and Players.LocalPlayer.Character
local root = character and character:FindFirstChild("HumanoidRootPart")
if not (character and root) then
    error("Local character HumanoidRootPart is not available")
end
_G.RBA = _G.RBA or {}
_G.RBA.lastTeleportCFrame = character:GetPivot()
local destination = CFrame.new(${options.x}, ${options.y}, ${options.z}) * CFrame.Angles(0, math.rad(${options.yawDegrees}), 0)
character:PivotTo(destination)
return { ok = true, position = root.Position, yawDegrees = ${options.yawDegrees} }`;
}

function teleportToPartScript(options: { partPath: string; offsetX: number; offsetY: number; offsetZ: number; yawDegrees: number }): string {
  return String.raw`local Players = game:GetService("Players")
local character = Players.LocalPlayer and Players.LocalPlayer.Character
local root = character and character:FindFirstChild("HumanoidRootPart")
if not (character and root) then
    error("Local character HumanoidRootPart is not available")
end

local rawPath = ${luaString(options.partPath)}
local normalizedPath = rawPath:gsub("\\", "/")
if not normalizedPath:find("/", 1, true) then
    normalizedPath = normalizedPath:gsub("%.", "/")
end
local destination = workspace
for segment in normalizedPath:gmatch("[^/]+") do
    if segment ~= "Workspace" and segment ~= "workspace" and segment ~= "game" then
        destination = destination:FindFirstChild(segment)
        if not destination then
            error("Could not find path segment '" .. segment .. "' in " .. rawPath)
        end
    end
end

local destinationCFrame
local destinationHeight = 0
if destination:IsA("BasePart") then
    destinationCFrame = destination.CFrame
    destinationHeight = destination.Size.Y / 2
elseif destination:IsA("Model") then
    destinationCFrame = destination:GetPivot()
    destinationHeight = destination:GetExtentsSize().Y / 2
else
    error("Destination must be a BasePart or Model, got " .. destination.ClassName)
end

_G.RBA = _G.RBA or {}
_G.RBA.lastTeleportCFrame = character:GetPivot()
local offset = CFrame.new(${options.offsetX}, ${options.offsetY} + destinationHeight, ${options.offsetZ})
local rotation = CFrame.Angles(0, math.rad(${options.yawDegrees}), 0)
character:PivotTo(destinationCFrame * offset * rotation)
return {
    ok = true,
    destination = destination:GetFullName(),
    className = destination.ClassName,
    position = root.Position
}`;
}

function returnToLastTeleportScript(): string {
  return String.raw`local Players = game:GetService("Players")
local character = Players.LocalPlayer and Players.LocalPlayer.Character
if not character then
    error("Local character is not available")
end
if not (_G.RBA and _G.RBA.lastTeleportCFrame) then
    error("No previous teleport position is available")
end
local destination = _G.RBA.lastTeleportCFrame
_G.RBA.lastTeleportCFrame = character:GetPivot()
character:PivotTo(destination)
return { ok = true, position = character:GetPivot().Position }`;
}

function teleportToPlaceScript(placeId: number, jobId?: string): string {
  const invocation = jobId
    ? `TeleportService:TeleportToPlaceInstance(${placeId}, ${luaString(jobId)}, player)`
    : `TeleportService:Teleport(${placeId}, player)`;
  return String.raw`local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local player = Players.LocalPlayer
if not player then
    error("LocalPlayer is not available")
end
task.delay(0.25, function()
    ${invocation}
end)
return { ok = true, scheduled = true, placeId = ${placeId}, jobId = ${jobId ? luaString(jobId) : "nil"} }`;
}

async function notifyClients(options: { title: string; message: string; level: "info" | "success" | "warn" | "error"; durationMs: number; target: ClientTarget }): Promise<Record<string, unknown>> {
  const sent = await sendProtocol({
    type: "rba_notify",
    title: options.title,
    message: options.message,
    level: options.level,
    durationMs: options.durationMs
  }, options.target);
  return { ok: true, sent, target: options.target };
}

async function setClientStatus(options: { message: string; level: "info" | "success" | "warn" | "error"; target: ClientTarget }): Promise<Record<string, unknown>> {
  const sent = await sendProtocol({
    type: "rba_status",
    message: options.message,
    level: options.level
  }, options.target);
  return { ok: true, sent, target: options.target };
}

async function executeLuaFile(options: { filePath: string; mode: "send" | "eval"; target: ClientTarget; syntaxCheck: boolean; timeoutMs: number; label?: string }): Promise<Record<string, unknown> | unknown[]> {
  const resolved = assertInsideWorkspace(options.filePath);
  if (options.syntaxCheck) {
    const check = await luaSyntaxCheck({ filePath: resolved });
    if (check.ok === false) {
      return { ok: false, phase: "syntax", path: options.filePath, check };
    }
  }
  const script = await fs.readFile(resolved, "utf8");
  if (options.mode === "send") {
    const sent = await sendLua(script, options.target);
    return { ok: true, mode: options.mode, path: options.filePath, bytes: script.length, sent };
  }
  return requestEval(script, options.target, options.timeoutMs, options.label ?? `execute_file:${options.filePath}`);
}

async function executeBundle(options: { files: string[]; mode: "send" | "eval"; target: ClientTarget; syntaxCheck: boolean; timeoutMs: number; stopOnError: boolean; delayMs: number }): Promise<Record<string, unknown>> {
  const results: unknown[] = [];
  for (const filePath of options.files) {
    const startedAt = Date.now();
    try {
      const result = await executeLuaFile({
        filePath,
        mode: options.mode,
        target: options.target,
        syntaxCheck: options.syntaxCheck,
        timeoutMs: options.timeoutMs,
        label: `bundle:${filePath}`
      });
      results.push({ path: filePath, ok: true, durationMs: Date.now() - startedAt, result });
      if (isRecord(result) && result.ok === false && options.stopOnError) {
        break;
      }
    } catch (error) {
      const failure = { path: filePath, ok: false, durationMs: Date.now() - startedAt, error: error instanceof Error ? error.message : String(error) };
      results.push(failure);
      if (options.stopOnError) {
        break;
      }
    }
    if (options.delayMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, options.delayMs));
    }
  }
  return {
    ok: results.every((result) => !isRecord(result) || result.ok !== false),
    files: options.files.length,
    mode: options.mode,
    target: options.target,
    results
  };
}

async function startLiveSession(options: { files: string[]; mode: "send" | "eval"; target: ClientTarget; syntaxCheck: boolean; timeoutMs: number; debounceMs: number; runOnce: boolean }): Promise<Record<string, unknown>> {
  const watchers: unknown[] = [];
  if (options.runOnce) {
    await executeBundle({
      files: options.files,
      mode: options.mode,
      target: options.target,
      syntaxCheck: options.syntaxCheck,
      timeoutMs: options.timeoutMs,
      stopOnError: false,
      delayMs: 0
    });
  }
  for (const filePath of options.files) {
    const watcher = await startFileWatcher({
      filePath,
      target: options.target,
      mode: options.mode,
      syntaxCheck: options.syntaxCheck,
      timeoutMs: options.timeoutMs,
      debounceMs: options.debounceMs
    });
    watchers.push(publicWatcher(watcher));
  }
  return { ok: true, watchers };
}

async function handleControlCommand(command: string, payload: ControlPayload): Promise<unknown> {
  switch (command) {
    case "status":
      return serverStatus();
    case "clients":
      return activeExecutorClients().map(clientSummary);
    case "events":
      return filterEvents({
        limit: typeof payload.limit === "number" ? payload.limit : undefined,
        type: typeof payload.type === "string" ? payload.type : undefined,
        clientId: typeof payload.clientId === "number" ? payload.clientId : undefined,
        since: typeof payload.since === "string" ? payload.since : undefined,
        until: typeof payload.until === "string" ? payload.until : undefined
      });
      case "send_lua":
        return {
          sent: sendLuaToClients(String(payload.script ?? ""), parseClientTarget(payload.target, "all"))
        };
      case "protocol":
        return {
          sent: sendProtocolToClients(isRecord(payload.payload) ? payload.payload : {}, parseClientTarget(payload.target, "all"))
        };
      case "eval_lua":
        return requestEvalFromClients(
        String(payload.source ?? ""),
        parseClientTarget(payload.target, "first"),
        typeof payload.timeoutMs === "number" ? payload.timeoutMs : 5000,
        typeof payload.label === "string" ? payload.label : "eval"
      );
    case "ping":
      return pingClients(parseClientTarget(payload.target, "all"), typeof payload.timeoutMs === "number" ? payload.timeoutMs : 3000);
    case "context":
      return createContextSnapshot({
        target: payload.target === undefined ? undefined : parseClientTarget(payload.target, "first"),
        eventLimit: typeof payload.eventLimit === "number" ? payload.eventLimit : 25,
        includeScreenshot: payload.includeScreenshot === true,
        includeImage: payload.includeImage === true,
        focusWindow: payload.focusWindow === true,
        timeoutMs: typeof payload.timeoutMs === "number" ? payload.timeoutMs : 5000
      });
    case "disconnect_client":
      return { disconnected: disconnectClient(Number(payload.clientId)), clientId: Number(payload.clientId) };
    default:
      throw new Error(`Unknown RBA control command: ${command}`);
  }
}

async function handleControlRequest(socket: WebSocket, request: Record<string, unknown>): Promise<void> {
  const requestId = String(request.requestId ?? "");
  try {
    const payload = isRecord(request.payload) ? request.payload : {};
    const result = await handleControlCommand(String(request.command ?? ""), payload);
    sendSocketJson(socket, {
      type: "rba_control_response",
      requestId,
      ok: true,
      payload: result
    });
  } catch (error) {
    sendSocketJson(socket, {
      type: "rba_control_response",
      requestId,
      ok: false,
      error: error instanceof Error ? error.message : String(error)
    });
  }
}

function disconnectClient(clientId: number): boolean {
  const client = clients.get(clientId);
  if (!client) {
    return false;
  }
  client.socket.close();
  clients.delete(clientId);
  if (selectedClientId === clientId) {
    selectedClientId = undefined;
  }
  addEvent({ at: now(), type: "client_disconnect_requested", clientId, message: "Client disconnect requested" });
  return true;
}

async function createContextSnapshot(options: {
  target?: ClientTarget;
  eventLimit: number;
  includeScreenshot: boolean;
  includeImage: boolean;
  focusWindow: boolean;
  timeoutMs: number;
}) {
  const target = resolveTarget(options.target, "first");
  const snapshot: Record<string, unknown> = {
    status: serverStatus(),
    clients: activeExecutorClients().map(clientSummary),
    selectedClientId,
    recentEvents: filterEvents({ limit: options.eventLimit })
  };

  try {
    snapshot.runtime = activeExecutorClients().length > 0
      ? await requestEval(runtimeProbeScripts.summary, target, options.timeoutMs, "context_snapshot")
      : { skipped: true, reason: "No connected clients" };
  } catch (error) {
    snapshot.runtime = { ok: false, error: error instanceof Error ? error.message : String(error) };
  }

  let screenshotPath: string | undefined;
  if (options.includeScreenshot) {
      screenshotPath = defaultScreenshotPath("context-roblox");
      try {
        const resolved = assertInsideWorkspace(screenshotPath);
        const screenshotMeta = await captureRobloxOrDesktop(resolved, options.focusWindow);
        snapshot.screenshot = {
          ok: true,
          meta: screenshotMeta
        };
    } catch (error) {
      snapshot.screenshot = { ok: false, error: error instanceof Error ? error.message : String(error) };
      screenshotPath = undefined;
    }
  }

  if (options.includeImage && screenshotPath) {
    const resolved = assertInsideWorkspace(screenshotPath);
    return imageResult(snapshot, resolved, "image/png");
  }
  return jsonText(snapshot);
}

async function sendWatchedFile(record: FileWatcherRecord): Promise<void> {
  try {
    const script = await fs.readFile(record.resolvedPath, "utf8");
    if (record.syntaxCheck) {
      const check = await luaSyntaxCheck({ filePath: record.resolvedPath });
      if (check.ok === false) {
        throw new Error(String(check.error ?? "Lua syntax check failed"));
      }
    }
    const result = record.mode === "eval"
      ? await requestEval(script, record.target, record.timeoutMs, `watch:${record.path}`)
      : { sent: await sendLua(script, record.target) };
    record.sends += 1;
    record.lastSentAt = now();
    addEvent({
      at: now(),
      type: record.mode === "eval" ? "file_watch_eval" : "file_watch_send",
      message: `Watcher ${record.id} ${record.mode === "eval" ? "evaluated" : "sent"} ${record.path}`,
      data: { watcherId: record.id, path: record.path, target: record.target, mode: record.mode, result, bytes: script.length }
    });
  } catch (error) {
    addEvent({
      at: now(),
      type: "file_watch_error",
      message: error instanceof Error ? error.message : String(error),
      data: { watcherId: record.id, path: record.path }
    });
  }
}

async function startFileWatcher(options: { filePath: string; target: ClientTarget; debounceMs: number; mode: "send" | "eval"; syntaxCheck: boolean; timeoutMs: number }): Promise<FileWatcherRecord> {
  const { filePath, target, debounceMs, mode, syntaxCheck, timeoutMs } = options;
  const resolved = assertInsideWorkspace(filePath);
  if (!await pathExists(resolved)) {
    throw new Error(`File does not exist: ${filePath}`);
  }
  const id = randomUUID();
  const record: FileWatcherRecord = {
    id,
      path: path.relative(workspaceRoot, resolved),
      resolvedPath: resolved,
      target,
      mode,
      syntaxCheck,
      timeoutMs,
      debounceMs,
      createdAt: now(),
    sends: 0,
    watcher: watch(resolved, { persistent: false }, () => {
      if (record.timer) {
        clearTimeout(record.timer);
      }
      record.timer = setTimeout(() => {
        record.timer = undefined;
        void sendWatchedFile(record);
      }, record.debounceMs);
    })
  };
  record.watcher.on("error", (error) => {
    addEvent({ at: now(), type: "file_watch_error", message: error.message, data: { watcherId: id, path: record.path } });
  });
  fileWatchers.set(id, record);
  addEvent({ at: now(), type: "file_watch_start", message: `Watching ${record.path}`, data: publicWatcher(record) });
  return record;
}

function stopFileWatcher(id: string): boolean {
  const record = fileWatchers.get(id);
  if (!record) {
    return false;
  }
  if (record.timer) {
    clearTimeout(record.timer);
  }
  record.watcher.close();
  fileWatchers.delete(id);
  addEvent({ at: now(), type: "file_watch_stop", message: `Stopped watcher ${id}`, data: publicWatcher(record) });
  return true;
}

function stopAllWatchers(): Record<string, unknown> {
  const ids = [...fileWatchers.keys()];
  let stopped = 0;
  for (const id of ids) {
    if (stopFileWatcher(id)) {
      stopped += 1;
    }
  }
  return { stopped, ids };
}

function publicWatcher(record: FileWatcherRecord) {
  return {
    id: record.id,
    path: record.path,
    target: record.target,
    mode: record.mode,
    syntaxCheck: record.syntaxCheck,
    timeoutMs: record.timeoutMs,
    debounceMs: record.debounceMs,
    createdAt: record.createdAt,
    sends: record.sends,
    lastSentAt: record.lastSentAt
  };
}

async function loadProfiles(): Promise<Record<string, ScriptProfileAction[]>> {
  const resolved = assertInsideWorkspace(PROFILE_PATH);
  const raw = await fs.readFile(resolved, "utf8");
  const parsed = JSON.parse(raw) as { profiles?: Record<string, ScriptProfileAction[]> };
  if (!parsed.profiles || typeof parsed.profiles !== "object") {
    throw new Error(`${PROFILE_PATH} must contain a profiles object.`);
  }
  return parsed.profiles;
}

async function runScriptProfile(name: string, targetOverride?: ClientTarget): Promise<unknown[]> {
  const profiles = await loadProfiles();
  const actions = profiles[name];
  if (!actions) {
    throw new Error(`Unknown script profile: ${name}`);
  }
  const results: unknown[] = [];
  for (const [index, action] of actions.entries()) {
    const target = resolveTarget(targetOverride ?? action.target, action.type === "eval" ? "first" : "all");
    if (action.type === "preset") {
      if (!action.preset || !(action.preset in luaPresets)) {
        throw new Error(`Profile ${name} action ${index} has an invalid preset.`);
      }
      const sent = await sendLua(luaPresets[action.preset].script, target);
      results.push({ index, type: action.type, preset: action.preset, sent });
      continue;
    }
    if (action.type === "file") {
      if (!action.path) {
        throw new Error(`Profile ${name} action ${index} is missing path.`);
      }
      const resolved = assertInsideWorkspace(action.path);
      const script = await fs.readFile(resolved, "utf8");
      const sent = await sendLua(script, target);
      results.push({ index, type: action.type, path: action.path, sent, bytes: script.length });
      continue;
    }
    if (action.type === "lua") {
      if (!action.script) {
        throw new Error(`Profile ${name} action ${index} is missing script.`);
      }
      const sent = await sendLua(action.script, target);
      results.push({ index, type: action.type, sent, bytes: action.script.length });
      continue;
    }
    if (action.type === "eval") {
      if (!action.script) {
        throw new Error(`Profile ${name} action ${index} is missing script.`);
      }
      results.push({
        index,
        type: action.type,
        label: action.label ?? `${name}:${index}`,
        result: await requestEval(action.script, target, action.timeoutMs ?? 5000, action.label ?? `${name}:${index}`)
      });
      continue;
    }
    throw new Error(`Profile ${name} action ${index} has unsupported type.`);
  }
    addEvent({ at: now(), type: "script_profile_run", message: `Ran profile ${name}`, data: { name, actionCount: actions.length } });
    return results;
  }

async function runAutorunForClient(clientId: number): Promise<void> {
  if (!autorunConfig.enabled) {
    return;
  }
  const target = autorunConfig.target === "all" ? clientId : autorunConfig.target;
  addEvent({ at: now(), type: "autorun_start", clientId, message: `Running autorun for client ${clientId}`, data: autorunConfig });
  try {
    const results: unknown[] = [];
    if (autorunConfig.profile) {
      results.push({ profile: autorunConfig.profile, result: await runScriptProfile(autorunConfig.profile, target) });
    }
    if (autorunConfig.files.length > 0) {
      results.push(await executeBundle({
        files: autorunConfig.files,
        mode: autorunConfig.mode,
        target,
        syntaxCheck: true,
        timeoutMs: autorunConfig.timeoutMs,
        stopOnError: false,
        delayMs: 150
      }));
    }
    addEvent({ at: now(), type: "autorun_complete", clientId, message: `Autorun complete for client ${clientId}`, data: { results } });
  } catch (error) {
    addEvent({ at: now(), type: "autorun_error", clientId, message: error instanceof Error ? error.message : String(error), data: autorunConfig });
  }
}

  async function listScreenshots(limit: number) {
  const screenshotsRoot = assertInsideWorkspace("screenshots");
  if (!await pathExists(screenshotsRoot)) {
    return [];
  }
  const entries = await fs.readdir(screenshotsRoot, { withFileTypes: true });
  const files = await Promise.all(entries
    .filter((entry) => entry.isFile() && [".png", ".jpg", ".jpeg"].includes(path.extname(entry.name).toLowerCase()))
    .map(async (entry) => {
      const fullPath = path.join(screenshotsRoot, entry.name);
      const stats = await fs.stat(fullPath);
      return {
        path: path.relative(workspaceRoot, fullPath),
        bytes: stats.size,
        modifiedAt: stats.mtime.toISOString()
      };
    }));
  return files.sort((a, b) => b.modifiedAt.localeCompare(a.modifiedAt)).slice(0, limit);
}

function dashboardHtml(): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>RBA Dashboard</title>
  <style>
    :root {
      --bg: #0f0f13;
      --bg-raised: #1a1a24;
      --bg-hover: #252535;
      --border: #2e2e42;
      --text: #e2e2f0;
      --text-muted: #8888aa;
      --accent: #7c6ef7;
      --accent-hover: #9d91ff;
      --success: #4ade80;
      --warn: #fbbf24;
      --danger: #f87171;
      --sp-1: 4px; --sp-2: 8px; --sp-3: 12px; --sp-4: 16px;
      --sp-5: 20px; --sp-6: 24px; --sp-8: 32px; --sp-10: 40px;
      --font: -apple-system, 'Segoe UI', sans-serif;
      --font-mono: 'Cascadia Code', 'Fira Code', monospace;
      --text-xs: 11px; --text-sm: 13px; --text-base: 14px; --text-lg: 16px; --text-xl: 18px;
      --r-sm: 4px; --r-md: 8px; --r-lg: 12px; --r-full: 9999px;
      --shadow-sm: 0 1px 3px rgba(0,0,0,.4);
      --shadow-md: 0 4px 16px rgba(0,0,0,.5);
      --t-fast: 120ms ease; --t-base: 200ms ease;
    }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; background: radial-gradient(circle at 8% -10%, rgba(124,110,247,.20), transparent 32rem), radial-gradient(circle at 94% 8%, rgba(74,222,128,.08), transparent 24rem), var(--bg); color: var(--text); font-family: var(--font); font-size: var(--text-base); }
    header { display: flex; align-items: center; justify-content: space-between; gap: var(--sp-4); padding: var(--sp-5) var(--sp-6); border-bottom: 1px solid rgba(124,110,247,.24); background: rgba(26,26,36,.88); backdrop-filter: blur(18px); position: sticky; top: 0; z-index: 5; }
    h1, h2 { margin: 0; font-size: var(--text-xl); }
    h2 { font-size: var(--text-lg); margin-bottom: var(--sp-4); }
    main { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: var(--sp-4); padding: var(--sp-6); }
    .card { background: linear-gradient(145deg, rgba(32,32,47,.96), rgba(22,22,32,.96)); border: 1px solid var(--border); border-radius: var(--r-lg); padding: var(--sp-5); box-shadow: var(--shadow-sm); min-width: 0; transition: transform var(--t-base), border-color var(--t-base), box-shadow var(--t-base); }
    .card:hover { transform: translateY(-2px); border-color: rgba(157,145,255,.52); box-shadow: var(--shadow-md); }
    .wide { grid-column: 1 / -1; }
    .btn { display: inline-flex; align-items: center; gap: var(--sp-2); padding: var(--sp-2) var(--sp-4); background: var(--accent); color: var(--text); border: none; border-radius: var(--r-md); font-size: var(--text-sm); font-weight: 500; cursor: pointer; transition: background var(--t-fast), transform var(--t-fast), opacity var(--t-fast); user-select: none; }
    .btn:hover { background: var(--accent-hover); }
    .btn:active { transform: scale(0.97); }
    .btn:disabled { opacity: 0.45; cursor: not-allowed; pointer-events: none; }
    .btn-ghost { background: transparent; color: var(--text-muted); border: 1px solid var(--border); }
    .btn-ghost:hover { background: var(--bg-hover); color: var(--text); }
    .input { width: 100%; padding: var(--sp-2) var(--sp-3); background: var(--bg); color: var(--text); border: 1px solid var(--border); border-radius: var(--r-md); font-size: var(--text-sm); font-family: var(--font); transition: border-color var(--t-fast); outline: none; }
    .input:focus { border-color: var(--accent); box-shadow: 0 0 0 2px rgba(124,110,247,.2); }
    textarea.input { min-height: 132px; font-family: var(--font-mono); resize: vertical; }
    .row { display: flex; align-items: center; gap: var(--sp-3); flex-wrap: wrap; }
    .stack { display: grid; gap: var(--sp-3); }
    .muted { color: var(--text-muted); font-size: var(--text-sm); }
    .error { color: var(--danger); font-size: var(--text-sm); min-height: var(--sp-5); }
    .pill { display: inline-flex; align-items: center; border: 1px solid var(--border); border-radius: var(--r-full); padding: var(--sp-1) var(--sp-3); color: var(--text-muted); font-size: var(--text-xs); }
    .brand { display: flex; align-items: center; gap: var(--sp-3); }
    .brand-mark { display: grid; place-items: center; width: 34px; height: 34px; border-radius: 11px; background: linear-gradient(135deg, #a69cff, #6255d7); color: #12111a; font-weight: 800; box-shadow: 0 0 24px rgba(124,110,247,.48); }
    .live { display: inline-flex; align-items: center; gap: 7px; }
    .status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--warn); box-shadow: 0 0 0 0 rgba(251,191,36,.55); animation: pulse 1.8s infinite; }
    .status-dot.ok { background: var(--success); box-shadow: 0 0 0 0 rgba(74,222,128,.55); }
    .status-dot.error { background: var(--danger); box-shadow: none; animation: none; }
    .activity { color: var(--text-muted); font-size: var(--text-xs); font-family: var(--font-mono); min-height: 16px; }
    .capsule-list { display: grid; gap: var(--sp-2); max-height: 245px; overflow: auto; }
    .capsule { display: flex; justify-content: space-between; gap: var(--sp-3); padding: var(--sp-3); border: 1px solid var(--border); border-radius: var(--r-md); background: rgba(15,15,19,.62); }
    .capsule strong { display: block; font-size: var(--text-sm); }
    .capsule code { color: var(--accent-hover); font-family: var(--font-mono); font-size: var(--text-xs); }
    .permission { display: inline-flex; align-items: center; gap: 4px; color: var(--text-muted); font-size: var(--text-xs); }
    .toast-region { position: fixed; right: var(--sp-5); bottom: var(--sp-5); z-index: 10; display: grid; gap: var(--sp-2); max-width: min(400px, calc(100vw - 32px)); }
    .toast { padding: var(--sp-3) var(--sp-4); border: 1px solid rgba(157,145,255,.55); border-radius: var(--r-md); background: rgba(25,24,37,.96); box-shadow: var(--shadow-md); animation: toast-in 220ms ease-out; font-size: var(--text-sm); }
    .toast.error { border-color: rgba(248,113,113,.7); }
    @keyframes pulse { 70% { box-shadow: 0 0 0 8px rgba(74,222,128,0); } 100% { box-shadow: 0 0 0 0 rgba(74,222,128,0); } }
    @keyframes toast-in { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: translateY(0); } }
    pre { margin: 0; max-height: 320px; overflow: auto; background: var(--bg); border: 1px solid var(--border); border-radius: var(--r-md); padding: var(--sp-3); color: var(--text); font-family: var(--font-mono); font-size: var(--text-xs); }
    table { width: 100%; border-collapse: collapse; font-size: var(--text-sm); }
    th, td { padding: var(--sp-2); border-bottom: 1px solid var(--border); text-align: left; vertical-align: top; }
    tr:nth-child(even) td { background: var(--bg); }
    ::-webkit-scrollbar { width: 6px; height: 6px; }
    ::-webkit-scrollbar-track { background: transparent; }
    ::-webkit-scrollbar-thumb { background: var(--border); border-radius: var(--r-full); }
    ::-webkit-scrollbar-thumb:hover { background: var(--text-muted); }
    @media (max-width: 800px) { main { grid-template-columns: 1fr; padding: var(--sp-4); } header { align-items: flex-start; flex-direction: column; } }
  </style>
</head>
<body>
  <header>
    <div class="brand"><div class="brand-mark">R</div><div><h1>RBA Script OS</h1><div class="muted live"><span class="status-dot" id="statusDot"></span><span id="statusText">Connecting</span></div></div></div>
    <div class="row"><span class="activity" id="activityText">Initializing command center</span><button class="btn" id="refreshBtn">Refresh</button><button class="btn btn-ghost" id="snapshotBtn">Context</button></div>
  </header>
  <main>
    <section class="card"><h2>Clients</h2><div id="clientsEmpty" class="muted">No clients yet.</div><div id="clients"></div></section>
    <section class="card"><h2>Profiles</h2><div class="row"><select class="input" id="profileSelect"></select><button class="btn" id="runProfileBtn">Run</button></div><div class="error" id="profileError"></div></section>
    <section class="card wide"><h2>Send Lua</h2><div class="stack"><textarea class="input" id="luaInput" placeholder="return game.PlaceId"></textarea><div class="row"><button class="btn" id="sendBtn">Send</button><button class="btn btn-ghost" id="evalBtn">Eval</button></div><div class="error" id="sendError"></div></div></section>
    <section class="card wide"><h2>Script Capsules</h2><div class="stack"><div class="row"><input class="input" id="capsuleId" placeholder="capsule-id"><input class="input" id="capsuleName" placeholder="Capsule name"><input class="input" id="capsulePath" placeholder="lua/example.lua"><button class="btn" id="createCapsuleBtn">Create capsule</button></div><div class="row"><label class="permission"><input type="checkbox" value="http">http</label><label class="permission"><input type="checkbox" value="filesystem">filesystem</label><label class="permission"><input type="checkbox" value="remotes">remotes</label><label class="permission"><input type="checkbox" value="dynamic_code">dynamic code</label><label class="permission"><input type="checkbox" value="transform">transform</label><label class="permission"><input type="checkbox" value="frame_loop">frame loop</label></div><div class="muted">Capsules create source restore points and block static capabilities that were not explicitly approved. They are an RBA policy boundary, not an OS sandbox inside an executor.</div><div class="error" id="capsuleError"></div><div class="capsule-list" id="capsules"><div class="muted">Loading capsules</div></div></div></section>
    <section class="card"><h2>Watchers</h2><div class="row"><input class="input" id="watchPath" placeholder="lua/example.lua"><button class="btn" id="watchBtn">Watch</button></div><div class="error" id="watchError"></div><pre id="watchers">Loading</pre></section>
    <section class="card"><h2>Screenshots</h2><div class="row"><button class="btn" id="captureBtn">Capture Roblox</button></div><div class="error" id="screenshotError"></div><pre id="screenshots">Loading</pre></section>
    <section class="card wide"><h2>Events</h2><pre id="events">Loading</pre></section>
    <section class="card wide"><h2>Context</h2><pre id="context">No snapshot yet.</pre></section>
  </main>
  <div class="toast-region" id="toasts" aria-live="polite"></div>
  <script>
    const $ = (id) => document.getElementById(id);
    let busy = false;
    let refreshing = false;
    function setBusy(value) {
      busy = value;
      document.querySelectorAll('button').forEach((button) => button.disabled = value && button.id !== 'refreshBtn');
    }
    function escapeHtml(value) { const node = document.createElement('span'); node.textContent = String(value || ''); return node.innerHTML; }
    function setActivity(message) { $('activityText').textContent = message; }
    function toast(message, isError = false) { const element = document.createElement('div'); element.className = 'toast' + (isError ? ' error' : ''); element.textContent = message; $('toasts').appendChild(element); setTimeout(() => element.remove(), 4200); }
    async function api(path, options = {}) {
      const response = await fetch(path, {
        ...options,
        headers: { 'content-type': 'application/json', ...(options.headers || {}) }
      });
      const text = await response.text();
      const data = text ? JSON.parse(text) : null;
      if (!response.ok) throw new Error(data && data.error ? data.error : response.statusText);
      return data;
    }
    function showJson(id, value) { $(id).textContent = JSON.stringify(value, null, 2); }
    function renderCapsules(capsules) {
      $('capsules').innerHTML = capsules.length ? capsules.map((capsule) => {
        const permissions = (capsule.permissions || []).length ? capsule.permissions.map(escapeHtml).join(', ') : 'no extra permissions';
        return '<div class="capsule"><div><strong>' + escapeHtml(capsule.name) + '</strong><code>' + escapeHtml(capsule.id) + ' · ' + escapeHtml(capsule.filePath) + '</code><div class="muted">' + permissions + '</div></div><div class="row"><button class="btn btn-ghost capsule-snapshot" data-id="' + escapeHtml(capsule.id) + '">Snapshot</button><button class="btn capsule-run" data-id="' + escapeHtml(capsule.id) + '">Run</button></div></div>';
      }).join('') : '<div class="muted">No capsules yet. Create one to give a script an explicit policy and rollback history.</div>';
    }
    async function refresh(silent = false) {
      if (refreshing || busy) return;
      refreshing = true;
      if (!silent) setActivity('Refreshing live command state');
      try {
        const [status, clients, events, watchers, profiles, screenshots, capsules] = await Promise.all([
          api('/api/status'), api('/api/clients'), api('/api/events?limit=60'), api('/api/watchers'), api('/api/profiles'), api('/api/screenshots'), api('/api/capsules')
        ]);
        const online = Boolean(status.websocket && status.websocket.running);
        $('statusText').textContent = online ? status.websocket.url : 'websocket stopped';
        $('statusDot').className = 'status-dot ' + (online ? 'ok' : 'error');
        $('clientsEmpty').style.display = clients.length ? 'none' : 'block';
        $('clients').innerHTML = clients.map((client) => '<div class="pill">#' + client.id + ' ' + escapeHtml(client.hello && client.hello.name ? client.hello.name : client.address) + (client.selected ? ' selected' : '') + '</div>').join(' ');
        $('profileSelect').innerHTML = Object.keys(profiles).map((name) => '<option value="' + escapeHtml(name) + '">' + escapeHtml(name) + '</option>').join('');
        showJson('events', events);
        showJson('watchers', watchers);
        showJson('screenshots', screenshots);
        renderCapsules(capsules.capsules || []);
        const newestEvent = events[0];
        setActivity(newestEvent ? 'Live · ' + newestEvent.type + ' · ' + new Date(newestEvent.at).toLocaleTimeString() : 'Live · waiting for activity');
      } catch (error) {
        $('statusText').textContent = error.message;
        $('statusDot').className = 'status-dot error';
        if (!silent) toast(error.message, true);
      } finally {
        refreshing = false;
      }
    }
    $('refreshBtn').addEventListener('click', refresh);
    async function action(label, work, errorId) { if (errorId) $(errorId).textContent = ''; setBusy(true); setActivity(label); try { const result = await work(); showJson('context', result); toast(label + ' complete'); await refresh(true); return result; } catch (error) { if (errorId) $(errorId).textContent = error.message; toast(error.message, true); return undefined; } finally { setBusy(false); } }
    $('snapshotBtn').addEventListener('click', () => action('Capturing development context', () => api('/api/context')));
    $('sendBtn').addEventListener('click', () => action('Sending Lua', () => api('/api/send-lua', { method: 'POST', body: JSON.stringify({ script: $('luaInput').value }) }), 'sendError'));
    $('evalBtn').addEventListener('click', () => action('Evaluating Lua', () => api('/api/eval-lua', { method: 'POST', body: JSON.stringify({ script: $('luaInput').value }) }), 'sendError'));
    $('runProfileBtn').addEventListener('click', () => action('Running profile', () => api('/api/run-profile', { method: 'POST', body: JSON.stringify({ name: $('profileSelect').value }) }), 'profileError'));
    $('watchBtn').addEventListener('click', () => action('Starting watcher', () => api('/api/watch', { method: 'POST', body: JSON.stringify({ path: $('watchPath').value }) }), 'watchError'));
    $('captureBtn').addEventListener('click', () => action('Capturing Roblox window', () => api('/api/capture', { method: 'POST', body: JSON.stringify({}) }), 'screenshotError'));
    $('createCapsuleBtn').addEventListener('click', () => action('Creating script capsule', () => api('/api/capsules', { method: 'POST', body: JSON.stringify({ id: $('capsuleId').value, name: $('capsuleName').value, path: $('capsulePath').value, permissions: Array.from(document.querySelectorAll('.permission input:checked')).map((input) => input.value) }) }), 'capsuleError'));
    $('capsules').addEventListener('click', (event) => { const button = event.target.closest('button[data-id]'); if (!button) return; const id = button.dataset.id; if (button.classList.contains('capsule-snapshot')) action('Creating capsule snapshot', () => api('/api/capsule-snapshot', { method: 'POST', body: JSON.stringify({ id, reason: 'dashboard_snapshot' }) }), 'capsuleError'); if (button.classList.contains('capsule-run')) action('Preflighting and running capsule', () => api('/api/capsule-run', { method: 'POST', body: JSON.stringify({ id, mode: 'eval', snapshotBeforeRun: true }) }), 'capsuleError'); });
    refresh();
    setInterval(() => refresh(true), 1200);
  </script>
</body>
</html>`;
}

function sendJson(response: ServerResponse, statusCode: number, value: unknown): void {
  response.writeHead(statusCode, { "content-type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(value));
}

async function readJsonBody(request: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let totalBytes = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    totalBytes += buffer.byteLength;
    if (totalBytes > websocketMaxPayloadBytes()) {
      throw new Error(`Request body exceeds the ${websocketMaxPayloadBytes()} byte safety limit.`);
    }
    chunks.push(buffer);
  }
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  return raw ? JSON.parse(raw) as Record<string, unknown> : {};
}

async function handleDashboardRequest(request: IncomingMessage, response: ServerResponse): Promise<void> {
  try {
    const url = new URL(request.url ?? "/", `http://${dashboardHost}:${dashboardPort}`);
    if (request.method === "GET" && url.pathname === "/") {
      response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      response.end(dashboardHtml());
      return;
    }
    if (request.method === "GET" && url.pathname === "/api/status") return sendJson(response, 200, serverStatus());
      if (request.method === "GET" && url.pathname === "/api/clients") return sendJson(response, 200, activeExecutorClients().map(clientSummary));
    if (request.method === "GET" && url.pathname === "/api/events") {
      return sendJson(response, 200, filterEvents({
        limit: Number.parseInt(url.searchParams.get("limit") ?? "50", 10),
        type: url.searchParams.get("type") ?? undefined,
        clientId: url.searchParams.has("clientId") ? Number.parseInt(url.searchParams.get("clientId") ?? "", 10) : undefined,
        since: url.searchParams.get("since") ?? undefined,
        until: url.searchParams.get("until") ?? undefined
      }));
    }
    if (request.method === "GET" && url.pathname === "/api/watchers") return sendJson(response, 200, [...fileWatchers.values()].map(publicWatcher));
    if (request.method === "GET" && url.pathname === "/api/profiles") return sendJson(response, 200, await loadProfiles());
    if (request.method === "GET" && url.pathname === "/api/screenshots") return sendJson(response, 200, await listScreenshots(20));
    if (request.method === "GET" && url.pathname === "/api/capsules") {
      const registry = await loadCapsuleRegistry();
      return sendJson(response, 200, { capsules: registry.capsules.map(publicCapsule) });
    }
    if (request.method === "GET" && url.pathname === "/api/context") {
      const snapshot = {
        status: serverStatus(),
          clients: activeExecutorClients().map(clientSummary),
        selectedClientId,
        recentEvents: filterEvents({ limit: 25 }),
        watchers: [...fileWatchers.values()].map(publicWatcher),
        capsules: (await loadCapsuleRegistry()).capsules.map(publicCapsule)
      };
      return sendJson(response, 200, snapshot);
    }
    if (request.method === "POST" && url.pathname === "/api/send-lua") {
      const body = await readJsonBody(request);
      const script = String(body.script ?? "");
      if (!script) throw new Error("script is required");
        return sendJson(response, 200, { sent: await sendLua(script, resolveTarget(parseClientTarget(body.target, "all"), "all")) });
    }
    if (request.method === "POST" && url.pathname === "/api/eval-lua") {
      const body = await readJsonBody(request);
      const script = String(body.script ?? "");
      if (!script) throw new Error("script is required");
        return sendJson(response, 200, await requestEval(script, resolveTarget(parseClientTarget(body.target, "first"), "first"), 5000, "dashboard_eval"));
    }
    if (request.method === "POST" && url.pathname === "/api/run-profile") {
      const body = await readJsonBody(request);
      return sendJson(response, 200, await runScriptProfile(String(body.name ?? ""), body.target === undefined ? undefined : parseClientTarget(body.target, "all")));
      }
      if (request.method === "POST" && url.pathname === "/api/watch") {
        const body = await readJsonBody(request);
      const mode = body.mode === "eval" ? "eval" : "send";
      const record = await startFileWatcher({
        filePath: String(body.path ?? ""),
        target: resolveTarget(parseClientTarget(body.target, mode === "eval" ? "first" : "all"), mode === "eval" ? "first" : "all"),
        mode,
        syntaxCheck: body.syntaxCheck !== false,
        timeoutMs: Number(body.timeoutMs ?? 8000),
        debounceMs: Number(body.debounceMs ?? 250)
      });
        return sendJson(response, 200, publicWatcher(record));
      }
    if (request.method === "POST" && url.pathname === "/api/unwatch") {
      const body = await readJsonBody(request);
      return sendJson(response, 200, { stopped: stopFileWatcher(String(body.id ?? "")) });
    }
    if (request.method === "POST" && url.pathname === "/api/capture") {
      const screenshotPath = defaultScreenshotPath("dashboard-roblox");
      const meta = await captureRobloxOrDesktop(assertInsideWorkspace(screenshotPath), true);
      return sendJson(response, 200, meta);
    }
    if (request.method === "POST" && url.pathname === "/api/capsules") {
      const body = await readJsonBody(request);
      return sendJson(response, 200, await createCapsule({
        id: String(body.id ?? ""),
        name: String(body.name ?? ""),
        filePath: String(body.path ?? ""),
        permissions: normalizeCapsulePermissions(body.permissions)
      }));
    }
    if (request.method === "POST" && url.pathname === "/api/capsule-snapshot") {
      const body = await readJsonBody(request);
      return sendJson(response, 200, await snapshotCapsule(String(body.id ?? ""), String(body.reason ?? "dashboard_snapshot")));
    }
    if (request.method === "POST" && url.pathname === "/api/capsule-run") {
      const body = await readJsonBody(request);
      const mode = body.mode === "send" ? "send" : "eval";
      return sendJson(response, 200, await runCapsule({
        id: String(body.id ?? ""),
        mode,
        target: resolveTarget(parseClientTarget(body.target, mode === "eval" ? "first" : "all"), mode === "eval" ? "first" : "all"),
        syntaxCheck: body.syntaxCheck !== false,
        timeoutMs: Number(body.timeoutMs ?? 8000),
        snapshotBeforeRun: body.snapshotBeforeRun !== false
      }));
    }
    sendJson(response, 404, { error: "Not found" });
  } catch (error) {
    sendJson(response, 500, { error: error instanceof Error ? error.message : String(error) });
  }
}

function startDashboard(host: string, port: number): Promise<void> {
  return new Promise((resolve, reject) => {
    if (dashboardServer) {
      resolve();
      return;
    }
    const server = createServer((request, response) => {
      void handleDashboardRequest(request, response);
    });
    let settled = false;
    server.once("listening", () => {
      dashboardServer = server;
      dashboardHost = host;
      dashboardPort = port;
      settled = true;
      addEvent({ at: now(), type: "dashboard_start", message: `Dashboard listening on http://${host}:${port}/` });
      resolve();
    });
    server.once("error", (error) => {
      addEvent({ at: now(), type: "dashboard_error", message: error.message });
      if (!settled) reject(error);
    });
    server.listen(port, host);
  });
}

async function stopDashboard(): Promise<void> {
  if (!dashboardServer) {
    return;
  }
  await new Promise<void>((resolve, reject) => {
    dashboardServer?.close((error) => {
      if (error) reject(error);
      else resolve();
    });
  });
  dashboardServer = undefined;
  addEvent({ at: now(), type: "dashboard_stop", message: "Dashboard stopped" });
}

function attachWebSocketHandlers(server: WebSocketServer): void {
  server.on("connection", (socket, request) => {
    const id = nextClientId++;
    const address = request.socket.remoteAddress ?? "unknown";
    const record: ClientRecord = {
      id,
      address,
      connectedAt: now(),
      role: "pending",
      rateWindowStartedAt: Date.now(),
      messagesInRateWindow: 0,
      socket
    };
    clients.set(id, record);
    addEvent({ at: now(), type: "client_connect", clientId: id, message: `Client connected from ${address}` });

    socket.on("message", (raw) => {
      const receivedAt = Date.now();
      if (receivedAt - record.rateWindowStartedAt >= websocketRateWindowMs()) {
        record.rateWindowStartedAt = receivedAt;
        record.messagesInRateWindow = 0;
      }
      record.messagesInRateWindow++;
      if (record.messagesInRateWindow > websocketRateLimit()) {
        socketMessagesDropped++;
        addEvent({
          at: now(),
          type: "client_rate_limited",
          clientId: id,
          message: `Client exceeded ${websocketRateLimit()} messages in ${websocketRateWindowMs()} ms`
        });
        socket.close(1008, "RBA message rate limit exceeded");
        return;
      }

      const text = raw.toString("utf8");
      socketMessagesReceived++;
      socketBytesReceived += Buffer.byteLength(text);
      record.lastMessageAt = now();
      let data: unknown = text;
      try {
        data = JSON.parse(text);
      } catch {
        // Plain text messages are still useful for executor/client logs.
      }

      if (isRecord(data) && data.type === "hello") {
        const firstHello = record.role !== "executor";
        record.role = "executor";
        record.hello = compactEventData(data);
        if (firstHello) {
          void runAutorunForClient(id);
        }
      }

      if (isRecord(data) && data.type === "client_heartbeat") {
        record.lastHeartbeatAt = now();
      }

      if (isRecord(data) && data.type === "rba_control_hello") {
        record.role = "control";
        record.hello = compactEventData(data);
        addEvent({
          at: now(),
          type: "control_connect",
          clientId: id,
          message: `Control connection attached from ${address}`,
          data
        });
        sendSocketJson(socket, {
          type: "rba_control_ready",
          pid: process.pid,
          workspaceRoot,
          status: serverStatus()
        });
        return;
      }

      if (record.role === "control" && isRecord(data) && data.type === "rba_control_request") {
        void handleControlRequest(socket, data);
        return;
      }

      if (isRecord(data) && "requestId" in data) {
        const requestId = String((data as { requestId?: unknown }).requestId);
        const pending = pendingResponses.get(requestId);
        if (pending && (pending.clientId === undefined || pending.clientId === id)) {
          clearTimeout(pending.timeout);
          pendingResponses.delete(requestId);
          pending.resolve({
            clientId: id,
            receivedAt: now(),
            data
          });
        }
      }

      addEvent({
        at: now(),
        type: isRecord(data) && "type" in data ? String(data.type) : "client_message",
        clientId: id,
        message: text.length > 500 ? `${text.slice(0, 500)}...` : text,
        data
      });
    });

    socket.on("close", () => {
      clients.delete(id);
      if (selectedClientId === id) {
        selectedClientId = undefined;
      }
      for (const [requestId, pending] of pendingResponses) {
        if (pending.clientId === id) {
          rejectPendingResponse(requestId, new Error(`RBA client ${id} disconnected before responding.`));
        }
      }
      addEvent({ at: now(), type: "client_close", clientId: id, message: "Client disconnected" });
    });

    socket.on("error", (error) => {
      addEvent({ at: now(), type: "client_error", clientId: id, message: error.message });
    });
  });
}

function listenWebSocketServer(host: string, port: number): Promise<WebSocketServer> {
  return new Promise((resolve, reject) => {
    const server = new WebSocketServer({
      host,
      port,
      maxPayload: websocketMaxPayloadBytes(),
      perMessageDeflate: false
    });
    let settled = false;

    server.once("listening", () => {
      settled = true;
      resolve(server);
    });

    server.once("error", (error) => {
      if (!settled) {
        server.close();
        reject(error);
      }
    });
  });
}

async function startWebSocketServer(host: string, port: number): Promise<void> {
  if (webSocketServer) {
    await publishConnectionState("server");
    return;
  }

  host = normalizeHost(host);
  const candidates = port === 0 ? [0] : parsePortCandidates(DEFAULT_PORT_CANDIDATES.join(","), port);
  let lastError: unknown;

  for (const candidate of candidates) {
    try {
      const server = await listenWebSocketServer(host, candidate);
      const address = server.address();
      const actualPort = typeof address === "object" && address ? address.port : candidate;
        webSocketServer = server;
        wsHost = host;
        wsPort = actualPort;
        attachWebSocketHandlers(server);
        addEvent({ at: now(), type: "server_start", message: `Listening on ws://${host}:${actualPort}/` });
        await publishConnectionState("server");
        return;
        } catch (error) {
        lastError = error;
        const message = error instanceof Error ? error.message : String(error);
        addEvent({ at: now(), type: "server_error", message });
        if (!isAddressInUse(error)) {
          throw error;
        }
        if (await connectControlUrl(`ws://${host}:${candidate}/`)) {
          wsHost = host;
          wsPort = candidate;
          await publishConnectionState("proxy");
          return;
        }
      }
    }

  throw lastError instanceof Error ? lastError : new Error(String(lastError ?? "No websocket port available"));
}

async function stopWebSocketServer(): Promise<void> {
  if (!webSocketServer) {
    return;
  }
  for (const client of clients.values()) {
    client.socket.close();
  }
  clients.clear();
  selectedClientId = undefined;
  await new Promise<void>((resolve, reject) => {
    webSocketServer?.close((error) => {
      if (error) {
        reject(error);
        return;
      }
      resolve();
    });
  });
  webSocketServer = undefined;
  addEvent({ at: now(), type: "server_stop", message: "Websocket server stopped" });
}

function serverStatus() {
  const connection = currentConnectionState(webSocketServer ? "server" : bridgeControlSocket?.readyState === WebSocket.OPEN ? "proxy" : "server");
  return {
        name: "RBA",
        workspaceRoot,
        connection,
        selectedClientId,
        eventLimit: eventLimit(),
        performance: {
          uptimeSeconds: Math.floor((Date.now() - processStartedAt) / 1000),
          eventLogFlushMs: eventLogFlushDelay(),
          pendingLogLines: pendingEventLogLines.length,
          eventLogLinesDropped,
          logMaxFileBytes: logMaxFileBytes(),
          logRotations: logRotations(),
          fileIoConcurrency: fileIoConcurrency(),
          searchMaxFileBytes: searchMaxFileBytes(),
          socket: {
            messagesReceived: socketMessagesReceived,
            bytesReceived: socketBytesReceived,
            messagesSent: socketMessagesSent,
            bytesSent: socketBytesSent,
            messagesDropped: socketMessagesDropped,
            maxPayloadBytes: websocketMaxPayloadBytes(),
            maxBufferedBytes: websocketMaxBufferedBytes(),
            rateLimit: websocketRateLimit(),
            rateWindowMs: websocketRateWindowMs()
          }
        },
        control: {
          proxying: !webSocketServer && bridgeControlSocket?.readyState === WebSocket.OPEN,
          url: bridgeControlUrl
        },
        websocket: {
          running: Boolean(webSocketServer),
          host: wsHost,
          port: wsPort,
          url: webSocketServer || bridgeControlSocket?.readyState === WebSocket.OPEN ? connection.url : undefined,
          portCandidates: connection.portCandidates,
          clients: [...clients.values()].map(clientSummary)
        },
    dashboard: {
      running: Boolean(dashboardServer),
      url: dashboardServer ? `http://${dashboardHost}:${dashboardPort}/` : undefined
      },
      watchers: [...fileWatchers.values()].map(publicWatcher),
      autorun: autorunConfig,
      recentEvents: events.slice(-10)
    };
  }

async function bridgeStatus(): Promise<unknown> {
  if (!webSocketServer && await ensureBridgeControl()) {
    return {
      proxy: true,
      controlUrl: bridgeControlUrl,
      upstream: await controlRequest("status", {}, 3000)
    };
  }
  return serverStatus();
}

async function bridgeClients(): Promise<unknown> {
  if (!webSocketServer && await ensureBridgeControl()) {
    return await controlRequest("clients", {}, 3000);
  }
  return activeExecutorClients().map(clientSummary);
}

async function bridgeEvents(options: { limit?: number; type?: string; clientId?: number; since?: string; until?: string }): Promise<unknown> {
  if (!webSocketServer && await ensureBridgeControl()) {
    return await controlRequest("events", options as ControlPayload, 5000);
  }
  return filterEvents(options);
}

const batchOperationSchema = z.object({
  action: z.enum(["write", "append", "mkdir"]),
  path: z.string().min(1),
  content: z.string().optional(),
  overwrite: z.boolean().default(false),
  backupExisting: z.boolean().default(true)
});

const clientTargetSchema = z.union([z.literal("all"), z.literal("first"), z.number().int().positive()]);
const presetNameSchema = z.enum(Object.keys(luaPresets) as [keyof typeof luaPresets, ...(keyof typeof luaPresets)[]]);

const server = new McpServer({
  name: "Roblox Bridge Agent",
  version: "1.0.0"
});

server.tool(
  "rba_ws_start",
  "Start the local RBA websocket bridge used by the Lua autoloader.",
  {
    host: z.string().default(DEFAULT_HOST).describe("Bind host. Keep 127.0.0.1 for local-only development."),
    port: z.number().int().min(1).max(65535).default(DEFAULT_PORT)
  },
  async ({ host, port }) => {
    await startWebSocketServer(host, port);
    return jsonText(serverStatus());
  }
);

server.tool(
  "rba_ws_stop",
  "Stop the local RBA websocket bridge.",
  {},
  async () => {
    await stopWebSocketServer();
    return jsonText(serverStatus());
  }
);

server.tool(
  "rba_ws_status",
  "Show websocket bridge status, connected clients, and recent client events.",
  {},
    async () => jsonText(await bridgeStatus())
);

server.tool(
  "rba_connection_info",
  "Return the active RBA websocket host, port, URL, candidate URLs, and published connection-state checks.",
  {},
  async () => jsonText({
    live: currentConnectionState(webSocketServer ? "server" : bridgeControlSocket?.readyState === WebSocket.OPEN ? "proxy" : "server"),
    published: await readPublishedConnectionState(),
    controlUrl: bridgeControlUrl
  })
);

server.tool(
  "rba_events",
  "Read recent websocket/client events captured by RBA.",
  {
    limit: z.number().int().min(1).max(EVENT_LIMIT).default(50),
    type: z.string().optional().describe("Optional event type filter."),
    clientId: z.number().int().positive().optional().describe("Optional client id filter."),
    since: z.string().optional().describe("Optional ISO timestamp lower bound."),
    until: z.string().optional().describe("Optional ISO timestamp upper bound.")
  },
    async ({ limit, type, clientId, since, until }) => jsonText(await bridgeEvents({ limit, type, clientId, since, until }))
);

server.tool(
  "rba_clear_events",
  "Clear buffered RBA events, optionally only those matching type/client filters.",
  {
    type: z.string().optional(),
    clientId: z.number().int().positive().optional()
  },
  async ({ type, clientId }) => {
    const before = events.length;
    for (let index = events.length - 1; index >= 0; index--) {
      const event = events[index];
      if (type && event.type !== type) {
        continue;
      }
      if (clientId !== undefined && event.clientId !== clientId) {
        continue;
      }
      events.splice(index, 1);
    }
    return jsonText({ removed: before - events.length, remaining: events.length });
  }
);

server.tool(
  "rba_clients",
  "List connected RBA websocket clients.",
  {},
  async () => jsonText(await bridgeClients())
);

server.tool(
  "rba_health_check",
  "Diagnose the shared RBA bridge, Instance Manager endpoint, connected clients, autoexec targets, recent errors, and optional eval/ping health.",
  {
    includePing: z.boolean().default(true),
    timeoutMs: z.number().int().min(100).max(15000).default(3000)
  },
  async ({ includePing, timeoutMs }) => jsonText(await healthCheck({ includePing, timeoutMs }))
);

server.tool(
  "rba_detect_roblox_crash",
  "Read-only Roblox process and RBA heartbeat diagnosis. Reports healthy, bridge_disconnected, not_running, or likely_crashed without changing any process.",
  {
    includePing: z.boolean().default(true).describe("Ping a connected executor as an additional responsiveness signal."),
    timeoutMs: z.number().int().min(100).max(15000).default(3000),
    staleAfterMs: z.number().int().min(1000).max(300000).default(20000).describe("Heartbeat age at which a connected executor is considered stale."),
    target: clientTargetSchema.optional()
  },
  async ({ includePing, timeoutMs, staleAfterMs, target }) => jsonText(await robloxCrashStatus({
    includePing,
    timeoutMs,
    staleAfterMs,
    target: resolveTarget(target, "all")
  }))
);

server.tool(
  "rba_restart_roblox",
  "Safely restart RobloxPlayerBeta.exe: discover and verify the current/installed executable path, close only RobloxPlayerBeta processes, then launch the verified executable normally.",
  {
    closeAll: z.boolean().default(true).describe("Close every currently running RobloxPlayerBeta.exe process before launch."),
    restartDelayMs: z.number().int().min(0).max(15000).default(1000),
    waitForProcessMs: z.number().int().min(1000).max(60000).default(20000)
  },
  async ({ closeAll, restartDelayMs, waitForProcessMs }) => jsonText(await restartRobloxPlayer({ closeAll, restartDelayMs, waitForProcessMs }))
);

server.tool(
  "rba_development_snapshot",
  "One development-oriented snapshot: RBA health, Roblox crash likelihood, autoexec state, and optional static script preflight. Does not execute the inspected script.",
  {
    includePing: z.boolean().default(true),
    timeoutMs: z.number().int().min(100).max(15000).default(3000),
    staleAfterMs: z.number().int().min(1000).max(300000).default(20000),
    scriptPath: z.string().optional().describe("Optional workspace-relative Lua file to inspect statically."),
    target: clientTargetSchema.optional()
  },
  async ({ includePing, timeoutMs, staleAfterMs, scriptPath, target }) => jsonText({
    checkedAt: now(),
    health: await healthCheck({ includePing, timeoutMs }),
    roblox: await robloxCrashStatus({ includePing, timeoutMs, staleAfterMs, target: resolveTarget(target, "all") }),
    script: scriptPath ? await scriptPreflight({ filePath: scriptPath }) : undefined
  })
);

server.tool(
  "rba_unified_status",
  "Verify the complete local workflow: RBA websocket service, Instance Manager connector endpoint, and every executor autoexec copy.",
  {
    timeoutMs: z.number().int().min(100).max(15000).default(3000)
  },
  async ({ timeoutMs }) => {
    const autoexecTargets = await Promise.all(autoexecTargetPaths.map(autoexecTargetStatus));
    const instanceManager = await instanceManagerStatus(timeoutMs);
    const rba = await bridgeStatus();
    const rbaWebsocket = isRecord(rba) && isRecord(rba.websocket) ? rba.websocket : undefined;
    const rbaReady = isRecord(rba) && (rba.proxy === true || rbaWebsocket?.running === true);
    return jsonText({
      ok: instanceManager.ok === true
        && autoexecTargets.length > 0
        && autoexecTargets.every((target) => target.exists === true && target.matchesSource === true)
        && rbaReady,
      rba,
      instanceManager,
      autoexecTargets,
      checkedAt: now()
    });
  }
);

server.tool(
  "rba_agent_bootstrap",
  "Prepare RBA for an agent session: start or attach the bridge, sync autoexec, optionally start dashboard, notify clients, and return health.",
  {
    startDashboard: z.boolean().default(false),
    dashboardPort: z.number().int().min(1).max(65535).default(DEFAULT_DASHBOARD_PORT),
    notify: z.boolean().default(true),
    includePing: z.boolean().default(true),
    timeoutMs: z.number().int().min(100).max(15000).default(3000)
  },
  async ({ startDashboard: shouldStartDashboard, dashboardPort, notify, includePing, timeoutMs }) => {
    await startWebSocketServer(DEFAULT_HOST, DEFAULT_PORT);
    const autoexec = await syncAutoloaderToAutoexec("agent_bootstrap");
    if (shouldStartDashboard) {
      await startDashboard("127.0.0.1", dashboardPort);
    }
    if (notify && activeExecutorClients().length > 0) {
      await notifyClients({
        title: "RBA",
        message: "Agent bridge ready",
        level: "success",
        durationMs: 3000,
        target: "all"
      });
    }
    return jsonText({
      autoexec,
      status: serverStatus(),
      health: await healthCheck({ includePing, timeoutMs })
    });
  }
);

server.tool(
  "rba_notify_clients",
  "Show an in-game RBA notification on connected Roblox clients.",
  {
    title: z.string().default("RBA"),
    message: z.string().min(1),
    level: z.enum(["info", "success", "warn", "error"]).default("info"),
    durationMs: z.number().int().min(1000).max(30000).default(4000),
    target: clientTargetSchema.optional()
  },
  async ({ title, message, level, durationMs, target }) => jsonText(await notifyClients({
    title,
    message,
    level,
    durationMs,
    target: resolveTarget(target, "all")
  }))
);

server.tool(
  "rba_set_client_status",
  "Update the in-game RBA status panel on connected Roblox clients.",
  {
    message: z.string().min(1),
    level: z.enum(["info", "success", "warn", "error"]).default("info"),
    target: clientTargetSchema.optional()
  },
  async ({ message, level, target }) => jsonText(await setClientStatus({
    message,
    level,
    target: resolveTarget(target, "all")
  }))
);

server.tool(
  "rba_client_info",
  "Show full details for one connected RBA websocket client.",
  {
    clientId: z.number().int().positive()
  },
  async ({ clientId }) => {
    const client = clients.get(clientId);
    if (!client) {
      throw new Error(`Unknown client id: ${clientId}`);
    }
    return jsonText(clientSummary(client));
  }
);

server.tool(
  "rba_select_client",
  "Set the default client used when a tool target is omitted.",
  {
    clientId: z.number().int().positive()
  },
  async ({ clientId }) => {
    if (!clients.has(clientId)) {
      throw new Error(`Unknown client id: ${clientId}`);
    }
    selectedClientId = clientId;
    addEvent({ at: now(), type: "client_selected", clientId, message: `Selected client ${clientId}` });
    return jsonText({ selectedClientId });
  }
);

server.tool(
  "rba_disconnect_client",
  "Close one connected RBA websocket client.",
  {
    clientId: z.number().int().positive()
  },
  async ({ clientId }) => jsonText({ disconnected: disconnectClient(clientId), clientId })
);

server.tool(
  "rba_send_lua",
  "Send Lua source text to connected development clients through the websocket bridge.",
  {
    script: z.string().min(1),
    target: clientTargetSchema.optional()
  },
  async ({ script, target }) => {
      const sent = await sendLua(script, resolveTarget(target, "all"));
    return okText(`Sent Lua to ${sent} client(s).`);
  }
);

server.tool(
  "rba_send_lua_file",
  "Send a Lua file from the RBA workspace to connected development clients.",
  {
    path: z.string().min(1),
    target: clientTargetSchema.optional()
  },
  async ({ path: filePath, target }) => {
    const resolved = assertInsideWorkspace(filePath);
    const script = await fs.readFile(resolved, "utf8");
      const sent = await sendLua(script, resolveTarget(target, "all"));
    return okText(`Sent ${filePath} (${script.length} bytes) to ${sent} client(s).`);
  }
);

server.tool(
  "rba_eval_lua",
  "Run Lua and wait for structured return values or errors from connected clients.",
  {
    script: z.string().min(1),
    target: clientTargetSchema.optional(),
    timeoutMs: z.number().int().min(100).max(30000).default(5000),
    label: z.string().default("eval")
  },
  async ({ script, target, timeoutMs, label }) => jsonText(await requestEval(script, resolveTarget(target, "first"), timeoutMs, label))
);

server.tool(
  "rba_eval_lua_file",
  "Run a workspace Lua file and wait for structured return values or errors from connected clients.",
  {
    path: z.string().min(1),
    target: clientTargetSchema.optional(),
    timeoutMs: z.number().int().min(100).max(30000).default(5000),
    label: z.string().optional()
  },
  async ({ path: filePath, target, timeoutMs, label }) => {
    const resolved = assertInsideWorkspace(filePath);
    const script = await fs.readFile(resolved, "utf8");
    return jsonText(await requestEval(script, resolveTarget(target, "first"), timeoutMs, label ?? `eval_file:${filePath}`));
  }
);

server.tool(
  "rba_execute_file",
  "Execute a workspace Lua file in Roblox, either fire-and-forget send or eval with structured results.",
  {
    path: z.string().min(1),
    mode: z.enum(["send", "eval"]).default("eval"),
    target: clientTargetSchema.optional(),
    syntaxCheck: z.boolean().default(true),
    timeoutMs: z.number().int().min(100).max(30000).default(8000),
    label: z.string().optional()
  },
  async ({ path: filePath, mode, target, syntaxCheck, timeoutMs, label }) => {
    return jsonText(await executeLuaFile({
      filePath,
      mode,
      target: resolveTarget(target, mode === "eval" ? "first" : "all"),
      syntaxCheck,
      timeoutMs,
      label
    }));
  }
);

server.tool(
  "rba_execute_bundle",
  "Execute multiple workspace Lua files in order with syntax checks, optional delay, and stop-on-error control.",
  {
    files: z.array(z.string().min(1)).min(1).max(50),
    mode: z.enum(["send", "eval"]).default("send"),
    target: clientTargetSchema.optional(),
    syntaxCheck: z.boolean().default(true),
    timeoutMs: z.number().int().min(100).max(30000).default(8000),
    stopOnError: z.boolean().default(true),
    delayMs: z.number().int().min(0).max(5000).default(100)
  },
  async ({ files, mode, target, syntaxCheck, timeoutMs, stopOnError, delayMs }) => jsonText(await executeBundle({
    files,
    mode,
    target: resolveTarget(target, mode === "eval" ? "first" : "all"),
    syntaxCheck,
    timeoutMs,
    stopOnError,
    delayMs
  }))
);

server.tool(
  "rba_lua_syntax_check",
  "Run local Lua syntax validation with luac for a workspace file or provided source before sending to Roblox.",
  {
    path: z.string().optional(),
    source: z.string().optional()
  },
  async ({ path: filePath, source }) => {
    if (!filePath && source === undefined) {
      throw new Error("Provide either path or source.");
    }
    return jsonText(await luaSyntaxCheck({ filePath, source }));
  }
);

server.tool(
  "rba_ping_clients",
  "Ping connected clients and return round-trip timing plus basic place/job details.",
  {
    target: clientTargetSchema.optional(),
    timeoutMs: z.number().int().min(100).max(15000).default(3000)
  },
  async ({ target, timeoutMs }) => jsonText(await pingClients(resolveTarget(target, "all"), timeoutMs))
);

server.tool(
  "rba_install_debug_runtime",
  "Install debug helpers on connected clients and return an initial runtime snapshot.",
  {
    target: clientTargetSchema.optional(),
    timeoutMs: z.number().int().min(100).max(30000).default(8000)
  },
    async ({ target, timeoutMs }) => jsonText(await requestEval(DEBUG_RUNTIME_LUA, resolveTarget(target, "all"), timeoutMs, "install_debug_runtime"))
);

server.tool(
  "rba_probe_runtime",
  "Run a built-in realtime probe such as summary, character, camera, players, environment, or datamodel.",
  {
    probe: z.enum(["summary", "character", "camera", "players", "environment", "datamodel"]),
    target: clientTargetSchema.optional(),
    timeoutMs: z.number().int().min(100).max(30000).default(5000)
  },
  async ({ probe, target, timeoutMs }) => {
    const script = probe === "summary" ? DEBUG_RUNTIME_LUA : runtimeProbeScripts[probe];
      return jsonText(await requestEval(script, resolveTarget(target, "first"), timeoutMs, `probe:${probe}`));
  }
);

server.tool(
  "rba_install_console_mirror",
  "Mirror client print/warn output back to RBA events with a Roblox-safe rate limit.",
  {
    target: clientTargetSchema.optional(),
    maxPerSecond: z.number().int().min(1).max(120).default(DEFAULT_CONSOLE_RATE_LIMIT),
    timeoutMs: z.number().int().min(100).max(30000).default(5000)
  },
  async ({ target, maxPerSecond, timeoutMs }) => {
      return jsonText(await requestEval(buildConsoleMirrorLua(maxPerSecond), resolveTarget(target, "all"), timeoutMs, "install_console_mirror"));
  }
);

server.tool(
  "rba_script_preflight",
  "Statically inspect a workspace Lua file or provided source before execution: syntax, metrics, lifecycle/loop checks, dynamic loading, remote calls, and direct transform writes. Never executes the script.",
  {
    path: z.string().optional(),
    source: z.string().optional()
  },
  async ({ path: filePath, source }) => jsonText(await scriptPreflight({ filePath, source }))
);

server.tool(
  "rba_create_script_capsule",
  "Create a named RBA script capsule: a permission-gated policy envelope around one workspace Lua file. Capsules preflight and snapshot source before dispatch; they do not claim to OS-sandbox code inside a Roblox executor.",
  {
    id: z.string().min(1).max(64).describe("Stable lowercase capsule id, such as camera-tools."),
    name: z.string().min(1).max(120).describe("Human-readable capsule name."),
    path: z.string().min(1).describe("Workspace-relative Lua file managed by this capsule."),
    permissions: z.array(z.enum(capsulePermissions)).default([]).describe("Capabilities intentionally granted to this script.")
  },
  async ({ id, name, path: filePath, permissions }) => jsonText(await createCapsule({ id, name, filePath, permissions }))
);

server.tool(
  "rba_list_script_capsules",
  "List registered script capsules and their explicit permissions, source file, timestamps, and policy-sandbox limitation.",
  {},
  async () => {
    const registry = await loadCapsuleRegistry();
    return jsonText({
      registryPath: path.relative(workspaceRoot, capsuleRegistryPath()),
      capsules: registry.capsules.map(publicCapsule),
      sandboxModel: "Capsules are an RBA policy and lifecycle boundary. Roblox executors cannot provide an OS-grade sandbox for arbitrary dispatched Lua."
    });
  }
);

server.tool(
  "rba_set_script_capsule_permissions",
  "Replace a script capsule's explicit capability grants. The next capsule run is blocked when static source requirements are not granted.",
  {
    id: z.string().min(1).max(64),
    permissions: z.array(z.enum(capsulePermissions))
  },
  async ({ id, permissions }) => jsonText(await setCapsulePermissions(id, permissions))
);

server.tool(
  "rba_capsule_snapshot",
  "Create a source snapshot for one script capsule. Use it as a time-travel restore point before an edit or experiment.",
  {
    id: z.string().min(1).max(64),
    reason: z.string().min(1).max(200).default("manual_snapshot")
  },
  async ({ id, reason }) => jsonText(await snapshotCapsule(id, reason))
);

server.tool(
  "rba_list_capsule_snapshots",
  "List time-travel source snapshots for one RBA script capsule.",
  {
    id: z.string().min(1).max(64)
  },
  async ({ id }) => jsonText(await listCapsuleSnapshots(id))
);

server.tool(
  "rba_rollback_script_capsule",
  "Restore a capsule source file from a selected snapshot. RBA captures the current source first as a safety snapshot.",
  {
    id: z.string().min(1).max(64),
    snapshotId: z.string().min(1).max(100)
  },
  async ({ id, snapshotId }) => jsonText(await rollbackCapsule(id, snapshotId))
);

server.tool(
  "rba_run_script_capsule",
  "Preflight, permission-check, optionally snapshot, and then dispatch a script capsule. Missing required permissions block the run before any Lua reaches a client.",
  {
    id: z.string().min(1).max(64),
    mode: z.enum(["send", "eval"]).default("eval"),
    target: clientTargetSchema.optional(),
    syntaxCheck: z.boolean().default(true),
    timeoutMs: z.number().int().min(100).max(30000).default(8000),
    snapshotBeforeRun: z.boolean().default(true)
  },
  async ({ id, mode, target, syntaxCheck, timeoutMs, snapshotBeforeRun }) => jsonText(await runCapsule({
    id,
    mode,
    target: resolveTarget(target, mode === "eval" ? "first" : "all"),
    syntaxCheck,
    timeoutMs,
    snapshotBeforeRun
  }))
);

server.tool(
  "rba_git_status",
  "Inspect the RBA workspace Git repository, selected branch/origin, changed and staged files, and the exact autoloader fingerprint without changing Git state.",
  {},
  async () => jsonText(await gitRepositoryStatus())
);

server.tool(
  "rba_git_sync_files",
  "Explicitly commit selected existing RBA workspace files and optionally push the current branch. It refuses to run with a pre-staged index and never uses git add --all, so unrelated scripts are not swept into a sync.",
  {
    files: z.array(z.string().min(1)).min(1).max(100),
    message: z.string().min(1).max(200),
    push: z.boolean().default(false),
    remote: z.string().min(1).default("origin"),
    branch: z.string().min(1).optional().describe("Optional branch to push; defaults to the checked-out branch.")
  },
  async ({ files, message, push, remote, branch }) => jsonText(await syncWorkspaceFilesToGit({ files, message, push, remote, branch }))
);

server.tool(
  "rba_uninstall_console_mirror",
  "Restore print/warn after rba_install_console_mirror.",
  {
    target: clientTargetSchema.optional(),
    timeoutMs: z.number().int().min(100).max(30000).default(5000)
  },
    async ({ target, timeoutMs }) => jsonText(await requestEval(CONSOLE_MIRROR_UNINSTALL_LUA, resolveTarget(target, "all"), timeoutMs, "uninstall_console_mirror"))
);

server.tool(
  "rba_wait_for_event",
  "Wait briefly for the next websocket event, optionally filtered by type and client id.",
  {
    type: z.string().optional(),
    clientId: z.number().int().positive().optional(),
    timeoutMs: z.number().int().min(100).max(60000).default(10000)
  },
  async ({ type, clientId, timeoutMs }) => jsonText(await waitForEvent(type, clientId, timeoutMs))
);

server.tool(
  "rba_context_snapshot",
  "Capture status, clients, recent events, runtime summary, and optional Roblox screenshot in one call.",
  {
    target: clientTargetSchema.optional(),
    eventLimit: z.number().int().min(1).max(EVENT_LIMIT).default(25),
    includeScreenshot: z.boolean().default(false),
    includeImage: z.boolean().default(false),
    focusWindow: z.boolean().default(false),
    timeoutMs: z.number().int().min(100).max(30000).default(5000)
  },
  async ({ target, eventLimit, includeScreenshot, includeImage, focusWindow, timeoutMs }) => createContextSnapshot({
    target,
    eventLimit,
    includeScreenshot,
    includeImage,
    focusWindow,
    timeoutMs
  })
);

server.tool(
  "rba_watch_file",
  "Watch a workspace Lua file and auto-send or eval it in Roblox on change for live editing.",
  {
    path: z.string().min(1),
    target: clientTargetSchema.optional(),
    mode: z.enum(["send", "eval"]).default("send"),
    syntaxCheck: z.boolean().default(true),
    timeoutMs: z.number().int().min(100).max(30000).default(8000),
    debounceMs: z.number().int().min(50).max(5000).default(250)
  },
  async ({ path: filePath, target, mode, syntaxCheck, timeoutMs, debounceMs }) => jsonText(publicWatcher(await startFileWatcher({
    filePath,
    target: resolveTarget(target, mode === "eval" ? "first" : "all"),
    mode,
    syntaxCheck,
    timeoutMs,
    debounceMs
  })))
);

server.tool(
  "rba_start_live_session",
  "Watch multiple workspace Lua files as one live-editing session and optionally run them once immediately.",
  {
    files: z.array(z.string().min(1)).min(1).max(50),
    mode: z.enum(["send", "eval"]).default("send"),
    target: clientTargetSchema.optional(),
    syntaxCheck: z.boolean().default(true),
    timeoutMs: z.number().int().min(100).max(30000).default(8000),
    debounceMs: z.number().int().min(50).max(5000).default(250),
    runOnce: z.boolean().default(false)
  },
  async ({ files, mode, target, syntaxCheck, timeoutMs, debounceMs, runOnce }) => jsonText(await startLiveSession({
    files,
    mode,
    target: resolveTarget(target, mode === "eval" ? "first" : "all"),
    syntaxCheck,
    timeoutMs,
    debounceMs,
    runOnce
  }))
);

server.tool(
  "rba_unwatch_file",
  "Stop one active RBA file watcher.",
  {
    id: z.string().min(1)
  },
  async ({ id }) => jsonText({ stopped: stopFileWatcher(id), id })
);

server.tool(
  "rba_stop_all_watchers",
  "Stop every active RBA live-edit file watcher.",
  {},
  async () => jsonText(stopAllWatchers())
);

server.tool(
  "rba_list_watchers",
  "List active RBA file watchers.",
  {},
  async () => jsonText([...fileWatchers.values()].map(publicWatcher))
);

server.tool(
  "rba_list_script_profiles",
  "List script profiles from the workspace profile JSON file.",
  {},
  async () => jsonText(await loadProfiles())
);

server.tool(
  "rba_run_script_profile",
  "Run a named script profile from the workspace profile JSON file.",
  {
    name: z.string().min(1),
    target: clientTargetSchema.optional()
  },
  async ({ name, target }) => jsonText(await runScriptProfile(name, target))
);

server.tool(
  "rba_set_autorun",
  "Configure optional profile/file execution that runs automatically when a Roblox client connects.",
  {
    enabled: z.boolean().default(false),
    profile: z.string().optional(),
    files: z.array(z.string().min(1)).max(25).default([]),
    mode: z.enum(["send", "eval"]).default("send"),
    target: clientTargetSchema.optional(),
    timeoutMs: z.number().int().min(100).max(30000).default(8000)
  },
  async ({ enabled, profile, files, mode, target, timeoutMs }) => {
    autorunConfig = {
      enabled,
      profile: profile && profile.trim() ? profile.trim() : undefined,
      files,
      mode,
      target: resolveTarget(target, "all"),
      timeoutMs
    };
    addEvent({ at: now(), type: "autorun_config", message: enabled ? "Autorun enabled" : "Autorun disabled", data: autorunConfig });
    return jsonText(autorunConfig);
  }
);

server.tool(
  "rba_get_autorun",
  "Show the current RBA autorun-on-connect configuration.",
  {},
  async () => jsonText(autorunConfig)
);

server.tool(
  "rba_dashboard_start",
  "Start the local RBA dashboard HTTP server.",
  {
    host: z.string().default("127.0.0.1"),
    port: z.number().int().min(1).max(65535).default(DEFAULT_DASHBOARD_PORT)
  },
  async ({ host, port }) => {
    await startDashboard(host, port);
    return jsonText(serverStatus());
  }
);

server.tool(
  "rba_dashboard_stop",
  "Stop the local RBA dashboard HTTP server.",
  {},
  async () => {
    await stopDashboard();
    return jsonText(serverStatus());
  }
);

server.tool(
  "rba_list_presets",
  "List built-in Lua websocket presets.",
  {},
  async () => {
    const presets = Object.entries(luaPresets).map(([name, preset]) => ({
      name,
      description: preset.description
    }));
    return jsonText(presets);
  }
);

server.tool(
  "rba_run_preset",
  "Run a built-in Lua preset on connected development clients.",
  {
    preset: presetNameSchema,
    target: clientTargetSchema.optional()
  },
  async ({ preset, target }) => {
    const script = luaPresets[preset].script;
      const sent = await sendLua(script, resolveTarget(target, "all"));
    return okText(`Ran preset "${preset}" on ${sent} client(s).`);
  }
);

server.tool(
  "rba_get_character_position",
  "Return the local character position and CFrame from connected development clients.",
  {
    target: clientTargetSchema.optional(),
    timeoutMs: z.number().int().min(100).max(30000).default(5000)
  },
  async ({ target, timeoutMs }) => jsonText(await requestEval(
    characterPositionScript(),
    resolveTarget(target, "first"),
    timeoutMs,
    "character_position"
  ))
);

server.tool(
  "rba_teleport_to_position",
  "Teleport the local character to exact coordinates and remember the previous position.",
  {
    x: z.number().finite(),
    y: z.number().finite(),
    z: z.number().finite(),
    yawDegrees: z.number().finite().default(0),
    target: clientTargetSchema.optional(),
    timeoutMs: z.number().int().min(100).max(30000).default(5000)
  },
  async ({ x, y, z: zPosition, yawDegrees, target, timeoutMs }) => jsonText(await requestEval(
    teleportToPositionScript({ x, y, z: zPosition, yawDegrees }),
    resolveTarget(target, "first"),
    timeoutMs,
    "teleport_to_position"
  ))
);

server.tool(
  "rba_teleport_to_part",
  "Teleport the local character to a Workspace BasePart or Model path, with an optional local offset.",
  {
    partPath: z.string().min(1).describe("Workspace path such as Map/SpawnPad or Workspace.Map.SpawnPad."),
    offsetX: z.number().finite().default(0),
    offsetY: z.number().finite().default(3),
    offsetZ: z.number().finite().default(0),
    yawDegrees: z.number().finite().default(0),
    target: clientTargetSchema.optional(),
    timeoutMs: z.number().int().min(100).max(30000).default(5000)
  },
  async ({ partPath, offsetX, offsetY, offsetZ, yawDegrees, target, timeoutMs }) => jsonText(await requestEval(
    teleportToPartScript({ partPath, offsetX, offsetY, offsetZ, yawDegrees }),
    resolveTarget(target, "first"),
    timeoutMs,
    "teleport_to_part"
  ))
);

server.tool(
  "rba_return_to_last_teleport",
  "Return the local character to its position before the most recent RBA teleport.",
  {
    target: clientTargetSchema.optional(),
    timeoutMs: z.number().int().min(100).max(30000).default(5000)
  },
  async ({ target, timeoutMs }) => jsonText(await requestEval(
    returnToLastTeleportScript(),
    resolveTarget(target, "first"),
    timeoutMs,
    "return_to_last_teleport"
  ))
);

server.tool(
  "rba_teleport_to_place",
  "Teleport the local player to a Roblox place, optionally joining a specific public server job.",
  {
    placeId: z.number().int().positive(),
    jobId: z.string().min(1).optional(),
    target: clientTargetSchema.optional(),
    timeoutMs: z.number().int().min(100).max(30000).default(5000)
  },
  async ({ placeId, jobId, target, timeoutMs }) => jsonText(await requestEval(
    teleportToPlaceScript(placeId, jobId),
    resolveTarget(target, "first"),
    timeoutMs,
    "teleport_to_place"
  ))
);

server.tool(
  "rba_write_file",
  "Create or replace a file inside the RBA workspace.",
  {
    path: z.string().min(1),
    content: z.string(),
    overwrite: z.boolean().default(false),
    backupExisting: z.boolean().default(true).describe("Create a restorable backup before overwriting an existing file."),
    createDirectories: z.boolean().default(true)
  },
  async ({ path: filePath, content, overwrite, backupExisting, createDirectories }) => {
    const resolved = assertInsideWorkspace(filePath);
    const exists = await pathExists(resolved);
    if (!overwrite && exists) {
      throw new Error(`File already exists: ${filePath}. Set overwrite=true to replace it.`);
    }
    const backup = overwrite && backupExisting && exists
      ? await backupWorkspaceFile(filePath, "before_write")
      : undefined;
    if (createDirectories) {
      await fs.mkdir(path.dirname(resolved), { recursive: true });
    }
    await fs.writeFile(resolved, content, "utf8");
    return jsonText({ ok: true, path: filePath, bytes: content.length, backup });
  }
);

server.tool(
  "rba_install_autoexec",
  "Install the current RBA autoloader into an executor autoexec path, backing up any existing file first.",
  {
    targetPath: z.string().default(defaultAutoexecPath),
    sourcePath: z.string().optional().describe("Workspace-relative source path. Defaults to lua/rba_autoloader.lua.")
  },
  async ({ targetPath, sourcePath }) => jsonText(await installAutoexec(targetPath, sourcePath))
);

server.tool(
  "rba_sync_autoexec",
  "Sync the workspace unified autoloader to one autoexec target, backing up changed content by default.",
  {
    targetPath: z.string().default(defaultAutoexecPath),
    backupExisting: z.boolean().default(true)
  },
  async ({ targetPath, backupExisting }) => jsonText(await writeAutoexecFile({
    targetPath,
    backup: backupExisting,
    reason: "manual_sync"
  }))
);

server.tool(
  "rba_sync_all_autoexec",
  "Sync the same unified RBA and Roblox Instance Manager autoloader to every configured executor target.",
  {
    backupExisting: z.boolean().default(true)
  },
  async ({ backupExisting }) => jsonText(await syncAutoloaderToAutoexec("manual_sync_all", backupExisting))
);

server.tool(
  "rba_autoexec_targets",
  "Show every configured executor autoexec target and verify its installed loader hash against the workspace source.",
  {},
  async () => jsonText({
    sourcePath: path.join(workspaceRoot, "lua", AUTOEXEC_FILENAME),
    targets: await Promise.all(autoexecTargetPaths.map(autoexecTargetStatus))
  })
);

server.tool(
  "rba_list_autoexec_backups",
  "List sidecar backups created for an autoexec target.",
  {
    targetPath: z.string().default(defaultAutoexecPath)
  },
  async ({ targetPath }) => jsonText(await listAutoexecBackups(targetPath))
);

server.tool(
  "rba_restore_autoexec_backup",
  "Restore an autoexec sidecar backup and preserve the currently installed file first.",
  {
    targetPath: z.string().default(defaultAutoexecPath),
    backupPath: z.string().min(1)
  },
  async ({ targetPath, backupPath }) => jsonText(await restoreAutoexecBackup(targetPath, backupPath))
);

server.tool(
  "rba_append_file",
  "Append text to a file inside the RBA workspace, creating it when needed.",
  {
    path: z.string().min(1),
    content: z.string(),
    createDirectories: z.boolean().default(true)
  },
  async ({ path: filePath, content, createDirectories }) => {
    const resolved = assertInsideWorkspace(filePath);
    if (createDirectories) {
      await fs.mkdir(path.dirname(resolved), { recursive: true });
    }
    await fs.appendFile(resolved, content, "utf8");
    return okText(`Appended ${content.length} bytes to ${filePath}.`);
  }
);

server.tool(
  "rba_read_file",
  "Read a workspace file, capped to a safe byte limit.",
  {
    path: z.string().min(1),
    maxBytes: z.number().int().min(1).max(1_000_000).default(200_000)
  },
  async ({ path: filePath, maxBytes }) => {
    const resolved = assertInsideWorkspace(filePath);
    const buffer = await fs.readFile(resolved);
    const sliced = buffer.subarray(0, maxBytes).toString("utf8");
    const truncated = buffer.byteLength > maxBytes;
    return jsonText({
      path: filePath,
      bytes: buffer.byteLength,
      truncated,
      content: sliced
    });
  }
);

server.tool(
  "rba_backup_file",
  "Create a timestamped backup of a workspace file under .rba-backups.",
  {
    path: z.string().min(1),
    reason: z.string().min(1).max(200).default("manual_backup")
  },
  async ({ path: filePath, reason }) => jsonText(await backupWorkspaceFile(filePath, reason))
);

server.tool(
  "rba_list_backups",
  "List workspace file backups, optionally filtered to one original path.",
  {
    path: z.string().min(1).optional()
  },
  async ({ path: filePath }) => jsonText(await listWorkspaceBackups(filePath))
);

server.tool(
  "rba_restore_backup",
  "Restore a .rba-backups file, first backing up the current destination when it exists.",
  {
    backupPath: z.string().min(1),
    destinationPath: z.string().min(1).optional()
  },
  async ({ backupPath, destinationPath }) => jsonText(await restoreWorkspaceBackup(backupPath, destinationPath))
);

server.tool(
  "rba_batch_files",
  "Run multiple workspace file operations in one call.",
  {
    operations: z.array(batchOperationSchema).min(1).max(50)
  },
  async ({ operations }) => {
    const results: string[] = [];

    for (const operation of operations) {
      const resolved = assertInsideWorkspace(operation.path);
      if (operation.action === "mkdir") {
        await fs.mkdir(resolved, { recursive: true });
        results.push(`mkdir ${operation.path}`);
        continue;
      }

      if (operation.content === undefined) {
        throw new Error(`Operation "${operation.action}" for ${operation.path} requires content.`);
      }

      await fs.mkdir(path.dirname(resolved), { recursive: true });
      if (operation.action === "write") {
        const exists = await pathExists(resolved);
        if (!operation.overwrite && exists) {
          throw new Error(`File already exists: ${operation.path}. Set overwrite=true to replace it.`);
        }
        if (operation.overwrite && operation.backupExisting && exists) {
          await backupWorkspaceFile(operation.path, "before_batch_write");
        }
        await fs.writeFile(resolved, operation.content, "utf8");
        results.push(`write ${operation.path} (${operation.content.length} bytes)`);
        continue;
      }

      await fs.appendFile(resolved, operation.content, "utf8");
      results.push(`append ${operation.path} (${operation.content.length} bytes)`);
    }

    return jsonText(results);
  }
);

server.tool(
  "rba_list_windows",
  "List visible desktop windows that can be used as screenshot targets.",
  {},
  async () => jsonText(await listWindows())
);

server.tool(
  "rba_capture_window_screenshot",
  "Capture a screenshot of a visible Windows process window and return it as an MCP image.",
  {
    processName: z.string().min(1).describe("Process name without .exe, for example RobloxPlayerBeta."),
    outputPath: z.string().optional().describe("Optional workspace-relative PNG path."),
    focusWindow: z.boolean().default(true).describe("Bring the window to the foreground before capture."),
    includeImage: z.boolean().default(true).describe("Return image bytes in the MCP response.")
  },
  async ({ processName, outputPath, focusWindow, includeImage }) => {
    const workspacePath = outputPath ?? defaultScreenshotPath(processName);
    const resolved = assertInsideWorkspace(workspacePath);
    const meta = await captureProcessWindow(processName.replace(/\.exe$/i, ""), resolved, focusWindow);
    if (!includeImage) {
      return jsonText(meta);
    }
    return imageResult(meta, resolved, "image/png");
  }
);

server.tool(
  "rba_capture_roblox_screenshot",
  "Capture RobloxPlayerBeta.exe and return the screenshot as an MCP image for visual context.",
  {
    outputPath: z.string().optional().describe("Optional workspace-relative PNG path."),
    focusWindow: z.boolean().default(true).describe("Bring Roblox to the foreground before capture."),
    includeImage: z.boolean().default(true).describe("Return image bytes in the MCP response.")
  },
  async ({ outputPath, focusWindow, includeImage }) => {
    const workspacePath = outputPath ?? defaultScreenshotPath("RobloxPlayerBeta");
    const resolved = assertInsideWorkspace(workspacePath);
      const meta = await captureRobloxOrDesktop(resolved, focusWindow);
    if (!includeImage) {
      return jsonText(meta);
    }
    return imageResult(meta, resolved, "image/png");
  }
);

server.tool(
  "rba_read_image",
  "Read a workspace PNG/JPEG file and return it as an MCP image.",
  {
    path: z.string().min(1)
  },
  async ({ path: imagePath }) => {
    const resolved = assertInsideWorkspace(imagePath);
    const ext = path.extname(resolved).toLowerCase();
    if (![".png", ".jpg", ".jpeg"].includes(ext)) {
      throw new Error("rba_read_image only supports .png, .jpg, and .jpeg files.");
    }
    const stats = await fs.stat(resolved);
    return imageResult({
      path: imagePath,
      bytes: stats.size,
      mimeType: imageMimeType(resolved)
    }, resolved, imageMimeType(resolved));
  }
);

server.tool(
  "rba_list_files",
  "List files inside the RBA workspace.",
  {
    path: z.string().default("."),
    recursive: z.boolean().default(false),
    maxEntries: z.number().int().min(1).max(2000).default(200)
  },
  async ({ path: listPath, recursive, maxEntries }) => {
    const resolved = assertInsideWorkspace(listPath);
    const entries = await walkFiles(resolved, recursive, maxEntries);
    return jsonText({
      root: workspaceRoot,
      path: listPath,
      entries,
      capped: entries.length >= maxEntries
    });
  }
);

server.tool(
  "rba_search_files",
  "Search text files inside the RBA workspace.",
  {
    query: z.string().min(1),
    path: z.string().default("."),
    extensions: z.array(z.string()).default([]).describe("Optional extensions such as .lua or .ts."),
    maxResults: z.number().int().min(1).max(500).default(100)
  },
  async ({ query, path: searchPath, extensions, maxResults }) => {
    const start = assertInsideWorkspace(searchPath);
    return jsonText(await searchWorkspaceFiles({ start, query, extensions, maxResults }));
  }
);

if (process.env.RBA_AUTO_START_WS === "true") {
  try {
    await startWebSocketServer(DEFAULT_HOST, DEFAULT_PORT);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[RBA] Could not auto-start websocket server: ${message}`);
  }
}

const transport = new StdioServerTransport();
await server.connect(transport);
