-- RBA unified local development autoloader.
-- Starts the RBA websocket client and the local Roblox Instance Manager connector.
-- Use only in development experiences you own or have explicit permission to test.

local RuntimeEnv = type(getgenv) == "function" and getgenv() or _G

local WebSocket = assert(
    WebSocket or Websocket or websocket or (syn and syn.websocket),
    "Your environment is missing a websocket API!"
)

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local Stats = game:GetService("Stats")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local HOSTS = { "localhost", "127.0.0.1" }
local PORTS = { 33882, 33883, 33884, 33885, 33886, 33887, 33888, 33889, 33890, 33891, 33892, 33893, 33894, 33895, 33896, 33897, 33898, 33899, 33900, 33901, 33902, 33903, 33904, 33905, 33906, 33907, 33908, 33909, 33910, 33911, 33912, 33913, 33914, 33915, 33916, 33917, 33918, 33919, 33920 }
local LOADER_VERSION = "4.0.0"
local PROTOCOL_VERSION = 4
local RETRY_SECONDS = 1
local MAX_RETRY_SECONDS = 8
local MAX_ENDPOINTS_PER_SCAN = 8
local STATUS_AUTO_HIDE_SECONDS = 5
local STATUS_FADE_SECONDS = 0.35
local MAX_INCOMING_BYTES = 1024 * 1024
local MAX_OUTGOING_BYTES = 1024 * 1024
local MAX_QUEUED_EVALS = 24
local MAX_QUEUED_BYTES = 4 * 1024 * 1024
local MAX_CONCURRENT_EVALS = 2
local DEFAULT_EVAL_TIMEOUT_MS = 8000
local MIN_EVAL_TIMEOUT_MS = 250
local MAX_EVAL_TIMEOUT_MS = 120000
local MAX_RECENT_REQUEST_IDS = 256
local MAX_INCOMING_MESSAGES_PER_WINDOW = 240
local INCOMING_RATE_WINDOW_SECONDS = 10
local MAX_INSPECT_DEPTH = 4
local MAX_INSPECT_NODES = 240
local MAX_TABLE_ITEMS = 64
local MAX_STRING_BYTES = 4096
local HEARTBEAT_SECONDS = 20
local INSTANCE_MANAGER_DEFAULT_ADDRESS = "localhost:16384"
local INSTANCE_MANAGER_SOURCE_PATH = "/script.luau"
local INSTANCE_MANAGER_MAX_SOURCE_BYTES = 1024 * 1024
local INSTANCE_MANAGER_MAX_RETRY_SECONDS = 15

local configuredMode = string.lower(tostring(RuntimeEnv.RBA_MODE or "unified"))
local instanceManagerEnabled = RuntimeEnv.RBA_ENABLE_INSTANCE_MANAGER ~= false
    and configuredMode ~= "rba"
    and configuredMode ~= "rba-only"

local previousLoaderState = _G.__RBA_LOADER_STATE
if type(previousLoaderState) == "table" and type(previousLoaderState.stop) == "function" then
    pcall(previousLoaderState.stop, "reloaded")
end

local loaderState = {
    generation = (tonumber(_G.__RBA_LOADER_GENERATION) or 0) + 1,
    running = true,
    client = nil,
    connectionHealthy = false,
    messageConnection = nil,
    closeConnection = nil,
    heartbeatThread = nil,
    queue = {},
    queuedBytes = 0,
    activeEvals = 0,
    activeThreads = {},
    activeWatchdogs = {},
    recentRequestIds = {},
    recentRequestOrder = {},
    receivedMessages = 0,
    receivedBytes = 0,
    rateWindowStartedAt = os.clock(),
    messagesInRateWindow = 0,
    droppedMessages = 0,
    executedScripts = 0,
    timedOutScripts = 0,
    mode = instanceManagerEnabled and "unified" or "rba-only"
}
_G.__RBA_LOADER_GENERATION = loaderState.generation
_G.__RBA_LOADER_STATE = loaderState

local function isCurrentLoader()
    return loaderState.running
        and _G.__RBA_LOADER_STATE == loaderState
        and _G.__RBA_LOADER_GENERATION == loaderState.generation
end

local function safeText(value, limit)
    local converted
    local ok = pcall(function()
        converted = tostring(value)
    end)
    local text = ok and converted or "<unprintable value>"
    local maxBytes = tonumber(limit) or MAX_STRING_BYTES
    if #text <= maxBytes then
        return text
    end
    return string.sub(text, 1, maxBytes) .. string.format("... <truncated %d bytes>", #text - maxBytes)
end

local function disconnectSignal(connection)
    if connection then
        pcall(function()
            connection:Disconnect()
        end)
    end
end

local function closeSocket(client)
    if not client then
        return
    end
    local ok = pcall(function()
        client:Close()
    end)
    if not ok then
        pcall(function()
            client.Close(client)
        end)
    end
end

local function cancelThread(thread)
    if thread and task and type(task.cancel) == "function" then
        pcall(task.cancel, thread)
    end
end

local function clearConnection()
    disconnectSignal(loaderState.messageConnection)
    disconnectSignal(loaderState.closeConnection)
    loaderState.messageConnection = nil
    loaderState.closeConnection = nil
    cancelThread(loaderState.heartbeatThread)
    loaderState.heartbeatThread = nil
    closeSocket(loaderState.client)
    loaderState.client = nil
    loaderState.connectionHealthy = false
end

function loaderState.stop(reason)
    if not loaderState.running then
        return
    end
    loaderState.running = false
    loaderState.stopReason = tostring(reason or "stopped")
    clearConnection()
    for thread in pairs(loaderState.activeThreads) do
        cancelThread(thread)
    end
    for thread in pairs(loaderState.activeWatchdogs) do
        cancelThread(thread)
    end
    loaderState.activeThreads = {}
    loaderState.activeWatchdogs = {}
    loaderState.queue = {}
    loaderState.queuedBytes = 0
    loaderState.activeEvals = 0
    if _G.RBA and _G.RBA._generation == loaderState.generation then
        _G.RBA = nil
    end
end

-- Disconnect the legacy always-on LogService mirror from older loader versions.
-- Console forwarding is intentionally opt-in through rba_install_console_mirror.
pcall(function()
    if _G.__RBA_LOGSERVICE_CONNECTION then
        _G.__RBA_LOGSERVICE_CONNECTION:Disconnect()
        _G.__RBA_LOGSERVICE_CONNECTION = nil
    end
    _G.__RBA_AUTO_CONSOLE_MIRROR = nil
end)

local function addUniqueUrl(urls, seen, url)
    if type(url) == "string" and url ~= "" and not seen[url] then
        seen[url] = true
        table.insert(urls, url)
    end
end

local function parseWsUrl(url)
    if type(url) ~= "string" then
        return nil, nil
    end
    local host, portText = string.match(url, "^ws://([^:/]+):(%d+)/?")
    local port = tonumber(portText)
    if host and port and port > 0 and port <= 65535 then
        return host, port
    end
    return nil, nil
end

local function addPortUrls(urls, seen, port)
    port = tonumber(port)
    if not port or port < 1 or port > 65535 then
        return
    end
    for _, host in ipairs(HOSTS) do
        addUniqueUrl(urls, seen, "ws://" .. host .. ":" .. tostring(port) .. "/")
    end
end

local function getCandidateUrls()
    local urls = {}
    local seen = {}

    if type(_G.RBA_URL) == "string" then
        addUniqueUrl(urls, seen, _G.RBA_URL)
    end

    if type(_G.RBA_PORT) == "number" or type(_G.RBA_PORT) == "string" then
        addPortUrls(urls, seen, _G.RBA_PORT)
    end

    if type(_G.RBA_PORTS) == "table" then
        for _, port in ipairs(_G.RBA_PORTS) do
            addPortUrls(urls, seen, port)
        end
    end

    for _, port in ipairs(PORTS) do
        addPortUrls(urls, seen, port)
    end

    return urls
end

local function ensureStatusGui()
    local ok, gui = pcall(function()
        if _G.__RBA_STATUS_GUI and _G.__RBA_STATUS_GUI.Parent then
            return _G.__RBA_STATUS_GUI
        end

        local parent
        local player = Players.LocalPlayer
        if player then
            parent = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 5)
        end
        if not parent then
            parent = game:GetService("CoreGui")
        end

        local screen = Instance.new("ScreenGui")
        screen.Name = "RBAStatusGui"
        screen.ResetOnSpawn = false
        screen.IgnoreGuiInset = true

        local frame = Instance.new("Frame")
        frame.Name = "Panel"
        frame.AnchorPoint = Vector2.new(1, 0)
        frame.Position = UDim2.new(1, -14, 0, 14)
        frame.Size = UDim2.new(0, 330, 0, 70)
        frame.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
        frame.BackgroundTransparency = 0.08
        frame.BorderSizePixel = 0
        frame.Parent = screen

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 8)
        corner.Parent = frame

        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(80, 80, 110)
        stroke.Thickness = 1
        stroke.Parent = frame

        local title = Instance.new("TextLabel")
        title.Name = "Title"
        title.BackgroundTransparency = 1
        title.Position = UDim2.new(0, 12, 0, 8)
        title.Size = UDim2.new(1, -24, 0, 20)
        title.Font = Enum.Font.GothamSemibold
        title.TextSize = 14
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.TextColor3 = Color3.fromRGB(235, 235, 245)
        title.Text = "RBA Bridge"
        title.Parent = frame

        local status = Instance.new("TextLabel")
        status.Name = "Status"
        status.BackgroundTransparency = 1
        status.Position = UDim2.new(0, 12, 0, 32)
        status.Size = UDim2.new(1, -24, 0, 30)
        status.Font = Enum.Font.Gotham
        status.TextSize = 12
        status.TextWrapped = true
        status.TextXAlignment = Enum.TextXAlignment.Left
        status.TextYAlignment = Enum.TextYAlignment.Top
        status.TextColor3 = Color3.fromRGB(180, 180, 205)
        status.Text = "Waiting for MCP bridge..."
        status.Parent = frame

        screen.Parent = parent
        _G.__RBA_STATUS_GUI = screen
        return screen
    end)

    if ok then
        return gui
    end
    return nil
end

local function cancelStatusTweens()
    if type(_G.__RBA_STATUS_TWEENS) ~= "table" then
        _G.__RBA_STATUS_TWEENS = {}
        return
    end
    for _, tween in ipairs(_G.__RBA_STATUS_TWEENS) do
        pcall(function()
            tween:Cancel()
        end)
    end
    _G.__RBA_STATUS_TWEENS = {}
end

local function setPanelTransparency(panel, hidden)
    panel.BackgroundTransparency = hidden and 1 or 0.08
    for _, descendant in ipairs(panel:GetDescendants()) do
        if descendant:IsA("TextLabel") then
            descendant.TextTransparency = hidden and 1 or 0
        elseif descendant:IsA("UIStroke") then
            descendant.Transparency = hidden and 1 or 0
        end
    end
end

local function hideStatusGui(gui, revision)
    if revision ~= _G.__RBA_STATUS_REVISION or not gui.Parent then
        return
    end
    local panel = gui:FindFirstChild("Panel")
    if not panel or not panel.Visible then
        return
    end

    cancelStatusTweens()
    local tweenInfo = TweenInfo.new(STATUS_FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local tweens = {
        TweenService:Create(panel, tweenInfo, { BackgroundTransparency = 1 })
    }
    for _, descendant in ipairs(panel:GetDescendants()) do
        if descendant:IsA("TextLabel") then
            table.insert(tweens, TweenService:Create(descendant, tweenInfo, { TextTransparency = 1 }))
        elseif descendant:IsA("UIStroke") then
            table.insert(tweens, TweenService:Create(descendant, tweenInfo, { Transparency = 1 }))
        end
    end
    _G.__RBA_STATUS_TWEENS = tweens
    for _, tween in ipairs(tweens) do
        tween:Play()
    end
    task.delay(STATUS_FADE_SECONDS, function()
        if revision == _G.__RBA_STATUS_REVISION and panel.Parent then
            panel.Visible = false
        end
    end)
end

local function setStatusGui(message, color, autoHideSeconds)
    pcall(function()
        local gui = ensureStatusGui()
        if not gui then
            return
        end
        local panel = gui:FindFirstChild("Panel")
        if not panel then
            return
        end
        _G.__RBA_STATUS_REVISION = (_G.__RBA_STATUS_REVISION or 0) + 1
        local revision = _G.__RBA_STATUS_REVISION
        cancelStatusTweens()
        panel.Visible = true
        setPanelTransparency(panel, false)
        local status = panel and panel:FindFirstChild("Status")
        local stroke = panel and panel:FindFirstChildOfClass("UIStroke")
        if status then
            status.Text = safeText(message, 768)
            status.TextColor3 = color or Color3.fromRGB(180, 180, 205)
        end
        if stroke and color then
            stroke.Color = color
        end
        local delaySeconds = tonumber(autoHideSeconds)
        if delaySeconds and delaySeconds > 0 then
            task.delay(delaySeconds, function()
                hideStatusGui(gui, revision)
            end)
        end
    end)
end

local function statusColor(level)
    if level == "success" then
        return Color3.fromRGB(74, 222, 128)
    end
    if level == "warn" then
        return Color3.fromRGB(251, 191, 36)
    end
    if level == "error" then
        return Color3.fromRGB(248, 113, 113)
    end
    return Color3.fromRGB(180, 180, 205)
end

local function notifyGui(title, message, level, durationMs)
    local text = safeText(message or "", 768)
    local heading = safeText(title or "RBA", 96)
    local visibleSeconds = math.max(1, math.floor((tonumber(durationMs) or 4000) / 1000))
    setStatusGui(heading .. ": " .. text, statusColor(level), visibleSeconds)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = heading,
            Text = text,
            Duration = visibleSeconds
        })
    end)
end

local function safeType(value)
    local ok, result = pcall(function()
        return typeof(value)
    end)

    if ok then
        return result
    end

    return type(value)
end

local function truncateString(value, limit)
    return safeText(value, limit or MAX_STRING_BYTES)
end

local function inspect(value, depth, seen, budget)
    depth = depth or MAX_INSPECT_DEPTH
    seen = seen or {}
    budget = budget or { nodes = 0, limit = MAX_INSPECT_NODES }
    budget.nodes = budget.nodes + 1
    if budget.nodes > budget.limit then
        return { kind = "truncated", reason = "inspection node budget exceeded" }
    end

    local valueType = safeType(value)
    if value == nil or valueType == "boolean" or valueType == "number" then
        return value
    end
    if valueType == "string" then
        return truncateString(value)
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
        return { kind = "CFrame", position = inspect(value.Position, depth - 1, seen, budget) }
    end
    if valueType == "EnumItem" then
        return { kind = "EnumItem", value = truncateString(value, 256) }
    end
    if valueType == "Instance" then
        local fullName = "<unknown>"
        pcall(function()
            fullName = value:GetFullName()
        end)
        return {
            kind = "Instance",
            className = truncateString(value.ClassName, 256),
            name = truncateString(value.Name, 256),
            path = truncateString(fullName, 1024)
        }
    end

    if type(value) == "table" then
        if seen[value] then
            return { kind = "cycle" }
        end
        if depth <= 0 then
            return { kind = "table", truncated = true, reason = "depth limit" }
        end

        seen[value] = true
        local output = {}
        local count = 0
        for key, child in pairs(value) do
            count = count + 1
            if count > MAX_TABLE_ITEMS or budget.nodes >= budget.limit then
                output.__truncated = true
                break
            end
            output[truncateString(key, 256)] = inspect(child, depth - 1, seen, budget)
        end
        seen[value] = nil
        return output
    end

    return { kind = truncateString(valueType, 128), value = truncateString(value) }
end

local function packValues(...)
    local output = {
        n = select("#", ...),
        values = {}
    }
    local budget = { nodes = 0, limit = MAX_INSPECT_NODES }

    for index = 1, output.n do
        output.values[index] = inspect(select(index, ...), MAX_INSPECT_DEPTH, {}, budget)
    end

    return output
end

local function snapshot()
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
                state = tostring(humanoid:GetState()),
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
            fieldOfView = camera.FieldOfView,
            viewportSize = inspect(camera.ViewportSize, 2)
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
            hasWebSocket = true
        }
    }
end

local function sendRaw(client, payload)
    if not isCurrentLoader() or loaderState.client ~= client then
        return false, "socket is no longer active"
    end
    if type(payload) ~= "string" then
        return false, "payload must be a string"
    end
    if #payload > MAX_OUTGOING_BYTES then
        return false, string.format("payload exceeds %d byte limit", MAX_OUTGOING_BYTES)
    end

    local ok, err = pcall(function()
        client:Send(payload)
    end)
    if not ok then
        ok, err = pcall(function()
            client.Send(client, payload)
        end)
    end
    return ok, ok and nil or tostring(err)
end

local getInstanceManagerHealth
local startInstanceManager

local function makeBridge(client)
    local bridge = {
        url = _G.RBA_URL,
        version = LOADER_VERSION,
        _generation = loaderState.generation,
        connectedAt = os.clock(),
        client = client,
        inspect = inspect,
        packValues = packValues,
        snapshot = snapshot
    }

    function bridge.send(data)
        local payload
        if typeof(data) == "string" then
            payload = data
        else
            local encoded, encodeError
            local encodedOk = pcall(function()
                encoded = HttpService:JSONEncode(data)
            end)
            if not encodedOk then
                encodeError = "payload could not be JSON encoded"
                warn("[RBA] Send rejected:", encodeError)
                return false, encodeError
            end
            payload = encoded
        end

        local sent, sendError = sendRaw(client, payload)
        if not sent then
            warn("[RBA] Send rejected:", sendError)
        end
        return sent, sendError
    end

    function bridge.reply(requestId, ok, payload)
        bridge.send({
            type = "rba_response",
            requestId = requestId,
            ok = ok,
            payload = inspect(payload, 5),
            at = os.time(),
            clock = os.clock()
        })
    end

    function bridge.trace(label, data)
        bridge.send({
            type = "trace",
            label = label,
            data = inspect(data, 4),
            at = os.time(),
            clock = os.clock()
        })
    end

    function bridge.log(...)
        local parts = {}
        local count = math.min(select("#", ...), 32)
        for index = 1, count do
            parts[index] = safeText(select(index, ...), 512)
        end

        local message = safeText(table.concat(parts, " "), MAX_STRING_BYTES)
        print("[RBA]", message)
        bridge.send({
            type = "log",
            message = message,
            at = os.time(),
            clock = os.clock()
        })
    end

    function bridge.showStatus(durationSeconds)
        setStatusGui(
            "Connected to " .. tostring(bridge.url),
            Color3.fromRGB(74, 222, 128),
            tonumber(durationSeconds) or STATUS_AUTO_HIDE_SECONDS
        )
    end

    function bridge.health()
        return {
            version = LOADER_VERSION,
            protocol = PROTOCOL_VERSION,
            mode = loaderState.mode,
            generation = loaderState.generation,
            connected = isCurrentLoader() and loaderState.client == client and loaderState.connectionHealthy,
            queuedEvals = #loaderState.queue,
            queuedBytes = loaderState.queuedBytes,
            activeEvals = loaderState.activeEvals,
            receivedMessages = loaderState.receivedMessages,
            receivedBytes = loaderState.receivedBytes,
            droppedMessages = loaderState.droppedMessages,
            executedScripts = loaderState.executedScripts,
            timedOutScripts = loaderState.timedOutScripts,
            instanceManager = getInstanceManagerHealth()
        }
    end

    function bridge.instanceManager()
        return getInstanceManagerHealth()
    end

    function bridge.startInstanceManager()
        return startInstanceManager()
    end

    function bridge.stop()
        loaderState.stop("bridge.stop")
    end

    return bridge
end

local function traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

local function compileSource(source)
    local loader = loadstring or load
    if type(loader) ~= "function" then
        return nil, "loadstring/load is unavailable in this executor environment"
    end

    local ok, chunkOrError, extraError = pcall(loader, source)
    if not ok then
        return nil, tostring(chunkOrError)
    end
    if type(chunkOrError) ~= "function" then
        return nil, tostring(extraError or chunkOrError or "unknown compile error")
    end
    return chunkOrError
end

local function normalizeLocalBridgeAddress(value)
    local address = tostring(value or INSTANCE_MANAGER_DEFAULT_ADDRESS)
    address = string.gsub(address, "^%s+", "")
    address = string.gsub(address, "%s+$", "")
    address = string.gsub(address, "^https?://", "")
    address = string.gsub(address, "/+$", "")

    local host
    local portText
    if string.sub(address, 1, 1) == "[" then
        host, portText = string.match(address, "^%[([^%]]+)%]:(%d+)$")
    else
        host, portText = string.match(address, "^([^:/]+):(%d+)$")
    end

    local normalizedHost = host and string.lower(host) or nil
    local port = tonumber(portText)
    if normalizedHost ~= "localhost" and normalizedHost ~= "127.0.0.1" and normalizedHost ~= "::1" then
        return nil, "Instance Manager BridgeURL must use localhost, 127.0.0.1, or ::1"
    end
    if not port or port < 1 or port > 65535 then
        return nil, "Instance Manager BridgeURL must include a valid TCP port"
    end

    if normalizedHost == "::1" then
        return "[::1]:" .. tostring(port)
    end
    return normalizedHost .. ":" .. tostring(port)
end

local function fetchInstanceManagerSource(url)
    local requestFunction = RuntimeEnv.request
        or RuntimeEnv.http_request
        or (RuntimeEnv.syn and RuntimeEnv.syn.request)
        or request
        or http_request
        or (syn and syn.request)

    if type(requestFunction) == "function" then
        local requestOk, response = pcall(requestFunction, {
            Url = url,
            Method = "GET",
            Headers = {
                ["Accept"] = "text/plain"
            }
        })
        if not requestOk then
            return nil, "local connector request failed: " .. tostring(response)
        end
        if type(response) ~= "table" then
            return nil, "local connector returned an invalid HTTP response"
        end
        local statusCode = tonumber(response.StatusCode or response.Status)
        if statusCode and (statusCode < 200 or statusCode >= 300) then
            return nil, "local connector returned HTTP " .. tostring(statusCode)
        end
        local body = response.Body or response.body
        if type(body) ~= "string" then
            return nil, "local connector response body was not text"
        end
        return body
    end

    local httpOk, body = pcall(function()
        return game:HttpGet(url, true)
    end)
    if not httpOk then
        return nil, "local connector download failed: " .. tostring(body)
    end
    if type(body) ~= "string" then
        return nil, "local connector response body was not text"
    end
    return body
end

local function instanceManagerState()
    local current = RuntimeEnv.__RBA_INSTANCE_MANAGER_STATE
    if type(current) ~= "table" then
        current = {
            version = 1,
            started = false,
            status = instanceManagerEnabled and "idle" or "disabled",
            attempts = 0
        }
        RuntimeEnv.__RBA_INSTANCE_MANAGER_STATE = current
    end
    return current
end

getInstanceManagerHealth = function()
    local state = instanceManagerState()
    return {
        enabled = instanceManagerEnabled,
        started = state.started == true,
        status = tostring(state.status or "unknown"),
        address = state.address,
        url = state.url,
        attempts = tonumber(state.attempts) or 0,
        sourceBytes = tonumber(state.sourceBytes) or 0,
        startedAt = state.startedAt,
        lastAttemptAt = state.lastAttemptAt,
        lastError = state.lastError
    }
end

startInstanceManager = function()
    local state = instanceManagerState()
    if not instanceManagerEnabled then
        state.status = "disabled"
        return false, "Instance Manager integration is disabled by RBA_MODE or RBA_ENABLE_INSTANCE_MANAGER"
    end
    if state.started then
        return true, "Instance Manager connector is already started"
    end

    local address, addressError = normalizeLocalBridgeAddress(RuntimeEnv.BridgeURL or INSTANCE_MANAGER_DEFAULT_ADDRESS)
    if not address then
        state.status = "configuration_error"
        state.lastError = addressError
        return false, addressError
    end

    state.started = true
    state.status = "starting"
    state.address = address
    state.url = "http://" .. address .. INSTANCE_MANAGER_SOURCE_PATH
    state.attempts = 0
    state.startedAt = os.time()
    state.lastAttemptAt = nil
    state.lastError = nil
    state.sourceBytes = 0
    RuntimeEnv.BridgeURL = address

    state.thread = task.spawn(function()
        local retrySeconds = RETRY_SECONDS
        while state.started do
            state.attempts = state.attempts + 1
            state.lastAttemptAt = os.time()
            state.status = "downloading"

            local source, downloadError = fetchInstanceManagerSource(state.url)
            if source and #source > INSTANCE_MANAGER_MAX_SOURCE_BYTES then
                downloadError = string.format(
                    "local connector source exceeds the %d byte safety limit",
                    INSTANCE_MANAGER_MAX_SOURCE_BYTES
                )
                source = nil
            end

            if source then
                state.sourceBytes = #source
                local callback, compileError = compileSource(source)
                if callback then
                    state.status = "running"
                    state.lastError = nil
                    print("[RBA] Instance Manager connector started from " .. state.url)
                    local runOk, runError = xpcall(function()
                        return callback(address)
                    end, traceback)
                    state.started = false
                    state.status = runOk and "stopped" or "runtime_error"
                    state.lastError = runOk
                        and "Instance Manager connector ended unexpectedly"
                        or safeText(runError, 2048)
                    break
                end
                downloadError = "Instance Manager connector compile error: " .. tostring(compileError)
            end

            state.status = "retrying"
            state.lastError = safeText(downloadError or "unknown connector startup error", 2048)
            warn("[RBA] Instance Manager startup failed:", state.lastError)
            task.wait(retrySeconds)
            retrySeconds = math.min(retrySeconds * 2, INSTANCE_MANAGER_MAX_RETRY_SECONDS)
        end
        state.thread = nil
    end)

    return true, "Instance Manager connector startup scheduled"
end

local function sendExecutionError(requestId, label, errorType, message, started)
    warn("[RBA] " .. errorType .. ":", message)
    if _G.RBA and _G.RBA._generation == loaderState.generation and _G.RBA.send then
        _G.RBA.send({
            type = requestId and "rba_response" or errorType,
            requestId = requestId,
            label = label,
            ok = false,
            error = truncateString(message),
            durationMs = math.floor((os.clock() - (started or os.clock())) * 1000)
        })
    end
end

local function executeQueuedSource(source, requestId, label)
    local started = os.clock()
    local callback, compileError = compileSource(source)

    if not callback then
        sendExecutionError(requestId, label, "compile_error", "compile error: " .. tostring(compileError), started)
        return
    end

    local ok, result = xpcall(function()
        return packValues(callback())
    end, traceback)
    loaderState.executedScripts = loaderState.executedScripts + 1

    if _G.RBA and _G.RBA._generation == loaderState.generation and _G.RBA.send then
        if ok then
            if requestId then
                _G.RBA.send({
                    type = "rba_response",
                    requestId = requestId,
                    label = label,
                    ok = true,
                    n = result.n,
                    values = result.values,
                    durationMs = math.floor((os.clock() - started) * 1000)
                })
            end
        else
            sendExecutionError(requestId, label, "runtime_error", tostring(result), started)
        end
    end
end

local pumpExecutionQueue

local function finishExecutionWorker(thread, job)
    if job.finished then
        return
    end
    job.finished = true
    if job.watchdog and job.watchdog ~= coroutine.running() then
        cancelThread(job.watchdog)
    end
    if job.watchdog then
        loaderState.activeWatchdogs[job.watchdog] = nil
    end
    loaderState.activeThreads[thread] = nil
    loaderState.activeEvals = math.max(0, loaderState.activeEvals - 1)
    if isCurrentLoader() then
        pumpExecutionQueue()
    end
end

pumpExecutionQueue = function()
    while isCurrentLoader()
        and loaderState.activeEvals < MAX_CONCURRENT_EVALS
        and #loaderState.queue > 0 do
        local job = table.remove(loaderState.queue, 1)
        loaderState.queuedBytes = math.max(0, loaderState.queuedBytes - #job.source)
        loaderState.activeEvals = loaderState.activeEvals + 1
        task.spawn(function()
            local thread = coroutine.running()
            job.thread = thread
            loaderState.activeThreads[thread] = true
            if not isCurrentLoader() then
                finishExecutionWorker(thread, job)
                return
            end
            job.watchdog = task.delay(job.timeoutMs / 1000, function()
                local watchdog = coroutine.running()
                loaderState.activeWatchdogs[watchdog] = true
                if not job.finished and loaderState.activeThreads[thread] then
                    loaderState.timedOutScripts = loaderState.timedOutScripts + 1
                    loaderState.droppedMessages = loaderState.droppedMessages + 1
                    cancelThread(thread)
                    sendExecutionError(
                        job.requestId,
                        job.label,
                        "execution_timeout",
                        string.format("Lua execution exceeded its %d ms timeout", job.timeoutMs),
                        job.queuedAt
                    )
                    finishExecutionWorker(thread, job)
                end
                loaderState.activeWatchdogs[watchdog] = nil
            end)
            loaderState.activeWatchdogs[job.watchdog] = true
            local ok, workerError = xpcall(function()
                executeQueuedSource(job.source, job.requestId, job.label)
            end, traceback)
            if not ok then
                sendExecutionError(job.requestId, job.label, "worker_error", tostring(workerError), job.queuedAt)
            end
            finishExecutionWorker(thread, job)
        end)
    end
end

local function enqueueSource(source, requestId, label, timeoutMs)
    if not isCurrentLoader() then
        return false
    end
    if type(source) ~= "string" then
        sendExecutionError(requestId, label, "protocol_error", "Lua source must be a string")
        return false
    end
    if #source > MAX_INCOMING_BYTES then
        loaderState.droppedMessages = loaderState.droppedMessages + 1
        sendExecutionError(
            requestId,
            label,
            "payload_too_large",
            string.format("Lua source exceeds the %d byte safety limit", MAX_INCOMING_BYTES)
        )
        return false
    end
    if #loaderState.queue >= MAX_QUEUED_EVALS then
        loaderState.droppedMessages = loaderState.droppedMessages + 1
        sendExecutionError(
            requestId,
            label,
            "queue_full",
            string.format("Execution queue is full (%d waiting, %d active)", #loaderState.queue, loaderState.activeEvals)
        )
        return false
    end
    if loaderState.queuedBytes + #source > MAX_QUEUED_BYTES then
        loaderState.droppedMessages = loaderState.droppedMessages + 1
        sendExecutionError(
            requestId,
            label,
            "queue_full",
            string.format("Execution queue reached its %d byte memory budget", MAX_QUEUED_BYTES)
        )
        return false
    end
    table.insert(loaderState.queue, {
        source = source,
        requestId = requestId,
        label = label,
        timeoutMs = math.max(
            MIN_EVAL_TIMEOUT_MS,
            math.min(MAX_EVAL_TIMEOUT_MS, tonumber(timeoutMs) or DEFAULT_EVAL_TIMEOUT_MS)
        ),
        finished = false,
        queuedAt = os.clock()
    })
    loaderState.queuedBytes = loaderState.queuedBytes + #source
    pumpExecutionQueue()
    return true
end

local function rememberRequestId(requestId)
    if type(requestId) ~= "string" or requestId == "" then
        return true
    end
    if loaderState.recentRequestIds[requestId] then
        return false
    end
    loaderState.recentRequestIds[requestId] = true
    table.insert(loaderState.recentRequestOrder, requestId)
    while #loaderState.recentRequestOrder > MAX_RECENT_REQUEST_IDS do
        local expired = table.remove(loaderState.recentRequestOrder, 1)
        loaderState.recentRequestIds[expired] = nil
    end
    return true
end

local function handlePayload(payload)
    if not isCurrentLoader() then
        return
    end
    if type(payload) ~= "string" then
        loaderState.droppedMessages = loaderState.droppedMessages + 1
        return
    end
    loaderState.receivedMessages = loaderState.receivedMessages + 1
    loaderState.receivedBytes = loaderState.receivedBytes + #payload
    local nowClock = os.clock()
    if nowClock - loaderState.rateWindowStartedAt >= INCOMING_RATE_WINDOW_SECONDS then
        loaderState.rateWindowStartedAt = nowClock
        loaderState.messagesInRateWindow = 0
    end
    loaderState.messagesInRateWindow = loaderState.messagesInRateWindow + 1
    if loaderState.messagesInRateWindow > MAX_INCOMING_MESSAGES_PER_WINDOW then
        loaderState.droppedMessages = loaderState.droppedMessages + 1
        if loaderState.messagesInRateWindow == MAX_INCOMING_MESSAGES_PER_WINDOW + 1 then
            sendExecutionError(nil, nil, "rate_limited", "Incoming websocket message rate exceeded the client safety limit")
        end
        return
    end
    if #payload > MAX_INCOMING_BYTES then
        loaderState.droppedMessages = loaderState.droppedMessages + 1
        sendExecutionError(nil, nil, "payload_too_large", "Incoming websocket message exceeded the safety limit")
        return
    end

    local decoded
    local decodedOk = pcall(function()
        decoded = HttpService:JSONDecode(payload)
    end)

    if decodedOk and type(decoded) == "table" and decoded.type == "eval" and type(decoded.source) == "string" then
        if not rememberRequestId(decoded.requestId) then
            loaderState.droppedMessages = loaderState.droppedMessages + 1
            sendExecutionError(
                decoded.requestId,
                decoded.label,
                "duplicate_request",
                "Duplicate eval request was ignored"
            )
            return
        end
        enqueueSource(decoded.source, decoded.requestId, decoded.label, decoded.timeoutMs)
        return
    end

    if decodedOk and type(decoded) == "table" and decoded.type == "rba_notify" then
        notifyGui(decoded.title, decoded.message, decoded.level, decoded.durationMs)
        if _G.RBA and _G.RBA.send then
            _G.RBA.send({
                type = "notify_ack",
                title = safeText(decoded.title or "RBA", 96),
                message = safeText(decoded.message or "", 768),
                level = safeText(decoded.level or "info", 32),
                clock = os.clock()
            })
        end
        return
    end

    if decodedOk and type(decoded) == "table" and decoded.type == "rba_status" then
        local level = safeText(decoded.level or "info", 32)
        setStatusGui(
            safeText(decoded.message or "RBA status update", 768),
            statusColor(level),
            level == "error" and nil or STATUS_AUTO_HIDE_SECONDS
        )
        if _G.RBA and _G.RBA.send then
            _G.RBA.send({
                type = "status_ack",
                message = safeText(decoded.message or "", 768),
                level = level,
                clock = os.clock()
            })
        end
        return
    end

    if decodedOk and type(decoded) == "table" then
        sendExecutionError(
            decoded.requestId,
            decoded.label,
            "protocol_error",
            "Unsupported RBA protocol message type: " .. tostring(decoded.type)
        )
        return
    end

    enqueueSource(payload, nil, "raw websocket script", DEFAULT_EVAL_TIMEOUT_MS)
end

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local instanceManagerStarted, instanceManagerMessage = startInstanceManager()
if not instanceManagerStarted and instanceManagerEnabled then
    warn("[RBA] " .. tostring(instanceManagerMessage))
end

local function waitWhileCurrent(seconds)
    local deadline = os.clock() + math.max(0, tonumber(seconds) or 0)
    while isCurrentLoader() and os.clock() < deadline do
        task.wait(math.min(0.25, math.max(0.03, deadline - os.clock())))
    end
end

local function startHeartbeat(client, bridge)
    cancelThread(loaderState.heartbeatThread)
    loaderState.heartbeatThread = task.spawn(function()
        while isCurrentLoader() and loaderState.client == client do
            waitWhileCurrent(HEARTBEAT_SECONDS)
            if not isCurrentLoader() or loaderState.client ~= client then
                break
            end
            local memoryMb
            pcall(function()
                memoryMb = Stats:GetTotalMemoryUsageMb()
            end)
            local sent = bridge.send({
                type = "client_heartbeat",
                version = LOADER_VERSION,
                generation = loaderState.generation,
                memoryMb = memoryMb,
                queue = {
                    waiting = #loaderState.queue,
                    queuedBytes = loaderState.queuedBytes,
                    active = loaderState.activeEvals,
                    dropped = loaderState.droppedMessages,
                    executed = loaderState.executedScripts,
                    timedOut = loaderState.timedOutScripts
                },
                at = os.time(),
                clock = os.clock()
            })
            if not sent then
                loaderState.connectionHealthy = false
                closeSocket(client)
                break
            end
        end
    end)
end

local scanCursor = 2
local retrySeconds = RETRY_SECONDS

while isCurrentLoader() do
    local connectedUrl
    local connectedHost
    local connectedPort
    local client
    local candidateUrls = getCandidateUrls()
    local scanUrls = {}

    if #candidateUrls > 0 then
        table.insert(scanUrls, candidateUrls[1])
        local remaining = math.min(MAX_ENDPOINTS_PER_SCAN - 1, #candidateUrls - 1)
        for _ = 1, remaining do
            if scanCursor > #candidateUrls then
                scanCursor = 2
            end
            table.insert(scanUrls, candidateUrls[scanCursor])
            scanCursor = scanCursor + 1
        end
    end

    setStatusGui("Scanning local RBA bridge endpoints...", Color3.fromRGB(251, 191, 36))

    for _, url in ipairs(scanUrls) do
        if not isCurrentLoader() then
            break
        end
        local success, result = pcall(function()
            return WebSocket.connect(url)
        end)

        if success and result then
            connectedUrl = url
            connectedHost, connectedPort = parseWsUrl(url)
            client = result
            break
        end
    end

    if client and isCurrentLoader() then
        clearConnection()
        loaderState.client = client
        loaderState.connectionHealthy = true
        _G.RBA_URL = connectedUrl
        _G.RBA_HOST = connectedHost
        _G.RBA_PORT = connectedPort
        _G.RBA = makeBridge(client)
        _G.RBA.url = connectedUrl
        _G.RBA.host = connectedHost
        _G.RBA.port = connectedPort
        retrySeconds = RETRY_SECONDS
        _G.RBA.send({
            type = "hello",
            name = game.Name,
            placeId = game.PlaceId,
            gameId = game.GameId,
            jobId = game.JobId,
            connectedUrl = connectedUrl,
            connectedHost = connectedHost,
            connectedPort = connectedPort,
            candidateCount = #candidateUrls,
            capabilities = {
                protocol = PROTOCOL_VERSION,
                loaderVersion = LOADER_VERSION,
                unifiedRuntime = instanceManagerEnabled,
                instanceManagerBridge = getInstanceManagerHealth(),
                evalResponses = true,
                inspect = true,
                snapshot = true,
                trace = true,
                notifications = true,
                statusPanel = true,
                boundedExecutionQueue = true,
                singleInstanceLifecycle = true,
                heartbeat = true,
                maxIncomingBytes = MAX_INCOMING_BYTES,
                maxOutgoingBytes = MAX_OUTGOING_BYTES,
                maxQueuedEvals = MAX_QUEUED_EVALS,
                maxQueuedBytes = MAX_QUEUED_BYTES,
                maxConcurrentEvals = MAX_CONCURRENT_EVALS,
                evalTimeouts = true,
                duplicateRequestProtection = true,
                loadstring = type(loadstring or load) == "function"
            },
            at = os.time(),
            clock = os.clock()
        })

        print("[RBA] Connected to " .. connectedUrl)
        setStatusGui("Connected to " .. connectedUrl, Color3.fromRGB(74, 222, 128), STATUS_AUTO_HIDE_SECONDS)

        local closed = false
        loaderState.messageConnection = client.OnMessage:Connect(function(payload)
            local ok, messageError = xpcall(function()
                handlePayload(payload)
            end, traceback)
            if not ok then
                loaderState.droppedMessages = loaderState.droppedMessages + 1
                warn("[RBA] Message handler error:", messageError)
            end
        end)
        loaderState.closeConnection = client.OnClose:Connect(function()
            closed = true
            loaderState.connectionHealthy = false
        end)
        startHeartbeat(client, _G.RBA)

        while isCurrentLoader()
            and loaderState.client == client
            and loaderState.connectionHealthy
            and not closed do
            task.wait(0.25)
        end

        clearConnection()
        if _G.RBA and _G.RBA._generation == loaderState.generation then
            _G.RBA = nil
        end
        if isCurrentLoader() then
            print("[RBA] Disconnected; reconnecting...")
            setStatusGui("Disconnected; reconnecting to RBA bridge...", Color3.fromRGB(248, 113, 113))
        end
    else
        closeSocket(client)
        if not isCurrentLoader() then
            break
        end
        warn("[RBA] Could not connect to any local RBA websocket port")
        setStatusGui("No local RBA bridge found. Start rba_ws_start in your MCP client.", Color3.fromRGB(248, 113, 113))
        retrySeconds = math.min(retrySeconds * 2, MAX_RETRY_SECONDS)
    end

    waitWhileCurrent(retrySeconds + math.random() * 0.25)
end

loaderState.stop(loaderState.stopReason or "loader loop ended")
