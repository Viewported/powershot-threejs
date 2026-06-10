--!native
--!optimize 2
-- PowerSHOT VHS overlay — ONE-SHOT, fully self-contained client effect.
--
-- PLACE THIS AT: StarterPlayer > StarterPlayerScripts > (a LocalScript)
-- Nothing else needed — no ModuleScripts, no tuner, no image asset.
--
-- Draws a translucent VHS "damage" layer on top of everything (the live game/UI
-- below shows through and reads as a degraded signal), and — because Roblox CAN
-- post-process the 3D scene via Lighting effects even though it can't read its
-- pixels into Lua — also grades the live scene (brightness/contrast/saturation/
-- tint/bloom) through a ColorCorrectionEffect + BloomEffect, so the look extends
-- to the real world behind the UI. Baked from a tuned settings export.
--
-- Tweak the CONSTANTS block to taste; effect values live in SETTINGS.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local AssetService = game:GetService("AssetService")
local Lighting = game:GetService("Lighting")

-- ===== CONSTANTS (safe to tweak) ============================================
local RES = Vector2.new(288, 162) -- working resolution; raise for finer grain, lower if heavy
local TARGET_FPS = 24 -- effect update rate (decoupled from render fps)
local SCANLINE_PERIOD = 3 -- one dark scanline every N screen px
local SCANLINE_ALPHA = 0.35
local DISPLAY_ORDER = 1000 -- overlay draw order; lower it to sit beneath your own HUD
local USE_SCENE_FX = true -- grade the live 3D scene via Lighting (real contrast etc.)

-- ===== SETTINGS (from your tuner export) ====================================
local SETTINGS = {
	analogBandMask = 0.64726,
	analogChromaBleed = 0.195205,
	analogDropouts = 0.195205,
	analogEdgeWave = 0.34,
	analogHeadSwitch = 0.0308219,
	analogRinging = 0.62,
	analogScanlines = 1.48973,
	analogStrength = 0.410959,
	analogTapeNoise = 0.400685,
	analogTracking = 0.10274,
	barrel = 0.015,
	brightness = -0.0410959,
	ca = 2.2,
	ccdBloom = 0.35,
	ccdBloomThreshold = 210,
	contrast = 0,
	eeGain = 3.2,
	eeThresh = 5,
	freeze = false,
	gamma = 0.47,
	hiClip = 250,
	lensSoftness = 0.32,
	mode = "overlay",
	noise = 0.012,
	noiseScale = 0.914384,
	power = 0.496575,
	resolutionScale = 1,
	sat = 1.18,
	scanlines = 0,
	shadow = 5,
	vignette = 0.44863,
	wbB = 0.97,
	wbG = 1,
	wbR = 1.02,
	ccm = { 1.1, -0.06, -0.02, -0.01, 1.08, -0.05, -0.03, -0.06, 1.04 },
}
-- ===========================================================================

-- hot locals
local floor = math.floor
local clamp = math.clamp
local sin = math.sin
local cos = math.cos
local sqrt = math.sqrt
local log = math.log
local abs = math.abs
local max = math.max
local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local TAU = 6.2831853071795864

local function fract(x: number): number
	return x - floor(x)
end
local function step(edge: number, x: number): number
	return x >= edge and 1.0 or 0.0
end
local function softBand(v: number, a: number, b: number): number
	return clamp((v - a) / (b - a), 0.0, 1.0)
end
local function smoothBand(v: number, a: number, b: number): number
	local t = softBand(v, a, b)
	return t * t * (3.0 - 2.0 * t)
end
local function hash12(px: number, py: number): number
	local ax, ay, az = fract(px * 0.1031), fract(py * 0.1031), fract(px * 0.1031)
	local d = ax * (ay + 33.33) + ay * (az + 33.33) + az * (ax + 33.33)
	ax += d
	ay += d
	az += d
	return fract((ax + ay) * az)
end
local function hash13(px: number, py: number, pz: number): number
	local ax, ay, az = fract(px * 0.1031), fract(py * 0.1031), fract(pz * 0.1031)
	local d = ax * (az + 31.32) + ay * (ay + 31.32) + az * (ax + 31.32)
	ax += d
	ay += d
	az += d
	return fract((ax + ay) * az)
end
local function gaussTemporal(px: number, py: number, t: number, salt: number): number
	local u1 = max(hash13(px, py, t + salt), 1e-6)
	local u2 = max(hash13(px + 11.0, py + 3.0, t + salt + 1.7), 1e-6)
	return sqrt(-2.0 * log(u1)) * cos(u2 * TAU)
end
local function clampb(v: number): number
	if v < 0 then
		return 0
	elseif v > 255 then
		return 255
	end
	return floor(v + 0.5)
end
local function writeRGBA(buf: buffer, o: number, r: number, g: number, b: number, a: number)
	writeu8(buf, o, clampb(r))
	writeu8(buf, o + 1, clampb(g))
	writeu8(buf, o + 2, clampb(b))
	writeu8(buf, o + 3, clampb(a))
end
local function over(pr, pg, pb, pa, cr, cg, cb, a)
	if a <= 0 then
		return pr, pg, pb, pa
	end
	local ia = 1 - a
	return cr * a + pr * ia, cg * a + pg * ia, cb * a + pb * ia, a + pa * ia
end
local function bandNear(v: number, center: number, width: number): number
	local d = abs(v - center)
	if d > 0.5 then
		d = 1 - d
	end
	return 1 - clamp(d / width, 0, 1)
end

-- settings -> static locals (baked, so resolved once)
local master = clamp(SETTINGS.power, 0, 1) * clamp(SETTINGS.analogStrength, 0, 3)
local grainAmt = clamp(SETTINGS.analogTapeNoise, 0, 3)
local headAmt = clamp(SETTINGS.analogHeadSwitch, 0, 3)
local dropAmt = clamp(SETTINGS.analogDropouts, 0, 3)
local bandMask = clamp(SETTINGS.analogBandMask, 0, 1)
local vign = clamp(SETTINGS.vignette, 0, 1)
local tracking = clamp(SETTINGS.analogTracking, 0, 3)
local bleed = clamp(SETTINGS.analogChromaBleed, 0, 3)
local scanShade = clamp(SETTINGS.analogScanlines, 0, 3)
local bright = SETTINGS.brightness

-- overlay damage kernel (premultiplied source-over stack -> straight RGBA) ------
local function renderOverlay(out: buffer, W: number, H: number, frame: number)
	local invW, invH = 1.0 / W, 1.0 / H
	local fframe = frame + 0.0
	local t = fframe * 0.037
	local headY = 0.84 + sin(fframe * 0.021) * 0.02
	local rollY = (fframe * 0.006) % 1.0
	local tearY = (fframe * 0.02 * (0.3 + tracking)) % 1.0
	local dFrame = floor(fframe * 0.13)
	local tF29 = floor(t * 29.0)
	local tF47 = floor(t * 47.0)

	for y = 0, H - 1 do
		local rowo = y * W
		local v = (y + 0.5) * invH
		local fieldLine = floor(y / 2)
		local rowNoise = hash12(y * 0.37 + 13.7, tF29 + 13.7) - 0.5
		local belowHead = v - headY
		local afterHead = belowHead >= 0.0 and 1.0 or 0.0
		local headBand = (1.0 - clamp(belowHead / 0.16, 0.0, 1.0)) * afterHead
		local headLineSeed = hash12(fieldLine * 0.73 + 91.3, tF47 + 91.3)
		local dSeed = hash13(fieldLine * 2.37, dFrame, 73.0)
		local dGate = step(1.0 - clamp(dropAmt * 0.08, 0.0, 0.3), dSeed)
		local dSegW = 60.0 + hash12(fieldLine + 19.0, dFrame + 19.0) * 120.0
		local rollBand = bandNear(v, rollY, 0.12)
		local tearBand = bandNear(v, tearY, 0.018) * clamp(tracking, 0.0, 1.0)

		for x = 0, W - 1 do
			local u = (x + 0.5) * invW
			local pr, pg, pb, pa = 0.0, 0.0, 0.0, 0.0

			-- vignette
			local dxc, dyc = u - 0.5, v - 0.5
			local r = sqrt(dxc * dxc + dyc * dyc) * 1.41421
			local vigA = vign * clamp((r - 0.42) / 0.58, 0.0, 1.0) ^ 1.5 * 0.85
			pr, pg, pb, pa = over(pr, pg, pb, pa, 0, 0, 0, vigA)

			-- brightness tint
			if bright < 0 then
				pr, pg, pb, pa = over(pr, pg, pb, pa, 0, 0, 0, -bright * 0.7)
			elseif bright > 0 then
				pr, pg, pb, pa = over(pr, pg, pb, pa, 1, 1, 1, bright * 0.45)
			end

			-- soft scanline shading + rolling bar
			local ss = 0.5 + 0.5 * sin(v * H * 3.1415927)
			pr, pg, pb, pa = over(pr, pg, pb, pa, 0, 0, 0, ss * scanShade * 0.05 * master)
			pr, pg, pb, pa = over(pr, pg, pb, pa, 1, 1, 1, rollBand * 0.06 * master)

			-- luminance grain — two octaves + a slow blotch so it doesn't look uniform
			local g = gaussTemporal(x, y, fframe, 0.0)
			local gv = clamp(0.5 + g * 0.35, 0.0, 1.0)
			pr, pg, pb, pa = over(pr, pg, pb, pa, gv, gv, gv, clamp(abs(g) * 0.045, 0.0, 0.4) * grainAmt * master)
			local n2 = hash13(x * 0.5 + 7.0, y * 0.5 + 3.0, fframe * 0.5) - 0.5
			local gv2 = clamp(0.5 + n2 * 0.9, 0.0, 1.0)
			pr, pg, pb, pa = over(pr, pg, pb, pa, gv2, gv2, gv2, clamp(abs(n2) * 0.05, 0.0, 0.3) * grainAmt * master)
			local bl = hash13(floor(x * 0.08), floor(y * 0.08), floor(fframe * 0.2)) - 0.5
			pr, pg, pb, pa = over(pr, pg, pb, pa, 0, 0, 0, clamp(bl, 0.0, 1.0) * 0.05 * master)

			-- chroma fringe noise
			if bleed > 0.0 then
				local cn = gaussTemporal(x + 4.0, y, fframe, 121.0)
				local fringeA = clamp(abs(cn) * 0.04, 0.0, 0.3) * bleed * master
				if cn >= 0 then
					pr, pg, pb, pa = over(pr, pg, pb, pa, 0.9, 0.1, 0.7, fringeA)
				else
					pr, pg, pb, pa = over(pr, pg, pb, pa, 0.1, 0.9, 0.6, fringeA)
				end
			end

			-- dropouts
			if dGate > 0.0 and dropAmt > 0.0 then
				local segPos = fract(x / dSegW + dSeed)
				local env = smoothBand(segPos, 0.0, 0.12) * (1.0 - smoothBand(segPos, 0.7, 1.0))
				if env > 0.0 then
					local ds = clamp(0.7 + (hash13(x * 0.91, y * 1.73, fframe + 12.0) - 0.5), 0.0, 1.0)
					local dropA = env * clamp(dropAmt * 0.5, 0.0, 1.0) * (0.4 + bandMask) * master
					pr, pg, pb, pa = over(pr, pg, pb, pa, ds, ds, ds, clamp(dropA, 0.0, 0.9))
				end
			end

			-- tracking sweep band
			if tearBand > 0.0 then
				local tn = clamp(0.5 + (hash13(x * 0.4, fieldLine * 1.1, dFrame + 5.0) - 0.5) * 1.6, 0.0, 1.0)
				pr, pg, pb, pa = over(pr, pg, pb, pa, tn, tn, tn, tearBand * 0.5 * master)
			end

			-- head-switch tear band
			if headBand > 0.0 and headAmt > 0.0 then
				local feather = smoothBand(u, 0.0, 0.05) * (1.0 - smoothBand(u, 0.95, 1.0))
				local hn = clamp(0.5 + (hash13(x * 0.31, y * 1.7, fframe * 0.21) - 0.5) * 1.5, 0.0, 1.0)
				local jitter = (headLineSeed - 0.5) * 0.4 + rowNoise * 0.2
				local headA = headBand * feather * clamp(headAmt * (0.6 + jitter), 0.0, 1.0) * 0.85
				pr, pg, pb, pa = over(pr, pg, pb, pa, hn, hn, hn, clamp(headA, 0.0, 0.95))
			end

			local o = (rowo + x) * 4
			if pa > 1e-4 then
				local inv = 1.0 / pa
				writeRGBA(out, o, pr * inv * 255.0, pg * inv * 255.0, pb * inv * 255.0, pa * 255.0)
			else
				writeRGBA(out, o, 0, 0, 0, 0)
			end
		end
	end
end

local function makeEditable(w: number, h: number): EditableImage?
	local ok, ed = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
	end)
	return (ok and ed) or nil
end

-- ===== build GUI overlay =====================================================
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "PowerShotVHS"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = DISPLAY_ORDER
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local damage = Instance.new("ImageLabel")
damage.Name = "Damage"
damage.Size = UDim2.fromScale(1, 1)
damage.BackgroundTransparency = 1
damage.BorderSizePixel = 0
damage.Active = false -- never sink input
damage.ScaleType = Enum.ScaleType.Stretch
damage.ResampleMode = Enum.ResamplerMode.Pixelated
damage.ZIndex = 1
damage.Parent = gui

local scan = Instance.new("ImageLabel")
scan.Name = "Scanlines"
scan.Size = UDim2.fromScale(1, 1)
scan.BackgroundTransparency = 1
scan.BorderSizePixel = 0
scan.Active = false
scan.ScaleType = Enum.ScaleType.Tile
scan.TileSize = UDim2.fromOffset(SCANLINE_PERIOD, SCANLINE_PERIOD)
scan.ResampleMode = Enum.ResamplerMode.Pixelated
scan.ImageTransparency = 1 - clamp(SETTINGS.analogScanlines / 3, 0, 1) * 0.85
scan.ZIndex = 2
scan.Parent = gui

-- crisp scanline tile
do
	local p = SCANLINE_PERIOD
	local buf = buffer.create(p * p * 4)
	local a = clampb(SCANLINE_ALPHA * 255.0)
	for yy = 0, p - 1 do
		local la = (yy == 0) and a or 0
		for xx = 0, p - 1 do
			local o = (yy * p + xx) * 4
			writeu8(buf, o, 0)
			writeu8(buf, o + 1, 0)
			writeu8(buf, o + 2, 0)
			writeu8(buf, o + 3, la)
		end
	end
	local img = makeEditable(p, p)
	if img then
		img:WritePixelsBuffer(Vector2.zero, Vector2.new(p, p), buf)
		scan.ImageContent = Content.fromObject(img)
	end
end

-- damage editable
local W, H = RES.X, RES.Y
local outBuf = buffer.create(W * H * 4)
local damageImg = makeEditable(W, H)
if damageImg then
	damage.ImageContent = Content.fromObject(damageImg)
else
	warn("[PowerSHOT] EditableImage unavailable; overlay disabled")
end

-- ===== live-scene grade (real, GPU, affects the 3D world) ====================
-- Roblox can't read scene pixels into Lua, but it CAN post-process the 3D render
-- via Lighting effects — so brightness/contrast/saturation/tint/bloom here grade
-- the actual world behind the UI (these are created locally => this client only).
local cc: ColorCorrectionEffect? = nil
if USE_SCENE_FX then
	cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "PowerShotGrade"
	cc.Brightness = SETTINGS.brightness
	cc.Contrast = SETTINGS.contrast
	cc.Saturation = SETTINGS.sat - 1.0
	local wm = max(SETTINGS.wbR, SETTINGS.wbG, SETTINGS.wbB, 1e-3)
	cc.TintColor = Color3.new(SETTINGS.wbR / wm, SETTINGS.wbG / wm, SETTINGS.wbB / wm)
	cc.Parent = Lighting

	if SETTINGS.ccdBloom > 0 then
		local bloom = Instance.new("BloomEffect")
		bloom.Name = "PowerShotBloom"
		bloom.Intensity = clamp(SETTINGS.ccdBloom, 0, 1)
		bloom.Size = 24
		bloom.Threshold = clamp(SETTINGS.ccdBloomThreshold / 255, 0, 2)
		bloom.Parent = Lighting
	end
end

-- ===== render loop (frame-paced) =============================================
local frame = 0
local acc = 0
local stepTime = 1 / TARGET_FPS
local baseBrightness = SETTINGS.brightness
local wobbleAmt = clamp(SETTINGS.analogTapeNoise, 0, 3) * 0.012

RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < stepTime then
		return
	end
	acc = math.min(acc - stepTime, stepTime)
	frame += 1

	if damageImg then
		renderOverlay(outBuf, W, H, frame)
		damageImg:WritePixelsBuffer(Vector2.zero, RES, outBuf)
	end

	-- subtle VHS brightness wobble on the live scene
	if cc then
		cc.Brightness = baseBrightness + (sin(frame * 0.27) * 0.4 + (hash12(frame, 7.0) - 0.5)) * wobbleAmt
	end
end)
