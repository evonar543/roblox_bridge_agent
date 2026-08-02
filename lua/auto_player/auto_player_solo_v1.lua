-- RBA Solo Player v1.
-- Development-only local player controller for non-goalkeeper roles.
-- Uses normal Humanoid movement and the game's normal Pass, Kick, Dribble,
-- and Sprint controllers. It never teleports, writes character CFrames, or
-- calls action remotes directly.

local RuntimeEnv = type(getgenv) == "function" and getgenv() or _G
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
assert(LocalPlayer, "Solo player controller requires a local player")

local previous = RuntimeEnv.__RBA_SOLO_PLAYER
if type(previous) == "table" and type(previous.stop) == "function" then
    pcall(previous.stop, "reloaded")
end
if type(previous) == "table" and previous.gui then
    pcall(function()
        previous.gui:Destroy()
    end)
end

local config = type(RuntimeEnv.RBA_SOLO_PLAYER_CONFIG) == "table"
    and RuntimeEnv.RBA_SOLO_PLAYER_CONFIG
    or {}

local UPDATE_HZ = math.clamp(tonumber(config.updateHz) or 8, 3, 15)
local THREAT_UPDATE_HZ = math.clamp(tonumber(config.threatUpdateHz) or 16, 8, 30)
local MOVE_UPDATE_HZ = math.clamp(tonumber(config.moveUpdateHz) or 12, 4, 20)
local REALTIME_MOVE_HZ = math.clamp(tonumber(config.realtimeMoveHz) or 20, 8, 30)
local MOVE_DEADZONE = math.clamp(tonumber(config.moveDeadzone) or 2, 0.5, 6)
local MOVE_STEP = math.clamp(tonumber(config.moveStep) or 12, 4, 24)
local SPRINT_DISTANCE = math.clamp(tonumber(config.sprintDistance) or 12, 6, 30)
local PASS_COOLDOWN = math.clamp(tonumber(config.passCooldown) or 1.4, 0.5, 5)
local SELF_PASS_COOLDOWN = math.clamp(tonumber(config.selfPassCooldown) or 2.2, 0.8, 6)
local DRIBBLE_COOLDOWN = math.clamp(tonumber(config.dribbleCooldown) or 1.1, 0.4, 4)
local SHOT_COOLDOWN = math.clamp(tonumber(config.shotCooldown) or 2, 0.8, 6)
local REQUEST_COOLDOWN = math.clamp(tonumber(config.requestCooldown) or 2.4, 0.8, 8)
local STEAL_COOLDOWN = math.clamp(tonumber(config.stealCooldown) or 1.35, 0.5, 5)
local STEAL_DISTANCE = math.clamp(tonumber(config.stealDistance) or 12.5, 5, 16)
local STEAL_APPROACH_DISTANCE = math.clamp(
    tonumber(config.stealApproachDistance) or 16,
    8,
    28
)
local STEAL_AIM_ALIGNMENT = math.clamp(tonumber(config.stealAimAlignment) or 0.6, -1, 1)
local INTERCEPT_SPEED = math.clamp(tonumber(config.interceptSpeed) or 27, 12, 40)
local MAX_INTERCEPT_SECONDS = math.clamp(tonumber(config.maxInterceptSeconds) or 1.35, 0.3, 3)
local ACTION_STAMINA_MIN = math.clamp(tonumber(config.actionStaminaMin) or 8, 0, 30)
local TACKLE_STAMINA_MIN = math.clamp(tonumber(config.tackleStaminaMin) or 15, 5, 40)
local SPRINT_STAMINA_MIN = math.clamp(tonumber(config.sprintStaminaMin) or 24, 8, 60)
local GK_REQUEST_MIN_PROGRESS = math.clamp(tonumber(config.gkRequestMinProgress) or 0.32, 0, 1)
local GK_REQUEST_MIN_DISTANCE = math.clamp(tonumber(config.gkRequestMinDistance) or 18, 5, 60)
local GK_REQUEST_MIN_CLEARANCE = math.clamp(tonumber(config.gkRequestMinClearance) or 7, 2, 25)
local SUPPORT_TEAMMATE_SPACING = math.clamp(tonumber(config.supportSpacing) or 10, 3, 30)
local PASS_MIN_FLIGHT_SECONDS = math.clamp(tonumber(config.passMinFlightSeconds) or 0.34, 0.15, 1)
local PASS_MAX_FLIGHT_SECONDS = math.clamp(tonumber(config.passMaxFlightSeconds) or 0.95, 0.3, 2)
local STEAL_APPROACH_LEAD = math.clamp(tonumber(config.stealApproachLead) or 0.16, 0, 0.5)
local POSSESSION_SETTLE_SECONDS = math.clamp(tonumber(config.possessionSettleSeconds) or 0.28, 0.08, 1.2)
local DANGER_DISTANCE = math.clamp(tonumber(config.dangerDistance) or 10.5, 4, 24)
local SAFE_PASS_CLEARANCE = math.clamp(tonumber(config.safePassClearance) or 7, 2, 20)
local SELF_PASS_MIN_CLEARANCE = math.clamp(
    tonumber(config.selfPassMinClearance) or 10,
    3,
    25
)
local SELF_PASS_MIN_RECEIVER_SPACE = math.clamp(
    tonumber(config.selfPassMinReceiverSpace) or 11,
    4,
    30
)
local SAFE_SHOT_CLEARANCE = math.clamp(tonumber(config.safeShotClearance) or 8, 2, 20)
local PREFERRED_SHOOT_RANGE = math.clamp(tonumber(config.preferredShootRange) or 42, 12, 100)
local SHOT_OVER_PASS_CLEARANCE = math.clamp(tonumber(config.shotOverPassClearance) or 5, 0, 20)
local CLOSE_SHOOT_RANGE = math.clamp(tonumber(config.closeShootRange) or 24, 8, 48)
local CLOSE_SHOT_CLEARANCE = math.clamp(tonumber(config.closeShotClearance) or 4.5, 1, 12)
local CLOSE_SHOT_AIM_ALIGNMENT = math.clamp(
    tonumber(config.closeShotAimAlignment) or 0.8,
    0.5,
    0.95
)
local LONG_SHOT_MAX_RANGE = math.clamp(tonumber(config.longShotMaxRange) or 54, 24, 100)
local LONG_SHOT_MIN_CLEARANCE = math.clamp(
    tonumber(config.longShotMinClearance) or 12,
    4,
    25
)
local GOAL_POST_MARGIN = math.clamp(tonumber(config.goalPostMargin) or 2.8, 1, 8)
local GOALKEEPER_AVOID_RADIUS = math.clamp(
    tonumber(config.goalkeeperAvoidRadius) or 7,
    2,
    20
)
local HOLD_RISK_RELEASE_THRESHOLD = math.clamp(tonumber(config.holdRiskReleaseThreshold) or 0.72, 0.35, 0.95)
local HOLD_RISK_SHIELD_THRESHOLD = math.clamp(tonumber(config.holdRiskShieldThreshold) or 0.42, 0.15, 0.9)
local DANGER_CLOSING_SPEED = math.clamp(tonumber(config.dangerClosingSpeed) or 12, 3, 40)
local PREEMPTIVE_DRIBBLE_DISTANCE = math.clamp(
    tonumber(config.preemptiveDribbleDistance) or 16,
    6,
    30
)
local PREEMPTIVE_CLOSING_SPEED = math.clamp(
    tonumber(config.preemptiveClosingSpeed) or 5,
    1,
    25
)
local QUICK_FINISH_SETTLE_SECONDS = math.clamp(
    tonumber(config.quickFinishSettleSeconds) or 0.12,
    0.05,
    0.5
)
local BALL_TRAJECTORY_SECONDS = math.clamp(
    tonumber(config.ballTrajectorySeconds) or 0.65,
    0.2,
    1.5
)
local CRITICAL_UPDATE_HZ = math.clamp(tonumber(config.criticalUpdateHz) or 24, 12, 40)
local LIVE_UPDATE_HZ = math.clamp(tonumber(config.liveUpdateHz) or 30, 16, 45)
local CONTEST_RADIUS = math.clamp(tonumber(config.contestRadius) or 16, 6, 30)
local EMERGENCY_RELEASE_DEADLINE = math.clamp(
    tonumber(config.emergencyReleaseDeadline) or 0.55,
    0.2,
    1.2
)
local RECEIVER_LEAD_LIMIT = math.clamp(tonumber(config.receiverLeadLimit) or 0.45, 0.1, 1)
local ADAPTIVE_RISK_STEP = math.clamp(tonumber(config.adaptiveRiskStep) or 0.06, 0.01, 0.16)
local MAX_ADAPTIVE_RISK_BIAS = math.clamp(
    tonumber(config.maxAdaptiveRiskBias) or 0.18,
    0.04,
    0.3
)
local AIM_TURN_RATE = math.clamp(tonumber(config.aimTurnRate) or 6.5, 1, 20)
local CLOSE_AIM_TURN_RATE = math.clamp(tonumber(config.closeAimTurnRate) or 12, 3, 30)
local PASS_AIM_ALIGNMENT = math.clamp(tonumber(config.passAimAlignment) or 0.88, 0.5, 0.999)
local SHOT_AIM_ALIGNMENT = math.clamp(tonumber(config.shotAimAlignment) or 0.91, 0.5, 0.999)
local EMERGENCY_PASS_AIM_ALIGNMENT = math.clamp(
    tonumber(config.emergencyPassAimAlignment) or 0.78,
    0.55,
    0.95
)
local SHOOT_RANGE = math.clamp(tonumber(config.shootRange) or 78, 20, 150)
local MIN_LANE_CLEARANCE = math.clamp(tonumber(config.minLaneClearance) or 4.5, 1, 16)
local BALL_VERTICAL_TOLERANCE = math.clamp(
    tonumber(config.ballVerticalTolerance) or 45,
    15,
    120
)
local DEBUG_LOGS = config.debugLogs == true

local FootballDefaults = require(ReplicatedStorage.Shared.Defaults.Football)
local MovementDefaults = require(ReplicatedStorage.Shared.Defaults.Movement)
local SharedStates = require(ReplicatedStorage.Shared.States)
local ActionPrimary = require(
    LocalPlayer.PlayerScripts.Client.Controllers.Actions.Managers.ActionPrimary
)
local ActionSecondary = require(
    LocalPlayer.PlayerScripts.Client.Controllers.Actions.Managers.ActionSecondary
)
local PrepareShot = require(
    LocalPlayer.PlayerScripts.Client.Controllers.Actions.Managers.PrepareShot
)
local RequestBall = require(
    LocalPlayer.PlayerScripts.Client.Controllers.Actions.Managers.RequestBall
)
local Tackle = require(
    LocalPlayer.PlayerScripts.Client.Controllers.Actions.Managers.Tackle
)
local Dribble = require(
    LocalPlayer.PlayerScripts.Client.Controllers.Actions.Managers.Dribble
)
local Sprint = require(
    LocalPlayer.PlayerScripts.Client.Controllers.Actions.Managers.Sprint
)
local Knit = require(ReplicatedStorage.Packages.Knit)
local MovementController = Knit.GetController("MovementController")

local state = {
    version = 1,
    running = true,
    autoPlay = config.autoPlay ~= false,
    autoPass = config.autoPass ~= false,
    autoSelfPass = config.autoSelfPass ~= false,
    autoDribble = config.autoDribble ~= false,
    autoScore = config.autoScore ~= false,
    autoRequestPass = config.autoRequestPass ~= false,
    autoSteal = config.autoSteal ~= false,
    autoAim = config.autoAim ~= false,
    assistMode = config.assistMode == true,
    phase = "ACQUIRE",
    status = "INITIALIZING",
    lastError = nil,
    startedAt = os.clock(),
    connection = nil,
    cameraConnection = nil,
    cameraBindingName = "RBA_SoloAim_" .. tostring(math.floor(os.clock() * 100000)),
    gui = nil,
    controls = {},
    plan = nil,
    goalCache = {},
    lastMoveAt = 0,
    lastDecisionAt = 0,
    decisionHz = UPDATE_HZ,
    context = nil,
    lastGuiAt = 0,
    lastPassAt = -math.huge,
    lastSelfPassAt = -math.huge,
    lastDribbleAt = -math.huge,
    lastShotAt = -math.huge,
    lastRequestAt = -math.huge,
    lastStealAt = -math.huge,
    possessionStartedAt = nil,
    hasPossession = false,
    hadPossession = false,
    possessionLosses = 0,
    safeReleases = 0,
    recentRelease = nil,
    pendingPossessionOutcome = nil,
    holdRisk = 0,
    holdReason = "clear",
    turnoverDeadline = math.huge,
    contestedDefenders = 0,
    predictedBall = nil,
    predictedBallSeconds = 0,
    adaptiveRiskBias = 0,
    emergencyReleases = 0,
    completedReleases = 0,
    pendingAction = nil,
    autoSprinting = false,
    aimTarget = nil,
    walking = false,
    movementCommands = 0,
    passes = 0,
    passRejects = 0,
    lastPassRejectReason = nil,
    selfPasses = 0,
    wallRejects = 0,
    dribbles = 0,
    shots = 0,
    requests = 0,
    stealAttempts = 0,
    steals = 0,
    lastPassCharge = 0,
    lastShotCharge = 0,
    decisions = 0,
    events = {}
}
RuntimeEnv.__RBA_SOLO_PLAYER = state

local function safeText(value)
    local ok, result = pcall(tostring, value)
    return ok and result or "<unprintable>"
end

local function addEvent(kind, data)
    table.insert(state.events, { kind = kind, at = os.clock(), data = data })
    while #state.events > 30 do
        table.remove(state.events, 1)
    end
end

local function log(message)
    if DEBUG_LOGS then
        print("[RBA Solo] " .. safeText(message))
    end
end

local function createInstance(className, properties, parent)
    local instance = Instance.new(className)
    for property, value in pairs(properties or {}) do
        instance[property] = value
    end
    instance.Parent = parent
    return instance
end

local function corner(parent, radius)
    return createInstance("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local function label(parent, properties)
    return createInstance("TextLabel", properties, parent)
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
    return parent
        or LocalPlayer:FindFirstChildOfClass("PlayerGui")
        or LocalPlayer:WaitForChild("PlayerGui", 5)
end

local function makeLine(screen, name, color)
    local line = createInstance("Frame", {
        Name = name,
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = color,
        BackgroundTransparency = 0.18,
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(0, 3),
        Visible = false,
        ZIndex = 20
    }, screen)
    corner(line, 2)
    createInstance("UIStroke", {
        Color = color,
        Transparency = 0.3,
        Thickness = 1
    }, line)
    return line
end

local function setWorldLine(line, from, to)
    local camera = Workspace.CurrentCamera
    if not camera or not from or not to then
        line.Visible = false
        return
    end
    local fromPoint, fromVisible = camera:WorldToViewportPoint(from)
    local toPoint, toVisible = camera:WorldToViewportPoint(to)
    if not fromVisible or not toVisible then
        line.Visible = false
        return
    end
    local delta = Vector2.new(toPoint.X - fromPoint.X, toPoint.Y - fromPoint.Y)
    local length = delta.Magnitude
    line.Position = UDim2.fromOffset(
        (fromPoint.X + toPoint.X) / 2,
        (fromPoint.Y + toPoint.Y) / 2
    )
    line.Size = UDim2.fromOffset(length, 3)
    line.Rotation = math.deg(math.atan2(delta.Y, delta.X))
    line.Visible = length > 2
end

local function createGui()
    local parent = resolveGuiParent()
    if not parent then
        state.lastError = "No GUI parent was available"
        return
    end
    local old = parent:FindFirstChild("RBASoloPlayerGui")
    if old then
        old:Destroy()
    end
    local screen = createInstance("ScreenGui", {
        Name = "RBASoloPlayerGui",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        DisplayOrder = 1001,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    }, parent)
    local panel = createInstance("Frame", {
        Name = "Panel",
        Active = true,
        Draggable = true,
        Position = UDim2.new(0, 18, 0, 86),
        Size = UDim2.fromOffset(350, 305),
        BackgroundColor3 = Color3.fromRGB(10, 16, 27),
        BackgroundTransparency = 0.08,
        BorderSizePixel = 0,
        ZIndex = 30
    }, screen)
    corner(panel, 12)
    createInstance("UIStroke", {
        Color = Color3.fromRGB(78, 142, 215),
        Transparency = 0.35,
        Thickness = 1
    }, panel)
    local header = createInstance("Frame", {
        BackgroundColor3 = Color3.fromRGB(24, 48, 80),
        BackgroundTransparency = 0.22,
        Position = UDim2.fromOffset(1, 1),
        Size = UDim2.new(1, -2, 0, 49),
        BorderSizePixel = 0,
        ZIndex = 31
    }, panel)
    corner(header, 11)
    label(header, {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(13, 6),
        Size = UDim2.fromOffset(220, 18),
        Font = Enum.Font.GothamBold,
        Text = "SOLO PLAY  //  FIELD AI",
        TextSize = 13,
        TextColor3 = Color3.fromRGB(241, 247, 255),
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 32
    })
    local subtitle = label(header, {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(13, 27),
        Size = UDim2.fromOffset(260, 15),
        Font = Enum.Font.GothamMedium,
        Text = "Normal movement + pass + dribble + kick",
        TextSize = 9,
        TextColor3 = Color3.fromRGB(145, 172, 207),
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 32
    })
    local status = label(panel, {
        BackgroundColor3 = Color3.fromRGB(38, 108, 167),
        BackgroundTransparency = 0.75,
        Position = UDim2.fromOffset(12, 61),
        Size = UDim2.new(1, -24, 0, 31),
        Font = Enum.Font.GothamSemibold,
        Text = "INITIALIZING",
        TextSize = 10,
        TextColor3 = Color3.fromRGB(172, 224, 255),
        TextXAlignment = Enum.TextXAlignment.Left,
        BorderSizePixel = 0,
        ZIndex = 31
    })
    corner(status, 7)

    local function metric(name, y)
        label(panel, {
            BackgroundTransparency = 1,
            Position = UDim2.fromOffset(14, y),
            Size = UDim2.fromOffset(72, 17),
            Font = Enum.Font.GothamSemibold,
            Text = name,
            TextSize = 9,
            TextColor3 = Color3.fromRGB(116, 139, 171),
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 31
        })
        return label(panel, {
            BackgroundTransparency = 1,
            Position = UDim2.fromOffset(88, y),
            Size = UDim2.fromOffset(246, 17),
            Font = Enum.Font.Code,
            Text = "--",
            TextSize = 10,
            TextColor3 = Color3.fromRGB(224, 235, 250),
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 31
        })
    end
    local phase = metric("MODE", 105)
    local target = metric("TARGET", 128)
    local lane = metric("LANE", 151)
    local counters = metric("STATS", 174)

    local function button(name, text, x, width, color)
        local value = createInstance("TextButton", {
            Name = name,
            BackgroundColor3 = color,
            BackgroundTransparency = 0.06,
            Position = UDim2.fromOffset(x, 204),
            Size = UDim2.fromOffset(width, 27),
            BorderSizePixel = 0,
            AutoButtonColor = false,
            Font = Enum.Font.GothamBold,
            Text = text,
            TextSize = 8,
            TextColor3 = Color3.fromRGB(235, 244, 255),
            ZIndex = 31
        }, panel)
        corner(value, 6)
        return value
    end
    local playButton = button("PlayButton", "AUTO: ON", 13, 75, Color3.fromRGB(35, 116, 90))
    local passButton = button("PassButton", "PASS: ON", 94, 75, Color3.fromRGB(39, 92, 139))
    local dribbleButton = button("DribbleButton", "DRIB: ON", 175, 75, Color3.fromRGB(109, 72, 154))
    local scoreButton = button("ScoreButton", "SCORE: ON", 256, 81, Color3.fromRGB(136, 78, 36))
    local assistButton = createInstance("TextButton", {
        Name = "AssistButton",
        BackgroundColor3 = Color3.fromRGB(57, 63, 75),
        BackgroundTransparency = 0.06,
        Position = UDim2.fromOffset(13, 239),
        Size = UDim2.fromOffset(324, 24),
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = "ASSIST MOVEMENT: OFF",
        TextSize = 9,
        TextColor3 = Color3.fromRGB(235, 244, 255),
        ZIndex = 31
    }, panel)
    corner(assistButton, 6)
    local stopButton = createInstance("TextButton", {
        Name = "StopButton",
        BackgroundColor3 = Color3.fromRGB(102, 43, 59),
        BackgroundTransparency = 0.06,
        Position = UDim2.fromOffset(13, 269),
        Size = UDim2.fromOffset(324, 24),
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = "STOP SOLO PLAY",
        TextSize = 9,
        TextColor3 = Color3.fromRGB(255, 219, 225),
        ZIndex = 31
    }, panel)
    corner(stopButton, 6)

    state.gui = screen
    state.controls = {
        subtitle = subtitle,
        status = status,
        phase = phase,
        target = target,
        lane = lane,
        counters = counters,
        playButton = playButton,
        passButton = passButton,
        dribbleButton = dribbleButton,
        scoreButton = scoreButton,
        assistButton = assistButton,
        stopButton = stopButton,
        moveLine = makeLine(screen, "MoveLine", Color3.fromRGB(248, 209, 83)),
        passLine = makeLine(screen, "PassLine", Color3.fromRGB(71, 205, 255)),
        shotLine = makeLine(screen, "ShotLine", Color3.fromRGB(255, 101, 145)),
        ballLine = makeLine(screen, "BallTrajectoryLine", Color3.fromRGB(143, 248, 255)),
        threatLine = makeLine(screen, "ThreatLine", Color3.fromRGB(255, 83, 112))
    }

    playButton.MouseButton1Click:Connect(function()
        state.autoPlay = not state.autoPlay
        addEvent("mode", { autoPlay = state.autoPlay })
    end)
    passButton.MouseButton1Click:Connect(function()
        state.autoPass = not state.autoPass
        addEvent("mode", { autoPass = state.autoPass })
    end)
    dribbleButton.MouseButton1Click:Connect(function()
        state.autoDribble = not state.autoDribble
        addEvent("mode", { autoDribble = state.autoDribble })
    end)
    scoreButton.MouseButton1Click:Connect(function()
        state.autoScore = not state.autoScore
        addEvent("mode", { autoScore = state.autoScore })
    end)
    assistButton.MouseButton1Click:Connect(function()
        state.assistMode = not state.assistMode
        if state.assistMode then
            stopMoving("manual assist enabled")
        end
        addEvent("mode", { assistMode = state.assistMode })
    end)
    stopButton.MouseButton1Click:Connect(function()
        state.stop("stopped from GUI")
    end)
end

local function flat(vector)
    return Vector3.new(vector.X, 0, vector.Z)
end

local function cameraAimAlignment(root, target)
    local camera = Workspace.CurrentCamera
    if not camera or not root or not target then
        return -1
    end
    local desired = flat(target - root.Position)
    local current = flat(camera.CFrame.LookVector)
    if desired.Magnitude < 0.1 or current.Magnitude < 0.1 then
        return -1
    end
    return desired.Unit:Dot(current.Unit)
end

local function turnCameraToward(root, target, blend)
    if not state.autoAim or not root or not target then
        return cameraAimAlignment(root, target)
    end
    local camera = Workspace.CurrentCamera
    local desiredFlat = flat(target - root.Position)
    if not camera or desiredFlat.Magnitude < 0.1 then
        return -1
    end
    local currentLook = camera.CFrame.LookVector
    local desiredLook = Vector3.new(
        desiredFlat.Unit.X,
        math.clamp(currentLook.Y, -0.3, 0.3),
        desiredFlat.Unit.Z
    ).Unit
    local desiredCFrame = CFrame.lookAt(
        camera.CFrame.Position,
        camera.CFrame.Position + desiredLook
    )
    camera.CFrame = camera.CFrame:Lerp(desiredCFrame, blend)
    return cameraAimAlignment(root, target)
end

local function setAimTarget(target)
    state.aimTarget = state.autoAim and target or nil
end

local function getCharacter()
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not character or not root or not humanoid or humanoid:GetState() == Enum.HumanoidStateType.Dead then
        return nil
    end
    return character, root, humanoid
end

local function controlsBlocked()
    return LocalPlayer:GetAttribute("DisableControls") == true
        or LocalPlayer:GetAttribute("ControlsDisabled") == true
        or LocalPlayer:GetAttribute("Freeze") == true
        or LocalPlayer:GetAttribute("IsFrozen") == true
end

local function sharedStateValue(groupName, stateName)
    local ok, value = pcall(function()
        local group = SharedStates[groupName]
        local stateValue = group and group[stateName]
        return stateValue and stateValue:get()
    end)
    return ok and value or nil
end

local function getSpecialAnimation(humanoid)
    if not humanoid then
        return nil
    end
    for _, track in ipairs(humanoid:GetPlayingAnimationTracks()) do
        local name = string.lower(safeText(track.Name))
        if string.find(name, "bicycle", 1, true)
            or string.find(name, "slide", 1, true)
            or string.find(name, "tackle", 1, true)
            or string.find(name, "celebr", 1, true) then
            return track.Name
        end
    end
    return nil
end

local function getPlayerContext(humanoid)
    local humanoidState = humanoid and humanoid:GetState()
    local specialAnimation = getSpecialAnimation(humanoid)
    local stamina = tonumber(sharedStateValue("Stamina", "Amount"))
    local intermission = sharedStateValue("Match", "IsInTeamScoredIntermission") == true
    local celebrating = sharedStateValue("Match", "InCelebrationCutscene") == true
    local spectating = sharedStateValue("Match", "Spectating") == true
    local transitioning = sharedStateValue("Match", "InTransitionScreen") == true
    local sliding = sharedStateValue("Actions", "Sliding")
    sliding = sliding and sliding.IsSliding and sliding.IsSliding:get() == true or false
    local preparingShot = sharedStateValue("Actions", "PrepareShot") == true
    local wasTackled = LocalPlayer:GetAttribute("WasTackled") == true
    local airborne = humanoidState == Enum.HumanoidStateType.Jumping
        or humanoidState == Enum.HumanoidStateType.Freefall
    local blocked = intermission or celebrating or spectating or transitioning
        or wasTackled
        or specialAnimation ~= nil
        or humanoidState == Enum.HumanoidStateType.Dead
        or humanoidState == Enum.HumanoidStateType.Seated
        or humanoidState == Enum.HumanoidStateType.Swimming
    return {
        stamina = stamina,
        intermission = intermission,
        celebrating = celebrating,
        spectating = spectating,
        transitioning = transitioning,
        sliding = sliding,
        preparingShot = preparingShot,
        wasTackled = wasTackled,
        airborne = airborne,
        specialAnimation = specialAnimation,
        blocked = blocked
    }
end

local function actionAllowed(context, kind)
    if not context or context.blocked or context.airborne then
        return false
    end
    if context.preparingShot then
        return false
    end
    if context.stamina and context.stamina < ACTION_STAMINA_MIN then
        return false
    end
    if kind == "TACKLE" then
        return not context.sliding
            and (not context.stamina or context.stamina >= TACKLE_STAMINA_MIN)
    end
    return true
end

local function getGoal(side)
    local cached = state.goalCache[side]
    if cached and cached.goal and cached.goal.Parent then
        return cached
    end
    local stadium = Workspace:FindFirstChild("Stadium")
    local teams = stadium and stadium:FindFirstChild("Teams")
    local team = teams and teams:FindFirstChild(side)
    local goal = team and team:FindFirstChild("Goal")
    local bars = goal and goal:FindFirstChild("Bars")
    local left = bars and bars:FindFirstChild("Left")
    local right = bars and bars:FindFirstChild("Right")
    local top = bars and bars:FindFirstChild("Top")
    if not goal or not left or not right or not top then
        return nil
    end
    local result = {
        side = side,
        goal = goal,
        center = Vector3.new(
            (left.Position.X + right.Position.X) / 2,
            top.Position.Y - top.Size.Y / 3,
            top.Position.Z
        ),
        planeZ = top.Position.Z,
        rightAxis = flat(right.Position - left.Position).Unit,
        halfWidth = flat(right.Position - left.Position).Magnitude / 2,
        minX = math.min(left.Position.X, right.Position.X),
        maxX = math.max(left.Position.X, right.Position.X)
    }
    state.goalCache[side] = result
    return result
end

local function getSides()
    local own = LocalPlayer:GetAttribute("IsHomeOrAway")
    if own ~= "Home" and own ~= "Away" then
        return nil
    end
    return own, own == "Home" and "Away" or "Home"
end

local function isUsableBallPosition(position, root)
    return position and root
        and math.abs(position.Y - root.Position.Y) <= BALL_VERTICAL_TOLERANCE
end

local function getBall(root)
    local misc = Workspace:FindFirstChild("Misc")
    if not misc then
        return nil
    end
    local best
    local bestScore = -math.huge
    for _, item in ipairs(misc:GetChildren()) do
        if item:IsA("BasePart") and item:GetAttribute("State") ~= nil and item:GetAttribute("Enabled") ~= false then
            local hasPossessor = item:GetAttribute("PossessorId") ~= nil
            local physicalPosition = isUsableBallPosition(item.Position, root)
            local score = item:GetAttribute("State") == "Released" and 3 or 1
            if item.AssemblyLinearVelocity.Magnitude > 4 then
                score = score + 1
            end
            if physicalPosition then
                score = score + 2
            elseif hasPossessor then
                -- This experience parks a possessed football below the pitch.
                -- The holder's AgentId gives us the real tactical position.
                score = score + 0.5
            else
                score = score - 4
            end
            if score > bestScore then
                best = item
                bestScore = score
            end
        end
    end
    return best
end

local function getPlayersBySide(ownSide)
    local teammates = {}
    local opponents = {}
    local carrier
    local agents = {}
    for _, player in ipairs(Players:GetPlayers()) do
        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local side = player:GetAttribute("IsHomeOrAway")
        if root and player:GetAttribute("IsOnPitch") ~= false
            and (side == "Home" or side == "Away") then
            local entry = {
                player = player,
                root = root,
                position = root.Position,
                side = side,
                role = player:GetAttribute("TeamRole")
            }
            local agentId = player:GetAttribute("AgentId")
            if agentId ~= nil then
                agents[safeText(agentId)] = entry
            end
            if player ~= LocalPlayer and entry.side == ownSide then
                table.insert(teammates, entry)
            elseif player ~= LocalPlayer then
                table.insert(opponents, entry)
            end
            if player ~= LocalPlayer and player:GetAttribute("HasBall") == true then
                carrier = entry
            end
        end
    end
    return teammates, opponents, carrier, agents
end

-- A pass target is a snapshot from the planner, not a permanent identity.
-- Re-check the live team, pitch state, and AgentId immediately before both
-- starting and releasing the action so a substitution or stale plan can never
-- turn a teammate pass into a pass toward an opponent.
local function isConfirmedPassTarget(player, ownSide, expectedAgentId)
    if not player or player == LocalPlayer or player.Parent ~= Players then
        return false, "target unavailable"
    end
    if player:GetAttribute("IsOnPitch") == false then
        return false, "target left pitch"
    end
    if player:GetAttribute("IsHomeOrAway") ~= ownSide then
        return false, "target team changed"
    end
    if expectedAgentId ~= nil
        and safeText(player:GetAttribute("AgentId")) ~= expectedAgentId then
        return false, "target identity changed"
    end
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then
        return false, "target character missing"
    end
    return true
end

local function rejectPass(reason)
    state.passRejects = state.passRejects + 1
    state.lastPassRejectReason = safeText(reason or "unconfirmed target")
    addEvent("pass_rejected", { reason = state.lastPassRejectReason })
end

local function isGoalkeeper(entry)
    return entry and entry.role == "Goalkeeper"
end

local function chooseGoalkeeperOutletBlock(root, goalkeeper, opponents)
    local outlet
    local bestScore = -math.huge
    for _, opponent in ipairs(opponents) do
        if opponent ~= goalkeeper and not isGoalkeeper(opponent) then
            local distance = flat(opponent.position - goalkeeper.position).Magnitude
            local score = math.min(distance, 55)
                - flat(opponent.position - root.Position).Magnitude * 0.16
            if score > bestScore then
                bestScore = score
                outlet = opponent
            end
        end
    end
    if not outlet then
        return goalkeeper.position
    end
    return goalkeeper.position:Lerp(outlet.position, 0.48)
end

local function pointToSegmentDistance(point, from, to)
    local segment = flat(to - from)
    local offset = flat(point - from)
    local lengthSquared = segment:Dot(segment)
    if lengthSquared < 0.001 then
        return offset.Magnitude, 0
    end
    local ratio = math.clamp(offset:Dot(segment) / lengthSquared, 0, 1)
    return (offset - segment * ratio).Magnitude, ratio
end

local function estimatePursuitSpeed(humanoid, context, hasBall)
    local speeds = MovementDefaults.Speed or {}
    local walkSpeed = tonumber(speeds.WalkSpeed) or 16
    local sprintSpeed = tonumber(
        hasBall and speeds.PossessionSprintSpeed or speeds.SprintSpeed
    ) or INTERCEPT_SPEED
    local currentSpeed = humanoid and tonumber(humanoid.WalkSpeed) or 0
    if context and context.stamina and context.stamina < SPRINT_STAMINA_MIN then
        return math.max(walkSpeed, currentSpeed)
    end
    return math.max(walkSpeed, currentSpeed, sprintSpeed)
end

local function timeToReach(from, to, speed)
    return flat(to - from).Magnitude / math.max(1, speed)
end

local function predictEntryPosition(entry, seconds)
    local lead = flat(entry.root.AssemblyLinearVelocity) * math.max(0, seconds or 0)
    if lead.Magnitude > 14 then
        lead = lead.Unit * 14
    end
    return entry.position + lead
end

local function arrivalSpace(position, opponents, seconds)
    local closest = 60
    for _, opponent in ipairs(opponents) do
        local predicted = predictEntryPosition(opponent, seconds)
        closest = math.min(closest, flat(predicted - position).Magnitude)
    end
    return closest
end

local function getFieldBarriers()
    local stadium = Workspace:FindFirstChild("Stadium")
    local field = stadium and stadium:FindFirstChild("Field")
    local barriers = field and field:FindFirstChild("Barriers")
    return barriers and barriers.Parent and barriers or nil
end

local function isWallPathBlocked(from, to)
    local barriers = getFieldBarriers()
    local delta = to - from
    if not barriers or delta.Magnitude < 0.1 then
        return false
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = { barriers }
    local hit = Workspace:Raycast(from + delta.Unit * 0.5, delta, params)
    return hit ~= nil, hit
end

local function laneClearance(from, to, opponents, predictionSeconds)
    local wallBlocked = isWallPathBlocked(from, to)
    if wallBlocked then
        state.wallRejects = state.wallRejects + 1
        return 0, true
    end
    local closest = math.huge
    predictionSeconds = math.max(0, tonumber(predictionSeconds) or 0)
    for _, opponent in ipairs(opponents) do
        local predictedPosition = predictEntryPosition(opponent, predictionSeconds)
        local distance, ratio = pointToSegmentDistance(predictedPosition, from, to)
        if ratio > 0.08 and ratio < 0.96 then
            closest = math.min(closest, distance)
        end
    end
    return closest == math.huge and 60 or closest, false
end

local function choosePathTarget(root, opponentGoal, opponents, pursuitSpeed)
    local forward = flat(opponentGoal.center - root.Position)
    if forward.Magnitude < 0.1 then
        return root.Position, "hold"
    end
    forward = forward.Unit
    local right = Vector3.new(forward.Z, 0, -forward.X)
    local candidates = {
        root.Position + forward * 18,
        root.Position + forward * 16 + right * 8,
        root.Position + forward * 16 - right * 8,
        root.Position + forward * 12 + right * 15,
        root.Position + forward * 12 - right * 15,
        root.Position + forward * 7 + right * 21,
        root.Position + forward * 7 - right * 21
    }
    local best = candidates[1]
    local bestClearance = 0
    local bestScore = -math.huge
    for _, candidate in ipairs(candidates) do
        local arrivalSeconds = timeToReach(root.Position, candidate, pursuitSpeed or INTERCEPT_SPEED)
        local clearance = laneClearance(
            root.Position,
            candidate,
            opponents,
            math.min(arrivalSeconds, 0.9)
        )
        local space = arrivalSpace(candidate, opponents, arrivalSeconds)
        local progress = flat(candidate - root.Position):Dot(forward)
        local score = progress * 1.25
            + math.min(clearance, 20) * 1.5
            + math.min(space, 20) * 0.8
            - arrivalSeconds * 1.1
        if score > bestScore then
            bestScore = score
            best = candidate
            bestClearance = clearance
        end
    end
    return Vector3.new(best.X, root.Position.Y, best.Z), "open lane", bestClearance
end

local function nearestOpponent(root, opponents)
    local nearest
    local distance = math.huge
    for _, opponent in ipairs(opponents) do
        if not isGoalkeeper(opponent) then
            local candidateDistance = flat(opponent.position - root.Position).Magnitude
            if candidateDistance < distance then
                nearest = opponent
                distance = candidateDistance
            end
        end
    end
    return nearest, distance
end

local function chooseRetentionTarget(root, ownGoal, opponentGoal, opponents, pursuitSpeed)
    local nearest, pressure = nearestOpponent(root, opponents)
    if not nearest then
        return choosePathTarget(root, opponentGoal, opponents, pursuitSpeed)
    end
    local away = flat(root.Position - nearest.position)
    local forward = flat(opponentGoal.center - ownGoal.center)
    if away.Magnitude < 0.1 or forward.Magnitude < 0.1 then
        return choosePathTarget(root, opponentGoal, opponents, pursuitSpeed)
    end
    away = away.Unit
    forward = forward.Unit
    local right = Vector3.new(forward.Z, 0, -forward.X)
    local candidates = {
        root.Position + away * 10 + forward * 6,
        root.Position + away * 12 + right * 5,
        root.Position + away * 12 - right * 5,
        root.Position + away * 8 - forward * 4
    }
    local best = candidates[1]
    local bestClearance = 0
    local bestScore = -math.huge
    for _, candidate in ipairs(candidates) do
        local arrivalSeconds = timeToReach(root.Position, candidate, pursuitSpeed or INTERCEPT_SPEED)
        local clearance = laneClearance(
            root.Position,
            candidate,
            opponents,
            math.min(arrivalSeconds, 0.8)
        )
        local predictedNearest = predictEntryPosition(nearest, arrivalSeconds)
        local separation = flat(candidate - predictedNearest).Magnitude
        local space = arrivalSpace(candidate, opponents, arrivalSeconds)
        local progress = flat(candidate - root.Position):Dot(forward)
        local score = separation * 1.25 + math.min(clearance, 18) * 1.5
            + math.min(space, 18) * 0.7
            + progress * 0.25
            - arrivalSeconds * 0.8
        if score > bestScore then
            best = candidate
            bestClearance = clearance
            bestScore = score
        end
    end
    return Vector3.new(best.X, root.Position.Y, best.Z), "shield into space", bestClearance, pressure
end

local function assessHoldRisk(root, opponents, pass, context)
    local nearest, distance = nearestOpponent(root, opponents)
    if not nearest then
        return 0, "no nearby defender", nil, 0, 0, math.huge,
            HOLD_RISK_RELEASE_THRESHOLD, HOLD_RISK_SHIELD_THRESHOLD
    end
    local separation = flat(root.Position - nearest.position)
    local direction = separation.Magnitude > 0.1 and separation.Unit or Vector3.zero
    local relativeVelocity = nearest.root.AssemblyLinearVelocity
        - root.AssemblyLinearVelocity
    local closingSpeed = math.max(0, relativeVelocity:Dot(direction))
    local distanceRisk = 1 - math.clamp(
        (distance - 2.5) / math.max(1, DANGER_DISTANCE * 1.55 - 2.5),
        0,
        1
    )
    local closingRisk = math.clamp(closingSpeed / DANGER_CLOSING_SPEED, 0, 1)
    local contestedDefenders = 0
    for _, opponent in ipairs(opponents) do
        if flat(opponent.position - root.Position).Magnitude <= CONTEST_RADIUS then
            contestedDefenders = contestedDefenders + 1
        end
    end
    local contestRisk = math.clamp((contestedDefenders - 1) / 2, 0, 1)
    local turnoverDeadline
    if closingSpeed > 0.5 then
        turnoverDeadline = math.max(0, (distance - 2.5) / closingSpeed)
    elseif distance <= 4.5 then
        turnoverDeadline = 0.35
    else
        turnoverDeadline = math.huge
    end
    local staminaRisk = context and context.stamina
        and math.clamp((18 - context.stamina) / 18, 0, 1)
        or 0
    local outletRisk = not pass and 0.16
        or pass.clearance < SAFE_PASS_CLEARANCE and 0.12
        or 0
    local risk = math.clamp(
        distanceRisk * 0.49
            + closingRisk * 0.22
            + contestRisk * 0.12
            + staminaRisk * 0.1
            + outletRisk
            + state.adaptiveRiskBias,
        0,
        1
    )
    local releaseThreshold = math.max(0.35, HOLD_RISK_RELEASE_THRESHOLD - state.adaptiveRiskBias)
    local shieldThreshold = math.max(0.15, HOLD_RISK_SHIELD_THRESHOLD - state.adaptiveRiskBias * 0.5)
    local reason = turnoverDeadline <= EMERGENCY_RELEASE_DEADLINE
        and "turnover deadline"
        or risk >= releaseThreshold
        and "imminent tackle risk"
        or risk >= shieldThreshold
        and "pressure building"
        or "controlled"
    return risk, reason, nearest, closingSpeed, contestedDefenders, turnoverDeadline,
        releaseThreshold, shieldThreshold
end

local function fieldProgress(position, ownGoal, opponentGoal)
    local axis = flat(opponentGoal.center - ownGoal.center)
    if axis.Magnitude < 0.1 then
        return 0.5
    end
    return math.clamp(
        flat(position - ownGoal.center):Dot(axis) / axis:Dot(axis),
        0,
        1
    )
end

local function nearestTeammateDistance(position, teammates, excludedPlayer)
    local closest = math.huge
    for _, teammate in ipairs(teammates) do
        if teammate.player ~= excludedPlayer then
            closest = math.min(
                closest,
                flat(teammate.position - position).Magnitude
            )
        end
    end
    return closest == math.huge and 60 or closest
end

local function chooseSupportTarget(root, carrier, ownGoal, opponentGoal, opponents, teammates)
    local forward = flat(opponentGoal.center - carrier.position)
    if forward.Magnitude < 0.1 then
        return root.Position, 0
    end
    forward = forward.Unit
    local right = Vector3.new(forward.Z, 0, -forward.X)
    local minX = math.min(ownGoal.minX, opponentGoal.minX) + 2
    local maxX = math.max(ownGoal.maxX, opponentGoal.maxX) - 2
    local minZ = math.min(ownGoal.planeZ, opponentGoal.planeZ) + 8
    local maxZ = math.max(ownGoal.planeZ, opponentGoal.planeZ) - 8
    local candidates = {
        carrier.position + forward * 13 + right * 10,
        carrier.position + forward * 13 - right * 10,
        carrier.position + forward * 19 + right * 5,
        carrier.position + forward * 19 - right * 5,
        carrier.position - forward * 7 + right * 14,
        carrier.position - forward * 7 - right * 14
    }
    local best = root.Position
    local bestClearance = 0
    local bestScore = -math.huge
    for _, candidate in ipairs(candidates) do
        candidate = Vector3.new(
            math.clamp(candidate.X, minX, maxX),
            root.Position.Y,
            math.clamp(candidate.Z, minZ, maxZ)
        )
        local fromCarrier = flat(candidate - carrier.position)
        local clearance = laneClearance(carrier.position, candidate, opponents)
        local progress = fromCarrier:Dot(forward)
        local spacing = math.min(fromCarrier.Magnitude, 28)
        local teammateSpacing = nearestTeammateDistance(
            candidate,
            teammates,
            carrier.player
        )
        local travelPenalty = math.min(flat(candidate - root.Position).Magnitude, 50) * 0.16
        local score = math.min(clearance, 22) * 2.1
            + progress * 0.8
            + spacing * 0.35
            + math.min(teammateSpacing, SUPPORT_TEAMMATE_SPACING * 2) * 0.45
            - travelPenalty
        if clearance >= MIN_LANE_CLEARANCE and score > bestScore then
            best = candidate
            bestClearance = clearance
            bestScore = score
        end
    end
    return best, bestClearance
end

local function getPassTarget(root, teammate)
    local distance = flat(teammate.position - root.Position).Magnitude
    local flightSeconds = math.clamp(
        PASS_MIN_FLIGHT_SECONDS + distance / 115,
        PASS_MIN_FLIGHT_SECONDS,
        PASS_MAX_FLIGHT_SECONDS
    )
    local lead = flat(teammate.root.AssemblyLinearVelocity)
        * math.min(flightSeconds, RECEIVER_LEAD_LIMIT)
    if lead.Magnitude > 12 then
        lead = lead.Unit * 12
    end
    local target = teammate.position + lead
    return Vector3.new(target.X, root.Position.Y, target.Z), flightSeconds
end

local function choosePass(root, teammates, opponents, opponentGoal)
    local forward = flat(opponentGoal.center - root.Position)
    if forward.Magnitude < 0.1 then
        return nil
    end
    forward = forward.Unit
    local best
    local bestScore = -math.huge
    for _, teammate in ipairs(teammates) do
        local target, flightSeconds = getPassTarget(root, teammate)
        local offset = flat(target - root.Position)
        local distance = offset.Magnitude
        if distance >= 7 and distance <= 70 then
            local progress = offset:Dot(forward)
            local clearance = laneClearance(
                root.Position,
                target,
                opponents,
                math.min(flightSeconds, 0.55)
            )
            local targetPressure = 60
            for _, opponent in ipairs(opponents) do
                targetPressure = math.min(
                    targetPressure,
                    flat(opponent.position - target).Magnitude
                )
            end
            local score = progress * 1.1
                + math.min(clearance, 24) * 2
                + math.min(targetPressure, 20) * 0.8
                - distance * 0.2
            if clearance >= MIN_LANE_CLEARANCE and score > bestScore then
                bestScore = score
                best = {
                    player = teammate.player,
                    side = teammate.side,
                    agentId = teammate.player:GetAttribute("AgentId"),
                    target = target,
                    clearance = clearance,
                    targetPressure = targetPressure,
                    score = score,
                    distance = distance,
                    flightSeconds = flightSeconds
                }
            end
        end
    end
    return best
end

local function chooseSelfPass(root, opponentGoal, opponents)
    local forward = flat(opponentGoal.center - root.Position)
    if forward.Magnitude < 0.1 then
        return nil
    end
    forward = forward.Unit
    local right = Vector3.new(forward.Z, 0, -forward.X)
    local candidates = {
        root.Position + forward * 13 + right * 7,
        root.Position + forward * 16 - right * 7,
        root.Position + forward * 19 + right * 3,
        root.Position + forward * 19 - right * 3
    }
    local best
    local bestScore = -math.huge
    for _, candidate in ipairs(candidates) do
        candidate = Vector3.new(candidate.X, root.Position.Y, candidate.Z)
        local clearance, wallBlocked = laneClearance(root.Position, candidate, opponents, 0.3)
        if not wallBlocked and clearance >= SELF_PASS_MIN_CLEARANCE then
            local receiverSpace = 60
            for _, opponent in ipairs(opponents) do
                local projected = predictEntryPosition(opponent, 0.35)
                receiverSpace = math.min(receiverSpace, flat(projected - candidate).Magnitude)
            end
            if receiverSpace >= SELF_PASS_MIN_RECEIVER_SPACE then
                local progress = flat(candidate - root.Position):Dot(forward)
                local score = progress * 1.1
                    + math.min(clearance, 24) * 1.45
                    + math.min(receiverSpace, 24) * 1.15
                if score > bestScore then
                    bestScore = score
                    best = {
                        target = candidate,
                        distance = flat(candidate - root.Position).Magnitude,
                        clearance = clearance,
                        receiverSpace = receiverSpace,
                        score = score
                    }
                end
            end
        end
    end
    return best
end

local function chooseShot(root, opponentGoal, opponents)
    local goalkeeper
    for _, opponent in ipairs(opponents) do
        if isGoalkeeper(opponent) then
            goalkeeper = opponent
            break
        end
    end
    local rightAxis = opponentGoal.rightAxis
    local halfWidth = math.max(1, opponentGoal.halfWidth or (opponentGoal.maxX - opponentGoal.minX) / 2)
    local usableHalfWidth = math.max(0.5, halfWidth - GOAL_POST_MARGIN)
    local targetY = root.Position.Y + 1.15
    local function goalTarget(lateral)
        local point = opponentGoal.center + rightAxis * lateral
        return Vector3.new(point.X, targetY, point.Z)
    end
    local candidates = {
        goalTarget(-usableHalfWidth),
        goalTarget(-usableHalfWidth * 0.44),
        goalTarget(0),
        goalTarget(usableHalfWidth * 0.44),
        goalTarget(usableHalfWidth)
    }
    local best
    local bestScore = -math.huge
    for _, target in ipairs(candidates) do
        local clearance = laneClearance(root.Position, target, opponents, 0.25)
        local distance = flat(target - root.Position).Magnitude
        local targetLateral = flat(target - opponentGoal.center):Dot(rightAxis)
        local goalkeeperLateral = goalkeeper
            and flat(goalkeeper.position - opponentGoal.center):Dot(rightAxis)
            or nil
        local goalkeeperSeparation = goalkeeperLateral
            and math.abs(goalkeeperLateral - targetLateral)
            or usableHalfWidth * 2
        local goalkeeperPenalty = goalkeeper
            and math.clamp(
                (GOALKEEPER_AVOID_RADIUS - goalkeeperSeparation) / GOALKEEPER_AVOID_RADIUS,
                0,
                1
            )
            or 0
        local score = math.min(clearance, 25) * 1.75
            + math.min(goalkeeperSeparation, usableHalfWidth * 2) * 1.5
            - goalkeeperPenalty * 7
            - distance * 0.1
        if score > bestScore then
            bestScore = score
            best = {
                target = target,
                clearance = clearance,
                distance = distance,
                score = score,
                goalkeeper = goalkeeper,
                goalkeeperSeparation = goalkeeperSeparation,
                goalkeeperPenalty = goalkeeperPenalty
            }
        end
    end
    return best
end

local function aimAlignment(root, target)
    local camera = Workspace.CurrentCamera
    if not camera then
        return -1
    end
    local desired = flat(target - root.Position)
    local look = flat(camera.CFrame.LookVector)
    if desired.Magnitude < 0.1 or look.Magnitude < 0.1 then
        return -1
    end
    return desired.Unit:Dot(look.Unit)
end

local function stopSprinting(reason)
    if not state.autoSprinting then
        return
    end
    local held = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
        or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
    if not held then
        pcall(function()
            MovementController:SetSprintingControlState(false)
        end)
    end
    state.autoSprinting = false
    addEvent("sprint_stop", { reason = reason })
end

local function stopMoving(reason)
    stopSprinting(reason)
    if state.walking then
        local _, root, humanoid = getCharacter()
        if root and humanoid then
            pcall(function()
                humanoid:MoveTo(root.Position)
            end)
        end
    end
    state.walking = false
end

local function moveTo(root, humanoid, target, context, forceSprint)
    if not target then
        stopMoving("no target")
        return
    end
    local delta = flat(target - root.Position)
    if delta.Magnitude <= MOVE_DEADZONE then
        stopMoving("target reached")
        return
    end
    local now = os.clock()
    local moveHz = forceSprint and REALTIME_MOVE_HZ or MOVE_UPDATE_HZ
    if now - state.lastMoveAt < 1 / moveHz then
        return
    end
    state.lastMoveAt = now
    local shouldSprint = (delta.Magnitude >= SPRINT_DISTANCE or forceSprint == true)
        and (not context or not context.stamina or context.stamina >= SPRINT_STAMINA_MIN)
    if shouldSprint and not state.autoSprinting then
        local ok = pcall(Sprint.Activate)
        if ok then
            state.autoSprinting = true
            addEvent("sprint_start", {})
        end
    elseif not shouldSprint then
        stopSprinting("near target")
    end
    local destination = root.Position + delta.Unit * math.min(delta.Magnitude, MOVE_STEP)
    destination = Vector3.new(destination.X, root.Position.Y, destination.Z)
    local ok, errorMessage = pcall(function()
        humanoid:MoveTo(destination)
    end)
    if not ok then
        state.lastError = "MoveTo failed: " .. safeText(errorMessage)
        stopMoving("move error")
        return
    end
    state.walking = true
    state.movementCommands = state.movementCommands + 1
end

local function startChargedAction(kind, startFunction, releaseFunction, chargeSeconds, target, metadata)
    if state.pendingAction then
        return false
    end
    local startedAt = os.clock()
    local pending = {
        kind = kind,
        startedAt = startedAt,
        target = target,
        requiresPossession = true,
        metadata = metadata or {}
    }
    state.pendingAction = pending
    local ok, errorMessage = pcall(startFunction)
    if not ok then
        state.pendingAction = nil
        state.lastError = kind .. " start failed: " .. safeText(errorMessage)
        addEvent("action_error", { kind = kind, error = state.lastError })
        return false
    end
    task.delay(chargeSeconds, function()
        if not state.running or state.pendingAction ~= pending then
            return
        end
        if pending.requiresPossession and not state.hasPossession then
            pcall(PrepareShot.CancelPreparedShot)
            state.pendingAction = nil
            addEvent("action_cancelled", {
                kind = kind,
                reason = "possession changed before release"
            })
            return
        end
        if type(pending.metadata.validate) == "function" then
            local validated, allowed, reason = pcall(pending.metadata.validate)
            if not validated or allowed ~= true then
                pcall(PrepareShot.CancelPreparedShot)
                state.pendingAction = nil
                local rejectionReason = validated and reason or "target validation failed"
                if kind == "PASS" then
                    rejectPass(rejectionReason)
                end
                addEvent("action_cancelled", {
                    kind = kind,
                    reason = safeText(rejectionReason)
                })
                return
            end
        end
        local released, releaseError = pcall(releaseFunction)
        state.pendingAction = nil
        if not released then
            state.lastError = kind .. " release failed: " .. safeText(releaseError)
            addEvent("action_error", { kind = kind, error = state.lastError })
            return
        end
        state.recentRelease = {
            kind = kind,
            at = os.clock(),
            target = target,
            emergency = pending.metadata.emergency == true
        }
        addEvent("action_released", {
            kind = kind,
            target = target,
            emergency = pending.metadata.emergency == true
        })
    end)
    return true
end

local function chargeForTarget(velocityRange, maxCharge, distance, pressure, clearance)
    local minimum = velocityRange and velocityRange.Min or 30
    local maximum = velocityRange and velocityRange.Max or 120
    local flightSeconds = math.clamp(
        PASS_MIN_FLIGHT_SECONDS + distance / 115,
        PASS_MIN_FLIGHT_SECONDS,
        PASS_MAX_FLIGHT_SECONDS
    )
    local desiredSpeed = distance / flightSeconds
    local ratio = math.clamp(
        (desiredSpeed - minimum) / math.max(1, maximum - minimum),
        0.12,
        0.9
    )
    if pressure and pressure < 12 then
        ratio = ratio + math.clamp((12 - pressure) / 55, 0, 0.16)
    end
    if clearance and clearance < 10 then
        ratio = ratio + math.clamp((10 - clearance) / 70, 0, 0.1)
    end
    return math.clamp(maxCharge * ratio, 0.09, maxCharge * 0.94)
end

local function chargeForShot(velocityRange, maxCharge, distance, clearance, closeFinish)
    local minimum = velocityRange and velocityRange.Min or 32
    local maximum = velocityRange and velocityRange.Max or 138
    local flightSeconds = math.clamp(0.26 + distance / 150, 0.26, 0.8)
    local desiredSpeed = math.max(closeFinish and 78 or 52, distance / flightSeconds)
    local minimumRatio = closeFinish and 0.5 or 0.32
    local ratio = math.clamp(
        (desiredSpeed - minimum) / math.max(1, maximum - minimum),
        minimumRatio,
        0.92
    )
    if clearance and clearance < SAFE_SHOT_CLEARANCE then
        ratio = ratio + math.clamp((SAFE_SHOT_CLEARANCE - clearance) / 45, 0, 0.12)
    end
    return math.clamp(maxCharge * ratio, 0.12, maxCharge * 0.96)
end

local function beginPass(plan)
    local cooldown = plan.emergencyRelease and math.min(PASS_COOLDOWN, 0.65)
        or PASS_COOLDOWN
    if os.clock() - state.lastPassAt < cooldown then
        return false
    end
    local confirmed, rejectionReason = isConfirmedPassTarget(
        plan.pass.player,
        plan.ownSide,
        plan.pass.agentId
    )
    if not confirmed then
        rejectPass(rejectionReason)
        return false
    end
    local maximum = tonumber(FootballDefaults.ChargeTimes.Pass) or 0.5
    local charge = chargeForTarget(
        FootballDefaults.Velocity.Pass,
        maximum,
        plan.pass.distance,
        plan.pass.targetPressure,
        plan.pass.clearance
    )
    if startChargedAction(
        "PASS",
        ActionSecondary.start,
        ActionSecondary.release,
        charge,
        plan.pass.target,
        {
            emergency = plan.emergencyRelease,
            validate = function()
                return isConfirmedPassTarget(
                    plan.pass.player,
                    plan.ownSide,
                    plan.pass.agentId
                )
            end
        }
    ) then
        state.lastPassAt = os.clock()
        state.lastPassCharge = charge
        state.passes = state.passes + 1
        if plan.emergencyRelease then
            state.emergencyReleases = state.emergencyReleases + 1
        end
        return true
    end
    return false
end

local function beginSelfPass(plan)
    if not state.autoSelfPass or os.clock() - state.lastSelfPassAt < SELF_PASS_COOLDOWN then
        return false
    end
    local maximum = tonumber(FootballDefaults.ChargeTimes.Kick)
        or tonumber(FootballDefaults.ChargeTimes.Pass)
        or 0.6
    local velocity = FootballDefaults.Velocity.Kick
    local minimum = velocity and velocity.Min or 32
    local topSpeed = velocity and velocity.Max or 138
    local desiredSpeed = math.max(64, plan.selfPass.distance / 0.34)
    local ratio = math.clamp(
        (desiredSpeed - minimum) / math.max(1, topSpeed - minimum),
        0.36,
        0.62
    )
    local charge = math.clamp(maximum * ratio, 0.16, maximum * 0.78)
    if startChargedAction(
        "SELF_PASS",
        ActionPrimary.start,
        ActionPrimary.release,
        charge,
        plan.selfPass.target,
        { selfPass = true }
    ) then
        state.lastSelfPassAt = os.clock()
        state.lastShotCharge = charge
        state.selfPasses = state.selfPasses + 1
        addEvent("self_pass", {
            distance = plan.selfPass.distance,
            clearance = plan.selfPass.clearance
        })
        return true
    end
    return false
end

local function beginShot(plan)
    if os.clock() - state.lastShotAt < SHOT_COOLDOWN then
        return false
    end
    -- ActionPrimary starts the game's normal "Kick". Kick has no dedicated
    -- ChargeTimes entry, so PrepareShot falls back to the normal Pass window.
    -- PowerShot's shorter window only applies while that equipped skill is
    -- already active; using it for every click-kick undercharged normal shots.
    local maximum = tonumber(FootballDefaults.ChargeTimes.Kick)
        or tonumber(FootballDefaults.ChargeTimes.Pass)
        or 0.55
    local charge = chargeForShot(
        FootballDefaults.Velocity.Kick,
        maximum,
        plan.shot.distance,
        plan.shot.clearance,
        plan.closeFinish == true
    )
    if startChargedAction("KICK", ActionPrimary.start, ActionPrimary.release, charge, plan.shot.target) then
        state.lastShotAt = os.clock()
        state.lastShotCharge = charge
        state.shots = state.shots + 1
        return true
    end
    return false
end

local function beginDribble()
    if os.clock() - state.lastDribbleAt < DRIBBLE_COOLDOWN then
        return false
    end
    local ok, errorMessage = pcall(Dribble.Activate)
    if not ok then
        state.lastError = "Dribble failed: " .. safeText(errorMessage)
        return false
    end
    state.lastDribbleAt = os.clock()
    state.dribbles = state.dribbles + 1
    addEvent("dribble", {})
    return true
end

local function beginRequestPass(plan, context)
    if not state.autoRequestPass or not plan.carrier or not plan.requestEligible then
        return false
    end
    if not actionAllowed(context, "REQUEST") then
        return false
    end
    if os.clock() - state.lastRequestAt < REQUEST_COOLDOWN then
        return false
    end
    local ok, errorMessage = pcall(RequestBall.Activate)
    if not ok then
        state.lastError = "Pass request failed: " .. safeText(errorMessage)
        addEvent("request_error", { error = state.lastError })
        return false
    end
    state.lastRequestAt = os.clock()
    state.requests = state.requests + 1
    addEvent("pass_requested", {
        carrier = plan.carrier.player.Name,
        clearance = plan.requestClearance
    })
    return true
end

local function beginSteal(root, plan, context)
    if not state.autoSteal or not plan.carrier then
        return false, "steal disabled"
    end
    if isGoalkeeper(plan.carrier) then
        return false, "goalkeeper protected"
    end
    if not actionAllowed(context, "TACKLE") then
        return false, "tackle state blocked"
    end
    if os.clock() - state.lastStealAt < STEAL_COOLDOWN then
        return false, "steal cooldown"
    end
    local delta = flat((plan.stealTarget or plan.carrier.position) - root.Position)
    if delta.Magnitude > STEAL_DISTANCE then
        return false, "close distance"
    end
    local look = flat(root.CFrame.LookVector)
    local alignment = look.Magnitude > 0.1 and delta.Magnitude > 0.1
        and look.Unit:Dot(delta.Unit)
        or -1
    if alignment < STEAL_AIM_ALIGNMENT then
        return false, "face carrier"
    end
    state.lastStealAt = os.clock()
    state.stealAttempts = state.stealAttempts + 1
    local ok, errorMessage = pcall(Tackle.Activate)
    if not ok then
        state.lastError = "Tackle failed: " .. safeText(errorMessage)
        addEvent("steal_error", { error = state.lastError })
        return false, "steal error"
    end
    local slideVelocity = root:FindFirstChild("SlideVelocity")
    if slideVelocity and slideVelocity.Enabled then
        state.steals = state.steals + 1
        addEvent("steal_started", { distance = delta.Magnitude })
        return true, "auto steal"
    end
    addEvent("steal_blocked", { distance = delta.Magnitude })
    return false, "steal unavailable"
end

local function getInterceptTarget(root, ball, pursuitSpeed)
    local velocity = flat(ball.AssemblyLinearVelocity)
    local relative = flat(ball.Position - root.Position)
    if velocity.Magnitude < 4 then
        return Vector3.new(ball.Position.X, root.Position.Y, ball.Position.Z), 0
    end
    local speedSquared = velocity:Dot(velocity)
    local runnerSpeed = math.max(1, tonumber(pursuitSpeed) or INTERCEPT_SPEED)
    local runnerSquared = runnerSpeed * runnerSpeed
    local a = speedSquared - runnerSquared
    local b = 2 * relative:Dot(velocity)
    local c = relative:Dot(relative)
    local time
    if math.abs(a) < 0.001 then
        if math.abs(b) > 0.001 then
            local candidate = -c / b
            time = candidate > 0 and candidate or nil
        end
    else
        local discriminant = b * b - 4 * a * c
        if discriminant >= 0 then
            local sqrtDiscriminant = math.sqrt(discriminant)
            local first = (-b - sqrtDiscriminant) / (2 * a)
            local second = (-b + sqrtDiscriminant) / (2 * a)
            if first > 0 and second > 0 then
                time = math.min(first, second)
            else
                time = math.max(first, second)
            end
        end
    end
    time = math.clamp(tonumber(time) or 0.25, 0.1, MAX_INTERCEPT_SECONDS)
    local target = ball.Position + velocity * time
    return Vector3.new(target.X, root.Position.Y, target.Z), time
end

local function buildPlan(character, root, humanoid, context)
    local ownSide, opponentSide = getSides()
    local opponentGoal = opponentSide and getGoal(opponentSide)
    local ownGoal = ownSide and getGoal(ownSide)
    if not ownSide or not opponentGoal or not ownGoal then
        return { kind = "WAIT", reason = "team or goal unavailable" }
    end
    local teammates, opponents, carrier, agents = getPlayersBySide(ownSide)
    local hasBall = LocalPlayer:GetAttribute("HasBall") == true
    local ball = getBall(root)
    local ballPosition = ball and ball.Position
    local ballIsReleased = ball and ball:GetAttribute("State") == "Released"
    local possessor = ball and not ballIsReleased
        and agents[safeText(ball:GetAttribute("PossessorId"))]
    if possessor then
        ballPosition = possessor.position
        if possessor.player == LocalPlayer then
            hasBall = true
        else
            carrier = possessor
        end
    elseif ball and not isUsableBallPosition(ball.Position, root) then
        -- Ignore hidden or recycled balls when no live player owns them.
        ball = nil
        ballPosition = nil
    end
    local plan = {
        kind = "POSITION",
        reason = "open support lane",
        root = root.Position,
        ball = ballPosition,
        hasBall = hasBall,
        ownSide = ownSide,
        ownerSide = hasBall and ownSide or (carrier and carrier.side),
        opponentGoal = opponentGoal.center,
        teammates = teammates,
        opponents = opponents
    }
    plan.pursuitSpeed = estimatePursuitSpeed(humanoid, context, hasBall)
    state.predictedBall = nil
    state.predictedBallSeconds = 0
    if ball and ballIsReleased and ballPosition then
        local velocity = flat(ball.AssemblyLinearVelocity)
        if velocity.Magnitude >= 4 then
            plan.predictedBallSeconds = math.min(BALL_TRAJECTORY_SECONDS, MAX_INTERCEPT_SECONDS)
            local projected = ballPosition + velocity * plan.predictedBallSeconds
            plan.predictedBall = Vector3.new(projected.X, ballPosition.Y, projected.Z)
            state.predictedBall = plan.predictedBall
            state.predictedBallSeconds = plan.predictedBallSeconds
        end
    end
    if hasBall then
        state.possessionStartedAt = state.possessionStartedAt or os.clock()
        local shot = chooseShot(root, opponentGoal, opponents)
        local pass = choosePass(root, teammates, opponents, opponentGoal)
        local selfPass = chooseSelfPass(root, opponentGoal, opponents)
        local pathTarget, pathReason, pathClearance = choosePathTarget(
            root,
            opponentGoal,
            opponents,
            plan.pursuitSpeed
        )
        plan.moveTarget = pathTarget
        plan.pathReason = pathReason
        plan.pathClearance = pathClearance
        plan.shot = shot
        plan.pass = pass
        plan.selfPass = selfPass
        local _, pressureDistance = nearestOpponent(root, opponents)
        plan.pressureDistance = pressureDistance
        local holdRisk, holdReason, nearestDefender, closingSpeed, contestedDefenders,
            turnoverDeadline, releaseThreshold, shieldThreshold = assessHoldRisk(
            root,
            opponents,
            pass,
            context
        )
        plan.holdRisk = holdRisk
        plan.holdReason = holdReason
        plan.nearestDefender = nearestDefender
        plan.closingSpeed = closingSpeed
        plan.contestedDefenders = contestedDefenders
        plan.turnoverDeadline = turnoverDeadline
        plan.releaseThreshold = releaseThreshold
        plan.shieldThreshold = shieldThreshold
        plan.emergencyRelease = turnoverDeadline <= EMERGENCY_RELEASE_DEADLINE
        state.holdRisk = holdRisk
        state.holdReason = holdReason
        state.turnoverDeadline = turnoverDeadline
        state.contestedDefenders = contestedDefenders
        plan.possessionSettled = os.clock() - state.possessionStartedAt
            >= POSSESSION_SETTLE_SECONDS
        plan.possessionAge = os.clock() - state.possessionStartedAt
        plan.closeFinishAvailable = shot
            and shot.distance <= CLOSE_SHOOT_RANGE
            and shot.clearance >= CLOSE_SHOT_CLEARANCE
            and plan.possessionAge >= QUICK_FINISH_SETTLE_SECONDS
        plan.lowStamina = context.stamina and context.stamina < SPRINT_STAMINA_MIN
        plan.preemptiveDribble = nearestDefender
            and pressureDistance <= PREEMPTIVE_DRIBBLE_DISTANCE
            and closingSpeed >= PREEMPTIVE_CLOSING_SPEED
        if not plan.possessionSettled and not plan.closeFinishAvailable then
            local secureTarget, secureReason, secureClearance = chooseRetentionTarget(
                root,
                ownGoal,
                opponentGoal,
                opponents,
                plan.pursuitSpeed
            )
            plan.kind = "DRIBBLE"
            plan.reason = "secure new possession"
            plan.moveTarget = secureTarget
            plan.pathReason = secureReason
            plan.pathClearance = secureClearance
        elseif plan.closeFinishAvailable and turnoverDeadline > 0.18 then
            plan.kind = "SHOOT"
            plan.reason = "close finish away from goalkeeper"
            plan.closeFinish = true
            plan.aimAlignment = aimAlignment(root, shot.target)
        elseif plan.lowStamina and pass and pass.clearance >= SAFE_PASS_CLEARANCE
            and pass.targetPressure >= DANGER_DISTANCE then
            plan.kind = "PASS"
            plan.reason = "stamina-safe release"
            plan.aimAlignment = aimAlignment(root, pass.target)
        elseif plan.emergencyRelease or holdRisk >= releaseThreshold then
            if pass and pass.clearance >= SAFE_PASS_CLEARANCE
                and (plan.emergencyRelease or pass.targetPressure >= DANGER_DISTANCE) then
                plan.kind = "PASS"
                plan.reason = plan.emergencyRelease
                    and "emergency safe release"
                    or "safe release before tackle"
                plan.aimAlignment = aimAlignment(root, pass.target)
            else
                local secureTarget, secureReason, secureClearance = chooseRetentionTarget(
                    root,
                    ownGoal,
                    opponentGoal,
                    opponents,
                    plan.pursuitSpeed
                )
                plan.kind = "DRIBBLE"
                plan.reason = secureReason
                plan.moveTarget = secureTarget
                plan.pathReason = secureReason
                plan.pathClearance = secureClearance
            end
        elseif plan.preemptiveDribble or holdRisk >= shieldThreshold then
            local secureTarget, secureReason, secureClearance = chooseRetentionTarget(
                root,
                ownGoal,
                opponentGoal,
                opponents,
                plan.pursuitSpeed
            )
            plan.kind = "DRIBBLE"
            plan.reason = secureReason
            plan.moveTarget = secureTarget
            plan.pathReason = secureReason
            plan.pathClearance = secureClearance
        elseif shot and shot.distance <= math.min(SHOOT_RANGE, PREFERRED_SHOOT_RANGE)
            and shot.clearance >= SAFE_SHOT_CLEARANCE
            and (not pass or shot.clearance >= pass.clearance + SHOT_OVER_PASS_CLEARANCE) then
            plan.kind = "SHOOT"
            plan.reason = "high-quality scoring lane"
            plan.aimAlignment = aimAlignment(root, shot.target)
        elseif shot and shot.distance <= math.min(SHOOT_RANGE, LONG_SHOT_MAX_RANGE)
            and shot.clearance >= LONG_SHOT_MIN_CLEARANCE
            and shot.goalkeeperSeparation >= GOALKEEPER_AVOID_RADIUS
            and (not pass or shot.score >= pass.score + SHOT_OVER_PASS_CLEARANCE) then
            plan.kind = "SHOOT"
            plan.reason = "clear long-range finish"
            plan.aimAlignment = aimAlignment(root, shot.target)
        elseif pass and pass.clearance >= SAFE_PASS_CLEARANCE
            and (pass.clearance >= pathClearance * 0.72
            or pass.targetPressure >= 13) then
            plan.kind = "PASS"
            plan.reason = "best teammate lane"
            plan.aimAlignment = aimAlignment(root, pass.target)
        elseif selfPass and not plan.lowStamina
            and (not pass or selfPass.clearance >= pass.clearance) then
            plan.kind = "SELF_PASS"
            plan.reason = "self-pass into open space"
            plan.aimAlignment = aimAlignment(root, selfPass.target)
        else
            plan.kind = "DRIBBLE"
            plan.reason = "carry into open lane"
        end
        return plan
    end
    state.possessionStartedAt = nil
    if carrier and carrier.side == ownSide then
        local target, clearance = chooseSupportTarget(
            root,
            carrier,
            ownGoal,
            opponentGoal,
            opponents,
            teammates
        )
        plan.kind = "SUPPORT"
        plan.reason = "open for teammate"
        plan.moveTarget = target
        plan.carrier = carrier
        plan.requestClearance = clearance
        plan.pass = { target = carrier.position, player = carrier.player, clearance = clearance }
        local carrierDistance = flat(carrier.position - root.Position).Magnitude
        local playerProgress = fieldProgress(root.Position, ownGoal, opponentGoal)
        local goalkeeperCarrier = isGoalkeeper(carrier)
        plan.requestEligible = not goalkeeperCarrier
            or (playerProgress >= GK_REQUEST_MIN_PROGRESS
                and carrierDistance >= GK_REQUEST_MIN_DISTANCE
                and clearance >= GK_REQUEST_MIN_CLEARANCE)
        plan.requestReason = goalkeeperCarrier and not plan.requestEligible
            and "advance for goalkeeper pass"
            or "open for pass"
        return plan
    end
    if carrier then
        if isGoalkeeper(carrier) then
            plan.kind = "BLOCK"
            plan.reason = "block goalkeeper outlet"
            plan.moveTarget = chooseGoalkeeperOutletBlock(root, carrier, opponents)
        else
            local predictedTarget, predictedSeconds = getInterceptTarget(
                root,
                carrier.root,
                plan.pursuitSpeed
            )
            local lead = flat(carrier.root.AssemblyLinearVelocity) * STEAL_APPROACH_LEAD
            local cutoff = predictedTarget + lead
            plan.kind = "PRESS"
            plan.reason = predictedSeconds > 0
                and "predict carrier cutoff"
                or "cut off ball carrier"
            local carrierDistance = flat(carrier.position - root.Position).Magnitude
            local approachTarget = carrierDistance <= STEAL_APPROACH_DISTANCE
                and carrier.position
                or cutoff
            plan.moveTarget = Vector3.new(
                approachTarget.X,
                root.Position.Y,
                approachTarget.Z
            )
            plan.stealTarget = carrier.position
            plan.carrierInterceptSeconds = predictedSeconds
        end
        plan.distance = flat(carrier.position - root.Position).Magnitude
        plan.carrier = carrier
        return plan
    end
    if ball then
        local offset = flat(ball.Position - root.Position)
        local target, interceptSeconds = getInterceptTarget(root, ball, plan.pursuitSpeed)
        plan.kind = "PRESS"
        plan.reason = interceptSeconds > 0 and "intercept loose pass" or "pursue loose ball"
        plan.moveTarget = target
        plan.distance = offset.Magnitude
        plan.interceptSeconds = interceptSeconds
        return plan
    end
    plan.moveTarget = ownGoal.center:Lerp(opponentGoal.center, 0.5)
    plan.reason = "reset central support"
    return plan
end

local function executePlan(character, root, humanoid, plan, context)
    if not state.autoPlay then
        stopMoving("auto play disabled")
        state.phase = "OBSERVE"
        state.status = "AUTO PLAY OFF"
        return
    end
    if plan.kind == "WAIT" then
        stopMoving("waiting")
        state.phase = "ACQUIRE"
        state.status = plan.reason
        return
    end
    setAimTarget(plan.moveTarget)
    if not state.assistMode then
        local interceptSeconds = plan.interceptSeconds or plan.carrierInterceptSeconds
        local forceSprint = plan.kind == "PRESS"
            and ((interceptSeconds and interceptSeconds <= 1.1)
                or (plan.distance and plan.distance <= STEAL_APPROACH_DISTANCE))
        moveTo(root, humanoid, plan.moveTarget, context, forceSprint)
    end
    state.phase = plan.kind
    state.status = state.assistMode and "ASSIST // " .. plan.reason or plan.reason
    if plan.kind == "SUPPORT" then
        if beginRequestPass(plan, context) then
            state.status = "PASS REQUESTED"
        elseif not plan.requestEligible then
            state.status = plan.requestReason
        end
        return
    end
    if plan.kind == "PRESS" and plan.carrier then
        setAimTarget(plan.carrier.position)
        local stole, reason = beginSteal(root, plan, context)
        if stole then
            state.status = "AUTO STEAL"
        elseif reason == "face carrier" then
            state.status = "FACE BALL CARRIER"
        end
        return
    end
    if not plan.hasBall or state.pendingAction then
        return
    end
    if not actionAllowed(context, "BALL") then
        state.status = "ACTION STATE BLOCKED"
        return
    end
    if plan.kind == "SHOOT" and state.autoScore then
        setAimTarget(plan.shot.target)
        plan.aimAlignment = cameraAimAlignment(root, plan.shot.target)
        local requiredAlignment = plan.closeFinish
            and math.min(SHOT_AIM_ALIGNMENT, CLOSE_SHOT_AIM_ALIGNMENT)
            or SHOT_AIM_ALIGNMENT
        if plan.aimAlignment >= requiredAlignment then
            if beginShot(plan) then
                state.status = plan.closeFinish and "CLOSE FINISH" or "AUTO KICK"
            end
        else
            state.status = string.format("AIM AT GOAL  %d%%", math.max(0, math.floor(plan.aimAlignment * 100)))
        end
    elseif plan.kind == "SELF_PASS" and state.autoSelfPass then
        setAimTarget(plan.selfPass.target)
        plan.aimAlignment = cameraAimAlignment(root, plan.selfPass.target)
        if plan.aimAlignment >= math.min(PASS_AIM_ALIGNMENT, 0.82) then
            if beginSelfPass(plan) then
                state.status = "SELF PASS"
            end
        else
            state.status = string.format("AIM AT SPACE  %d%%", math.max(0, math.floor(plan.aimAlignment * 100)))
        end
    elseif plan.kind == "PASS" and state.autoPass then
        local confirmed, rejectionReason = isConfirmedPassTarget(
            plan.pass.player,
            plan.ownSide,
            plan.pass.agentId
        )
        if not confirmed then
            rejectPass(rejectionReason)
            state.status = "PASS BLOCKED // " .. safeText(rejectionReason)
            return
        end
        setAimTarget(plan.pass.target)
        plan.aimAlignment = cameraAimAlignment(root, plan.pass.target)
        local requiredAlignment = plan.emergencyRelease
            and math.min(PASS_AIM_ALIGNMENT, EMERGENCY_PASS_AIM_ALIGNMENT)
            or PASS_AIM_ALIGNMENT
        if plan.aimAlignment >= requiredAlignment then
            if beginPass(plan) then
                state.status = plan.emergencyRelease and "EMERGENCY PASS" or "AUTO PASS"
            end
        else
            state.status = string.format("AIM AT PASS  %d%%", math.max(0, math.floor(plan.aimAlignment * 100)))
        end
    elseif plan.kind == "DRIBBLE" and state.autoDribble then
        if beginDribble() then
            state.status = "AUTO DRIBBLE"
        end
    end
end

local function renderGui(force)
    if not state.gui or not state.gui.Parent then
        return
    end
    local now = os.clock()
    if not force and now - state.lastGuiAt < 0.1 then
        return
    end
    state.lastGuiAt = now
    local controls = state.controls
    local plan = state.plan
    controls.status.Text = state.phase .. "  //  " .. state.status
    controls.phase.Text = plan and safeText(plan.kind) or "--"
    controls.target.Text = plan and safeText(plan.reason) or "--"
    if plan and plan.shot then
        controls.lane.Text = string.format("SHOT %.1f  //  LANE %.1f", plan.shot.distance, plan.shot.clearance)
    elseif plan and plan.kind == "SELF_PASS" and plan.selfPass then
        controls.lane.Text = string.format("SELF %.1f  //  SPACE %.1f", plan.selfPass.distance, plan.selfPass.receiverSpace)
    elseif plan and plan.pass then
        controls.lane.Text = string.format("PASS %s  //  LANE %.1f", plan.pass.player.Name, plan.pass.clearance)
    else
        controls.lane.Text = "--"
    end
    controls.counters.Text = string.format(
        "M%d P%d X%d D%d S%d T%d",
        state.movementCommands,
        state.passes,
        state.selfPasses,
        state.dribbles,
        state.shots,
        state.steals
    )
    controls.subtitle.Text = state.autoPlay
        and (state.assistMode
            and "Manual movement + automatic pass, dribble, finish, and reads"
            or "Wall-safe lanes, self-passes, intercepts, steals, passes, kicks")
        or "Observation only"
    controls.playButton.Text = state.autoPlay and "AUTO: ON" or "AUTO: OFF"
    controls.passButton.Text = state.autoPass and "PASS: ON" or "PASS: OFF"
    controls.dribbleButton.Text = state.autoDribble and "DRIB: ON" or "DRIB: OFF"
    controls.scoreButton.Text = state.autoScore and "SCORE: ON" or "SCORE: OFF"
    controls.assistButton.Text = state.assistMode
        and "ASSIST MOVEMENT: ON"
        or "ASSIST MOVEMENT: OFF"
    controls.playButton.BackgroundColor3 = state.autoPlay and Color3.fromRGB(35, 116, 90) or Color3.fromRGB(57, 63, 75)
    controls.passButton.BackgroundColor3 = state.autoPass and Color3.fromRGB(39, 92, 139) or Color3.fromRGB(57, 63, 75)
    controls.dribbleButton.BackgroundColor3 = state.autoDribble and Color3.fromRGB(109, 72, 154) or Color3.fromRGB(57, 63, 75)
    controls.scoreButton.BackgroundColor3 = state.autoScore and Color3.fromRGB(136, 78, 36) or Color3.fromRGB(57, 63, 75)
    controls.assistButton.BackgroundColor3 = state.assistMode
        and Color3.fromRGB(47, 131, 122)
        or Color3.fromRGB(57, 63, 75)
    local _, root = getCharacter()
    if root and plan then
        setWorldLine(controls.moveLine, root.Position, plan.moveTarget)
        setWorldLine(
            controls.passLine,
            root.Position,
            plan.pass and plan.pass.target or (plan.selfPass and plan.selfPass.target)
        )
        setWorldLine(controls.shotLine, root.Position, plan.shot and plan.shot.target)
        setWorldLine(controls.ballLine, plan.ball, plan.predictedBall)
        setWorldLine(
            controls.threatLine,
            plan.hasBall and root.Position or nil,
            plan.nearestDefender and plan.nearestDefender.position or nil
        )
    else
        controls.moveLine.Visible = false
        controls.passLine.Visible = false
        controls.shotLine.Visible = false
        controls.ballLine.Visible = false
        controls.threatLine.Visible = false
    end
end

function state.stop(reason)
    if not state.running then
        return
    end
    state.running = false
    stopMoving("controller stopped")
    state.pendingAction = nil
    if state.connection then
        pcall(function()
            state.connection:Disconnect()
        end)
        state.connection = nil
    end
    if state.cameraConnection then
        pcall(function()
            RunService:UnbindFromRenderStep(state.cameraBindingName)
        end)
        state.cameraConnection = nil
    end
    state.aimTarget = nil
    state.phase = "STOPPED"
    state.status = safeText(reason or "stopped")
    renderGui(true)
end

function state.health()
    return {
        version = state.version,
        running = state.running,
        phase = state.phase,
        status = state.status,
        autoPlay = state.autoPlay,
        autoPass = state.autoPass,
        autoSelfPass = state.autoSelfPass,
        autoDribble = state.autoDribble,
        autoScore = state.autoScore,
        autoRequestPass = state.autoRequestPass,
        autoSteal = state.autoSteal,
        autoAim = state.autoAim,
        assistMode = state.assistMode,
        decisions = state.decisions,
        decisionHz = state.decisionHz,
        context = state.context,
        walking = state.walking,
        autoSprinting = state.autoSprinting,
        pendingAction = state.pendingAction and state.pendingAction.kind or nil,
        plan = state.plan,
        movementCommands = state.movementCommands,
        passes = state.passes,
        passRejects = state.passRejects,
        lastPassRejectReason = state.lastPassRejectReason,
        selfPasses = state.selfPasses,
        wallRejects = state.wallRejects,
        lastPassCharge = state.lastPassCharge,
        dribbles = state.dribbles,
        shots = state.shots,
        lastShotCharge = state.lastShotCharge,
        requests = state.requests,
        stealAttempts = state.stealAttempts,
        steals = state.steals,
        possessionLosses = state.possessionLosses,
        safeReleases = state.safeReleases,
        holdRisk = state.holdRisk,
        holdReason = state.holdReason,
        turnoverDeadline = state.turnoverDeadline,
        contestedDefenders = state.contestedDefenders,
        predictedBall = state.predictedBall,
        predictedBallSeconds = state.predictedBallSeconds,
        adaptiveRiskBias = state.adaptiveRiskBias,
        emergencyReleases = state.emergencyReleases,
        completedReleases = state.completedReleases,
        lastError = state.lastError,
        events = state.events
    }
end

local function updateRateForPlan(plan)
    if not plan then
        return UPDATE_HZ
    end
    if plan.emergencyRelease or (plan.turnoverDeadline and plan.turnoverDeadline <= EMERGENCY_RELEASE_DEADLINE) then
        return CRITICAL_UPDATE_HZ
    end
    local liveIntercept = plan.interceptSeconds or plan.carrierInterceptSeconds
    if liveIntercept and liveIntercept <= 0.8 then
        return LIVE_UPDATE_HZ
    end
    if plan.interceptSeconds or plan.kind == "PRESS" or plan.kind == "BLOCK" then
        return THREAT_UPDATE_HZ
    end
    if plan.kind == "SUPPORT" or plan.hasBall then
        return math.max(UPDATE_HZ, math.floor(THREAT_UPDATE_HZ * 0.75))
    end
    return UPDATE_HZ
end

local function updatePossessionState(plan)
    local now = os.clock()
    if plan.hasBall then
        if not state.hadPossession then
            state.possessionStartedAt = now
            addEvent("possession_gained", {})
        end
        state.pendingPossessionOutcome = nil
        state.hasPossession = true
        state.hadPossession = true
        return
    end

    if state.hadPossession then
        state.pendingPossessionOutcome = {
            at = now,
            release = state.recentRelease
        }
        state.hadPossession = false
        state.possessionStartedAt = nil
    end

    local pending = state.pendingPossessionOutcome
    if pending then
        if plan.ownerSide == plan.ownSide then
            if pending.release then
                state.safeReleases = state.safeReleases + 1
                state.completedReleases = state.completedReleases + 1
                if pending.release.kind == "PASS" then
                    state.adaptiveRiskBias = math.max(
                        0,
                        state.adaptiveRiskBias - ADAPTIVE_RISK_STEP * 0.5
                    )
                end
                addEvent("release_retained_by_team", { kind = pending.release.kind })
            else
                addEvent("possession_recovered_by_team", {})
            end
            state.pendingPossessionOutcome = nil
        elseif plan.ownerSide and plan.ownerSide ~= plan.ownSide then
            state.possessionLosses = state.possessionLosses + 1
            state.adaptiveRiskBias = math.min(
                MAX_ADAPTIVE_RISK_BIAS,
                state.adaptiveRiskBias + (pending.release and ADAPTIVE_RISK_STEP or ADAPTIVE_RISK_STEP * 0.75)
            )
            addEvent(pending.release and "release_lost" or "possession_lost", {
                kind = pending.release and pending.release.kind or "HOLD"
            })
            state.pendingPossessionOutcome = nil
        elseif now - pending.at > 1.8 then
            addEvent("possession_outcome_unresolved", {})
            state.pendingPossessionOutcome = nil
        end
    end
    state.hasPossession = false
end

createGui()
renderGui(true)

RunService:BindToRenderStep(
    state.cameraBindingName,
    Enum.RenderPriority.Camera.Value + 1,
    function(deltaTime)
    if not state.running or not state.autoAim or not state.aimTarget then
        return
    end
    local _, root = getCharacter()
    if not root then
        return
    end
    local turnRate = state.plan and state.plan.closeFinish
        and CLOSE_AIM_TURN_RATE
        or AIM_TURN_RATE
    local blend = math.clamp(1 - math.exp(-turnRate * deltaTime), 0, 0.95)
    turnCameraToward(root, state.aimTarget, blend)
    end
)
state.cameraConnection = true

state.connection = RunService.Heartbeat:Connect(function()
    if not state.running then
        return
    end
    if LocalPlayer:GetAttribute("TeamRole") == "Goalkeeper" then
        stopMoving("goalkeeper excluded")
        state.aimTarget = nil
        state.phase = "STANDBY"
        state.status = "GOALKEEPER EXCLUDED"
        state.plan = nil
        renderGui()
        return
    end
    local character, root, humanoid = getCharacter()
    if not character or controlsBlocked() or LocalPlayer:GetAttribute("IsOnPitch") == false then
        stopMoving("waiting for field")
        state.aimTarget = nil
        state.phase = "ACQUIRE"
        state.status = "WAITING FOR FIELD"
        state.plan = nil
        renderGui()
        return
    end
    local context = getPlayerContext(humanoid)
    state.context = context
    if context.blocked then
        stopMoving("match or animation state blocked")
        state.aimTarget = nil
        state.phase = "ACQUIRE"
        state.status = context.specialAnimation and "SPECIAL ANIMATION"
            or context.intermission and "MATCH INTERMISSION"
            or context.celebrating and "CELEBRATION"
            or context.spectating and "SPECTATING"
            or "MATCH STATE BLOCKED"
        state.plan = nil
        renderGui()
        return
    end
    if context.airborne or context.sliding then
        stopMoving(context.airborne and "airborne" or "sliding")
        state.phase = "ACQUIRE"
        state.status = context.airborne and "AIRBORNE" or "SLIDING"
        renderGui()
        return
    end
    local now = os.clock()
    if now - state.lastDecisionAt >= 1 / state.decisionHz then
        state.lastDecisionAt = now
        state.decisions = state.decisions + 1
        state.plan = buildPlan(character, root, humanoid, context)
        updatePossessionState(state.plan)
        state.decisionHz = updateRateForPlan(state.plan)
        executePlan(character, root, humanoid, state.plan, context)
    end
    renderGui()
end)

log("Solo Player v1 started; use STOP SOLO PLAY or state.stop() to end")
return state
