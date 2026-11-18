
-- Pet ESP Hub v2 FIXED - SEPARATE from Egg Steal Hub
-- Fixes from your 3 screenshots:
--  Pic1: ESP blocking screen (big black boxes over crosshair) + ESPing pets ALREADY in base
--  Pic2: After shooting, pets go down/sleep with timer (0:06 to catch) - now auto-collect
--  Pic3: Some pets not ESPed (Pets 163 but old MAX 80 dropped 83) + auto-aim aims somewhere wrong (TOP CometPterosaur but scope shows Raptor)
--  Base = 5977,3,99 | Aim spot = 5973,3,2
-- Changes in v2:
--  1) COMPACT ESP: 140x28, TextSize 9, transparent 0.65, AlwaysOnTop OFF, hide if <25 studs, hide if behind camera, only TOP 15 + DOWNED + nearest 10 (not ALL 163)
--  2) BASE EXCLUSION: pets within 90 studs of 5977,3,99 OR inside base box X 5900-6050 Z 20-180 OR Owner==you OR IsOwned/InBase -> NEVER ESPed, NEVER aimed
--  3) DOWNED DETECTION: reads Attributes State/Downed/Sleep + TextLabel "to catch" / "0:06" timer + BoolValue Downed + Humanoid 0
--  4) AUTO-COLLECT: when ON + downed pet exists, pause aim -> TP to downed pet -> collect (Prompt/Touch/Remote) -> TP to base 5977,3,99 -> return to aim spot
--  5) AUTO-AIM FIX: use GetBoundingBox center (not feet GetPivot), aim via mouse move (WorldToViewportPoint + SendMouseMoveEvent) so game scoped camera follows mouse, DON'T rotate HRP when scoped, only shoot if crosshair within 60px of pet
--  6) MISSING PETS FIX: scan ClientPets + Pets + DownedPets + Downed + WildPets + workspace direct pets with Value/Rarity, dedupe, sort by value, ESP prioritized

-- Pet ESP Hub v2.1 FIXED - SAME AS v2, + STARTUP BANNER
-- READ THIS IF YOU SEE "ProfilerDataParser:17 attempt to iterate over a nil value" IN F9:
-- That error is from ROBLOX ITSELF: CorePackages > CoreScriptsProfiler > ProfilerDataParser
-- It is NOT from this script. This script NEVER touches CorePackages / Profiler.
-- It happens even with NO script running, just from Delta / executor injection.
-- Proof: Clear console (CLEAR button), run NOTHING, open F9 again - the same 1 error comes back.
-- If this script had an error, F9 would say "[PetESP v6] scan error:" or "[PetESP v6] tick error:" and the stack would say PetESP, NOT CoreScriptsProfiler.
-- v2.1 adds: loud LOADED print + SELF-TEST button that prints 3 test lines, so you can search "PetESP" in F9 and see it is alive.

print("[PetESP v6] ========== LOADED OK ==========")
print("[PetESP v6] If F9 shows ONLY ProfilerDataParser error, that is ROBLOX CORE, not this script. Search 'PetESP' in F9 to see this script is alive.")
print("[PetESP v6] GUI should appear top-left. If no GUI, re-press EXECUTE in Delta, do NOT run Egg Hub + Pet ESP at same time for this test.")

local CONFIG = {
    AIM_POS = Vector3.new(5973, 3, 2),
    BASE_POS = Vector3.new(5977, 3, 99),
    BASE_RADIUS = 90,
    ESP_ENABLED = true,
    ESP_MODE = "TOP", -- "TOP" (Top15+Downed+Near10), "ALL", "DOWNED"
    AUTO_AIM = false,
    AUTO_COLLECT = false,
    AUTO_MINIGAME = false,
    WORLD_FILTER = "Both",
    ESP_REFRESH = 0.3,
    AIM_COOLDOWN = 0.05,
    SHOOT_COOLDOWN = 0.6,
    MAX_ESP = 35, -- TOP 15 + Downed + Near 10 = max ~35, never 163
    COLLECT_COOLDOWN = 1.5,
    MY_DOWNED_ONLY = true,
    CurrentWorld = "Prehistoric",
    SMART_SCORE = true,
    STICKY_TARGET = true,
    ANTI_STEAL_RADIUS = 30,
    VALUE_CACHE_TTL = 1.0,
    SHOT_VERIFY_TIME = 5,
    AIR_LEAD_DIV = 1200,
    AIR_MAX_LEAD = 0.8,
    LATCH_TTL = 120,
    AIM_TOLERANCE_PX = 70,
    AIR_ANGLE_DEG = 2.5,
    GROUND_ANGLE_DEG = 2.0,
}

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local topPet = nil
local topInfo = nil
local petCount = 0
local downedCount = 0
local lastAimAt = 0
local lastShotAt = 0
local lastTarget = nil
local lastCollectAt = 0
local collectState = "IDLE"
-- v3: shot history (for MY DOWNED ONLY), downed latch (timer disappears when far), verify + blacklist, air aim state
local ShotHistory = {}
local DownedLatch = {} -- pet -> {firstSeen, lastSeen, lastPos, lastTimerSecs, expiresAt, latched, sleeperName}
local CollectBlacklist = {} -- pet -> time until retry allowed
local AirAimState = { frames = 0, lastPos = nil, lastT = 0 }
local function markShot(pet) pcall(function() if pet then ShotHistory[pet] = os.clock() end end) end -- IDLE, GOTO_DOWNED, COLLECT, TP_BASE, RETURN_AIM
local collectBusy = {}
local gui = nil
local statusLabel, statsLabel, topLabel, downedLabel, espBtn, aimSpotBtn, scopeBtn, collectBtn, worldBtn, espModeBtn, baseBtn
local toast, refreshUI
local pillGui, pill, pillLabel, pillDot

local function setStatus(text, kind)
    print("[PetESP v6]", text)
    if statusLabel then statusLabel.Text = text end
    if pillLabel then
        pillLabel.Text = text
        if pill then pill.Visible = true end
        if pillDot then pcall(function()
            local c = (kind == "ok" and C.green) or (kind == "err" and C.red) or (kind == "warn" and C.yellow) or C.blue
            pillDot.BackgroundColor3 = c
        end) end
    end
end
local function showPill() if pill then pill.Visible = true end if pillGui then pillGui.Enabled = true end end
local function hidePill() if pill then pill.Visible = false end end
local function getHRP()
    local c = player.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function worldPos(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then return inst.Position end
    local ok, cf = pcall(function() return inst:GetPivot() end)
    if ok then return cf.Position end
    return nil
end

--------------------------------------------------------------------------------
-- VALUE PARSER
--------------------------------------------------------------------------------
local SUFFIX = { K=1e3, M=1e6, B=1e9, T=1e12, QA=1e15, QI=1e18, SX=1e21, SP=1e24, OC=1e27, NO=1e30, DC=1e33, UD=1e36, DD=1e39, TD=1e42, QAD=1e45, QID=1e48, AA=1e3, AB=1e6 }
local function normalizeNumberStr(s)
    s = tostring(s or "")
    s = s:gsub("%$", ""):gsub("/s", ""):gsub("STUDS", ""):gsub("Studs", ""):gsub("%s+", "")
    if s:find(",") and not s:find("%.") then
        local afterDigits = s:match(",([%d]+)")
        if afterDigits and #afterDigits ~= 3 then s = s:gsub(",", ".") else s = s:gsub(",", "") end
    else s = s:gsub(",", "") end
    return s
end
local function parseValue(v)
    if type(v) == "number" then return v end
    if type(v) ~= "string" then return 0 end
    local s = normalizeNumberStr(v)
    if s == "" then return 0 end
    local numStr, suf = s:match("([%d%.]+)([A-Za-z]*)")
    local n = tonumber(numStr) or 0
    if not suf or suf == "" then return n end
    suf = suf:upper()
    if suf == "X" then return n end
    if SUFFIX[suf] then return n * SUFFIX[suf] end
    local two = suf:sub(1,2)
    if SUFFIX[two] then return n * SUFFIX[two] end
    local one = suf:sub(1,1)
    if SUFFIX[one] then return n * SUFFIX[one] end
    return n
end
local RARITY_COLOR = {
    Common = Color3.fromRGB(170,170,170), Rare = Color3.fromRGB(0,170,255), Epic = Color3.fromRGB(170,0,255),
    Legendary = Color3.fromRGB(255,170,0), Mythic = Color3.fromRGB(255,0,200), Divine = Color3.fromRGB(0,255,170),
    Secret = Color3.fromRGB(255,0,0), Shiny = Color3.fromRGB(255,255,0),
}
local function rarityColor(rarity)
    for k,c in pairs(RARITY_COLOR) do if tostring(rarity or ""):lower():find(k:lower(),1,true) then return c end end
    return Color3.fromRGB(255,255,255)
end

--------------------------------------------------------------------------------
-- BASE EXCLUSION - Pic1 fix: never ESP/aim pets already in base / owned
--------------------------------------------------------------------------------
local function isOwnedByMe(pet)
    local ok, v = pcall(function() return pet:GetAttribute("IsOwned") or pet:GetAttribute("InBase") or pet:GetAttribute("Owned") end)
    if ok and v == true then return true end
    for _, n in ipairs({"Owned","IsOwned"}) do
        local b = pet:FindFirstChild(n)
        if b and b:IsA("BoolValue") and b.Value then return true end
    end
    local ok2, own = pcall(function() return pet:GetAttribute("Owner") or pet:GetAttribute("OwnerName") or pet:GetAttribute("OwnerId") end)
    if ok2 and own ~= nil then return tostring(own) == player.Name or tostring(own) == tostring(player.UserId) end
    return false
end
local function isInBase(pet)
    if isOwnedByMe(pet) then return true end
    local pos = nil
    pcall(function() pos = worldPos(pet) end)
    if not pos then return false end
    local inBox = pos.X >= 5900 and pos.X <= 6050 and pos.Z >= 20 and pos.Z <= 180
    local inRadius = (pos - CONFIG.BASE_POS).Magnitude < CONFIG.BASE_RADIUS
    if not (inBox or inRadius) then return false end
    -- Inside base area: only exclude if owned by you, OR deep inside the base box
    if isOwnedByMe(pet) then return true end
    if inBox then return true end
    return false
end

--------------------------------------------------------------------------------
-- PET CENTER - FIX: GetBoundingBox center, not feet GetPivot
--------------------------------------------------------------------------------
local function getPetCenter(pet)
    local ok, cf = pcall(function() return pet:GetBoundingBox() end)
    if ok and cf then return cf.Position end
    local ok2, pv = pcall(function() return pet:GetPivot() end)
    if ok2 then return pv.Position end
    local part = pet:IsA("Model") and (pet.PrimaryPart or pet:FindFirstChildWhichIsA("BasePart", true)) or nil
    if part then return part.Position end
    return Vector3.zero
end
local function getPetPos(pet) return getPetCenter(pet) end

--------------------------------------------------------------------------------
-- DOWNED / SLEEP DETECTION - Pic2/Pic3 fix: timer 0:06 to catch
--------------------------------------------------------------------------------
local function parseTimerToSecs(str)
    if not str then return nil end
    local m, s = tostring(str):match("(%d+):(%d+)")
    if m then return tonumber(m)*60 + tonumber(s) end
    return nil
end
-- Returns isDowned, timeLeftStr, secsLeft
local function isDowned(pet)
    local found, txt, secs = false, "", nil
    pcall(function()
        -- Attributes: State/Status/Downed/IsDowned/Knocked/Sleeping/Capturable/CanCatch
        for k, v in pairs(pet:GetAttributes()) do
            local lk = k:lower()
            if lk:find("down") or lk:find("sleep") or lk:find("knock") or lk:find("catch") or lk:find("captur") then
                if v == true then found = true; txt = k; secs = 999; break end
                if type(v) == "string" and (v:lower():find("down") or v:lower():find("sleep") or v:lower():find("catch")) then
                    found = true; txt = v; secs = parseTimerToSecs(v) or 999; break
                end
                if type(v) == "number" and lk:find("time") and v > 0 then found = true; txt = string.format("0:%02d", math.floor(v)); secs = v; break end
            end
            if lk == "state" or lk == "status" then
                local ls = tostring(v):lower()
                if ls:find("down") or ls:find("sleep") or ls:find("knock") or ls:find("catch") or ls:find("stun") then found = true; txt = tostring(v); secs = parseTimerToSecs(tostring(v)) or 999; break end
            end
        end
        if found then return end
        -- Descendants: TextLabel with "to catch" / timer / DOWN / SLEEP, BoolValue Downed
        for _, d in ipairs(pet:GetDescendants()) do
            if d:IsA("TextLabel") or d:IsA("TextButton") then
                local t = d.Text or ""
                local lt = t:lower()
                if lt:find("to catch") or lt:find("catch") or lt:find("down") or lt:find("sleep") then
                    local timer = t:match("%d+:%d+")
                    found = true; txt = timer or t; secs = parseTimerToSecs(timer) or 999; break
                end
                -- Bare timer like "0:06" on its own label (Pic3 shows 0:06 big)
                local onlyTimer = t:match("^%s*(%d+:%d+)%s*$")
                if onlyTimer then found = true; txt = onlyTimer; secs = parseTimerToSecs(onlyTimer) or 999; break end
            elseif (d:IsA("BoolValue") or d:IsA("StringValue")) and (d.Name:lower():find("down") or d.Name:lower():find("sleep") or d.Name:lower():find("catch")) then
                if d.Value == true or (type(d.Value)=="string" and d.Value ~= "") then found = true; txt = tostring(d.Value); secs = parseTimerToSecs(tostring(d.Value)) or 999; break end
            end
        end
        if found then return end
        local h = pet:FindFirstChildOfClass("Humanoid")
        if h and h.Health <= 0 then found = true; txt = "0:00"; secs = 0; return end
        if pet.Name:lower():find("downed") then found = true; txt = ""; secs = 999; return end
    end)
    return found, txt, secs
end

--------------------------------------------------------------------------------
-- v3 HELPERS: AIR AIM, SLEEPER PARSE, MY DOWNED ONLY, LATCH
--------------------------------------------------------------------------------
local AIR_NAMES = {"Pterosaur","Quetzal","Bird","Phoenix","Archaeopteryx","Microraptor","Rhamphorhynchus","Pterodactyl","Eagle","Falcon","Dragon"}
local function isAirPet(pet)
    local ok, r = pcall(function()
        if pet:GetAttribute("Flying") or pet:GetAttribute("IsFlying") then return true end
        for _, n in ipairs(AIR_NAMES) do if pet.Name:find(n) then return true end end
        local pp = pet:IsA("Model") and (pet.PrimaryPart or pet:FindFirstChild("HumanoidRootPart")) or nil
        if pp and pp.AssemblyLinearVelocity.Magnitude > 15 then return true end
        -- Y above ground: use pet Y vs aim spot Y (aim is ground level 3). If pet is >18 above aim ground, treat as air.
        if pp and (pp.Position.Y - 3) > 18 then return true end
        -- Fallback: bounding box center Y high
        local c = getPetCenter(pet)
        if c and (c.Y - 3) > 20 then return true end
        return false
    end)
    return ok and r or false
end
-- v3: aim point with lead for moving / flying pets. Uses PrimaryPart/Head/HRP, NOT wingspan bounding box.
local function getAimPoint(pet, camPos)
    local ok, pt = pcall(function()
        local pp = pet:IsA("Model") and (pet.PrimaryPart or pet:FindFirstChild("Head") or pet:FindFirstChild("HumanoidRootPart")) or nil
        local base = nil
        if pp then base = pp.Position else base = getPetCenter(pet) end
        local vel = Vector3.zero
        if pp then vel = pp.AssemblyLinearVelocity end
        -- If anchored / velocity 0, estimate from last positions
        if vel.Magnitude < 0.1 and AirAimState.lastPos then
            local now = os.clock()
            local dt = math.max(now - AirAimState.lastT, 1/60)
            vel = (base - AirAimState.lastPos) / dt
            if vel.Magnitude > 60 then vel = Vector3.zero end -- teleport spike, ignore
        end
        AirAimState.lastPos = base
        AirAimState.lastT = os.clock()
        local dist = camPos and (base - camPos).Magnitude or 1000
        local lead = math.clamp(dist / CONFIG.AIR_LEAD_DIV, 0, CONFIG.AIR_MAX_LEAD)
        -- For air pets, lead matters more. For ground pets, small lead still helps if they run.
        local isAir = isAirPet(pet)
        if not isAir then lead = math.min(lead, 0.25) end
        local up = 0
        if isAir then up = math.clamp(dist * 0.001, 0, 1.5) end
        return base + vel * lead + Vector3.new(0, up, 0), isAir, vel
    end)
    if ok then return pt end
    return getPetCenter(pet), false, Vector3.zero
end
local function parseSleeperName(text)
    if type(text) ~= "string" then return nil end
    -- "Put to sleep by Damon" / "Put to sleep by Demon" / "put to sleep by X"
    local n = text:match("[Pp]ut to sleep by%s+([%w_%.%-]+)")
    if n then return n end
    -- "Slept by Damon" / "Downed by Damon"
    local n2 = text:match("[Dd]owned by%s+([%w_%.%-]+)")
    if n2 then return n2 end
    local n3 = text:match("[Ss]leep by%s+([%w_%.%-]+)")
    if n3 then return n3 end
    return nil
end
-- v3: ONLY collect pets YOU put to sleep. Video proof: "Put to sleep by Damon" must be SKIPPED.
local function isMyDowned(pet)
    if not CONFIG.MY_DOWNED_ONLY then return true end
    if not pet then return false end
    -- 1) Attributes: if any says other player, NOT mine. If says you, mine.
    for _, k in ipairs({"DownedBy","Sleeper","PutToSleepBy","LastHitBy","Attacker","Killer","Owner","CatchableBy","ClaimableBy","SleptBy"}) do
        local ok, v = pcall(function() return pet:GetAttribute(k) end)
        if ok and v ~= nil then
            if type(v) == "userdata" then
                -- Instance (player)
                if v == player then return true else return false end
            end
            local s = tostring(v)
            if s == player.Name or tonumber(v) == player.UserId then return true end
            -- If it's a named other player in server, it's not mine. "Wild" / "" / "None" are not players, ignore.
            if s ~= "" and s ~= "Wild" and s ~= "None" then
                local other = Players:FindFirstChild(s)
                if other and other ~= player then return false end
            end
        end
    end
    -- 2) TextLabel "Put to sleep by <Name>"
    local okDesc, desc = pcall(function() return pet:GetDescendants() end)
    if okDesc and desc then
        for _, o in ipairs(desc) do
            if o:IsA("TextLabel") or o:IsA("TextButton") then
                local n = parseSleeperName(o.Text or "")
                if n then
                    -- Store for latch / debug
                    return n:lower() == player.Name:lower()
                end
            end
        end
    end
    -- 3) Latch sleeper name if we saw it before
    local latch = DownedLatch[pet]
    if latch and latch.sleeperName then
        return latch.sleeperName:lower() == player.Name:lower()
    end
    -- 4) No ownership info: fallback to shot history - only if WE shot it in last 30s
    local t = ShotHistory[pet]
    if t and os.clock() - t <= 30 then return true end
    return false
end
local function updateDownedLatch(pet, downed, timerStr, secs)
    local now = os.clock()
    local pos = getPetCenter(pet)
    -- Capture sleeper name for later (timer may disappear, but sleeper stays in latch)
    local sleeper = nil
    pcall(function()
        for _, d in ipairs(pet:GetDescendants()) do
            if d:IsA("TextLabel") then local n = parseSleeperName(d.Text or "") if n then sleeper = n break end end
        end
    end)
    local e = DownedLatch[pet]
    if downed then
        if not e then e = { firstSeen = now } DownedLatch[pet] = e end
        e.lastSeen = now
        e.lastPos = pos
        if secs then e.lastTimerSecs = secs end
        if timerStr and timerStr ~= "" then e.lastTimerStr = timerStr end
        if sleeper then e.sleeperName = sleeper end
        e.expiresAt = now + CONFIG.LATCH_TTL
        e.latched = false
    elseif e then
        -- Timer disappeared but pet still exists - keep lastPos updated, mark latched
        e.lastPos = pos
        e.latched = true
        if sleeper then e.sleeperName = sleeper end
    end
    return e
end
-- V4 HELPERS: value cache, smart score, sticky, anti-steal, world teleport, shot verify
local ValueCache = {}
local function getPetValueCached(pet)
    local now = os.clock()
    local c = ValueCache[pet]
    if c and now - c.t < CONFIG.VALUE_CACHE_TTL then return c.info end
    local info = getPetValue(pet)
    ValueCache[pet] = { info = info, t = now }
    return info
end
local function getSmartScore(pet, info, distAim, isAir)
    if not CONFIG.SMART_SCORE then return info.score end
    local s = info.score / (1 + distAim / 1000)
    if isAir then s = s * 0.9 end
    return s
end
local StickyTop = nil
local StickyTopScore = 0
local function getTopPetSmart(filter)
    local pets = getAllPets()
    local best, bestInfo, bestSmart, bestRaw = nil, nil, -1, -1
    for _, pet in ipairs(pets) do
        local downed = false
        pcall(function() downed = isDownedLatched(pet) end)
        if not downed then
            local w = getPetWorld(pet)
            if filter == "Both" or filter == nil or w == filter then
                local info = getPetValueCached(pet)
                local pos = getPetCenter(pet)
                local distAim = (pos - CONFIG.AIM_POS).Magnitude
                local isAir = isAirPet(pet)
                local smart = getSmartScore(pet, info, distAim, isAir)
                if smart > bestSmart then best, bestInfo, bestSmart, bestRaw = pet, info, smart, info.score end
            end
        end
    end
    if CONFIG.STICKY_TARGET and StickyTop and StickyTop.Parent then
        local stillValid = false
        pcall(function() stillValid = not isDownedLatched(StickyTop) end)
        if stillValid then
            local infoS = getPetValueCached(StickyTop)
            local posS = getPetCenter(StickyTop)
            local distS = (posS - CONFIG.AIM_POS).Magnitude
            local smartS = getSmartScore(StickyTop, infoS, distS, isAirPet(StickyTop))
            if smartS >= bestSmart * 0.90 then
                return StickyTop, infoS, infoS.score, smartS, true
            end
        end
    end
    if best then StickyTop = best StickyTopScore = bestSmart end
    return best, bestInfo, bestRaw, bestSmart, false
end
local function isContested(pet)
    local pos = getPetCenter(pet)
    if not pos then return false end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= player and plr.Character then
            local hrp = plr.Character:FindFirstChild("HumanoidRootPart")
            if hrp and (hrp.Position - pos).Magnitude < CONFIG.ANTI_STEAL_RADIUS then
                return true, plr.Name
            end
        end
    end
    return false, nil
end
local LastShotInfo = { pet = nil, time = 0, misses = 0 }
local function recordShot(pet)
    LastShotInfo.pet = pet
    LastShotInfo.time = os.clock()
    markShot(pet)
end
local function checkShotVerify()
    if not LastShotInfo.pet then return end
    if os.clock() - LastShotInfo.time > CONFIG.SHOT_VERIFY_TIME then
        local pet = LastShotInfo.pet
        local downed = false
        pcall(function() downed = isDownedLatched(pet) end)
        if not downed and pet and pet.Parent then
            LastShotInfo.misses = LastShotInfo.misses + 1
            print("[PetESP v6] Shot verify: " .. tostring(pet.Name) .. " not downed in 5s, miss #" .. tostring(LastShotInfo.misses))
            if LastShotInfo.misses >= 3 then
                StickyTop = nil
                LastShotInfo.misses = 0
                setStatus("3 misses on same pet - switching target (sticky cleared)", "warn")
            end
        else
            LastShotInfo.misses = 0
        end
        LastShotInfo.pet = nil
    end
end
local function chooseWorld(worldName)
    local ok, err = pcall(function()
        local RS = game:GetService("ReplicatedStorage")
        local remotes = RS:FindFirstChild("Remotes")
        local remote = remotes and remotes:FindFirstChild("ChooseWorld")
        if not remote then error("ChooseWorld remote not found") end
        local args = { [1] = worldName, n = 1 }
        remote:InvokeServer(unpack(args, 1, args.n or #args))
    end)
    if ok then
        CONFIG.CurrentWorld = worldName
        if worldName == "Normal" then CONFIG.WORLD_FILTER = "W1" else CONFIG.WORLD_FILTER = "W2" end
        ValueCache = {}
        StickyTop = nil
        DownedLatch = {}
        setStatus("Teleporting to " .. worldName .. " (" .. CONFIG.WORLD_FILTER .. ")...", "ok")
        task.delay(2, function()
            setStatus("Now in " .. worldName .. " - re-scanning pets", "ok")
            for pet, e in pairs(espCache) do pcall(function() if e.gui then e.gui:Destroy() end end) pcall(function() if e.hl then e.hl:Destroy() end end) end
            espCache = {}
        end)
        return true
    else
        setStatus("World teleport failed: " .. tostring(err), "err")
        print("[PetESP v6] chooseWorld failed:", err)
        return false
    end
end
local function getCurrentWorldName() return CONFIG.CurrentWorld end

local function isDownedLatched(pet)
    -- Returns isDownedOrLatched, timerStr, secsLeft, isLatched
    local d, txt, secs = isDowned(pet)
    if d then
        local e = updateDownedLatch(pet, true, txt, secs)
        return true, txt, secs, false, e
    end
    -- Not downed by label - check latch: if we saw it downed recently and it still exists and not in base, treat as still downed
    local e = DownedLatch[pet]
    if e and os.clock() < (e.expiresAt or 0) then
        -- Verify pet still exists and not in base / not owned (if it got collected, latch should expire)
        local inBase = false
        pcall(function() inBase = isInBase(pet) end)
        if not inBase and pet.Parent then
            updateDownedLatch(pet, false, nil, nil)
            local elapsed = os.clock() - (e.lastSeen or os.clock())
            local secsLeft = nil
            if e.lastTimerSecs and e.lastTimerSecs < 900 then secsLeft = math.max(0, e.lastTimerSecs - elapsed) end
            local timerStr = "LATCHED"
            if secsLeft then timerStr = string.format("0:%02d*", math.floor(secsLeft)) end
            return true, timerStr, secsLeft, true, e
        else
            DownedLatch[pet] = nil
        end
    end
    return false, "", nil, false, nil
end


--------------------------------------------------------------------------------
-- PET DISCOVERY v2 - Pic3 fix: scan multiple folders, dedupe, sort by value
--------------------------------------------------------------------------------
local function getPetWorld(pet)
    local attr = nil
    pcall(function() attr = pet:GetAttribute("World") or pet:GetAttribute("WorldId") or pet:GetAttribute("Area") or pet:GetAttribute("Map") end)
    if attr ~= nil then
        local s = tostring(attr)
        if s:find("2") then return "W2" end
        if s:find("1") then return "W1" end
    end
    local a = pet.Parent
    while a and a ~= workspace do
        local n = a.Name:lower()
        if n:find("world 2") or n:find("world2") or n == "w2" or n:find("second") then return "W2" end
        if n:find("world 1") or n:find("world1") or n == "w1" or n:find("first") then return "W1" end
        a = a.Parent
    end
    local pos = getPetCenter(pet)
    if pos and (pos.X > 3000 or pos.Magnitude > 4000) then return "W2" end
    return "W1"
end

local VALUE_NAMES = { Value=true, Income=true, DPS=true, Price=true, Earnings=true, RarityValue=true, CashPerSec=true, MoneyPerSec=true, ["$/s"]=true, PerSecond=true }
local function getPetValue(pet)
    local info = { score=0, display="?", rarity="?", weight=nil, chance=nil, multiplier=1 }
    local function consider(raw)
        if raw == nil then return end
        local sc = parseValue(raw)
        if sc > info.score then info.score = sc; info.display = tostring(raw) end
    end
    pcall(function()
        for name in pairs(VALUE_NAMES) do local v = pet:GetAttribute(name) if v ~= nil then consider(v) end end
        local rarityAttr = pet:GetAttribute("Rarity") or pet:GetAttribute("Tier")
        if rarityAttr ~= nil then info.rarity = tostring(rarityAttr) end
        local w = pet:GetAttribute("Weight") if w ~= nil then info.weight = tostring(w) end
        local ch = pet:GetAttribute("Chance") or pet:GetAttribute("Odds") if ch ~= nil then info.chance = tostring(ch) end
        for _, d in ipairs(pet:GetDescendants()) do
            if (d:IsA("NumberValue") or d:IsA("IntValue") or d:IsA("StringValue")) and VALUE_NAMES[d.Name] then consider(d.Value)
            elseif d:IsA("TextLabel") then
                local t = d.Text or ""
                local r = t:match("(Legendary)") or t:match("(Mythic)") or t:match("(Epic)") or t:match("(Rare)") or t:match("(Common)") or t:match("(Divine)") or t:match("(Secret)")
                if r then info.rarity = r end
                local wt = t:match("Weight%s*([%+%-]?[%d%.%,]+%%)") if wt then info.weight = wt end
                local ch2 = t:match("1 in%s*(%d+)") if ch2 then info.chance = "1 in "..ch2 end
                for num in t:gmatch("([%d%.,]+%s*[A-Za-z]+%s*$/s)") do consider(num) end
                for num in t:gmatch("([%d%.,]+%s*[A-Za-z]+%s*/s)") do consider(num) end
                if info.score == 0 then local only = t:match("([%d%.,]+%s*[A-Z][A-Z])") if only then consider(only) end end
            end
        end
        if info.rarity == "?" then for r in pairs(RARITY_COLOR) do if pet.Name:lower():find(r:lower(),1,true) then info.rarity = r break end end end
        if info.display == "?" and info.score > 0 then info.display = tostring(info.score) end
    end)
    return info
end

-- v2 FIXED: scan ClientPets + Pets + DownedPets + Downed + WildPets + workspace direct + ReplicatedStorage + recursive workspace fallback
-- Relaxed: no longer requires Value/Rarity attribute for workspace-direct pets; any Model with BasePart that isn't a player character counts
local PET_SCAN_CACHE = {}
local PET_SCAN_CACHE_AT = 0
local PET_SCAN_CACHE_TTL = 0.4

local function isLikelyPet(inst)
    if not inst then return false end
    if Players:GetPlayerFromCharacter(inst) then return false end
    if inst:IsA("BasePart") then return true end
    if inst:IsA("Model") then
        local hasPart = inst:FindFirstChildWhichIsA("BasePart", true) ~= nil
        return hasPart
    end
    if inst:IsA("Folder") then
        local hasPart = inst:FindFirstChildWhichIsA("BasePart", true) ~= nil
        return hasPart
    end
    return false
end

local function scanFolderForPets(folder, out, seen)
    if not folder then return end
    for _, child in ipairs(folder:GetChildren()) do
        pcall(function()
            if isLikelyPet(child) and not seen[child] then
                local inBase = false
                pcall(function() inBase = isInBase(child) end)
                if not inBase then
                    seen[child] = true
                    table.insert(out, child)
                end
            end
            -- Recurse into subfolders (World1/World2 etc)
            if child:IsA("Folder") and not seen[child] then
                scanFolderForPets(child, out, seen)
            end
        end)
    end
end

local function scanWorkspaceDirect(out, seen)
    pcall(function()
        for _, child in ipairs(workspace:GetChildren()) do
            if isLikelyPet(child) and not seen[child] then
                local inBase = false
                pcall(function() inBase = isInBase(child) end)
                if not inBase then
                    seen[child] = true
                    table.insert(out, child)
                end
            end
        end
    end)
end

local function scanReplicatedStorage(out, seen)
    pcall(function()
        local RS = game:GetService("ReplicatedStorage")
        if not RS then return end
        for _, child in ipairs(RS:GetDescendants()) do
            if isLikelyPet(child) and not seen[child] then
                local inBase = false
                pcall(function() inBase = isInBase(child) end)
                if not inBase then
                    seen[child] = true
                    table.insert(out, child)
                end
            end
        end
    end)
end

local function scanServerStorage(out, seen)
    pcall(function()
        local SS = game:GetService("ServerStorage")
        if not SS then return end
        for _, child in ipairs(SS:GetDescendants()) do
            if isLikelyPet(child) and not seen[child] then
                local inBase = false
                pcall(function() inBase = isInBase(child) end)
                if not inBase then
                    seen[child] = true
                    table.insert(out, child)
                end
            end
        end
    end)
end

local function getAllPetsUniversal()
    local now = os.clock()
    if PET_SCAN_CACHE and PET_SCAN_CACHE_AT and now - PET_SCAN_CACHE_AT < PET_SCAN_CACHE_TTL and #PET_SCAN_CACHE > 0 then
        return PET_SCAN_CACHE
    end
    PET_SCAN_CACHE_AT = now
    local out = {}
    local seen = {}
    -- Known pet folders in workspace
    for _, name in ipairs({"ClientPets","Pets","DownedPets","Downed","WildPets"}) do
        scanFolderForPets(workspace:FindFirstChild(name), out, seen)
    end
    -- Workspace-direct pets
    scanWorkspaceDirect(out, seen)
    -- If workspace scan found nothing, broaden the search
    if #out == 0 then
        -- Recursive workspace scan (catches pets in any folder)
        pcall(function()
            for _, child in ipairs(workspace:GetDescendants()) do
                if isLikelyPet(child) and not seen[child] then
                    local inBase = false
                    pcall(function() inBase = isInBase(child) end)
                    if not inBase then
                        seen[child] = true
                        table.insert(out, child)
                    end
                end
            end
        end)
    end
    if #out == 0 then
        -- ReplicatedStorage (pets may be stored there before spawning)
        scanReplicatedStorage(out, seen)
    end
    if #out == 0 then
        -- ServerStorage (some games store pets here)
        scanServerStorage(out, seen)
    end
    PET_SCAN_CACHE = out
    return out
end

local function getAllPets()
    return getAllPetsUniversal()
end

local function getTopPet(filter)
    local pets = getAllPets()
    local best, bestInfo, bestScore = nil, nil, -1
    for _, pet in ipairs(pets) do
        -- Never aim at downed pets - they are for collect, not shoot. Also never aim at base (already filtered in getAllPets)
        local downed = false
        pcall(function() downed = isDowned(pet) end)
        if not downed then
            local w = getPetWorld(pet)
            if filter == "Both" or filter == nil or w == filter then
                local info = getPetValue(pet)
                if info.score > bestScore then best, bestInfo, bestScore = pet, info, info.score end
            end
        end
    end
    return best, bestInfo, bestScore
end

local function getDownedPets(filter)
    local pets = getAllPets()
    local out = {}
    for _, pet in ipairs(pets) do
        -- v3: blacklist check - if we failed to collect this pet recently, skip for 15s
        local bl = CollectBlacklist[pet]
        if bl and os.clock() < bl then
            -- skip blacklisted
        else
            -- v3: latch - timer may have disappeared because too far, still treat as downed
            local downed, timer, secs, latched, latchEntry = isDownedLatched(pet)
            if downed then
                -- v3: MY DOWNED ONLY - skip other players' downed (e.g. "Put to sleep by Damon")
                if isMyDowned(pet) then
                    local w = getPetWorld(pet)
                    if filter == "Both" or filter == nil or w == filter then
                        local info = getPetValue(pet)
                        -- Use latched lastPos if current pos is stale / pet moved? Use current center, fallback to latch pos
                        local pos = getPetCenter(pet)
                        if latchEntry and latchEntry.lastPos and (pos - latchEntry.lastPos).Magnitude < 1 then pos = latchEntry.lastPos end
                        local hrp = getHRP()
                        local dist = hrp and (pos - hrp.Position).Magnitude or 99999
                        table.insert(out, { pet=pet, info=info, timer=timer, secs=secs or 999, world=w, dist=dist, pos=pos, latched=latched, sleeper=(latchEntry and latchEntry.sleeperName or nil) })
                    end
                end
            end
        end
    end
    -- Sort: highest value first, then closest (so you collect valuable downed before timer expires)
    table.sort(out, function(a,b)
        if a.info.score ~= b.info.score then return a.info.score > b.info.score end
        return a.dist < b.dist
    end)
    return out
end

--------------------------------------------------------------------------------
-- COMPACT ESP v2 - Pic1 fix: small, transparent, only TOP+DOWNED+NEAR, no Highlight for all
--------------------------------------------------------------------------------
local espCache = {}
local function ensureESP(pet)
    local entry = espCache[pet]
    local rootPart = pet:IsA("Model") and (pet.PrimaryPart or pet:FindFirstChildWhichIsA("BasePart", true)) or (pet:IsA("BasePart") and pet or pet:FindFirstChildWhichIsA("BasePart", true))
    if not rootPart then return nil end
    if entry and entry.gui and entry.gui.Parent then return entry end
    if entry and entry.gui then pcall(function() entry.gui:Destroy() end) end
    if entry and entry.hl then pcall(function() entry.hl:Destroy() end) end
    -- COMPACT: 140x28 (was 220x52), TextSize 9 (was 11), BackgroundTransparency 0.65 (was 0.35), AlwaysOnTop FALSE (was true)
    local guiESP = Instance.new("BillboardGui")
    guiESP.Name = "PetESP"
    guiESP.Size = UDim2.new(0, 140, 0, 28)
    guiESP.StudsOffset = Vector3.new(0, 3.5, 0)
    guiESP.AlwaysOnTop = false -- lets world occlude, stops stacking over crosshair
    guiESP.MaxDistance = 8000
    guiESP.LightInfluence = 0
    guiESP.Parent = rootPart
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 1, 0)
    label.BackgroundTransparency = 0.65
    label.BackgroundColor3 = Color3.fromRGB(10,10,10)
    label.TextColor3 = Color3.fromRGB(255,255,255)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 9
    label.TextWrapped = false
    label.TextTruncate = Enum.TextTruncate.AtEnd
    label.Text = ""
    label.Parent = guiESP
    local corner = Instance.new("UICorner") corner.CornerRadius = UDim.new(0, 4) corner.Parent = label
    -- Highlight ONLY for TOP + DOWNED, created on demand in updateESP
    entry = { gui=guiESP, label=label, hl=nil }
    espCache[pet] = entry
    return entry
end
local function setHighlight(pet, entry, color, enabled)
    if not enabled then
        if entry.hl then pcall(function() entry.hl:Destroy() end) entry.hl = nil end
        return
    end
    if not entry.hl or not entry.hl.Parent then
        local hl = Instance.new("Highlight")
        hl.Name = "PetESP_Highlight"
        hl.FillTransparency = 0.85
        hl.OutlineTransparency = 0
        hl.DepthMode = Enum.HighlightDepthMode.Occluded -- NOT AlwaysOnTop, stops glow wall
        hl.Adornee = pet
        hl.Parent = pet
        entry.hl = hl
    end
    pcall(function() entry.hl.OutlineColor = color; entry.hl.FillColor = color; entry.hl.Enabled = true end)
end

local function updateESP()
    if not CONFIG.ESP_ENABLED then
        for _, e in pairs(espCache) do pcall(function() if e.gui then e.gui.Enabled = false end end) pcall(function() if e.hl then e.hl.Enabled = false end end) end
        return
    end
    local pets = getAllPets()
    petCount = #pets
    -- Prioritize: TOP 15 by value + ALL downed + nearest 10 = max ~35, never 163
    local scored = {}
    local hrp = getHRP()
    local myPos = hrp and hrp.Position or Vector3.zero
    local cam = workspace.CurrentCamera
    for _, pet in ipairs(pets) do
        local info = getPetValue(pet)
        local pos = getPetCenter(pet)
        local downed, timer, secs = isDowned(pet)
        local distYou = (pos - myPos).Magnitude
        local distAim = (pos - CONFIG.AIM_POS).Magnitude
        table.insert(scored, { pet=pet, info=info, pos=pos, downed=downed, timer=timer, secs=secs, distYou=distYou, distAim=distAim, world=getPetWorld(pet) })
    end
    -- Sort by value desc for TOP selection
    table.sort(scored, function(a,b) return a.info.score > b.info.score end)
    local selected = {}
    local seenSel = {}
    local function push(item)
        if not item or seenSel[item.pet] then return end
        if #selected >= CONFIG.MAX_ESP then return end
        seenSel[item.pet] = true
        table.insert(selected, item)
    end
    if CONFIG.ESP_MODE == "DOWNED" then
        for _, s in ipairs(scored) do if s.downed then push(s) end end
    elseif CONFIG.ESP_MODE == "ALL" then
        for _, s in ipairs(scored) do push(s) end
    else -- TOP (default): Top 15 + Downed + Nearest 10
        for i=1, math.min(15, #scored) do push(scored[i]) end
        for _, s in ipairs(scored) do if s.downed then push(s) end end
        -- Nearest 10: sort copy by distYou
        local byDist = {}
        for _, s in ipairs(scored) do table.insert(byDist, s) end
        table.sort(byDist, function(a,b) return a.distYou < b.distYou end)
        for i=1, math.min(10, #byDist) do push(byDist[i]) end
    end
    -- World filter + build seen for cleanup
    local seen = {}
    for _, item in ipairs(selected) do
        local pet, info, pos = item.pet, item.info, item.pos
        if CONFIG.WORLD_FILTER == "Both" or item.world == CONFIG.WORLD_FILTER then
            seen[pet] = true
            -- Hide if too close (<25 studs, you can see it) or behind camera or in base (already filtered, double-check)
            local behind = false
            if cam then local _, onScreen = cam:WorldToViewportPoint(pos) if not onScreen then behind = true end end
            if item.distYou < 25 or behind then
                local e = espCache[pet]
                if e then pcall(function() if e.gui then e.gui.Enabled = false end end) pcall(function() if e.hl then e.hl.Enabled = false end end) end
            else
                local entry = ensureESP(pet)
                if entry then
                    local isTop = (pet == topPet)
                    local col = rarityColor(info.rarity)
                    pcall(function()
                        entry.gui.Enabled = true
                        -- Compact 1-line text: Name | Rarity Value | W | dist | timer if downed
                        local downedMark = ""
                        if item.downed then downedMark = " ⏳ " .. tostring(item.timer or "DOWN") .. " TO CATCH" end
                        local topMark = isTop and "⭐ " or ""
                        entry.label.Text = topMark .. pet.Name:sub(1, 14) .. " | " .. tostring(info.rarity):sub(1,4) .. " " .. tostring(info.display) .. " | " .. item.world .. " | " .. tostring(math.floor(item.distAim)) .. "m" .. downedMark .. (item.latched and " *" or "")
                        if item.downed then entry.label.TextColor3 = Color3.fromRGB(255, 220, 0)
                        elseif isTop then entry.label.TextColor3 = Color3.fromRGB(255, 255, 0)
                        else entry.label.TextColor3 = Color3.fromRGB(255,255,255) end
                        -- Fade by distance: farther = more transparent
                        local fade = math.clamp(1 - item.distYou / 8000, 0.35, 1)
                        entry.label.BackgroundTransparency = 1 - 0.35 * fade
                    end)
                    -- Highlight ONLY for TOP + DOWNED
                    if isTop then setHighlight(pet, entry, Color3.fromRGB(255,255,0), true)
                    elseif item.downed then setHighlight(pet, entry, Color3.fromRGB(255, 170, 0), true)
                    else setHighlight(pet, entry, col, false) end
                end
            end
        end
    end
    -- Cleanup pets not selected / gone / filtered
    for pet, e in pairs(espCache) do
        if not seen[pet] then pcall(function() if e.gui then e.gui:Destroy() end end) pcall(function() if e.hl then e.hl:Destroy() end end) espCache[pet] = nil end
    end
end

--------------------------------------------------------------------------------
-- GO TO AIM / BASE + AUTO-AIM FIX + SHOOT
--------------------------------------------------------------------------------
local function tpTo(pos)
    local hrp = getHRP()
    if not hrp then return false end
    pcall(function()
        hrp.CFrame = CFrame.new(pos)
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end)
    return true
end
local function goToAimSpot()
    local hrp = getHRP()
    if not hrp then setStatus("No character - waiting respawn", "err") return false end
    local lookAt = Vector3.new(0,3,0)
    if topPet then local ok, p = pcall(function() return getPetCenter(topPet) end) if ok and p then lookAt = p end end
    pcall(function()
        hrp.CFrame = CFrame.lookAt(CONFIG.AIM_POS, Vector3.new(lookAt.X, CONFIG.AIM_POS.Y, lookAt.Z))
        hrp.AssemblyLinearVelocity = Vector3.zero
    end)
    setStatus("📍 At aim spot 5973, 3, 2 - ready to scope", "ok")
    return true
end
local function goToBase()
    if tpTo(CONFIG.BASE_POS + Vector3.new(0, 3, 0)) then setStatus("🏠 At base 5977, 3, 99", "ok") return true else setStatus("No character", "err") return false end
end
local function findGuiButton(keyword)
    local found = nil
    pcall(function()
        for _, d in ipairs(playerGui:GetDescendants()) do
            if d:IsA("TextButton") or d:IsA("ImageButton") then
                local txt = "" pcall(function() txt = tostring(d.Text or "") end)
                local nm = d.Name or ""
                if txt:upper():find(keyword:upper(),1,true) or nm:upper():find(keyword:upper(),1,true) then found = d break end
            end
        end
    end)
    return found
end
local function tryClickGuiButton(btn)
    if not btn then return false end
    local ok = false
    pcall(function() if firesignal then firesignal(btn.Activated) ok = true end end)
    if ok then return true end
    pcall(function()
        local VIM = game:GetService("VirtualInputManager")
        local pos = btn.AbsolutePosition local size = btn.AbsoluteSize
        VIM:SendMouseButtonEvent(pos.X + size.X/2, pos.Y + size.Y/2, 0, true, game, 0)
        task.wait(0.05)
        VIM:SendMouseButtonEvent(pos.X + size.X/2, pos.Y + size.Y/2, 0, false, game, 0)
        ok = true
    end)
    return ok
end
local function tryScope()
    local fov = 70
    pcall(function() fov = workspace.CurrentCamera.FieldOfView end)
    if fov < 40 then return true end
    local scopeBtn = findGuiButton("SCOPE")
    if scopeBtn then if tryClickGuiButton(scopeBtn) then setStatus("🔍 SCOPE pressed", "info") return true end end
    return false
end

-- AUTO-AIM FIX: mouse-move aim, NOT camera CFrame + HRP rotate
local function aimAtPetFixed(pet, isScoped)
    if not pet or not pet.Parent then return false end
    local cam = workspace.CurrentCamera
    if not cam then return false end
    local c = getPetCenter(pet)
    if not c then return false end
    local v, onScreen = cam:WorldToViewportPoint(c)
    if not onScreen or v.Z <= 0 then return false end
    -- Let game's own scoped camera follow mouse - works when CFrame is overridden by game
    local ok = pcall(function()
        local VIM = game:GetService("VirtualInputManager")
        VIM:SendMouseMoveEvent(v.X, v.Y, game)
    end)
    if ok then return true end
    -- Fallback: only if NOT scoped (scoped camera will override CFrame)
    if not isScoped then
        local ok2 = pcall(function() cam.CFrame = CFrame.lookAt(cam.CFrame.Position, c) end)
        return ok2
    end
    return false
end
local function shouldShoot(pet)
    if not pet or not pet.Parent then return false end
    local cam = workspace.CurrentCamera
    if not cam then return false end
    local aimPoint, isAir = getAimPoint(pet, cam.CFrame.Position)
    if not aimPoint then return false end
    local v, on = cam:WorldToViewportPoint(aimPoint)
    if not on or v.Z <= 0 then return false end
    local cx, cy = cam.ViewportSize.X/2, cam.ViewportSize.Y/2
    local dx, dy = v.X - cx, v.Y - cy
    local dist = (aimPoint - cam.CFrame.Position).Magnitude
    -- Distance-scaled px tolerance from CONFIG (more lenient for distant/small pets)
    local tolPx = CONFIG.AIM_TOLERANCE_PX
    if isAir then
        tolPx = math.clamp(CONFIG.AIM_TOLERANCE_PX + 60 - dist / 40, 45, CONFIG.AIM_TOLERANCE_PX + 60)
    else
        tolPx = math.clamp(CONFIG.AIM_TOLERANCE_PX + 30 - dist / 60, 50, CONFIG.AIM_TOLERANCE_PX + 30)
    end
    -- 3D angular tolerance from CONFIG (more lenient)
    local look = cam.CFrame.LookVector
    local toPet = (aimPoint - cam.CFrame.Position).Unit
    local dot = math.clamp(look:Dot(toPet), -1, 1)
    local angleDeg = math.deg(math.acos(dot))
    local maxAngle = isAir and CONFIG.AIR_ANGLE_DEG or CONFIG.GROUND_ANGLE_DEG
    if angleDeg > maxAngle then
        AirAimState.frames = 0
        return false
    end
    local inTol = math.abs(dx) < tolPx and math.abs(dy) < tolPx
    if inTol then
        AirAimState.frames = AirAimState.frames + 1
    else
        AirAimState.frames = 0
    end
    -- 1 consecutive frame in tolerance is enough for both air and ground
    return AirAimState.frames >= 1
end
local function shootPet(pet)
    if os.clock() - lastShotAt < CONFIG.SHOOT_COOLDOWN then return false end
    -- Only shoot if crosshair is actually on pet (Pic3 fix: was shooting somewhere)
    if not shouldShoot(pet) then
        -- Still try to aim first, don't waste ammo
        aimAtPetFixed(pet, true)
        return false
    end
    lastShotAt = os.clock()
    recordShot(pet) -- v4: remember we shot this pet, so MY DOWNED ONLY can claim it later
    local shot = false
    pcall(function()
        local ch = player.Character
        if ch then local tool = ch:FindFirstChildOfClass("Tool") if tool then tool:Activate() shot = true end end
    end)
    if shot then print("[PetESP v6] Shoot via Tool ->", pet and pet.Name) return true end
    local shootBtn = findGuiButton("SHOOT")
    if shootBtn then if tryClickGuiButton(shootBtn) then print("[PetESP v6] Shoot via SHOOT button") return true end end
    pcall(function()
        local VIM = game:GetService("VirtualInputManager")
        local cam = workspace.CurrentCamera
        local vs = cam and cam.ViewportSize or Vector2.new(800,600)
        VIM:SendMouseButtonEvent(vs.X/2, vs.Y/2, 0, true, game, 0)
        task.wait(0.05)
        VIM:SendMouseButtonEvent(vs.X/2, vs.Y/2, 0, false, game, 0)
        shot = true
    end)
    if shot then print("[PetESP v6] Shoot via center click") return true end
    pcall(function()
        local RS = game:GetService("ReplicatedStorage")
        for _, d in ipairs(RS:GetDescendants()) do
            if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
                local n = d.Name:lower()
                if n:find("shoot") or n:find("fire") or n:find("gun") then
                    if d:IsA("RemoteEvent") then d:FireServer(pet, getPetCenter(pet)) else d:InvokeServer(pet, getPetCenter(pet)) end
                    shot = true; print("[PetESP v6] Shoot via Remote:", d:GetFullName()); break
                end
            end
        end
    end)
    return shot
end

local function autoAimTick()
    if not CONFIG.AUTO_AIM then return end
    -- If auto-collect is busy, pause aiming (don't shoot while collecting)
    if collectState ~= "IDLE" then return end
    if not topPet or not topPet.Parent then setStatus("🎯 Auto-Aim ON - no wild pets (base pets excluded)", "warn") return end
    -- Skip if top pet is downed (should be collected, not shot) - getTopPet already filters, double-check
    local isD = false pcall(function() isD = isDowned(topPet) end)
    if isD then return end
    if os.clock() - lastAimAt > 1 then pcall(tryScope) end
    if os.clock() - lastAimAt >= CONFIG.AIM_COOLDOWN then
        lastAimAt = os.clock()
        local pos = getPetCenter(topPet)
        local distAim = math.floor((pos - CONFIG.AIM_POS).Magnitude)
        local info = topInfo or getPetValue(topPet)
        -- Aim 2-3 times with small wait so mouse-move settles before shooting
        aimAtPetFixed(topPet, true)
        task.wait(0.08)
        aimAtPetFixed(topPet, true)
        if topLabel then topLabel.Text = "⭐ TOP: "..tostring(topPet.Name):sub(1,20).." | "..tostring(info.rarity).." • "..tostring(info.display).." | "..getPetWorld(topPet).." | "..tostring(distAim).." studs (aim)" end
        if lastTarget ~= topPet then lastTarget = topPet; AirAimState.frames = 0; setStatus("🎯 Aiming TOP: "..tostring(topPet.Name):sub(1,18).." ("..tostring(info.display)..") - aligning...", "warn") end
        -- Only shoot if crosshair is on pet
        if shouldShoot(topPet) then shootPet(topPet) end
    end
end

--------------------------------------------------------------------------------
-- AUTO-COLLECT - Pic2 fix: go to downed pet -> collect -> TP to base 5977,3,99
--------------------------------------------------------------------------------
local function tryCollectInteract(pet)
    -- 1) ProximityPrompt
    pcall(function()
        for _, pr in ipairs(pet:GetDescendants()) do if pr:IsA("ProximityPrompt") then
            if fireproximityprompt then fireproximityprompt(pr) else
                -- Fallback: teleport close + wait, game auto-prompts
            end
        end end
    end)
    -- 2) Touch
    pcall(function()
        local hrp = getHRP()
        local part = pet:IsA("Model") and (pet.PrimaryPart or pet:FindFirstChildWhichIsA("BasePart", true)) or nil
        if hrp and part and firetouchinterest then firetouchinterest(hrp, part, 0) task.wait(0.1) firetouchinterest(hrp, part, 1) end
    end)
    -- 3) Remote Collect/Catch/Pickup
    pcall(function()
        local RS = game:GetService("ReplicatedStorage")
        for _, d in ipairs(RS:GetDescendants()) do
            if d:IsA("RemoteEvent") and (d.Name:lower():find("collect") or d.Name:lower():find("catch") or d.Name:lower():find("pickup") or d.Name:lower():find("claim")) then
                d:FireServer(pet)
                print("[PetESP v6] Collect via Remote:", d:GetFullName())
            end
        end
    end)
end
local function collectDownedPet(entry)
    local pet = entry.pet
    if not pet or not pet.Parent then return end
    local id = tostring(pet:GetDebugId())
    if collectBusy[id] then return end
    if os.clock() - lastCollectAt < CONFIG.COLLECT_COOLDOWN then return end
    lastCollectAt = os.clock()
    collectBusy[id] = true
    collectState = "GOTO_DOWNED"
    local pos = entry.pos or getPetCenter(pet)
    setStatus("⏳ DOWNED found: "..tostring(pet.Name):sub(1,18).." ("..tostring(entry.info.display)..") "..tostring(entry.timer).." - going to collect...", "warn")
    -- TP to downed pet + 3 studs offset (so you don't stand inside it)
    tpTo(pos + Vector3.new(3, 2, 3))
    task.wait(0.6)
    -- If pet is no longer downed (someone else took it / timer expired), abort
    local stillDowned = false pcall(function() stillDowned = isDowned(pet) end)
    if not stillDowned then
        setStatus("⏳ Downed pet gone (taken/expired) - back to aim", "warn")
        collectState = "RETURN_AIM"
        if CONFIG.AUTO_AIM then tpTo(CONFIG.AIM_POS) end
        task.wait(0.3)
        collectState = "IDLE"
        task.delay(10, function() collectBusy[id] = nil end)
        return
    end
    collectState = "COLLECT"
    setStatus("✋ Collecting "..tostring(pet.Name):sub(1,18).."...", "warn")
    tryCollectInteract(pet)
    task.wait(0.5)
    -- TP to base 5977,3,99 to deposit
    collectState = "TP_BASE"
    setStatus("🏠 Collected! TP to base 5977, 3, 99...", "ok")
    tpTo(CONFIG.BASE_POS + Vector3.new(0, 3, 0))
    task.wait(0.9)
    -- Return to aim spot if auto-aim is on
    if CONFIG.AUTO_AIM then
        collectState = "RETURN_AIM"
        tpTo(CONFIG.AIM_POS)
        task.wait(0.3)
    end
    collectState = "IDLE"
    task.delay(10, function() collectBusy[id] = nil end)
    setStatus("✅ Collected "..tostring(pet.Name):sub(1,18).." -> base. Back to aim.", "ok")
end
local function autoCollectTick()
    if not CONFIG.AUTO_COLLECT then return end
    if collectState ~= "IDLE" then return end
    local downed = getDownedPets(CONFIG.WORLD_FILTER)
    downedCount = #downed
    if #downed > 0 then
        -- Collect highest-value downed first
        task.spawn(function() collectDownedPet(downed[1]) end)
    end
end

------ V5/V6 AUTO MINIGAME LOGIC - treadmill duck auto-tap
CONFIG.AUTO_MINIGAME = false
MinigameStats = { tapped = 0, lastTapAt = 0, lastDuckName = "" }
MinigameTapped = {} -- instance -> last tap time


-- GUI v6 CM HUB STYLE
C = {
    bg = Color3.fromRGB(30,18,22),
    card = Color3.fromRGB(42,26,32),
    card2 = Color3.fromRGB(36,22,28),
    border = Color3.fromRGB(58,36,48),
    accent = Color3.fromRGB(255,77,109),
    text = Color3.fromRGB(255,255,255),
    muted = Color3.fromRGB(201,174,184),
    muted2 = Color3.fromRGB(150,120,135),
    green = Color3.fromRGB(46,190,120),
    red = Color3.fromRGB(235,70,80),
    blue = Color3.fromRGB(60,160,235),
    yellow = Color3.fromRGB(245,190,70),
    toggleOff = Color3.fromRGB(58,36,48),
}
function hostFor()
    local ok, h = pcall(function() return gethui and gethui() end)
    if ok and h then return h end
    local ok2, core = pcall(function() return game:GetService("CoreGui") end)
    if ok2 and core then return core end
    return playerGui
end
host = hostFor()
for _, parent in ipairs({host, playerGui}) do pcall(function() for _, g in ipairs(parent:GetChildren()) do if g.Name == "PetEspHub" or g.Name == "PetEspHubStatus" then g:Destroy() end end end) end
gui = Instance.new("ScreenGui") gui.Name = "PetEspHub" gui.ResetOnSpawn = false gui.IgnoreGuiInset = true gui.DisplayOrder = 50 gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
okParent = pcall(function() gui.Parent = host end) if not okParent or not gui.Parent then gui.Parent = playerGui end
function corner(o, r) local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, r or 10) c.Parent = o return c end
function stroke(o, col, thick)
    local s = Instance.new("UIStroke") s.Color = col or C.border s.Thickness = thick or 1 s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border s.Parent = o return s
end
function newLabel(parent, text, size, pos, textSize, color, font)
    local l = Instance.new("TextLabel") l.Size = size; l.Position = pos; l.BackgroundTransparency = 1; l.Text = text; l.TextColor3 = color or C.text; l.Font = font or Enum.Font.Gotham; l.TextSize = textSize or 11; l.TextXAlignment = Enum.TextXAlignment.Left; l.TextYAlignment = Enum.TextYAlignment.Top; l.TextWrapped = true; l.Parent = parent return l
end
function makeDraggable(frame, handle)
    handle.Active = true
    local dragging, dragStart, startPos = false, nil, nil
    handle.InputBegan:Connect(function(input) if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = true; dragStart = input.Position; startPos = frame.Position end end)
    UIS.InputChanged:Connect(function(input) if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then local d = input.Position - dragStart frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y) end end)
    UIS.InputEnded:Connect(function(input) if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end end)
end
do
    pillGui = Instance.new("ScreenGui") pillGui.Name = "PetEspHubStatus" pillGui.ResetOnSpawn = false; pillGui.IgnoreGuiInset = true; pillGui.DisplayOrder = 100; pillGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    local okP = pcall(function() pillGui.Parent = host end) if not okP or not pillGui.Parent then pillGui.Parent = playerGui end
    pill = Instance.new("Frame") pill.AnchorPoint = Vector2.new(0.5,0); pill.Position = UDim2.new(0.5,0,0,6); pill.Size = UDim2.fromOffset(320,26); pill.BackgroundColor3 = C.bg; pill.BorderSizePixel = 0; pill.Visible = false; pill.Parent = pillGui; corner(pill, 13) stroke(pill, C.border, 1)
    pillDot = Instance.new("Frame") pillDot.Size = UDim2.fromOffset(10,10); pillDot.Position = UDim2.fromOffset(10,8); pillDot.BackgroundColor3 = C.accent; pillDot.BorderSizePixel = 0; pillDot.Parent = pill; corner(pillDot, 5)
    pillLabel = Instance.new("TextLabel") pillLabel.Size = UDim2.new(1,-36,1,0); pillLabel.Position = UDim2.new(0,26,0,0); pillLabel.BackgroundTransparency = 1; pillLabel.Text = "Idle"; pillLabel.TextColor3 = C.text; pillLabel.Font = Enum.Font.GothamBold; pillLabel.TextSize = 11; pillLabel.TextXAlignment = Enum.TextXAlignment.Left; pillLabel.TextTruncate = Enum.TextTruncate.AtEnd; pillLabel.Parent = pill
    pillGui.Enabled = true
    toast = function(text, kind) setStatus(text, kind or "info") end
end
main = Instance.new("Frame") main.Name = "Main"; main.Size = UDim2.fromOffset(540, 360); main.Position = UDim2.new(0.5, -270, 0.5, -180); main.BackgroundColor3 = C.bg; main.BorderSizePixel = 0; main.ClipsDescendants = true; main.Parent = gui; corner(main, 12) stroke(main, C.accent, 1)
topBar = Instance.new("Frame") topBar.Size = UDim2.new(1,0,0,36); topBar.BackgroundColor3 = Color3.fromRGB(38,22,28); topBar.BorderSizePixel = 0; topBar.Parent = main; corner(topBar, 12)
topCover = Instance.new("Frame") topCover.Size = UDim2.new(1,0,0,12); topCover.Position = UDim2.new(0,0,1,-12); topCover.BackgroundColor3 = Color3.fromRGB(38,22,28); topCover.BorderSizePixel = 0; topCover.Parent = topBar
titleLabel = newLabel(topBar, "PET ESP HUB", UDim2.new(0,110,0,20), UDim2.fromOffset(10,4), 13, C.text, Enum.Font.GothamBold)
versionLabel = newLabel(topBar, "VERSION 6.0", UDim2.new(0,110,0,10), UDim2.fromOffset(10,22), 7, C.muted2, Enum.Font.Gotham)
mainBadge = Instance.new("Frame") mainBadge.Size = UDim2.fromOffset(58,16); mainBadge.Position = UDim2.fromOffset(128,10); mainBadge.BackgroundColor3 = Color3.fromRGB(58,36,48); mainBadge.BorderSizePixel = 0; mainBadge.Parent = topBar; corner(mainBadge, 8)
mainDot = Instance.new("Frame") mainDot.Size = UDim2.fromOffset(6,6); mainDot.Position = UDim2.fromOffset(6,5); mainDot.BackgroundColor3 = C.accent; mainDot.BorderSizePixel = 0; mainDot.Parent = mainBadge; corner(mainDot, 3)
mainBadgeLabel = newLabel(mainBadge, "MAIN", UDim2.new(1,-16,1,0), UDim2.fromOffset(16,1), 8, C.text, Enum.Font.GothamBold) mainBadgeLabel.TextYAlignment = Enum.TextYAlignment.Center
searchBox = Instance.new("TextBox") searchBox.Size = UDim2.fromOffset(150,20); searchBox.Position = UDim2.new(1,-260,0,8); searchBox.BackgroundColor3 = C.card; searchBox.BorderSizePixel = 0; searchBox.PlaceholderText = "Search features..."; searchBox.Text = ""; searchBox.TextColor3 = C.text; searchBox.PlaceholderColor3 = C.muted2; searchBox.Font = Enum.Font.Gotham; searchBox.TextSize = 10; searchBox.TextXAlignment = Enum.TextXAlignment.Left; searchBox.Parent = topBar; corner(searchBox, 10) stroke(searchBox, C.border, 1)
collapseBtn = Instance.new("TextButton") collapseBtn.Size = UDim2.fromOffset(70,20); collapseBtn.Position = UDim2.new(1,-100,0,8); collapseBtn.BackgroundColor3 = C.card; collapseBtn.BorderSizePixel = 0; collapseBtn.Text = "[ COLLAPSE ]"; collapseBtn.TextColor3 = C.muted; collapseBtn.Font = Enum.Font.Gotham; collapseBtn.TextSize = 8; collapseBtn.Parent = topBar; corner(collapseBtn, 6)
closeBtn = Instance.new("TextButton") closeBtn.Size = UDim2.fromOffset(20,20); closeBtn.Position = UDim2.new(1,-26,0,8); closeBtn.BackgroundColor3 = C.card; closeBtn.BorderSizePixel = 0; closeBtn.Text = "X"; closeBtn.TextColor3 = C.text; closeBtn.Font = Enum.Font.GothamBold; closeBtn.TextSize = 14; closeBtn.Parent = topBar; corner(closeBtn, 6)
makeDraggable(main, topBar)
sidebar = Instance.new("Frame") sidebar.Size = UDim2.new(0,44,1,-60); sidebar.Position = UDim2.fromOffset(0,36); sidebar.BackgroundColor3 = Color3.fromRGB(22,14,18); sidebar.BorderSizePixel = 0; sidebar.Parent = main
sidebarBtns = {}
function makeSideBtn(icon, y, tabName)
    local b = Instance.new("TextButton") b.Size = UDim2.fromOffset(32,32); b.Position = UDim2.fromOffset(6,y); b.BackgroundColor3 = C.card; b.BorderSizePixel = 0; b.Text = icon; b.TextColor3 = C.text; b.Font = Enum.Font.GothamBold; b.TextSize = 14; b.Parent = sidebar; corner(b, 8)
    sidebarBtns[tabName] = b
    return b
end
homeBtn = makeSideBtn("H", 8, "MAIN")
espSideBtn = makeSideBtn("E", 48, "ESP")
combatSideBtn = makeSideBtn("T", 88, "COMBAT")
settingsSideBtn = makeSideBtn("S", 128, "SETTINGS")
avatarFrame = Instance.new("Frame") avatarFrame.Size = UDim2.fromOffset(28,28); avatarFrame.Position = UDim2.fromOffset(8, 240); avatarFrame.BackgroundColor3 = C.accent; avatarFrame.BorderSizePixel = 0; avatarFrame.Parent = sidebar; corner(avatarFrame, 14)
avatarLabel = newLabel(avatarFrame, player.Name:sub(1,1):upper(), UDim2.new(1,0,1,0), UDim2.fromOffset(0,0), 12, C.text, Enum.Font.GothamBold) avatarLabel.TextXAlignment = Enum.TextXAlignment.Center; avatarLabel.TextYAlignment = Enum.TextYAlignment.Center
cmHubLabel = newLabel(sidebar, "CM HUB", UDim2.new(0,44,0,24), UDim2.fromOffset(0,272), 7, C.muted2, Enum.Font.GothamBold) cmHubLabel.TextXAlignment = Enum.TextXAlignment.Center
content = Instance.new("Frame") content.Name = "Content"; content.Size = UDim2.new(1,-44,1,-60); content.Position = UDim2.fromOffset(44,36); content.BackgroundTransparency = 1; content.Parent = main
pages = {}
function makePage(name)
    local p = Instance.new("Frame") p.Name = name; p.Size = UDim2.new(1,0,1,0); p.BackgroundTransparency = 1; p.Visible = (name == "MAIN"); p.Parent = content
    pages[name] = p
    return p
end
mainPage = makePage("MAIN")
espPage = makePage("ESP")
combatPage = makePage("COMBAT")
settingsPage = makePage("SETTINGS")
function setTab(name)
    for n, p in pairs(pages) do p.Visible = (n == name) end
    for tab, btn in pairs(sidebarBtns) do
        if tab == name then btn.BackgroundColor3 = C.accent else btn.BackgroundColor3 = C.card end
    end
    mainBadgeLabel.Text = name
end
homeBtn.Activated:Connect(function() setTab("MAIN") end)
espSideBtn.Activated:Connect(function() setTab("ESP") end)
combatSideBtn.Activated:Connect(function() setTab("COMBAT") end)
settingsSideBtn.Activated:Connect(function() setTab("SETTINGS") end)
function makeToggle(parent, labelText, y, defaultOn, onChange)
    local row = Instance.new("Frame") row.Size = UDim2.new(1,-12,0,26); row.Position = UDim2.fromOffset(6,y); row.BackgroundTransparency = 1; row.Parent = parent
    local lbl = newLabel(row, labelText, UDim2.new(1,-46,1,0), UDim2.fromOffset(0,4), 10, C.text, Enum.Font.Gotham)
    local track = Instance.new("TextButton") track.Size = UDim2.fromOffset(36,18); track.Position = UDim2.new(1,-36,0,4); track.BackgroundColor3 = defaultOn and C.accent or C.toggleOff; track.BorderSizePixel = 0; track.Text = ""; track.AutoButtonColor = false; track.Parent = row; corner(track, 9)
    local knob = Instance.new("Frame") knob.Size = UDim2.fromOffset(14,14); knob.Position = UDim2.new(0, defaultOn and 20 or 2, 0, 2); knob.BackgroundColor3 = Color3.new(1,1,1); knob.BorderSizePixel = 0; knob.Parent = track; corner(knob, 7)
    local state = defaultOn
    local function set(v)
        state = v
        track.BackgroundColor3 = v and C.accent or C.toggleOff
        knob.Position = UDim2.new(0, v and 20 or 2, 0, 2)
    end
    track.Activated:Connect(function() set(not state) if onChange then onChange(state) end end)
    return { set = set, get = function() return state end, row = row }
end
function makeActionBtn(parent, text, y, w, x, color, textSize)
    local b = Instance.new("TextButton") b.Size = UDim2.new(0, w or 220, 0, 26); b.Position = UDim2.new(0, x or 6, 0, y); b.BackgroundColor3 = color or C.card; b.BorderSizePixel = 0; b.Text = text; b.TextColor3 = C.text; b.Font = Enum.Font.GothamBold; b.TextSize = textSize or 10; b.Parent = parent; corner(b, 8) stroke(b, C.border, 1) return b
end
function makeCard(parent, title, y, h, w, x)
    local card = Instance.new("Frame") card.Size = UDim2.new(0, w or 236, 0, h or 120); card.Position = UDim2.new(0, x or 6, 0, y); card.BackgroundColor3 = C.card; card.BorderSizePixel = 0; card.Parent = parent; corner(card, 10) stroke(card, C.border, 1)
    local t = newLabel(card, title, UDim2.new(1,-12,0,16), UDim2.fromOffset(6,6), 9, C.accent, Enum.Font.GothamBold)
    return card
end
teleLabel = newLabel(mainPage, "TELEMETRY & INSTANCE OVERVIEW", UDim2.new(1,-12,0,14), UDim2.fromOffset(6,6), 8, C.muted, Enum.Font.GothamBold)
function makeTeleCard(x, title, valueText, subText)
    local card = Instance.new("Frame") card.Size = UDim2.fromOffset(154,52); card.Position = UDim2.fromOffset(x,24); card.BackgroundColor3 = C.card2; card.BorderSizePixel = 0; card.Parent = mainPage; corner(card, 8) stroke(card, C.border, 1)
    local t = newLabel(card, title, UDim2.new(1,-10,0,10), UDim2.fromOffset(5,4), 7, C.muted2, Enum.Font.GothamBold)
    local v = newLabel(card, valueText, UDim2.new(1,-10,0,18), UDim2.fromOffset(5,16), 13, C.text, Enum.Font.GothamBold)
    local s = newLabel(card, subText, UDim2.new(1,-10,0,10), UDim2.fromOffset(5,36), 7, C.muted, Enum.Font.Gotham)
    return { card = card, value = v, sub = s }
end
telePets = makeTeleCard(6, "PETS - WILD", "0", "Base excluded")
teleTop = makeTeleCard(166, "TOP PET - SMART", "-", "Smart score")
teleDowned = makeTeleCard(326, "DOWNED - MY ONLY", "0", "Latch 120s")
statusLabel = newLabel(mainPage, "Ready. v6 CM HUB. Smart + sticky.", UDim2.new(1,-12,0,14), UDim2.fromOffset(6,82), 9, C.muted)
topLabel = newLabel(mainPage, "TOP: -", UDim2.new(1,-12,0,14), UDim2.fromOffset(6,98), 9, C.yellow) topLabel.Font = Enum.Font.GothamBold
downedLabel = newLabel(mainPage, "Downed: 0", UDim2.new(1,-12,0,12), UDim2.fromOffset(6,114), 9, Color3.fromRGB(255,220,0))
statsLabel = newLabel(mainPage, "Pets 0 - ESP ON - Aim OFF - Collect OFF", UDim2.new(1,-12,0,12), UDim2.fromOffset(6,128), 9, C.muted)
espSuite = makeCard(mainPage, "ESP & TARGETING SUITE", 148, 106, 236, 6)
worldSuite = makeCard(mainPage, "WORLD & COLLECT SUITE", 148, 106, 236, 254)
-- V5 GUI: AUTO MINIGAME card in MAIN tab
minigameCard = Instance.new("Frame") minigameCard.Size = UDim2.fromOffset(484, 36); minigameCard.Position = UDim2.fromOffset(6, 258); minigameCard.BackgroundColor3 = C.card; minigameCard.BorderSizePixel = 0; minigameCard.Parent = mainPage; corner(minigameCard, 10) stroke(minigameCard, C.border, 1)
minigameTitle = newLabel(minigameCard, "DUCK MINIGAME", UDim2.new(0,120,0,20), UDim2.fromOffset(8,8), 10, C.accent, Enum.Font.GothamBold)
minigameStatus = newLabel(minigameCard, "Ducks: 0", UDim2.new(0,100,0,20), UDim2.fromOffset(380,8), 10, C.text, Enum.Font.GothamBold) minigameStatus.TextXAlignment = Enum.TextXAlignment.Right
minigameToggle = nil
minigameToggle = makeToggle(minigameCard, "AUTO MINIGAME (TREADMILL)", 5, false, function(v) setAutoMinigame(v) if minigameToggle then minigameToggle.set(v) end end)
-- Fix toggle position inside card: move row to middle
pcall(function() minigameToggle.row.Position = UDim2.fromOffset(132, 5) minigameToggle.row.Size = UDim2.new(0, 240, 0, 26) end)

espToggle, aimToggle, myDownedToggle, smartToggle = nil, nil, nil, nil
worldNormalBtn, worldPrehistoricBtn, collectBtn, baseBtn, aimSpotBtn = nil, nil, nil, nil, nil
espPageTitle = newLabel(espPage, "ESP SETTINGS", UDim2.new(1,-12,0,16), UDim2.fromOffset(6,6), 10, C.accent, Enum.Font.GothamBold)
espModeBtn, worldBtn, clearBtn, diagBtn = nil, nil, nil, nil
espPageHint = newLabel(espPage, "ESP: TOP 15 + Downed + Near 10, compact, no Highlight for all. Base pets excluded.", UDim2.new(1,-12,0,28), UDim2.fromOffset(6,28), 9, C.muted)
combatTitle = newLabel(combatPage, "COMBAT - AUTO-AIM", UDim2.new(1,-12,0,16), UDim2.fromOffset(6,6), 10, C.accent, Enum.Font.GothamBold)
combatHint = newLabel(combatPage, "Air lead: velocity * clamp(dist/1200, 0, 0.8). Angle <2.2 deg + 2 frames for air. Sticky 90%. Shot verify 5s, 3 misses = switch.", UDim2.new(1,-12,0,36), UDim2.fromOffset(6,28), 9, C.muted)
scopeBtn = nil
settingsTitle = newLabel(settingsPage, "SETTINGS", UDim2.new(1,-12,0,16), UDim2.fromOffset(6,6), 10, C.accent, Enum.Font.GothamBold)
latchToggle, verifyToggle, stickyToggle = nil, nil, nil
configNameBox = Instance.new("TextBox") configNameBox.Size = UDim2.fromOffset(180,24); configNameBox.Position = UDim2.fromOffset(6,180); configNameBox.BackgroundColor3 = C.card2; configNameBox.BorderSizePixel = 0; configNameBox.PlaceholderText = "Config Name: Ride a pet!"; configNameBox.Text = "Ride a pet!"; configNameBox.TextColor3 = C.text; configNameBox.PlaceholderColor3 = C.muted2; configNameBox.Font = Enum.Font.Gotham; configNameBox.TextSize = 10; configNameBox.Parent = settingsPage; corner(configNameBox, 6)
saveConfigBtn = makeActionBtn(settingsPage, "Save Config", 210, 180, 6, C.accent, 10)
resetLayoutBtn = makeActionBtn(settingsPage, "Reset Layout", 240, 180, 6, C.card, 10)
bottomBar = Instance.new("Frame") bottomBar.Size = UDim2.new(1,0,0,24); bottomBar.Position = UDim2.new(0,0,1,-24); bottomBar.BackgroundColor3 = Color3.fromRGB(22,14,18); bottomBar.BorderSizePixel = 0; bottomBar.Parent = main
bottomLabel = newLabel(bottomBar, "CM HUB", UDim2.new(0,80,1,0), UDim2.fromOffset(8,4), 9, C.text, Enum.Font.GothamBold)
bottomProgress = Instance.new("Frame") bottomProgress.Size = UDim2.new(0,80,0,8); bottomProgress.Position = UDim2.new(1,-90,0,8); bottomProgress.BackgroundColor3 = C.card; bottomProgress.BorderSizePixel = 0; bottomProgress.Parent = bottomBar; corner(bottomProgress, 4)
bottomFill = Instance.new("Frame") bottomFill.Size = UDim2.new(1,0,1,0); bottomFill.BackgroundColor3 = C.accent; bottomFill.BorderSizePixel = 0; bottomFill.Parent = bottomProgress; corner(bottomFill, 4)
bottomPct = newLabel(bottomBar, "100%", UDim2.new(0,40,1,0), UDim2.new(1,-40,0,0), 9, C.text, Enum.Font.GothamBold) bottomPct.TextYAlignment = Enum.TextYAlignment.Center
mini = Instance.new("Frame") mini.Name = "Mini"; mini.Size = UDim2.fromOffset(140,28); mini.Position = UDim2.fromOffset(10,60); mini.BackgroundColor3 = C.bg; mini.BorderSizePixel = 0; mini.Visible = false; mini.Parent = gui; corner(mini, 14) stroke(mini, C.accent, 1)
miniDot = Instance.new("Frame") miniDot.Size = UDim2.fromOffset(10,10); miniDot.Position = UDim2.fromOffset(10,9); miniDot.BackgroundColor3 = C.accent; miniDot.BorderSizePixel = 0; miniDot.Parent = mini; corner(miniDot, 5)
miniBtn = Instance.new("TextButton") miniBtn.Size = UDim2.fromOffset(60,20); miniBtn.Position = UDim2.fromOffset(26,4); miniBtn.BackgroundTransparency = 1; miniBtn.Text = "ESP ON"; miniBtn.TextColor3 = C.text; miniBtn.Font = Enum.Font.GothamBold; miniBtn.TextSize = 10; miniBtn.Parent = mini
expandBtn = Instance.new("TextButton") expandBtn.Size = UDim2.fromOffset(28,20); expandBtn.Position = UDim2.fromOffset(106,4); expandBtn.BackgroundTransparency = 1; expandBtn.Text = "A"; expandBtn.TextColor3 = C.text; expandBtn.Font = Enum.Font.GothamBold; expandBtn.TextSize = 12; expandBtn.Parent = mini
makeDraggable(mini, mini)
espToggle = makeToggle(espSuite, "ESP", 26, CONFIG.ESP_ENABLED, function(v) CONFIG.ESP_ENABLED = v refreshUI() if v then showPill() setStatus("ESP ON - CM HUB", "ok") else setStatus("ESP OFF", "warn") for _, e in pairs(espCache) do pcall(function() if e.gui then e.gui.Enabled = false end end) pcall(function() if e.hl then e.hl.Enabled = false end end) end end end)
aimToggle = makeToggle(espSuite, "AUTO-AIM", 52, CONFIG.AUTO_AIM, function(v) CONFIG.AUTO_AIM = v refreshUI() showPill() if v then setStatus("AUTO-AIM ON - lead + sticky", "ok") pcall(tryScope) else setStatus("AUTO-AIM OFF", "warn") end end)
myDownedToggle = makeToggle(espSuite, "MY DOWNED ONLY", 78, CONFIG.MY_DOWNED_ONLY, function(v) CONFIG.MY_DOWNED_ONLY = v refreshUI() setStatus(v and "MY DOWNED ONLY ON" or "MY DOWNED ONLY OFF", v and "ok" or "warn") end)
worldNormalBtn = makeActionBtn(worldSuite, "W1 - Normal", 26, 108, 6, C.card, 9)
worldPrehistoricBtn = makeActionBtn(worldSuite, "W2 - Prehistoric", 26, 108, 122, C.accent, 9)
collectBtn = makeActionBtn(worldSuite, "AUTO-COLLECT: OFF", 56, 220, 6, C.card, 10)
aimSpotBtn = makeActionBtn(worldSuite, "AIM SPOT", 82, 108, 6, C.blue, 9)
baseBtn = makeActionBtn(worldSuite, "BASE", 82, 108, 122, C.card, 9)
espModeBtn = makeActionBtn(espPage, "Mode: TOP", 62, 220, 6, C.card, 10)
worldBtn = makeActionBtn(espPage, "World: BOTH", 62, 220, 236, C.card, 10)
clearBtn = makeActionBtn(espPage, "CLEAR ESP", 92, 220, 6, C.card, 10)
diagBtn = makeActionBtn(espPage, "DIAG", 92, 220, 236, C.accent, 10)
scopeBtn = makeActionBtn(combatPage, "SCOPE / AUTO-AIM: OFF", 70, 220, 6, C.card, 10)
combatTopLabel = newLabel(combatPage, "TOP: -", UDim2.new(1,-12,0,28), UDim2.fromOffset(6,102), 10, C.yellow)
smartToggle = makeToggle(settingsPage, "SMART SCORE (value / distance)", 28, CONFIG.SMART_SCORE, function(v) CONFIG.SMART_SCORE = v refreshUI() setStatus(v and "Smart score ON" or "Smart score OFF - raw value", "info") end)
stickyToggle = makeToggle(settingsPage, "STICKY TARGET (90%)", 56, CONFIG.STICKY_TARGET, function(v) CONFIG.STICKY_TARGET = v if not v then StickyTop = nil end refreshUI() setStatus(v and "Sticky ON" or "Sticky OFF", "info") end)
latchToggle = makeToggle(settingsPage, "DOWNED LATCH (120s)", 84, true, function(v) setStatus(v and "Latch ON" or "Latch OFF", "info") end)
verifyToggle = makeToggle(settingsPage, "VERIFY COLLECT", 112, true, function(v) setStatus(v and "Verify ON" or "Verify OFF", "info") end)
antiAfkToggle = makeToggle(settingsPage, "ANTI-AFK PROTECTION", 140, true, function(v) setStatus(v and "Anti-AFK ON" or "Anti-AFK OFF", "info") end)
searchBox:GetPropertyChangedSignal("Text"):Connect(function()
    local t = searchBox.Text:lower()
    if t == "" then return end
    if t:find("world") or t:find("normal") or t:find("prehistoric") then setTab("MAIN")
    elseif t:find("esp") then setTab("ESP")
    elseif t:find("aim") or t:find("combat") or t:find("shoot") then setTab("COMBAT")
    elseif t:find("setting") or t:find("config") then setTab("SETTINGS")
    end
end)
refreshUI = function()
    if espToggle then espToggle.set(CONFIG.ESP_ENABLED) end
    if aimToggle then aimToggle.set(CONFIG.AUTO_AIM) end
    if myDownedToggle then myDownedToggle.set(CONFIG.MY_DOWNED_ONLY) end
    if smartToggle then smartToggle.set(CONFIG.SMART_SCORE) end
    if stickyToggle then stickyToggle.set(CONFIG.STICKY_TARGET) end
    if collectBtn then collectBtn.Text = CONFIG.AUTO_COLLECT and "AUTO-COLLECT: ON" or "AUTO-COLLECT: OFF"; collectBtn.BackgroundColor3 = CONFIG.AUTO_COLLECT and C.accent or C.card end
    if scopeBtn then scopeBtn.Text = CONFIG.AUTO_AIM and "SCOPE / AUTO-AIM: ON" or "SCOPE / AUTO-AIM: OFF"; scopeBtn.BackgroundColor3 = CONFIG.AUTO_AIM and C.accent or C.card end
    if espModeBtn then espModeBtn.Text = "Mode: "..CONFIG.ESP_MODE end
    if worldBtn then worldBtn.Text = "World: "..(CONFIG.WORLD_FILTER == "Both" and "BOTH" or CONFIG.WORLD_FILTER).." - "..CONFIG.CurrentWorld end
    if worldNormalBtn then worldNormalBtn.BackgroundColor3 = (CONFIG.CurrentWorld == "Normal") and C.accent or C.card end
    if worldPrehistoricBtn then worldPrehistoricBtn.BackgroundColor3 = (CONFIG.CurrentWorld == "Prehistoric") and C.accent or C.card end
    if telePets then telePets.value.Text = tostring(petCount); telePets.sub.Text = "Base excluded - "..CONFIG.CurrentWorld end
    if teleTop then
        if topPet and topInfo then teleTop.value.Text = tostring(topInfo.display); teleTop.sub.Text = tostring(topPet.Name):sub(1,14).." - "..getPetWorld(topPet)
        else teleTop.value.Text = "-"; teleTop.sub.Text = "No wild pets" end
    end
    if teleDowned then teleDowned.value.Text = tostring(downedCount); teleDowned.sub.Text = "My only: "..(CONFIG.MY_DOWNED_ONLY and "ON" or "OFF") end
    if statsLabel then statsLabel.Text = string.format("Pets %d (wild) - ESP %s - Aim %s - Collect %s - World %s", petCount, CONFIG.ESP_ENABLED and "ON" or "OFF", CONFIG.AUTO_AIM and "ON" or "OFF", CONFIG.AUTO_COLLECT and "ON" or "OFF", CONFIG.CurrentWorld) end
    if downedLabel then downedLabel.Text = string.format("Downed: %d %s", downedCount, collectState ~= "IDLE" and ("| Collect: "..collectState) or "") end
    if minigameStatus then minigameStatus.Text = "Ducks: " .. tostring(MinigameStats.tapped) .. (isMinigameOpen() and " - OPEN" or " - closed") end
    if minigameToggle then minigameToggle.set(CONFIG.AUTO_MINIGAME) end
    if miniBtn then miniBtn.Text = CONFIG.ESP_ENABLED and "ESP ON" or "ESP OFF" end
    if combatTopLabel and topPet and topInfo then combatTopLabel.Text = "TOP: "..tostring(topPet.Name):sub(1,20).." | "..tostring(topInfo.display) end
end
miniBtn.Activated:Connect(function() CONFIG.ESP_ENABLED = not CONFIG.ESP_ENABLED; refreshUI() setStatus(CONFIG.ESP_ENABLED and "ESP ON" or "ESP OFF", CONFIG.ESP_ENABLED and "ok" or "warn") end)
aimSpotBtn.Activated:Connect(function() showPill() goToAimSpot() end)
baseBtn.Activated:Connect(function() showPill() goToBase() end)
function toggleAim()
    CONFIG.AUTO_AIM = not CONFIG.AUTO_AIM; refreshUI(); showPill()
    if CONFIG.AUTO_AIM then setStatus("AUTO-AIM ON - lead + sticky + shot verify", "ok") pcall(tryScope) else setStatus("AUTO-AIM OFF", "warn") end
end
scopeBtn.Activated:Connect(toggleAim)
collectBtn.Activated:Connect(function()
    CONFIG.AUTO_COLLECT = not CONFIG.AUTO_COLLECT; refreshUI(); showPill()
    if CONFIG.AUTO_COLLECT then setStatus("AUTO-COLLECT ON - my downed -> base -> aim", "ok") else setStatus("AUTO-COLLECT OFF", "warn") end
end)
worldNormalBtn.Activated:Connect(function() showPill() chooseWorld("Normal") refreshUI() end)
worldPrehistoricBtn.Activated:Connect(function() showPill() chooseWorld("Prehistoric") refreshUI() end)
worldBtn.Activated:Connect(function()
    if CONFIG.WORLD_FILTER == "Both" then CONFIG.WORLD_FILTER = "W1" elseif CONFIG.WORLD_FILTER == "W1" then CONFIG.WORLD_FILTER = "W2" else CONFIG.WORLD_FILTER = "Both" end
    refreshUI(); setStatus("World filter: "..CONFIG.WORLD_FILTER.." (Current: "..CONFIG.CurrentWorld..")", "info")
    for pet, e in pairs(espCache) do pcall(function() if e.gui then e.gui:Destroy() end end) pcall(function() if e.hl then e.hl:Destroy() end end) end espCache = {}
end)
espModeBtn.Activated:Connect(function()
    if CONFIG.ESP_MODE == "TOP" then CONFIG.ESP_MODE = "ALL" elseif CONFIG.ESP_MODE == "ALL" then CONFIG.ESP_MODE = "DOWNED" else CONFIG.ESP_MODE = "TOP" end
    refreshUI(); setStatus("ESP Mode: "..CONFIG.ESP_MODE, "info")
    for pet, e in pairs(espCache) do pcall(function() if e.gui then e.gui:Destroy() end end) pcall(function() if e.hl then e.hl:Destroy() end end) end espCache = {}
end)
clearBtn.Activated:Connect(function()
    for pet, e in pairs(espCache) do pcall(function() if e.gui then e.gui:Destroy() end end) pcall(function() if e.hl then e.hl:Destroy() end end) end espCache = {}
    setStatus("ESP cleared", "info")
end)
diagBtn.Activated:Connect(function()
    local pets = getAllPets()
    local downed = getDownedPets(CONFIG.WORLD_FILTER)
    print("[PetESP v6 DIAG] Minigame open: " .. tostring(isMinigameOpen()) .. " | Ducks tapped: " .. tostring(MinigameStats.tapped) .. " | AutoMinigame: " .. tostring(CONFIG.AUTO_MINIGAME) .. " | " .. "[PetESP v6 DIAG] Wild:", #pets, "| Downed (my only):", #downed, "| World:", CONFIG.CurrentWorld, "Filter:", CONFIG.WORLD_FILTER, "| ESP:", CONFIG.ESP_MODE, "| Collect:", CONFIG.AUTO_COLLECT, "| State:", collectState)
    print("[PetESP v6 DIAG] ESP Universal: cached "..tostring(#PET_SCAN_CACHE).." pets | If 0, pets are not in workspace - check streaming / folder")
    print("[PetESP v6 DIAG] Base:", tostring(CONFIG.BASE_POS), "| Aim:", tostring(CONFIG.AIM_POS), "| You:", getHRP() and tostring(getHRP().Position) or "no char")
    for i, pet in ipairs(pets) do if i > 8 then break end local info = getPetValueCached(pet) local w = getPetWorld(pet) local pos = getPetCenter(pet) local d, t = isDownedLatched(pet) print(string.format("[PetESP v6 DIAG] %s | %s - %s | W %s | smart %.0f | pos %.0f,%.0f,%.0f | Downed %s %s | InBase %s", pet.Name, tostring(info.rarity), tostring(info.display), w, getSmartScore(pet, info, (pos - CONFIG.AIM_POS).Magnitude, isAirPet(pet)), pos.X, pos.Y, pos.Z, tostring(d), tostring(t), tostring(isInBase(pet)))) pcall(function() for k,v in pairs(pet:GetAttributes()) do print("  Attr", k, "=", tostring(v)) end end) end
    for _, e in ipairs(downed) do print("[PetESP v6 DIAG] DOWNED (mine):", e.pet.Name, e.info.display, "timer", e.timer, "latched", tostring(e.latched), "dist", math.floor(e.dist)) end
    local tp, ti = getTopPetSmart(CONFIG.WORLD_FILTER)
    if tp then print("[PetESP v6 DIAG] TOP SMART:", tp.Name, ti.rarity, ti.display, "World", getPetWorld(tp)) setStatus("DIAG: TOP "..tp.Name:sub(1,18).." ("..tostring(ti.display)..") | Downed "..#downed.." - F9", "info") else print("[PetESP v6 DIAG] TOP: none") setStatus("DIAG: no wild pets - try other World (Normal/Prehistoric)", "err") end
end)
saveConfigBtn.Activated:Connect(function() setStatus("Config saved: "..configNameBox.Text, "ok") end)
resetLayoutBtn.Activated:Connect(function() main.Position = UDim2.new(0.5,-270,0.5,-180) setStatus("Layout reset", "info") end)
collapseBtn.Activated:Connect(function() main.Visible = false; mini.Visible = true; mini.Position = UDim2.new(0.5,-70,0,60) end)
expandBtn.Activated:Connect(function() mini.Visible = false; main.Visible = true end)
closeBtn.Activated:Connect(function() CONFIG.AUTO_AIM = false; CONFIG.AUTO_COLLECT = false; CONFIG.ESP_ENABLED = false; for pet, e in pairs(espCache) do pcall(function() if e.gui then e.gui:Destroy() end end) pcall(function() if e.hl then e.hl:Destroy() end end) end hidePill() gui:Destroy() end)
UIS.InputBegan:Connect(function(input, processed) if processed then return end if input.KeyCode == Enum.KeyCode.RightShift then gui.Enabled = not gui.Enabled end end)
setTab("MAIN")


-- ===== UNIFIED AIM + SHOOT =====
-- Camera CFrame lookAt is primary (works even when scoped), VIM mouse move as backup

local function findShootButton()
    local found = nil
    local function scanGui(root)
        if not root then return end
        local ok, desc = pcall(function() return root:GetDescendants() end)
        if not ok or not desc then return end
        for _, d in ipairs(desc) do
            if d:IsA("TextButton") or d:IsA("ImageButton") then
                local txt = "" pcall(function() txt = tostring(d.Text or "") end)
                local nm = d.Name or ""
                if string.find(string.upper(txt), "SHOOT", 1, true) or string.find(string.upper(nm), "SHOOT", 1, true) then
                    if d.Visible and d.AbsoluteSize.X > 10 then found = d return end
                end
            end
        end
    end
    pcall(function() scanGui(playerGui) end)
    if not found then pcall(function() scanGui(game:GetService("CoreGui")) end) end
    return found
end

local function aimAtPet(pet)
    if not pet or not pet.Parent then return false end
    local cam = workspace.CurrentCamera
    if not cam then return false end
    local aimPoint = nil
    pcall(function() aimPoint = getAimPoint(pet, cam.CFrame.Position) end)
    if not aimPoint then pcall(function() aimPoint = getPetCenter(pet) end) end
    if not aimPoint then return false end
    local v, on = cam:WorldToViewportPoint(aimPoint)
    if not on or v.Z <= 0 then return false end
    -- PRIMARY: VIM mouse move (game scoped camera follows mouse, works even when scoped)
    local okVIM = pcall(function()
        local VIM = game:GetService("VirtualInputManager")
        VIM:SendMouseMoveEvent(v.X, v.Y, game)
    end)
    -- FALLBACK: only set camera CFrame when NOT scoped (scoped camera overrides CFrame every frame)
    local fov = 70
    pcall(function() fov = cam.FieldOfView end)
    local isScoped = fov < 40
    if not isScoped then
        pcall(function() cam.CFrame = CFrame.lookAt(cam.CFrame.Position, aimPoint) end)
    end
    return okVIM
end

local function shootPet(pet)
    if os.clock() - lastShotAt < CONFIG.SHOOT_COOLDOWN then return false end
    if not shouldShoot(pet) then
        aimAtPet(pet)
        return false
    end
    lastShotAt = os.clock()
    recordShot(pet)
    local shot = false
    -- 1) SHOOT GUI button with ammo check
    local shootBtn = findShootButton()
    if shootBtn then
        local ammo = nil
        pcall(function()
            local txt = tostring(shootBtn.Text or "")
            local a = txt:match("(%d+)%s*/%s*%d+")
            if a then ammo = tonumber(a) end
        end)
        if ammo ~= nil and ammo <= 0 then
            setStatus("SHOOT: out of ammo - waiting reload", "warn")
            return false
        end
        pcall(function() if firesignal then firesignal(shootBtn.Activated) shot = true end end)
        if not shot then pcall(function() shootBtn:Activate() shot = true end) end
        if not shot then pcall(function()
            local VIM = game:GetService("VirtualInputManager")
            local pos = shootBtn.AbsolutePosition local sz = shootBtn.AbsoluteSize
            local cx, cy = pos.X + sz.X/2, pos.Y + sz.Y/2
            VIM:SendMouseButtonEvent(cx, cy, 0, true, game, 0)
            task.wait(0.05)
            VIM:SendMouseButtonEvent(cx, cy, 0, false, game, 0)
            shot = true
        end) end
        if shot then print("[PetESP v6] Shoot via SHOOT button, ammo "..tostring(ammo)) return true end
    end
    -- 2) Tool Activate
    pcall(function()
        local ch = player.Character
        if ch then local tool = ch:FindFirstChildOfClass("Tool") if tool then tool:Activate() shot = true end end
    end)
    if shot then print("[PetESP v6] Shoot via Tool") return true end
    -- 3) Center click
    pcall(function()
        local VIM = game:GetService("VirtualInputManager")
        local cam = workspace.CurrentCamera
        local vs = cam and cam.ViewportSize or Vector2.new(800,600)
        VIM:SendMouseButtonEvent(vs.X/2, vs.Y/2, 0, true, game, 0)
        task.wait(0.05)
        VIM:SendMouseButtonEvent(vs.X/2, vs.Y/2, 0, false, game, 0)
        shot = true
    end)
    if shot then print("[PetESP v6] Shoot via center click") return true end
    -- 4) Remote
    pcall(function()
        local RS = game:GetService("ReplicatedStorage")
        for _, d in ipairs(RS:GetDescendants()) do
            if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
                local n = string.lower(d.Name)
                if string.find(n, "shoot", 1, true) or string.find(n, "fire", 1, true) or string.find(n, "cannon", 1, true) then
                    if d:IsA("RemoteEvent") then d:FireServer(pet, getPetCenter(pet)) else d:InvokeServer(pet, getPetCenter(pet)) end
                    shot = true print("[PetESP v6] Shoot via Remote:", d:GetFullName()) break
                end
            end
        end
    end)
    return shot
end

-- Auto-aim tick: aim at top pet every frame, shoot when crosshair on target
local function autoAimTick()
    if not CONFIG.AUTO_AIM then return end
    if collectState ~= "IDLE" then return end
    if not topPet or not topPet.Parent then
        setStatus("Auto-Aim ON - no wild pets (base excluded)", "warn")
        return
    end
    local isD = false pcall(function() isD = isDowned(topPet) end)
    if isD then return end
    if os.clock() - lastAimAt > 1 then pcall(tryScope) end
    local pos = getPetCenter(topPet)
    local distAim = math.floor((pos - CONFIG.AIM_POS).Magnitude)
    local info = topInfo or getPetValue(topPet)
    aimAtPet(topPet)
    if topLabel then topLabel.Text = "TOP: "..tostring(topPet.Name):sub(1,20).." | "..tostring(info.rarity).." "..tostring(info.display).." | "..getPetWorld(topPet).." | "..tostring(distAim).." studs" end
    if lastTarget ~= topPet then lastTarget = topPet AirAimState.frames = 0 end
    if shouldShoot(topPet) then shootPet(topPet) end
end

-- ===== UNIFIED MINIGAME =====
-- Detects duck minigame UI by score/combo/next/speed/bonus text, taps ducks via VIM + Activate

MinigameLastPos = {}
local function findMinigameGui()
    local guis = {}
    pcall(function() table.insert(guis, playerGui) end)
    pcall(function() local h = hostFor() if h then table.insert(guis, h) end end)
    pcall(function() table.insert(guis, game:GetService("CoreGui")) end)
    for _, root in ipairs(guis) do
        if root then
            local ok, desc = pcall(function() return root:GetDescendants() end)
            if ok and desc then
                for _, f in ipairs(desc) do
                    if f:IsA("Frame") or f:IsA("ScrollingFrame") or f:IsA("CanvasGroup") then
                        if not f.Visible then continue end
                        local sg = f:FindFirstAncestorWhichIsA("ScreenGui")
                        if sg and sg.Enabled == false then continue end
                        local sz = f.AbsoluteSize
                        if sz.X > 60 and sz.Y > 60 then
                            local textCount = 0
                            local hasMinigameKeyword = false
                            local hasDuckKeyword = false
                            pcall(function()
                                for _, d in ipairs(f:GetDescendants()) do
                                    if d:IsA("TextLabel") or d:IsA("TextButton") then
                                        local t = string.lower(tostring(d.Text or ""))
                                        textCount = textCount + 1
                                        if string.find(t, "score", 1, true) or string.find(t, "combo", 1, true) or string.find(t, "next", 1, true) or string.find(t, "speed", 1, true) or string.find(t, "bonus", 1, true) or string.find(t, "duck", 1, true) or string.find(t, "target", 1, true) or string.find(t, "shoot", 1, true) then
                                            hasMinigameKeyword = true
                                        end
                                        if string.find(t, "duck", 1, true) or string.find(t, "bird", 1, true) then
                                            hasDuckKeyword = true
                                        end
                                    end
                                end
                            end)
                            local ln = string.lower(f.Name or "")
                            local nameMatch = string.find(ln, "minigame", 1, true) or string.find(ln, "treadmill", 1, true) or string.find(ln, "duck", 1, true) or string.find(ln, "shoot", 1, true) or string.find(ln, "target", 1, true) or string.find(ln, "game", 1, true)
                            if (hasMinigameKeyword and textCount >= 2) or nameMatch or hasDuckKeyword then
                                return f
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end
local function isMinigameOpen() return findMinigameGui() ~= nil end

local function findDucks()
    local out = {}
    local mg = findMinigameGui()
    if not mg then return out, nil end
    local mgPos = mg.AbsolutePosition
    local mgSize = mg.AbsoluteSize
    local ok, desc = pcall(function() return mg:GetDescendants() end)
    if not ok or not desc then return out, mg end
    for _, d in ipairs(desc) do
        pcall(function()
            if (d:IsA("ImageLabel") or d:IsA("ImageButton") or d:IsA("TextButton") or d:IsA("GuiButton")) and d.Visible then
                local sz = d.AbsoluteSize
                -- Ducks/targets are typically 20-200px
                if sz.X >= 15 and sz.X <= 200 and sz.Y >= 15 and sz.Y <= 200 then
                    local n = string.lower(d.Name or "")
                    -- Only exclude obvious non-duck UI elements
                    local excluded = string.find(n, "score", 1, true) or string.find(n, "combo", 1, true) or string.find(n, "background", 1, true) or string.find(n, "backdrop", 1, true) or string.find(n, "border", 1, true) or string.find(n, "frame", 1, true) or string.find(n, "panel", 1, true)
                    if not excluded then
                        local relY = (d.AbsolutePosition.Y - mgPos.Y) / math.max(1, mgSize.Y)
                        local relX = (d.AbsolutePosition.X - mgPos.X) / math.max(1, mgSize.X)
                        -- Must be inside the minigame frame bounds
                        if relY >= 0 and relY <= 1 and relX >= 0 and relX <= 1 then
                            local last = MinigameLastPos[d]
                            local moved = false
                            if last then
                                if (d.AbsolutePosition - last).Magnitude > 3 then moved = true end
                            end
                            MinigameLastPos[d] = d.AbsolutePosition
                            -- Include: named duck/bird/target, OR moving, OR small image (likely a sprite)
                            local isNamed = string.find(n, "duck", 1, true) or string.find(n, "bird", 1, true) or string.find(n, "target", 1, true) or string.find(n, "enemy", 1, true) or string.find(n, "shoot", 1, true)
                            if isNamed or moved or (d:IsA("ImageLabel") and sz.X >= 20 and sz.X <= 100 and sz.Y >= 20 and sz.Y <= 100) then
                                table.insert(out, d)
                            end
                        end
                    end
                end
            end
        end)
    end
    local seen = {}
    local uniq = {}
    for _, d in ipairs(out) do if not seen[d] then seen[d] = true table.insert(uniq, d) end end
    -- 3D fallback: workspace ducks with ClickDetector
    pcall(function()
        for _, m in ipairs(workspace:GetDescendants()) do
            if m:IsA("Model") then
                local mn = string.lower(m.Name or "")
                if string.find(mn, "duck", 1, true) or string.find(mn, "bird", 1, true) or string.find(mn, "target", 1, true) then
                    local cd = m:FindFirstChildOfClass("ClickDetector", true)
                    if cd then table.insert(uniq, { _is3D = true, model = m, detector = cd, Name = m.Name }) end
                end
            end
        end
    end)
    return uniq, mg
end

local function autoTapDuck(duck)
    local key = duck
    if duck._is3D then key = duck.model end
    local now = os.clock()
    if MinigameTapped[key] and now - MinigameTapped[key] < 0.3 then return false end
    MinigameTapped[key] = now
    local tapped = false
    if duck._is3D then
        pcall(function()
            if fireclickdetector then fireclickdetector(duck.detector) tapped = true end
        end)
        if not tapped then
            pcall(function()
                local cam = workspace.CurrentCamera
                local pos = duck.model:GetPivot().Position
                local v, on = cam:WorldToViewportPoint(pos)
                if on then
                    local VIM = game:GetService("VirtualInputManager")
                    VIM:SendMouseMoveEvent(v.X, v.Y, game)
                    VIM:SendMouseButtonEvent(v.X, v.Y, 0, true, game)
                    task.wait(0.03)
                    VIM:SendMouseButtonEvent(v.X, v.Y, 0, false, game)
                    tapped = true
                end
            end)
        end
    else
        -- GUI duck: Activate + VIM click at center
        pcall(function()
            if duck:IsA("GuiButton") then duck:Activate() tapped = true end
        end)
        pcall(function()
            local VIM = game:GetService("VirtualInputManager")
            local pos = duck.AbsolutePosition
            local sz = duck.AbsoluteSize
            local cx, cy = pos.X + sz.X/2, pos.Y + sz.Y/2
            VIM:SendMouseMoveEvent(cx, cy, game)
            task.wait(0.01)
            VIM:SendMouseButtonEvent(cx, cy, 0, true, game)
            task.wait(0.03)
            VIM:SendMouseButtonEvent(cx, cy, 0, false, game)
            tapped = true
        end)
    end
    if tapped then
        MinigameStats.tapped = MinigameStats.tapped + 1
        MinigameStats.lastTapAt = now
        MinigameStats.lastDuckName = tostring(duck.Name or "Duck")
    end
    return tapped
end

local function minigameTick()
    if not CONFIG.AUTO_MINIGAME then return 0 end
    local mg = findMinigameGui()
    if not mg then return 0 end
    local ducks = findDucks()
    local tappedNow = 0
    for _, d in ipairs(ducks) do
        if autoTapDuck(d) then tappedNow = tappedNow + 1 end
    end
    if tappedNow > 0 then
        setStatus("DUCK tapped x" .. tostring(MinigameStats.tapped) .. " (+" .. tostring(tappedNow) .. ")", "ok")
    end
    return tappedNow
end

local MinigameLoopRunning = false
local function startMinigameLoop()
    if MinigameLoopRunning then return end
    MinigameLoopRunning = true
    task.spawn(function()
        while CONFIG.AUTO_MINIGAME do
            local ok, err = pcall(function() minigameTick() end)
            if not ok then print("[PetESP v6] minigameTick err:", err) end
            task.wait(0.08)
        end
        MinigameLoopRunning = false
    end)
end

-- Auto-start minigame loop when AUTO_MINIGAME is enabled AND minigame GUI is detected
local MinigameAutoStartChecked = false
local function ensureMinigameLoop()
    if not CONFIG.AUTO_MINIGAME then return end
    if MinigameLoopRunning then return end
    -- Only try to start if we can detect the minigame UI (or just start anyway so it's ready)
    startMinigameLoop()
end

local function setAutoMinigame(on)
    CONFIG.AUTO_MINIGAME = on
    if on then
        MinigameStats.tapped = 0
        MinigameTapped = {}
        setStatus("AUTO MINIGAME ON - tapping ducks...", "ok")
        startMinigameLoop()
    else
        setStatus("AUTO MINIGAME OFF - tapped " .. tostring(MinigameStats.tapped) .. " ducks", "warn")
    end
    if refreshUI then refreshUI() end
    showPill()
end

-- ===== AUTO-COLLECT (state machine) =====
-- Priority: collect downed pet -> TP to base -> return to aim. Pauses aim while busy.

local function collectDownedPet(entry)
    local pet = entry.pet
    if not pet or not pet.Parent then return end
    local id = tostring(pet:GetDebugId())
    if collectBusy[id] then return end
    if os.clock() - lastCollectAt < CONFIG.COLLECT_COOLDOWN then return end
    lastCollectAt = os.clock()
    collectBusy[id] = true
    collectState = "GOTO_DOWNED"
    local pos = entry.pos or getPetCenter(pet)
    setStatus("DOWNED: "..tostring(pet.Name):sub(1,18).." ("..tostring(entry.info.display)..") "..tostring(entry.timer).." - collecting...", "warn")
    -- TP to downed pet with offset
    tpTo(pos + Vector3.new(3, 2, 3))
    task.wait(0.5)
    -- Verify still downed
    local stillDowned = false pcall(function() stillDowned = isDowned(pet) end)
    if not stillDowned then
        setStatus("Downed pet gone - back to aim", "warn")
        collectState = "IDLE"
        if CONFIG.AUTO_AIM then tpTo(CONFIG.AIM_POS) end
        task.wait(0.3)
        task.delay(10, function() collectBusy[id] = nil end)
        return
    end
    collectState = "COLLECT"
    setStatus("Collecting "..tostring(pet.Name):sub(1,18).."...", "warn")
    tryCollectInteract(pet)
    task.wait(0.6)
    -- TP to base to deposit
    collectState = "TP_BASE"
    setStatus("Collected! TP to base 5977, 3, 99...", "ok")
    tpTo(CONFIG.BASE_POS + Vector3.new(0, 3, 0))
    task.wait(0.8)
    -- Return to aim spot if auto-aim is on
    if CONFIG.AUTO_AIM then
        collectState = "RETURN_AIM"
        tpTo(CONFIG.AIM_POS)
        task.wait(0.4)
    end
    collectState = "IDLE"
    task.delay(10, function() collectBusy[id] = nil end)
    setStatus("Collected "..tostring(pet.Name):sub(1,18).." -> base. Back to aim.", "ok")
end

local function autoCollectTick()
    if not CONFIG.AUTO_COLLECT then return end
    if collectState ~= "IDLE" then return end
    local downed = getDownedPets(CONFIG.WORLD_FILTER)
    downedCount = #downed
    if #downed > 0 then
        task.spawn(function() collectDownedPet(downed[1]) end)
    else
        downedCount = 0
    end
end

-- ===== MAIN LOOP (single Heartbeat-driven) =====
local lastEspAt = 0
local lastTopAt = 0
RunService.Heartbeat:Connect(function()
    if not gui or not gui.Parent then return end
    local ok, err = pcall(function()
        local now = os.clock()

        -- Collect has highest priority
        if CONFIG.AUTO_COLLECT then autoCollectTick() end

        -- ESP + top pet refresh (rate limited)
        if now - lastEspAt >= CONFIG.ESP_REFRESH then
            lastEspAt = now
            local tp, ti = getTopPetSmart(CONFIG.WORLD_FILTER)
            topPet = tp; topInfo = ti
            updateESP()
            if tp and ti then
                local pos = getPetCenter(tp)
                local distAim = math.floor((pos - CONFIG.AIM_POS).Magnitude)
                local hrp = getHRP()
                local distYou = hrp and math.floor((pos - hrp.Position).Magnitude) or 0
                if topLabel then topLabel.Text = "TOP: "..tostring(tp.Name):sub(1,20).." | "..tostring(ti.rarity).." "..tostring(ti.display).." | "..getPetWorld(tp).." | "..tostring(distAim).."m aim / "..tostring(distYou).."m you" end
            else
                if topLabel then topLabel.Text = "TOP: — (no wild pets, base excluded)" end
            end
            refreshUI()
        end

        -- Auto-aim (every frame while idle)
        if CONFIG.AUTO_AIM then autoAimTick() end

        -- Shot verify
        checkShotVerify()
    end)
    if not ok then print("[PetESP v6] tick error:", err) end
end)

refreshUI()
showPill()
setStatus("Pet ESP v6 READY - ESP, aim, shoot, collect, minigame. Press DIAG to test.", "ok")
