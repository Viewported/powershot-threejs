-- PowerSHOT (Roblox port) — client orchestrator.
--
-- PLACE THIS AT: StarterPlayer > StarterPlayerScripts > "PowerShotClient" (LocalScript)
--   (a LocalScript; it requires the three ModuleScripts under
--    ReplicatedStorage > PowerShot)
--
-- Loads the source image (or the built-in test pattern), creates a fullscreen
-- ImageLabel backed by an EditableImage, runs the pipeline every ~1/TARGET_FPS
-- seconds into that image, and mounts the J-toggle tuner.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PowerShot = ReplicatedStorage:WaitForChild("PowerShot")
local Config = require(PowerShot:WaitForChild("Config"))
local Pipeline = require(PowerShot:WaitForChild("Pipeline"))
local Tuner = require(PowerShot:WaitForChild("Tuner"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- live params (deep copy of defaults; ccm is its own table) --------------------
local params = table.clone(Config.defaults)
params.ccm = table.clone(Config.defaults.ccm)

-- fullscreen display ----------------------------------------------------------
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PowerShotScreen"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

local image = Instance.new("ImageLabel")
image.Name = "Display"
image.Size = UDim2.fromScale(1, 1)
image.BackgroundColor3 = Color3.new(0, 0, 0)
image.BorderSizePixel = 0
image.ScaleType = Enum.ScaleType.Stretch
image.ResampleMode = Enum.ResamplerMode.Pixelated -- crisp retro upscale
image.Parent = screenGui

local status = Instance.new("TextLabel")
status.Name = "Status"
status.AnchorPoint = Vector2.new(1, 1)
status.Position = UDim2.new(1, -10, 1, -10)
status.Size = UDim2.fromOffset(260, 18)
status.BackgroundTransparency = 1
status.Font = Enum.Font.Code
status.TextSize = 12
status.TextXAlignment = Enum.TextXAlignment.Right
status.TextColor3 = Color3.fromRGB(120, 230, 170)
status.Text = "booting..."
status.Parent = screenGui

-- source image ----------------------------------------------------------------
-- Either a Roblox asset you own, or the built-in test pattern. We read the asset
-- once into a native-size buffer and downscale per (re)build.
local srcNativeBuf: buffer? = nil
local srcNativeW, srcNativeH = 0, 0
local useTestPattern = Config.SOURCE_ASSET_ID == ""

if not useTestPattern then
	local ok, srcEditable = pcall(function()
		return AssetService:CreateEditableImageAsync(Content.fromUri(Config.SOURCE_ASSET_ID))
	end)
	if ok and srcEditable then
		srcNativeW = srcEditable.Size.X
		srcNativeH = srcEditable.Size.Y
		srcNativeBuf = srcEditable:ReadPixelsBuffer(Vector2.zero, srcEditable.Size)
	else
		warn(
			"[PowerSHOT] could not load SOURCE_ASSET_ID (must be an image you own) — using test pattern. "
				.. tostring(srcEditable)
		)
		useTestPattern = true
	end
end

-- working buffers + display editable ------------------------------------------
local W, H = 0, 0
local display: EditableImage? = nil
local srcSmall: buffer = buffer.create(4)
local outBuf: buffer = buffer.create(4)

local function rebuild()
	W = math.max(8, math.floor(Config.BASE_WIDTH * params.resolutionScale))
	H = math.max(8, math.floor(Config.BASE_HEIGHT * params.resolutionScale))
	srcSmall = buffer.create(W * H * 4)
	outBuf = buffer.create(W * H * 4)

	if useTestPattern then
		Pipeline.generateTestPattern(srcSmall, W, H)
	elseif srcNativeBuf then
		Pipeline.resample(srcNativeBuf, srcNativeW, srcNativeH, srcSmall, W, H)
	end

	if display then
		display:Destroy()
		display = nil
	end
	local ok, ed = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(W, H) })
	end)
	if ok and ed then
		display = ed
		image.ImageContent = Content.fromObject(ed)
	else
		warn("[PowerSHOT] EditableImage create failed: " .. tostring(ed))
		status.Text = "EditableImage unavailable"
	end
end

rebuild()

-- tuner (mutates params live; resolution slider calls rebuild) -----------------
Tuner.build(playerGui, params, { onResolutionChanged = rebuild })

-- render loop with frame pacing ------------------------------------------------
local frame = 0
local acc = 0
local stepTime = 1 / Config.TARGET_FPS
local statusAcc = 0

RunService.Heartbeat:Connect(function(dt)
	acc += dt
	statusAcc += dt
	if acc < stepTime then
		return
	end
	acc = math.min(acc - stepTime, stepTime) -- bound catch-up, no spiral

	if not display then
		return
	end
	if not params.freeze then
		frame += 1
	end

	Pipeline.process(srcSmall, outBuf, W, H, params, frame)
	display:WritePixelsBuffer(Vector2.zero, Vector2.new(W, H), outBuf)

	if statusAcc >= 0.5 then
		statusAcc = 0
		local label = params.mode == "analog" and "analog" or "digital"
		status.Text = string.format("%dx%d · %s%s · J=tuner", W, H, label, params.freeze and " · frozen" or "")
	end
end)
