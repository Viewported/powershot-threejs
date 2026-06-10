--!strict
-- PowerSHOT (Roblox port) — configuration, presets, and default tuner params.
--
-- PLACE THIS AT: ReplicatedStorage > PowerShot (Folder) > "Config" (ModuleScript)
--
-- Values stay in the original 0..255 "signal" domain so the math matches the
-- three.js / TSL reference as closely as possible. The live Luau pipeline runs a
-- trimmed subset of the full ISP: the heavy Bayer-mosaic / demosaic / JPEG-DCT
-- stages are collapsed into cheaper per-pixel approximations so the whole frame
-- can be processed on the CPU through an EditableImage every tick.

local Config = {}

-- Base working resolution. The image is processed this small on the CPU and then
-- stretched to fill the screen with Pixelated resampling — which is exactly the
-- crunchy low-fi look we want for VHS / early-digicam footage. Raise for more
-- detail, lower if the lobby drops frames. (Multiplied by params.resolutionScale.)
Config.BASE_WIDTH = 192
Config.BASE_HEIGHT = 108

-- Effect update rate, decoupled from the game's render framerate. 24 is plenty
-- for a retro look and keeps CPU cost bounded; the ImageLabel just holds the last
-- frame between updates.
Config.TARGET_FPS = 24

-- rbxassetid of the image to run the effect on. IMPORTANT: this must be an image
-- you uploaded / own — EditableImage refuses to read assets you don't have rights
-- to. Leave as "" to use the built-in test pattern (recommended for first run, it
-- shows off every effect immediately).
Config.SOURCE_ASSET_ID = "" -- e.g. "rbxassetid://1234567890"

-- Default parameter set (mirrors the "cybershot" preset + global controls).
-- Every key here is also exposed as a slider/toggle in the tuner panel.
Config.defaults = {
	mode = "analog", -- "analog" or "digital"
	freeze = false, -- pause the animated grain/tape noise
	resolutionScale = 1.0, -- 0.3 .. 1.0 of BASE_WIDTH/HEIGHT
	power = 1.0, -- blend source(0) .. full effect(1)
	noiseScale = 1.06, -- global noise trim

	-- optics / geometry
	barrel = 0.012, -- barrel distortion
	ca = 1.8, -- chromatic aberration, in pixels
	lensSoftness = 0.28, -- 0..3, lens point-spread blur amount
	vignette = 0.35,

	-- sensor / color (digital path)
	noise = 0.010, -- sensor noise intensity
	wbR = 1.04,
	wbG = 1.0,
	wbB = 0.94,
	-- color correction matrix, row-major 3x3
	ccm = { 1.08, -0.05, -0.01, -0.03, 1.06, -0.04, -0.02, -0.08, 1.06 },
	hiClip = 248, -- highlight clip
	gamma = 0.48,
	shadow = 6, -- shadow crush threshold
	sat = 1.12, -- saturation boost
	ccdBloom = 0.6, -- CCD bloom / highlight smear amount
	ccdBloomThreshold = 200,
	eeGain = 2.8, -- edge enhancement gain
	eeThresh = 6, -- edge enhancement coring threshold
	scanlines = 0.0, -- digital scanlines (analog mode has its own)

	-- analog VHS / NTSC path
	analogStrength = 0.78,
	analogTracking = 0.52,
	analogChromaBleed = 0.82,
	analogRinging = 0.68,
	analogTapeNoise = 0.78,
	analogBandMask = 0.42,
	analogEdgeWave = 0.42,
	analogDropouts = 0.38,
	analogScanlines = 0.58,
	analogHeadSwitch = 0.50,

	-- output grade
	brightness = 0.0, -- -1 .. 1
	contrast = 0.0, -- -1 .. 1
}

-- Camera presets (subset of fields the live pipeline actually consumes, copied
-- 1:1 from the three.js presets). applyPreset() overlays these onto a params
-- table without clobbering the global/output controls.
Config.PRESETS = {
	cybershot = {
		name = "Sony Cyber-shot DSC-W70",
		wbR = 1.04,
		wbG = 1.0,
		wbB = 0.94,
		vignette = 0.35,
		lensSoftness = 0.28,
		barrel = 0.012,
		ca = 1.8,
		noise = 0.010,
		hiClip = 248,
		shadow = 6,
		sat = 1.12,
		gamma = 0.48,
		ccdBloom = 1.12,
		ccdBloomThreshold = 200,
		ccm = { 1.08, -0.05, -0.01, -0.03, 1.06, -0.04, -0.02, -0.08, 1.06 },
		eeGain = 2.8,
		eeThresh = 6,
		analogStrength = 0.78,
		analogTracking = 0.52,
		analogChromaBleed = 0.82,
		analogRinging = 0.68,
		analogTapeNoise = 0.78,
		analogBandMask = 0.42,
		analogEdgeWave = 0.42,
		analogDropouts = 0.38,
		analogScanlines = 0.58,
		analogHeadSwitch = 0.50,
	},
	powershot = {
		name = "Canon PowerShot A520",
		wbR = 1.02,
		wbG = 1.0,
		wbB = 0.97,
		vignette = 0.30,
		lensSoftness = 0.32,
		barrel = 0.015,
		ca = 2.2,
		noise = 0.012,
		hiClip = 250,
		shadow = 5,
		sat = 1.18,
		gamma = 0.47,
		ccdBloom = 0.35,
		ccdBloomThreshold = 210,
		ccm = { 1.10, -0.06, -0.02, -0.01, 1.08, -0.05, -0.03, -0.06, 1.04 },
		eeGain = 3.2,
		eeThresh = 5,
		analogStrength = 0.72,
		analogTracking = 0.46,
		analogChromaBleed = 0.76,
		analogRinging = 0.62,
		analogTapeNoise = 0.70,
		analogBandMask = 0.35,
		analogEdgeWave = 0.34,
		analogDropouts = 0.32,
		analogScanlines = 0.54,
		analogHeadSwitch = 0.42,
	},
	coolpix = {
		name = "Nikon Coolpix L18",
		wbR = 0.98,
		wbG = 1.0,
		wbB = 1.04,
		vignette = 0.25,
		lensSoftness = 0.24,
		barrel = 0.010,
		ca = 1.5,
		noise = 0.008,
		hiClip = 245,
		shadow = 8,
		sat = 1.08,
		gamma = 0.46,
		ccdBloom = 0.25,
		ccdBloomThreshold = 215,
		ccm = { 1.04, -0.03, -0.02, -0.02, 1.05, -0.01, 0.00, -0.04, 1.08 },
		eeGain = 2.5,
		eeThresh = 7,
		analogStrength = 0.62,
		analogTracking = 0.38,
		analogChromaBleed = 0.60,
		analogRinging = 0.48,
		analogTapeNoise = 0.56,
		analogBandMask = 0.24,
		analogEdgeWave = 0.24,
		analogDropouts = 0.24,
		analogScanlines = 0.48,
		analogHeadSwitch = 0.34,
	},
	exilim = {
		name = "Casio Exilim EX-Z75",
		wbR = 1.06,
		wbG = 1.0,
		wbB = 0.92,
		vignette = 0.40,
		lensSoftness = 0.38,
		barrel = 0.018,
		ca = 2.5,
		noise = 0.014,
		hiClip = 252,
		shadow = 4,
		sat = 1.22,
		gamma = 0.45,
		ccdBloom = 0.5,
		ccdBloomThreshold = 195,
		ccm = { 1.12, -0.04, -0.04, -0.02, 1.04, -0.03, -0.04, -0.08, 1.04 },
		eeGain = 3.5,
		eeThresh = 4,
		analogStrength = 0.88,
		analogTracking = 0.64,
		analogChromaBleed = 0.96,
		analogRinging = 0.82,
		analogTapeNoise = 0.92,
		analogBandMask = 0.56,
		analogEdgeWave = 0.58,
		analogDropouts = 0.48,
		analogScanlines = 0.66,
		analogHeadSwitch = 0.62,
	},
	ixus = {
		name = "Canon IXUS 60 (SD600)",
		wbR = 1.03,
		wbG = 1.0,
		wbB = 0.96,
		vignette = 0.28,
		lensSoftness = 0.26,
		barrel = 0.014,
		ca = 1.6,
		noise = 0.009,
		hiClip = 247,
		shadow = 6,
		sat = 1.15,
		gamma = 0.47,
		ccdBloom = 0.35,
		ccdBloomThreshold = 205,
		ccm = { 1.06, -0.04, -0.01, -0.02, 1.05, -0.03, -0.01, -0.06, 1.06 },
		eeGain = 2.6,
		eeThresh = 6,
		analogStrength = 0.68,
		analogTracking = 0.44,
		analogChromaBleed = 0.70,
		analogRinging = 0.58,
		analogTapeNoise = 0.64,
		analogBandMask = 0.30,
		analogEdgeWave = 0.30,
		analogDropouts = 0.28,
		analogScanlines = 0.52,
		analogHeadSwitch = 0.40,
	},
}

Config.PRESET_KEYS = { "cybershot", "powershot", "coolpix", "exilim", "ixus" }

-- Overlay a preset's camera fields onto a live params table.
function Config.applyPreset(params, preset)
	for key, value in preset do
		if key == "name" then
			continue
		end
		if key == "ccm" then
			params.ccm = table.clone(value)
		else
			params[key] = value
		end
	end
end

return Config
