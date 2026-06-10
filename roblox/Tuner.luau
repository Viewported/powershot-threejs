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
-- `modes` lists which modes actually consume the control (derived from the
-- kernels) — a slider is hidden in modes that ignore it, so you never drag a dead
-- control. (Contrast/saturation/gamma can't apply in overlay: Roblox can't read
-- the pixels below to grade them.)
local ALL = { overlay = true, analog = true, digital = true }
local DIG = { digital = true }
local DIG_OV = { digital = true, overlay = true }
local ANA = { analog = true }
local ANA_OV = { analog = true, overlay = true }
local ANA_DIG = { analog = true, digital = true }

local SPECS = {
	{ header = "GLOBAL", modes = ALL },
	{ key = "resolutionScale", label = "Resolution", min = 0.3, max = 1.0, rebuild = true, modes = ALL },
	{ key = "power", label = "Power", min = 0, max = 1, modes = ALL },
	{ key = "noiseScale", label = "Noise scale", min = 0, max = 3, modes = DIG },
	{ header = "OPTICS", modes = DIG_OV },
	{ key = "barrel", label = "Barrel distortion", min = 0, max = 0.05, decimals = 3, modes = DIG },
	{ key = "ca", label = "Chromatic aberration", min = 0, max = 6, decimals = 1, modes = DIG },
	{ key = "lensSoftness", label = "Lens softness", min = 0, max = 3, modes = DIG },
	{ key = "vignette", label = "Vignette", min = 0, max = 1, modes = DIG_OV },
	{ header = "COLOR / SENSOR", modes = DIG },
	{ key = "noise", label = "Sensor noise", min = 0, max = 0.05, decimals = 3, modes = DIG },
	{ key = "sat", label = "Saturation", min = 0, max = 2, modes = DIG },
	{ key = "gamma", label = "Gamma", min = 0.2, max = 1.2, modes = DIG },
	{ key = "hiClip", label = "Highlight clip", min = 180, max = 255, decimals = 0, modes = DIG },
	{ key = "shadow", label = "Shadow crush", min = 0, max = 30, decimals = 0, modes = DIG },
	{ key = "ccdBloom", label = "CCD bloom", min = 0, max = 3, modes = DIG },
	{ key = "eeGain", label = "Edge enhance", min = 0, max = 6, decimals = 1, modes = DIG },
	{ header = "ANALOG / OVERLAY", modes = ANA_OV },
	{ key = "analogStrength", label = "VHS amount", min = 0, max = 3, modes = ANA_OV },
	{ key = "analogTracking", label = "Tracking", min = 0, max = 3, modes = ANA_OV },
	{ key = "analogChromaBleed", label = "Chroma bleed", min = 0, max = 3, modes = ANA_OV },
	{ key = "analogRinging", label = "Ringing", min = 0, max = 3, modes = ANA },
	{ key = "analogTapeNoise", label = "Tape noise", min = 0, max = 3, modes = ANA_OV },
	{ key = "analogBandMask", label = "Band mask", min = 0, max = 3, modes = ANA_OV },
	{ key = "analogEdgeWave", label = "Edge wave", min = 0, max = 3, modes = ANA },
	{ key = "analogDropouts", label = "Dropouts", min = 0, max = 3, modes = ANA_OV },
	{ key = "analogScanlines", label = "Scanlines", min = 0, max = 3, modes = ANA_OV },
	{ key = "analogHeadSwitch", label = "Head switch", min = 0, max = 3, modes = ANA_OV },
	{ header = "OUTPUT GRADE", modes = ALL },
	{ key = "brightness", label = "Brightness", min = -1, max = 1, modes = ALL },
	{ key = "contrast", label = "Contrast", min = -1, max = 1, modes = ANA_DIG },
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

-- compact number literal: integers stay integers, everything else trimmed to 6sf
local function numToStr(v: number): string
	if v == math.floor(v) and math.abs(v) < 1e7 then
		return string.format("%d", v)
	end
	return string.format("%.6g", v)
end

-- Serialize the live params into a Lua table literal you can paste back to bake a
-- one-shot script. Keys are sorted for a stable diff; ccm is emitted as an array.
local function serialize(params): string
	local keys = {}
	for k in params do
		if k ~= "ccm" then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	local out = { "-- PowerSHOT settings export", "{" }
	for _, k in keys do
		local v = params[k]
		local ty = typeof(v)
		if ty == "number" then
			table.insert(out, string.format("\t%s = %s,", k, numToStr(v)))
		elseif ty == "boolean" then
			table.insert(out, string.format("\t%s = %s,", k, tostring(v)))
		elseif ty == "string" then
			table.insert(out, string.format("\t%s = %q,", k, v))
		end
	end
	local ccm = {}
	for _, n in params.ccm do
		table.insert(ccm, numToStr(n))
	end
	table.insert(out, "\tccm = { " .. table.concat(ccm, ", ") .. " },")
	table.insert(out, "}")
	return table.concat(out, "\n")
end

-- one labelled slider row; returns (row, refresh) where refresh re-reads params[key].
local function makeSlider(parent: Instance, spec, params, callbacks): (Frame, () -> ())
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
	return row, function()
		setDisplay(params[key])
	end
end

local function makeHeader(parent: Instance, text: string): TextLabel
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 22)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 12
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = DIM
	label.Text = text
	label.Parent = parent
	return label
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
	local entries: { { gui: GuiObject, modes: { [string]: boolean } } } = {}
	local order = 0
	local function place(gui: GuiObject): GuiObject
		order += 1
		gui.LayoutOrder = order
		return gui
	end

	local function updateVisibility()
		for _, e in entries do
			e.gui.Visible = e.modes[params.mode] == true
		end
	end

	-- mode + freeze + preset + export toggles (always visible)
	local MODES = { "overlay", "analog", "digital" }
	place(makeToggle(scroll, function()
		return "Mode:  " .. string.upper(params.mode)
	end, function()
		local i = table.find(MODES, params.mode) or 1
		params.mode = MODES[(i % #MODES) + 1]
		updateVisibility()
	end))
	place(makeToggle(scroll, function()
		return "Tape:  " .. (params.freeze and "FROZEN" or "LIVE")
	end, function()
		params.freeze = not params.freeze
	end))

	local presetIndex = 1
	place(makeToggle(scroll, function()
		return "Preset:  " .. Config.PRESET_KEYS[presetIndex]
	end, function()
		presetIndex = (presetIndex % #Config.PRESET_KEYS) + 1
		Config.applyPreset(params, Config.PRESETS[Config.PRESET_KEYS[presetIndex]])
		for _, refresh in refreshers do
			refresh()
		end
	end))

	for _, spec in SPECS do
		if spec.header then
			local label = makeHeader(scroll, spec.header)
			place(label)
			table.insert(entries, { gui = label, modes = spec.modes })
		else
			local row, refresh = makeSlider(scroll, spec, params, callbacks)
			place(row)
			table.insert(entries, { gui = row, modes = spec.modes })
			table.insert(refreshers, refresh)
		end
	end

	-- EXPORT: dump live settings to the Output window and a selectable box
	-- (focus it, Ctrl+A, Ctrl+C). Paste the result back to bake a one-shot script.
	place(makeHeader(scroll, "EXPORT"))
	local exportBox = Instance.new("TextBox")
	exportBox.Size = UDim2.new(1, 0, 0, 160)
	exportBox.BackgroundColor3 = BG2
	exportBox.TextColor3 = TEXT
	exportBox.Font = Enum.Font.Code
	exportBox.TextSize = 11
	exportBox.TextXAlignment = Enum.TextXAlignment.Left
	exportBox.TextYAlignment = Enum.TextYAlignment.Top
	exportBox.TextWrapped = true
	exportBox.ClearTextOnFocus = false
	exportBox.MultiLine = true
	exportBox.TextEditable = true
	exportBox.Text = "press Export below, then select-all + copy this box\n(also printed to the Output window)"
	exportBox.Parent = scroll
	local exportCorner = Instance.new("UICorner")
	exportCorner.CornerRadius = UDim.new(0, 6)
	exportCorner.Parent = exportBox
	local exportPad = Instance.new("UIPadding")
	exportPad.PaddingTop = UDim.new(0, 6)
	exportPad.PaddingBottom = UDim.new(0, 6)
	exportPad.PaddingLeft = UDim.new(0, 8)
	exportPad.PaddingRight = UDim.new(0, 8)
	exportPad.Parent = exportBox
	place(makeToggle(scroll, function()
		return "⤓ Export settings"
	end, function()
		local s = serialize(params)
		exportBox.Text = s
		print("[PowerSHOT] settings export:\n" .. s)
	end))
	place(exportBox)

	updateVisibility()

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
