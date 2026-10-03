-- =========================================================
-- SERVICE
-- =========================================================
local Players = game:GetService("Players")
local VirtualInputManager = game:GetService("VirtualInputManager")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local RbxAnalyticsService = game:GetService("RbxAnalyticsService")
local VirtualUser = game:GetService("VirtualUser")
local SoundService = game:GetService("SoundService")
local LocalPlayer = Players.LocalPlayer
local playerGui = LocalPlayer:FindFirstChild("PlayerGui")

local Connections = {}
local CleanupObjects = {}

local originalMaterials = {}
local originalShadows = {}
local originalQualityLevel = settings().Rendering.QualityLevel

-- =========================================================--
-- ASSETS
-- =========================================================--
local Assets = {
    LOGO_FULL          = "rbxthumb://type=Asset&id=86703178512316&w=150&h=150",
    LOGO_TEXT          = "rbxthumb://type=Asset&id=136303933903606&w=150&h=150",
    LOGO_WITHOUT_TEXT  = "rbxthumb://type=Asset&id=133854239689854&w=150&h=150",
}

-- =========================================================
-- CONFIG
-- =========================================================
local Config = {
    API_URL = "",
    API_KEY = "",
    GAME_NAME = "Car Driving Indonesia",
    PRODUCT_CODE = "NEX-CDID-BARISTA",
    LICENSE_KEY = (getgenv and getgenv().Nexova_key) or Nexova_key or "",
    REQUEST_FUNC = request or http_request or (syn and syn.request) or (fluxus and fluxus.request),
    HEADERS = {
        ["Content-Type"] = "application/json",
        ["X-API-Key"] = ""
    },
    PUBLISH_MODE = true,
    DEBUG_MODE = false,
    SESSION_TOKEN = nil,
    HEARTBEAT_INTERVAL = 60,
    IS_RUNNING = false,
}

local AuthState = {
    status_license = "unknown",
    key = "",
    plan_license = "N/A",
    max_devices = 1,
    expired_at = "N/A"
}

-- =========================================================
-- PLAN TIER & FEATURE GATE SYSTEM
-- =========================================================
local PlanSystem = {

    TIERS = {
        ["NEX-FREE"]    = 1,
        ["NEX-SPARK"]   = 2,
        ["NEX-PULSE"]   = 3,
        ["NEX-VORTEX"]  = 4,
        ["NEX-APEX"]    = 5,
        ["NEX-ETERNAL"] = 6
    },

    REQUIREMENTS = {
        ["ALLOW_PLAN"] = "NEX-PULSE",
    }

}

function PlanSystem.HasAccess(featureName)
    local reqData = PlanSystem.REQUIREMENTS[featureName]
    if not reqData then return false end

    local currentPlan = AuthState.plan_license or "NEX-FREE"
    local currentTier = PlanSystem.TIERS[currentPlan] or 1

    if type(reqData) == "table" then
        for _, planCode in ipairs(reqData) do
            local targetTier = PlanSystem.TIERS[planCode] or 1
            if currentPlan == planCode or currentTier >= targetTier then
                return true
            end
        end
        return false
    else
        local requiredTier = PlanSystem.TIERS[reqData] or 1
        return currentTier >= requiredTier
    end
end

-- =========================================================
-- SYSTEM EFEK AUDIO (NAMA KUSTOM)
-- =========================================================
local AudioRegistry = {
    WelcomeHub      = "rbxassetid://6112625298",
    MinimizeHub     = "rbxassetid://74947743572579",
    AutoFarmBGM     = "rbxassetid://86316862829978",
    ToastSFX        = "rbxassetid://129485210015224"
}

local currentBGMTrack = nil

local function playEffect(actionType, isLooping)
    -- Jika yang dipanggil adalah musik BGM dan sedang berjalan, stop yang lama dulu
    if isLooping and currentBGMTrack then
        pcall(function() currentBGMTrack:Destroy() end)
        currentBGMTrack = nil
    end

    local createdTrack = nil

    task.spawn(function()
        pcall(function()
            local audioTrack = Instance.new("Sound")
            audioTrack.SoundId = AudioRegistry[actionType] or AudioRegistry.Tap
            audioTrack.Volume = (actionType == "AutoFarmBGM") and 0.8 or 0.8
            audioTrack.Looped = isLooping or false
            
            -- Penentuan lokasi parent
            local targetHolder = nil
            pcall(function() targetHolder = gethui() end)
            if not targetHolder then pcall(function() targetHolder = game:GetService("CoreGui") end) end
            if not targetHolder then targetHolder = SoundService end
            
            audioTrack.Parent = targetHolder
            
            if not audioTrack.IsLoaded then
                audioTrack.Loaded:Wait()
            end
            
            audioTrack:Play()
            createdTrack = audioTrack

            -- Jika ini BGM Looped, simpan ke variable glo
