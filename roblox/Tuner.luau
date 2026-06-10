--!strict
-- PowerSHOT (Roblox port) — the J-toggle tuner panel.
--
-- PLACE THIS AT: ReplicatedStorage > PowerShot (Folder) > "Tuner" (ModuleScript)
--
-- Builds a scrollable control panel (mirrors the web app's panel) that mutates a
-- live params table in place. The running pipeline reads that same table every
-- frame, so every slider/toggle is reflected immediately. Press J to show/hide.

local UserInputService = game:GetService("UserInputService")

local Config = require(script.Parent.Config)

local Tuner = {}

-- Slider / control layout. Each scalar key maps to one slider; `header` rows are
-- section dividers; `rebuild = true` re-creates the working buffers (resolution).
local SPECS = {
	{ header = "GLOBAL" },
	{ key = "resolutionScale", label = "Resolution", min = 0.3, max = 1.0, rebuild = true },
	{ key = "power", label = "Power", min = 0, max = 1 },
	{ key = "noiseScale", label = "Noise scale", min = 0, max = 3 },
	{ header = "OPTICS" },
	{ key = "barrel", label = "Barrel distortion", min = 0, max = 0.05, decimals = 3 },
	{ key = "ca", label = "Chromatic aberration", min = 0, max = 6, decimals = 1 },
	{ key = "lensSoftness", label = "Lens softness", min = 0, max = 3 },
	{ key = "vignette", label = "Vignette", min = 0, max = 1 },
	{ header = "COLOR / SENSOR (digital)" },
	{ key = "noise", label = "Sensor noise", min = 0, max = 0.05, decimals = 3 },
	{ key = "sat", label = "Saturation", min = 0, max = 2 },
	{ key = "gamma", label = "Gamma", min = 0.2, max = 1.2 },
	{ key = "hiClip", label = "Highlight clip", min = 180, max = 255, decimals = 0 },
	{ key = "shadow", label = "Shadow crush", min = 0, max = 30, decimals = 0 },
	{ key = "ccdBloom", label = "CCD bloom", min = 0, max = 3 },
	{ key = "eeGain", label = "Edge enhance", min = 0, max = 6, decimals = 1 },
	{ header = "ANALOG VHS" },
	{ key = "analogStrength", label = "VHS amount", min = 0, max = 3 },
	{ key = "analogTracking", label = "Tracking", min = 0, max = 3 },
	{ key = "analogChromaBleed", label = "Chroma bleed", min = 0, max = 3 },
	{ key = "analogRinging", label = "Ringing", min = 0, max = 3 },
	{ key = "analogTapeNoise", label = "Tape noise", min = 0, max = 3 },
	{ key = "analogBandMask", label = "Band mask", min = 0, max = 3 },
	{ key = "analogEdgeWave", label = "Edge wave", min = 0, max = 3 },
	{ key = "analogDropouts", label = "Dropouts", min = 0, max = 3 },
	{ key = "analogScanlines", label = "Scanlines", min = 0, max = 3 },
	{ key = "analogHeadSwitch", label = "Head switch", min = 0, max = 3 },
	{ header = "OUTPUT GRADE" },
	{ key = "brightness", label = "Brightness", min = -1, max = 1 },
	{ key = "contrast", label = "Contrast", min = -1, max = 1 },
}

local BG = Color3.fromRGB(14, 16, 20)
local BG2 = Color3.fromRGB(24, 27, 33)
local ACCENT = Color3.fromRGB(120, 230, 170)
local TEXT = Color3.fromRGB(220, 224, 230)
local DIM = Color3.fromRGB(140, 146, 156)

local function fmt(value: number, decimals: number?): string
	local d = decimals or 2
	if d == 0 then
		return string.format("%d", math.round(value))
	end
	return string.format("%." .. d .. "f", value)
end

-- one labelled slider row; returns a `refresh` fn that re-reads params[key].
local function makeSlider(parent: Instance, spec, params, callbacks): () -> ()
	local key = spec.key
	local minV, maxV = spec.min, spec.max
	local decimals = spec.decimals

	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 38)
	row.BackgroundTransparency = 1
	row.Parent = parent

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, -64, 0, 18)
	name.Position = UDim2.fromOffset(0, 0)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.Gotham
	name.TextSize = 13
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextColor3 = TEXT
	name.Text = spec.label
	name.Parent = row

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Size = UDim2.new(0, 60, 0, 18)
	valueLabel.Position = UDim2.new(1, -60, 0, 0)
	valueLabel.BackgroundTransparency = 1
	valueLabel.Font = Enum.Font.GothamMedium
	valueLabel.TextSize = 13
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.TextColor3 = ACCENT
	valueLabel.Parent = row

	local track = Instance.new("TextButton")
	track.Size = UDim2.new(1, 0, 0, 8)
	track.Position = UDim2.fromOffset(0, 24)
	track.BackgroundColor3 = BG2
	track.AutoButtonColor = false
	track.Text = ""
	track.Parent = row
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 4)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = ACCENT
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	local function setDisplay(value: number)
		local rel = (value - minV) / (maxV - minV)
		rel = math.clamp(rel, 0, 1)
		fill.Size = UDim2.fromScale(rel, 1)
		valueLabel.Text = fmt(value, decimals)
	end

	local function apply(value: number)
		value = math.clamp(value, minV, maxV)
		params[key] = value
		setDisplay(value)
		if spec.rebuild and callbacks.onResolutionChanged then
			callbacks.onResolutionChanged()
		end
	end

	local dragging = false
	local function setFromX(absX: number)
		local rel = math.clamp((absX - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		apply(minV + (maxV - minV) * rel)
	end

	track.InputBegan:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	track.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if
			dragging
			and (
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			)
		then
			setFromX(input.Position.X)
		end
	end)

	setDisplay(params[key])
	return function()
		setDisplay(params[key])
	end
end

local function makeHeader(parent: Instance, text: string)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 22)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 12
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = DIM
	label.Text = text
	label.Parent = parent
end

local function makeToggle(parent: Instance, getText: () -> string, onClick: () -> ()): TextButton
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 0, 30)
	btn.BackgroundColor3 = BG2
	btn.AutoButtonColor = true
	btn.Font = Enum.Font.GothamMedium
	btn.TextSize = 13
	btn.TextColor3 = TEXT
	btn.Text = getText()
	btn.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = btn
	btn.Activated:Connect(function()
		onClick()
		btn.Text = getText()
	end)
	return btn
end

-- Build the panel under `playerGui`. `callbacks.onResolutionChanged` is invoked
-- when the resolution slider moves. Returns the ScreenGui.
function Tuner.build(playerGui: Instance, params, callbacks)
	callbacks = callbacks or {}
	local gui = Instance.new("ScreenGui")
	gui.Name = "PowerShotTuner"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 200 -- above the overlay/display layer
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.fromOffset(320, 560)
	panel.Position = UDim2.fromOffset(16, 16)
	panel.BackgroundColor3 = BG
	panel.BackgroundTransparency = 0.08
	panel.BorderSizePixel = 0
	panel.Visible = false -- press J to reveal
	panel.Parent = gui
	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 10)
	panelCorner.Parent = panel
	local panelPad = Instance.new("UIPadding")
	panelPad.PaddingTop = UDim.new(0, 12)
	panelPad.PaddingBottom = UDim.new(0, 12)
	panelPad.PaddingLeft = UDim.new(0, 14)
	panelPad.PaddingRight = UDim.new(0, 14)
	panelPad.Parent = panel

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 22)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = TEXT
	title.Text = "PowerSHOT · tuner"
	title.Parent = panel

	local hint = Instance.new("TextLabel")
	hint.Size = UDim2.new(1, 0, 0, 16)
	hint.Position = UDim2.fromOffset(0, 22)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Gotham
	hint.TextSize = 11
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.TextColor3 = DIM
	hint.Text = "press J to hide · drag sliders to tune"
	hint.Parent = panel

	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.new(1, 0, 1, -46)
	scroll.Position = UDim2.fromOffset(0, 46)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.CanvasSize = UDim2.new() -- auto-sized below
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarImageColor3 = DIM
	scroll.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	local refreshers: { () -> () } = {}

	-- mode + freeze + preset toggles at the top of the scroll
	local MODES = { "overlay", "analog", "digital" }
	makeToggle(scroll, function()
		return "Mode:  " .. string.upper(params.mode)
	end, function()
		local i = table.find(MODES, params.mode) or 1
		params.mode = MODES[(i % #MODES) + 1]
	end)
	makeToggle(scroll, function()
		return "Tape:  " .. (params.freeze and "FROZEN" or "LIVE")
	end, function()
		params.freeze = not params.freeze
	end)

	local presetIndex = 1
	makeToggle(scroll, function()
		return "Preset:  " .. Config.PRESET_KEYS[presetIndex]
	end, function()
		presetIndex = (presetIndex % #Config.PRESET_KEYS) + 1
		Config.applyPreset(params, Config.PRESETS[Config.PRESET_KEYS[presetIndex]])
		for _, refresh in refreshers do
			refresh()
		end
	end)

	for _, spec in SPECS do
		if spec.header then
			makeHeader(scroll, spec.header)
		else
			table.insert(refreshers, makeSlider(scroll, spec, params, callbacks))
		end
	end

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.J then
			panel.Visible = not panel.Visible
		end
	end)

	return gui
end

return Tuner
