-- RBA Auto Goalkeeper v8 - BEST MODE.
-- Standalone snapshot of the ping-aware, sprint-assisted controller.
-- Previous controller revision: v7.
--
-- RBA auto-goalkeeper experiment.
-- Predicts released-ball crossings and invokes the game's normal Leap action
-- on the local goalkeeper only. The controller runs until stopped or reloaded.

local RuntimeEnv = type(getgenv) == "function" and getgenv() or _G
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
assert(LocalPlayer, "Auto-goalkeeper requires a local player")

local previous = RuntimeEnv.__RBA_AUTO_GOALKEEPER
if type(previous) == "table" and type(previous.stop) == "function" then
    pcall(previous.stop, "reloaded")
end
if type(previous) == "table" and previous.gui then
    pcall(function()
        previous.gui:Destroy()
    end)
end

local config = type(RuntimeEnv.RBA_AUTO_GOALKEEPER_CONFIG) == "table"
    and RuntimeEnv.RBA_AUTO_GOALKEEPER_CONFIG
    or {}

local UPDATE_HZ = math.clamp(tonumber(config.updateHz) or 30, 10, 60)
local MAX_PREDICTION_SECONDS = math.clamp(tonumber(config.maxPredictionSeconds) or 2.5, 0.5, 5)
local TRIGGER_LEAD_SECONDS = math.clamp(tonumber(config.triggerLeadSeconds) or 1.08, 0.2, 1.5)
local CENTER_DIVE_THRESHOLD = math.clamp(tonumber(config.centerDiveThreshold) or 2.25, 0.5, 6)
local GOAL_MARGIN = math.clamp(tonumber(config.goalMargin) or 1.25, 0, 4)
local BALL_RESTITUTION = math.clamp(tonumber(config.ballRestitution) or 0.25, 0, 0.8)
local DEFAULT_BEST_MODE = config.bestMode ~= false
local DEFAULT_AUTO_DIVE = config.autoDive ~= false
local DEFAULT_WALK_ASSIST = config.walkAssist ~= false
local DEFAULT_AUTO_CLEAR = config.autoClear ~= false
local AUTO_CLEAR_SETTLE_SECONDS = math.clamp(
    tonumber(config.autoClearSettleSeconds) or 0.7,
    0.3,
    2
)
local AUTO_CLEAR_CHARGE_SECONDS = math.clamp(
    tonumber(config.autoClearChargeSeconds) or 0.32,
    0.12,
    0.8
)
local AUTO_CLEAR_COOLDOWN = math.clamp(
    tonumber(config.autoClearCooldown) or 3.5,
    2,
    10
)
local WALK_UPDATE_HZ = math.clamp(tonumber(config.walkUpdateHz) or 8, 2, 15)
local WALK_DEADZONE = math.clamp(tonumber(config.walkDeadzone) or 1.15, 0.5, 4)
local WALK_MAX_STEP = math.clamp(tonumber(config.walkMaxStep) or 7, 2, 12)
local GOALKEEPER_DEPTH = math.clamp(tonumber(config.goalkeeperDepth) or 3.5, 1, 8)
local DEFENSIVE_TRACK_DISTANCE = math.clamp(
    tonumber(config.defensiveTrackDistance) or 70,
    35,
    120
)
local DEPTH_CORRECTION_DISTANCE = math.clamp(
    tonumber(config.depthCorrectionDistance) or 32,
    15,
    60
)
local GOALKEEPER_DEPTH_TOLERANCE = math.clamp(
    tonumber(config.goalkeeperDepthTolerance) or 4.5,
    2,
    8
)
local LEARNING_RATE = math.clamp(tonumber(config.learningRate) or 0.22, 0.05, 0.5)
local MAX_LEARNED_BIAS_X = math.clamp(tonumber(config.maxLearnedBiasX) or 4, 1, 8)
local MAX_LEARNED_BIAS_Y = math.clamp(tonumber(config.maxLearnedBiasY) or 3, 1, 6)
local MIN_PREDICTION_CONFIDENCE = math.clamp(
    tonumber(config.minPredictionConfidence) or 0.2,
    0.1,
    0.9
)
local MAX_DIVE_ATTEMPTS_PER_SHOT = math.clamp(
    math.floor(tonumber(config.maxDiveAttemptsPerShot) or 2),
    1,
    3
)
local DIVE_RETRY_COOLDOWN = math.clamp(
    tonumber(config.diveRetryCooldown) or 0.75,
    0.7,
    1.2
)
local PING_UPDATE_INTERVAL = math.clamp(
    tonumber(config.pingUpdateInterval) or 0.5,
    0.25,
    2
)
local PING_COMPENSATION_FACTOR = math.clamp(
    tonumber(config.pingCompensationFactor) or 0.5,
    0.25,
    1
)
local MAX_PING_COMPENSATION = math.clamp(
    tonumber(config.maxPingCompensation) or 0.35,
    0.1,
    0.6
)
local MAX_ANTICIPATION_SECONDS = math.clamp(
    tonumber(config.maxAnticipationSeconds) or 5,
    2.5,
    8
)
local SPRINT_START_DISTANCE = math.clamp(
    tonumber(config.sprintStartDistance) or 8,
    5,
    16
)
local SPRINT_STOP_DISTANCE = math.clamp(
    tonumber(config.sprintStopDistance) or 3.5,
    2,
    8
)
local DEBUG_LOGS = config.debugLogs ~= false

local FootballDefaults = require(ReplicatedStorage.Shared.Defaults.Football)
local MovementDefaults = require(ReplicatedStorage.Shared.Defaults.Movement)
local Leap = require(LocalPlayer.PlayerScripts.Client.Controllers.Actions.Managers.Leap)
local ActionPrimary = require(
    LocalPlayer.PlayerScripts.Client.Controllers.Actions.Managers.ActionPrimary
)
local PrepareShot = require(
    LocalPlayer.PlayerScripts.Client.Controllers.Actions.Managers.PrepareShot
)
local Sprint = require(LocalPlayer.PlayerScripts.Client.Controllers.Actions.Managers.Sprint)
local Knit = require(ReplicatedStorage.Packages.Knit)
local MovementController = Knit.GetController("MovementController")

local state = {
    version = 8,
    confirmationMode = "heartbeat",
    running = true,
    phase = "ACQUIRE",
    bestMode = DEFAULT_BEST_MODE,
    autoDive = DEFAULT_BEST_MODE or DEFAULT_AUTO_DIVE,
    walkAssist = DEFAULT_BEST_MODE or DEFAULT_WALK_ASSIST,
    autoClear = DEFAULT_BEST_MODE or DEFAULT_AUTO_CLEAR,
    walking = false,
    walkMode = "CENTER",
    sprinting = false,
    sprintStarts = 0,
    sprintStops = 0,
    walkTarget = nil,
    movementCommands = 0,
    lastMoveAt = 0,
    possessionStartedAt = nil,
    pendingClear = nil,
    clearAttempts = 0,
    clears = 0,
    lastClearAt = 0,
    clearStatus = "READY",
    incoming = nil,
    physicsCache = {
        ball = nil,
        gravity = Workspace.Gravity,
        updatedAt = 0
    },
    network = {
        pingSeconds = 0,
        jitterSeconds = 0,
        compensationSeconds = 0,
        source = "unavailable",
        samples = 0,
        lastUpdatedAt = 0
    },
    startedAt = os.clock(),
    connection = nil,
    stopReason = nil,
    samples = 0,
    predictions = 0,
    threats = 0,
    diveAttempts = 0,
    dives = 0,
    lastDiveAt = nil,
    lastDiveAttemptAt = 0,
    diveActiveUntil = 0,
    lastDiveDirection = nil,
    lastDiveToken = nil,
    pendingDive = nil,
    lastPrediction = nil,
    lastError = nil,
    activeShot = nil,
    learning = {
        calibratedShots = 0,
        completedShots = 0,
        saves = 0,
        failedSaves = 0,
        biasX = 0,
        biasY = 0,
        meanError = 0,
        leadAdjustment = 0,
        startupSeconds = 0.02,
        timingSamples = 0,
        lastTimingError = 0
    },
    status = "INITIALIZING",
    team = nil,
    role = nil,
    ballState = "Searching",
    gui = nil,
    controls = {},
    lastGuiUpdateAt = 0,
    events = {}
}
RuntimeEnv.__RBA_AUTO_GOALKEEPER = state

local function safeText(value)
    local ok, result = pcall(tostring, value)
    return ok and result or "<unprintable>"
end

local function log(message)
    if not DEBUG_LOGS then
        return
    end
    print("[RBA AutoGK] " .. safeText(message))
end

local function addEvent(kind, data)
    table.insert(state.events, {
        kind = kind,
        at = os.clock(),
        data = data
    })
    while #state.events > 30 do
        table.remove(state.events, 1)
    end
end

local function isHumanoidUsable(humanoid)
    if not humanoid or not humanoid.Parent then
        return false
    end
    if LocalPlayer:GetAttribute("IsOnPitch") == false then
        return false
    end
    return humanoid:GetState() ~= Enum.HumanoidStateType.Dead
end

local function normalizePingSeconds(value)
    local numeric = tonumber(value)
    if not numeric or numeric <= 0 then
        return nil
    end
    if numeric > 10 then
        numeric = numeric / 1000
    end
    if numeric < 0.005 or numeric > 2 then
        return nil
    end
    return numeric
end

local function readPingSample()
    local attributePing = normalizePingSeconds(LocalPlayer:GetAttribute("Ping"))
    local statsPing
    pcall(function()
        local network = Stats:FindFirstChild("Network")
        local serverItems = network and network:FindFirstChild("ServerStatsItem")
        local dataPing = serverItems and serverItems:FindFirstChild("Data Ping")
        if dataPing then
            statsPing = normalizePingSeconds(dataPing:GetValue())
        end
    end)

    if attributePing and statsPing then
        return math.max(attributePing, statsPing), "attribute+data"
    end
    if attributePing then
        return attributePing, "attribute"
    end
    if statsPing then
        return statsPing, "data"
    end
    return nil, "unavailable"
end

local function updateNetworkTiming(force)
    local nowClock = os.clock()
    local network = state.network
    if not force and nowClock - network.lastUpdatedAt < PING_UPDATE_INTERVAL then
        return
    end
    network.lastUpdatedAt = nowClock

    local sample, source = readPingSample()
    if not sample then
        return
    end

    if network.samples == 0 then
        network.pingSeconds = sample
        network.jitterSeconds = 0
    else
        local deviation = math.abs(sample - network.pingSeconds)
        network.jitterSeconds = network.jitterSeconds
            + (deviation - network.jitterSeconds) * 0.18
        network.pingSeconds = network.pingSeconds
            + (sample - network.pingSeconds) * 0.2
    end
    network.samples = network.samples + 1
    network.source = source
    network.compensationSeconds = math.clamp(
        network.pingSeconds * PING_COMPENSATION_FACTOR
            + network.jitterSeconds
            + 2 / UPDATE_HZ,
        0.025,
        MAX_PING_COMPENSATION
    )
end

local renderGui
local stopWalking
local stopSprinting
local releaseToken
local mapGoalPoint
local getBallKinematics

local function createInstance(className, properties, parent)
    local instance = Instance.new(className)
    for property, value in pairs(properties or {}) do
        instance[property] = value
    end
    instance.Parent = parent
    return instance
end

local function addCorner(parent, radius)
    return createInstance("UICorner", {
        CornerRadius = UDim.new(0, radius)
    }, parent)
end

local function addStroke(parent, color, transparency)
    return createInstance("UIStroke", {
        Color = color,
        Transparency = transparency or 0,
        Thickness = 1
    }, parent)
end

local function createLabel(parent, name, position, size, text, textSize, color, font)
    return createInstance("TextLabel", {
        Name = name,
        BackgroundTransparency = 1,
        Position = position,
        Size = size,
        Font = font or Enum.Font.Gotham,
        Text = text,
        TextColor3 = color or Color3.fromRGB(210, 218, 232),
        TextSize = textSize or 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center
    }, parent)
end

local function createMetric(parent, name, x, y, width)
    local container = createInstance("Frame", {
        Name = name,
        BackgroundColor3 = Color3.fromRGB(20, 27, 41),
        BackgroundTransparency = 0.18,
        Position = UDim2.fromOffset(x, y),
        Size = UDim2.fromOffset(width, 27),
        BorderSizePixel = 0
    }, parent)
    addCorner(container, 6)
    addStroke(container, Color3.fromRGB(58, 72, 96), 0.62)

    createLabel(
        container,
        "Key",
        UDim2.fromOffset(9, 1),
        UDim2.new(0.42, -9, 1, -2),
        string.upper(name),
        9,
        Color3.fromRGB(115, 130, 154),
        Enum.Font.GothamSemibold
    )
    return createLabel(
        container,
        "Value",
        UDim2.new(0.42, 0, 0, 1),
        UDim2.new(0.58, -9, 1, -2),
        "--",
        11,
        Color3.fromRGB(232, 238, 248),
        Enum.Font.GothamMedium
    )
end

local function resolveGuiParent()
    local parent
    if type(gethui) == "function" then
        pcall(function()
            parent = gethui()
        end)
    end
    if not parent then
        pcall(function()
            parent = game:GetService("CoreGui")
        end)
    end
    if not parent then
        parent = LocalPlayer:FindFirstChildOfClass("PlayerGui")
            or LocalPlayer:WaitForChild("PlayerGui", 5)
    end
    return parent
end

local function createGui()
    local parent = resolveGuiParent()
    if not parent then
        state.lastError = "No supported GUI parent was available"
        return nil
    end

    local oldGui = parent:FindFirstChild("RBAAutoGoalkeeperGui")
    if oldGui then
        oldGui:Destroy()
    end

    local screen = createInstance("ScreenGui", {
        Name = "RBAAutoGoalkeeperGui",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        DisplayOrder = 1000,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    }, parent)

    local panel = createInstance("Frame", {
        Name = "Panel",
        Active = true,
        Draggable = true,
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -18, 0, 86),
        Size = UDim2.fromOffset(370, 531),
        BackgroundColor3 = Color3.fromRGB(10, 15, 25),
        BackgroundTransparency = 0.08,
        BorderSizePixel = 0
    }, screen)
    addCorner(panel, 12)
    addStroke(panel, Color3.fromRGB(80, 105, 145), 0.35)

    createInstance("UIGradient", {
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(20, 30, 49)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(9, 14, 23))
        }),
        Rotation = 90
    }, panel)

    local header = createInstance("Frame", {
        Name = "Header",
        BackgroundColor3 = Color3.fromRGB(27, 44, 70),
        BackgroundTransparency = 0.22,
        Position = UDim2.fromOffset(1, 1),
        Size = UDim2.new(1, -2, 0, 52),
        BorderSizePixel = 0
    }, panel)
    addCorner(header, 11)

    createLabel(
        header,
        "Title",
        UDim2.fromOffset(14, 7),
        UDim2.fromOffset(230, 20),
        "AUTO GK  //  TRAJECTORY",
        14,
        Color3.fromRGB(244, 248, 255),
        Enum.Font.GothamBold
    )
    local subtitle = createLabel(
        header,
        "Subtitle",
        UDim2.fromOffset(14, 27),
        UDim2.fromOffset(230, 17),
        "Adaptive physics and movement telemetry",
        10,
        Color3.fromRGB(134, 153, 181),
        Enum.Font.GothamMedium
    )

    local livePill = createInstance("Frame", {
        Name = "LivePill",
        BackgroundColor3 = Color3.fromRGB(66, 211, 146),
        BackgroundTransparency = 0.85,
        Position = UDim2.new(1, -101, 0, 13),
        Size = UDim2.fromOffset(84, 26),
        BorderSizePixel = 0
    }, header)
    addCorner(livePill, 13)
    local liveDot = createInstance("Frame", {
        Name = "Dot",
        BackgroundColor3 = Color3.fromRGB(66, 211, 146),
        Position = UDim2.fromOffset(10, 9),
        Size = UDim2.fromOffset(8, 8),
        BorderSizePixel = 0
    }, livePill)
    addCorner(liveDot, 4)
    local liveText = createLabel(
        livePill,
        "Text",
        UDim2.fromOffset(25, 1),
        UDim2.new(1, -30, 1, -2),
        "ARMED",
        10,
        Color3.fromRGB(117, 239, 187),
        Enum.Font.GothamBold
    )

    local statusBanner = createInstance("Frame", {
        Name = "StatusBanner",
        BackgroundColor3 = Color3.fromRGB(40, 120, 180),
        BackgroundTransparency = 0.82,
        Position = UDim2.fromOffset(12, 63),
        Size = UDim2.new(1, -24, 0, 37),
        BorderSizePixel = 0
    }, panel)
    addCorner(statusBanner, 7)
    local statusText = createLabel(
        statusBanner,
        "Text",
        UDim2.fromOffset(11, 1),
        UDim2.new(1, -22, 1, -2),
        "INITIALIZING",
        11,
        Color3.fromRGB(153, 216, 255),
        Enum.Font.GothamSemibold
    )

    local metricWidth = 167
    local controls = {
        subtitle = subtitle,
        livePill = livePill,
        liveDot = liveDot,
        liveText = liveText,
        statusBanner = statusBanner,
        statusText = statusText,
        team = createMetric(panel, "Team", 12, 110, metricWidth),
        role = createMetric(panel, "Role", 191, 110, metricWidth),
        ball = createMetric(panel, "Ball", 12, 143, metricWidth),
        eta = createMetric(panel, "ETA", 191, 143, metricWidth),
        target = createMetric(panel, "Target", 12, 176, metricWidth),
        direction = createMetric(panel, "Direction", 191, 176, metricWidth),
        reach = createMetric(panel, "Reach", 12, 209, metricWidth),
        movement = createMetric(panel, "Movement", 191, 209, metricWidth),
        learning = createMetric(panel, "Learning", 12, 242, metricWidth),
        counters = createMetric(panel, "Counters", 191, 242, metricWidth)
    }

    createLabel(
        panel,
        "GoalLabel",
        UDim2.fromOffset(13, 277),
        UDim2.new(1, -26, 0, 16),
        "GOAL-MOUTH INTERCEPT",
        9,
        Color3.fromRGB(112, 129, 153),
        Enum.Font.GothamSemibold
    )
    local goalTrack = createInstance("Frame", {
        Name = "GoalTrack",
        BackgroundColor3 = Color3.fromRGB(27, 37, 55),
        Position = UDim2.fromOffset(13, 297),
        Size = UDim2.new(1, -26, 0, 64),
        BorderSizePixel = 0,
        ClipsDescendants = true
    }, panel)
    addCorner(goalTrack, 5)
    addStroke(goalTrack, Color3.fromRGB(77, 95, 123), 0.45)

    local goalCenter = createInstance("Frame", {
        Name = "Center",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0, 0),
        Size = UDim2.new(0, 1, 1, 0),
        BackgroundColor3 = Color3.fromRGB(83, 101, 128),
        BackgroundTransparency = 0.48,
        BorderSizePixel = 0
    }, goalTrack)
    local goalMidline = createInstance("Frame", {
        Name = "Midline",
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = Color3.fromRGB(83, 101, 128),
        BackgroundTransparency = 0.68,
        BorderSizePixel = 0
    }, goalTrack)
    local trackState = createLabel(
        goalTrack,
        "TrackState",
        UDim2.fromOffset(8, 0),
        UDim2.new(1, -16, 1, 0),
        "NO INCOMING SHOT",
        9,
        Color3.fromRGB(112, 129, 153),
        Enum.Font.GothamSemibold
    )
    trackState.TextXAlignment = Enum.TextXAlignment.Center
    trackState.ZIndex = 2
    local reachZone = createInstance("Frame", {
        Name = "ReachZone",
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, -2),
        Size = UDim2.new(0, 0, 0, 10),
        BackgroundColor3 = Color3.fromRGB(76, 166, 232),
        BackgroundTransparency = 0.78,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 1
    }, goalTrack)
    addCorner(reachZone, 5)
    local interceptLine = createInstance("Frame", {
        Name = "InterceptLine",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.fromOffset(0, 2),
        BackgroundColor3 = Color3.fromRGB(66, 185, 255),
        BackgroundTransparency = 0.28,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 2
    }, goalTrack)
    addCorner(interceptLine, 1)
    local rawMarker = createInstance("Frame", {
        Name = "RawPrediction",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.fromOffset(7, 7),
        Rotation = 45,
        BackgroundColor3 = Color3.fromRGB(171, 183, 203),
        BackgroundTransparency = 0.22,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 3
    }, goalTrack)
    local goalMarker = createInstance("Frame", {
        Name = "Prediction",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.fromOffset(11, 11),
        BackgroundColor3 = Color3.fromRGB(66, 185, 255),
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 4
    }, goalTrack)
    addCorner(goalMarker, 5)
    addStroke(goalMarker, Color3.fromRGB(225, 244, 255), 0.18)
    local keeperMarker = createInstance("Frame", {
        Name = "Keeper",
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, -2),
        Size = UDim2.fromOffset(5, 16),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BorderSizePixel = 0,
        ZIndex = 5
    }, goalTrack)
    addCorner(keeperMarker, 2)

    local urgencyTrack = createInstance("Frame", {
        Name = "UrgencyTrack",
        BackgroundColor3 = Color3.fromRGB(26, 35, 51),
        Position = UDim2.fromOffset(13, 369),
        Size = UDim2.new(1, -26, 0, 5),
        BorderSizePixel = 0
    }, panel)
    addCorner(urgencyTrack, 3)
    local urgencyFill = createInstance("Frame", {
        Name = "Fill",
        BackgroundColor3 = Color3.fromRGB(66, 185, 255),
        Size = UDim2.new(0, 0, 1, 0),
        BorderSizePixel = 0
    }, urgencyTrack)
    addCorner(urgencyFill, 3)

    local detailText = createLabel(
        panel,
        "Detail",
        UDim2.fromOffset(13, 378),
        UDim2.new(1, -26, 0, 18),
        "Waiting for a released football...",
        10,
        Color3.fromRGB(126, 143, 168),
        Enum.Font.Code
    )

    local bestButton = createInstance("TextButton", {
        Name = "BestButton",
        BackgroundColor3 = Color3.fromRGB(104, 62, 159),
        BackgroundTransparency = 0.05,
        Position = UDim2.fromOffset(13, 411),
        Size = UDim2.fromOffset(344, 29),
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = "BEST MODE: ON  //  PING + SPRINT + ADAPTIVE",
        TextColor3 = Color3.fromRGB(242, 226, 255),
        TextSize = 9
    }, panel)
    addCorner(bestButton, 7)
    addStroke(bestButton, Color3.fromRGB(177, 118, 232), 0.42)

    local autoButton = createInstance("TextButton", {
        Name = "AutoButton",
        BackgroundColor3 = Color3.fromRGB(31, 116, 91),
        BackgroundTransparency = 0.08,
        Position = UDim2.fromOffset(13, 449),
        Size = UDim2.fromOffset(106, 29),
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = "AUTO DIVE: ON",
        TextColor3 = Color3.fromRGB(220, 255, 242),
        TextSize = 9
    }, panel)
    addCorner(autoButton, 7)
    addStroke(autoButton, Color3.fromRGB(67, 198, 151), 0.5)

    local walkButton = createInstance("TextButton", {
        Name = "WalkButton",
        BackgroundColor3 = Color3.fromRGB(38, 89, 135),
        BackgroundTransparency = 0.08,
        Position = UDim2.fromOffset(126, 449),
        Size = UDim2.fromOffset(106, 29),
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = "WALK: ON",
        TextColor3 = Color3.fromRGB(213, 237, 255),
        TextSize = 9
    }, panel)
    addCorner(walkButton, 7)
    addStroke(walkButton, Color3.fromRGB(86, 170, 232), 0.5)

    local clearButton = createInstance("TextButton", {
        Name = "ClearButton",
        BackgroundColor3 = Color3.fromRGB(113, 76, 31),
        BackgroundTransparency = 0.08,
        Position = UDim2.fromOffset(239, 449),
        Size = UDim2.fromOffset(118, 29),
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = "AUTO CLEAR: ON",
        TextColor3 = Color3.fromRGB(255, 231, 190),
        TextSize = 9
    }, panel)
    addCorner(clearButton, 7)
    addStroke(clearButton, Color3.fromRGB(224, 164, 79), 0.5)

    local stopButton = createInstance("TextButton", {
        Name = "StopButton",
        BackgroundColor3 = Color3.fromRGB(98, 42, 55),
        BackgroundTransparency = 0.08,
        Position = UDim2.fromOffset(13, 487),
        Size = UDim2.fromOffset(344, 29),
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = "STOP TEST",
        TextColor3 = Color3.fromRGB(255, 215, 222),
        TextSize = 10
    }, panel)
    addCorner(stopButton, 7)
    addStroke(stopButton, Color3.fromRGB(214, 87, 111), 0.52)

    controls.goalCenter = goalCenter
    controls.goalMidline = goalMidline
    controls.trackState = trackState
    controls.reachZone = reachZone
    controls.interceptLine = interceptLine
    controls.rawMarker = rawMarker
    controls.goalMarker = goalMarker
    controls.keeperMarker = keeperMarker
    controls.urgencyFill = urgencyFill
    controls.detailText = detailText
    controls.bestButton = bestButton
    controls.autoButton = autoButton
    controls.walkButton = walkButton
    controls.clearButton = clearButton
    controls.stopButton = stopButton
    state.controls = controls
    state.gui = screen

    bestButton.MouseButton1Click:Connect(function()
        if not state.running then
            return
        end
        state.bestMode = not state.bestMode
        if state.bestMode then
            state.autoDive = true
            state.walkAssist = true
            state.autoClear = true
        else
            stopSprinting("best mode disabled")
        end
        addEvent("best_mode_changed", { enabled = state.bestMode })
        if renderGui then
            renderGui(true)
        end
    end)
    autoButton.MouseButton1Click:Connect(function()
        if not state.running then
            return
        end
        state.bestMode = false
        state.autoDive = not state.autoDive
        addEvent("mode_changed", { autoDive = state.autoDive })
        if renderGui then
            renderGui(true)
        end
    end)
    walkButton.MouseButton1Click:Connect(function()
        if not state.running then
            return
        end
        state.bestMode = false
        state.walkAssist = not state.walkAssist
        if not state.walkAssist and stopWalking then
            stopWalking("disabled from GUI")
        end
        addEvent("mode_changed", {
            autoDive = state.autoDive,
            walkAssist = state.walkAssist
        })
        if renderGui then
            renderGui(true)
        end
    end)
    clearButton.MouseButton1Click:Connect(function()
        if not state.running then
            return
        end
        state.bestMode = false
        state.autoClear = not state.autoClear
        if not state.autoClear and state.pendingClear then
            pcall(PrepareShot.CancelPreparedShot)
            state.pendingClear = nil
            state.clearStatus = "CLEAR OFF"
        end
        addEvent("mode_changed", {
            autoDive = state.autoDive,
            walkAssist = state.walkAssist,
            autoClear = state.autoClear
        })
        if renderGui then
            renderGui(true)
        end
    end)
    stopButton.MouseButton1Click:Connect(function()
        state.stop("stopped from GUI")
    end)

    return screen
end

renderGui = function(force)
    if not state.gui or not state.gui.Parent then
        return
    end
    local nowClock = os.clock()
    if not force and nowClock - state.lastGuiUpdateAt < 0.1 then
        return
    end
    state.lastGuiUpdateAt = nowClock

    local controls = state.controls
    local pingMs = math.floor(state.network.pingSeconds * 1000 + 0.5)
    local compensationMs = math.floor(
        state.network.compensationSeconds * 1000 + 0.5
    )
    controls.subtitle.Text = state.bestMode
        and string.format("BEST // PING %dms // COMP +%dms", pingMs, compensationMs)
        or (state.autoDive and "Adaptive dive response // running"
            or "Prediction-only telemetry // running")

    local statusColor = Color3.fromRGB(66, 185, 255)
    local statusTextColor = Color3.fromRGB(153, 216, 255)
    local liveLabel = state.bestMode and "BEST" or state.autoDive and "ARMED" or "OBSERVE"
    if not state.running then
        statusColor = Color3.fromRGB(119, 128, 148)
        statusTextColor = Color3.fromRGB(185, 193, 207)
        liveLabel = "STOPPED"
    elseif state.status == "THREAT" or state.status == "DIVING" then
        statusColor = Color3.fromRGB(255, 91, 113)
        statusTextColor = Color3.fromRGB(255, 188, 198)
        liveLabel = state.status
    elseif state.status == "STANDBY" or state.status == "OUT OF REACH" then
        statusColor = Color3.fromRGB(245, 181, 66)
        statusTextColor = Color3.fromRGB(255, 221, 155)
        liveLabel = "STANDBY"
    elseif state.status == "WAITING FOR SHOT" then
        statusColor = Color3.fromRGB(69, 211, 148)
        statusTextColor = Color3.fromRGB(142, 241, 195)
    end

    controls.livePill.BackgroundColor3 = statusColor
    controls.liveDot.BackgroundColor3 = statusColor
    controls.liveText.TextColor3 = statusTextColor
    controls.liveText.Text = liveLabel
    controls.statusBanner.BackgroundColor3 = statusColor
    controls.statusText.TextColor3 = statusTextColor
    controls.statusText.Text = state.running
        and (safeText(state.phase) .. "  //  " .. safeText(state.status))
        or ("STOPPED  //  " .. safeText(state.stopReason or "inactive"))

    controls.team.Text = safeText(state.team or "--")
    controls.role.Text = safeText(state.role or "--")
    controls.ball.Text = safeText(state.ballState or "Searching")
    controls.counters.Text = string.format(
        "%dP/%dT/%dD/%dC",
        state.predictions,
        state.threats,
        state.dives,
        state.clears
    )
    controls.movement.Text = LocalPlayer:GetAttribute("HasBall") == true
        and safeText(state.clearStatus)
        or (state.walkAssist
            and (state.walking
                and ((state.sprinting and "SPRINT " or "") .. safeText(state.walkMode))
                or "READY")
            or "OFF")
    controls.learning.Text = string.format(
        "%dS / %.1fE",
        state.learning.calibratedShots,
        state.learning.meanError
    )

    local prediction = state.lastPrediction
    if prediction then
        controls.eta.Text = string.format("%.3fs", prediction.secondsToGoal)
        controls.target.Text = string.format("X %.1f  Y %.1f", prediction.intercept.X, prediction.intercept.Y)
        controls.direction.Text = safeText(prediction.direction)
        controls.reach.Text = string.format("%.1f / %.1f", prediction.horizontalDistance, prediction.maxReach)
        controls.detailText.Text = string.format(
            "%s // CONF %d%% // JITTER %.2f",
            prediction.insideGoal and "ON TARGET" or "OUTSIDE GOAL",
            math.floor((prediction.confidence or 0) * 100 + 0.5),
            prediction.jitter or 0
        )

        local xRatio, yRatio = mapGoalPoint(
            prediction.intercept,
            state.lastGoal
        )
        local rawIntercept = prediction.rawIntercept or prediction.intercept
        local rawXRatio, rawYRatio = mapGoalPoint(
            rawIntercept,
            state.lastGoal
        )
        local goalWidth = 0
        if state.lastGoal then
            goalWidth = state.lastGoal.maxX - state.lastGoal.minX
        end

        controls.goalMarker.Position = UDim2.new(xRatio, 0, yRatio, 0)
        controls.goalMarker.BackgroundColor3 = statusColor
        controls.goalMarker.Visible = true
        controls.trackState.Visible = false
        controls.rawMarker.Position = UDim2.new(rawXRatio, 0, rawYRatio, 0)
        controls.rawMarker.Visible = true

        local keeperRatio = math.clamp(state.keeperGoalRatio or 0.5, 0, 1)
        controls.reachZone.Position = UDim2.new(keeperRatio, 0, 1, -2)
        controls.reachZone.Size = UDim2.new(
            goalWidth > 0 and math.clamp(prediction.maxReach * 2 / goalWidth, 0, 1) or 0,
            0,
            0,
            10
        )
        controls.reachZone.Visible = goalWidth > 0

        local trackSize = controls.goalMarker.Parent.AbsoluteSize
        if trackSize.X > 0 and trackSize.Y > 0 then
            local startX = keeperRatio * trackSize.X
            local startY = trackSize.Y - 5
            local endX = xRatio * trackSize.X
            local endY = yRatio * trackSize.Y
            local deltaX = endX - startX
            local deltaY = endY - startY
            local lineLength = math.sqrt(deltaX * deltaX + deltaY * deltaY)
            controls.interceptLine.Position = UDim2.fromOffset(
                (startX + endX) / 2,
                (startY + endY) / 2
            )
            controls.interceptLine.Size = UDim2.fromOffset(lineLength, 2)
            controls.interceptLine.Rotation = math.deg(math.atan2(deltaY, deltaX))
            controls.interceptLine.BackgroundColor3 = statusColor
            controls.interceptLine.Visible = lineLength > 1
        else
            controls.interceptLine.Visible = false
        end

        controls.urgencyFill.BackgroundColor3 = statusColor
        controls.urgencyFill.Size = UDim2.new(
            math.clamp(1 - prediction.secondsToGoal / MAX_PREDICTION_SECONDS, 0, 1),
            0,
            1,
            0
        )
    else
        controls.eta.Text = "--"
        controls.target.Text = "--"
        controls.direction.Text = "--"
        controls.reach.Text = "--"
        controls.detailText.Text = state.running
            and "Waiting for a released football..."
            or safeText(state.stopReason or "Test stopped")
        controls.goalMarker.Visible = false
        controls.trackState.Text = safeText(state.status or "NO INCOMING SHOT")
        controls.trackState.Visible = true
        controls.rawMarker.Visible = false
        controls.reachZone.Visible = false
        controls.interceptLine.Visible = false
        controls.urgencyFill.Size = UDim2.new(0, 0, 1, 0)
    end

    if state.lastGoal and state.keeperGoalRatio then
        controls.keeperMarker.Position = UDim2.new(
            math.clamp(state.keeperGoalRatio, 0, 1),
            0,
            1,
            -2
        )
    end
    controls.bestButton.Text = state.bestMode
        and "BEST MODE: ON  //  PING + SPRINT + ADAPTIVE"
        or "BEST MODE: OFF  //  MANUAL FEATURE TOGGLES"
    controls.bestButton.BackgroundColor3 = state.bestMode
        and Color3.fromRGB(104, 62, 159)
        or Color3.fromRGB(54, 59, 72)
    controls.autoButton.Text = state.autoDive and "AUTO DIVE: ON" or "PREDICTION ONLY"
    controls.autoButton.BackgroundColor3 = state.autoDive
        and Color3.fromRGB(31, 116, 91)
        or Color3.fromRGB(42, 75, 112)
    controls.walkButton.Text = state.walkAssist and "WALK: ON" or "WALK: OFF"
    controls.walkButton.BackgroundColor3 = state.walkAssist
        and Color3.fromRGB(38, 89, 135)
        or Color3.fromRGB(54, 59, 72)
    controls.clearButton.Text = state.autoClear and "AUTO CLEAR: ON" or "AUTO CLEAR: OFF"
    controls.clearButton.BackgroundColor3 = state.autoClear
        and Color3.fromRGB(113, 76, 31)
        or Color3.fromRGB(54, 59, 72)
    controls.stopButton.Text = state.running and "STOP TEST" or "STOPPED"
end

function state.stop(reason)
    if not state.running then
        return
    end
    state.running = false
    state.stopReason = safeText(reason or "stopped")
    if state.pendingClear then
        pcall(PrepareShot.CancelPreparedShot)
        state.pendingClear = nil
    end
    if stopWalking then
        stopWalking("controller stopped")
    end
    if state.connection then
        pcall(function()
            state.connection:Disconnect()
        end)
        state.connection = nil
    end
    state.status = "STOPPED"
    if renderGui then
        renderGui(true)
    end
    log("Stopped: " .. state.stopReason)
end

function state.health()
    return {
        version = state.version,
        confirmationMode = state.confirmationMode,
        running = state.running,
        phase = state.phase,
        bestMode = state.bestMode,
        autoDive = state.autoDive,
        walkAssist = state.walkAssist,
        autoClear = state.autoClear,
        walking = state.walking,
        walkMode = state.walkMode,
        sprinting = state.sprinting,
        sprintStarts = state.sprintStarts,
        sprintStops = state.sprintStops,
        walkTarget = state.walkTarget,
        movementCommands = state.movementCommands,
        clearAttempts = state.clearAttempts,
        clears = state.clears,
        clearStatus = state.clearStatus,
        pendingClear = state.pendingClear and {
            requestedAt = state.pendingClear.requestedAt,
            releasedAt = state.pendingClear.releasedAt
        } or nil,
        guiVisible = state.gui ~= nil and state.gui.Parent ~= nil,
        status = state.status,
        team = state.team,
        role = state.role,
        ballState = state.ballState,
        startedAt = state.startedAt,
        stopReason = state.stopReason,
        samples = state.samples,
        predictions = state.predictions,
        threats = state.threats,
        diveAttempts = state.diveAttempts,
        dives = state.dives,
        lastDiveAt = state.lastDiveAt,
        lastDiveDirection = state.lastDiveDirection,
        lastDiveToken = state.lastDiveToken,
        pendingDive = state.pendingDive and {
            direction = state.pendingDive.direction,
            token = state.pendingDive.token,
            requestedAt = state.pendingDive.requestedAt
        } or nil,
        activeShot = state.activeShot and {
            token = state.activeShot.token,
            startedAt = state.activeShot.startedAt,
            crossed = state.activeShot.crossed,
            diveAttempted = state.activeShot.diveAttempted
        } or nil,
        learning = state.learning,
        network = state.network,
        incoming = state.incoming,
        lastPrediction = state.lastPrediction,
        lastError = state.lastError,
        events = state.events
    }
end

local function findMatchBall(goal)
    local misc = Workspace:FindFirstChild("Misc")
    if not misc then
        return nil
    end

    local best
    local bestKinematics
    local bestScore = -math.huge
    for _, instance in ipairs(misc:GetChildren()) do
        if instance:IsA("BasePart")
            and instance:GetAttribute("State") ~= nil
            and instance:GetAttribute("Enabled") ~= false then
            local ballState = instance:GetAttribute("State")
            local score = ballState == "Released" and 500 or 100
            local kinematics
            if goal and ballState == "Released" then
                kinematics = getBallKinematics(instance, goal)
                local fieldDirection = goal.planeZ >= 0 and -1 or 1
                local fieldDepth = (kinematics.position.Z - goal.planeZ)
                    * fieldDirection
                local velocityTowardGoal = kinematics.velocity.Z
                    * fieldDirection < -1
                if fieldDepth >= -3 and velocityTowardGoal then
                    score = 10000 - math.abs(fieldDepth)
                elseif fieldDepth < -3 then
                    score = -1000 - math.abs(fieldDepth)
                else
                    score = 300 - math.abs(fieldDepth)
                end
            end
            if score > bestScore then
                best = instance
                bestKinematics = kinematics
                bestScore = score
            end
        end
    end
    return best, bestKinematics
end

local function getGoalGeometry()
    local teamName = LocalPlayer:GetAttribute("IsHomeOrAway")
    local stadium = Workspace:FindFirstChild("Stadium")
    local teams = stadium and stadium:FindFirstChild("Teams")
    local team = teams and teamName and teams:FindFirstChild(teamName)
    local goal = team and team:FindFirstChild("Goal")
    local bars = goal and goal:FindFirstChild("Bars")
    local top = bars and bars:FindFirstChild("Top")
    local left = bars and bars:FindFirstChild("Left")
    local right = bars and bars:FindFirstChild("Right")
    local hitbox = goal and goal:FindFirstChild("Hitbox")
    local interceptionHitbox = goal and goal:FindFirstChild("InterceptionHitbox")

    if not top or not left or not right or not hitbox then
        return nil
    end

    local mouthHitbox = interceptionHitbox or hitbox
    local postMinX = math.min(left.Position.X, right.Position.X)
    local postMaxX = math.max(left.Position.X, right.Position.X)
    local postAxis = left.Position - right.Position
    local hitboxMinX = mouthHitbox.Position.X - mouthHitbox.Size.X / 2
    local hitboxMaxX = mouthHitbox.Position.X + mouthHitbox.Size.X / 2
    local crossbarBottomY = top.Position.Y - top.Size.Y / 2
    return {
        team = teamName,
        goal = goal,
        planeZ = top.Position.Z,
        rightAxis = postAxis.Magnitude > 0 and postAxis.Unit or Vector3.xAxis,
        fieldDirection = Vector3.new(0, 0, top.Position.Z >= 0 and -1 or 1),
        centerX = (postMinX + postMaxX) / 2,
        minX = math.max(postMinX, hitboxMinX),
        maxX = math.min(postMaxX, hitboxMaxX),
        minY = mouthHitbox.Position.Y - mouthHitbox.Size.Y / 2,
        maxY = math.min(
            crossbarBottomY,
            mouthHitbox.Position.Y + mouthHitbox.Size.Y / 2
        )
    }
end

mapGoalPoint = function(position, goal)
    if not position or not goal then
        return 0.5, 0.5
    end
    local width = goal.maxX - goal.minX
    local height = goal.maxY - goal.minY
    local xRatio = width > 0
        and math.clamp((position.X - goal.minX) / width, 0, 1)
        or 0.5
    local yRatio = height > 0
        and 1 - math.clamp((position.Y - goal.minY) / height, 0, 1)
        or 0.5
    return xRatio, yRatio
end

function state.goalDisplayHealth()
    local goal = getGoalGeometry()
    local controls = state.controls
    if not goal then
        return {
            ready = false,
            error = "Goal geometry is unavailable"
        }
    end

    local minX, floorY = mapGoalPoint(
        Vector3.new(goal.minX, goal.minY, goal.planeZ),
        goal
    )
    local maxX, crossbarY = mapGoalPoint(
        Vector3.new(goal.maxX, goal.maxY, goal.planeZ),
        goal
    )
    return {
        ready = controls.goalMarker ~= nil
            and controls.rawMarker ~= nil
            and controls.interceptLine ~= nil
            and controls.reachZone ~= nil,
        planeZ = goal.planeZ,
        width = goal.maxX - goal.minX,
        height = goal.maxY - goal.minY,
        mapping = {
            minX = minX,
            maxX = maxX,
            floorY = floorY,
            crossbarY = crossbarY
        },
        trackSize = controls.goalMarker
            and controls.goalMarker.Parent.AbsoluteSize
            or Vector2.zero
    }
end

local function getEffectiveBallGravity(ball)
    local cache = state.physicsCache
    local nowClock = os.clock()
    if cache.ball == ball and nowClock - cache.updatedAt < 0.5 then
        return cache.gravity
    end

    local mass = math.max(ball.AssemblyMass, 0.001)
    local upwardForce = 0
    for _, descendant in ipairs(ball:GetDescendants()) do
        if descendant:IsA("VectorForce") and descendant.Enabled then
            local force = descendant.Force
            if descendant.RelativeTo ~= Enum.ActuatorRelativeTo.World then
                local attachment = descendant.Attachment0
                if attachment then
                    force = attachment.WorldCFrame:VectorToWorldSpace(force)
                else
                    force = ball.CFrame:VectorToWorldSpace(force)
                end
            end
            upwardForce = upwardForce + force.Y
        end
    end

    local gravity = math.clamp(
        Workspace.Gravity - upwardForce / mass,
        0,
        Workspace.Gravity * 2
    )
    cache.ball = ball
    cache.gravity = gravity
    cache.updatedAt = nowClock
    return gravity
end

local function advanceBallState(ball, goal, position, velocity, duration)
    local gravity = getEffectiveBallGravity(ball)
    local dampingExponent = tonumber(FootballDefaults.VelocityDampening) or 0.755
    local groundCenterY = goal.minY + ball.Size.Y / 2
    local elapsed = 0
    while elapsed < duration do
        local step = math.min(1 / 120, duration - elapsed)
        local speed = velocity.Magnitude
        local damping = Vector3.zero
        if speed > 1 then
            damping = velocity.Unit * (speed ^ dampingExponent)
        elseif speed > 0 then
            damping = velocity
        end

        velocity = velocity
            + (Vector3.new(0, -gravity, 0) - damping) * step
        position = position + velocity * step
        if position.Y < groundCenterY then
            position = Vector3.new(position.X, groundCenterY, position.Z)
            if velocity.Y < 0 then
                local bounceVelocity = -velocity.Y * BALL_RESTITUTION
                velocity = Vector3.new(
                    velocity.X,
                    bounceVelocity >= 2 and bounceVelocity or 0,
                    velocity.Z
                )
            end
        end
        elapsed = elapsed + step
    end
    return position, velocity, gravity
end

getBallKinematics = function(ball, goal)
    local livePosition = ball.Position
    local liveVelocity = ball.AssemblyLinearVelocity
    local result = {
        position = livePosition,
        velocity = liveVelocity,
        livePosition = livePosition,
        liveVelocity = liveVelocity,
        liveCoherent = true,
        source = "live",
        releaseAge = nil,
        gravity = getEffectiveBallGravity(ball)
    }

    if ball:GetAttribute("State") ~= "Released" then
        return result
    end
    local releasePosition = ball:GetAttribute("ReleasePosition")
    local releaseVelocity = ball:GetAttribute("ReleaseVelocity")
    local releaseTime = tonumber(ball:GetAttribute("LastReleaseTime"))
    if typeof(releasePosition) ~= "Vector3"
        or typeof(releaseVelocity) ~= "Vector3"
        or not releaseTime then
        return result
    end

    local ok, serverNow = pcall(function()
        return Workspace:GetServerTimeNow()
    end)
    if not ok then
        return result
    end
    local releaseAge = serverNow - releaseTime
    if releaseAge < 0 or releaseAge > MAX_ANTICIPATION_SECONDS + 1 then
        return result
    end

    local seededPosition, seededVelocity, gravity = advanceBallState(
        ball,
        goal,
        releasePosition,
        releaseVelocity,
        releaseAge
    )
    local liveCoherent = livePosition.Y >= goal.minY - 8
        and liveVelocity.Magnitude >= 1
        and (livePosition - seededPosition).Magnitude <= 20
    local useReleaseState = releaseAge < 0.42 or not liveCoherent
    result.liveCoherent = liveCoherent
    result.releaseAge = releaseAge
    result.seededPosition = seededPosition
    result.seededVelocity = seededVelocity
    result.gravity = gravity
    if useReleaseState then
        result.position = seededPosition
        result.velocity = seededVelocity
        result.source = "release_attributes"
    end
    return result
end

local function isInsideGoal(position, goal)
    return position.X >= goal.minX - GOAL_MARGIN
        and position.X <= goal.maxX + GOAL_MARGIN
        and position.Y >= goal.minY - GOAL_MARGIN
        and position.Y <= goal.maxY + GOAL_MARGIN
end

local function classifyIncomingBall(ball, goal, kinematics)
    kinematics = kinematics or getBallKinematics(ball, goal)
    local fieldDirection = goal.planeZ >= 0 and -1 or 1
    local position = kinematics.position
    local velocity = kinematics.velocity
    local fieldDepth = (position.Z - goal.planeZ) * fieldDirection
    local closingSpeed = -velocity.Z * fieldDirection
    local released = ball:GetAttribute("State") == "Released"
    local secondsToPlane = closingSpeed > 1 and fieldDepth / closingSpeed or math.huge
    local incoming = released
        and fieldDepth >= -3
        and closingSpeed > 1
        and secondsToPlane >= 0
        and secondsToPlane <= MAX_ANTICIPATION_SECONDS

    local projectedX = position.X
    local projectedY = position.Y
    if incoming then
        projectedX = projectedX + velocity.X * secondsToPlane
        projectedY = projectedY
            + velocity.Y * secondsToPlane
            - 0.5 * kinematics.gravity
                * secondsToPlane * secondsToPlane
    end

    local corridorMargin = 16
    local likelyThreat = incoming
        and projectedX >= goal.minX - corridorMargin
        and projectedX <= goal.maxX + corridorMargin
    local urgency = incoming
        and math.clamp(1 - secondsToPlane / MAX_ANTICIPATION_SECONDS, 0, 1)
        or 0

    return {
        incoming = incoming,
        likelyThreat = likelyThreat,
        fieldDepth = fieldDepth,
        closingSpeed = closingSpeed,
        secondsToPlane = secondsToPlane < math.huge and secondsToPlane or nil,
        projectedX = projectedX,
        projectedY = projectedY,
        urgency = urgency,
        releaseToken = releaseToken(ball),
        source = kinematics.source,
        releaseAge = kinematics.releaseAge,
        liveCoherent = kinematics.liveCoherent
    }
end

local function effectiveLeadSeconds(horizontalDistance)
    local networkLead = state.bestMode and state.network.compensationSeconds or 0
    local leapLifetime = tonumber(MovementDefaults.Movers.LeapMoverLifetime) or 0.7
    local leapVelocity = tonumber(MovementDefaults.Movers.LeapMoverMaxVelocity) or 30
    local movementTime = horizontalDistance
        and math.clamp(horizontalDistance / leapVelocity, 0.08, leapLifetime)
        or math.min(0.25, leapLifetime)
    local computedLead = movementTime
        + networkLead
        + state.learning.startupSeconds
        + state.learning.leadAdjustment
    local maximumLead = math.min(
        TRIGGER_LEAD_SECONDS + networkLead,
        leapLifetime + networkLead + 0.15
    )
    return math.clamp(computedLead, 0.2, maximumLead), movementTime
end

local function calibrateFromCrossing(shot, actualPosition)
    local initial = shot.initialPrediction
    if not initial or not initial.rawPosition then
        return
    end

    local errorX = actualPosition.X - initial.rawPosition.X
    local errorY = actualPosition.Y - initial.rawPosition.Y
    local errorMagnitude = math.sqrt(errorX * errorX + errorY * errorY)
    local learning = state.learning

    learning.biasX = math.clamp(
        learning.biasX + (errorX - learning.biasX) * LEARNING_RATE,
        -MAX_LEARNED_BIAS_X,
        MAX_LEARNED_BIAS_X
    )
    learning.biasY = math.clamp(
        learning.biasY + (errorY - learning.biasY) * LEARNING_RATE,
        -MAX_LEARNED_BIAS_Y,
        MAX_LEARNED_BIAS_Y
    )
    learning.calibratedShots = learning.calibratedShots + 1
    learning.meanError = learning.calibratedShots == 1
        and errorMagnitude
        or learning.meanError + (errorMagnitude - learning.meanError) * LEARNING_RATE

    addEvent("model_calibrated", {
        token = shot.token,
        errorX = errorX,
        errorY = errorY,
        biasX = learning.biasX,
        biasY = learning.biasY,
        meanError = learning.meanError
    })
end

local function calibrateDiveTiming(shot, crossingAt)
    if not shot.diveStartedAt or not shot.diveTravelSeconds then
        return
    end
    local timingError = crossingAt
        - (shot.diveStartedAt + shot.diveTravelSeconds)
    if math.abs(timingError) > 1.5 then
        return
    end

    local learning = state.learning
    learning.timingSamples = learning.timingSamples + 1
    learning.lastTimingError = timingError
    learning.leadAdjustment = math.clamp(
        learning.leadAdjustment - timingError * 0.18,
        -0.18,
        0.2
    )
    addEvent("dive_timing_calibrated", {
        token = shot.token,
        timingError = timingError,
        leadAdjustment = learning.leadAdjustment
    })
end

local function completeShot(shot, result)
    if shot.completed then
        return
    end
    shot.completed = true
    state.learning.completedShots = state.learning.completedShots + 1

    if result == "save" then
        state.learning.saves = state.learning.saves + 1
    elseif result == "miss" and shot.diveAttempted then
        state.learning.failedSaves = state.learning.failedSaves + 1
    end

    addEvent("shot_completed", {
        token = shot.token,
        result = result,
        diveAttempted = shot.diveAttempted,
        leadSeconds = effectiveLeadSeconds()
    })
end

local function observeShot(ball, goal, kinematics, incoming)
    kinematics = kinematics or getBallKinematics(ball, goal)
    local ballState = ball:GetAttribute("State")
    local token = releaseToken(ball)
    local shot = state.activeShot

    if ballState ~= "Released" then
        if shot then
            local possessorId = ball:GetAttribute("PossessorId")
            local agentId = LocalPlayer:GetAttribute("AgentId")
            local localPossession = LocalPlayer:GetAttribute("HasBall") == true
                or (possessorId ~= nil and agentId ~= nil
                    and safeText(possessorId) == safeText(agentId))
            completeShot(shot, localPossession and "save" or "interrupted")
            state.activeShot = nil
        end
        return
    end

    if not shot or shot.token ~= token or shot.ball ~= ball then
        if shot then
            completeShot(shot, "superseded")
        end
        incoming = incoming or classifyIncomingBall(ball, goal, kinematics)
        if not incoming.incoming or not incoming.likelyThreat then
            state.activeShot = nil
            return
        end
        shot = {
            token = token,
            ball = ball,
            startedAt = os.clock(),
            previousPosition = kinematics.liveCoherent
                and kinematics.livePosition
                or nil,
            goalPlaneZ = goal.planeZ,
            crossed = false,
            completed = false,
            diveAttempted = false,
            initialPrediction = nil
        }
        state.activeShot = shot
        addEvent("shot_started", { token = token })
        return
    end

    if not kinematics.liveCoherent then
        shot.previousPosition = nil
        return
    end
    local previousPosition = shot.previousPosition
    local currentPosition = kinematics.livePosition
    shot.previousPosition = currentPosition
    if shot.crossed or not previousPosition then
        return
    end

    local previousSide = previousPosition.Z - goal.planeZ
    local currentSide = currentPosition.Z - goal.planeZ
    if previousSide ~= 0 and currentSide ~= 0 and previousSide * currentSide > 0 then
        return
    end
    if (currentPosition - previousPosition).Magnitude < 0.01 then
        return
    end
    local fieldDirection = goal.planeZ >= 0 and -1 or 1
    local travelledTowardGoal = (currentPosition.Z - previousPosition.Z)
        * fieldDirection < -0.01
    if not travelledTowardGoal then
        return
    end

    local denominator = math.abs(previousSide) + math.abs(currentSide)
    local alpha = denominator > 0 and math.abs(previousSide) / denominator or 0
    local actualPosition = previousPosition:Lerp(currentPosition, alpha)
    shot.crossed = true
    shot.actualCrossing = actualPosition

    local plausibleHeight = actualPosition.Y >= goal.minY - 6
        and actualPosition.Y <= goal.maxY + 16
    local plausibleDuration = os.clock() - shot.startedAt
        <= MAX_PREDICTION_SECONDS + 1
    if not plausibleHeight or not plausibleDuration then
        completeShot(shot, "invalid")
        addEvent("shot_discarded", {
            token = token,
            reason = not plausibleHeight and "implausible crossing height"
                or "crossing arrived too late",
            actual = actualPosition
        })
        return
    end

    local nearGoalMouth = actualPosition.X >= goal.minX - 12
        and actualPosition.X <= goal.maxX + 12
        and actualPosition.Y >= goal.minY - 4
        and actualPosition.Y <= goal.maxY + 10
    if nearGoalMouth then
        calibrateFromCrossing(shot, actualPosition)
        calibrateDiveTiming(shot, os.clock())
    end

    local onTarget = isInsideGoal(actualPosition, goal)
    completeShot(shot, onTarget and "miss" or "wide")
    addEvent("goal_plane_crossed", {
        token = token,
        actual = actualPosition,
        onTarget = onTarget
    })
end

local function recordInitialPrediction(ball, prediction)
    local shot = state.activeShot
    if not shot or shot.ball ~= ball or shot.initialPrediction then
        return
    end
    shot.initialPrediction = {
        rawPosition = prediction.rawPosition,
        correctedPosition = prediction.position,
        secondsToGoal = prediction.time
    }
end

local function stabilizePrediction(ball, prediction)
    local shot = state.activeShot
    if not shot or shot.ball ~= ball then
        prediction.jitter = 0
        prediction.confidence = 0.25
        return prediction
    end

    shot.predictionSamples = (shot.predictionSamples or 0) + 1
    local instantPosition = prediction.position
    local previousPosition = shot.smoothedIntercept
    local jitter = previousPosition and (instantPosition - previousPosition).Magnitude or 0
    if previousPosition then
        local urgency = 1 - math.clamp(
            prediction.time / MAX_PREDICTION_SECONDS,
            0,
            1
        )
        local smoothingAlpha = math.clamp(0.28 + urgency * 0.5, 0.28, 0.78)
        prediction.position = previousPosition:Lerp(instantPosition, smoothingAlpha)
    end

    shot.smoothedIntercept = prediction.position
    shot.lastPredictionJitter = jitter
    prediction.instantPosition = instantPosition
    prediction.jitter = jitter

    local sampleConfidence = math.clamp(shot.predictionSamples / 5, 0, 1)
    local stabilityConfidence = math.clamp(1 - jitter / 12, 0.35, 1)
    prediction.confidence = sampleConfidence * stabilityConfidence
    return prediction
end

local function integrateToGoal(ball, goal, kinematics)
    if ball:GetAttribute("State") ~= "Released" then
        return nil
    end

    kinematics = kinematics or getBallKinematics(ball, goal)
    local position = kinematics.position
    local velocity = kinematics.velocity
    if velocity.Magnitude < 1 or math.abs(velocity.Z) < 0.1 then
        return nil
    end

    local displacementToPlane = goal.planeZ - position.Z
    if displacementToPlane * velocity.Z <= 0 then
        return nil
    end

    local gravity = kinematics.gravity
    local dampingExponent = tonumber(FootballDefaults.VelocityDampening) or 0.755
    local step = 1 / 120
    local elapsed = 0
    local previousPosition = position
    local previousSide = previousPosition.Z - goal.planeZ
    local groundCenterY = goal.minY + ball.Size.Y / 2

    while elapsed < MAX_PREDICTION_SECONDS do
        local speed = velocity.Magnitude
        local damping = Vector3.zero
        if speed > 1 then
            damping = velocity.Unit * (speed ^ dampingExponent)
        elseif speed > 0 then
            damping = velocity
        end

        local acceleration = Vector3.new(0, -gravity, 0) - damping
        velocity = velocity + acceleration * step
        position = position + velocity * step
        if position.Y < groundCenterY then
            position = Vector3.new(position.X, groundCenterY, position.Z)
            if velocity.Y < 0 then
                local bounceVelocity = -velocity.Y * BALL_RESTITUTION
                velocity = Vector3.new(
                    velocity.X,
                    bounceVelocity >= 2 and bounceVelocity or 0,
                    velocity.Z
                )
            end
        end
        elapsed = elapsed + step

        local side = position.Z - goal.planeZ
        if previousSide == 0 or side == 0 or previousSide * side < 0 then
            local denominator = math.abs(previousSide) + math.abs(side)
            local alpha = denominator > 0 and math.abs(previousSide) / denominator or 0
            local rawIntercept = previousPosition:Lerp(position, alpha)
            local intercept = Vector3.new(
                rawIntercept.X + state.learning.biasX,
                rawIntercept.Y + state.learning.biasY,
                rawIntercept.Z
            )
            local crossingTime = elapsed - step + step * alpha
            return {
                position = intercept,
                rawPosition = rawIntercept,
                time = crossingTime,
                velocity = velocity,
                gravity = gravity,
                source = kinematics.source,
                releaseAge = kinematics.releaseAge
            }
        end

        previousPosition = position
        previousSide = side
    end

    return nil
end

local function selectDiveDirection(root, intercept, goal)
    local offset = intercept - root.Position
    local rawGoalAxis = goal.rightAxis or Vector3.xAxis
    local flatGoalAxis = Vector3.new(rawGoalAxis.X, 0, rawGoalAxis.Z)
    local goalAxis = flatGoalAxis.Magnitude > 0.001
        and flatGoalAxis.Unit
        or Vector3.xAxis
    local sideOffset = goalAxis:Dot(offset)
    local desiredDirection
    if math.abs(sideOffset) <= CENTER_DIVE_THRESHOLD then
        desiredDirection = goal.fieldDirection
            or Vector3.new(0, 0, goal.planeZ >= 0 and -1 or 1)
    else
        desiredDirection = goalAxis * (sideOffset >= 0 and 1 or -1)
    end

    local flatDesiredDirection = Vector3.new(
        desiredDirection.X,
        0,
        desiredDirection.Z
    )
    desiredDirection = flatDesiredDirection.Magnitude > 0.001
        and flatDesiredDirection.Unit
        or Vector3.new(0, 0, goal.planeZ >= 0 and -1 or 1)
    local flatLook = Vector3.new(
        root.CFrame.LookVector.X,
        0,
        root.CFrame.LookVector.Z
    )
    local look = flatLook.Magnitude > 0.001
        and flatLook.Unit
        or desiredDirection
    local flatRight = Vector3.new(
        root.CFrame.RightVector.X,
        0,
        root.CFrame.RightVector.Z
    )
    local right = flatRight.Magnitude > 0.001
        and flatRight.Unit
        or Vector3.new(look.Z, 0, -look.X)
    local candidates = {
        { name = "Forward", vector = look },
        { name = "Right", vector = right },
        { name = "Left", vector = -right }
    }
    local best = candidates[1]
    local bestAlignment = best.vector:Dot(desiredDirection)
    for index = 2, #candidates do
        local alignment = candidates[index].vector:Dot(desiredDirection)
        if alignment > bestAlignment then
            best = candidates[index]
            bestAlignment = alignment
        end
    end
    return best.name, sideOffset, bestAlignment
end

local function projectedHalfExtent(part, axis)
    return math.abs(axis:Dot(part.CFrame.RightVector)) * part.Size.X / 2
        + math.abs(axis:Dot(part.CFrame.LookVector)) * part.Size.Z / 2
end

local function getCaptureRadius(character, ball, goal)
    local rawAxis = goal.rightAxis or Vector3.xAxis
    local flatAxis = Vector3.new(rawAxis.X, 0, rawAxis.Z)
    local axis = flatAxis.Magnitude > 0.001 and flatAxis.Unit or Vector3.xAxis
    local hitbox = character:FindFirstChild("Hitbox", true)
    local keeperRadius = hitbox and hitbox:IsA("BasePart")
        and projectedHalfExtent(hitbox, axis)
        or 2.5
    local ballRadius = projectedHalfExtent(ball, axis)
    return math.clamp(keeperRadius + ballRadius, 2.5, 8)
end

releaseToken = function(ball)
    local releaseId = ball:GetAttribute("ReleaseId")
    local releaseTime = tonumber(ball:GetAttribute("LastReleaseTime"))
    if releaseId and releaseTime then
        return string.format("%s@%.3f", safeText(releaseId), releaseTime)
    end
    return safeText(releaseId or releaseTime or ball)
end

local function setSprinting(enabled, reason)
    if enabled == state.sprinting then
        return
    end

    local ok, errorMessage
    if enabled then
        -- This follows the same controller path as holding Left Shift, while
        -- leaving keyboard focus and camera input untouched.
        ok, errorMessage = pcall(Sprint.Activate)
    else
        local playerHoldingShift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
            or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
        if playerHoldingShift then
            ok = true
        else
            ok, errorMessage = pcall(function()
                MovementController:SetSprintingControlState(false)
            end)
        end
    end
    if not ok then
        state.lastError = "Sprint control failed: " .. safeText(errorMessage)
        addEvent("sprint_error", { error = state.lastError })
        return
    end

    state.sprinting = enabled
    if enabled then
        state.sprintStarts = state.sprintStarts + 1
    else
        state.sprintStops = state.sprintStops + 1
    end
    addEvent(enabled and "sprint_started" or "sprint_stopped", {
        reason = reason
    })
end

stopSprinting = function(reason)
    if state.sprinting then
        setSprinting(false, reason or "stopped")
    end
end

stopWalking = function(reason)
    stopSprinting(reason or "walk stopped")
    if state.walking then
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if root and isHumanoidUsable(humanoid) then
            pcall(function()
                humanoid:MoveTo(root.Position)
            end)
        end
        if reason then
            addEvent("walk_stopped", { reason = reason })
        end
    end
    state.walking = false
    state.walkTarget = nil
end

local function updateWalkAssist(humanoid, root, ball, goal, prediction, incoming)
    local leapPosition = root:FindFirstChild("LeapPosition")
    local diveActive = os.clock() < state.diveActiveUntil
        or (leapPosition and leapPosition.Enabled)
    if not state.walkAssist or state.pendingDive or diveActive then
        state.phase = diveActive and "RECOVER" or state.phase
        stopWalking(
            diveActive and "dive active"
                or state.pendingDive and "dive pending"
                or "walk assist disabled"
        )
        return
    end
    if not isHumanoidUsable(humanoid) or humanoid.SeatPart then
        stopWalking("humanoid unavailable")
        return
    end

    local humanoidState = humanoid:GetState()
    if humanoidState == Enum.HumanoidStateType.Dead
        or humanoidState == Enum.HumanoidStateType.Seated
        or humanoidState == Enum.HumanoidStateType.Swimming
        or humanoidState == Enum.HumanoidStateType.Climbing then
        stopWalking("movement state blocked")
        return
    end

    local halfWidth = math.max(1, (goal.maxX - goal.minX) / 2)
    local edgePadding = math.min(2, halfWidth * 0.22)
    local fieldDirection = goal.planeZ >= 0 and -1 or 1
    local ballDepth = (ball.Position.Z - goal.planeZ) * fieldDirection
    local velocityTowardGoal = ball.AssemblyLinearVelocity.Z * fieldDirection < -1
    local withinDefensiveRange = ballDepth >= 0
        and ballDepth <= DEFENSIVE_TRACK_DISTANCE
    local desiredX
    if prediction then
        desiredX = prediction.position.X
        state.walkMode = "INTERCEPT"
    elseif incoming and incoming.incoming and incoming.likelyThreat then
        desiredX = incoming.projectedX
        state.walkMode = "ANTICIPATE"
    elseif withinDefensiveRange
        and (ball:GetAttribute("State") ~= "Released" or velocityTowardGoal) then
        local proximity = 1 - math.clamp(
            ballDepth / DEFENSIVE_TRACK_DISTANCE,
            0,
            1
        )
        local trackingWeight = ball:GetAttribute("State") == "Released"
            and (0.35 + proximity * 0.55)
            or (0.12 + proximity * 0.43)
        local ballOffset = math.clamp(
            ball.Position.X - goal.centerX,
            -halfWidth,
            halfWidth
        )
        desiredX = goal.centerX + ballOffset * trackingWeight
        state.walkMode = "TRACK"
    else
        desiredX = goal.centerX
        state.walkMode = "CENTER"
    end
    desiredX = math.clamp(
        desiredX,
        goal.minX + edgePadding,
        goal.maxX - edgePadding
    )

    local idealDepthZ = goal.planeZ + fieldDirection * GOALKEEPER_DEPTH
    local depthError = idealDepthZ - root.Position.Z
    local desiredZ = root.Position.Z
    local flatLook = Vector3.new(
        root.CFrame.LookVector.X,
        0,
        root.CFrame.LookVector.Z
    )
    local depthDirection = math.abs(depthError) > 0
        and Vector3.new(0, 0, math.sign(depthError))
        or Vector3.zero
    local facingDepthTarget = flatLook.Magnitude > 0
        and depthDirection.Magnitude > 0
        and flatLook.Unit:Dot(depthDirection) >= 0.2
    local allowDepthCorrection = state.walkMode == "CENTER"
        and math.abs(desiredX - root.Position.X) <= 2
        and not (incoming and incoming.incoming)
        and facingDepthTarget
    if allowDepthCorrection and math.abs(depthError) > GOALKEEPER_DEPTH_TOLERANCE then
        desiredZ = root.Position.Z + math.clamp(depthError, -1.5, 1.5)
    end
    local desiredPosition = Vector3.new(
        desiredX,
        root.Position.Y,
        desiredZ
    )
    state.walkTarget = desiredPosition

    local flatDelta = Vector3.new(
        desiredPosition.X - root.Position.X,
        0,
        desiredPosition.Z - root.Position.Z
    )
    if flatDelta.Magnitude <= WALK_DEADZONE then
        stopWalking("target reached")
        return
    end

    local sprintWanted = state.bestMode
        and state.walkMode ~= "CENTER"
        and flatDelta.Magnitude >= SPRINT_START_DISTANCE
    if sprintWanted then
        setSprinting(true, state.walkMode)
    elseif state.sprinting and not state.bestMode then
        stopSprinting("best mode disabled")
    elseif state.sprinting and flatDelta.Magnitude <= SPRINT_STOP_DISTANCE then
        stopSprinting("near positioning target")
    elseif state.sprinting and state.walkMode == "CENTER" then
        stopSprinting("centering")
    end

    local nowClock = os.clock()
    if nowClock - state.lastMoveAt < 1 / WALK_UPDATE_HZ then
        return
    end
    state.lastMoveAt = nowClock

    local commandDistance = math.min(flatDelta.Magnitude, WALK_MAX_STEP)
    local commandPosition = root.Position + flatDelta.Unit * commandDistance
    commandPosition = Vector3.new(commandPosition.X, root.Position.Y, commandPosition.Z)
    local ok, errorMessage = pcall(function()
        humanoid:MoveTo(commandPosition)
    end)
    if not ok then
        state.lastError = "Walk assist failed: " .. safeText(errorMessage)
        stopWalking("MoveTo error")
        return
    end

    state.walking = true
    state.movementCommands = state.movementCommands + 1
end

local function checkPendingClear()
    local pending = state.pendingClear
    if not pending then
        return
    end

    local nowClock = os.clock()
    if pending.releasedAt and LocalPlayer:GetAttribute("HasBall") ~= true then
        state.pendingClear = nil
        state.possessionStartedAt = nil
        state.clears = state.clears + 1
        state.clearStatus = "CLEAR CONFIRMED"
        addEvent("clear_confirmed", {
            confirmationMs = math.floor((nowClock - pending.releasedAt) * 1000)
        })
        return
    end

    if nowClock - pending.requestedAt >= 2.5 then
        state.pendingClear = nil
        state.lastError = "Auto clear did not release possession within 2.5 seconds"
        state.clearStatus = "CLEAR FAILED"
        addEvent("clear_not_confirmed", {
            error = state.lastError
        })
    end
end

local function updateAutoClear(humanoid, root, goal)
    local nowClock = os.clock()
    if not state.autoClear then
        state.clearStatus = "CLEAR OFF"
        return
    end
    if LocalPlayer:GetAttribute("IsInPenalties") == true then
        state.clearStatus = "PENALTY HOLD"
        return
    end
    if state.pendingClear then
        state.clearStatus = state.pendingClear.releasedAt and "RELEASING" or "CHARGING"
        return
    end

    state.possessionStartedAt = state.possessionStartedAt or nowClock
    if nowClock - state.possessionStartedAt < AUTO_CLEAR_SETTLE_SECONDS then
        state.clearStatus = "SECURING BALL"
        return
    end
    if nowClock - state.lastClearAt < AUTO_CLEAR_COOLDOWN then
        state.clearStatus = "CLEAR COOLDOWN"
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then
        state.clearStatus = "NO CAMERA"
        return
    end
    local fieldDirection = Vector3.new(0, 0, goal.planeZ >= 0 and -1 or 1)
    local cameraDirection = Vector3.new(
        camera.CFrame.LookVector.X,
        0,
        camera.CFrame.LookVector.Z
    )
    local alignment = cameraDirection.Magnitude > 0
        and cameraDirection.Unit:Dot(fieldDirection)
        or -1
    if alignment < 0.2 then
        state.clearStatus = "FACE MIDFIELD"
        if nowClock - state.lastMoveAt >= 1 / WALK_UPDATE_HZ then
            state.lastMoveAt = nowClock
            local safeFacingTarget = Vector3.new(
                math.clamp(root.Position.X, goal.minX + 1, goal.maxX - 1),
                root.Position.Y,
                goal.planeZ + fieldDirection.Z * (GOALKEEPER_DEPTH + 1.5)
            )
            pcall(function()
                humanoid:MoveTo(safeFacingTarget)
            end)
        end
        return
    end

    stopWalking("preparing automatic clear")
    state.lastClearAt = nowClock
    state.clearAttempts = state.clearAttempts + 1
    state.clearStatus = "CHARGING"
    local pending = {
        requestedAt = nowClock,
        releasedAt = nil
    }
    state.pendingClear = pending
    addEvent("clear_requested", {
        alignment = alignment,
        chargeSeconds = AUTO_CLEAR_CHARGE_SECONDS
    })

    local ok, errorMessage = pcall(ActionPrimary.start)
    if not ok then
        state.pendingClear = nil
        state.lastError = "Auto clear start failed: " .. safeText(errorMessage)
        state.clearStatus = "CLEAR ERROR"
        addEvent("clear_error", { error = state.lastError })
        return
    end

    task.delay(AUTO_CLEAR_CHARGE_SECONDS, function()
        if not state.running or state.pendingClear ~= pending then
            return
        end
        if LocalPlayer:GetAttribute("HasBall") ~= true then
            pending.releasedAt = os.clock()
            return
        end
        local released, releaseError = pcall(ActionPrimary.release)
        pending.releasedAt = os.clock()
        if not released then
            state.pendingClear = nil
            state.lastError = "Auto clear release failed: " .. safeText(releaseError)
            state.clearStatus = "CLEAR ERROR"
            addEvent("clear_error", { error = state.lastError })
        end
    end)
end

local function checkPendingDive()
    local pending = state.pendingDive
    if not pending then
        return false
    end

    local elapsed = os.clock() - pending.requestedAt
    local root = pending.root
    local leapPosition = root and root.Parent and root:FindFirstChild("LeapPosition")
    if leapPosition and leapPosition.Enabled and not pending.wasLeapEnabled then
        local confirmedAt = os.clock()
        state.pendingDive = nil
        state.dives = state.dives + 1
        state.lastDiveAt = confirmedAt
        state.lastDiveDirection = pending.direction
        state.diveActiveUntil = confirmedAt
            + (tonumber(MovementDefaults.Movers.LeapMoverLifetime) or 0.7)
        local learning = state.learning
        learning.startupSeconds = learning.startupSeconds
            + (math.clamp(elapsed, 0, 0.2) - learning.startupSeconds) * 0.25
        local shot = state.activeShot
        if shot and shot.token == pending.token then
            shot.diveStartedAt = confirmedAt
            shot.diveTravelSeconds = pending.travelSeconds
            shot.expectedCrossingAt = pending.expectedCrossingAt
        end
        state.phase = "COMMIT"
        state.status = "DIVE CONFIRMED"
        addEvent("dive_confirmed", {
            direction = pending.direction,
            token = pending.token,
            confirmationMs = math.floor(elapsed * 1000),
            prediction = pending.prediction
        })
        renderGui(true)
        return true
    end

    if not root or not root.Parent or elapsed >= 0.4 then
        state.pendingDive = nil
        state.lastError = not root or not root.Parent
            and "Character changed before the dive could be verified"
            or "LeapPosition did not enable within 400 ms"
        local shot = state.activeShot
        local retryAvailable = shot
            and shot.token == pending.token
            and (shot.diveAttemptCount or 0) < MAX_DIVE_ATTEMPTS_PER_SHOT
        if retryAvailable then
            state.lastDiveToken = nil
            state.status = "DIVE RETRY ARMED"
        else
            state.status = "DIVE NOT CONFIRMED"
        end
        addEvent("dive_not_confirmed", {
            direction = pending.direction,
            token = pending.token,
            error = state.lastError,
            retryAvailable = retryAvailable
        })
        renderGui(true)
        return true
    end

    return true
end

updateNetworkTiming(true)
createGui()
renderGui(true)

local accumulator = 0
state.connection = RunService.Heartbeat:Connect(function(deltaTime)
    if not state.running then
        return
    end
    checkPendingDive()
    checkPendingClear()
    updateNetworkTiming(false)

    accumulator = accumulator + deltaTime
    if accumulator < 1 / UPDATE_HZ then
        return
    end
    accumulator = 0
    state.samples = state.samples + 1
    state.team = LocalPlayer:GetAttribute("IsHomeOrAway")
    state.role = LocalPlayer:GetAttribute("TeamRole")

    if state.role ~= "Goalkeeper" then
        stopWalking("goalkeeper role inactive")
        state.incoming = nil
        state.phase = "STANDBY"
        state.status = "STANDBY"
        state.ballState = "Role inactive"
        state.lastPrediction = nil
        renderGui()
        return
    end
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local goal = getGoalGeometry()
    local ball, kinematics = findMatchBall(goal)
    if not root or not isHumanoidUsable(humanoid) or not ball or not goal then
        stopWalking("waiting for match")
        state.incoming = nil
        state.phase = "ACQUIRE"
        state.status = "WAITING FOR MATCH"
        state.ballState = ball and safeText(ball:GetAttribute("State")) or "Searching"
        state.lastPrediction = nil
        renderGui()
        return
    end
    state.ballState = safeText(ball:GetAttribute("State") or "Unknown")
    state.lastGoal = goal
    state.keeperGoalRatio = goal.maxX > goal.minX
        and (root.Position.X - goal.minX) / (goal.maxX - goal.minX)
        or 0.5
    if LocalPlayer:GetAttribute("HasBall") == true then
        state.incoming = nil
        if state.activeShot then
            completeShot(state.activeShot, "save")
            state.activeShot = nil
        end
        stopWalking("keeper has ball")
        updateAutoClear(humanoid, root, goal)
        state.phase = state.pendingClear and "CLEAR" or "POSSESSION"
        state.status = (state.clearStatus == "CHARGING"
            or state.clearStatus == "RELEASING")
            and "AUTO CLEARING"
            or "HOLDING BALL"
        state.ballState = "Possessed by you"
        state.lastPrediction = nil
        renderGui()
        return
    end
    state.possessionStartedAt = nil
    kinematics = kinematics or getBallKinematics(ball, goal)
    local incoming = classifyIncomingBall(ball, goal, kinematics)
    observeShot(ball, goal, kinematics, incoming)
    state.incoming = incoming

    local prediction = integrateToGoal(ball, goal, kinematics)
    if not prediction then
        updateWalkAssist(humanoid, root, ball, goal, nil, incoming)
        state.phase = incoming.incoming and incoming.likelyThreat
            and "POSITION"
            or "ACQUIRE"
        state.status = incoming.incoming and incoming.likelyThreat
            and "ANTICIPATING SHOT"
            or state.ballState == "Released" and "NO GOAL PATH"
            or "WAITING FOR SHOT"
        state.lastPrediction = nil
        renderGui()
        return
    end
    state.predictions = state.predictions + 1
    state.phase = "TRACK"
    recordInitialPrediction(ball, prediction)
    stabilizePrediction(ball, prediction)

    local insideGoal = isInsideGoal(prediction.position, goal)
    local direction, sideOffset, directionAlignment = selectDiveDirection(
        root,
        prediction.position,
        goal
    )
    local horizontalDistance = math.abs(sideOffset)
    local captureRadius = getCaptureRadius(character, ball, goal)
    local effectiveSaveDistance = math.max(0, horizontalDistance - captureRadius)
    local maxLeapTravel = (tonumber(MovementDefaults.Movers.LeapMoverLifetime) or 0.7)
        * (tonumber(MovementDefaults.Movers.LeapMoverMaxVelocity) or 30)
    local maxReach = maxLeapTravel + captureRadius
    local stretchSave = horizontalDistance > maxReach + GOAL_MARGIN
    local commitLead, commitTravelTime = effectiveLeadSeconds(effectiveSaveDistance)

    state.lastPrediction = {
        ball = ball:GetFullName(),
        releaseToken = releaseToken(ball),
        intercept = prediction.position,
        secondsToGoal = prediction.time,
        insideGoal = insideGoal,
        direction = direction,
        directionAlignment = directionAlignment,
        sideOffset = sideOffset,
        horizontalDistance = horizontalDistance,
        captureRadius = captureRadius,
        effectiveSaveDistance = effectiveSaveDistance,
        maxReach = maxReach,
        stretchSave = stretchSave,
        rawIntercept = prediction.rawPosition,
        instantIntercept = prediction.instantPosition,
        jitter = prediction.jitter,
        confidence = prediction.confidence,
        learnedBias = Vector2.new(state.learning.biasX, state.learning.biasY),
        effectiveLeadSeconds = commitLead,
        commitTravelSeconds = commitTravelTime,
        predictionSource = prediction.source,
        releaseAge = prediction.releaseAge,
        networkCompensationSeconds = state.network.compensationSeconds
    }
    updateWalkAssist(humanoid, root, ball, goal, prediction, incoming)

    if not insideGoal then
        state.status = "SHOT WIDE / HIGH"
        renderGui()
        return
    end
    local leapPosition = root:FindFirstChild("LeapPosition")
    if state.pendingDive then
        state.phase = "COMMIT"
        state.status = "DIVE COMMITTING"
        renderGui()
        return
    end
    if os.clock() < state.diveActiveUntil
        or (leapPosition and leapPosition.Enabled) then
        state.phase = "RECOVER"
        state.status = "DIVE RECOVERY"
        renderGui()
        return
    end
    if prediction.time > commitLead then
        state.status = stretchSave
            and "CLOSING ANGLE"
            or prediction.confidence < MIN_PREDICTION_CONFIDENCE
            and "LOCKING TRAJECTORY"
            or "TRACKING SHOT"
        renderGui()
        return
    end

    local token = releaseToken(ball)
    if state.lastDiveToken == token then
        state.status = state.autoDive and "DIVE COMMITTED" or "THREAT"
        renderGui()
        return
    end

    local shot = state.activeShot
    local diveCount = shot and shot.token == token
        and (shot.diveAttemptCount or 0)
        or 0
    if diveCount >= MAX_DIVE_ATTEMPTS_PER_SHOT then
        state.status = "DIVE ATTEMPTS USED"
        renderGui()
        return
    end
    if os.clock() - state.lastDiveAttemptAt < DIVE_RETRY_COOLDOWN then
        state.status = "DIVE RETRY COOLDOWN"
        renderGui()
        return
    end

    local firstThreat = not shot or not shot.threatRegistered
    if firstThreat then
        state.threats = state.threats + 1
        if shot then
            shot.threatRegistered = true
        end
    end
    state.lastDiveToken = token
    state.status = "THREAT"
    addEvent(firstThreat and "threat" or "threat_retry", state.lastPrediction)
    log(string.format(
        "Threat in %.2fs at X %.2f / Y %.2f; dive %s",
        prediction.time,
        prediction.position.X,
        prediction.position.Y,
        direction
    ))
    renderGui(true)

    if not state.autoDive then
        return
    end

    state.lastDiveAttemptAt = os.clock()
    state.diveAttempts = state.diveAttempts + 1
    state.phase = "COMMIT"
    state.status = "DIVING"
    state.pendingDive = {
        direction = direction,
        token = token,
        requestedAt = os.clock(),
        root = root,
        prediction = state.lastPrediction,
        travelSeconds = commitTravelTime,
        expectedCrossingAt = os.clock() + prediction.time,
        wasLeapEnabled = root:FindFirstChild("LeapPosition")
            and root.LeapPosition.Enabled
            or false
    }
    if shot and shot.token == token then
        shot.diveAttempted = true
        shot.diveAttemptCount = diveCount + 1
    end
    stopWalking("dive requested")
    local ok, errorMessage = pcall(Leap.Activate, direction)
    if not ok then
        state.pendingDive = nil
        if shot and (shot.diveAttemptCount or 0) < MAX_DIVE_ATTEMPTS_PER_SHOT then
            state.lastDiveToken = nil
        end
        state.lastError = safeText(errorMessage)
        addEvent("dive_error", state.lastError)
        warn("[RBA AutoGK] Dive failed:", state.lastError)
        state.status = "DIVE ERROR"
        renderGui(true)
        return
    end
    renderGui(true)
end)

log(string.format(
    "Started in %s mode; use STOP TEST or state.stop() to end",
    state.autoDive and "automatic dive" or "prediction only"
))

return state
