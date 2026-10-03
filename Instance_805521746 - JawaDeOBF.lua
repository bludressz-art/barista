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

            -- Jika ini BGM Looped, simpan ke variable global agar bisa di-stop nanti
            if isLooping then
                currentBGMTrack = audioTrack
            else
                -- Pembersihan otomatis HANYA untuk SFX pendek
                task.delay(audioTrack.TimeLength + 0.8, function()
                    pcall(function() audioTrack:Destroy() end)
                end)
            end
        end)
    end)

    return createdTrack
end

-- ==========================================
--  ANTI-DUMP/ANTI-SPY
-- ==========================================

-- =========================================================
-- HELPER FUNCTIONS
-- =========================================================
local function debugPrint(msg)
    if Config.DEBUG_MODE then print("[NEX-PRINT] " .. tostring(msg)) end
end

local function debugWarn(msg)
    if Config.DEBUG_MODE then warn("[NEX-WARN] " .. tostring(msg)) end
end

local function getHWID()
    local hwid = nil

    pcall(function()
        if gethwid then
            local res = gethwid()
            if res and res ~= "" then hwid = res end
        end
    end)

    if not hwid then
        pcall(function()
            local clientId = RbxAnalyticsService:GetClientId()
            if clientId and clientId ~= "" then
                hwid = clientId
            end
        end)
    end

    return hwid and tostring(hwid) or nil
end

local function sendApiRequest(action, payload)
    local reqSuccess, response = pcall(function()
        return Config.REQUEST_FUNC({
            Url = Config.API_URL .. "/API/route_license.php?act=" .. tostring(action),
            Method = "POST",
            Headers = Config.HEADERS,
            Body = HttpService:JSONEncode(payload)
        })
    end)

    if not reqSuccess or not response or not response.Body then
        return false, {message = "Connection error / No response from server."}
    end

    local parseSuccess, parsed = pcall(function()
        return HttpService:JSONDecode(response.Body)
    end)

    if parseSuccess and parsed then
        return parsed.success, parsed
    else
        return false, {message = "Invalid JSON response from server."}
    end
end

-- =========================================================
-- CORE LIFECYCLE (SESSION & CLEANUP)
-- =========================================================
local function endSession()
    if not Config.SESSION_TOKEN then return end

    local hwid = getHWID()
    if not hwid then return end

    local success, response = sendApiRequest("session_end", {
        session_token = Config.SESSION_TOKEN,
        hwid_hash     = hwid
    })

    if success then
        debugPrint("The session was successfully and cleanly terminated on the server.")
    else
        debugWarn("Failed to end the session: " .. tostring(response.message))
    end

    Config.SESSION_TOKEN = nil
end

local function destroyHub(reason)
    if not Config.IS_RUNNING and #Connections == 0 and #CleanupObjects == 0 then return end
    
    debugPrint("Cleaning up script resources... Reason: " .. tostring(reason or "Manual"))
    Config.IS_RUNNING = false

    endSession()

    for name, conn in pairs(Connections) do
        if conn then
            pcall(function() conn:Disconnect() end)
            debugPrint("Disconnected: " .. name)
        end
    end
    table.clear(Connections)

    for name, obj in pairs(CleanupObjects) do
        if obj and obj.Parent then
            pcall(function() obj:Destroy() end)
            debugPrint("Destroyed object: " .. name)
        end
    end
    table.clear(CleanupObjects)
end

local function startHeartbeatLoop()
    task.spawn(function()
        while Config.IS_RUNNING and Config.SESSION_TOKEN do
            task.wait(Config.HEARTBEAT_INTERVAL)
            if not Config.IS_RUNNING then break end

            local hbSuccess, hbData = sendApiRequest("heartbeat", {
                session_token = Config.SESSION_TOKEN,
                hwid_hash     = getHWID()
            })

            if not hbSuccess then
                -- Safely extract error message
                local rawMessage = (type(hbData) == "table" and hbData.message) or "Session expired."
                
                debugWarn("Heartbeat Failed: " .. tostring(rawMessage))
                destroyHub("Heartbeat Failed: " .. tostring(rawMessage))
                
                -- Ringkas string Kick khusus layar HP
                LocalPlayer:Kick("[NEX-KICK] Session Ended: " .. tostring(rawMessage))
                break
            else
                local okMessage = (type(hbData) == "table" and hbData.message) or "OK"
                debugPrint("Heartbeat OK: " .. tostring(okMessage))
            end
        end
    end)
end

-- =========================================================
-- MULTI-PURPOSE NOTIFICATION TOAST SYSTEM
-- =========================================================
local ToastSystem = {
    ActiveToast = nil,
    
    -- Konfigurasi Preset Warna & Icon untuk setiap Tipe Notifikasi
    PRESETS = {
        ["info"] = {
            Icon = "ℹ️",
            Color = Color3.fromRGB(0, 180, 255),    -- Cyan/Blue
            Title = "INFORMATION"
        },
        ["success"] = {
            Icon = "✅",
            Color = Color3.fromRGB(0, 235, 145),    -- Green
            Title = "SUCCESS"
        },
        ["warning"] = {
            Icon = "⚠️",
            Color = Color3.fromRGB(255, 180, 0),    -- Gold/Yellow
            Title = "WARNING"
        },
        ["error"] = {
            Icon = "🔒",
            Color = Color3.fromRGB(255, 60, 80),    -- Red
            Title = "ACCESS DENIED"
        }
    }
}

function ToastSystem.Show(toastType, message, customTitle, displayDuration)
    -- Jika parameter displayDuration tergeser atau bernilai number di argumen ke-3/4
    if type(customTitle) == "number" then
        displayDuration = customTitle
        customTitle = nil
    end
    
    displayDuration = type(displayDuration) == "number" and displayDuration or 2.5

    -- Ambil preset berdasarkan tipe
    local preset = ToastSystem.PRESETS[string.lower(tostring(toastType))] or ToastSystem.PRESETS["info"]
    
    -- Pastikan titleText berjenis string (Aman jika dikirim boolean/nil)
    local titleText = preset.Title
    if customTitle and type(customTitle) == "string" and customTitle ~= "" then
        titleText = customTitle
    end
    
    local mainColor = preset.Color
    local iconText  = preset.Icon

    -- Jika ada toast aktif, bersihkan terlebih dahulu
    if ToastSystem.ActiveToast then
        pcall(function() ToastSystem.ActiveToast:Destroy() end)
        ToastSystem.ActiveToast = nil
    end

    local mainHub = CoreGui:FindFirstChild("NexovaHub") or playerGui:FindFirstChild("NexovaHub")
    if not mainHub then return end

    -- Container Frame Toast
    local ToastFrame = Instance.new("Frame")
    ToastFrame.Name = "NexovaToast"
    ToastFrame.AnchorPoint = Vector2.new(0.5, 0)
    ToastFrame.Position = UDim2.new(0.5, 0, 0, -65)
    ToastFrame.Size = UDim2.fromOffset(320, 52)
    ToastFrame.BackgroundColor3 = Color3.fromRGB(8, 15, 30)
    ToastFrame.BorderSizePixel = 0
    ToastFrame.ClipsDescendants = true
    ToastFrame.ZIndex = 999
    ToastFrame.Parent = mainHub

    ToastSystem.ActiveToast = ToastFrame

    local ToastCorner = Instance.new("UICorner", ToastFrame)
    ToastCorner.CornerRadius = UDim.new(0, 8)

    local ToastStroke = Instance.new("UIStroke", ToastFrame)
    ToastStroke.Thickness = 1.5
    ToastStroke.Color = mainColor

    -- Icon Indikator
    local IconLabel = Instance.new("TextLabel", ToastFrame)
    IconLabel.Position = UDim2.new(0, 12, 0.5, -13)
    IconLabel.Size = UDim2.fromOffset(24, 24)
    IconLabel.BackgroundTransparency = 1
    IconLabel.Text = iconText
    IconLabel.TextSize = 16
    IconLabel.Font = Enum.Font.GothamBold

    -- Judul Toast (Diubah ke tostring agar 100% aman dari error)
    local TitleLabel = Instance.new("TextLabel", ToastFrame)
    TitleLabel.Position = UDim2.new(0, 42, 0, 8)
    TitleLabel.Size = UDim2.new(1, -50, 0, 16)
    TitleLabel.BackgroundTransparency = 1
    TitleLabel.Text = string.upper(tostring(titleText))
    TitleLabel.TextColor3 = mainColor
    TitleLabel.TextSize = 11
    TitleLabel.Font = Enum.Font.GothamBold
    TitleLabel.TextXAlignment = Enum.TextXAlignment.Left

    -- Pesan / Deskripsi
    local MsgLabel = Instance.new("TextLabel", ToastFrame)
    MsgLabel.Position = UDim2.new(0, 42, 0, 24)
    MsgLabel.Size = UDim2.new(1, -50, 0, 18)
    MsgLabel.BackgroundTransparency = 1
    MsgLabel.Text = tostring(message or "")
    MsgLabel.TextColor3 = Color3.fromRGB(210, 215, 230)
    MsgLabel.TextSize = 10
    MsgLabel.Font = Enum.Font.GothamMedium
    MsgLabel.TextXAlignment = Enum.TextXAlignment.Left
    MsgLabel.TextTruncate = Enum.TextTruncate.AtEnd

    -- Progress Track & Bar (Inset 8px dari samping & 6px dari bawah)
    local ProgressTrack = Instance.new("Frame", ToastFrame)
    ProgressTrack.Name = "ProgressTrack"
    ProgressTrack.Position = UDim2.new(0, 8, 1, -6)
    ProgressTrack.Size = UDim2.new(1, -16, 0, 3)
    ProgressTrack.BackgroundColor3 = Color3.fromRGB(20, 30, 50)
    ProgressTrack.BorderSizePixel = 0
    ProgressTrack.ClipsDescendants = true

    local TrackCorner = Instance.new("UICorner", ProgressTrack)
    TrackCorner.CornerRadius = UDim.new(1, 0)

    local ProgressBar = Instance.new("Frame", ProgressTrack)
    ProgressBar.Name = "ProgressBar"
    ProgressBar.Position = UDim2.new(0, 0, 0, 0)
    ProgressBar.Size = UDim2.new(0, 0, 1, 0)
    ProgressBar.BackgroundColor3 = mainColor
    ProgressBar.BorderSizePixel = 0

    local BarCorner = Instance.new("UICorner", ProgressBar)
    BarCorner.CornerRadius = UDim.new(1, 0)

    playEffect("ToastSFX")

    -- Animasi Masuk
    local tweenIn = TweenService:Create(
        ToastFrame,
        TweenInfo.new(0.35, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
        { Position = UDim2.new(0.5, 0, 0, 20) }
    )
    tweenIn:Play()

    -- Animasi Garis Progress
    local tweenProgress = TweenService:Create(
        ProgressBar,
        TweenInfo.new(displayDuration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
        { Size = UDim2.new(1, 0, 1, 0) }
    )
    
    tweenIn.Completed:Connect(function()
        tweenProgress:Play()
    end)

    -- Animasi Keluar
    tweenProgress.Completed:Connect(function()
        if ToastSystem.ActiveToast == ToastFrame then
            local tweenOut = TweenService:Create(
                ToastFrame,
                TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
                { Position = UDim2.new(0.5, 0, 0, -65) }
            )
            tweenOut:Play()
            tweenOut.Completed:Connect(function()
                if ToastFrame and ToastFrame.Parent then
                    ToastFrame:Destroy()
                end
                if ToastSystem.ActiveToast == ToastFrame then
                    ToastSystem.ActiveToast = nil
                end
            end)
        end
    end)
end

-- =========================================================
-- UI & AUTHENTICATION
-- =========================================================
local function loadingScreen()

    local UILoading = {}

    UILoading.Screen = Instance.new("ScreenGui")
    UILoading.Screen.Name = "NexovaLoadingScreen"
    UILoading.Screen.IgnoreGuiInset = true
    UILoading.Screen.ResetOnSpawn = false
    UILoading.Screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    pcall(function() UILoading.Screen.Parent = CoreGui end)
    if not UILoading.Screen.Parent then
        UILoading.Screen.Parent = LocalPlayer:WaitForChild("PlayerGui")
    end

    CleanupObjects["LoadingScreen"] = UILoading.Screen

    UILoading.Overlay = Instance.new("Frame", UILoading.Screen)
    UILoading.Overlay.Name = "Overlay"
    UILoading.Overlay.Size = UDim2.fromScale(1, 1)
    UILoading.Overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    UILoading.Overlay.BackgroundTransparency = 0.05
    UILoading.Overlay.BorderSizePixel = 0

    -- =====================================================
    -- CONTAINER UTAMA (Pusat Layar di HP & PC)
    -- =====================================================
    UILoading.Container = Instance.new("Frame", UILoading.Overlay)
    UILoading.Container.Name = "MainContainer"
    UILoading.Container.AnchorPoint = Vector2.new(0.5, 0.5)
    UILoading.Container.Position = UDim2.fromScale(0.5, 0.5)
    UILoading.Container.Size = UDim2.fromOffset(500, 200) -- Ukuran area kotak loading
    UILoading.Container.BackgroundTransparency = 1

    -- =====================================================
    -- ADAPTIVE UISCALE
    -- =====================================================
    UILoading.Scale = Instance.new("UIScale", UILoading.Container)
    UILoading.Scale.Name = "UILoadingScale"

    local function updateScale()
        local cam = workspace.CurrentCamera or workspace:FindFirstChildOfClass("Camera")
        if not cam then return end
        
        local screenSize = cam.ViewportSize
        if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
            local minDimension = math.min(screenSize.X, screenSize.Y)
            local targetScale = (minDimension * 0.85) / 500
            UILoading.Scale.Scale = math.clamp(targetScale, 0.60, 0.90)
        else
            UILoading.Scale.Scale = 1.0
        end
    end

    pcall(function()
        updateScale()
        workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
            local cam = workspace.CurrentCamera
            if cam then
                cam:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
            end
        end)
        if workspace.CurrentCamera then
            workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
        end
    end)

    -- SEMUA ELEMEN SEKARANG MASUK KE DALAM CONTAINER (Posisi diatur relatif terhadap Container)

    UILoading.Logo = Instance.new("ImageLabel", UILoading.Container)
    UILoading.Logo.Name = "LogoLoading"
    UILoading.Logo.AnchorPoint = Vector2.new(0.5, 0.5)
    UILoading.Logo.Position = UDim2.new(0, 100, 0, 100) -- Posisi awal di tengah kontainer
    UILoading.Logo.Size = UDim2.fromOffset(140, 140)
    UILoading.Logo.BackgroundTransparency = 1
    UILoading.Logo.Image = Assets.LOGO_WITHOUT_TEXT
    UILoading.Logo.ImageTransparency = 1
    UILoading.Logo.ScaleType = Enum.ScaleType.Fit

    UILoading.Divider = Instance.new("Frame", UILoading.Container)
    UILoading.Divider.Name = "Divider"
    UILoading.Divider.AnchorPoint = Vector2.new(0.5, 0.5)
    UILoading.Divider.Position = UDim2.new(0, 185, 0, 100)
    UILoading.Divider.Size = UDim2.fromOffset(2, 150)
    UILoading.Divider.BackgroundColor3 = Color3.fromRGB(65, 65, 72)
    UILoading.Divider.BackgroundTransparency = 1
    UILoading.Divider.BorderSizePixel = 0

    UILoading.Title = Instance.new("ImageLabel", UILoading.Container)
    UILoading.Title.Name = "Title"
    UILoading.Title.AnchorPoint = Vector2.new(0, 0.5)
    UILoading.Title.Position = UDim2.new(0, 205, 0, 45)
    UILoading.Title.Size = UDim2.fromOffset(220, 55)
    UILoading.Title.BackgroundTransparency = 1
    UILoading.Title.Image = Assets.LOGO_TEXT
    UILoading.Title.ImageTransparency = 1
    UILoading.Title.ScaleType = Enum.ScaleType.Fit

    UILoading.TitleScale = Instance.new("UIScale", UILoading.Title)
    UILoading.TitleScale.Scale = 0.80

    UILoading.Status = Instance.new("TextLabel", UILoading.Container)
    UILoading.Status.Name = "StatusText"
    UILoading.Status.AnchorPoint = Vector2.new(0, 0.5)
    UILoading.Status.Position = UDim2.new(0, 205, 0, 85)
    UILoading.Status.Size = UDim2.fromOffset(280, 25)
    UILoading.Status.BackgroundTransparency = 1
    UILoading.Status.Text = "Initializing..."
    UILoading.Status.TextColor3 = Color3.fromRGB(190, 190, 196)
    UILoading.Status.TextTransparency = 1
    UILoading.Status.Font = Enum.Font.Gotham
    UILoading.Status.TextSize = 13
    UILoading.Status.TextXAlignment = Enum.TextXAlignment.Left

    UILoading.StatusScale = Instance.new("UIScale", UILoading.Status)
    UILoading.StatusScale.Scale = 0.80

    UILoading.ProgressBackground = Instance.new("Frame", UILoading.Container)
    UILoading.ProgressBackground.Name = "ProgressBackground"
    UILoading.ProgressBackground.AnchorPoint = Vector2.new(0, 0.5)
    UILoading.ProgressBackground.Position = UDim2.new(0, 205, 0, 115)
    UILoading.ProgressBackground.Size = UDim2.fromOffset(260, 5)
    UILoading.ProgressBackground.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
    UILoading.ProgressBackground.BackgroundTransparency = 1
    UILoading.ProgressBackground.BorderSizePixel = 0

    UILoading.ProgressScale = Instance.new("UIScale", UILoading.ProgressBackground)
    UILoading.ProgressScale.Scale = 0.80

    Instance.new("UICorner", UILoading.ProgressBackground).CornerRadius = UDim.new(1, 0)

    UILoading.ProgressBar = Instance.new("Frame", UILoading.ProgressBackground)
    UILoading.ProgressBar.Name = "ProgressBar"
    UILoading.ProgressBar.Size = UDim2.fromScale(0, 1)
    UILoading.ProgressBar.BackgroundColor3 = Color3.fromRGB(0, 120, 220)
    UILoading.ProgressBar.BorderSizePixel = 0

    Instance.new("UICorner", UILoading.ProgressBar).CornerRadius = UDim.new(1, 0)

    UILoading.ProgressGradient = Instance.new("UIGradient", UILoading.ProgressBar)
    UILoading.ProgressGradient.Color = ColorSequence.new({ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 200, 255)), ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 120, 255)), ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 60, 180))})

    UILoading.Percentage = Instance.new("TextLabel", UILoading.Container)
    UILoading.Percentage.Name = "PercentageText"
    UILoading.Percentage.AnchorPoint = Vector2.new(0, 0.5)
    UILoading.Percentage.Position = UDim2.new(0, 205, 0, 140)
    UILoading.Percentage.Size = UDim2.fromOffset(260, 20)
    UILoading.Percentage.BackgroundTransparency = 1
    UILoading.Percentage.Text = "0%"
    UILoading.Percentage.TextColor3 = Color3.fromRGB(120, 120, 125)
    UILoading.Percentage.TextTransparency = 1
    UILoading.Percentage.Font = Enum.Font.Gotham
    UILoading.Percentage.TextSize = 11
    UILoading.Percentage.TextXAlignment = Enum.TextXAlignment.Left

    UILoading.PercentageScale = Instance.new("UIScale", UILoading.Percentage)
    UILoading.PercentageScale.Scale = 0.80

    local function tween(instance, duration, properties)
        local animation = TweenService:Create(instance, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), properties)
        animation:Play()
        return animation
    end

    -- First Animation UI (Digeser relatif ke kontainer)
    tween(UILoading.Logo, 0.5, { ImageTransparency = 0 })
    task.wait(0.6)
    tween(UILoading.Logo, 0.6, { Position = UDim2.new(0, 65, 0, 100) }) -- Bergeser ke kiri sedikit di dalam kontainer
    task.wait(0.15)
    tween(UILoading.Divider, 0.25, { BackgroundTransparency = 0 })
    task.wait(0.12)

    tween(UILoading.Title, 0.45, { ImageTransparency = 0 })
    tween(UILoading.TitleScale, 0.45, { Scale = 1 })
    tween(UILoading.Status, 0.45, { TextTransparency = 0 })
    tween(UILoading.StatusScale, 0.45, { Scale = 1 })
    tween(UILoading.ProgressBackground, 0.45, { BackgroundTransparency = 0 })
    tween(UILoading.ProgressScale, 0.45, { Scale = 1 })
    tween(UILoading.Percentage, 0.45, { TextTransparency = 0 })
    tween(UILoading.PercentageScale, 0.45, { Scale = 1 })
    task.wait(0.45)

    return {
        update = function(percent, text)
            UILoading.Status.Text = text
            UILoading.Percentage.Text = tostring(percent) .. "%"
            tween(UILoading.ProgressBar, 0.4, { Size = UDim2.fromScale(percent / 100, 1) })
        end,
        fail = function(message)
            UILoading.Status.Text = message
            UILoading.Percentage.Text = "FAILED"
            UILoading.ProgressBar.BackgroundColor3 = Color3.fromRGB(210, 45, 55)
            UILoading.ProgressGradient.Color = ColorSequence.new({ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 90, 90)), ColorSequenceKeypoint.new(0.5, Color3.fromRGB(220, 45, 55)), ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 20, 30))})
        end,
        close = function()
            tween(UILoading.Logo, 0.4, { ImageTransparency = 1 })
            tween(UILoading.Divider, 0.2, { BackgroundTransparency = 1 })
            tween(UILoading.Title, 0.4, { ImageTransparency = 1 })
            tween(UILoading.Status, 0.2, { TextTransparency = 1 })
            tween(UILoading.ProgressBar, 0.1, { BackgroundTransparency = 1 })
            tween(UILoading.ProgressBackground, 0.1, { BackgroundTransparency = 1 })
            tween(UILoading.Percentage, 0.2, { TextTransparency = 1 })
            tween(UILoading.Overlay, 0.4, { BackgroundTransparency = 1 })
            task.wait(0.45)
            CleanupObjects["LoadingScreen"] = nil
            UILoading.Screen:Destroy()
        end
    }
end

local function authenticateUser()

    if not Config.REQUEST_FUNC then
        LocalPlayer:Kick("[NEX-KICK] Executor HTTP not supported!")
        return false
    end

    local loader = loadingScreen()
    loader.update(10, "Checking Device...")

    local hwid = getHWID()
    if not hwid then
        loader.fail("HWID Error")
        task.wait(1.5)
        LocalPlayer:Kick("[NEX-KICK] Failed to detect HWID.")
        return false
    end

    if Config.LICENSE_KEY == "" then
        loader.fail("No License")
        task.wait(1.5)
        LocalPlayer:Kick("[NEX-KICK] License key is empty!")
        return false
    end

    local authPayload = {
        license_key     = Config.LICENSE_KEY,
        product_code    = Config.PRODUCT_CODE,
        place_id        = game.PlaceId,
        roblox_id       = LocalPlayer.UserId,
        roblox_username = LocalPlayer.Name,
        hwid_hash       = hwid
    }

    -- Verify Lisensi
    loader.update(40, "Verifying License...")
    local vSuccess, vData = sendApiRequest("verify", authPayload)
    if not vSuccess then
        loader.fail("Invalid License")
        task.wait(1.5)
        if type(vData) == "table" and vData.code == "max_devices_reached" then
            -- Teks singkat khusus HP (Tanpa spasi berlebih/enter panjang)
            LocalPlayer:Kick("[NEX-KICK] Device Limit! Reset HWID via Discord Bot.")
        else
            local errMessage = (type(vData) == "table" and vData.message) or "Invalid/expired key."
            LocalPlayer:Kick("[NEX-KICK] Verify Failed: " .. tostring(errMessage))
        end
        return false
    end

    -- Save AuthState from verify/license
    pcall(function()
        local licInfo = type(vData) == "table" and vData.data and (vData.data.license or vData.data)
        if licInfo then
            AuthState.status_license = tostring(licInfo.status or licInfo.status_license or "active")
            AuthState.key            = tostring(licInfo.license_key or Config.LICENSE_KEY)
            AuthState.plan_license   = tostring(licInfo.plan_code or licInfo.plan or "NEX-FREE")
            AuthState.max_devices    = licInfo.max_devices or 1
            
            local exp = licInfo.expired_at or licInfo.expires
            if not exp or exp == "" or tostring(exp) == "nil" or tostring(exp) == "userdata: 0x00000000" then
                AuthState.expired_at = "Lifetime"
            else
                AuthState.expired_at = tostring(exp)
            end
        end
    end)

    -- Allowed Plan Check
    loader.update(60, "Checking Plan Access...")
    if not PlanSystem.HasAccess("ALLOW_PLAN") then
        loader.fail("Plan Access Denied")
        task.wait(1.5)
        local reqPlan = PlanSystem.REQUIREMENTS["ALLOW_PLAN"]
        local reqText = (type(reqPlan) == "table") and table.concat(reqPlan, "/") or tostring(reqPlan)
        
        -- Ringkas teks plan agar muat di HP
        LocalPlayer:Kick("[NEX-KICK] Requires " .. reqText .. " Plan or higher!")
        return false
    end

    -- Open / Create Session
    loader.update(80, "Creating Session...")
    local sessSuccess, sessData = sendApiRequest("session_start", authPayload)
    if not sessSuccess or type(sessData) ~= "table" or not sessData.data or not sessData.data.session_token then
        loader.fail("Session Failed")
        task.wait(1.5)
        local errMessage = (type(sessData) == "table" and sessData.message) or "Active on another device."
        LocalPlayer:Kick("[NEX-KICK] Session Failed: " .. tostring(errMessage))
        return false
    end

    Config.SESSION_TOKEN = sessData.data.session_token
    Config.IS_RUNNING = true

    loader.update(100, "Authentication Successful!")
    task.wait(0.5)
    loader.close()

    startHeartbeatLoop()

    return true
end

-- =========================================================
-- AUTO END SESSION ON CLIENT LEAVE
-- =========================================================
Connections["PlayerLeave"] = LocalPlayer.AncestryChanged:Connect(function(_, parent)
    destroyHub("Player Close The Game")
end)

-- =========================================================
-- MAIN HUB
-- =========================================================
local function mainScreen()

    if CoreGui:FindFirstChild("NexovaHub") then CoreGui.NexovaHub:Destroy() end
    if playerGui and playerGui:FindFirstChild("NexovaHub") then playerGui.NexovaHub:Destroy() end

    local ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = "NexovaHub"
    ScreenGui.IgnoreGuiInset = true
    ScreenGui.ResetOnSpawn = false
    ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local success = pcall(function() ScreenGui.Parent = CoreGui end)
    if not success or not ScreenGui.Parent then ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

    CleanupObjects["MainHub"] = ScreenGui

    -- =====================================================
    -- BLACK SCREEN COVER (ANTI-RENDER OPTIMIZER)
    -- =====================================================
    local BlackFrame = Instance.new("Frame")
    BlackFrame.Name = "BlackFrame"
    BlackFrame.Size = UDim2.fromScale(1, 1)
    BlackFrame.Position = UDim2.fromScale(0, 0)
    BlackFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    BlackFrame.BorderSizePixel = 0
    BlackFrame.ZIndex = 1
    BlackFrame.Visible = false
    BlackFrame.Parent = ScreenGui

    local BlackText = Instance.new("TextLabel")
    BlackText.AnchorPoint = Vector2.new(0.5, 0.5)
    BlackText.Position = UDim2.fromScale(0.5, 0.15)
    BlackText.Size = UDim2.fromOffset(400, 30)
    BlackText.BackgroundTransparency = 1
    BlackText.Text = "NEXOVA HUB // ANTI-RENDER MODE ACTIVE"
    BlackText.TextColor3 = Color3.fromRGB(0, 180, 255)
    BlackText.TextSize = 12
    BlackText.Font = Enum.Font.GothamMedium
    BlackText.Parent = BlackFrame

    -- =====================================================
    -- MAIN FRAME
    -- =====================================================
    local MainFrame = Instance.new("Frame")
    MainFrame.Name = "MainFrame"
    MainFrame.AnchorPoint = Vector2.new(0.5, 0.5)
    MainFrame.Position = UDim2.fromScale(0.5, 0.5)
    MainFrame.Size = UDim2.fromOffset(700, 500)
    MainFrame.BackgroundColor3 = Color3.fromRGB(5, 9, 20)
    MainFrame.BorderSizePixel = 0
    MainFrame.Visible = false
    MainFrame.ZIndex = 10
    MainFrame.Parent = ScreenGui

    local MainFrameCorner = Instance.new("UICorner")
    MainFrameCorner.CornerRadius = UDim.new(0, 12)
    MainFrameCorner.Parent = MainFrame

    local MainFrameStroke = Instance.new("UIStroke")
    MainFrameStroke.Color = Color3.fromRGB(0, 180, 255)
    MainFrameStroke.Transparency = 0.25
    MainFrameStroke.Thickness = 1
    MainFrameStroke.Parent = MainFrame

    local MainFrameGradient = Instance.new("UIGradient")
    MainFrameGradient.Color = ColorSequence.new({ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 180, 255)), ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 110, 255)), ColorSequenceKeypoint.new(1, Color3.fromRGB(235, 40, 255))})
    MainFrameGradient.Rotation = 0
    MainFrameGradient.Parent = MainFrameStroke

    -- =====================================================
    -- ADAPTIVE UISCALE (FIX UKURAN DI HP & PC)
    -- =====================================================
    local MainFrameScale = Instance.new("UIScale")

    local function updateScale()
        local cam = workspace.CurrentCamera or workspace:FindFirstChildOfClass("Camera")
        if not cam then return end
        
        local screenSize = cam.ViewportSize
        if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
            local minDimension = math.min(screenSize.X, screenSize.Y)
            local targetScale = (minDimension * 0.85) / 700
            MainFrameScale.Scale = math.clamp(targetScale, 0.60, 0.80)
        else
            MainFrameScale.Scale = 1.0
        end
    end

    pcall(function()
        updateScale()
        workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
            local cam = workspace.CurrentCamera
            if cam then
                cam:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
            end
        end)
        if workspace.CurrentCamera then
            workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
        end
    end)

    MainFrameScale.Parent = MainFrame

    local Window = MainFrame
    local WindowScale = MainFrameScale

    -- =====================================================
    -- MINIMIZED ICON
    -- =====================================================
    local MinimizedIcon = Instance.new("ImageButton")
    MinimizedIcon.Name = "MinimizedIcon"
    MinimizedIcon.AnchorPoint = Vector2.new(0.5, 0.5)
    MinimizedIcon.Position = UDim2.new(0.5, 0, 0, 60)
    MinimizedIcon.Size = UDim2.fromOffset(50, 50)
    MinimizedIcon.BackgroundColor3 = Color3.fromRGB(8, 15, 30)
    MinimizedIcon.BorderSizePixel = 0
    MinimizedIcon.AutoButtonColor = false
    MinimizedIcon.Image = Assets.LOGO_WITHOUT_TEXT
    MinimizedIcon.ScaleType = Enum.ScaleType.Fit
    MinimizedIcon.Visible = false
    MinimizedIcon.Draggable = true
    MinimizedIcon.Parent = ScreenGui

    local MinimizedCorner = Instance.new("UICorner")
    MinimizedCorner.CornerRadius = UDim.new(0, 14)
    MinimizedCorner.Parent = MinimizedIcon

    local MinimizedStroke = Instance.new("UIStroke")
    MinimizedStroke.Color = Color3.fromRGB(0, 180, 255)
    MinimizedStroke.Transparency = 0.15
    MinimizedStroke.Thickness = 1
    MinimizedStroke.Parent = MinimizedIcon

    -- =====================================================
    -- SIDEBAR
    -- =====================================================
    local Sidebar = Instance.new("Frame")
    Sidebar.Name = "Sidebar"
    Sidebar.Size = UDim2.new(0, 190, 1, 0)
    Sidebar.BackgroundColor3 = Color3.fromRGB(7, 13, 27)
    Sidebar.BorderSizePixel = 0
    Sidebar.Parent = MainFrame

    local SidebarCorner = Instance.new("UICorner")
    SidebarCorner.CornerRadius = UDim.new(0, 12)
    SidebarCorner.Parent = Sidebar

    local SidebarCover = Instance.new("Frame")
    SidebarCover.Size = UDim2.new(0, 20, 1, 0)
    SidebarCover.Position = UDim2.new(1, -20, 0, 0)
    SidebarCover.BackgroundColor3 = Color3.fromRGB(7, 13, 27)
    SidebarCover.BorderSizePixel = 0
    SidebarCover.Parent = Sidebar

    local Logo = Instance.new("ImageLabel")
    Logo.Name = "Logo"
    Logo.AnchorPoint = Vector2.new(0.5, 0)
    Logo.Position = UDim2.new(0.5, 0, 0, 25)
    Logo.Size = UDim2.fromOffset(190, 85)
    Logo.BackgroundTransparency = 1
    Logo.Image = Assets.LOGO_FULL
    Logo.ScaleType = Enum.ScaleType.Fit
    Logo.Parent = Sidebar

    -- =====================================================
    -- NAVIGATION
    -- =====================================================
    local Navigation = Instance.new("Frame")
    Navigation.Name = "Navigation"
    Navigation.Position = UDim2.new(0, 18, 0, 125)
    Navigation.Size = UDim2.new(1, -36, 0, 320)
    Navigation.BackgroundTransparency = 1
    Navigation.Parent = Sidebar

    local NavigationLayout = Instance.new("UIListLayout")
    NavigationLayout.Padding = UDim.new(0, 5)
    NavigationLayout.SortOrder = Enum.SortOrder.LayoutOrder
    NavigationLayout.Parent = Navigation

    local navButtons = {}

    local function createNavButton(name, text, icon)
        local Button = Instance.new("TextButton")
        Button.Name = name
        Button.Size = UDim2.new(1, 0, 0, 35)
        Button.BackgroundColor3 = Color3.fromRGB(7, 13, 27)
        Button.BackgroundTransparency = 1
        Button.BorderSizePixel = 0
        Button.AutoButtonColor = false
        Button.Text = ""
        Button.Parent = Navigation

        local Corner = Instance.new("UICorner")
        Corner.CornerRadius = UDim.new(0, 8)
        Corner.Parent = Button

        local Icon = Instance.new("TextLabel")
        Icon.Name = "Icon"
        Icon.Position = UDim2.new(0, 14, 0, 0)
        Icon.Size = UDim2.fromOffset(30, 35)
        Icon.BackgroundTransparency = 1
        Icon.Text = icon
        Icon.TextColor3 = Color3.fromRGB(125, 135, 160)
        Icon.TextSize = 15
        Icon.Font = Enum.Font.GothamBold
        Icon.TextXAlignment = Enum.TextXAlignment.Center
        Icon.TextYAlignment = Enum.TextYAlignment.Center
        Icon.Parent = Button

        local Label = Instance.new("TextLabel")
        Label.Name = "Label"
        Label.Position = UDim2.new(0, 58, 0, 0)
        Label.Size = UDim2.new(1, -65, 1, 0)
        Label.BackgroundTransparency = 1
        Label.Text = text
        Label.TextColor3 = Color3.fromRGB(195, 202, 220)
        Label.TextSize = 12
        Label.Font = Enum.Font.GothamMedium
        Label.TextXAlignment = Enum.TextXAlignment.Left
        Label.Parent = Button

        navButtons[name] = {button = Button, icon = Icon, label = Label}
        return Button
    end

    createNavButton("Home", "HOME", "🏠")
    createNavButton("Barista", "BARISTA", "🔥")

    -- =====================================================
    -- DISCORD BUTTON
    -- =====================================================
    local DiscordButton = Instance.new("TextButton")
    DiscordButton.Name = "Discord"
    DiscordButton.AnchorPoint = Vector2.new(0.5, 1)
    DiscordButton.Position = UDim2.new(0.5, 0, 1, -18)
    DiscordButton.Size = UDim2.new(1, -36, 0, 30)
    DiscordButton.BackgroundColor3 = Color3.fromRGB(10, 28, 65)
    DiscordButton.BackgroundTransparency = 0.15
    DiscordButton.BorderSizePixel = 0
    DiscordButton.AutoButtonColor = false
    DiscordButton.Text = "👾   DISCORD"
    DiscordButton.TextColor3 = Color3.fromRGB(235, 240, 250)
    DiscordButton.TextSize = 11
    DiscordButton.Font = Enum.Font.GothamBold
    DiscordButton.Parent = Sidebar

    local DiscordCorner = Instance.new("UICorner")
    DiscordCorner.CornerRadius = UDim.new(0, 8)
    DiscordCorner.Parent = DiscordButton

    local DiscordStroke = Instance.new("UIStroke")
    DiscordStroke.Color = Color3.fromRGB(175, 50, 255)
    DiscordStroke.Transparency = 0.25
    DiscordStroke.Parent = DiscordButton

    -- =====================================================
    -- CONTENT CONTAINER
    -- =====================================================
    local Content = Instance.new("Frame")
    Content.Name = "Content"
    Content.Position = UDim2.new(0, 190, 0, 0)
    Content.Size = UDim2.new(1, -190, 1, 0)
    Content.BackgroundTransparency = 1
    Content.Parent = MainFrame

    local function createCard(parent, name, position, size)
        local Card = Instance.new("Frame")
        Card.Name = name
        Card.Position = position
        Card.Size = size
        Card.BackgroundColor3 = Color3.fromRGB(8, 15, 30)
        Card.BorderSizePixel = 0
        Card.Parent = parent

        local Corner = Instance.new("UICorner")
        Corner.CornerRadius = UDim.new(0, 10)
        Corner.Parent = Card

        local Stroke = Instance.new("UIStroke")
        Stroke.Color = Color3.fromRGB(25, 42, 68)
        Stroke.Transparency = 0.15
        Stroke.Thickness = 1
        Stroke.Parent = Card

        return Card
    end

    local function createCardTitle(parent, icon, text, color)
        local Icon = Instance.new("TextLabel")
        Icon.Position = UDim2.new(0, 16, 0, 16)
        Icon.Size = UDim2.fromOffset(22, 22)
        Icon.BackgroundTransparency = 1
        Icon.Text = icon
        Icon.TextColor3 = color
        Icon.TextSize = 18
        Icon.Font = Enum.Font.GothamBold
        Icon.TextYAlignment = Enum.TextYAlignment.Center
        Icon.Parent = parent

        local Title = Instance.new("TextLabel")
        Title.Position = UDim2.new(0, 45, 0, 10)
        Title.Size = UDim2.new(1, -58, 0, 35)
        Title.BackgroundTransparency = 1
        Title.Text = text
        Title.TextColor3 = Color3.fromRGB(235, 240, 250)
        Title.TextSize = 14
        Title.Font = Enum.Font.GothamMedium
        Title.TextXAlignment = Enum.TextXAlignment.Left
        Title.TextYAlignment = Enum.TextYAlignment.Center
        Title.Parent = parent
    end

    -- =====================================================
    -- TOPBAR
    -- =====================================================
    local TopBar = Instance.new("Frame")
    TopBar.Name = "TopBar"
    TopBar.Size = UDim2.new(1, 0, 0, 60)
    TopBar.BackgroundTransparency = 1
    TopBar.Parent = Content

    -- PlanBadge digeser ke paling kiri (XOffset = 25)
    local PlanBadge = Instance.new("Frame", TopBar)
    PlanBadge.Name = "PlanBadge"
    PlanBadge.Position = UDim2.new(0, 25, 0.5, -12)
    PlanBadge.Size = UDim2.fromOffset(110, 24)
    PlanBadge.BackgroundColor3 = (AuthState.plan_license == "NEX-ETERNAL") and Color3.fromRGB(35, 15, 60) or Color3.fromRGB(12, 22, 45)
    PlanBadge.BorderSizePixel = 0

    local PlanBadgeCorner = Instance.new("UICorner", PlanBadge)
    PlanBadgeCorner.CornerRadius = UDim.new(0, 6)

    local PlanBadgeText = Instance.new("TextLabel", PlanBadge)
    PlanBadgeText.Size = UDim2.fromScale(1, 1)
    PlanBadgeText.BackgroundTransparency = 1
    PlanBadgeText.Text = "👑 " .. tostring(AuthState.plan_license or "NEX-FREE")
    PlanBadgeText.TextColor3 = (AuthState.plan_license == "NEX-ETERNAL") and Color3.fromRGB(240, 160, 255) or Color3.fromRGB(180, 220, 255)
    PlanBadgeText.TextSize = 10
    PlanBadgeText.Font = Enum.Font.GothamBold

    -- =====================================================
    -- ANIMATED MARQUEE GRADIENT TEXT (TOPBAR CENTER)
    -- =====================================================
    local MarqueeContainer = Instance.new("Frame")
    MarqueeContainer.Name = "MarqueeContainer"
    MarqueeContainer.Position = UDim2.new(0, 145, 0.5, -15)
    MarqueeContainer.Size = UDim2.new(1, -240, 0, 30)
    MarqueeContainer.BackgroundTransparency = 1
    MarqueeContainer.ClipsDescendants = true
    MarqueeContainer.Parent = TopBar

    local MarqueeLabel = Instance.new("TextLabel")
    MarqueeLabel.Name = "MarqueeLabel"
    MarqueeLabel.Position = UDim2.new(1, 0, 0, 0)
    MarqueeLabel.Size = UDim2.new(0, 0, 1, 0)
    MarqueeLabel.AutomaticSize = Enum.AutomaticSize.X
    MarqueeLabel.BackgroundTransparency = 1
    MarqueeLabel.Text = "✨ Welcome to NEXOVA HUB! Thank you for purchasing and using products from Nexova! Unleash Your Power! ✨"
    MarqueeLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    MarqueeLabel.TextSize = 12.5
    MarqueeLabel.Font = Enum.Font.GothamBold
    MarqueeLabel.TextXAlignment = Enum.TextXAlignment.Left
    MarqueeLabel.TextYAlignment = Enum.TextYAlignment.Center
    MarqueeLabel.Parent = MarqueeContainer

    -- UIGradient Warna Neon Nexova
    local TextGradient = Instance.new("UIGradient")
    TextGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 235, 145)),
        ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 180, 255)),
        ColorSequenceKeypoint.new(0.66, Color3.fromRGB(235, 40, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 235, 145))
    })
    TextGradient.Rotation = 0 -- Dipasang mendatar (0 derajat)
    TextGradient.Offset = Vector2.new(-1, 0)
    TextGradient.Parent = MarqueeLabel

    -- 1. Loop Animasi Pergeseran Teks (Kanan ke Kiri)
    task.spawn(function()
        local TweenService = game:GetService("TweenService")
        task.wait(0.1)
        
        local textWidth = MarqueeLabel.TextBounds.X
        local duration = 14 -- Durasi jalan teks
        
        while MarqueeLabel and MarqueeLabel.Parent do
            MarqueeLabel.Position = UDim2.new(1, 0, 0, 0)
            
            local tween = TweenService:Create(MarqueeLabel, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
                Position = UDim2.new(0, -textWidth, 0, 0)
            })
            
            tween:Play()
            tween.Completed:Wait()
        end
    end)

    -- 2. Loop Animasi Gradient Bergerak dari KIRI KE KANAN (Lebih Halus & Pelan)
    task.spawn(function()
        local TweenService = game:GetService("TweenService")
        
        -- Durasi 6 detik membuat gerakannya jauh lebih smooth dan santai
        local gradTweenInfo = TweenInfo.new(6, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1)
        
        TextGradient.Offset = Vector2.new(-1, 0)
        local gradTween = TweenService:Create(TextGradient, gradTweenInfo, {
            Offset = Vector2.new(1, 0) -- Menggeser ke kanan
        })
        gradTween:Play()
    end)

    -- =====================================================
    -- WINDOW BUTTON
    -- =====================================================
    local function createWindowButton(name, text, position)
        local Button = Instance.new("TextButton")
        Button.Name = name
        Button.Position = position
        Button.Size = UDim2.fromOffset(30, 30)
        Button.BackgroundColor3 = Color3.fromRGB(8, 15, 30)
        Button.BackgroundTransparency = 0.2
        Button.BorderSizePixel = 0
        Button.AutoButtonColor = false
        Button.Text = text
        Button.TextColor3 = Color3.fromRGB(235, 240, 250)
        Button.TextSize = 20
        Button.Font = Enum.Font.Gotham
        Button.Parent = TopBar

        local Corner = Instance.new("UICorner")
        Corner.CornerRadius = UDim.new(0, 8)
        Corner.Parent = Button

        local Stroke = Instance.new("UIStroke")
        Stroke.Color = Color3.fromRGB(30, 45, 70)
        Stroke.Transparency = 0.3
        Stroke.Parent = Button

        return Button
    end

    local MinimizeButton = createWindowButton("Minimize", "-", UDim2.new(1, -86, 0.5, -15))
    local CloseButton = createWindowButton("Close", "×", UDim2.new(1, -50, 0.5, -15))
    CloseButton.TextColor3 = Color3.fromRGB(235, 40, 255)

    -- =====================================================
    -- DIVIDER LINE (GARIS PEMISAH TOPBAR & CONTENT)
    -- =====================================================
    local TopBarDivider = Instance.new("Frame")
    TopBarDivider.Name = "TopBarDivider"
    TopBarDivider.Position = UDim2.new(0, 25, 1, -5)
    TopBarDivider.Size = UDim2.new(1, -50, 0, 1)
    TopBarDivider.BackgroundColor3 = Color3.fromRGB(30, 45, 75)
    TopBarDivider.BorderSizePixel = 0
    TopBarDivider.Parent = TopBar

    -- Gradient untuk efek fade memudar di kedua pinggir garis
    local DividerGradient = Instance.new("UIGradient")
    DividerGradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.8),
        NumberSequenceKeypoint.new(0.2, 0),
        NumberSequenceKeypoint.new(0.8, 0),
        NumberSequenceKeypoint.new(1, 0.8)
    })
    DividerGradient.Parent = TopBarDivider

    -- =====================================================
    -- BODY
    -- =====================================================
    local Body = Instance.new("Frame")
    Body.Name = "Body"
    Body.Position = UDim2.new(0, 25, 0, 70)
    Body.Size = UDim2.new(1, -50, 1, -85)
    Body.BackgroundTransparency = 1
    Body.Parent = Content

    -- =====================================================
    -- HOME PAGE
    -- =====================================================
    local HomePage = Instance.new("Frame")
    HomePage.Name = "HomePage"
    HomePage.Size = UDim2.fromScale(1, 1)
    HomePage.BackgroundTransparency = 1
    HomePage.Visible = true
    HomePage.Parent = Body

    -- =====================================================
    -- PROFILE CARD
    -- =====================================================
    local ProfileCard = createCard(HomePage, "Profile", UDim2.new(0, 0, 0, 0), UDim2.new(0, 223, 0, 190))
    createCardTitle(ProfileCard, "👤", "PROFILE", Color3.fromRGB(0, 180, 255))

    -- AVATAR
    local Avatar = Instance.new("ImageLabel")
    Avatar.Name = "Avatar"
    Avatar.Position = UDim2.new(0, 14, 0, 50)
    Avatar.Size = UDim2.fromOffset(100, 100)
    Avatar.BackgroundColor3 = Color3.fromRGB(15, 22, 38)
    Avatar.BorderSizePixel = 0
    Avatar.Parent = ProfileCard

    local AvatarCorner = Instance.new("UICorner")
    AvatarCorner.CornerRadius = UDim.new(1, 0)
    AvatarCorner.Parent = Avatar

    local AvatarStroke = Instance.new("UIStroke")
    AvatarStroke.Color = Color3.fromRGB(0, 180, 255)
    AvatarStroke.Transparency = 0.25
    AvatarStroke.Parent = Avatar

    pcall(function()
        local image = Players:GetUserThumbnailAsync(LocalPlayer.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size180x180)
        Avatar.Image = image
    end)

    -- PROFILE INFO
    local function profileRow(parent, y, label, value)
        local Label = Instance.new("TextLabel")
        Label.Position = UDim2.new(0, 130, 0, y)
        Label.Size = UDim2.new(1, -130, 0, 15)
        Label.BackgroundTransparency = 1
        Label.Text = label
        Label.TextColor3 = Color3.fromRGB(125, 135, 160)
        Label.TextSize = 10
        Label.Font = Enum.Font.Gotham
        Label.TextXAlignment = Enum.TextXAlignment.Left
        Label.TextYAlignment = Enum.TextYAlignment.Center
        Label.Parent = parent

        local Value = Instance.new("TextLabel")
        Value.Position = UDim2.new(0, 130, 0, y + 13)
        Value.Size = UDim2.new(1, -130, 0, 17)
        Value.BackgroundTransparency = 1
        Value.Text = value
        Value.TextColor3 = Color3.fromRGB(235, 240, 250)
        Value.TextSize = 11.5
        Value.Font = Enum.Font.GothamMedium
        Value.TextXAlignment = Enum.TextXAlignment.Left
        Value.TextYAlignment = Enum.TextYAlignment.Center
        Value.TextTruncate = Enum.TextTruncate.AtEnd
        Value.Parent = parent

        return Value
    end

    profileRow(ProfileCard, 50, "Username", LocalPlayer.Name)
    profileRow(ProfileCard, 90, "Display Name", LocalPlayer.DisplayName)
    profileRow(ProfileCard, 130, "User ID", tostring(LocalPlayer.UserId))

    -- ONLINE DOT
    local AvatarOnline = Instance.new("Frame")
    AvatarOnline.AnchorPoint = Vector2.new(1, 1)
    AvatarOnline.Position = UDim2.new(0, 114, 0, 150)
    AvatarOnline.Size = UDim2.fromOffset(13, 13)
    AvatarOnline.BackgroundColor3 = Color3.fromRGB(0, 235, 145)
    AvatarOnline.BorderSizePixel = 0
    AvatarOnline.Parent = ProfileCard

    local AvatarOnlineCorner = Instance.new("UICorner")
    AvatarOnlineCorner.CornerRadius = UDim.new(1, 0)
    AvatarOnlineCorner.Parent = AvatarOnline

    -- =====================================================
    -- LICENSE CARD (Ukuran kembali normal 190)
    -- =====================================================
    local LicenseCard = createCard(HomePage, "License", UDim2.new(0, 237, 0, 0), UDim2.new(0, 223, 0, 190))
    createCardTitle(LicenseCard, "🔑", "LICENSE", Color3.fromRGB(175, 50, 255))

    local function maskLicense(key)
        if not key or key == "" then return "N/A" end
        if #key <= 8 then return key end
        return string.sub(key, 1, 4) .. "-XXXX-XXXX-" .. string.sub(key, -4)
    end

    local function licenseRow(y, label, value, valueColor)
        local Label = Instance.new("TextLabel")
        Label.Position = UDim2.new(0, 14, 0, y)
        Label.Size = UDim2.fromOffset(70, 22)
        Label.BackgroundTransparency = 1
        Label.Text = label
        Label.TextColor3 = Color3.fromRGB(125, 135, 160)
        Label.TextSize = 11
        Label.Font = Enum.Font.Gotham
        Label.TextXAlignment = Enum.TextXAlignment.Left
        Label.TextYAlignment = Enum.TextYAlignment.Center
        Label.Parent = LicenseCard

        local Value = Instance.new("TextLabel")
        Value.Position = UDim2.new(0, 80, 0, y)
        Value.Size = UDim2.new(1, -94, 0, 22)
        Value.BackgroundTransparency = 1
        Value.Text = value
        Value.TextColor3 = valueColor or Color3.fromRGB(235, 240, 250)
        Value.TextSize = 11.5
        Value.Font = Enum.Font.GothamMedium
        Value.TextXAlignment = Enum.TextXAlignment.Right
        Value.TextYAlignment = Enum.TextYAlignment.Center
        Value.TextTruncate = Enum.TextTruncate.AtEnd
        Value.Parent = LicenseCard

        return Value
    end

    local LicenseStatus = tostring(AuthState.status_license or "unknown")
    local LicenseStatusText = "Active"

    if LicenseStatus == "active" then 
        LicenseStatusText = "✓ Active"
    elseif LicenseStatus == "expired" then 
        LicenseStatusText = "✕ Expired"
    elseif LicenseStatus == "revoked" then 
        LicenseStatusText = "✕ Revoked"
    else 
        LicenseStatusText = LicenseStatus
    end

    local LicenseStatusColor = Color3.fromRGB(0, 235, 145)
    if LicenseStatus ~= "active" then
        LicenseStatusColor = Color3.fromRGB(255, 80, 90)
    end

    local expiresText
    if AuthState.plan_license == "NEX-ETERNAL" or AuthState.expired_at == "Lifetime" then
        expiresText = "Lifetime"
    else
        expiresText = tostring(AuthState.expired_at or "N/A")
    end

    local currentPlan = tostring(AuthState.plan_license or "NEX-FREE")
    local planColor = Color3.fromRGB(0, 180, 255)

    if currentPlan == "NEX-ETERNAL" then
        planColor = Color3.fromRGB(235, 40, 255)
        currentPlan = "👑 NEX-ETERNAL"
    elseif currentPlan == "NEX-APEX" then
        planColor = Color3.fromRGB(255, 180, 0)
        currentPlan = "⭐ NEX-APEX"
    end

    local productCodeText = tostring(Config and Config.PRODUCT_CODE or AuthState.product_code or "NEX-CDID-BARISTA")

    -- Jarak Y dipersingkat (interval 26px) agar 5 baris muat pas di dalam card 190px
    licenseRow(42, "Status", LicenseStatusText, LicenseStatusColor)
    licenseRow(68, "Product", productCodeText, Color3.fromRGB(180, 210, 255))
    licenseRow(94, "License Key", maskLicense(AuthState.key))
    licenseRow(120, "Plan", currentPlan, planColor)
    licenseRow(146, "Expires", expiresText)

    -- =====================================================
    -- SESSION, FPS, PING
    -- =====================================================
    local function createHomeMetricCard(name, position, size, icon, title, initialVal, accentColor, hasGradient)
        local Card = createCard(HomePage, name, position, size)
        createCardTitle(Card, icon, title, accentColor)

        local ValueLabel = Instance.new("TextLabel")
        ValueLabel.Position = UDim2.new(0, 14, 0, 48)
        ValueLabel.Size = UDim2.new(1, -28, 0, 25)
        ValueLabel.BackgroundTransparency = 1
        ValueLabel.Text = initialVal
        ValueLabel.TextColor3 = Color3.fromRGB(235, 240, 250)
        ValueLabel.TextSize = 14
        ValueLabel.Font = Enum.Font.GothamMedium
        ValueLabel.TextXAlignment = Enum.TextXAlignment.Left
        ValueLabel.Parent = Card

        local Line = Instance.new("Frame")
        Line.Position = UDim2.new(0, 14, 1, -16)
        Line.Size = UDim2.new(1, -28, 0, 3)
        Line.BackgroundColor3 = Color3.fromRGB(30, 40, 65)
        Line.BorderSizePixel = 0
        Line.ClipsDescendants = true
        Line.Parent = Card

        local LineCorner = Instance.new("UICorner")
        LineCorner.CornerRadius = UDim.new(1, 0)
        LineCorner.Parent = Line

        local FillBar = nil
        if not hasGradient then
            FillBar = Instance.new("Frame")
            FillBar.Position = UDim2.new(0, 0, 0, 0)
            FillBar.Size = UDim2.new(0, 0, 1, 0)
            FillBar.BackgroundColor3 = accentColor
            FillBar.BorderSizePixel = 0
            FillBar.Parent = Line
            
            local FillCorner = Instance.new("UICorner")
            FillCorner.CornerRadius = UDim.new(1, 0)
            FillCorner.Parent = FillBar
        else
            local Gradient = Instance.new("UIGradient")
            Gradient.Color = ColorSequence.new({ColorSequenceKeypoint.new(0, Color3.fromRGB(175, 50, 255)), ColorSequenceKeypoint.new(1, Color3.fromRGB(235, 40, 255))})
            Gradient.Parent = Line
        end

        return ValueLabel, FillBar
    end

    local SessionTime = createHomeMetricCard("Session", UDim2.new(0, 0, 0, 204), UDim2.new(0, 144, 0, 100), "⏳", "SESSION", "00:00:00", Color3.fromRGB(175, 50, 255), true)
    local FPSValue, FPSFill = createHomeMetricCard("FPS", UDim2.new(0, 158, 0, 204), UDim2.new(0, 144, 0, 100), "💻", "FPS", "0 FPS", Color3.fromRGB(0, 180, 255), false)
    local PingValue, PingFill = createHomeMetricCard("Ping", UDim2.new(0, 316, 0, 204), UDim2.new(0, 144, 0, 100), "📶", "PING", "0 MS", Color3.fromRGB(0, 235, 145), false)

    if PingFill then PingFill.Size = UDim2.fromScale(0.85, 1) end

    -- =====================================================
    -- REAL-TIME UPDATERS (SESSION, FPS, PING)
    -- =====================================================
    local sessionStartTick = tick()
    local countedFrames = 0
    local timerTick = tick()

    Connections["FPS_RenderStepped"] = RunService.RenderStepped:Connect(function()
        countedFrames = (tonumber(countedFrames) or 0) + 1
    end)

    task.spawn(function()
        while task.wait(0.5) do
            local nowTick = tick()
            local diffTime = nowTick - timerTick
            
            local elapsedSec = math.floor(nowTick - sessionStartTick)
            local hrs = math.floor(elapsedSec / 3600)
            local mins = math.floor((elapsedSec % 3600) / 60)
            local secs = elapsedSec % 60
            if SessionTime then
                SessionTime.Text = string.format("%02d:%02d:%02d", hrs, mins, secs)
            end

            if diffTime > 0 then
                local currentFps = math.floor(((tonumber(countedFrames) or 0) / diffTime) + 0.5)
                timerTick = nowTick
                countedFrames = 0
                
                local maxBarWidth = 116

                -- Update FPS Bar
                pcall(function()
                    if FPSValue then
                        FPSValue.Text = (currentFps and type(currentFps) == "number") and (currentFps .. " FPS") or "0 FPS"
                    end

                    if FPSFill then
                        local fpsPercent = math.clamp(currentFps / 240, 0.05, 1)
                        local calculatedWidth = math.floor(maxBarWidth * fpsPercent)
                        FPSFill.Size = UDim2.new(0, calculatedWidth, 0, 3)
                    end
                end)
                
                -- Update Ping Bar
                pcall(function()
                    local stats = game:GetService("Stats")
                    local networkStats = stats and stats.Network
                    local serverStatsItem = networkStats and networkStats.ServerStatsItem
                    local pingItem = serverStatsItem and serverStatsItem:FindFirstChild("Data Ping")
                    
                    if pingItem then
                        local pVal = math.floor(pingItem:GetValue())
                        if PingValue then PingValue.Text = pVal .. " MS" end
                        
                        if PingFill then
                            local pingPercent = math.clamp(1 - (pVal / 500), 0.05, 1)
                            local calculatedWidth = math.floor(maxBarWidth * pingPercent)
                            PingFill.Size = UDim2.new(0, calculatedWidth, 0, 3)
                        end
                    else
                        if PingValue then PingValue.Text = "65 MS" end
                        if PingFill then PingFill.Size = UDim2.new(0, math.floor(maxBarWidth * 0.8), 0, 3) end
                    end
                end)
            end
        end
    end)

    -- =====================================================
    -- AUTO BARISTA PAGE
    -- =====================================================
    local BaristaPage = Instance.new("Frame")
    BaristaPage.Name = "BaristaPage"
    BaristaPage.Size = UDim2.fromScale(1, 1)
    BaristaPage.BackgroundTransparency = 1
    BaristaPage.Visible = false
    BaristaPage.Parent = Body

    local function createAutoBaristaMetricCard(name, position, size, icon, title, initialText, accentColor, isGradient)
        local Card = createCard(BaristaPage, name, position, size)
        createCardTitle(Card, icon, title, accentColor)

        local ValueLabel = Instance.new("TextLabel")
        ValueLabel.Name = "ValueLabel"
        ValueLabel.Position = UDim2.new(0, 14, 0, 48)
        ValueLabel.Size = UDim2.new(1, -28, 0, 25)
        ValueLabel.BackgroundTransparency = 1
        ValueLabel.Text = initialText
        ValueLabel.TextColor3 = Color3.fromRGB(235, 240, 250)
        ValueLabel.TextSize = 14
        ValueLabel.Font = Enum.Font.GothamMedium
        ValueLabel.TextXAlignment = Enum.TextXAlignment.Left
        ValueLabel.TextTruncate = Enum.TextTruncate.AtEnd
        ValueLabel.Parent = Card

        local Line = Instance.new("Frame")
        Line.Name = "AccentLine"
        Line.Position = UDim2.new(0, 14, 1, -16)
        Line.Size = UDim2.new(1, -28, 0, 3)
        Line.BackgroundColor3 = accentColor
        Line.BorderSizePixel = 0
        Line.Parent = Card

        local LineCorner = Instance.new("UICorner")
        LineCorner.CornerRadius = UDim.new(1, 0)
        LineCorner.Parent = Line

        if isGradient then
            Line.BackgroundColor3 = Color3.fromRGB(30, 20, 55)
            local Gradient = Instance.new("UIGradient")
            Gradient.Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, Color3.fromRGB(175, 50, 255)), 
                ColorSequenceKeypoint.new(1, Color3.fromRGB(235, 40, 255))
            })
            Gradient.Parent = Line
        end

        return ValueLabel
    end

    -- =====================================================
    -- TOP ROW (METRICS)
    -- =====================================================
    local BaristaStatusValue  = createAutoBaristaMetricCard("BaristaStatusCard", UDim2.new(0, 0, 0, 0),   UDim2.new(0, 144, 0, 110), "⚙️", "STATUS", "● STOPPED", Color3.fromRGB(255, 80, 90), false)
    local BaristaOrdersValue  = createAutoBaristaMetricCard("BaristaOrdersCard", UDim2.new(0, 158, 0, 0),   UDim2.new(0, 144, 0, 110), "☕", "ORDERS", "0", Color3.fromRGB(175, 50, 255), true)
    local BaristaElapsedValue = createAutoBaristaMetricCard("BaristaElapsedCard", UDim2.new(0, 316, 0, 0),   UDim2.new(0, 144, 0, 110), "⏳", "ELAPSED", "00:00:00", Color3.fromRGB(175, 50, 255), true)

    -- =====================================================
    -- MIDDLE ROW (STATUS INFO & 2 METRIC CARDS SAMAKAN UKURAN)
    -- =====================================================
    -- 1. Main Status Progress Box (Lebar 144px, sejajar dengan STATUS Card atas)
    local AutoBaristaProgressCard = createCard(BaristaPage, "AutoBaristaProgressCard", UDim2.new(0, 0, 0, 126), UDim2.new(0, 144, 0, 104))
    createCardTitle(AutoBaristaProgressCard, "📊", "STATUS INFO", Color3.fromRGB(175, 50, 255))

    local AutoBaristaStatusProgress = Instance.new("TextLabel")
    AutoBaristaStatusProgress.Name = "StatusProgressLabel"
    AutoBaristaStatusProgress.Position = UDim2.new(0, 8, 0, 48)
    AutoBaristaStatusProgress.Size = UDim2.new(1, -16, 0, 42)
    AutoBaristaStatusProgress.BackgroundColor3 = Color3.fromRGB(15, 20, 35)
    AutoBaristaStatusProgress.BackgroundTransparency = 0.5
    AutoBaristaStatusProgress.BorderSizePixel = 0
    AutoBaristaStatusProgress.Text = "Status: Idle / Waiting to start..."
    AutoBaristaStatusProgress.TextColor3 = Color3.fromRGB(200, 210, 230)
    AutoBaristaStatusProgress.TextSize = 11
    AutoBaristaStatusProgress.Font = Enum.Font.Gotham
    AutoBaristaStatusProgress.TextWrapped = true
    AutoBaristaStatusProgress.Parent = AutoBaristaProgressCard

    local ProgressCorner = Instance.new("UICorner")
    ProgressCorner.CornerRadius = UDim.new(0, 6)
    ProgressCorner.Parent = AutoBaristaStatusProgress

    local ProgressStroke = Instance.new("UIStroke")
    ProgressStroke.Color = Color3.fromRGB(175, 50, 255)
    ProgressStroke.Transparency = 0.5
    ProgressStroke.Parent = AutoBaristaStatusProgress

    -- 2. Metric Card Tengah #1: CURRENT MENU (Ukuran 144px, Posisi X: 158px -> SejajarORDERS Card)
    local BaristaMenuValue = createAutoBaristaMetricCard("BaristaMenuCard", UDim2.new(0, 158, 0, 126), UDim2.new(0, 144, 0, 104), "📋", "MENU", "-", Color3.fromRGB(0, 200, 255), false)

    -- 3. Metric Card Tengah #2: CURRENT FLAVOUR (Ukuran 144px, Posisi X: 316px -> Sejajar ELAPSED Card)
    local BaristaFlavourValue = createAutoBaristaMetricCard("BaristaFlavourCard", UDim2.new(0, 316, 0, 126), UDim2.new(0, 144, 0, 104), "🧪", "FLAVOUR", "-", Color3.fromRGB(0, 200, 255), false)

    -- =====================================================
    -- BOTTOM ROW (CONTROLS)
    -- =====================================================
    local BaristaControlCard = createCard(BaristaPage, "BaristaControlCard", UDim2.new(0, 0, 0, 248), UDim2.new(0, 460, 0, 104))
    createCardTitle(BaristaControlCard, "☕", "AUTO BARISTA CONTROL", Color3.fromRGB(175, 50, 255))

    local BaristaStartButton = Instance.new("TextButton")
    BaristaStartButton.Name = "StartBaristaButton"
    BaristaStartButton.Position = UDim2.new(0, 14, 0, 50)
    BaristaStartButton.Size = UDim2.new(1, -28, 0, 36)
    BaristaStartButton.BackgroundColor3 = Color3.fromRGB(10, 28, 65)
    BaristaStartButton.BorderSizePixel = 0
    BaristaStartButton.Text = "START AUTO BARISTA"
    BaristaStartButton.TextColor3 = Color3.fromRGB(235, 240, 250)
    BaristaStartButton.TextSize = 12
    BaristaStartButton.Font = Enum.Font.GothamMedium
    BaristaStartButton.AutoButtonColor = false
    BaristaStartButton.Parent = BaristaControlCard

    local StartCorner = Instance.new("UICorner")
    StartCorner.CornerRadius = UDim.new(0, 6)
    StartCorner.Parent = BaristaStartButton

    local StartStroke = Instance.new("UIStroke")
    StartStroke.Color = Color3.fromRGB(0, 180, 255)
    StartStroke.Transparency = 0.35
    StartStroke.Parent = BaristaStartButton

    -- =========================================================
    -- AUTO BARISTA LOGIC
    -- =========================================================
    local autoBarista = false
    local startTime = 0
    local ordersCompletedCount = 0
    local BaristaMenu = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BaristaMenu"))
    local currentOrder = nil
    local orderScannerConnection = nil

    local function firePrompt(prompt)
        if not (prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled) then return end
        pcall(function()
            if fireproximityprompt then
                fireproximityprompt(prompt)
            else
                prompt:InputHoldBegin()
                task.wait(prompt.HoldDuration or 0.5)
                prompt:InputHoldEnd()
            end
        end)
    end

    local function smartTeleportTo(destination)
        local Character = LocalPlayer.Character
        local Humanoid = Character and Character:FindFirstChildOfClass("Humanoid")
        local RootPart = Character and Character:FindFirstChild("HumanoidRootPart")
        
        local targetCFrame = nil

        -- 1. Deteksi tipe input: Apakah berupa CFrame atau Nama Objek (String)?
        if typeof(destination) == "CFrame" then
            targetCFrame = destination
        elseif type(destination) == "string" then
            local targetObj = workspace:FindFirstChild(destination, true)
            if targetObj then
                -- Ambil CFrame berdasarkan apakah objek berupa Part atau Model
                if targetObj:IsA("BasePart") then
                    targetCFrame = targetObj.CFrame * CFrame.new(0, 0, -3)
                elseif targetObj:IsA("Model") then
                    targetCFrame = targetObj:GetPivot() * CFrame.new(0, 0, -3)
                end
            else
                debugWarn("The target was not found in the workspace: " .. destination)
                return
            end
        else
            debugWarn("The teleport destination format is invalid!")
            return
        end

        -- 2. Eksekusi perpindahan (Otomatis deteksi Mobil atau Jalan Kaki)
        if targetCFrame then
            if Humanoid and Humanoid.SeatPart and Humanoid.SeatPart:IsA("VehicleSeat") then
                local DriveSeat = Humanoid.SeatPart
                local Vehicle = DriveSeat.Parent

                if Vehicle and Vehicle:IsA("Model") then
                    -- Netralkan kecepatan mobil agar tidak terlempar
                    DriveSeat.AssemblyLinearVelocity = Vector3.zero
                    DriveSeat.AssemblyAngularVelocity = Vector3.zero

                    -- Pindahkan mobil
                    Vehicle:PivotTo(targetCFrame)

                    task.wait(0.05)
                    DriveSeat.AssemblyLinearVelocity = Vector3.zero
                    DriveSeat.AssemblyAngularVelocity = Vector3.zero
                end
            else
                -- Jika jalan kaki
                if RootPart then
                    RootPart.CFrame = targetCFrame
                end
            end


        end
    end

    local function pressSpaceKey(times, interval)
        for i = 1, times do
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
            task.wait(0.05)
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
            task.wait(interval)
        end
    end

    local function clickGuiButton(btn)
        if not btn then return end

        -- Cara 1: Gunakan firesignal jika executor mendukung (paling stabil)
        if firesignal then
            pcall(function() firesignal(btn.MouseButton1Click) end)
            pcall(function() firesignal(btn.MouseButton1Down) end)
            pcall(function() firesignal(btn.Activated) end)
            return
        end

        -- Cara 2: Iterasi getconnections dengan pcall & conn:Fire()
        if getconnections then
            local events = {btn.MouseButton1Click, btn.MouseButton1Down, btn.Activated}
            local fired = false

            for _, event in ipairs(events) do
                for _, conn in pairs(getconnections(event)) do
                    if conn.Fire then
                        pcall(function() conn:Fire() end)
                        fired = true
                    elseif conn.Function then
                        pcall(function() conn:Function() end)
                        fired = true
                    end
                end
            end

            if fired then return end
        end

        -- Cara 3: Fallback ke VirtualUser / GuiService
        if btn:IsA("GuiButton") then
            pcall(function()
                local guiService = game:GetService("GuiService")
                guiService.SelectedObject = btn
                
                local virtualUser = game:GetService("VirtualUser")
                virtualUser:Button1Down(Vector2.new(0, 0))
                virtualUser:Button1Up(Vector2.new(0, 0))
            end)
        end
    end

    local function runAutoBrew()

        local BrewGui = playerGui:WaitForChild("Job"):WaitForChild("BrewMinigame")
        local Track = BrewGui:WaitForChild("Track")
        local Zone = Track:WaitForChild("Zone")
        local Needle = Track:WaitForChild("Needle")

        -- Tunggu sampai BrewMinigame benar-benar aktif
        local timeout = os.clock() + 10

        while not BrewGui.Visible and os.clock() < timeout do
            task.wait(0.05)
        end

        if not BrewGui.Visible then
            debugWarn("[BARISTA] BrewMinigame tidak muncul")
            return false
        end

        debugPrint("[BARISTA] Auto Brew Started")

        local holding = false
        local lastX = Needle.Position.X.Scale
        local lastTime = os.clock()

        local function setHold(state)
            if holding == state then return end
            holding = state
            VirtualInputManager:SendKeyEvent(state, Enum.KeyCode.Space, false, game)
        end

        while BrewGui.Parent and BrewGui.Visible do

            local now = os.clock()
            local dt = now - lastTime

            if dt > 0 then
                local needleX = Needle.Position.X.Scale
                local zoneX = Zone.Position.X.Scale
                local zoneWidth = Zone.Size.X.Scale
                -- Tengah Zone
                local targetX = zoneX + (zoneWidth / 2)
                -- Kecepatan Needle
                local velocity = (needleX - lastX) / dt
                -- Prediction asimetris
                local predictionTime
                if velocity > 0 then
                    -- Bergerak kanan -> rem lebih awal
                    predictionTime = 0.30
                else
                    -- Bergerak kiri -> biarkan lebih bebas
                    predictionTime = 0.08
                end
                local predictedX = needleX + (velocity * predictionTime)
                local predictedError = targetX - predictedX
                local centerTolerance = 0.012

                ------------------------------------------------
                -- CONTROL
                ------------------------------------------------

                if predictedError > centerTolerance then
                    -- Needle terlalu kiri
                    -- Tekan Space -> gerak kanan
                    setHold(true)
                elseif predictedError < -centerTolerance then
                    -- Needle terlalu kanan
                    -- Lepas Space -> gerak kiri
                    setHold(false)
                else
                    -- Masih di sekitar tengah
                    if velocity > 0.025 then
                        -- Masih bergerak kanan
                        -- Lepas lebih awal
                        setHold(false)
                    elseif velocity < -0.025 then
                        -- Sedang bergerak kiri
                        -- Jangan buru-buru rem
                        setHold(false)
                    else
                        -- Hampir diam
                        setHold(false)
                    end
                end
                lastX = needleX
                lastTime = now
            end
            task.wait(0.01)
        end

        -- Pastikan Space dilepas
        setHold(false)

        debugPrint("[BARISTA] Auto Brew Finished")

        return true
    end

    local function getMenuIdFromName(menuName)

        if not menuName or menuName == "" then
            return nil
        end

        for menuId, data in pairs(BaristaMenu.Items) do
            if data.name then
                local nameID = data.name.id
                local nameEN = data.name.en
                if nameID == menuName or nameEN == menuName then return menuId end
            end
        end

        return nil
    end

    local function scanCurrentOrder()

        local npcDialog = playerGui:FindFirstChild("NpcDialog")

        if not npcDialog then return nil end

        local textObject

        if npcDialog:IsA("TextLabel") or npcDialog:IsA("TextButton") or npcDialog:IsA("TextBox") then
            textObject = npcDialog
        else
            textObject = npcDialog:FindFirstChildWhichIsA("TextLabel", true)
        end

        if not textObject then return nil end

        local text = textObject.Text

        if not text or text == "" then return nil end

        ------------------------------------------------
        -- Contoh:
        -- "Halo! Aku pesan Es Kopi Susu, rasa Caramel ya."
        ------------------------------------------------

        local menuName, flavour

        -- Dengan rasa
        menuName, flavour = text:match("[Pp]esan%s+(.+),%s*[Rr]asa%s+(.+)%s+[Yy]a")

        -- Tanpa rasa
        if not menuName then
            menuName = text:match("[Pp]esan%s+(.+)%s+[Yy]a")
        end

        if not menuName then
            return nil
        end

        menuName = menuName:gsub("^%s+", "")
        menuName = menuName:gsub("%s+$", "")

        if flavour then
            flavour = flavour:gsub("^%s+", "")
            flavour = flavour:gsub("%s+$", "")
        end

        ------------------------------------------------
        -- Cari MenuId internal
        ------------------------------------------------

        local menuId = getMenuIdFromName(menuName)

        if not menuId then
            debugWarn("[BARISTA] Menu tidak ditemukan:", menuName)
            return nil
        end

        ------------------------------------------------
        -- Ambil recipe steps
        ------------------------------------------------
        local steps = nil
        if BaristaMenu.Items[menuId] then
            steps = BaristaMenu.Items[menuId].steps
        end

        ------------------------------------------------
        -- Simpan currentOrder
        ------------------------------------------------
        currentOrder = {
            Menu = menuName,
            MenuId = menuId,
            Flavour = flavour,
            RawText = text,
            Steps = steps
        }

        debugPrint("==============================")
        debugPrint("[BARISTA] ORDER DETECTED")
        debugPrint("[BARISTA] Menu   :", currentOrder.Menu)
        debugPrint("[BARISTA] Menu ID:", currentOrder.MenuId)
        debugPrint("[BARISTA] Flavour:", currentOrder.Flavour or "-")
        debugPrint("[BARISTA] Raw    :", currentOrder.RawText)

        if currentOrder.Steps then
            for i, step in ipairs(currentOrder.Steps) do
                debugPrint("[BARISTA] Step", i, ":", step)
            end
        end

        debugPrint("==============================")

        -- Update Text Card Menu & Flavour di Middle Row
        pcall(function()
            if BaristaMenuValue then BaristaMenuValue.Text = currentOrder.Menu or "-" end
            if BaristaFlavourValue then BaristaFlavourValue.Text = currentOrder.Flavour or "-" end
        end)

        return currentOrder
    end

    local function waitForCurrentOrder(timeout)
        timeout = timeout or 10
        local deadline = os.clock() + timeout
        while os.clock() < deadline do
            local order = scanCurrentOrder()
            if order then return order end
            task.wait(0.2)
        end
        debugWarn("[BARISTA] Order tidak ditemukan")
        return nil
    end 

    local function updateStatus(message)
        pcall(function()
            if AutoBaristaStatusProgress then
                AutoBaristaStatusProgress.Text = "Status: " .. message
            end
        end)
    end

    local function formatBaristaElapsedTime(seconds)
        local hours = math.floor(seconds / 3600)
        local minutes = math.floor((seconds % 3600) / 60)
        local secs = seconds % 60
        return string.format("%02d:%02d:%02d", hours, minutes, secs)
    end

    local function selectCurrentFlavour()
        local flavourName = currentOrder and currentOrder.Flavour
        debugPrint("[BARISTA] Flavour:", flavourName or "-")

        if not flavourName or flavourName == "" then
            debugWarn("[BARISTA] Flavour tidak ditemukan di currentOrder")
            return false
        end

        local choicePicker = playerGui and playerGui:FindFirstChild("Job") and playerGui.Job:FindFirstChild("ChoicePicker")
        local flavourGrid = choicePicker and choicePicker:FindFirstChild("Grid")
        
        local flavourButton = nil
        if flavourGrid then
            flavourButton = flavourGrid:FindFirstChild(flavourName)
            if not flavourButton then
                for _, btn in ipairs(flavourGrid:GetChildren()) do
                    if btn.Name:lower() == flavourName:lower() or btn.Name:find(flavourName) then
                        flavourButton = btn
                        break
                    end
                end
            end
        end

        if flavourButton then
            debugPrint("[BARISTA] Select Flavour:", flavourButton.Name)
            clickGuiButton(flavourButton)
            task.wait(1)
            return true
        else
            debugWarn("[BARISTA] Flavour button tidak ditemukan:", flavourName)
            return false
        end
    end
    
    local function doKopiHitam()

        -- Teleport ke BeanHopper
        updateStatus("Getting Coffee Beans...")
        smartTeleportTo(CFrame.new(-27.46021270751953, 24.607194900512695, 8416.7197265625))
        task.wait(1)

        -- Fire Prompt BeanHopper
        local BeanHopper = workspace.Barista.Stations.BeanHopper.BaristaStationPrompt
        firePrompt(BeanHopper)
        task.wait(1)

        -- Fire Prompt Brewer
        updateStatus("Loading Beans into Brewer...")
        local Brewer = workspace.Barista.Stations.Brewer.BaristaStationPrompt
        firePrompt(Brewer)
        task.wait(0.2)

        -- Brew Mini Game
        updateStatus("Brewing Coffee...")
        local brewSuccess = runAutoBrew()
        if not brewSuccess then
            updateStatus("Brewing Failed!")
            debugWarn("[BARISTA] Brew gagal")
            return false
        end
        task.wait(1)

        return true

    end

    local function doCappuccino()

        -- Teleport ke BeanHopper
        updateStatus("Getting Coffee Beans...")
        smartTeleportTo(CFrame.new(-27.46021270751953, 24.607194900512695, 8416.7197265625))
        task.wait(1)

        -- Fire Prompt BeanHopper
        local BeanHopper = workspace.Barista.Stations.BeanHopper.BaristaStationPrompt
        firePrompt(BeanHopper)
        task.wait(1)

        -- Fire Prompt Brewer
        updateStatus("Loading Beans into Brewer...")
        local Brewer = workspace.Barista.Stations.Brewer.BaristaStationPrompt
        firePrompt(Brewer)
        task.wait(0.2)

        -- Brew Mini Game
        updateStatus("Brewing Coffee...")
        local brewSuccess = runAutoBrew()
        if not brewSuccess then
            updateStatus("Brewing Failed!")
            debugWarn("[BARISTA] Brew gagal")
            return false
        end
        task.wait(1)

        -- Teleport ke Milk
        updateStatus("Getting Milk...")
        smartTeleportTo(CFrame.new(-13.959260940551758, 24.011192321777344, 8427.1953125))
        task.wait(1)

        -- Fire Prompt Milk
        local Milk = workspace.Barista.Stations.Milk.BaristaStationPrompt
        firePrompt(Milk)
        task.wait(1)

        -- Teleport ke FlavourBottle
        updateStatus("Getting Flavour...")
        smartTeleportTo(CFrame.new(-25.904417037963867, 24.565404891967773, 8441.203125))
        task.wait(1)

        -- Fire Prompt FlavourBottle
        local FlavourBottle = workspace.Barista.Stations.FlavourBottle.BaristaStationPrompt
        firePrompt(FlavourBottle)
        task.wait(1)

        -- Pilih Flavour sesuai pesanan
        updateStatus("Selecting Flavour...")
        if not selectCurrentFlavour() then
            updateStatus("Failed to Select Flavour!")
            return false
        end
        task.wait(1)

        -- Teleport ke Steamer
        updateStatus("Steaming Milk...")
        smartTeleportTo(CFrame.new(-23.854318618774414, 24.607194900512695, 8413.7763671875))
        task.wait(1)

        -- Fire Prompt Steamer
        local Steamer = workspace.Barista.Stations.Steamer.BaristaStationPrompt
        firePrompt(Steamer)
        task.wait(1)

        return true

    end

    local function doEsKopiSusu()

        -- Teleport ke BeanHopper
        updateStatus("Getting Coffee Beans...")
        smartTeleportTo(CFrame.new(-27.46021270751953, 24.607194900512695, 8416.7197265625))
        task.wait(1)

        -- Fire Prompt BeanHopper
        local BeanHopper = workspace.Barista.Stations.BeanHopper.BaristaStationPrompt
        firePrompt(BeanHopper)
        task.wait(1)

        -- Fire Prompt Brewer
        updateStatus("Loading Beans into Brewer...")
        local Brewer = workspace.Barista.Stations.Brewer.BaristaStationPrompt
        firePrompt(Brewer)
        task.wait(0.2)

        -- Brew Mini Game
        updateStatus("Brewing Coffee...")
        local brewSuccess = runAutoBrew()
        if not brewSuccess then
            updateStatus("Brewing Failed!")
            debugWarn("[BARISTA] Brew gagal")
            return false
        end
        task.wait(1)

        -- Teleport ke Milk
        updateStatus("Getting Milk...")
        smartTeleportTo(CFrame.new(-13.959260940551758, 24.011192321777344, 8427.1953125))
        task.wait(1)

        -- Fire Prompt Milk
        local Milk = workspace.Barista.Stations.Milk.BaristaStationPrompt
        firePrompt(Milk)
        task.wait(1)

        -- Teleport ke FlavourBottle
        updateStatus("Getting Flavour...")
        smartTeleportTo(CFrame.new(-25.904417037963867, 24.565404891967773, 8441.203125))
        task.wait(1)

        -- Fire Prompt FlavourBottle
        local FlavourBottle = workspace.Barista.Stations.FlavourBottle.BaristaStationPrompt
        firePrompt(FlavourBottle)
        task.wait(1)

        -- Pilih Flavour sesuai pesanan
        updateStatus("Selecting Flavour...")
        if not selectCurrentFlavour() then
            updateStatus("Failed to Select Flavour!")
            return false
        end
        task.wait(1)

        -- Teleport ke IceMaker
        updateStatus("Getting Ice Cubes...")
        smartTeleportTo(CFrame.new(-5.728482246398926, 24.632293701171875, 8415.39453125))
        task.wait(1)

        -- Fire Prompt IceMaker
        local IceMaker = workspace.Barista.Stations.IceMaker.BaristaStationPrompt
        firePrompt(IceMaker)
        task.wait(1)

        return true

    end

    local function doAmericano()

        -- Teleport ke BeanHopper
        updateStatus("Getting Coffee Beans...")
        smartTeleportTo(CFrame.new(-27.46021270751953, 24.607194900512695, 8416.7197265625))
        task.wait(1)

        -- Fire Prompt BeanHopper
        local BeanHopper = workspace.Barista.Stations.BeanHopper.BaristaStationPrompt
        firePrompt(BeanHopper)
        task.wait(1)

        -- Fire Prompt Brewer
        updateStatus("Loading Beans into Brewer...")
        local Brewer = workspace.Barista.Stations.Brewer.BaristaStationPrompt
        firePrompt(Brewer)
        task.wait(0.2)

        -- Brew Mini Game
        updateStatus("Brewing Coffee...")
        local brewSuccess = runAutoBrew()
        if not brewSuccess then
            updateStatus("Brewing Failed!")
            debugWarn("[BARISTA] Brew gagal")
            return false
        end
        task.wait(1)

        -- Teleport ke WaterTap
        updateStatus("Filling Water...")
        smartTeleportTo(CFrame.new(-41.08833312988281, 23.017559051513672, 8436.4150390625))
        task.wait(1)

        -- Fire Prompt WaterTap
        local WaterTap = workspace.Barista.Stations.WaterTap.BaristaStationPrompt
        firePrompt(WaterTap)
        task.wait(1)

        return true

    end

    local function doLatte()

        -- Teleport ke BeanHopper
        updateStatus("Getting Coffee Beans...")
        smartTeleportTo(CFrame.new(-27.46021270751953, 24.607194900512695, 8416.7197265625))
        task.wait(1)

        -- Fire Prompt BeanHopper
        local BeanHopper = workspace.Barista.Stations.BeanHopper.BaristaStationPrompt
        firePrompt(BeanHopper)
        task.wait(1)

        -- Fire Prompt Brewer
        updateStatus("Loading Beans into Brewer...")
        local Brewer = workspace.Barista.Stations.Brewer.BaristaStationPrompt
        firePrompt(Brewer)
        task.wait(0.2)

        -- Brew Mini Game
        updateStatus("Brewing Coffee...")
        local brewSuccess = runAutoBrew()
        if not brewSuccess then
            updateStatus("Brewing Failed!")
            debugWarn("[BARISTA] Brew gagal")
            return false
        end
        task.wait(1)

        -- Teleport ke Milk
        updateStatus("Getting Milk...")
        smartTeleportTo(CFrame.new(-13.959260940551758, 24.011192321777344, 8427.1953125))
        task.wait(1)

        -- Fire Prompt Milk
        local Milk = workspace.Barista.Stations.Milk.BaristaStationPrompt
        firePrompt(Milk)
        task.wait(1)

        return true

    end

    local function doHotChocolate()

        -- Teleport ke Milk
        updateStatus("Getting Milk...")
        smartTeleportTo(CFrame.new(-13.959260940551758, 24.011192321777344, 8427.1953125))
        task.wait(1)

        -- Fire Prompt Milk
        local Milk = workspace.Barista.Stations.Milk.BaristaStationPrompt
        firePrompt(Milk)
        task.wait(1)

        -- Teleport ke ChocolateJar
        updateStatus("Getting Chocolate...")
        smartTeleportTo(CFrame.new(-20.886396408081055, 24.565404891967773, 8436.17578125))
        task.wait(1)

        -- Fire Prompt ChocolateJar
        local ChocolateJar = workspace.Barista.Stations.ChocolateJar.BaristaStationPrompt
        firePrompt(ChocolateJar)
        task.wait(1)

        return true

    end

    local function doMocha()

        -- Teleport ke BeanHopper
        updateStatus("Getting Coffee Beans...")
        smartTeleportTo(CFrame.new(-27.46021270751953, 24.607194900512695, 8416.7197265625))
        task.wait(1)

        -- Fire Prompt BeanHopper
        local BeanHopper = workspace.Barista.Stations.BeanHopper.BaristaStationPrompt
        firePrompt(BeanHopper)
        task.wait(1)

        -- Fire Prompt Brewer
        updateStatus("Loading Beans into Brewer...")
        local Brewer = workspace.Barista.Stations.Brewer.BaristaStationPrompt
        firePrompt(Brewer)
        task.wait(0.2)

        -- Brew Mini Game
        updateStatus("Brewing Coffee...")
        local brewSuccess = runAutoBrew()
        if not brewSuccess then
            updateStatus("Brewing Failed!")
            debugWarn("[BARISTA] Brew gagal")
            return false
        end
        task.wait(1)

        -- Teleport ke Milk
        updateStatus("Getting Milk...")
        smartTeleportTo(CFrame.new(-13.959260940551758, 24.011192321777344, 8427.1953125))
        task.wait(1)

        -- Fire Prompt Milk
        local Milk = workspace.Barista.Stations.Milk.BaristaStationPrompt
        firePrompt(Milk)
        task.wait(1)

        -- Teleport ke ChocolateJar
        updateStatus("Getting Chocolate...")
        smartTeleportTo(CFrame.new(-20.886396408081055, 24.565404891967773, 8436.17578125))
        task.wait(1)

        -- Fire Prompt ChocolateJar
        local ChocolateJar = workspace.Barista.Stations.ChocolateJar.BaristaStationPrompt
        firePrompt(ChocolateJar)
        task.wait(1)

        return true

    end

    local function doMacchiato()

        -- Teleport ke BeanHopper
        updateStatus("Getting Coffee Beans...")
        smartTeleportTo(CFrame.new(-27.46021270751953, 24.607194900512695, 8416.7197265625))
        task.wait(1)

        -- Fire Prompt BeanHopper
        local BeanHopper = workspace.Barista.Stations.BeanHopper.BaristaStationPrompt
        firePrompt(BeanHopper)
        task.wait(1)

        -- Fire Prompt Brewer
        updateStatus("Loading Beans into Brewer...")
        local Brewer = workspace.Barista.Stations.Brewer.BaristaStationPrompt
        firePrompt(Brewer)
        task.wait(0.2)

        -- Brew Mini Game
        updateStatus("Brewing Coffee...")
        local brewSuccess = runAutoBrew()
        if not brewSuccess then
            updateStatus("Brewing Failed!")
            debugWarn("[BARISTA] Brew gagal")
            return false
        end
        task.wait(1)

        -- Teleport ke Steamer
        updateStatus("Steaming Milk...")
        smartTeleportTo(CFrame.new(-23.854318618774414, 24.607194900512695, 8413.7763671875))
        task.wait(1)

        -- Fire Prompt Steamer
        local Steamer = workspace.Barista.Stations.Steamer.BaristaStationPrompt
        firePrompt(Steamer)
        task.wait(1)

        return true

    end

    local function doFrappuccino()

        -- Teleport ke BeanHopper
        updateStatus("Getting Coffee Beans...")
        smartTeleportTo(CFrame.new(-27.46021270751953, 24.607194900512695, 8416.7197265625))
        task.wait(1)

        -- Fire Prompt BeanHopper
        local BeanHopper = workspace.Barista.Stations.BeanHopper.BaristaStationPrompt
        firePrompt(BeanHopper)
        task.wait(1)

        -- Fire Prompt Brewer
        updateStatus("Loading Beans into Brewer...")
        local Brewer = workspace.Barista.Stations.Brewer.BaristaStationPrompt
        firePrompt(Brewer)
        task.wait(0.2)

        -- Brew Mini Game
        updateStatus("Brewing Coffee...")
        local brewSuccess = runAutoBrew()
        if not brewSuccess then
            updateStatus("Brewing Failed!")
            debugWarn("[BARISTA] Brew gagal")
            return false
        end
        task.wait(1)

        -- Teleport ke Milk
        updateStatus("Getting Milk...")
        smartTeleportTo(CFrame.new(-13.959260940551758, 24.011192321777344, 8427.1953125))
        task.wait(1)

        -- Fire Prompt Milk
        local Milk = workspace.Barista.Stations.Milk.BaristaStationPrompt
        firePrompt(Milk)
        task.wait(1)

        -- Teleport ke CreamDispenser
        updateStatus("Adding Whipped Cream...")
        smartTeleportTo(CFrame.new(-34.13874053955078, 24.565404891967773, 8443.1826171875))
        task.wait(1)

        -- Fire Prompt CreamDispenser
        local CreamDispenser = workspace.Barista.Stations.CreamDispenser.BaristaStationPrompt
        firePrompt(CreamDispenser)
        task.wait(1)

        -- Teleport ke IceMaker
        updateStatus("Getting Ice Cubes...")
        smartTeleportTo(CFrame.new(-5.728482246398926, 24.632293701171875, 8415.39453125))
        task.wait(1)

        -- Fire Prompt IceMaker
        local IceMaker = workspace.Barista.Stations.IceMaker.BaristaStationPrompt
        firePrompt(IceMaker)
        task.wait(1)

        return true

    end

    local function doTea()

        -- Teleport ke WaterTap
        updateStatus("Filling Hot Water...")
        smartTeleportTo(CFrame.new(-41.08833312988281, 23.017559051513672, 8436.4150390625))
        task.wait(1)

        -- Fire Prompt WaterTap
        local WaterTap = workspace.Barista.Stations.WaterTap.BaristaStationPrompt
        firePrompt(WaterTap)
        task.wait(1)

        -- Teleport ke TeaBox
        updateStatus("Getting Tea Bag...")
        smartTeleportTo(CFrame.new(-16.10846519470215, 24.565404891967773, 8431.048828125))
        task.wait(1)

        -- Fire Prompt TeaBox
        local TeaBox = workspace.Barista.Stations.TeaBox.BaristaStationPrompt
        firePrompt(TeaBox)
        task.wait(1)

        return true

    end

    local function doThaiTea()

        -- Teleport ke WaterTap
        updateStatus("Filling Hot Water...")
        smartTeleportTo(CFrame.new(-41.08833312988281, 23.017559051513672, 8436.4150390625))
        task.wait(1)

        -- Fire Prompt WaterTap
        local WaterTap = workspace.Barista.Stations.WaterTap.BaristaStationPrompt
        firePrompt(WaterTap)
        task.wait(1)

        -- Teleport ke TeaBox
        updateStatus("Getting Tea Bag...")
        smartTeleportTo(CFrame.new(-16.10846519470215, 24.565404891967773, 8431.048828125))
        task.wait(1)

        -- Fire Prompt TeaBox
        local TeaBox = workspace.Barista.Stations.TeaBox.BaristaStationPrompt
        firePrompt(TeaBox)
        task.wait(1)

        -- Teleport ke Milk
        updateStatus("Getting Milk...")
        smartTeleportTo(CFrame.new(-13.959260940551758, 24.011192321777344, 8427.1953125))
        task.wait(1)

        -- Fire Prompt Milk
        local Milk = workspace.Barista.Stations.Milk.BaristaStationPrompt
        firePrompt(Milk)
        task.wait(1)

        -- Teleport ke IceMaker
        updateStatus("Getting Ice Cubes...")
        smartTeleportTo(CFrame.new(-5.728482246398926, 24.632293701171875, 8415.39453125))
        task.wait(1)

        -- Fire Prompt IceMaker
        local IceMaker = workspace.Barista.Stations.IceMaker.BaristaStationPrompt
        firePrompt(IceMaker)
        task.wait(1)

        return true

    end

    local function doMatcha()

        -- Teleport ke WaterTap
        updateStatus("Filling Water...")
        smartTeleportTo(CFrame.new(-41.08833312988281, 23.017559051513672, 8436.4150390625))
        task.wait(1)

        -- Fire Prompt WaterTap
        local WaterTap = workspace.Barista.Stations.WaterTap.BaristaStationPrompt
        firePrompt(WaterTap)
        task.wait(1)

        -- Teleport ke MatchaJar
        updateStatus("Getting Matcha Powder...")
        smartTeleportTo(CFrame.new(-18.60329246520996, 24.565404891967773, 8433.6748046875))
        task.wait(1)

        -- Fire Prompt MatchaJar
        local MatchaJar = workspace.Barista.Stations.MatchaJar.BaristaStationPrompt
        firePrompt(MatchaJar)
        task.wait(1)

        -- Teleport ke Milk
        updateStatus("Getting Milk...")
        smartTeleportTo(CFrame.new(-13.959260940551758, 24.011192321777344, 8427.1953125))
        task.wait(1)

        -- Fire Prompt Milk
        local Milk = workspace.Barista.Stations.Milk.BaristaStationPrompt
        firePrompt(Milk)
        task.wait(1)

        return true

    end

    local function doBubbleTea()

        -- Teleport ke WaterTap
        updateStatus("Filling Water...")
        smartTeleportTo(CFrame.new(-41.08833312988281, 23.017559051513672, 8436.4150390625))
        task.wait(1)

        -- Fire Prompt WaterTap
        local WaterTap = workspace.Barista.Stations.WaterTap.BaristaStationPrompt
        firePrompt(WaterTap)
        task.wait(1)

        -- Teleport ke TeaBox
        updateStatus("Getting Tea Bag...")
        smartTeleportTo(CFrame.new(-16.10846519470215, 24.565404891967773, 8431.048828125))
        task.wait(1)

        -- Fire Prompt TeaBox
        local TeaBox = workspace.Barista.Stations.TeaBox.BaristaStationPrompt
        firePrompt(TeaBox)
        task.wait(1)

        -- Teleport ke Milk
        updateStatus("Getting Milk...")
        smartTeleportTo(CFrame.new(-13.959260940551758, 24.011192321777344, 8427.1953125))
        task.wait(1)

        -- Fire Prompt Milk
        local Milk = workspace.Barista.Stations.Milk.BaristaStationPrompt
        firePrompt(Milk)
        task.wait(1)

        -- Teleport ke BobaPot
        updateStatus("Adding Boba...")
        smartTeleportTo(CFrame.new(-23.343908309936523, 24.565404891967773, 8438.5400390625))
        task.wait(1)

        -- Fire Prompt BobaPot
        local BobaPot = workspace.Barista.Stations.BobaPot.BaristaStationPrompt
        firePrompt(BobaPot)
        task.wait(1)

        -- Teleport ke IceMaker
        updateStatus("Getting Ice Cubes...")
        smartTeleportTo(CFrame.new(-5.728482246398926, 24.632293701171875, 8415.39453125))
        task.wait(1)

        -- Fire Prompt IceMaker
        local IceMaker = workspace.Barista.Stations.IceMaker.BaristaStationPrompt
        firePrompt(IceMaker)
        task.wait(1)

        return true

    end

    local function doSoda()

        -- Teleport ke WaterTap
        updateStatus("Filling Water...")
        smartTeleportTo(CFrame.new(-41.08833312988281, 23.017559051513672, 8436.4150390625))
        task.wait(1)

        -- Fire Prompt WaterTap
        local WaterTap = workspace.Barista.Stations.WaterTap.BaristaStationPrompt
        firePrompt(WaterTap)
        task.wait(1)

        -- Teleport ke Carbonator
        updateStatus("Adding Carbonated Water...")
        smartTeleportTo(CFrame.new(-36.2972526550293, 24.565404891967773, 8441.0244140625))
        task.wait(1)

        -- Fire Prompt Carbonator
        local Carbonator = workspace.Barista.Stations.Carbonator.BaristaStationPrompt
        firePrompt(Carbonator)
        task.wait(1)

        -- Teleport ke IceMaker
        updateStatus("Getting Ice Cubes...")
        smartTeleportTo(CFrame.new(-5.728482246398926, 24.632293701171875, 8415.39453125))
        task.wait(1)

        -- Fire Prompt IceMaker
        local IceMaker = workspace.Barista.Stations.IceMaker.BaristaStationPrompt
        firePrompt(IceMaker)
        task.wait(1)

        return true

    end

    local function doLemonade()

        -- Teleport ke WaterTap
        updateStatus("Filling Water...")
        smartTeleportTo(CFrame.new(-41.08833312988281, 23.017559051513672, 8436.4150390625))
        task.wait(1)

        -- Fire Prompt WaterTap
        local WaterTap = workspace.Barista.Stations.WaterTap.BaristaStationPrompt
        firePrompt(WaterTap)
        task.wait(1)

        -- Teleport ke Carbonator
        updateStatus("Adding Carbonated Water...")
        smartTeleportTo(CFrame.new(-36.2972526550293, 24.565404891967773, 8441.0244140625))
        task.wait(1)

        -- Fire Prompt Carbonator
        local Carbonator = workspace.Barista.Stations.Carbonator.BaristaStationPrompt
        firePrompt(Carbonator)
        task.wait(1)

        -- Teleport ke LemonBoard
        updateStatus("Cutting Lemon...")
        smartTeleportTo(CFrame.new(-28.2451171875, 24.565404891967773, 8443.5751953125))
        task.wait(1)

        -- Fire Prompt LemonBoard
        local LemonBoard = workspace.Barista.Stations.LemonBoard.BaristaStationPrompt
        firePrompt(LemonBoard)
        task.wait(1)

        -- Teleport ke IceMaker
        updateStatus("Getting Ice Cubes...")
        smartTeleportTo(CFrame.new(-5.728482246398926, 24.632293701171875, 8415.39453125))
        task.wait(1)

        -- Fire Prompt IceMaker
        local IceMaker = workspace.Barista.Stations.IceMaker.BaristaStationPrompt
        firePrompt(IceMaker)
        task.wait(1)

        return true

    end

    local function runAutoBarista()

        -- =========================================
        -- 1. TELEPORT KE KASIR UNTUK AMBIL ORDER
        -- =========================================
        updateStatus("Moving to Cashier...")
        debugPrint("[BARISTA] Going to cashier")
        local cashierCFrame = CFrame.new(-32.88235092163086, 23.811004638671875, 8422.7119140625)
        smartTeleportTo(cashierCFrame)
        task.wait(1)

        -- =========================================
        -- 2. TALK DENGAN CUSTOMER (Mencari yang terdekat)
        -- =========================================
        updateStatus("Waiting for Customer...")
        debugPrint("[BARISTA] Talking to customer")
        local customers = workspace:FindFirstChild("BaristaCustomers")
        local cashierPosition = cashierCFrame.Position
        local startTime = os.clock()
        local servePrompt = nil
        local currentCustomer = nil

        while not servePrompt and os.clock() - startTime < 30 do
            if customers then
                local closestDistance = 6 -- Radius maksimum toleransi (studs)
                
                for _, customer in ipairs(customers:GetChildren()) do
                    local hrp = customer:FindFirstChild("HumanoidRootPart")
                    if hrp then
                        local prompt = hrp:FindFirstChild("BaristaServePrompt")
                        if prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled then
                            local distance = (hrp.Position - cashierPosition).Magnitude
                            if distance <= closestDistance then
                                closestDistance = distance
                                servePrompt = prompt
                                currentCustomer = customer
                            end
                        end
                    end
                end
            end

            if not servePrompt then
                task.wait(0.2)
            end
        end

        if servePrompt then
            updateStatus("Talking to Customer...")
            debugPrint("[BARISTA] Customer arrived:", servePrompt:GetFullName())
            firePrompt(servePrompt)
        else
            updateStatus("Customer Not Found!")
            debugWarn("[BARISTA] Customer tidak sampai ke kasir dalam 30 detik")
            return
        end
        task.wait(1)

        -- =========================================
        -- 3. TUNGGU ORDER MUNCUL & BUKA CUP RACK
        -- =========================================
        updateStatus("Receiving Order...")
        debugPrint("[BARISTA] Waiting order")

        currentOrder = nil

        local order = waitForCurrentOrder(10)
        if not order then
            updateStatus("Order Not Found!")
            debugWarn("[BARISTA] Order tidak ditemukan")
            return
        end

        debugPrint("[BARISTA] Order:", currentOrder.MenuId)
        debugPrint("[BARISTA] Flavour:", currentOrder.Flavour or "-")

        task.wait(1)
        pressSpaceKey(1, 0.5)
        task.wait(1)

        -- Teleport ke CupRack
        updateStatus("Getting Cup...")
        smartTeleportTo(CFrame.new(-11.643688201904297, 24.607194900512695, 8409.1103515625))
        task.wait(1)

        -- Open CupRack & Tunggu UI Terbuka
        game:GetService("ReplicatedStorage"):WaitForChild("NetworkContainer"):WaitForChild("RemoteEvents"):WaitForChild("Barista"):FireServer("Station", "CupRack")
        
        local choicePicker = playerGui:WaitForChild("Job", 5):WaitForChild("ChoicePicker", 5)
        task.wait(1)

        -- Select Cup (Sesuai Pesanan dengan Fallback Case-Insensitive)
        local menuName = currentOrder and currentOrder.MenuId
        debugPrint("[BARISTA] Target Cup:", menuName or "-")
        
        if not menuName or menuName == "" then
            updateStatus("Invalid Menu!")
            debugWarn("[BARISTA] MenuId tidak ditemukan di currentOrder")
            return
        end

        local cupGrid = choicePicker and choicePicker:WaitForChild("Grid", 5)
        local cupButton = nil

        if cupGrid then
            cupButton = cupGrid:FindFirstChild(menuName)
            if not cupButton then
                -- Fallback jika ada perbedaan huruf besar/kecil
                for _, btn in ipairs(cupGrid:GetChildren()) do
                    if btn.Name:lower() == menuName:lower() or btn.Name:find(menuName) then
                        cupButton = btn
                        break
                    end
                end
            end
        end

        if cupButton then
            debugPrint("[BARISTA] Select Cup Success:", cupButton.Name)
            clickGuiButton(cupButton)
        else
            updateStatus("Cup Button Not Found: " .. tostring(menuName))
            debugWarn("[BARISTA] Cup button tidak ditemukan untuk menu:", menuName)
            
            -- Print semua nama tombol yang ada untuk debugging F9
            if cupGrid then
                for _, child in ipairs(cupGrid:GetChildren()) do
                    debugPrint("[BARISTA GRID ITEM]:", child.Name)
                end
            end
            task.wait(2)
            return
        end
        task.wait(1)

        -- =========================================
        -- 4. PILIH MENU
        -- =========================================
        updateStatus("Making: " .. currentOrder.MenuId)

        local drinkSuccess = false

        if currentOrder.MenuId == "KopiHitam" then
            drinkSuccess = doKopiHitam()
        elseif currentOrder.MenuId == "Cappuccino" then
            drinkSuccess = doCappuccino()
        elseif currentOrder.MenuId == "EsKopiSusu" then
            drinkSuccess = doEsKopiSusu()
        elseif currentOrder.MenuId == "Americano" then
            drinkSuccess = doAmericano()
        elseif currentOrder.MenuId == "Latte" then
            drinkSuccess = doLatte()
        elseif currentOrder.MenuId == "HotChocolate" then
           drinkSuccess = doHotChocolate()
        elseif currentOrder.MenuId == "Mocha" then
            drinkSuccess = doMocha()
        elseif currentOrder.MenuId == "Macchiato" then
            drinkSuccess = doMacchiato()
        elseif currentOrder.MenuId == "Frappuccino" then
            drinkSuccess = doFrappuccino()
        elseif currentOrder.MenuId == "Tea" then
            drinkSuccess = doTea()
        elseif currentOrder.MenuId == "ThaiTea" then
            drinkSuccess = doThaiTea()
        elseif currentOrder.MenuId == "Matcha" then
            drinkSuccess = doMatcha()
        elseif currentOrder.MenuId == "BubbleTea" then
            drinkSuccess = doBubbleTea()
        elseif currentOrder.MenuId == "Soda" then
            drinkSuccess = doSoda()
        elseif currentOrder.MenuId == "Lemonade" then
            drinkSuccess = doLemonade()
        else
            debugWarn("[BARISTA] Menu tidak didukung:", currentOrder.MenuId)
            return
        end

        if not drinkSuccess then
            updateStatus("Drink Preparation Failed!")
            debugWarn("[BARISTA] Pembuatan minuman gagal")
            return
        end

        -- =========================================
        -- 5. KEMBALI KE KASIR UNTUK SERVE
        -- =========================================
        updateStatus("Returning to Cashier...")
        debugPrint("[BARISTA] Waiting customer")

        local cashierCFrame = CFrame.new(-32.88235092163086, 23.811004638671875, 8422.7119140625)
        smartTeleportTo(cashierCFrame)
        task.wait(1)

        -- Validasi awal: Apakah customer masih ada di workspace?
        if not (currentCustomer and currentCustomer.Parent) then
            updateStatus("Customer Disappeared!")
            debugWarn("[BARISTA] Customer sudah tidak ada/despawn sebelum dilayani!")
            return
        end

        local startTime = os.clock()
        local servePrompt = nil

        updateStatus("Waiting Customer at Cashier...")
        while not servePrompt and os.clock() - startTime < 30 do
            -- Cek ulang apakah customer masih ada
            if not (currentCustomer and currentCustomer.Parent) then
                debugWarn("[BARISTA] Customer hilang/despawn saat ditunggu!")
                break
            end

            local hrp = currentCustomer:FindFirstChild("HumanoidRootPart")
            if hrp then
                -- Naikkan batas toleransi jarak ke 15 studs
                local distance = (hrp.Position - cashierCFrame.Position).Magnitude
                debugPrint("[BARISTA] Customer:", currentCustomer.Name, "Distance:", math.floor(distance * 100) / 100)
                
                if distance <= 6 then
                    -- Cari prompt (walau Enabled masih false, tunggu sejenak)
                    local prompt = hrp:FindFirstChild("BaristaServePrompt")
                    if prompt and prompt:IsA("ProximityPrompt") then
                        if prompt.Enabled then
                            servePrompt = prompt
                        else
                            debugPrint("[BARISTA] Prompt ditemukan tapi belum Enabled, menunggu...")
                        end
                    end
                end
            end

            if not servePrompt then
                task.wait(0.2)
            end
        end

        -- Serve Order
        if servePrompt then
            updateStatus("Serving Order...")
            debugPrint("[BARISTA] Serving:", currentCustomer.Name)
            
            -- Eksekusi prompt
            firePrompt(servePrompt)
            task.wait(0.5)

            -- Update statistik & UI
            ordersCompletedCount = ordersCompletedCount + 1

            if BaristaOrdersValue then 
                BaristaOrdersValue.Text = tostring(ordersCompletedCount) 
            end

            pcall(function()
                if BaristaMenuValue then BaristaMenuValue.Text = "-" end
                if BaristaFlavourValue then BaristaFlavourValue.Text = "-" end
            end)

            updateStatus("Order Completed!")
        else
            updateStatus("Customer Timeout / Lost!")
            debugWarn("[BARISTA] Customer tidak dapat di-serve dalam 30 detik")
            return
        end
        task.wait(1)

    end

    Connections["BaristaStartButton"] = BaristaStartButton.MouseButton1Click:Connect(function()

        autoBarista = not autoBarista

        if autoBarista then

            BaristaStartButton.Text = "STOP AUTO BARISTA"
            BaristaStartButton.BackgroundColor3 = Color3.fromRGB(180, 30, 60)
            BaristaStatusValue.Text = "● RUNNING"
            BaristaStatusValue.TextColor3 = Color3.fromRGB(0, 235, 145)
            startTime = os.time()

            ToastSystem.Show("success", "Auto Barista Started!")

            updateStatus("Starting Auto Barista...")

            -- only be used in Private Server
            if #Players:GetChildren() > 1 then
                LocalPlayer:Kick("[NEX-KICK] Used on a Private Server!")
                return false
            end

            -- only be used in Jakarta
            if game.PlaceId ~= 14005966837 then
                LocalPlayer:Kick("[NEX-KICK] Used in Jakarta!")
                return false
            end

            -- Loop Timer Elapsed & UI Status Update
            task.spawn(function()
                while autoBarista do
                    local elapsed = os.time() - startTime
                    BaristaElapsedValue.Text = formatBaristaElapsedTime(elapsed)
                    task.wait(1)
                end
            end)

            -- Apply FPS Booster
            pcall(function()
                originalQualityLevel = settings().Rendering.QualityLevel
                settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
                for _, obj in ipairs(workspace:GetDescendants()) do
                    if obj:IsA("BasePart") then
                        if not originalMaterials[obj] then
                            originalMaterials[obj] = obj.Material
                            originalShadows[obj] = obj.CastShadow
                        end
                        obj.Material = Enum.Material.SmoothPlastic
                        obj.CastShadow = false
                    elseif obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Smoke") or obj:IsA("Fire") then
                        obj.Enabled = false
                    elseif obj:IsA("PostEffect") then
                        obj.Enabled = false
                    end
                end
                debugPrint("FPS Booster Activated!")
            end)

            -- Step Starter -> Teleport To Npc Barista Manager
            updateStatus("Going to Barista Manager...")
            for i = 1, 5 do
                smartTeleportTo("NPC_BARISTA_MANAGER")
                task.wait(0.2)
            end
            task.wait(1)

            -- Step Starter -> Talk With Npc Barista Manager
            updateStatus("Starting Job Process...")
            local startTime = os.clock()
            while os.clock() - startTime < 1 do
                local NPC_BARISTA_MANAGER = workspace.Barista.NPC_BARISTA_MANAGER.Head.DialogPrompt
                firePrompt(NPC_BARISTA_MANAGER)
                task.wait(0.5)
            end
            pressSpaceKey(5, 0.2)
            task.wait(1)

            -- Loop Eksekusi Main Auto Barista CDID
            task.spawn(function()
                while autoBarista do
                    runAutoBarista()
                    task.wait(0.1)
                end
            end)

        else

            BaristaStartButton.Text = "START AUTO BARISTA"
            BaristaStartButton.BackgroundColor3 = Color3.fromRGB(10, 28, 65)
            BaristaStatusValue.Text = "● STOPPED"
            BaristaStatusValue.TextColor3 = Color3.fromRGB(255, 80, 90)
            debugPrint("Auto Barista Stopped - Killing character and cleaning up...")

            updateStatus("Stopped")

            pcall(function()
                if BaristaMenuValue then BaristaMenuValue.Text = "-" end
                if BaristaFlavourValue then BaristaFlavourValue.Text = "-" end
            end)

            -- Restore Graphic
            pcall(function()
                settings().Rendering.QualityLevel = originalQualityLevel
                for obj, mat in pairs(originalMaterials) do
                    if obj and obj.Parent then
                        obj.Material = mat
                        if originalShadows[obj] ~= nil then
                            obj.CastShadow = originalShadows[obj]
                        end
                    end
                end
                table.clear(originalMaterials)
                table.clear(originalShadows)

                for _, obj in ipairs(workspace:GetDescendants()) do
                    if obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Smoke") or obj:IsA("Fire") then
                        obj.Enabled = true
                    elseif obj:IsA("PostEffect") then
                        obj.Enabled = true
                    end
                end
                debugPrint("Graphics Restored to Original!")

            end)
            
            -- Kill Character
            pcall(function()
                local character = LocalPlayer.Character
                if character then
                    local humanoid = character:FindFirstChildOfClass("Humanoid")
                    if humanoid then 
                        humanoid.Health = 0 
                    end
                    character:BreakJoints()
                end
            end)
            
        end
        
    end)

    -- =========================================================
    -- FOOTER
    -- =========================================================
    local Footer = Instance.new("TextLabel")
    Footer.AnchorPoint = Vector2.new(0.5, 1)
    Footer.Position = UDim2.new(0.5, 0, 1, 0)
    Footer.Size = UDim2.new(1, -40, 0, 20)
    Footer.BackgroundTransparency = 1
    Footer.Text = "N E X O V A   H U B   //   U N L E A S H   Y O U R   P O W E R"
    Footer.TextColor3 = Color3.fromRGB(125, 135, 160)
    Footer.TextSize = 9
    Footer.Font = Enum.Font.Gotham
    Footer.Parent = Body

    -- =========================================================
    -- DISCORD LOGIC
    -- =========================================================
    Connections["DiscordButton"] = DiscordButton.MouseButton1Click:Connect(function()
        if setclipboard then
            setclipboard("https://discord.gg/KeNubYZzeB")
            DiscordButton.Text = "✓ COPIED!"
            ToastSystem.Show("success", "The Nexova Hub Discord link has been successfully copied!")
            task.wait(2)
            DiscordButton.Text = "👾   DISCORD"
        else
            debugPrint("Link Discord: " .. "https://discord.gg/KeNubYZzeB")
        end
    end)

    -- =========================================================
    -- NAVIGATION LOGIC (WITH MULTI-PLAN SUPPORT, TOAST & SMOOTH TRANSITION)
    -- =========================================================    
    local TweenService = game:GetService("TweenService")

    -- Map nama target ke instance Page
    local PAGES = {
        ["Home"] = HomePage,
        ["Barista"] = BaristaPage
    }

    -- Penampung tween yang sedang berjalan agar tidak tumpah tindih saat diklik cepat
    local activeTweens = {}
    local activePageName = nil

    -- 1. Daftar Plan yang diizinkan untuk setiap Halaman / Tab
    local PAGE_REQUIREMENTS = {
        ["Home"]    = "NEX-PULSE",
        ["Barista"] = "NEX-PULSE",
    }

    local function setActiveNavigation(targetName)
        if activePageName == targetName then return true end

        -- 2. Ambil daftar Plan yang diizinkan
        local reqPlans = PAGE_REQUIREMENTS[targetName] or {"NEX-FREE"}
        local currentPlan = AuthState.plan_license or "NEX-FREE"

        if type(reqPlans) == "string" then
            reqPlans = {reqPlans}
        end

        -- Pengecekan Akses Plan User
        local hasAccess = false

        if PlanSystem and PlanSystem.TIERS then
            local currentTier = PlanSystem.TIERS[currentPlan] or 1
            for _, planCode in ipairs(reqPlans) do
                local reqTier = PlanSystem.TIERS[planCode] or 1
                if planCode == "NEX-FREE" or currentPlan == planCode or currentTier >= reqTier then
                    hasAccess = true
                    break
                end
            end
        else
            hasAccess = true
        end

        -- Jika Akses Ditolak
        if not hasAccess then
            local reqPlansStr = table.concat(reqPlans, " / ")
            debugWarn("Access Denied to Tab [" .. tostring(targetName) .. "]! Required Plan: " .. reqPlansStr)
            
            if ToastSystem and ToastSystem.Show then
                ToastSystem.Show(
                    "error", 
                    "Tab [" .. tostring(targetName) .. "] requires plan: " .. reqPlansStr .. "!"
                )
            end

            -- Efek Tombol Berkedip Merah
            local navData = navButtons[targetName]
            if navData and navData.button then
                local origBgColor = navData.button.BackgroundColor3
                navData.button.BackgroundColor3 = Color3.fromRGB(180, 40, 50)
                navData.button.BackgroundTransparency = 0.2
                
                task.delay(0.3, function()
                    navData.button.BackgroundColor3 = origBgColor
                    navData.button.BackgroundTransparency = 1
                end)
            end
            
            return false
        end

        -- 3. Update Visual Tombol Navigasi
        for navName, data in pairs(navButtons) do
            if navName == targetName then
                data.button.BackgroundTransparency = 0
                data.button.BackgroundColor3 = Color3.fromRGB(10, 28, 65)
                data.icon.TextColor3 = Color3.fromRGB(0, 180, 255)
                data.label.TextColor3 = Color3.fromRGB(235, 240, 250)
                
                local stroke = data.button:FindFirstChildOfClass("UIStroke")
                if not stroke then
                    stroke = Instance.new("UIStroke")
                    stroke.Parent = data.button
                end
                stroke.Color = Color3.fromRGB(175, 50, 255)
                stroke.Transparency = 0.15
            else
                data.button.BackgroundTransparency = 1
                data.icon.TextColor3 = Color3.fromRGB(125, 135, 160)
                data.label.TextColor3 = Color3.fromRGB(195, 202, 220)
                
                local stroke = data.button:FindFirstChildOfClass("UIStroke")
                if stroke then stroke:Destroy() end
            end
        end

        -- 4. ANIMASI TRANSISI VERTICAL CYBER SLIDE (SLIDE UP)
        local oldPageName = activePageName
        activePageName = targetName

        local oldPage = PAGES[oldPageName]
        local newPage = PAGES[targetName]

        -- Hentikan tween lama jika ada
        if oldPage and activeTweens[oldPage] then activeTweens[oldPage]:Cancel() end
        if newPage and activeTweens[newPage] then activeTweens[newPage]:Cancel() end

        -- Sembunyikan SEMUA halaman terlebih dahulu agar tidak menumpuk
        for _, pageFrame in pairs(PAGES) do
            pageFrame.Visible = false
        end

        -- Tampilkan dan animasikan Halaman Baru meluncur dari bawah
        if newPage then
            -- Set posisi awal di agak bawah (Y = 35px)
            newPage.Position = UDim2.new(0, 0, 0, 35)
            newPage.Visible = true

            -- Animasi meluncur ke posisi normal (0, 0)
            local tweenInInfo = TweenInfo.new(0.28, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)
            local tweenIn = TweenService:Create(newPage, tweenInInfo, {
                Position = UDim2.new(0, 0, 0, 0)
            })
            
            activeTweens[newPage] = tweenIn
            tweenIn:Play()
        end

        return true
    end

    -- Event Listener Tombol Navigasi
    for name, data in pairs(navButtons) do
        Connections["Nav_" .. name] = data.button.MouseButton1Click:Connect(function()
            setActiveNavigation(name)
        end)
    end
    
    -- Inisialisasi Halaman Awal (Home)
    setActiveNavigation("Home")

    -- =========================================================
    -- MINIMIZE & CLOSE LOGIC (SUPPORT PC & HP)
    -- =========================================================
    local minimized = false
    MinimizeButton.Active = true
    MinimizedIcon.Active = true
    CloseButton.Active = true

    local function toggleHub()
        minimized = not minimized

        -- Pengaturan durasi & Easing
        local tweenInfoOpen = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
        local tweenInfoClose = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        local tweenInfoButton = TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

        -- Pastikan MinimizedIcon selalu terlihat
        MinimizedIcon.Visible = true

        -- Animasi Umpan Balik Tombol Icon (Efek Membal/Press)
        MinimizedIcon.Size = UDim2.fromOffset(40, 40) -- Mengecil sebentar saat diklik
        TweenService:Create(MinimizedIcon, tweenInfoButton, { Size = UDim2.fromOffset(50, 50) }):Play()

        if minimized then
            
            playEffect("MinimizeHub")

            -- 1. Animasi Menyusut (Minimize Window)
            local closeTween = TweenService:Create(WindowScale, tweenInfoClose, { Scale = 0 })
            closeTween:Play()
            
            closeTween.Completed:Connect(function()
                if minimized then
                    Window.Visible = false
                end
            end)

        else

            playEffect("MinimizeHub")

            -- Hitung ukuran target ideal berdasarkan layar (Touch Device)
            local targetFinalScale = 1.0
            if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
                local minDimension = math.min(workspace.CurrentCamera.ViewportSize.X, workspace.CurrentCamera.ViewportSize.Y)
                local targetScale = (minDimension * 0.85) / 700
                targetFinalScale = math.clamp(targetScale, 0.60, 0.80)
            end

            -- 2. Animasi Membesar & Membal (Open Window)
            WindowScale.Scale = targetFinalScale * 0.5 -- Mulai dari skala kecil
            Window.Visible = true
            
            TweenService:Create(WindowScale, tweenInfoOpen, { Scale = targetFinalScale }):Play()
        end
    end

    -- Menggunakan InputBegan agar aman untuk Mouse (PC) maupun Touch (HP)
    Connections["MinimizeButton"] = MinimizeButton.InputBegan:Connect(function(input)
        if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) and not minimized then
            toggleHub()
        end
    end)

    Connections["MinimizedIcon"] = MinimizedIcon.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            toggleHub()
        end
    end)

    Connections["CloseButton"] = CloseButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            destroyHub("user_closed_hub")
        end
    end)
    
    -- =========================================================
    -- DRAGGING LOGIC
    -- =========================================================
    local dragging = false
    local dragInput, dragStart, startPosition

    Connections["TopBarDragStart"] = TopBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPosition = Window.Position

            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    TopBar.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)

    Connections["WindowDragMove"] = UserInputService.InputChanged:Connect(function(input)
        if dragging and (input == dragInput or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            Window.Position = UDim2.new(
                startPosition.X.Scale,
                startPosition.X.Offset + delta.X,
                startPosition.Y.Scale,
                startPosition.Y.Offset + delta.Y
            )
        end
    end)

    -- =========================================================
    -- OPEN ANIMATION (Saat Script Pertama Kali Dimuat)
    -- =========================================================
    task.spawn(function()
        task.wait(0.5)

        playEffect("WelcomeHub")

        -- 1. Hitung Target Scale Layar
        local finalScale = 1.0
        if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
            local minDimension = math.min(workspace.CurrentCamera.ViewportSize.X, workspace.CurrentCamera.ViewportSize.Y)
            local targetScale = (minDimension * 0.85) / 700
            finalScale = math.clamp(targetScale, 0.60, 0.80)
        end

        -- 2. Setup Easing Info yang Lembut & Membal
        local tweenInfoWindow = TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
        local tweenInfoIcon = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

        -- 3. Prepare Elemen sebelum Tampak
        WindowScale.Scale = finalScale * 0.4 -- Mulai dari ukuran kecil agar efek pop-in terasa jelas
        Window.Visible = true

        MinimizedIcon.Size = UDim2.fromOffset(0, 0) -- Mulai dari nol piksel
        MinimizedIcon.Visible = true

        -- 4. Jalankan Animasi
        -- Window membesar dengan efek membal (overshoot)
        TweenService:Create(WindowScale, tweenInfoWindow, { Scale = finalScale }):Play()

        -- MinimizedIcon menyusul muncul membal sebentar setelahnya
        task.wait(0.1)
        TweenService:Create(MinimizedIcon, tweenInfoIcon, { Size = UDim2.fromOffset(50, 50) }):Play()
    end)

    return ScreenGui    

end

-- =========================================================
-- START
-- =========================================================
task.spawn(function()
    if Config and Config.PUBLISH_MODE then
        if authenticateUser() then
            mainScreen()
        end
    else
        pcall(function() 
            LocalPlayer:Kick("[NEX-KICK] - The script is currently unavailable. Please contact the administrator!") 
        end)
    end
end)