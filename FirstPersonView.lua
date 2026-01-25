
-- first person view controller (client)
-- focuses on camera cframe, mouse lock, local character hiding, and zoom fov

local Players = game:GetService("Players") -- local player + character events
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- shared config/state modules
local UserInputService = game:GetService("UserInputService") -- mouse delta + key binds
local RunService = game:GetService("RunService") -- renderstep/heartbeat loops

local player = Players.LocalPlayer -- client owner

-- always fetch CurrentCamera by call
-- some experiences replace the camera instance during transitions
local function getCamera()
    return workspace.CurrentCamera
end

local camera = getCamera() -- initial camera ref (may change later)

-- fp system modules (config + shared state)
local folder = ReplicatedStorage:WaitForChild("FirstPersonSystem")
local C = require(folder:WaitForChild("FPConfig")) -- tuning values
local State = require(folder:WaitForChild("FPState")) -- published camera info for other scripts

-- character references (rebuilt on respawn)
local character, humanoid, hrp, head

-- angles stored in degrees
-- yaw = horizontal, pitch = vertical
local yaw, pitch = 0, 0
local targetYaw, targetPitch = 0, 0 -- input writes here, renderstep smooths toward it

-- exponential smoothing helper
-- keeps smoothing stable across framerates
local function expAlpha(speed, dt)
    return 1 - math.exp(-speed * dt)
end

-- reads exhaustion attribute used for sensitivity + lag scaling
-- missing or invalid values treated as 0 to avoid runtime issues
local function getExhaustion(): number
    local ex = player:GetAttribute("Exhaustion")
    if typeof(ex) ~= "number" then return 0 end
    return math.clamp(ex, 0, 1) -- expected 0..1
end

-- loading screen gate
-- when active, do not fight ui/camera ownership
local function isLoading(): boolean
    return player:GetAttribute("LoadingScreenActive") == true
end

-- visibility hooks used to keep character hidden locally in fp
local visibilityConns: {RBXScriptConnection} = {}
local forceHideConn: RBXScriptConnection? = nil

-- periodic reapply
-- some rigs or scripts reset LocalTransparencyModifier
local VIS_REAPPLY_INTERVAL = 0.35

-- connection cleanup (prevents duplicates after respawn)
local function disconnectVisibilityConns()
    for _, c in ipairs(visibilityConns) do
        pcall(function() c:Disconnect() end) -- safe disconnect if already dead
    end
    table.clear(visibilityConns)

    -- stop periodic reapply if running
    if forceHideConn then
        pcall(function() forceHideConn:Disconnect() end)
        forceHideConn = nil
    end
end

-- applies local hide/show to supported instance types
-- this is client-only visual hiding (does not replicate)
local function applyLocalHideToInstance(inst: Instance, isFirstPerson: boolean)
    -- most visible geometry comes from BasePart
    if inst:IsA("BasePart") then
        inst.LocalTransparencyModifier = isFirstPerson and 1 or 0
        return
    end

    -- decals/textures can remain visible without this
    if inst:IsA("Decal") or inst:IsA("Texture") then
        inst.Transparency = isFirstPerson and 1 or 0
        return
    end

    -- no action for non-visual instances by design
end

-- hides/shows the local character for fp
-- guarded by config because some games want body visible
local function setLocalVisibility(isFirstPerson: boolean)
    if not C.HideCharacterInFP then return end
    if not character then return end

    -- descendants covers accessory parts, layered clothing meshes, etc
    for _, inst in ipairs(character:GetDescendants()) do
        applyLocalHideToInstance(inst, isFirstPerson)
    end

    -- children pass included for robustness with timing/ordering
    for _, inst in ipairs(character:GetChildren()) do
        applyLocalHideToInstance(inst, isFirstPerson)
    end
end

-- binds events so later-added instances are hidden as well
-- also reasserts hide periodically to resist resets
local function bindVisibilityHooks()
    disconnectVisibilityConns()

    if not character then return end
    if not C.HideCharacterInFP then return end

    -- apply once immediately
    setLocalVisibility(true)

    -- accessory or parts added after spawn
    table.insert(visibilityConns, character.DescendantAdded:Connect(function(inst)
        applyLocalHideToInstance(inst, true)
    end))

    -- some content enters as direct children first
    table.insert(visibilityConns, character.ChildAdded:Connect(function(inst)
        applyLocalHideToInstance(inst, true)
    end))

    -- periodic enforcement
    local acc = 0
    forceHideConn = RunService.Heartbeat:Connect(function(dt)
        -- if character was removed, stop doing work
        if not character or not character.Parent then return end

        acc += dt
        if acc >= VIS_REAPPLY_INTERVAL then
            acc = 0
            setLocalVisibility(true)
        end
    end)
end

-- zoom settings
-- attribute-based so other code can toggle zoom if needed
local ZOOM_KEY = Enum.KeyCode.V
local ZOOM_MULTIPLIER = 0.62
local ZOOM_IN_SPEED = 18
local ZOOM_OUT_SPEED = 20

-- fov tracking
-- baseFOV follows external fov changes when zoom not held
local baseFOV = camera.FieldOfView
local currentFOV = camera.FieldOfView

local function isZoomHeld(): boolean
    return player:GetAttribute("ZoomHeld") == true
end

-- loading gate connection for mouse settings
local mouseGateConn: RBXScriptConnection?

-- applies mouse behavior for fp
-- separate function because it is called from multiple places
local function applyMouseForFirstPerson()
    if C.LockMouse then
        UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
    end
    if C.HideMouseIcon then
        UserInputService.MouseIconEnabled = false
    end
end

-- when loading screen active, revert to default mouse behavior
-- then reapply fp settings once loading ends
local function applyMouseGate()
    if isLoading() then
        UserInputService.MouseBehavior = Enum.MouseBehavior.Default
        UserInputService.MouseIconEnabled = true

        -- single-use listener so we don't stack signals
        if mouseGateConn == nil then
            mouseGateConn = player:GetAttributeChangedSignal("LoadingScreenActive"):Connect(function()
                if not isLoading() then
                    if mouseGateConn then
                        mouseGateConn:Disconnect()
                        mouseGateConn = nil
                    end
                    applyMouseForFirstPerson()
                end
            end)
        end
        return
    end

    applyMouseForFirstPerson()
end

-- reassert fp ownership
-- useful after loading screens or camera swaps
local function ensureFirstPersonActive()
    camera = getCamera()

    -- disable default humanoid rotation (we rotate hrp ourselves)
    if humanoid and humanoid.Parent then
        humanoid.AutoRotate = false
    end

    -- lock first person mode (protected because some contexts throw)
    pcall(function()
        player.CameraMode = Enum.CameraMode.LockFirstPerson
    end)

    -- scriptable so camera.CFrame is respected
    camera.CameraType = Enum.CameraType.Scriptable

    -- mouse lock/hide (not gated here; caller should gate)
    applyMouseForFirstPerson()

    -- reapply local hide in case anything reset it
    setLocalVisibility(true)

    -- reset fov baseline so zoom stays consistent
    baseFOV = camera.FieldOfView
    currentFOV = camera.FieldOfView
end

-- camera instance can be replaced by the engine or other systems
-- re-assert fp when that happens (unless loading screen owns it)
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    camera = getCamera()
    if not isLoading() then
        task.defer(ensureFirstPersonActive) -- defer to allow camera init
    end
end)

-- when loading ends, immediately take control back
player:GetAttributeChangedSignal("LoadingScreenActive"):Connect(function()
    if not isLoading() then
        task.defer(ensureFirstPersonActive)
    end
end)

-- binds character refs after spawn
-- also resets angles and visibility hooks
local function bindCharacter(char)
    camera = getCamera()

    character = char
    humanoid = character:WaitForChild("Humanoid")
    hrp = character:WaitForChild("HumanoidRootPart")
    head = character:WaitForChild("Head")

    -- keep rotation under this script
    humanoid.AutoRotate = false

    -- enforce scriptable camera
    camera.CameraType = Enum.CameraType.Scriptable

    -- assert fp immediately
    ensureFirstPersonActive()

    -- handle loading screen mouse policy
    applyMouseGate()

    -- hide local character and keep it hidden
    bindVisibilityHooks()

    -- reset look state on respawn (prevents inheriting previous angles)
    yaw, pitch = 0, 0
    targetYaw, targetPitch = 0, 0

    -- reset fov trackers
    baseFOV = camera.FieldOfView
    currentFOV = camera.FieldOfView
end

-- seat state matters because seats can fight hrp.CFrame changes
-- skipping rotation while seated reduces jitter
local function isSeated(): boolean
    if not humanoid then return false end
    if humanoid.Sit == true then return true end
    if humanoid.SeatPart ~= nil then return true end
    return humanoid:GetState() == Enum.HumanoidStateType.Seated
end

-- character lifecycle
player.CharacterAdded:Connect(function(char)
    -- small delay helps ensure head/hrp exist reliably
    task.wait(0.1)
    bindCharacter(char)
end)

-- handle already-spawned character (fast joins / studio)
if player.Character then
    bindCharacter(player.Character)
end

-- zoom toggle input (attribute-based)
UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end -- ignore if ui captured input
    if input.KeyCode == ZOOM_KEY then
        player:SetAttribute("ZoomHeld", true)
    end
end)

UserInputService.InputEnded:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == ZOOM_KEY then
        player:SetAttribute("ZoomHeld", false)
    end
end)

-- mouse movement drives target angles
-- input is separated from renderstep smoothing
UserInputService.InputChanged:Connect(function(input, gp)
    if isLoading() then return end

    -- only track mouse delta here
    if input.UserInputType ~= Enum.UserInputType.MouseMovement then
        if gp then return end
        return
    end

    -- allow external systems (menus) to temporarily disable look
    if player:GetAttribute("SuppressMouseLook") then return end

    local d = input.Delta

    -- scale sensitivity with exhaustion
    local ex = getExhaustion()
    local sensDrop = C.ExhaustSensitivityDrop or 0.35
    local sens = C.Sensitivity * (1 - sensDrop * ex)

    -- update targets (smoothed later)
    targetYaw -= d.X * sens
    targetPitch -= d.Y * sens

    -- clamp pitch to avoid full flips
    targetPitch = math.clamp(targetPitch, C.PitchMin, C.PitchMax)
end)

-- base camera update (position + rotation)
-- runs on renderstep for smoothness and consistent camera timing
RunService:BindToRenderStep("FirstPersonBaseCamera", Enum.RenderPriority.Camera.Value + 10, function(dt)
    camera = getCamera()
    if isLoading() then return end

    -- validate refs before doing math
    if not humanoid or humanoid.Health <= 0 or not hrp or not head then return end

    local ex = getExhaustion()

    -- exhaustion increases lag by reducing smoothing speed
    local lagBoost = C.ExhaustTurnLagBoost or 0.55

    local camSmooth = C.CameraSmooth * (1 - lagBoost * ex)
    local bodySmooth = C.BodyTurnSmooth * (1 - (lagBoost * 0.75) * ex)

    -- floor smoothing so it never gets too low
    camSmooth = math.max(C.MinCameraSmooth or 6, camSmooth)
    bodySmooth = math.max(C.MinBodySmooth or 6, bodySmooth)

    -- smooth toward target angles
    local aCam = expAlpha(camSmooth, dt)
    yaw = yaw + (targetYaw - yaw) * aCam
    pitch = pitch + (targetPitch - pitch) * aCam

    -- rotate body toward yaw (skip pitch)
    local aBody = expAlpha(bodySmooth, dt)
    local desiredBody = CFrame.new(hrp.Position) * CFrame.Angles(0, math.rad(yaw), 0)

    if not isSeated() then
        hrp.CFrame = hrp.CFrame:Lerp(desiredBody, aBody)
    end

    -- camera anchored at head + configured offset
    local camPos = head.Position + C.CameraOffset

    -- yaw then pitch so it behaves like standard fps
    local camRot = CFrame.Angles(0, math.rad(yaw), 0) * CFrame.Angles(math.rad(pitch), 0, 0)

    camera.CFrame = CFrame.new(camPos) * camRot

    -- publish base cframe for downstream systems (sway/weapon/arms/etc)
    State.BaseCFrame = camera.CFrame
end)

-- zoom fov update
-- late priority so it applies after other camera updates
RunService:BindToRenderStep("FirstPersonZoomFOV", Enum.RenderPriority.Last.Value, function(dt)
    camera = getCamera()
    if isLoading() then return end

    -- if zoom not held, keep baseFOV in sync with external fov changes
    if not isZoomHeld() then
        baseFOV = camera.FieldOfView
    end

    local targetFOV = baseFOV
    if isZoomHeld() then
        targetFOV = baseFOV * ZOOM_MULTIPLIER
    end

    local speed = isZoomHeld() and ZOOM_IN_SPEED or ZOOM_OUT_SPEED
    local a = 1 - math.exp(-speed * dt)

    currentFOV = currentFOV + (targetFOV - currentFOV) * a
    camera.FieldOfView = currentFOV
end)
`
