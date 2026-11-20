-- ============================================================================
-- PET ESP DIAGNOSTIC v1  (run this INSTEAD of the hub, then paste the output)
-- It changes nothing. It only measures what the hub assumes is true.
-- ============================================================================
local P = "[DIAG]"
local Players = game:GetService("Players")
local WS      = game:GetService("Workspace")
local RS      = game:GetService("ReplicatedStorage")
local UIS     = game:GetService("UserInputService")
local LP      = Players.LocalPlayer

local function log(...) print(P, ...) end
local function safe(label, fn)
    local ok, err = pcall(fn)
    if not ok then print(P, "ERROR in " .. label .. ": " .. tostring(err)) end
end

-- same constants as the hub
local BASE_POS    = Vector3.new(5977, 3, 99)
local BASE_RADIUS = 90
local BASE_BOX    = {X_MIN = 5900, X_MAX = 6050, Z_MIN = 20, Z_MAX = 180}
local ESP_MAX_DIST = 500

local function isInBase(pos)
    if not pos then return false end
    if (pos - BASE_POS).Magnitude <= BASE_RADIUS then return true end
    if pos.X >= BASE_BOX.X_MIN and pos.X <= BASE_BOX.X_MAX
       and pos.Z >= BASE_BOX.Z_MIN and pos.Z <= BASE_BOX.Z_MAX then return true end
    return false
end

local function rootOf(m)
    if m:IsA("BasePart") then return m end
    if m:IsA("Model") then
        if m.PrimaryPart and m.PrimaryPart:IsA("BasePart") then return m.PrimaryPart end
        local hrp = m:FindFirstChild("HumanoidRootPart")
        if hrp and hrp:IsA("BasePart") then return hrp end
        local c = m:FindFirstChildWhichIsA("BasePart")
        if c then return c end
        for _, d in ipairs(m:GetDescendants()) do
            if d:IsA("BasePart") then return d end
        end
    end
    return nil
end

local char = LP.Character
local hrp = char and char:FindFirstChild("HumanoidRootPart")
local myPos = hrp and hrp.Position or Vector3.new()

print(P, "================ START DIAGNOSTIC ================")

safe("env", function()
    local ex = "n/a"
    pcall(function() ex = identifyexecutor() end)
    log("executor:", tostring(ex))
    log("TouchEnabled:", tostring(UIS.TouchEnabled), "| MouseEnabled:", tostring(UIS.MouseEnabled))
    log("TouchEnabled && not MouseEnabled (hub IS_MOBILE):", tostring(UIS.TouchEnabled and not UIS.MouseEnabled))
    local cam = WS.CurrentCamera
    log("CurrentCamera:", cam and cam:GetFullName() or "NIL", "| ViewportSize:",
        cam and tostring(cam.ViewportSize) or "n/a")
    log("my position:", tostring(myPos))
end)

-- ---------------------------------------------------------------- streaming
safe("streaming", function()
    log("Workspace.StreamingEnabled:", tostring(WS.StreamingEnabled))
    if WS.StreamingEnabled then
        log(">>> WARNING: streaming ON. Distant zone pets are NOT replicated to the client.")
    end
    local names = {}
    for _, c in ipairs(WS:GetChildren()) do
        table.insert(names, c.Name .. "(" .. c.ClassName .. ")")
    end
    log("Workspace children:", table.concat(names, ", "))
end)

-- ---------------------------------------------------------------- Zones class
safe("zones", function()
    local folders, anyClass = 0, {}
    for _, d in ipairs(WS:GetDescendants()) do
        if d.Name == "Zones" then
            table.insert(anyClass, d)
            if d:IsA("Folder") then folders = folders + 1 end
        end
    end
    log("Instances named 'Zones':", #anyClass, "| of which are Folder:", folders)
    for i, z in ipairs(anyClass) do
        if i <= 10 then
            log("  Zones[" .. i .. "]", z:ClassName, z:GetFullName(), "| children:", #z:GetChildren())
        end
    end
    if #anyClass > 0 and folders == 0 then
        log(">>> FINDING 1 CONFIRMED: 'Zones' is NOT a Folder. Hub ignores it (line 310).")
    end
end)

-- ---------------------------------------------------------- spawn structure
safe("spawns", function()
    local totalZones, totalSpawnFolders, totalSpawnKids = 0, 0, 0
    local shown = 0
    for _, d in ipairs(WS:GetDescendants()) do
        if d.Name == "Zones" then
            for _, zone in ipairs(d:GetChildren()) do
                totalZones = totalZones + 1
                local sp = zone:FindFirstChild("Spawns")
                if not sp then
                    for _, c in ipairs(zone:GetChildren()) do
                        if c.Name:lower():find("spawn", 1, true) then sp = c break end
                    end
                end
                if sp then
                    totalSpawnFolders = totalSpawnFolders + 1
                    totalSpawnKids = totalSpawnKids + #sp:GetChildren()
                    if shown < 6 then
                        for _, k in ipairs(sp:GetChildren()) do
                            if shown < 6 then
                                shown = shown + 1
                                local r = rootOf(k)
                                log("  SAMPLE", k.ClassName, k:GetFullName(),
                                    "| rootPart:", r and r.Name or "NIL",
                                    "| pos:", r and tostring(r.Position) or "n/a")
                                local attrs, n = {}, 0
                                for kk, vv in pairs(k:GetAttributes()) do
                                    n = n + 1
                                    if n <= 6 then table.insert(attrs, kk .. "=" .. tostring(vv)) end
                                end
                                log("    attributes:", #attrs > 0 and table.concat(attrs, ", ") or "(none)")
                            end
                        end
                    end
                end
            end
        end
    end
    log("subzones:", totalZones, "| with a Spawns-like child:", totalSpawnFolders,
        "| total spawn entries:", totalSpawnKids)
    if totalSpawnFolders == 0 then
        log(">>> FINDING 3 CONFIRMED: no child named 'Spawns' under any zone.")
    end
end)

-- ------------------------------------------------ how many the hub would keep
safe("hub_simulation", function()
    local found, noRoot, inBaseCnt, tooFar, ok = 0, 0, 0, 0, 0
    for _, d in ipairs(WS:GetDescendants()) do
        if d.Name == "Zones" and d:IsA("Folder") then
            for _, zone in ipairs(d:GetChildren()) do
                local sp = zone:FindFirstChild("Spawns")
                if sp then
                    for _, k in ipairs(sp:GetChildren()) do
                        if k:IsA("Model") or k:IsA("BasePart") then
                            found = found + 1
                            local r = rootOf(k)
                            if not r then noRoot = noRoot + 1
                            else
                                local dist = (r.Position - myPos).Magnitude
                                if isInBase(r.Position) then inBaseCnt = inBaseCnt + 1
                                elseif dist >= ESP_MAX_DIST then tooFar = tooFar + 1
                                else ok = ok + 1 end
                            end
                        end
                    end
                end
            end
        end
    end
    log("HUB SIM -> discovered:", found, "| noRootPart:", noRoot,
        "| filtered as IN BASE:", inBaseCnt, "| beyond 500m:", tooFar, "| WOULD SHOW:", ok)
    if found > 0 and ok == 0 then
        log(">>> FINDING 4/5 CONFIRMED: pets exist but every one is dropped (base filter / no root part / distance).")
        log("    isInBase at my position:", tostring(isInBase(myPos)))
    end
end)

-- ------------------------------------------------------------- interaction
safe("prompts", function()
    local n, shown = 0, 0
    for _, d in ipairs(WS:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            n = n + 1
            if shown < 10 then
                shown = shown + 1
                log("  PROMPT", d:GetFullName(), "| ActionText:", tostring(d.ActionText),
                    "| ObjectText:", tostring(d.ObjectText), "| Hold:", tostring(d.HoldDuration),
                    "| Enabled:", tostring(d.Enabled))
            end
        end
    end
    log("ProximityPrompts in workspace:", n)
end)

safe("remotes", function()
    local names = {}
    for _, d in ipairs(RS:GetDescendants()) do
        if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
            table.insert(names, d.Name)
        end
    end
    log("ReplicatedStorage remotes (" .. #names .. "):",
        #names > 0 and table.concat(names, ", ", 1, math.min(#names, 25)) or "(none)")
end)

safe("gui_buttons", function()
    local pg = LP:FindFirstChild("PlayerGui")
    if not pg then log("PlayerGui: NIL") return end
    local guiNames = {}
    for _, g in ipairs(pg:GetChildren()) do table.insert(guiNames, g.Name) end
    log("PlayerGui children:", #guiNames > 0 and table.concat(guiNames, ", ") or "(none)")
    local shown = 0
    for _, d in ipairs(pg:GetDescendants()) do
        if (d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible and shown < 15 then
            shown = shown + 1
            log("  BTN", d:GetFullName(), "| text:", tostring(d.Text),
                "| size:", tostring(d.AbsoluteSize))
        end
    end
    if shown == 0 then log(">>> no visible buttons in PlayerGui") end
end)

safe("executor_funcs", function()
    local names = {"firesignal", "fireproximityprompt", "fireclickdetector", "getconnections"}
    for _, n in ipairs(names) do
        local v = rawget(getfenv(), n)
        log(n .. ":", type(v) == "function" and "yes" or "NO")
    end
end)

print(P, "================= END DIAGNOSTIC ==================")
print(P, "Copy EVERYTHING above and paste it back.")
