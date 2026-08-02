-- Chicken Farm development controller.
--
-- Designed only for the Chicken Farm experience (universe 10209534490) that
-- the developer has authorized. It uses the game's existing Paper.Network
-- commands, retains the server as the source of truth, and never changes cash,
-- inventory, or character transforms locally.

local RuntimeEnv = getgenv and getgenv() or _G
local previous = RuntimeEnv.__RBA_CHICKEN_FARM
if previous and type(previous.stop) == "function" then
    pcall(previous.stop, "reloaded")
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
local EXPECTED_GAME_ID = 10209534490

assert(game.GameId == EXPECTED_GAME_ID, "Chicken Farm controller loaded in the wrong experience")

local config = RuntimeEnv.RBA_CHICKEN_FARM_CONFIG or {}
local RAYFIELD_URL = config.rayfieldUrl
    or "https://raw.githubusercontent.com/SiriusSoftwareLtd/Rayfield/main/source.lua"
local function setting(name, fallback)
    local value = config[name]
    return value == nil and fallback or value
end

local state = {
    version = 1,
    running = true,
    enabled = setting("enabled", true),
    autoCollectEggs = setting("autoCollectEggs", true),
    autoDepositEggs = setting("autoDepositEggs", true),
    autoClaimCash = setting("autoClaimCash", true),
    autoBuyFive = setting("autoBuyFive", true),
    autoMerge = setting("autoMerge", false),
    autoUpgradeProcess = setting("autoUpgradeProcess", false),
    autoUpgradeTier = setting("autoUpgradeTier", false),
    depositThreshold = math.clamp(tonumber(setting("depositThreshold", 25)) or 25, 1, 10000),
    pending = nil,
    status = "INITIALIZING",
    lastError = nil,
    lastActionAt = {},
    attempted = {
        collect = 0,
        deposit = 0,
        cash = 0,
        buyFive = 0,
        merge = 0,
        process = 0,
        tier = 0
    },
    succeeded = {
        deposit = 0,
        cash = 0,
        buyFive = 0,
        merge = 0,
        process = 0,
        tier = 0
    },
    recentlyCollected = {},
    ui = nil,
    connection = nil
}
RuntimeEnv.__RBA_CHICKEN_FARM = state

-- Define the lifecycle immediately, before any operation that may yield. This
-- makes a rapid reload safe even while Paper is still loading player stats.
function state.stop(reason)
    if not state.running then
        return
    end
    state.running = false
    state.enabled = false
    state.status = reason or "Stopped"
    if state.connection then
        state.connection:Disconnect()
        state.connection = nil
    end
end

local Paper = require(ReplicatedStorage:WaitForChild("Paper"))
Paper.Stats.LoadedAsync()

local function now()
    return os.clock()
end

local function ready(action, cooldown)
    return now() - (state.lastActionAt[action] or -math.huge) >= cooldown
end

local function mark(action)
    state.lastActionAt[action] = now()
end

local function getStat(name, fallback)
    local ok, value = pcall(Paper.Stats.GetValue, name)
    return ok and value ~= nil and value or fallback
end

local function invoke(action, command, ...)
    if state.pending then
        return false, "busy"
    end
    state.pending = action
    state.attempted[action] = (state.attempted[action] or 0) + 1
    local packed = table.pack(pcall(Paper.Network.InvokeServer, command, ...))
    state.pending = nil
    if not packed[1] then
        state.lastError = action .. " failed: " .. tostring(packed[2])
        return false, state.lastError
    end
    if packed[2] then
        state.succeeded[action] = (state.succeeded[action] or 0) + 1
        return true, packed[3]
    end
    return false, packed[3] or "server declined"
end

local function collectEggs()
    local eggs = workspace:FindFirstChild("Eggs")
    if not eggs then
        return 0
    end
    local collected = 0
    local timestamp = now()
    for _, egg in ipairs(eggs:GetChildren()) do
        if collected >= 10 then
            break
        end
        local previousAttempt = state.recentlyCollected[egg.Name] or -math.huge
        if timestamp - previousAttempt >= 2 then
            state.recentlyCollected[egg.Name] = timestamp
            local ok, errorMessage = pcall(Paper.Network.FireServer, "Collect Egg", egg.Name)
            if ok then
                collected = collected + 1
                state.attempted.collect = state.attempted.collect + 1
            else
                state.lastError = "collect failed: " .. tostring(errorMessage)
            end
        end
    end
    for eggId, attemptedAt in pairs(state.recentlyCollected) do
        if timestamp - attemptedAt > 10 then
            state.recentlyCollected[eggId] = nil
        end
    end
    return collected
end

local function tick()
    if not state.enabled or state.pending then
        return
    end
    if state.autoCollectEggs and ready("collect", 0.25) then
        local count = collectEggs()
        if count > 0 then
            state.status = "Collecting " .. count .. " egg(s)"
        end
        mark("collect")
    end

    local eggs = tonumber(getStat("Eggs", 0)) or 0
    if state.autoDepositEggs and eggs >= state.depositThreshold and ready("deposit", 1.5) then
        local ok, message = invoke("deposit", "Deposit Eggs")
        state.status = ok and "Depositing eggs" or "Waiting to deposit: " .. tostring(message)
        mark("deposit")
        return
    end

    local cashReady = tonumber(getStat("CashCollect", 0)) or 0
    if state.autoClaimCash and cashReady > 0 and ready("cash", 1.5) then
        local ok, message = invoke("cash", "Collect Cash")
        state.status = ok and "Collecting cash" or "Waiting to collect cash: " .. tostring(message)
        mark("cash")
        return
    end

    if state.autoBuyFive and ready("buyFive", 0.45) then
        local ok, message = invoke("buyFive", "Buy Chickens", 5)
        state.status = ok and "Bought five chickens" or "Saving for Buy 5: " .. tostring(message)
        mark("buyFive")
        return
    end

    if state.autoMerge and ready("merge", 1) then
        local ok, message = invoke("merge", "Merge Chickens")
        state.status = ok and "Merged chickens" or "Merge unavailable: " .. tostring(message)
        mark("merge")
        return
    end

    if state.autoUpgradeProcess and ready("process", 1.2) then
        local ok, message = invoke("process", "Upgrade Process Level")
        state.status = ok and "Upgraded processing" or "Saving for processing: " .. tostring(message)
        mark("process")
        return
    end

    if state.autoUpgradeTier and ready("tier", 1.2) then
        local ok, message = invoke("tier", "Upgrade Buy Tier Level")
        state.status = ok and "Upgraded buy tier" or "Saving for buy tier: " .. tostring(message)
        mark("tier")
    end
end

local function telemetry()
    return string.format(
        "Status: %s\nEggs: %s | Cash: %s | Ready cash: %s\nChickens: %s | Buy tier: %s | Process: %s\nCollected: %d | Buy 5: %d | Deposits: %d | Claims: %d\nLast error: %s",
        state.status,
        tostring(getStat("Eggs", 0)),
        tostring(getStat("Cash", 0)),
        tostring(getStat("CashCollect", 0)),
        tostring(getStat("TotalChickens", 0)),
        tostring(getStat("BuyTierLevel", 0)),
        tostring(getStat("ProcessingLevel", 0)),
        state.attempted.collect,
        state.succeeded.buyFive,
        state.succeeded.deposit,
        state.succeeded.cash,
        state.lastError or "none"
    )
end

local function loadRayfield()
    assert(type(loadstring) == "function", "Rayfield requires loadstring support")
    -- Use the published source file directly. The short-link loader currently
    -- selects a Plugin-capability path in some executors, while this standard
    -- Rayfield source remains compatible with ordinary client execution.
    local source = game:HttpGet(RAYFIELD_URL)
    assert(type(source) == "string" and #source > 0, "Rayfield download returned no source")
    local loader, compileError = loadstring(source)
    assert(loader, compileError)
    return loader()
end

local function createUi()
    local Rayfield = loadRayfield()
    local window = Rayfield:CreateWindow({
        Name = "Chicken Farm Developer Controller",
        Icon = "egg",
        LoadingTitle = "Chicken Farm",
        LoadingSubtitle = "Development automation",
        ShowText = "Chicken Farm",
        Theme = "Default",
        ToggleUIKeybind = "K",
        DisableRayfieldPrompts = true,
        DisableBuildWarnings = true,
        -- This executor cannot safely restore Rayfield element state; use the
        -- controller config table above for deliberate persisted defaults.
        ConfigurationSaving = { Enabled = false },
        Discord = { Enabled = false },
        KeySystem = false
    })

    local farmTab = window:CreateTab("Farm", "egg")
    farmTab:CreateSection("Main loop")
    farmTab:CreateToggle({
        Name = "Controller active",
        CurrentValue = state.enabled,
        Flag = "chicken_farm_enabled",
        Callback = function(value)
            state.enabled = value
            state.status = value and "Controller active" or "Paused"
        end
    })
    farmTab:CreateToggle({
        Name = "Collect eggs",
        CurrentValue = state.autoCollectEggs,
        Flag = "chicken_farm_collect",
        Callback = function(value) state.autoCollectEggs = value end
    })
    farmTab:CreateToggle({
        Name = "Deposit eggs",
        CurrentValue = state.autoDepositEggs,
        Flag = "chicken_farm_deposit",
        Callback = function(value) state.autoDepositEggs = value end
    })
    farmTab:CreateToggle({
        Name = "Claim processed cash",
        CurrentValue = state.autoClaimCash,
        Flag = "chicken_farm_claim_cash",
        Callback = function(value) state.autoClaimCash = value end
    })
    farmTab:CreateToggle({
        Name = "Buy 5 chickens",
        CurrentValue = state.autoBuyFive,
        Flag = "chicken_farm_buy_five",
        Callback = function(value) state.autoBuyFive = value end
    })
    farmTab:CreateSlider({
        Name = "Deposit at",
        Range = { 1, 500 },
        Increment = 1,
        Suffix = " eggs",
        CurrentValue = state.depositThreshold,
        Flag = "chicken_farm_deposit_threshold",
        Callback = function(value) state.depositThreshold = value end
    })

    local growthTab = window:CreateTab("Growth", "trending-up")
    growthTab:CreateSection("Opt-in upgrades")
    growthTab:CreateToggle({
        Name = "Merge chickens",
        CurrentValue = state.autoMerge,
        Flag = "chicken_farm_merge",
        Callback = function(value) state.autoMerge = value end
    })
    growthTab:CreateToggle({
        Name = "Upgrade processing",
        CurrentValue = state.autoUpgradeProcess,
        Flag = "chicken_farm_process",
        Callback = function(value) state.autoUpgradeProcess = value end
    })
    growthTab:CreateToggle({
        Name = "Upgrade buy tier",
        CurrentValue = state.autoUpgradeTier,
        Flag = "chicken_farm_tier",
        Callback = function(value) state.autoUpgradeTier = value end
    })

    local diagnosticsTab = window:CreateTab("Diagnostics", "activity")
    diagnosticsTab:CreateLabel("Live telemetry is available through __RBA_CHICKEN_FARM:health()", "activity")
    state.ui = { rayfield = Rayfield }
end

function state.health()
    return {
        version = state.version,
        running = state.running,
        enabled = state.enabled,
        autoCollectEggs = state.autoCollectEggs,
        autoDepositEggs = state.autoDepositEggs,
        autoClaimCash = state.autoClaimCash,
        autoBuyFive = state.autoBuyFive,
        autoMerge = state.autoMerge,
        autoUpgradeProcess = state.autoUpgradeProcess,
        autoUpgradeTier = state.autoUpgradeTier,
        status = state.status,
        pending = state.pending,
        attempted = state.attempted,
        succeeded = state.succeeded,
        lastError = state.lastError,
        eggs = getStat("Eggs", 0),
        cash = getStat("Cash", 0),
        cashCollect = getStat("CashCollect", 0),
        chickens = getStat("TotalChickens", 0)
    }
end

local uiOk, uiError = xpcall(createUi, function(errorMessage)
    return tostring(errorMessage) .. "\n" .. debug.traceback()
end)
if not uiOk then
    state.lastError = "Rayfield UI failed: " .. tostring(uiError)
    state.status = "UI ERROR - controller still running"
end

state.connection = RunService.Heartbeat:Connect(function()
    if not state.running or RuntimeEnv.__RBA_CHICKEN_FARM ~= state then
        if RuntimeEnv.__RBA_CHICKEN_FARM ~= state then
            state.stop("superseded")
        end
        return
    end
    tick()
end)

state.status = uiOk and "Ready" or state.status
return state
