local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local function getCamera() return workspace.CurrentCamera end
local camera = getCamera()

local folder = ReplicatedStorage:WaitForChild("FirstPersonSystem")
local C = require(folder:WaitForChild("FPConfig"))
local State = require(folder:WaitForChild("FPState"))

local character, humanoid, hrp, head
local yaw, pitch = 0, 0
local targetYaw, targetPitch = 0, 0

local function expAlpha(speed, dt)
	return 1 - math.exp(-speed * dt)
end

local function getExhaustion(): number
	local ex = player:GetAttribute("Exhaustion")
	if typeof(ex) ~= "number" then return 0 end
	return math.clamp(ex, 0, 1)
end

local function isLoading(): boolean
	return player:GetAttribute("LoadingScreenActive") == true
end

-- =========================
-- Robust local visibility
-- =========================
local visibilityConns: {RBXScriptConnection} = {}
local forceHideConn: RBXScriptConnection? = nil
local VIS_REAPPLY_INTERVAL = 0.35 -- seconds (keeps it "for sure" even if something resets it)

local function disconnectVisibilityConns()
	for _, c in ipairs(visibilityConns) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(visibilityConns)
	if forceHideConn then
		pcall(function() forceHideConn:Disconnect() end)
		forceHideConn = nil
	end
end

local function applyLocalHideToInstance(inst: Instance, isFirstPerson: boolean)
	-- BaseParts cover MeshPart, Part, UnionOperation, etc.	
	if inst:IsA("BasePart") then
		inst.LocalTransparencyModifier = isFirstPerson and 1 or 0
		return
	end

	-- Face decals / classic textures
	if inst:IsA("Decal") or inst:IsA("Texture") then
		inst.Transparency = isFirstPerson and 1 or 0
		return
	end

	-- NOTE: SurfaceAppearance has no Enabled property.
	-- We rely on hiding the parent BasePart (MeshPart) instead.
end

local function setLocalVisibility(isFirstPerson: boolean)
	if not C.HideCharacterInFP then return end
	if not character then return end

	for _, inst in ipairs(character:GetDescendants()) do
		applyLocalHideToInstance(inst, isFirstPerson)
	end

	-- Also apply to direct children (covers rare cases where something is not in descendants yet)
	for _, inst in ipairs(character:GetChildren()) do
		applyLocalHideToInstance(inst, isFirstPerson)
	end
end

local function bindVisibilityHooks()
	disconnectVisibilityConns()
	if not character then return end
	if not C.HideCharacterInFP then return end

	-- Apply immediately
	setLocalVisibility(true)

	-- Apply to anything added later (accessories, layered clothing, dynamic head parts)
	table.insert(visibilityConns, character.DescendantAdded:Connect(function(inst)
		applyLocalHideToInstance(inst, true)
	end))
	table.insert(visibilityConns, character.ChildAdded:Connect(function(inst)
		applyLocalHideToInstance(inst, true)
	end))

	-- Re-apply periodically (some experiences reset LocalTransparencyModifier)
	local acc = 0
	forceHideConn = RunService.Heartbeat:Connect(function(dt)
		if not character or not character.Parent then return end
		acc += dt
		if acc >= VIS_REAPPLY_INTERVAL then
			acc = 0
			setLocalVisibility(true)
		end
	end)
end

-- =========================
-- Zoom
-- =========================
local ZOOM_KEY = Enum.KeyCode.V
local ZOOM_MULTIPLIER = 0.62
local ZOOM_IN_SPEED = 18
local ZOOM_OUT_SPEED = 20

local baseFOV = camera.FieldOfView
local currentFOV = camera.FieldOfView

local function isZoomHeld(): boolean
	return player:GetAttribute("ZoomHeld") == true
end

-- =========================
-- Mouse gate
-- =========================
local mouseGateConn: RBXScriptConnection?

local function applyMouseForFirstPerson()
	if C.LockMouse then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end
	if C.HideMouseIcon then
		UserInputService.MouseIconEnabled = false
	end
end

local function applyMouseGate()
	if isLoading() then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
		if mouseGateConn == nil then
			mouseGateConn = player:GetAttributeChangedSignal("LoadingScreenActive"):Connect(function()
				if not isLoading() then
					if mouseGateConn then mouseGateConn:Disconnect() mouseGateConn = nil end
					applyMouseForFirstPerson()
				end
			end)
		end
		return
	end
	applyMouseForFirstPerson()
end

-- Re-assert first person after loading screen releases camera
local function ensureFirstPersonActive()
	camera = getCamera()
	if humanoid and humanoid.Parent then
		humanoid.AutoRotate = false
	end
	pcall(function()
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	end)
	camera.CameraType = Enum.CameraType.Scriptable
	applyMouseForFirstPerson()
	setLocalVisibility(true)
	baseFOV = camera.FieldOfView
	currentFOV = camera.FieldOfView
end

-- Track CurrentCamera changes
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	camera = getCamera()
	if not isLoading() then
		task.defer(ensureFirstPersonActive)
	end
end)

-- When loading ends, re-assert camera immediately
player:GetAttributeChangedSignal("LoadingScreenActive"):Connect(function()
	if not isLoading() then
		task.defer(ensureFirstPersonActive)
	end
end)

local function bindCharacter(char)
	camera = getCamera()
	character = char
	humanoid = character:WaitForChild("Humanoid")
	hrp = character:WaitForChild("HumanoidRootPart")
	head = character:WaitForChild("Head")

	humanoid.AutoRotate = false
	camera.CameraType = Enum.CameraType.Scriptable
	ensureFirstPersonActive()
	applyMouseGate()

	-- Robust hide
	bindVisibilityHooks()

	yaw, pitch = 0, 0
	targetYaw, targetPitch = 0, 0
	baseFOV = camera.FieldOfView
	currentFOV = camera.FieldOfView
end

local function isSeated(): boolean
	if not humanoid then return false end
	if humanoid.Sit == true then return true end
	if humanoid.SeatPart ~= nil then return true end
	return humanoid:GetState() == Enum.HumanoidStateType.Seated
end

player.CharacterAdded:Connect(function(char)
	task.wait(0.1)
	bindCharacter(char)
end)

if player.Character then
	bindCharacter(player.Character)
end

UserInputService.InputBegan:Connect(function(input, gp)
	if gp then return end
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

UserInputService.InputChanged:Connect(function(input, gp)
	if isLoading() then return end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement then
		if gp then return end
		return
	end
	if player:GetAttribute("SuppressMouseLook") then return end

	local d = input.Delta
	local ex = getExhaustion()
	local sensDrop = C.ExhaustSensitivityDrop or 0.35
	local sens = C.Sensitivity * (1 - sensDrop * ex)

	targetYaw -= d.X * sens
	targetPitch -= d.Y * sens
	targetPitch = math.clamp(targetPitch, C.PitchMin, C.PitchMax)
end)

RunService:BindToRenderStep("FirstPersonBaseCamera", Enum.RenderPriority.Camera.Value + 10, function(dt)
	camera = getCamera()
	if isLoading() then return end
	if not humanoid or humanoid.Health <= 0 or not hrp or not head then return end

	local ex = getExhaustion()
	local lagBoost = C.ExhaustTurnLagBoost or 0.55
	local camSmooth = C.CameraSmooth * (1 - lagBoost * ex)
	local bodySmooth = C.BodyTurnSmooth * (1 - (lagBoost * 0.75) * ex)
	camSmooth = math.max(C.MinCameraSmooth or 6, camSmooth)
	bodySmooth = math.max(C.MinBodySmooth or 6, bodySmooth)

	local aCam = expAlpha(camSmooth, dt)
	yaw = yaw + (targetYaw - yaw) * aCam
	pitch = pitch + (targetPitch - pitch) * aCam

	local aBody = expAlpha(bodySmooth, dt)
	local desiredBody = CFrame.new(hrp.Position) * CFrame.Angles(0, math.rad(yaw), 0)
	if not isSeated() then
		hrp.CFrame = hrp.CFrame:Lerp(desiredBody, aBody)
	end

	local camPos = head.Position + C.CameraOffset
	local camRot = CFrame.Angles(0, math.rad(yaw), 0) * CFrame.Angles(math.rad(pitch), 0, 0)
	camera.CFrame = CFrame.new(camPos) * camRot
	State.BaseCFrame = camera.CFrame
end)

RunService:BindToRenderStep("FirstPersonZoomFOV", Enum.RenderPriority.Last.Value, function(dt)
	camera = getCamera()
	if isLoading() then return end

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
