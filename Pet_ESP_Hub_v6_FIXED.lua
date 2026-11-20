-- Pet ESP Hub v8.2 MOBILE + ANY ZONES + REAL GAME REMOTES
-- ZONES: scans ANY folder named "Zones" in Workspace (World1, World2, Hub, Worlds...)
--   Wild pet path: Workspace.<World>.Zones.<Zone>.Spawns.Spawn_<Name>_<n>
-- FIX LIST vs v8:
--   1) Camera is fetched dynamically (no stale CurrentCamera after respawn)
--   2) tapButton: firesignal -> VIM mouse -> guarded touch (SendTouchEvent may not exist)
--   3) findShootButton no longer matches "scope"
--   4) isDowned no longer treats a bare ClickDetector as downed (only catch ProximityPrompt / real state)
--   5) updateFreeToCatch precedence bug fixed + nil-safe
--   6) free-to-catch name match guarded against empty pet name
--   7) auto-aim no longer force-teleports you to the fixed AIM_POS (optional flag)
--   8) scanZonesFast skips nested duplicate models (no double ESP)
--   9) minigame detection broadened, and never taps our own hub buttons
--  10) ESP / Collect / Aim all driven from one clean loop with pcall safety
--
-- v8.2 REAL GAME REMOTES (this is what actually shoots here - there is no Shoot button):
--   Aim : ReplicatedStorage.Remotes.EnterAim:FireServer()
--   Fire: ReplicatedStorage.Remotes.Fire:FireServer(WEAPON, DART, directionUnit)
--   Buy : ReplicatedStorage.Remotes.Buy:InvokeServer("DartsAll", "All")
--   >>> Edit CONFIG.WEAPON_NAME / CONFIG.DART_NAME below to the weapon + dart you use.

print("[PetESP v8.1] ====== LOADED OK - MOBILE + ANY ZONES + CLEAN ESP ======")

local Players      = game:GetService("Players")
local Workspace    = game:GetService("Workspace")
local UserInput    = game:GetService("UserInputService")
local VIM          = game:GetService("VirtualInputManager")
local RunService   = game:GetService("RunService")
local RepStorage   = game:GetService("ReplicatedStorage")
local LocalPlayer  = Players.LocalPlayer
local PlayerGui    = LocalPlayer:WaitForChild("PlayerGui")

local IS_MOBILE = UserInput.TouchEnabled and not UserInput.MouseEnabled
print("[PetESP v8.1] IS_MOBILE = " .. tostring(IS_MOBILE))

local CONFIG = {
    AIM_POS = Vector3.new(5973, 3, 2),
    BASE_POS = Vector3.new(5977, 3, 99),
    BASE_RADIUS = 90,
    BASE_BOX = {X_MIN = 5900, X_MAX = 6050, Z_MIN = 20, Z_MAX = 180},

    ESP_ENABLED   = true,
    AUTO_AIM      = true,
    AUTO_COLLECT  = true,
    MINIGAME      = false,
    LOW_LAG       = false,

    ESP_MODE      = "Nearest",   -- "Nearest" or "Value"
    TOP_N         = 10,
    ESP_MAX_DIST  = 500,
    HIDE_DIST     = 25,
    SCAN_INTERVAL = 2.5,
    ESP_INTERVAL  = 0.3,
    AIM_COOLDOWN  = 1.2,
    COLLECT_COOLDOWN = 1.0,

    -- v8.1 flags
    FORCE_AIM_SPOT = false,          -- true = old fixed-scope behaviour (teleport to AIM_POS before shooting)
    TP_BASE_AFTER_COLLECT = true,    -- after catching a wild downed pet, teleport to BASE_POS

    -- v8.2 remotes + aim lock
    USE_REMOTE_FIRE = true,          -- Remotes.EnterAim + Remotes.Fire (the real way this game shoots)
    WEAPON_NAME     = "RlyehTrident",-- <<< change to the weapon you use
    DART_NAME       = "Abysse",      -- <<< change to the dart you use
    FIRE_ORIGIN     = "camera",      -- "camera" or "character" - origin used to build the aim vector
    FIRE_INTERVAL   = 0.35,          -- seconds between Fire remote calls while locked on
    AIM_LOCK        = true,          -- glue the camera to the target every frame
    AIM_LOCK_ALPHA  = 0.45,          -- 0.1 = slow/smooth, 1.0 = instant snap
    ZOOM_ON_AIM     = true,          -- PC: scroll wheel to enter aim/zoom like a human
    ZOOM_NOTCHES    = 3,
    AUTO_BUY_DARTS  = false,
    BUY_INTERVAL    = 15,
}

local RARITY_COLORS = {
    Common = Color3.fromRGB(255,255,255),
    Uncommon = Color3.fromRGB(0,255,100),
    Rare = Color3.fromRGB(0,170,255),
    Epic = Color3.fromRGB(170,0,255),
    Legendary = Color3.fromRGB(255,200,0),
    Mythic = Color3.fromRGB(255,0,120),
    Divine = Color3.fromRGB(0,255,255),
    Secret = Color3.fromRGB(255,100,0),
}
local RARITY_VALUES = {
    Common = 100, Uncommon = 250, Rare = 500, Epic = 1200,
    Legendary = 5000, Mythic = 10000, Divine = 25000, Secret = 50000,
    Amargasaurus = 5000, ["T-Rex"] = 8000, Triceratops = 3000, Stegosaurus = 2500,
    Baryonyx = 4000, Raptor = 800, Mosasaurus = 7000,
}

-- State
local espFolder        = {}
local highlightFolder  = {}
local cachedPets       = {}
local cachedZones      = {}
local cachedZonesCount = -1
local lastScan    = 0
local lastZones   = 0
local lastAim     = 0
local lastCollect = 0
local lastMinigame = 0
local statusLabel  = nil
local freeToCatchName = nil
local ScreenGui    = nil   -- forward declaration (assigned later)
local lastBuy      = 0
local lockTarget   = nil   -- pet the aim-lock loop is currently glued to
local aimLockRef   = nil   -- last target we called EnterAim for
local aimEnteredAt = 0

--------------------------------------------------------------------------------
-- Real game remotes (confirmed):
--   Remotes.Buy:InvokeServer("DartsAll", "All")
--   Remotes.EnterAim:FireServer()
--   Remotes.Fire:FireServer(weapon, dart, directionUnit)
--------------------------------------------------------------------------------
local function getRemotesFolder()
    return RepStorage:FindFirstChild("Remotes")
end

local function getRemote(name)
    local r = getRemotesFolder()
    local inst = r and r:FindFirstChild(name)
    if inst and (inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction")) then return inst end
    return nil
end

local function unpackArgs(list, n)
    local up = table.unpack or unpack
    return up(list, 1, n or #list)
end

local function remoteBuyAllDarts()
    local buy = getRemote("Buy")
    if not buy then return false, "Remotes.Buy missing" end
    local ok, res = pcall(function() return buy:InvokeServer(unpackArgs({"DartsAll", "All"})) end)
    return ok, tostring(res)
end

local function remoteEnterAim()
    local aim = getRemote("EnterAim")
    if not aim then return false end
    return (pcall(function() aim:FireServer() end))
end

local function getFireOrigin()
    if CONFIG.FIRE_ORIGIN == "character" then
        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hrp then return hrp.Position end
    end
    local cam = Workspace.CurrentCamera
    if cam then return cam.CFrame.Position end
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    return hrp and hrp.Position or Vector3.new(0, 0, 0)
end

local function remoteFireAt(center)
    local fire = getRemote("Fire")
    if not fire or not center then return false end
    local d = center - getFireOrigin()
    if d.Magnitude < 0.01 then return false end
    return (pcall(function()
        fire:FireServer(CONFIG.WEAPON_NAME, CONFIG.DART_NAME, d.Unit)
    end))
end

-- PC: this game enters aim / zooms by scrolling the wheel. Try the known
-- VirtualInputManager wheel signatures because they differ per executor.
local function sendWheel(delta)
    local attempts = {
        function() VIM:SendMouseWheelEvent(0, delta, true) end,
        function() VIM:SendMouseWheelEvent(delta, 0, true) end,
        function() VIM:SendMouseWheelEvent(0, delta, false) end,
        function() VIM:SendMouseWheelEvent(0, 0, delta) end,
    }
    for _, fn in ipairs(attempts) do
        if pcall(fn) then return true end
    end
    return false
end

-- Enter aim mode: remote first (authoritative), then wheel-scroll for the
-- real geometry zoom so the animal fills the crosshair.
local function enterAimMode(force)
    if not force and tick() - aimEnteredAt < 3 then return true end
    local ok = remoteEnterAim()
    if CONFIG.ZOOM_ON_AIM and not IS_MOBILE then
        for _ = 1, CONFIG.ZOOM_NOTCHES do
            sendWheel(120)
            task.wait(0.02)
        end
    end
    aimEnteredAt = tick()
    return ok
end

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------
local function getCam()
    return Workspace.CurrentCamera
end

local function getAttr(obj, name)
    local ok, v = pcall(function() return obj:GetAttribute(name) end)
    if ok then return v end
    return nil
end

local function getPetName(model)
    local n = getAttr(model, "PetName") or getAttr(model, "Species")
    if n and tostring(n) ~= "" then return tostring(n) end
    local sv = model:FindFirstChild("PetName")
    if sv and sv:IsA("StringValue") and sv.Value ~= "" then return sv.Value end
    local raw = model.Name
    if raw:find("Spawn_", 1, true) then
        raw = raw:gsub("Spawn_", ""):gsub("_%d+$", ""):gsub("_", " ")
    end
    return raw
end

local function getPetRarity(model)
    local r = getAttr(model, "Rarity") or getAttr(model, "Tier")
    if r then return tostring(r) end
    return "Common"
end

local function getPetValue(model)
    local v = getAttr(model, "Value") or getAttr(model, "Price") or getAttr(model, "Worth")
    if type(v) == "number" and v > 0 then return v end
    local iv = model:FindFirstChild("Value") or model:FindFirstChild("Price")
    if iv and (iv:IsA("IntValue") or iv:IsA("NumberValue")) and iv.Value > 0 then return iv.Value end
    local rarity = getPetRarity(model)
    if RARITY_VALUES[rarity] then return RARITY_VALUES[rarity] end
    local name = getPetName(model)
    if RARITY_VALUES[name] then return RARITY_VALUES[name] end
    return 100
end

local function formatValue(v)
    if v >= 1000 then return string.format("$%.1fk", v / 1000) end
    return "$" .. tostring(v)
end

local function getRarityColor(model)
    local r = getPetRarity(model)
    if RARITY_COLORS[r] then return RARITY_COLORS[r] end
    local val = getPetValue(model)
    if val >= 10000 then return RARITY_COLORS.Mythic end
    if val >= 5000  then return RARITY_COLORS.Legendary end
    if val >= 1200  then return RARITY_COLORS.Epic end
    if val >= 500   then return RARITY_COLORS.Rare end
    return RARITY_COLORS.Common
end

local function isInBase(pos)
    if not pos then return false end
    if (pos - CONFIG.BASE_POS).Magnitude <= CONFIG.BASE_RADIUS then return true end
    if pos.X >= CONFIG.BASE_BOX.X_MIN and pos.X <= CONFIG.BASE_BOX.X_MAX
       and pos.Z >= CONFIG.BASE_BOX.Z_MIN and pos.Z <= CONFIG.BASE_BOX.Z_MAX then
        return true
    end
    return false
end

local function isOwnedPet(model)
    local owner = getAttr(model, "Owner") or getAttr(model, "OwnerName")
    if owner and tostring(owner) == LocalPlayer.Name then return true end
    if getAttr(model, "IsOwned") == true or getAttr(model, "InBase") == true then return true end
    return false
end

--------------------------------------------------------------------------------
-- Downed detection (wild pets)
--------------------------------------------------------------------------------
-- Catch proximity = ProximityPrompt whose text mentions catch/collect/tame.
-- A bare ClickDetector is NOT treated as "downed" (many wild pets have interact detectors).
local function hasCatchProximity(model)
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            local txt = (tostring(d.ActionText or "") .. " " .. tostring(d.ObjectText or "") .. " " .. d.Name):lower()
            if txt:find("catch", 1, true) or txt:find("collect", 1, true) or txt:find("tame", 1, true) then
                return true, d
            end
        end
    end
    return false, nil
end

local function updateFreeToCatch()
    freeToCatchName = nil
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    for _, d in ipairs(pg:GetDescendants()) do
        if d:IsA("TextLabel") and d.Text then
            local t = d.Text:lower()
            if t:find("free to catch", 1, true) or t:find("to catch", 1, true) then
                local parent = d.Parent
                if parent then
                    for _, sib in ipairs(parent:GetChildren()) do
                        if sib ~= d and sib:IsA("TextLabel") and sib.Text then
                            local low = sib.Text:lower()
                            if #low >= 3 and not low:find("catch", 1, true) and not low:find("free", 1, true) then
                                freeToCatchName = sib.Text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
                                break
                            end
                        end
                    end
                end
                if freeToCatchName then
                    print("[PetESP v8.1] FreeToCatch = " .. freeToCatchName)
                end
                break
            end
        end
    end
end

local function isDowned(model)
    local nm = model.Name:lower()
    if nm:find("downed", 1, true) then return true end

    -- Free to catch banner name match (guarded against empty pet name)
    if freeToCatchName and freeToCatchName ~= "" then
        local pn = getPetName(model):lower()
        if #pn >= 3 then
            local ftc = freeToCatchName:lower()
            if ftc:find(pn, 1, true) or pn:find(ftc, 1, true)
               or (pn:find("mosasaurus", 1, true) and ftc:find("mosasaurus", 1, true))
               or (pn:find("baryonyx", 1, true) and ftc:find("baryonyx", 1, true)) then
                return true
            end
        end
    end

    local state = getAttr(model, "State")
    if state then
        local s = tostring(state):lower()
        if s:find("down", 1, true) or s:find("knock", 1, true) or s:find("stun", 1, true) or s:find("catch", 1, true) then
            return true
        end
    end

    for _, key in ipairs({"Downed", "IsDowned", "Knocked", "CanCatch", "Catchable"}) do
        if getAttr(model, key) == true then return true end
    end
    for _, key in ipairs({"Downed", "IsDowned", "Knocked", "CanCatch", "Catchable"}) do
        local bv = model:FindFirstChild(key)
        if bv and bv:IsA("BoolValue") and bv.Value == true then return true end
    end

    if model:IsA("Model") then
        local hum = model:FindFirstChildOfClass("Humanoid")
        if hum and (hum.Health <= 0 or hum.Sit == true) then return true end
    end

    -- Downed prompts (catch ProximityPrompt only)
    if hasCatchProximity(model) then return true end

    -- Timer / catch text label directly on the pet
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("TextLabel") and d.Text then
            local t = d.Text:lower()
            if t:find("to catch", 1, true) or t:find("free to catch", 1, true) or t:match("%d+:%d%d") then
                return true
            end
        end
    end

    return false
end

--------------------------------------------------------------------------------
-- Position helpers
--------------------------------------------------------------------------------
local function findRootPart(model)
    if model:IsA("BasePart") then return model end
    if model:IsA("Model") then
        if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then return model.PrimaryPart end
        local hrp = model:FindFirstChild("HumanoidRootPart")
        if hrp and hrp:IsA("BasePart") then return hrp end
        local child = model:FindFirstChildWhichIsA("BasePart")
        if child then return child end
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BasePart") then return d end
        end
    end
    if model:IsA("Folder") then
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BasePart") then return d end
        end
    end
    return nil
end

local function getPetCenter(model)
    local root = findRootPart(model)
    if root then return root.Position end
    return nil
end

local function getZoneName(model)
    local p = model.Parent
    while p and p ~= Workspace do
        if p.Parent and p.Parent.Name == "Zones" then return p.Name end
        p = p.Parent
    end
    return "?"
end

--------------------------------------------------------------------------------
-- Zone discovery + pet scan
--------------------------------------------------------------------------------
local function findAllZones()
    if tick() - lastZones < 10 and #cachedZones > 0 then return cachedZones end
    lastZones = tick()
    cachedZones = {}
    local seen = {}
    for _, d in ipairs(Workspace:GetDescendants()) do
        if d.Name == "Zones" and d:IsA("Folder") and not seen[d] then
            seen[d] = true
            table.insert(cachedZones, d)
        end
    end
    if #cachedZones ~= cachedZonesCount then
        cachedZonesCount = #cachedZones
        print("[PetESP v8.1] Found Zones folders: " .. #cachedZones)
        for _, z in ipairs(cachedZones) do
            print("[PetESP v8.1] Zones: " .. z:GetFullName() .. " | Subzones: " .. #z:GetChildren())
        end
    end
    return cachedZones
end

local function scanZonesFast()
    local found = {}
    local seen = {}

    -- Skip a descendant if any ancestor is already added (prevents duplicate ESP)
    local function ancestorSeen(obj)
        local a = obj.Parent
        while a and a ~= Workspace do
            if seen[a] then return true end
            a = a.Parent
        end
        return false
    end

    local function tryAdd(obj)
        if not obj or seen[obj] then return end
        if not (obj:IsA("Model") or obj:IsA("BasePart")) then return end
        if obj:IsA("Model") and Players:GetPlayerFromCharacter(obj) then return end
        if ancestorSeen(obj) then return end

        local isSpawn = obj.Name:find("Spawn_", 1, true) ~= nil
        local hasHum  = obj:IsA("Model") and obj:FindFirstChildOfClass("Humanoid") ~= nil
        local hasVal  = getAttr(obj, "Value") ~= nil or getAttr(obj, "Rarity") ~= nil or getAttr(obj, "PetName") ~= nil
        local parentSpawns = obj.Parent and obj.Parent.Name == "Spawns"

        if not (isSpawn or hasHum or hasVal or parentSpawns) then return end
        if not findRootPart(obj) then return end

        seen[obj] = true
        table.insert(found, obj)
    end

    for _, zones in ipairs(findAllZones()) do
        for _, zone in ipairs(zones:GetChildren()) do
            local spawns = zone:FindFirstChild("Spawns")
            if spawns then
                for _, spawn in ipairs(spawns:GetChildren()) do
                    tryAdd(spawn)
                    if not seen[spawn] then
                        for _, desc in ipairs(spawn:GetDescendants()) do
                            if desc:IsA("Model") then tryAdd(desc) end
                        end
                    end
                end
            else
                for _, child in ipairs(zone:GetChildren()) do
                    if child:IsA("Model") then tryAdd(child) end
                end
            end
        end
    end

    for _, name in ipairs({"ClientPets", "Pets", "WildPets", "DownedPets"}) do
        local c = Workspace:FindFirstChild(name)
        if c then
            for _, child in ipairs(c:GetChildren()) do
                if child:IsA("Model") then tryAdd(child) end
            end
        end
    end

    return found
end

local function getCachedPets()
    local interval = CONFIG.LOW_LAG and 4 or CONFIG.SCAN_INTERVAL
    if tick() - lastScan >= interval or #cachedPets == 0 then
        cachedPets = scanZonesFast()
        lastScan = tick()
    end
    return cachedPets
end

--------------------------------------------------------------------------------
-- ESP + Highlight
--------------------------------------------------------------------------------
local function getESP(model, rootPart)
    if espFolder[model] and espFolder[model].gui and espFolder[model].gui.Parent then
        return espFolder[model]
    end
    if not rootPart then return nil end

    local gui = Instance.new("BillboardGui")
    gui.Name = "PetESP"
    gui.Size = UDim2.new(0, 130, 0, 24)
    gui.StudsOffset = Vector3.new(0, 3.2, 0)
    gui.AlwaysOnTop = true
    gui.LightInfluence = 0
    gui.MaxDistance = 600
    gui.Adornee = rootPart

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, 0, 1, 0)
    frame.BackgroundColor3 = Color3.fromRGB(10, 10, 12)
    frame.BackgroundTransparency = 0.35
    frame.BorderSizePixel = 0
    frame.Parent = gui
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = frame

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -6, 1, 0)
    label.Position = UDim2.new(0, 3, 0, 0)
    label.BackgroundTransparency = 1
    label.TextColor3 = Color3.fromRGB(255, 255, 255)
    label.TextSize = 11
    label.Font = Enum.Font.GothamBold
    label.Text = "Pet"
    label.TextXAlignment = Enum.TextXAlignment.Center
    label.TextStrokeTransparency = 0.1
    label.Parent = frame

    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then gui.Parent = pg else pcall(function() gui.Parent = game:GetService("CoreGui") end) end

    local entry = { gui = gui, label = label, frame = frame, lastText = "" }
    espFolder[model] = entry
    return entry
end

local function getHighlight(model, isDownedPet, rarityColor)
    local existing = highlightFolder[model]
    if existing and existing.Parent then return existing end
    local hl = Instance.new("Highlight")
    hl.Name = "PetHighlight"
    hl.FillTransparency = 0.85
    hl.OutlineTransparency = 0
    hl.FillColor = isDownedPet and Color3.fromRGB(255, 200, 0) or rarityColor
    hl.OutlineColor = hl.FillColor
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Adornee = model
    if model:IsA("Model") or model:IsA("BasePart") then
        hl.Parent = model
    else
        hl.Parent = Workspace
    end
    highlightFolder[model] = hl
    return hl
end

local function clearESP(model)
    if espFolder[model] then
        pcall(function() espFolder[model].gui:Destroy() end)
        espFolder[model] = nil
    end
    if highlightFolder[model] then
        pcall(function() highlightFolder[model]:Destroy() end)
        highlightFolder[model] = nil
    end
end

--------------------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------------------
ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "PetESPHubV8"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function() ScreenGui.Parent = game:GetService("CoreGui") end)
if not ScreenGui.Parent then ScreenGui.Parent = PlayerGui end

local MainFrame = Instance.new("Frame")
MainFrame.Size = UDim2.new(0, 235, 0, 372)
MainFrame.Position = UDim2.new(0, 10, 0, 10)
MainFrame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true
MainFrame.Parent = ScreenGui
Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 10)

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, 0, 0, 32)
Title.BackgroundTransparency = 1
Title.Text = "  PET ESP HUB v8.1 MOBILE"
Title.TextColor3 = Color3.fromRGB(0, 255, 140)
Title.TextSize = 13
Title.Font = Enum.Font.GothamBold
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = MainFrame

local MobileLabel = Instance.new("TextLabel")
MobileLabel.Size = UDim2.new(1, -20, 0, 16)
MobileLabel.Position = UDim2.new(0, 10, 0, 32)
MobileLabel.BackgroundTransparency = 1
MobileLabel.Text = IS_MOBILE and "Mobile Mode: Camera Aim + Tap Shoot" or "PC Mode: Camera Aim + Click"
MobileLabel.TextColor3 = Color3.fromRGB(255, 200, 0)
MobileLabel.TextSize = 10
MobileLabel.Font = Enum.Font.Gotham
MobileLabel.TextXAlignment = Enum.TextXAlignment.Left
MobileLabel.Parent = MainFrame

local function makeToggle(y, text, default, callback)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -20, 0, 28)
    btn.Position = UDim2.new(0, 10, 0, y)
    btn.BackgroundColor3 = default and Color3.fromRGB(0, 170, 90) or Color3.fromRGB(60, 60, 65)
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.TextSize = 12
    btn.Font = Enum.Font.Gotham
    btn.Text = text .. (default and " : ON" or " : OFF")
    btn.Parent = MainFrame
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
    local state = default
    btn.MouseButton1Click:Connect(function()
        state = not state
        btn.BackgroundColor3 = state and Color3.fromRGB(0, 170, 90) or Color3.fromRGB(60, 60, 65)
        btn.Text = text .. (state and " : ON" or " : OFF")
        callback(state)
    end)
    return btn
end

makeToggle(52,  "ESP", CONFIG.ESP_ENABLED,  function(v) CONFIG.ESP_ENABLED = v end)
makeToggle(84,  "Auto-Aim", CONFIG.AUTO_AIM, function(v) CONFIG.AUTO_AIM = v end)
makeToggle(116, "Auto-Collect WILD Downed", CONFIG.AUTO_COLLECT, function(v) CONFIG.AUTO_COLLECT = v end)
makeToggle(148, "Minigame Tap", CONFIG.MINIGAME, function(v) CONFIG.MINIGAME = v end)
makeToggle(180, "LOW LAG MODE", CONFIG.LOW_LAG, function(v)
    CONFIG.LOW_LAG = v
    CONFIG.TOP_N = v and 8 or 10
    print("[PetESP v8.1] LOW LAG = " .. tostring(v))
end)

local ModeBtn = Instance.new("TextButton")
ModeBtn.Size = UDim2.new(1, -20, 0, 28)
ModeBtn.Position = UDim2.new(0, 10, 0, 212)
ModeBtn.BackgroundColor3 = Color3.fromRGB(80, 40, 180)
ModeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ModeBtn.Text = "ESP Mode: Nearest (Tap to switch)"
ModeBtn.TextSize = 11
ModeBtn.Font = Enum.Font.GothamBold
ModeBtn.Parent = MainFrame
Instance.new("UICorner", ModeBtn).CornerRadius = UDim.new(0, 8)
ModeBtn.MouseButton1Click:Connect(function()
    if CONFIG.ESP_MODE == "Nearest" then
        CONFIG.ESP_MODE = "Value"
        ModeBtn.Text = "ESP Mode: Highest Value"
    else
        CONFIG.ESP_MODE = "Nearest"
        ModeBtn.Text = "ESP Mode: Nearest"
    end
end)

local BuyBtn = makeToggle(244, "Auto-Buy All Darts", CONFIG.AUTO_BUY_DARTS, function(v)
    CONFIG.AUTO_BUY_DARTS = v
    if v then
        local ok, res = remoteBuyAllDarts()
        print("[PetESP v8.2] BUY DartsAll/All -> " .. (ok and "OK" or "FAIL") .. " | " .. tostring(res))
        lastBuy = tick()
    end
end)

local WeaponLabel = Instance.new("TextLabel")
WeaponLabel.Size = UDim2.new(1, -20, 0, 16)
WeaponLabel.Position = UDim2.new(0, 10, 0, 346)
WeaponLabel.BackgroundTransparency = 1
WeaponLabel.Text = "W: " .. CONFIG.WEAPON_NAME .. "  |  D: " .. CONFIG.DART_NAME
WeaponLabel.TextColor3 = Color3.fromRGB(160, 200, 255)
WeaponLabel.TextSize = 10
WeaponLabel.Font = Enum.Font.Code
WeaponLabel.TextXAlignment = Enum.TextXAlignment.Left
WeaponLabel.Parent = MainFrame

local StatusPill = Instance.new("Frame")
StatusPill.Size = UDim2.new(1, -20, 0, 32)
StatusPill.Position = UDim2.new(0, 10, 0, 276)
StatusPill.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
StatusPill.Parent = MainFrame
Instance.new("UICorner", StatusPill).CornerRadius = UDim.new(0, 8)

statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -10, 1, 0)
statusLabel.Position = UDim2.new(0, 5, 0, 0)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
statusLabel.TextSize = 11
statusLabel.Font = Enum.Font.Code
statusLabel.Text = "Pets: 0 | Top: none"
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = StatusPill

local TestBtn = Instance.new("TextButton")
TestBtn.Size = UDim2.new(1, -20, 0, 28)
TestBtn.Position = UDim2.new(0, 10, 0, 308)
TestBtn.BackgroundColor3 = Color3.fromRGB(40, 90, 255)
TestBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
TestBtn.Text = "SELF-TEST (F9)"
TestBtn.TextSize = 12
TestBtn.Font = Enum.Font.GothamBold
TestBtn.Parent = MainFrame
Instance.new("UICorner", TestBtn).CornerRadius = UDim.new(0, 8)
TestBtn.MouseButton1Click:Connect(function()
    updateFreeToCatch()
    cachedPets = scanZonesFast()
    lastScan = tick()
    print("[PetESP v8.1] SELF-TEST scanned=" .. #cachedPets .. " | FreeToCatch=" .. tostring(freeToCatchName))
    local zonesCount = {}
    for _, p in ipairs(cachedPets) do
        local z = getZoneName(p)
        zonesCount[z] = (zonesCount[z] or 0) + 1
    end
    for z, c in pairs(zonesCount) do print("[PetESP v8.1] Zone " .. z .. " = " .. c) end
    for i, p in ipairs(cachedPets) do
        if i <= 10 then
            print("[PetESP v8.1] " .. i .. " " .. getPetName(p) .. " | " .. formatValue(getPetValue(p)) .. " | Zone=" .. getZoneName(p) .. " | Downed=" .. tostring(isDowned(p)) .. " | FullName=" .. p:GetFullName())
        end
    end
end)

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 22, 0, 22)
CloseBtn.Position = UDim2.new(1, -28, 0, 5)
CloseBtn.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.Text = "X"
CloseBtn.TextSize = 12
CloseBtn.Parent = MainFrame
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0, 6)
CloseBtn.MouseButton1Click:Connect(function() ScreenGui.Enabled = false end)

--------------------------------------------------------------------------------
-- Character + input helpers
--------------------------------------------------------------------------------
local function getPlayerPos()
    local char = LocalPlayer.Character
    if char and char:FindFirstChild("HumanoidRootPart") then
        return char.HumanoidRootPart.Position
    end
    return Vector3.new(0, 0, 0)
end

local function teleportTo(pos)
    local char = LocalPlayer.Character
    if char and char:FindFirstChild("HumanoidRootPart") then
        char.HumanoidRootPart.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
    end
end

-- Find a button by keywords across PlayerGui + CoreGui, skipping our own hub GUI
local function findButton(keywords, excludeOwn)
    local roots = {}
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then table.insert(roots, pg) end
    pcall(function()
        local cg = game:GetService("CoreGui")
        if cg then table.insert(roots, cg) end
    end)
    for _, root in ipairs(roots) do
        for _, d in ipairs(root:GetDescendants()) do
            if (d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible and d.AbsoluteSize.X > 5 then
                local skip = excludeOwn and ScreenGui and d:IsDescendantOf(ScreenGui)
                if not skip then
                    local s = (tostring(d.Name or "") .. " " .. tostring(d.Text or "")):lower()
                    for _, kw in ipairs(keywords) do
                        if s:find(kw, 1, true) then return d end
                    end
                end
            end
        end
    end
    return nil
end

-- Robust tap: firesignal -> VIM mouse -> (guarded) VIM touch
local function tapButton(btn)
    if not btn then return false end
    if firesignal then
        local ok = pcall(function() firesignal(btn.Activated) end)
        if ok then return true end
    end
    local pos = btn.AbsolutePosition + btn.AbsoluteSize / 2
    local okMouse = pcall(function()
        VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
        task.wait(0.05)
        VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
    end)
    if okMouse then return true end
    pcall(function()
        VIM:SendTouchEvent(0, 0, pos.X, pos.Y, true)
        task.wait(0.08)
        VIM:SendTouchEvent(0, 0, pos.X, pos.Y, false)
    end)
    return true
end

local function findShootButton()
    -- NOTE: "scope" removed on purpose (tapping scope would not shoot)
    return findButton({"shoot", "fire", "dart", "attack"}, true)
end

local function findCatchButton()
    return findButton({"catch", "collect", "tame"}, true)
end

local function tryCollectPet(pet)
    local center = getPetCenter(pet)
    if center then teleportTo(center) task.wait(0.5) end

    -- 1) Mobile catch button
    local catchBtn = findCatchButton()
    if catchBtn then
        print("[PetESP v8.1] Tapping Catch for " .. getPetName(pet))
        tapButton(catchBtn)
        task.wait(0.4)
    end

    -- 2) ProximityPrompts / ClickDetectors
    for _, d in ipairs(pet:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            pcall(function() if fireproximityprompt then fireproximityprompt(d) end end)
        elseif d:IsA("ClickDetector") then
            pcall(function() if fireclickdetector then fireclickdetector(d) end end)
        end
    end
    task.wait(0.3)
end

--------------------------------------------------------------------------------
-- Auto-aim (mobile camera lookAt + tap Shoot / PC camera + click)
--------------------------------------------------------------------------------
local function doAutoAim(target)
    if not target or not target.Parent then return end
    if tick() - lastAim < CONFIG.AIM_COOLDOWN then return end
    lastAim = tick()

    local cam = getCam()
    if not cam then return end
    local center = getPetCenter(target)
    if not center then return end

    -- Optional fixed-scope behaviour (off by default - breaks wild-pet hunting in far zones)
    if CONFIG.FORCE_AIM_SPOT then
        local myPos = getPlayerPos()
        if (myPos - CONFIG.AIM_POS).Magnitude > 15 then
            teleportTo(CONFIG.AIM_POS)
            task.wait(0.3)
        end
    end

    -- Aim camera at pet (works for both mobile and PC)
    pcall(function() cam.CFrame = CFrame.lookAt(cam.CFrame.Position, center) end)

    -- SECONDARY aim: move mouse onto the pet's screen position.
    -- Mouse-follow cameras can overwrite Camera.CFrame next frame, so this makes the
    -- crosshair converge on the target instead of drifting back.
    pcall(function()
        local c2 = getCam()
        if c2 then
            local vp, onScreen = c2:WorldToViewportPoint(center)
            if onScreen and vp.Z > 0 then
                VIM:SendMouseMoveEvent(vp.X, vp.Y, game)
            end
        end
    end)
    task.wait(0.15)

    local shootBtn = findShootButton()
    if shootBtn then
        print("[PetESP v8.1] Aim -> " .. getPetName(target) .. " | tapping Shoot")
        tapButton(shootBtn)
        return
    end

    if IS_MOBILE then
        -- Fallback: fire shoot remote, else tap screen center (crosshair)
        local fired = false
        pcall(function()
            for _, r in ipairs(RepStorage:GetDescendants()) do
                if r:IsA("RemoteEvent") then
                    local n = r.Name:lower()
                    if n:find("shoot", 1, true) or n:find("fire", 1, true) or n:find("dart", 1, true) then
                        r:FireServer(center)
                        fired = true
                        print("[PetESP v8.1] Fired Shoot Remote: " .. r:GetFullName())
                        break
                    end
                end
            end
        end)
        if not fired then
            local c = getCam()
            if c then
                local vx, vy = c.ViewportSize.X / 2, c.ViewportSize.Y / 2
                pcall(function()
                    VIM:SendMouseButtonEvent(vx, vy, 0, true, game, 0)
                    task.wait(0.05)
                    VIM:SendMouseButtonEvent(vx, vy, 0, false, game, 0)
                end)
            end
        end
    else
        -- PC fallback: click screen center
        local c = getCam()
        if c then
            local vx, vy = c.ViewportSize.X / 2, c.ViewportSize.Y / 2
            pcall(function()
                VIM:SendMouseButtonEvent(vx, vy, 0, true, game, 0)
                task.wait(0.05)
                VIM:SendMouseButtonEvent(vx, vy, 0, false, game, 0)
            end)
        end
    end
end

--------------------------------------------------------------------------------
-- Minigame (broadened; never taps our own hub)
--------------------------------------------------------------------------------
local function doMinigame()
    if tick() - lastMinigame < 0.4 then return end
    lastMinigame = tick()

    local roots = {}
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then table.insert(roots, pg) end
    pcall(function()
        local cg = game:GetService("CoreGui")
        if cg then table.insert(roots, cg) end
    end)

    local tapped = 0
    for _, root in ipairs(roots) do
        for _, d in ipairs(root:GetDescendants()) do
            if (d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible then
                if not (ScreenGui and d:IsDescendantOf(ScreenGui)) then
                    local s = (tostring(d.Name or "") .. " " .. tostring(d.Text or "")):lower()
                    if s:find("duck", 1, true) or s:find("target", 1, true) or s:find("tap", 1, true) then
                        if tapButton(d) then tapped = tapped + 1 end
                    end
                end
            end
        end
    end
    if tapped > 0 then
        print("[PetESP v8.1] Minigame tapped " .. tapped)
    end
end

--------------------------------------------------------------------------------
-- AIM LOCK + FIRE  (runs every frame so the crosshair stays glued to the pet)
--------------------------------------------------------------------------------
local function clickCenter()
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local vx, vy = cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2
    pcall(function()
        VIM:SendMouseButtonEvent(vx, vy, 0, true, game, 0)
        task.wait(0.02)
        VIM:SendMouseButtonEvent(vx, vy, 0, false, game, 0)
    end)
end

RunService.RenderStepped:Connect(function()
    if not CONFIG.AUTO_AIM then aimLockRef = nil return end

    local target = lockTarget
    if not (target and target.Parent) then
        aimLockRef = nil
        return
    end

    local cam = Workspace.CurrentCamera
    local center = getPetCenter(target)
    if not (cam and center) then return end

    -- New target: EnterAim remote + PC wheel zoom (once per target)
    if aimLockRef ~= target then
        aimLockRef = target
        enterAimMode(true)
    end

    -- Continuous lock: this is the "auto lock-on" - re-aimed every frame
    local want = CFrame.lookAt(cam.CFrame.Position, center)
    if CONFIG.AIM_LOCK then
        cam.CFrame = cam.CFrame:Lerp(want, CONFIG.AIM_LOCK_ALPHA)
    else
        cam.CFrame = want
    end

    -- Keep the in-aim crosshair sitting on the animal
    pcall(function()
        local vp, onScreen = cam:WorldToViewportPoint(center)
        if onScreen and vp.Z > 0 then VIM:SendMouseMoveEvent(vp.X, vp.Y, game) end
    end)

    -- Fire on a steady cadence
    if tick() - lastAim >= CONFIG.FIRE_INTERVAL then
        lastAim = tick()
        local fired = false
        if CONFIG.USE_REMOTE_FIRE then
            remoteEnterAim()
            fired = remoteFireAt(center)
        end
        if not fired then
            local btn = findShootButton()
            if btn then tapButton(btn) else clickCenter() end
        end
    end
end)

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------
task.spawn(function()
    while true do
        local interval = CONFIG.LOW_LAG and 0.5 or CONFIG.ESP_INTERVAL
        task.wait(interval)

        local ok, err = pcall(function()
            updateFreeToCatch()

            local allPets = getCachedPets()
            local playerPos = getPlayerPos()

            local espCandidates = {}
            local downedList = {}
            local aimCandidates = {}

            for _, pet in ipairs(allPets) do
                if pet and pet.Parent then
                    local center = getPetCenter(pet)
                    if center and (center - playerPos).Magnitude < CONFIG.ESP_MAX_DIST then
                        local downed = isDowned(pet)
                        if downed then table.insert(downedList, pet) end
                        if not isOwnedPet(pet) and not isInBase(center) then
                            table.insert(espCandidates, pet)
                            if not downed then table.insert(aimCandidates, pet) end
                        end
                    end
                end
            end

            -- Sort ESP candidates
            if CONFIG.ESP_MODE == "Nearest" then
                table.sort(espCandidates, function(a, b)
                    local ca = getPetCenter(a) or Vector3.new()
                    local cb = getPetCenter(b) or Vector3.new()
                    return (ca - playerPos).Magnitude < (cb - playerPos).Magnitude
                end)
            else
                table.sort(espCandidates, function(a, b) return getPetValue(a) > getPetValue(b) end)
            end

            -- Aim candidates always by value (highest first)
            table.sort(aimCandidates, function(a, b) return getPetValue(a) > getPetValue(b) end)

            local topN = CONFIG.LOW_LAG and 8 or CONFIG.TOP_N
            local keep = {}

            if CONFIG.ESP_ENABLED then
                for i = 1, math.min(topN, #espCandidates) do
                    local pet = espCandidates[i]
                    keep[pet] = true
                    local center = getPetCenter(pet)
                    local root = findRootPart(pet)
                    if center and root then
                        local dist = (center - playerPos).Magnitude
                        local downed = isDowned(pet)
                        local rarityColor = getRarityColor(pet)

                        local hl = getHighlight(pet, downed, rarityColor)
                        if hl then
                            hl.Enabled = true
                            hl.FillColor = downed and Color3.fromRGB(255, 200, 0) or rarityColor
                            hl.OutlineColor = hl.FillColor
                        end

                        local esp = getESP(pet, root)
                        if esp and esp.gui then
                            esp.gui.Enabled = dist >= CONFIG.HIDE_DIST
                            esp.gui.Adornee = root
                            local newText
                            if downed then
                                newText = getPetName(pet) .. "  FREE!"
                            else
                                newText = getPetName(pet) .. "  " .. formatValue(getPetValue(pet)) .. "  " .. math.floor(dist) .. "m"
                            end
                            if newText ~= esp.lastText then
                                esp.label.Text = newText
                                esp.label.TextColor3 = downed and Color3.fromRGB(255, 220, 0) or Color3.fromRGB(255, 255, 255)
                                esp.frame.BackgroundColor3 = downed and Color3.fromRGB(80, 60, 0) or Color3.fromRGB(10, 10, 12)
                                esp.lastText = newText
                            end
                        end
                    end
                end
            end

            -- Disable / cleanup not-kept entries
            for pet, entry in pairs(espFolder) do
                if not keep[pet] then
                    pcall(function() entry.gui.Enabled = false end)
                    if not pet.Parent then clearESP(pet) end
                end
            end
            for pet, hl in pairs(highlightFolder) do
                if not keep[pet] then
                    pcall(function() hl.Enabled = false end)
                    if not pet.Parent then clearESP(pet) end
                end
            end

            if statusLabel then
                local tn = (#aimCandidates > 0) and getPetName(aimCandidates[1]) or "none"
                statusLabel.Text = "Pets: " .. #espCandidates .. " | Top: " .. tn .. " | Downed: " .. #downedList
                    .. (freeToCatchName and (" | FTC: " .. freeToCatchName) or "")
            end

            -- Priority: collect wild downed first (aim is now handled by the lock loop)
            if CONFIG.AUTO_COLLECT and #downedList > 0 then
                if tick() - lastCollect >= CONFIG.COLLECT_COOLDOWN then
                    lastCollect = tick()
                    table.sort(downedList, function(a, b)
                        local ca = getPetCenter(a) or Vector3.new()
                        local cb = getPetCenter(b) or Vector3.new()
                        return (ca - playerPos).Magnitude < (cb - playerPos).Magnitude
                    end)
                    local target = downedList[1]
                    print("[PetESP v8.2] Auto-collect WILD downed: " .. getPetName(target) .. " | FTC=" .. tostring(freeToCatchName))
                    tryCollectPet(target)
                    if CONFIG.TP_BASE_AFTER_COLLECT then
                        task.wait(0.4)
                        teleportTo(CONFIG.BASE_POS)
                    end
                end
            end

            -- Auto-buy darts
            if CONFIG.AUTO_BUY_DARTS and tick() - lastBuy >= CONFIG.BUY_INTERVAL then
                lastBuy = tick()
                local okBuy, resBuy = remoteBuyAllDarts()
                if not okBuy then print("[PetESP v8.2] auto-buy failed: " .. tostring(resBuy)) end
            end

            if CONFIG.MINIGAME then doMinigame() end
        end)

        if not ok then
            print("[PetESP v8.1] tick error: " .. tostring(err))
        end
    end
end)

print("[PetESP v8.1] Ready - ANY Zones, Clean ESP, Camera Aim, Auto-Collect Wild")
