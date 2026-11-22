-- Pet ESP Hub v8.3 MOBILE + CURRENT-WORLD ONLY + REAL GAME REMOTES
-- v8.3 CHANGES (vs v8.2):
--   * Scans wild animals ONLY in the world you are standing in (CONFIG.WORLD = "auto",
--     or set it to e.g. "World3" to pin one). Other worlds' Zones are ignored.
--   * Aim lock actually works now: v8.2 never assigned the lock target. The main loop
--     now picks one (nearest wild animal in range, sticky) and the camera locks to it.
--   * Camera lock is bound after the game's camera script and never yields; firing +
--     auto-scope run in their own thread. Fire direction is built from your camera
--     position straight to the animal, so shots go to it even if the camera is fought.
--   * Auto-scope: EnterAim remote (+ wheel zoom on PC / Scope button on mobile) per target.
--   * X button = full shutdown (every loop stops, ESP/highlights/GUI destroyed).
--     "-" button = hide the panel; tap the small PET bubble to bring it back.
--   * Buttons use .Activated so they work on touch.
-- v8.3.2:
--   * ESP value = the game's own overhead label ("LEGENDARY . 135SP $/S"), parsed with K/M/B/T/Qa/Qi/Sx/Sp/Oc/No/Dc.
--   * Animals are also discovered through that label (any folder), locked/downed animals always get ESP.
--   * Scope/shoot: real mouse/touch click (GUI-inset corrected) + signal fallbacks, verified by the SHOOT button
--     appearing. LEARN FILL / SLEEP / SCOPE buttons record the real dart names + scope button from YOU using them once.
-- v8.3.1:
--   * Aim sequence: TP to AIM_POS -> tap Scope -> fill circles with FILL_DART (Magma) ->
--     finish with SLEEP_DART (Abyss) -> collect the downed animal -> TP to BASE_POS.
--   * Collect fixes: name match ignores spaces (SeaTurtleRainbow vs "Sea Turtle Rainbow ..."),
--     owned/base pets are never "downed" targets, no endless retry on the same pet.
--   * FreeToCatch console spam fixed (prints only when it changes).
--   * PET bubble reopens the panel (own tap/drag handling); RightShift also toggles it.
--   * DEBUG button dumps world, buttons, darts and the nearest animal's attributes.
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
-- v8.3 REAL GAME REMOTES (this is what actually shoots here - there is no Shoot button):
--   Aim : ReplicatedStorage.Remotes.EnterAim:FireServer()
--   Fire: ReplicatedStorage.Remotes.Fire:FireServer(WEAPON, DART, directionUnit)
--   Buy : ReplicatedStorage.Remotes.Buy:InvokeServer("DartsAll", "All")
--   >>> Edit CONFIG.WEAPON_NAME / SLEEP_DART / FILL_DART below to the weapon + darts you use.

print("[PetESP v8.3] ====== LOADED OK - MOBILE + ANY ZONES + CLEAN ESP ======")

local Players      = game:GetService("Players")
local Workspace    = game:GetService("Workspace")
local UserInput    = game:GetService("UserInputService")
local VIM          = game:GetService("VirtualInputManager")
local RunService   = game:GetService("RunService")
local RepStorage   = game:GetService("ReplicatedStorage")
local LocalPlayer  = Players.LocalPlayer
local PlayerGui    = LocalPlayer:WaitForChild("PlayerGui")

-- Single-instance guard: re-running the script cleanly replaces the old hub
local GENV = (getgenv and getgenv()) or _G
if GENV.PetESPHubCleanup then pcall(GENV.PetESPHubCleanup) end
local RUNNING = true
local connections = {}

local IS_MOBILE = UserInput.TouchEnabled and not UserInput.MouseEnabled
print("[PetESP v8.3] IS_MOBILE = " .. tostring(IS_MOBILE))

local CONFIG = {
    AIM_POS = Vector3.new(-5996, 3, 2),     -- stand here, open the scope, shoot
    BASE_POS = Vector3.new(-6021, 3, 100),   -- go here after a catch
    BASE_RADIUS = 90,
    BASE_BOX = {X_MIN = -6110, X_MAX = -5930, Z_MIN = 20, Z_MAX = 180},

    ESP_ENABLED   = true,
    AUTO_AIM      = true,
    AUTO_COLLECT  = true,
    MINIGAME      = false,
    LOW_LAG       = false,

    ESP_MODE      = "Nearest",   -- "Nearest" or "Value"
    TOP_N         = 15,
    ESP_MAX_DIST  = 500,
    HIDE_DIST     = 25,
    SCAN_INTERVAL = 2.5,
    ESP_INTERVAL  = 0.3,
    AIM_COOLDOWN  = 1.2,
    COLLECT_COOLDOWN = 1.0,

    -- v8.3 flags
    FORCE_AIM_SPOT = true,           -- true = old fixed-scope behaviour (teleport to AIM_POS before shooting)
    TP_BASE_AFTER_COLLECT = true,    -- after catching a wild downed pet, teleport to BASE_POS

    -- v8.3 remotes + aim lock
    USE_REMOTE_FIRE = true,          -- Remotes.EnterAim + Remotes.Fire (the real way this game shoots)
    WEAPON_NAME     = "RlyehTrident",-- <<< change to the weapon you use
    SLEEP_DART      = "Abysse",      -- dart that puts the animal to sleep (Abyss Harpoon, sleeps 125s)
    FILL_DART       = "auto",        -- cheap dart that fills the hit circles (Magma Harpoon). "auto" = look it up, else "Magma"
    FILL_SHOTS      = 5,             -- fill-dart shots before the sleep dart when the circles can't be read
    SLEEP_RETRY     = 2.0,           -- seconds between sleep-dart shots (saves your Abyss darts)
    AUTO_SCOPE      = true,
    LABEL_DISCOVERY = true,          -- find wild animals by their overhead "$/S" label (any folder)
    LABEL_NEEDS_ODDS = true,         -- ...and require the "1 in N" line, so base/owned pets are not picked up
    FIRE_ORIGIN     = "camera",      -- "camera" or "character" - origin used to build the aim vector
    FIRE_INTERVAL   = 0.35,          -- seconds between Fire remote calls while locked on
    AIM_LOCK        = true,          -- glue the camera to the target every frame
    AIM_LOCK_ALPHA  = 0.45,          -- 0.1 = slow/smooth, 1.0 = instant snap
    ZOOM_ON_AIM     = true,          -- PC: scroll wheel to enter aim/zoom like a human
    ZOOM_NOTCHES    = 3,
    AUTO_BUY_DARTS  = false,
    BUY_INTERVAL    = 15,

    -- v8.3
    WORLD             = "auto",      -- "auto" = world you are in; or pin a name like "World3"
    SCAN_EXTRA_FOLDERS = false,      -- also scan Workspace.Pets/ClientPets/... (not world-specific)
    AIM_MAX_DIST      = 400,         -- only lock onto animals within this many studs
    AIM_PRIORITY      = "Nearest",   -- "Nearest" or "Value"
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
local AIM_BIND     = "PetESPAimLock"
local currentWorldName = "?"
local lastFTCPrinted = nil
local collecting     = false                       -- true while the collect + go-to-base routine runs
local collectTried   = setmetatable({}, {__mode = "k"})
local lastShotTarget = nil
local debugDump      = nil                         -- assigned later
local armLearn       = nil                         -- assigned later
local labelPets      = {}                          -- animals found through their overhead label
local nativeCache    = setmetatable({}, {__mode = "k"})

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

local function remoteFireAt(center, dart)
    local fire = getRemote("Fire")
    if not fire or not center then return false end
    local d = center - getFireOrigin()
    if d.Magnitude < 0.01 then return false end
    return (pcall(function()
        fire:FireServer(CONFIG.WEAPON_NAME, dart or CONFIG.SLEEP_DART, d.Unit)
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

-- The game draws its own overhead label on every animal: "LEGENDARY . 135SP $/S".
-- That is the accurate value, so read it instead of guessing.
local SUFFIX_MULT = { k = 1e3, m = 1e6, b = 1e9, t = 1e12, qa = 1e15, qi = 1e18,
                      sx = 1e21, sp = 1e24, oc = 1e27, no = 1e30, dc = 1e33 }
local VALUE_STEPS = { {"Dc", 1e33}, {"No", 1e30}, {"Oc", 1e27}, {"Sp", 1e24}, {"Sx", 1e21},
                      {"Qi", 1e18}, {"Qa", 1e15}, {"T", 1e12}, {"B", 1e9}, {"M", 1e6}, {"K", 1e3} }

local function parseIncome(text)
    local t = text:lower()
    local num, suf = t:match("([%d%.,]+)%s*(%a*)%s*%$%s*/%s*s")
    if not num then return nil end
    num = tonumber((num:gsub(",", "")))
    if not num then return nil end
    local mult = 1
    if suf and suf ~= "" then
        mult = SUFFIX_MULT[suf]
        if not mult then return nil end
    end
    return num * mult
end

local function nativeInfo(model)
    local c = nativeCache[model]
    if c and tick() - c.t < 1.5 then return c.info end
    local info = nil
    local function scan(root)
        for _, d in ipairs(root:GetDescendants()) do
            if d:IsA("TextLabel") and d.Text ~= "" then
                local v = parseIncome(d.Text)
                if v then
                    local rw = d.Text:lower():match("^%s*(%a+)")
                    info = { value = v, text = d.Text,
                             rarity = rw and (rw:sub(1, 1):upper() .. rw:sub(2)) or nil }
                    return true
                end
            end
        end
        return false
    end
    for _, g in ipairs(model:GetDescendants()) do
        if g:IsA("BillboardGui") and g.Name ~= "PetESP" and scan(g) then break end
    end
    if not info then
        for _, g in ipairs(PlayerGui:GetChildren()) do
            if g:IsA("BillboardGui") and g.Name ~= "PetESP" and g.Adornee
               and g.Adornee:IsDescendantOf(model) and scan(g) then break end
        end
    end
    nativeCache[model] = { t = tick(), info = info }
    return info
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
    local ni = nativeInfo(model)
    if ni and ni.rarity then return ni.rarity end
    return "Common"
end

local function getPetValue(model)
    local ni = nativeInfo(model)
    if ni and ni.value then return ni.value end
    local v = getAttr(model, "Value") or getAttr(model, "Price") or getAttr(model, "Worth")
    if type(v) == "number" and v > 0 then return v end
    local iv = model:FindFirstChild("Value") or model:FindFirstChild("Price")
    if iv and (iv:IsA("IntValue") or iv:IsA("NumberValue")) and iv.Value > 0 then return iv.Value end
    
    -- NEW: Check for a Configuration folder with Value/Price children
    local config = model:FindFirstChild("Configuration")
    if config then
        for _, c in ipairs(config:GetChildren()) do
            if c:IsA("NumberValue") or c:IsA("IntValue") then
                local low = c.Name:lower()
                if low:find("value", 1, true) or low:find("price", 1, true) or low:find("worth", 1, true) then
                    if c.Value > 0 then return c.Value end
                end
            end
        end
    end

    local rarity = getPetRarity(model)
    if RARITY_VALUES[rarity] then return RARITY_VALUES[rarity] end
    local name = getPetName(model)
    if RARITY_VALUES[name] then return RARITY_VALUES[name] end
    return 100
end

local function formatValue(v)
    for _, st in ipairs(VALUE_STEPS) do
        if v >= st[2] then
            local x = v / st[2]
            return string.format(x >= 100 and "%.0f%s" or (x >= 10 and "%.1f%s" or "%.2f%s"), x, st[1])
        end
    end
    return tostring(math.floor(v))
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

-- Stricter than the ESP scan: only things that really look like wild animals are
-- eligible for aim lock (so we never lock onto scenery models).
local function normAlnum(str)
    return (tostring(str):lower():gsub("[^%w]", ""))
end

local function isWildAnimal(model)
    if labelPets[model] then return true end
    if model.Name:find("Spawn_", 1, true) then return true end
    if model.Parent and model.Parent.Name == "Spawns" then return true end
    if model:IsA("Model") and model:FindFirstChildOfClass("Humanoid") then return true end
    if getAttr(model, "PetName") ~= nil or getAttr(model, "Species") ~= nil
       or getAttr(model, "Rarity") ~= nil or getAttr(model, "Value") ~= nil then
        return true
    end
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
                if freeToCatchName and freeToCatchName ~= lastFTCPrinted then
                    lastFTCPrinted = freeToCatchName          -- print only when it changes
                    print("[PetESP v8.3] FreeToCatch = " .. freeToCatchName)
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
        -- compare with spaces/punctuation stripped: "SeaTurtleRainbow" vs "Sea Turtle Rainbow COMMON · Coral Reef"
        local pn = normAlnum(getPetName(model))
        if #pn >= 3 then
            local ftc = normAlnum(freeToCatchName)
            if ftc:find(pn, 1, true) or pn:find(ftc, 1, true) then
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
-- Label-based discovery: any BillboardGui that shows "$/S" (and the "1 in N" odds line) belongs to a wild animal
local function labelState(b)
    local inc, odds, hasText = false, false, false
    for _, d in ipairs(b:GetDescendants()) do
        if d:IsA("TextLabel") and d.Text ~= "" then
            hasText = true
            local t = d.Text:lower()
            if t:find("%$%s*/%s*s") then inc = true end
            if t:find("%d%s+in%s+%d") then odds = true end
        end
    end
    return inc, odds, hasText
end

local function registerBillboard(b)
    if not CONFIG.LABEL_DISCOVERY or b.Name == "PetESP" then return end
    task.spawn(function()
        for _, w in ipairs({0.4, 1.5, 4}) do
            task.wait(w)
            if not RUNNING or not b.Parent then return end
            local inc, odds, hasText = labelState(b)
            if inc and (odds or not CONFIG.LABEL_NEEDS_ODDS) then
                local host = b.Adornee or b.Parent
                local model = host and ((host:IsA("Model") and host) or host:FindFirstAncestorWhichIsA("Model"))
                if model and model ~= Workspace and not Players:GetPlayerFromCharacter(model)
                   and #model:GetChildren() <= 80 and not model:FindFirstChild("Zones") then
                    labelPets[model] = true
                end
                return
            end
            if hasText then return end        -- text is there and it is not an animal label
        end
    end)
end

table.insert(connections, Workspace.DescendantAdded:Connect(function(d)
    if d:IsA("BillboardGui") then registerBillboard(d) end
end))
table.insert(connections, PlayerGui.DescendantAdded:Connect(function(d)
    if d:IsA("BillboardGui") then registerBillboard(d) end
end))
task.spawn(function()
    local n = 0
    for _, root in ipairs({Workspace, PlayerGui}) do
        for _, d in ipairs(root:GetDescendants()) do
            if d:IsA("BillboardGui") then registerBillboard(d) end
            n = n + 1
            if n % 4000 == 0 then task.wait() end
            if not RUNNING then return end
        end
    end
end)

local allZoneFolders, lastZoneEnum = {}, 0

local function normName(str)
    return (tostring(str):lower():gsub("[%s_%-]", ""))
end

local function worldNameOf(zonesFolder)
    local p = zonesFolder.Parent
    if not p or p == Workspace then return "Workspace" end
    return p.Name
end

local function myRootPos()
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    return hrp and hrp.Position or nil
end

-- Closest sampled spawn in a Zones folder to pos (samples a few spawns per zone: cheap)
local function distToZones(zonesFolder, pos)
    local best = math.huge
    for _, zone in ipairs(zonesFolder:GetChildren()) do
        local holder = zone:FindFirstChild("Spawns") or zone
        local sampled = 0
        for _, s2 in ipairs(holder:GetChildren()) do
            local root = findRootPart(s2)
            if root then
                local d = (root.Position - pos).Magnitude
                if d < best then best = d end
                sampled = sampled + 1
                if sampled >= 4 then break end
            end
        end
    end
    return best
end

-- Returns ONLY the Zones folders of the world you are in (or CONFIG.WORLD if pinned)
local function findAllZones()
    if tick() - lastZones < 3 and #cachedZones > 0 then return cachedZones end
    lastZones = tick()

    if tick() - lastZoneEnum >= 15 or #allZoneFolders == 0 then
        lastZoneEnum = tick()
        allZoneFolders = {}
        local seen = {}
        for _, d in ipairs(Workspace:GetDescendants()) do
            if d.Name == "Zones" and d:IsA("Folder") and not seen[d] then
                seen[d] = true
                table.insert(allZoneFolders, d)
            end
        end
    end

    local picked, pickedName = {}, nil
    local want = CONFIG.WORLD
    if want and tostring(want) ~= "" and tostring(want):lower() ~= "auto" then
        local w = normName(want)
        for _, z in ipairs(allZoneFolders) do
            if normName(worldNameOf(z)) == w then
                table.insert(picked, z)
                pickedName = worldNameOf(z)
            end
        end
    end

    if #picked == 0 then
        local pos = myRootPos()
        if not pos then return cachedZones end   -- no character yet: keep previous pick
        local bestD, bestName = math.huge, nil
        for _, z in ipairs(allZoneFolders) do
            local d = distToZones(z, pos)
            if d < bestD then bestD = d; bestName = worldNameOf(z) end
        end
        if bestName then
            for _, z in ipairs(allZoneFolders) do
                if worldNameOf(z) == bestName then table.insert(picked, z) end
            end
            pickedName = bestName
        else
            picked = allZoneFolders          -- no spawns visible anywhere yet: fall back to all
            pickedName = "all"
        end
    end

    cachedZones = picked
    if pickedName ~= currentWorldName then
        currentWorldName = pickedName or "?"
        lastScan = 0                         -- rescan right away after a world change
        print("[PetESP v8.3] Current world = " .. tostring(currentWorldName)
            .. " | Zones folders: " .. #picked .. " (of " .. #allZoneFolders .. " total)")
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
        local isPet   = (obj:IsA("Model") and #obj.Name > 3 and not Players:GetPlayerFromCharacter(obj))

        if not (isSpawn or hasHum or hasVal or parentSpawns or isPet) then return end
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

    for _, name in ipairs(CONFIG.SCAN_EXTRA_FOLDERS and {"ClientPets", "Pets", "WildPets", "DownedPets", "WildAnimals", "Animals", "Mobs", "Living"} or {}) do
        local c = Workspace:FindFirstChild(name)
        if c then
            for _, child in ipairs(c:GetChildren()) do
                if child:IsA("Model") then tryAdd(child) end
            end
        end
    end

    if CONFIG.LABEL_DISCOVERY then
        for model in pairs(labelPets) do
            if not model.Parent then
                labelPets[model] = nil
            elseif not seen[model] and not ancestorSeen(model) and findRootPart(model) then
                seen[model] = true
                table.insert(found, model)
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
    gui.Size = UDim2.new(0, 190, 0, 24)
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
local function shutdown()
    if not RUNNING then return end
    RUNNING = false
    CONFIG.ESP_ENABLED = false
    CONFIG.AUTO_AIM = false
    CONFIG.AUTO_COLLECT = false
    CONFIG.MINIGAME = false
    CONFIG.AUTO_BUY_DARTS = false
    lockTarget = nil
    GENV.PetESPSpyHandler = nil
    pcall(function() RunService:UnbindFromRenderStep(AIM_BIND) end)
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    for m in pairs(espFolder) do clearESP(m) end
    for m in pairs(highlightFolder) do clearESP(m) end
    if ScreenGui then pcall(function() ScreenGui:Destroy() end) end
    if GENV.PetESPHubCleanup == shutdown then GENV.PetESPHubCleanup = nil end
    print("[PetESP v8.3] SHUTDOWN - all logic stopped, GUI removed")
end
GENV.PetESPHubCleanup = shutdown

ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "PetESPHubV8"
ScreenGui.DisplayOrder = 999
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local parented = false
if gethui then parented = (pcall(function() ScreenGui.Parent = gethui() end)) and ScreenGui.Parent ~= nil end
if not parented then pcall(function() ScreenGui.Parent = game:GetService("CoreGui") end) end
if not ScreenGui.Parent then ScreenGui.Parent = PlayerGui end

local MainFrame = Instance.new("Frame")
MainFrame.Size = UDim2.new(0, 240, 0, 444)
MainFrame.Position = UDim2.new(0, 10, 0, 10)
MainFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true
MainFrame.Parent = ScreenGui
Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 12)

local Stroke = Instance.new("UIStroke")
Stroke.Thickness = 1.8
Stroke.Color = Color3.fromRGB(0, 255, 140)
Stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
Stroke.Parent = MainFrame

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -64, 0, 32)
Title.Position = UDim2.new(0, 10, 0, 0)
Title.BackgroundTransparency = 1
Title.Text = "PET ESP HUB v8.3 FIXED"
Title.TextColor3 = Color3.fromRGB(0, 255, 140)
Title.TextSize = 14
Title.Font = Enum.Font.GothamBold
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = MainFrame

local MobileLabel = Instance.new("TextLabel")
MobileLabel.Size = UDim2.new(1, -20, 0, 16)
MobileLabel.Position = UDim2.new(0, 10, 0, 32)
MobileLabel.BackgroundTransparency = 1
MobileLabel.Text = IS_MOBILE and "MOBILE MODE: CAMERA AIM" or "PC MODE: CLICK TO SHOOT"
MobileLabel.TextColor3 = Color3.fromRGB(255, 200, 0)
MobileLabel.TextSize = 10
MobileLabel.Font = Enum.Font.GothamMedium
MobileLabel.TextXAlignment = Enum.TextXAlignment.Left
MobileLabel.Parent = MainFrame

local function makeToggle(y, text, default, callback)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -20, 0, 30)
    btn.Position = UDim2.new(0, 10, 0, y)
    btn.BackgroundColor3 = default and Color3.fromRGB(0, 150, 80) or Color3.fromRGB(50, 50, 55)
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.TextSize = 12
    btn.Font = Enum.Font.GothamSemibold
    btn.Text = text .. (default and " : ON" or " : OFF")
    btn.Parent = MainFrame
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
    
    local s = Instance.new("UIStroke")
    s.Thickness = 1
    s.Color = Color3.fromRGB(255,255,255)
    s.Transparency = 0.8
    s.Parent = btn

    local state = default
    btn.Activated:Connect(function()
        state = not state
        btn.BackgroundColor3 = state and Color3.fromRGB(0, 150, 80) or Color3.fromRGB(50, 50, 55)
        btn.Text = text .. (state and " : ON" or " : OFF")
        callback(state)
    end)
    return btn
end

makeToggle(55,  "ESP ENABLED", CONFIG.ESP_ENABLED,  function(v) CONFIG.ESP_ENABLED = v end)
makeToggle(90,  "AUTO-AIM LOCK", CONFIG.AUTO_AIM, function(v) CONFIG.AUTO_AIM = v end)
makeToggle(125, "AUTO-COLLECT WILD", CONFIG.AUTO_COLLECT, function(v) CONFIG.AUTO_COLLECT = v end)
makeToggle(160, "MINIGAME TAP", CONFIG.MINIGAME, function(v) CONFIG.MINIGAME = v end)
makeToggle(195, "LOW LAG MODE", CONFIG.LOW_LAG, function(v)
    CONFIG.LOW_LAG = v
    CONFIG.TOP_N = v and 8 or 12
    print("[PetESP v8.3] LOW LAG = " .. tostring(v))
end)

local ModeBtn = Instance.new("TextButton")
ModeBtn.Size = UDim2.new(1, -20, 0, 30)
ModeBtn.Position = UDim2.new(0, 10, 0, 230)
ModeBtn.BackgroundColor3 = Color3.fromRGB(70, 40, 160)
ModeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ModeBtn.Text = "ESP: Nearest (Tap to change)"
ModeBtn.TextSize = 11
ModeBtn.Font = Enum.Font.GothamBold
ModeBtn.Parent = MainFrame
Instance.new("UICorner", ModeBtn).CornerRadius = UDim.new(0, 8)
ModeBtn.Activated:Connect(function()
    if CONFIG.ESP_MODE == "Nearest" then
        CONFIG.ESP_MODE = "Value"
        ModeBtn.Text = "ESP: Highest Value"
    else
        CONFIG.ESP_MODE = "Nearest"
        ModeBtn.Text = "ESP: Nearest"
    end
end)

local BuyBtn = makeToggle(265, "AUTO-BUY DARTS", CONFIG.AUTO_BUY_DARTS, function(v)
    CONFIG.AUTO_BUY_DARTS = v
    if v then
        local ok, res = remoteBuyAllDarts()
        print("[PetESP v8.3] BUY -> " .. (ok and "OK" or "FAIL"))
        lastBuy = tick()
    end
end)

local StatusPill = Instance.new("Frame")
StatusPill.Size = UDim2.new(1, -20, 0, 44)
StatusPill.Position = UDim2.new(0, 10, 0, 300)
StatusPill.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
StatusPill.Parent = MainFrame
Instance.new("UICorner", StatusPill).CornerRadius = UDim.new(0, 8)
local sps = Instance.new("UIStroke")
sps.Thickness = 1
sps.Color = Color3.fromRGB(255,255,255)
sps.Transparency = 0.9
sps.Parent = StatusPill

statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -10, 1, 0)
statusLabel.Position = UDim2.new(0, 5, 0, 0)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
statusLabel.TextSize = 9
statusLabel.Font = Enum.Font.Code
statusLabel.Text = "Scanning..."
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextWrapped = true
statusLabel.Parent = StatusPill

local TestBtn = Instance.new("TextButton")
TestBtn.Size = UDim2.new(1, -20, 0, 30)
TestBtn.Position = UDim2.new(0, 10, 0, 352)
TestBtn.BackgroundColor3 = Color3.fromRGB(40, 90, 255)
TestBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
TestBtn.Text = "DEBUG / SELF-TEST"
TestBtn.TextSize = 12
TestBtn.Font = Enum.Font.GothamBold
TestBtn.Parent = MainFrame
Instance.new("UICorner", TestBtn).CornerRadius = UDim.new(0, 8)

local WeaponLabel = Instance.new("TextLabel")
WeaponLabel.Size = UDim2.new(1, -20, 0, 16)
WeaponLabel.Position = UDim2.new(0, 10, 0, 420)
WeaponLabel.BackgroundTransparency = 1
WeaponLabel.Text = "WEAPON: " .. CONFIG.WEAPON_NAME .. " | SLEEP: " .. CONFIG.SLEEP_DART
WeaponLabel.TextColor3 = Color3.fromRGB(160, 200, 255)
WeaponLabel.TextSize = 9
WeaponLabel.Font = Enum.Font.Code
WeaponLabel.TextXAlignment = Enum.TextXAlignment.Left
WeaponLabel.Parent = MainFrame

local function makeSmall(x, text, kind)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 68, 0, 24)
    b.Position = UDim2.new(0, x, 0, 388)
    b.BackgroundColor3 = Color3.fromRGB(120, 70, 20)
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.Text = text
    b.TextSize = 9
    b.Font = Enum.Font.GothamBold
    b.Parent = MainFrame
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    b.Activated:Connect(function() if armLearn then armLearn(kind) end end)
end
makeSmall(10, "LEARN FILL", "fill")
makeSmall(86, "LEARN SLEEP", "sleep")
makeSmall(162, "LEARN SCOPE", "scope")

TestBtn.Activated:Connect(function()
    updateFreeToCatch()
    cachedPets = scanZonesFast()
    lastScan = tick()
    print("[PetESP v8.3] SCAN=" .. #cachedPets .. " | FTC=" .. tostring(freeToCatchName))
    if debugDump then pcall(debugDump) end
end)

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 24, 0, 24)
CloseBtn.Position = UDim2.new(1, -30, 0, 4)
CloseBtn.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.Text = "X"
CloseBtn.TextSize = 14
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.Parent = MainFrame
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0, 6)
CloseBtn.Activated:Connect(shutdown)   -- X = stop EVERYTHING and remove the GUI

local MiniBtn = Instance.new("TextButton")
MiniBtn.Size = UDim2.new(0, 24, 0, 24)
MiniBtn.Position = UDim2.new(1, -58, 0, 4)
MiniBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 75)
MiniBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
MiniBtn.Text = "-"
MiniBtn.TextSize = 16
MiniBtn.Font = Enum.Font.GothamBold
MiniBtn.Parent = MainFrame
Instance.new("UICorner", MiniBtn).CornerRadius = UDim.new(0, 6)

-- Small bubble that brings the panel back (logic keeps running while hidden)
local OpenBtn = Instance.new("TextButton")
OpenBtn.Size = UDim2.new(0, 46, 0, 46)
OpenBtn.Position = UDim2.new(0, 10, 0, 10)
OpenBtn.BackgroundColor3 = Color3.fromRGB(0, 150, 80)
OpenBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
OpenBtn.Text = "PET"
OpenBtn.TextSize = 13
OpenBtn.Font = Enum.Font.GothamBold
OpenBtn.Active = true
OpenBtn.Visible = false
OpenBtn.Parent = ScreenGui
Instance.new("UICorner", OpenBtn).CornerRadius = UDim.new(1, 0)

local function showPanel(show)
    if show then MainFrame.Position = OpenBtn.Position else OpenBtn.Position = MainFrame.Position end
    MainFrame.Visible = show
    OpenBtn.Visible = not show
end
MiniBtn.Activated:Connect(function() showPanel(false) end)

-- PET bubble: own drag + tap handling (a Draggable button can swallow the tap and never reopen)
do
    local dragging, moved, startInput, startPos = false, false, nil, nil
    local function isPointer(i)
        return i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch
    end
    table.insert(connections, OpenBtn.InputBegan:Connect(function(input)
        if isPointer(input) then
            dragging, moved = true, false
            startInput, startPos = input.Position, OpenBtn.Position
        end
    end))
    table.insert(connections, UserInput.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - startInput
            if delta.Magnitude > 6 then moved = true end
            if moved then
                OpenBtn.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
                                             startPos.Y.Scale, startPos.Y.Offset + delta.Y)
            end
        end
    end))
    table.insert(connections, UserInput.InputEnded:Connect(function(input)
        if dragging and isPointer(input) then
            dragging = false
            if not moved then showPanel(true) end
        end
    end))
end
-- RightShift also toggles the panel (PC)
table.insert(connections, UserInput.InputBegan:Connect(function(input, gp)
    if not gp and input.KeyCode == Enum.KeyCode.RightShift then showPanel(not MainFrame.Visible) end
end))

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

local function isShown(g)
    local p = g
    while p and p ~= game do
        if p:IsA("GuiObject") and not p.Visible then return false end
        if p:IsA("ScreenGui") then return p.Enabled end
        p = p.Parent
    end
    return true
end

-- Find a button by keywords in its name / own text / any text label inside it (PlayerGui only)
local function buttonLabel(d)
    local str = tostring(d.Name or "")
    if d:IsA("TextButton") then str = str .. " " .. tostring(d.Text or "") end
    return str:lower()
end

local function findButton(keywords, excludeOwn)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil end
    local function skip(d) return excludeOwn and ScreenGui and d:IsDescendantOf(ScreenGui) end
    local function matches(str)
        for _, kw in ipairs(keywords) do
            if str:find(kw, 1, true) then return true end
        end
        return false
    end
    local all = pg:GetDescendants()
    -- pass 1: real buttons
    for _, d in ipairs(all) do
        if d:IsA("GuiButton") and d.Visible and d.AbsoluteSize.X > 5 and isShown(d) and not skip(d) then
            if matches(buttonLabel(d)) then return d end
            for _, k in ipairs(d:GetDescendants()) do
                if k:IsA("TextLabel") and k.Text ~= "" and matches(k.Text:lower()) then return d end
            end
        end
    end
    -- pass 2: a button drawn as Frame + label: click where the label is
    for _, d in ipairs(all) do
        if d:IsA("TextLabel") and d.Visible and d.AbsoluteSize.X > 5 and d.Text ~= "" and isShown(d) and not skip(d) then
            if matches(d.Text:lower()) then return d:FindFirstAncestorWhichIsA("GuiButton") or d end
        end
    end
    return nil
end

local GuiService = game:GetService("GuiService")

-- A real mouse/touch click at the middle of the button (corrected for the top-bar inset)
local function realClick(btn)
    local pos = btn.AbsolutePosition + btn.AbsoluteSize / 2
    local sg = btn:FindFirstAncestorWhichIsA("ScreenGui")
    local inset = (sg and sg.IgnoreGuiInset) and Vector2.new(0, 0) or GuiService:GetGuiInset()
    local x, y = pos.X + inset.X, pos.Y + inset.Y
    local ok = pcall(function()
        VIM:SendMouseMoveEvent(x, y, game)
        task.wait(0.03)
        VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
        task.wait(0.06)
        VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
    end)
    if IS_MOBILE then
        pcall(function()
            VIM:SendTouchEvent(0, 0, x, y)
            task.wait(0.05)
            VIM:SendTouchEvent(0, 2, x, y)
        end)
    end
    return ok
end

-- Fire the button's own signals (works when real input is blocked)
local function signalClick(btn)
    local fired = false
    if firesignal then
        for _, sig in ipairs({"MouseButton1Down", "MouseButton1Click", "Activated", "MouseButton1Up"}) do
            if pcall(function() firesignal(btn[sig]) end) then fired = true end
        end
    end
    return fired
end

-- only = "real" | "signal" | nil (real click first, signals only if the click errored)
local function tapButton(btn, only)
    if not btn then return false end
    local okReal, okSig = false, false
    if only ~= "signal" then okReal = realClick(btn) end
    if only == "signal" or (only == nil and not okReal) then okSig = signalClick(btn) end
    return okReal or okSig
end

local shootCache, shootCacheT = nil, 0
local function findShootButton()
    if shootCache and shootCache.Parent and shootCache.Visible and isShown(shootCache) then return shootCache end
    shootCache = nil
    if tick() - shootCacheT < 0.4 then return nil end
    shootCacheT = tick()
    shootCache = findButton({"shoot"}, true)
    return shootCache
end

local function findCatchButton()
    return findButton({"catch", "collect", "tame"}, true)
end

local function tryCollectPet(pet)
    local center = getPetCenter(pet)
    if center then teleportTo(center) task.wait(0.5) end
    if not RUNNING then return end

    -- 1) Mobile catch button
    local catchBtn = findCatchButton()
    if catchBtn then
        print("[PetESP v8.3] Tapping Catch for " .. getPetName(pet))
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
        print("[PetESP v8.3] Minigame tapped " .. tapped)
    end
end

--------------------------------------------------------------------------------
-- AIM LOCK + AUTO-SCOPE + FIRE
--  * Camera lock: bound AFTER the game's camera script (Camera priority + 1) so it is
--    not overwritten, and it never yields (render-step callbacks must not yield).
--  * Scope + firing run in their own thread. The Fire direction goes from your camera
--    position straight to the animal, independent of where the camera is pointing.
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

-- Which dart names does the game use? Best-effort lookup (printed so you can verify).
local fillDart = "Magma"
local learned = {}
local learnArm, learnArmedAt = nil, 0
local learnedScopePath = nil
local LEARN_FILE = "PetESP_learned.json"
local HttpService = game:GetService("HttpService")

local function updateWeaponLabel()
    WeaponLabel.Text = "W:" .. tostring(CONFIG.WEAPON_NAME) .. " FILL:" .. tostring(fillDart)
        .. " SLEEP:" .. tostring(CONFIG.SLEEP_DART)
end

local function saveLearned()
    if not writefile then return end
    pcall(function() writefile(LEARN_FILE, HttpService:JSONEncode(learned)) end)
end

local function loadLearned()
    if not (isfile and readfile) then return end
    pcall(function()
        if isfile(LEARN_FILE) then
            local data = HttpService:JSONDecode(readfile(LEARN_FILE))
            if type(data) == "table" then
                learned = data
                if learned.weapon then CONFIG.WEAPON_NAME = learned.weapon end
                if learned.fill then fillDart = learned.fill end
                if learned.sleep then CONFIG.SLEEP_DART = learned.sleep end
                learnedScopePath = learned.scope
                print("[PetESP v8.3] loaded learned settings from " .. LEARN_FILE)
            end
        end
    end)
end
loadLearned()

local function resolveDarts()
    local function names(keyword)
        local out, seen = {}, {}
        for _, d in ipairs(RepStorage:GetDescendants()) do
            if not d:FindFirstAncestor("Remotes") and d.Name:lower():find(keyword, 1, true) and not seen[d.Name] then
                seen[d.Name] = true
                table.insert(out, d.Name)
            end
        end
        return out
    end
    local magma, abyss = names("magma"), names("abyss")
    print("[PetESP v8.3] magma candidates: " .. (#magma > 0 and table.concat(magma, ", ") or "none")
        .. " | abyss candidates: " .. (#abyss > 0 and table.concat(abyss, ", ") or "none"))
    if learned.fill then
        fillDart = learned.fill
    elseif tostring(CONFIG.FILL_DART):lower() ~= "auto" then
        fillDart = CONFIG.FILL_DART
    elseif #magma > 0 then
        fillDart = magma[1]
    end
    print("[PetESP v8.3] fill dart = " .. tostring(fillDart) .. " | sleep dart = " .. tostring(CONFIG.SLEEP_DART))
    updateWeaponLabel()
end
task.spawn(function() pcall(resolveDarts) end)

-- LEARN mode: record what the game itself does when YOU use it once.
local function onRemoteCalled(remote, method, args)
    if not learnArm then return end
    if tick() - learnArmedAt > 60 then learnArm = nil return end
    if not (remote.Parent and remote.Parent.Name == "Remotes") then return end
    local parts = {}
    for i = 1, args.n do
        local a = args[i]
        parts[i] = (typeof(a) == "Instance") and a:GetFullName() or tostring(a)
    end
    print("[PetESP SPY] " .. remote.Name .. ":" .. method .. "(" .. table.concat(parts, ", ") .. ")")
    if remote.Name == "Fire" and (learnArm == "fill" or learnArm == "sleep") and type(args[2]) == "string" then
        if type(args[1]) == "string" then CONFIG.WEAPON_NAME = args[1]; learned.weapon = args[1] end
        if learnArm == "fill" then
            fillDart = args[2]; learned.fill = args[2]
        else
            CONFIG.SLEEP_DART = args[2]; learned.sleep = args[2]
        end
        print("[PetESP v8.3] LEARNED " .. learnArm .. " dart = " .. args[2] .. " | weapon = " .. tostring(args[1]))
        learnArm = nil
        saveLearned()
        updateWeaponLabel()
    end
end

local function installSpy()
    GENV.PetESPSpyHandler = onRemoteCalled
    if GENV.PetESPSpyInstalled then return true end
    if not (hookmetamethod and getnamecallmethod) then return false end
    local old
    local wrap = newcclosure or function(f) return f end
    local ok = pcall(function()
        old = hookmetamethod(game, "__namecall", wrap(function(self, ...)
            local m = getnamecallmethod()
            if (m == "FireServer" or m == "InvokeServer") and GENV.PetESPSpyHandler
               and not (checkcaller and checkcaller()) then
                local h, args, rem = GENV.PetESPSpyHandler, table.pack(...), self
                task.spawn(function() pcall(h, rem, m, args) end)
            end
            return old(self, ...)
        end))
    end)
    if ok then GENV.PetESPSpyInstalled = true end
    return ok
end

-- LEARN SCOPE: remember the GUI object under your next click
table.insert(connections, UserInput.InputBegan:Connect(function(input)
    if learnArm ~= "scope" then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    local objs = pg:GetGuiObjectsAtPosition(input.Position.X, input.Position.Y)
    if #objs == 0 then
        local m = UserInput:GetMouseLocation()
        local inset = GuiService:GetGuiInset()
        objs = pg:GetGuiObjectsAtPosition(m.X - inset.X, m.Y - inset.Y)
    end
    local pick
    for _, o in ipairs(objs) do
        if not pick and o:IsA("GuiButton") then pick = o end
    end
    pick = pick or objs[1]
    if pick then
        local full = pick:GetFullName()
        local rel = full:match("PlayerGui%.(.+)$")
        if rel then
            learnedScopePath = rel; learned.scope = rel; learnArm = nil
            saveLearned()
            print("[PetESP v8.3] LEARNED scope button = " .. full .. " (" .. pick.ClassName .. ")")
        end
    end
end))

armLearn = function(kind)
    learnArm, learnArmedAt = kind, tick()
    local hooked = installSpy()
    if kind == "scope" then
        print("[PetESP v8.3] LEARN SCOPE armed: click the real Scope button ONCE now (60s)")
    else
        print("[PetESP v8.3] LEARN " .. kind:upper() .. " armed: scope in and shoot ONCE with the "
            .. (kind == "fill" and "FILL dart (Magma)" or "SLEEP dart (Abyss)") .. " (60s)")
        if not hooked then print("[PetESP v8.3] this executor cannot hook remotes (hookmetamethod missing) - set the dart names in CONFIG by hand") end
    end
end

-- Dots above an animal's head (best effort): how many hit circles it has
local function countHitDots(pet)
    local best = nil
    for _, g in ipairs(pet:GetDescendants()) do
        if g:IsA("BillboardGui") then
            for _, c in ipairs(g:GetDescendants()) do
                local n, sz = 0, nil
                for _, k in ipairs(c:GetChildren()) do
                    if (k:IsA("Frame") or k:IsA("ImageLabel")) and k.Visible then
                        local a = k.AbsoluteSize
                        if a.X > 2 and math.abs(a.X - a.Y) <= 2 then
                            sz = sz or a.X
                            if math.abs(a.X - sz) <= 2 then n = n + 1 end
                        end
                    end
                end
                if n >= 3 and n <= 15 and (not best or n > best) then best = n end
            end
        end
    end
    return best
end

-- fill shots needed = total circles - 1 (the last hit is the sleep dart)
local function fillShotsFor(pet)
    for _, k in ipairs({"MaxHits", "HitsNeeded", "DartsNeeded", "MaxDarts", "RequiredHits"}) do
        local v = getAttr(pet, k)
        if type(v) == "number" and v > 0 then return math.max(0, v - 1) end
    end
    local dots = countHitDots(pet)
    if dots then return math.max(0, dots - 1) end
    return CONFIG.FILL_SHOTS
end

local function waitAimUi(seconds)
    local t0 = tick()
    while tick() - t0 < seconds do
        if findShootButton() then return true end
        task.wait(0.1)
        if not RUNNING then return false end
    end
    return false
end

local function resolveScopeButton()
    if not learnedScopePath then return nil end
    local cur = LocalPlayer:FindFirstChild("PlayerGui")
    for seg in learnedScopePath:gmatch("[^%.]+") do
        cur = cur and cur:FindFirstChild(seg)
    end
    if cur and cur:IsA("GuiObject") and isShown(cur) then return cur end
    return nil
end

-- Auto-scope: click the Scope button (learned one first). Each method is verified by the SHOOT
-- button showing up, so we never click twice and toggle the scope back off.
local function autoScope()
    if findShootButton() then return true end
    local b = resolveScopeButton() or findButton({"scope"}, true)
    if b then
        print("[PetESP v8.3] scope button: " .. b:GetFullName())
        tapButton(b, "real")
        if waitAimUi(1.0) then return true end
        tapButton(b, "signal")
        if waitAimUi(1.0) then return true end
    else
        print("[PetESP v8.3] scope button not found - press LEARN SCOPE and click it once")
    end
    enterAimMode(true)
    local ok = waitAimUi(1.5)
    if not ok then print("[PetESP v8.3] scope did not open, or the SHOOT button was not detected") end
    return ok
end

RunService:BindToRenderStep(AIM_BIND, Enum.RenderPriority.Camera.Value + 1, function()
    if not RUNNING or not CONFIG.AUTO_AIM then return end
    local target = lockTarget
    if not (target and target.Parent) then return end
    local cam = Workspace.CurrentCamera
    local center = getPetCenter(target)
    if not (cam and center) then return end
    local want = CFrame.lookAt(cam.CFrame.Position, center)
    if CONFIG.AIM_LOCK then
        cam.CFrame = cam.CFrame:Lerp(want, CONFIG.AIM_LOCK_ALPHA)
    else
        cam.CFrame = want
    end
end)

-- Sequence per animal: go to the aim spot -> open scope -> fill circles with the cheap dart
-- -> finish with the sleep dart (Abyss) -> animal goes down -> main loop collects it.
task.spawn(function()
    local scopedFor = nil
    local scopeTriedAt = 0
    local shots = setmetatable({}, {__mode = "k"})
    local lastSleepShot = 0
    while RUNNING do
        task.wait(CONFIG.FIRE_INTERVAL)
        local ok, err = pcall(function()
            if not (RUNNING and CONFIG.AUTO_AIM) or collecting then scopedFor = nil return end
            local target = lockTarget
            if not (target and target.Parent) then scopedFor = nil return end
            local center = getPetCenter(target)
            if not center then return end

            -- 1) stand on the aim spot
            if CONFIG.FORCE_AIM_SPOT and (getPlayerPos() - CONFIG.AIM_POS).Magnitude > 15 then
                teleportTo(CONFIG.AIM_POS)
                task.wait(0.5)
                scopedFor = nil
                if not RUNNING or collecting then return end
            end

            -- 2) open the scope (once per target, or again if the aim screen closed)
            if CONFIG.AUTO_SCOPE and (scopedFor ~= target
               or (tick() - scopeTriedAt > 6 and not findShootButton())) then
                scopeTriedAt = tick()
                autoScope()
                scopedFor = target
                if not RUNNING or collecting or lockTarget ~= target then return end
            end

            -- 3) pick the dart: fill circles first, sleep dart last
            local n = shots[target] or 0
            local dart
            if n < fillShotsFor(target) then
                dart = fillDart
            else
                if tick() - lastSleepShot < CONFIG.SLEEP_RETRY then return end
                dart = CONFIG.SLEEP_DART
                lastSleepShot = tick()
            end

            local fired = false
            if CONFIG.USE_REMOTE_FIRE then fired = remoteFireAt(center, dart) end
            if fired then
                shots[target] = n + 1
                lastShotTarget = target
            else
                local btn = findShootButton()      -- fallback: tap SHOOT (uses the equipped dart)
                if btn then tapButton(btn); lastShotTarget = target else clickCenter() end
            end
        end)
        if not ok then print("[PetESP v8.3] aim/fire error: " .. tostring(err)) end
    end
end)

-- DEBUG button output: paste this in chat if something misbehaves
debugDump = function()
    local function nm(i) return i and i:GetFullName() or "none" end
    print("[PetESP v8.3] ---- DEBUG ----")
    local lp = 0
    for _ in pairs(labelPets) do lp = lp + 1 end
    print("world=" .. tostring(currentWorldName) .. " pets=" .. #cachedPets .. " labelPets=" .. lp
        .. " FTC=" .. tostring(freeToCatchName))
    print("sleepDart=" .. tostring(CONFIG.SLEEP_DART) .. " fillDart=" .. tostring(fillDart))
    print("scopeButton=" .. nm(findButton({"scope"}, true)) .. " | shootButton=" .. nm(findShootButton()))
    local me = getPlayerPos()
    local nearest, nd = nil, math.huge
    for _, p in ipairs(cachedPets) do
        local c = p.Parent and getPetCenter(p)
        if c then
            local d = (c - me).Magnitude
            if d < nd then nearest, nd = p, d end
        end
    end
    if nearest then
        print("nearest=" .. nearest:GetFullName() .. " dist=" .. math.floor(nd)
            .. " downed=" .. tostring(isDowned(nearest)) .. " hitDots=" .. tostring(countHitDots(nearest))
            .. " native=" .. tostring(nativeInfo(nearest) and nativeInfo(nearest).text))
        local okA, attrs = pcall(function() return nearest:GetAttributes() end)
        if okA then for k, v in pairs(attrs) do print("  attr " .. k .. " = " .. tostring(v)) end end
    end
    pcall(resolveDarts)
end

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------
task.spawn(function()
    while RUNNING do
        local interval = CONFIG.LOW_LAG and 0.5 or CONFIG.ESP_INTERVAL
        task.wait(interval)

        local ok, err = pcall(function()
            if not RUNNING then return end
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
                        if not isOwnedPet(pet) and not isInBase(center) then
                            if downed then table.insert(downedList, pet) end
                            table.insert(espCandidates, pet)
                            if not downed and isWildAnimal(pet) then table.insert(aimCandidates, pet) end
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
            -- Pick the lock target: in range, sticky (keep the current one while valid)
            local aimOrigin = CONFIG.FORCE_AIM_SPOT and CONFIG.AIM_POS or playerPos
            local inRange = {}
            for _, pet in ipairs(aimCandidates) do
                local c = getPetCenter(pet)
                if c and (c - aimOrigin).Magnitude <= CONFIG.AIM_MAX_DIST then
                    table.insert(inRange, pet)
                end
            end
            local pick = nil
            if lockTarget and lockTarget.Parent and table.find(inRange, lockTarget) then
                pick = lockTarget
            elseif #inRange > 0 then
                if CONFIG.AIM_PRIORITY == "Value" then
                    table.sort(inRange, function(a, b) return getPetValue(a) > getPetValue(b) end)
                else
                    table.sort(inRange, function(a, b)
                        local ca = getPetCenter(a) or Vector3.new()
                        local cb = getPetCenter(b) or Vector3.new()
                        return (ca - aimOrigin).Magnitude < (cb - aimOrigin).Magnitude
                    end)
                end
                pick = inRange[1]
            end
            lockTarget = (CONFIG.AUTO_AIM and not collecting) and pick or nil

            local topN = CONFIG.LOW_LAG and 8 or CONFIG.TOP_N
            local keep = {}

            if CONFIG.ESP_ENABLED then
                local espShow, inShow, extra = {}, {}, {}
                for _, d in ipairs(downedList) do extra[d] = true end
                if lockTarget then extra[lockTarget] = true end
                for i = 1, math.min(topN, #espCandidates) do
                    inShow[espCandidates[i]] = true
                    table.insert(espShow, espCandidates[i])
                end
                for _, pet in ipairs(espCandidates) do      -- the locked / downed animal always gets ESP
                    if extra[pet] and not inShow[pet] then table.insert(espShow, pet) end
                end
                for _, pet in ipairs(espShow) do
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
                                local ni = nativeInfo(pet)
                                local vtxt = ni and (formatValue(ni.value) .. " $/s") or ("$" .. formatValue(getPetValue(pet)))
                                newText = getPetName(pet) .. "  " .. vtxt .. "  " .. math.floor(dist) .. "m"
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
                local tn = lockTarget and getPetName(lockTarget) or "none"
                statusLabel.Text = "World: " .. tostring(currentWorldName) .. " | Pets: " .. #espCandidates .. " | Lock: " .. tn .. " | Downed: " .. #downedList
                    .. (freeToCatchName and (" | FTC: " .. freeToCatchName) or "")
            end

            -- Collect downed wild animals, then go to the base spot
            if CONFIG.AUTO_COLLECT and #downedList > 0 and not collecting
               and tick() - lastCollect >= CONFIG.COLLECT_COOLDOWN then
                local fresh = {}
                for _, pet in ipairs(downedList) do
                    local t = collectTried[pet]
                    if not t or tick() - t > 25 then table.insert(fresh, pet) end   -- no endless retry on one pet
                end
                if #fresh > 0 then
                    lastCollect = tick()
                    table.sort(fresh, function(a, b)
                        if (a == lastShotTarget) ~= (b == lastShotTarget) then return a == lastShotTarget end
                        local ca = getPetCenter(a) or Vector3.new()
                        local cb = getPetCenter(b) or Vector3.new()
                        return (ca - playerPos).Magnitude < (cb - playerPos).Magnitude
                    end)
                    local target = fresh[1]
                    collectTried[target] = tick()
                    collecting = true
                    lockTarget = nil
                    print("[PetESP v8.3] Auto-collect: " .. getPetName(target))
                    pcall(tryCollectPet, target)
                    if RUNNING and CONFIG.TP_BASE_AFTER_COLLECT then
                        task.wait(0.4)
                        teleportTo(CONFIG.BASE_POS)
                        task.wait(0.6)
                    end
                    collecting = false
                    if target == lastShotTarget then lastShotTarget = nil end
                end
            end

            -- Auto-buy darts
            if CONFIG.AUTO_BUY_DARTS and tick() - lastBuy >= CONFIG.BUY_INTERVAL then
                lastBuy = tick()
                local okBuy, resBuy = remoteBuyAllDarts()
                if not okBuy then print("[PetESP v8.3] auto-buy failed: " .. tostring(resBuy)) end
            end

            if CONFIG.MINIGAME then doMinigame() end
        end)

        if not ok then
            print("[PetESP v8.3] tick error: " .. tostring(err))
        end
    end
end)

print("[PetESP v8.3] Ready - ANY Zones, Clean ESP, Camera Aim, Auto-Collect Wild")
