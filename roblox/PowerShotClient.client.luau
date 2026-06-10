-- PowerSHOT (Roblox port) — client orchestrator.
--
-- PLACE THIS AT: StarterPlayer > StarterPlayerScripts > "PowerShotClient" (LocalScript)
--   (a LocalScript; it requires the three ModuleScripts under
--    ReplicatedStorage > PowerShot)
--
-- Two ways to run, switchable live from the tuner (Mode):
--   • "overlay"  — a translucent VHS "damage" layer drawn ON TOP of everything;
--                  the live game/UI below shows through and reads as a degraded
--                  signal. (Roblox can't read the pixels below, so this composites
--                  damage — scanlines, grain, head-switch, dropouts, vignette,
--                  color fringe — via the image's alpha channel rather than
--                  warping the actual content.)
--   • "analog" / "digital" — process a source image (asset or test pattern) and
--                  show it fullscreen, with the full warping pipeline.

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

-- GUI -------------------------------------------------------------------------
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PowerShotScreen"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 100 -- above normal game UI, below the tuner (200)
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

-- source-image display (image modes): opaque black backing + processed image
local image = Instance.new("ImageLabel")
image.Name = "Display"
image.Size = UDim2.fromScale(1, 1)
image.BackgroundColor3 = Color3.new(0, 0, 0)
image.BackgroundTransparency = 0
image.BorderSizePixel = 0
image.Active = false -- don't sink input
image.ScaleType = Enum.ScaleType.Stretch
image.ResampleMode = Enum.ResamplerMode.Pixelated
image.ZIndex = 1
image.Parent = screenGui

-- overlay "damage" layer (overlay mode): transparent, per-pixel alpha
local damage = Instance.new("ImageLabel")
damage.Name = "Damage"
damage.Size = UDim2.fromScale(1, 1)
damage.BackgroundTransparency = 1
damage.BorderSizePixel = 0
damage.Active = false
damage.ScaleType = Enum.ScaleType.Stretch
damage.ResampleMode = Enum.ResamplerMode.Pixelated
damage.ImageTransparency = 0
damage.ZIndex = 2
damage.Parent = screenGui

-- crisp tiled scanline layer (overlay mode), drawn above the damage layer
local scan = Instance.new("ImageLabel")
scan.Name = "Scanlines"
scan.Size = UDim2.fromScale(1, 1)
scan.BackgroundTransparency = 1
scan.BorderSizePixel = 0
scan.Active = false
scan.ScaleType = Enum.ScaleType.Tile
scan.TileSize = UDim2.fromOffset(Config.SCANLINE_PERIOD, Config.SCANLINE_PERIOD)
scan.ResampleMode = Enum.ResamplerMode.Pixelated
scan.ZIndex = 3
scan.Parent = screenGui

local status = Instance.new("TextLabel")
status.Name = "Status"
status.AnchorPoint = Vector2.new(1, 1)
status.Position = UDim2.new(1, -10, 1, -10)
status.Size = UDim2.fromOffset(280, 18)
status.BackgroundTransparency = 1
status.Font = Enum.Font.Code
status.TextSize = 12
status.TextXAlignment = Enum.TextXAlignment.Right
status.TextColor3 = Color3.fromRGB(120, 230, 170)
status.ZIndex = 4
status.Text = "booting..."
status.Parent = screenGui

-- crisp scanline tile (created once; resolution-independent) -------------------
do
	local period = Config.SCANLINE_PERIOD
	local scanBuf = buffer.create(period * period * 4)
	Pipeline.generateScanline(scanBuf, period, period, 0.35)
	local ok, scanImg = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(period, period) })
	end)
	if ok and scanImg then
		scanImg:WritePixelsBuffer(Vector2.zero, Vector2.new(period, period), scanBuf)
		scan.ImageContent = Content.fromObject(scanImg)
	end
end

-- source image ----------------------------------------------------------------
-- Used only by the image modes. Read the asset once into a native-size buffer;
-- overlay mode ignores it.
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

-- working buffers + display/damage editables ----------------------------------
local W, H = 0, 0
local displayImg: EditableImage? = nil
local damageImg: EditableImage? = nil
local srcSmall: buffer = buffer.create(4)
local outBuf: buffer = buffer.create(4)

local function makeEditable(w: number, h: number): EditableImage?
	local ok, ed = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
	end)
	if ok and ed then
		return ed
	end
	warn("[PowerSHOT] EditableImage create failed: " .. tostring(ed))
	return nil
end

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

	if displayImg then
		displayImg:Destroy()
	end
	if damageImg then
		damageImg:Destroy()
	end
	displayImg = makeEditable(W, H)
	damageImg = makeEditable(W, H)
	if displayImg then
		image.ImageContent = Content.fromObject(displayImg)
	end
	if damageImg then
		damage.ImageContent = Content.fromObject(damageImg)
	end
	if not displayImg and not damageImg then
		status.Text = "EditableImage unavailable"
	end
end

rebuild()

local function applyModeVisuals()
	local overlay = params.mode == "overlay"
	image.Visible = not overlay
	damage.Visible = overlay
	scan.Visible = overlay
end

local lastMode = nil
applyModeVisuals()

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

	if params.mode ~= lastMode then
		lastMode = params.mode
		applyModeVisuals()
	end
	if not params.freeze then
		frame += 1
	end

	local overlay = params.mode == "overlay"
	local target = overlay and damageImg or displayImg
	if target then
		Pipeline.process(srcSmall, outBuf, W, H, params, frame)
		target:WritePixelsBuffer(Vector2.zero, Vector2.new(W, H), outBuf)
	end
	if overlay then
		scan.ImageTransparency = 1 - math.clamp(params.analogScanlines / 3, 0, 1) * 0.85
	end

	if statusAcc >= 0.5 then
		statusAcc = 0
		status.Text = string.format("%dx%d · %s%s · J=tuner", W, H, params.mode, params.freeze and " · frozen" or "")
	end
end)
