--!native
--!optimize 2
-- PowerSHOT (Roblox port) — per-pixel ISP + analog VHS kernels over EditableImage
-- buffers.
--
-- PLACE THIS AT: ReplicatedStorage > PowerShot (Folder) > "Pipeline" (ModuleScript)
--
-- This is the Luau translation of src/pipeline.js. The original runs each stage
-- as a parallel WebGPU fragment pass; here everything happens on the CPU in one
-- pass per pixel, so we keep the cheap, high-impact stages and approximate the
-- expensive multi-pass ones (full Bayer mosaic/demosaic, 8x8 JPEG DCT, 25-tap
-- bilateral NR) — they would be far too slow per frame in Luau and read poorly at
-- this resolution anyway.
--
-- Buffers are RGBA8 (4 bytes/pixel, row-major, top-left origin) — the exact
-- layout EditableImage:ReadPixelsBuffer / WritePixelsBuffer use. Pixel math runs
-- in the 0..255 signal domain, matching the reference constants 1:1.

local Pipeline = {}

-- hot locals --------------------------------------------------------------------
local floor = math.floor
local clamp = math.clamp
local sin = math.sin
local cos = math.cos
local exp = math.exp
local sqrt = math.sqrt
local log = math.log
local abs = math.abs
local max = math.max
local min = math.min
local readu8 = buffer.readu8
local writeu8 = buffer.writeu8

local TAU = 6.2831853071795864
local HALF_PI = 1.5707963267948966

-- small math helpers ------------------------------------------------------------

local function fract(x: number): number
	return x - floor(x)
end

local function mix(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function step(edge: number, x: number): number
	return x >= edge and 1.0 or 0.0
end

local function softBand(value: number, a: number, b: number): number
	return clamp((value - a) / (b - a), 0.0, 1.0)
end

local function smoothBand(value: number, a: number, b: number): number
	local t = softBand(value, a, b)
	return t * t * (3.0 - 2.0 * t)
end

-- Dave Hoskins hashes — no large-argument sin, so grain stays free of the
-- diagonal/grid artifacts the classic fract(sin(dot)) hash degenerates into.
local function hash12(px: number, py: number): number
	local ax = fract(px * 0.1031)
	local ay = fract(py * 0.1031)
	local az = fract(px * 0.1031)
	local d = ax * (ay + 33.33) + ay * (az + 33.33) + az * (ax + 33.33)
	ax += d
	ay += d
	az += d
	return fract((ax + ay) * az)
end

local function hash13(px: number, py: number, pz: number): number
	local ax = fract(px * 0.1031)
	local ay = fract(py * 0.1031)
	local az = fract(pz * 0.1031)
	local d = ax * (az + 31.32) + ay * (ay + 31.32) + az * (ax + 31.32)
	ax += d
	ay += d
	az += d
	return fract((ax + ay) * az)
end

-- unit-variance gaussian (Box-Muller). temporal folds the frame counter in so the
-- grain shimmers each frame; fixed is time-invariant fixed-pattern noise.
local function gaussTemporal(px: number, py: number, t: number, salt: number): number
	local u1 = max(hash13(px, py, t + salt), 1e-6)
	local u2 = max(hash13(px + 11.0, py + 3.0, t + salt + 1.7), 1e-6)
	return sqrt(-2.0 * log(u1)) * cos(u2 * TAU)
end

-- color space (matches rgbToYCbCr / yCbCrToRgb in the reference) -----------------
local function rgb2y(r: number, g: number, b: number): number
	return r * 0.299 + g * 0.587 + b * 0.114
end

-- pixel access ------------------------------------------------------------------
-- nearest sample with clamp-to-edge. Returns r,g,b (0..255). x,y are integers.
local function readRGB(buf: buffer, W: number, H: number, x: number, y: number): (number, number, number)
	if x < 0 then
		x = 0
	elseif x >= W then
		x = W - 1
	end
	if y < 0 then
		y = 0
	elseif y >= H then
		y = H - 1
	end
	local o = (y * W + x) * 4
	return readu8(buf, o), readu8(buf, o + 1), readu8(buf, o + 2)
end

-- nearest sample at float pixel coords, returned as full-range YCbCr (chroma
-- centered on 0). Used by the analog path's many horizontal taps.
local function sampleYcc(buf: buffer, W: number, H: number, xf: number, yf: number): (number, number, number)
	local x = floor(xf + 0.5)
	local y = floor(yf + 0.5)
	if x < 0 then
		x = 0
	elseif x >= W then
		x = W - 1
	end
	if y < 0 then
		y = 0
	elseif y >= H then
		y = H - 1
	end
	local o = (y * W + x) * 4
	local r = readu8(buf, o)
	local g = readu8(buf, o + 1)
	local b = readu8(buf, o + 2)
	local Y = r * 0.299 + g * 0.587 + b * 0.114
	local cb = r * -0.168736 + g * -0.331264 + b * 0.5
	local cr = r * 0.5 + g * -0.418688 + b * -0.081312
	return Y, cb, cr
end

local function writePx(buf: buffer, o: number, r: number, g: number, b: number)
	if r < 0 then
		r = 0
	elseif r > 255 then
		r = 255
	end
	if g < 0 then
		g = 0
	elseif g > 255 then
		g = 255
	end
	if b < 0 then
		b = 0
	elseif b > 255 then
		b = 255
	end
	writeu8(buf, o, floor(r + 0.5))
	writeu8(buf, o + 1, floor(g + 0.5))
	writeu8(buf, o + 2, floor(b + 0.5))
	writeu8(buf, o + 3, 255)
end

-- clamp+round to a byte
local function clampb(v: number): number
	if v < 0 then
		return 0
	elseif v > 255 then
		return 255
	end
	return floor(v + 0.5)
end

-- write a straight-alpha RGBA pixel (overlay mode uses the alpha channel)
local function writeRGBA(buf: buffer, o: number, r: number, g: number, b: number, a: number)
	writeu8(buf, o, clampb(r))
	writeu8(buf, o + 1, clampb(g))
	writeu8(buf, o + 2, clampb(b))
	writeu8(buf, o + 3, clampb(a))
end

-- "source-over" compositor in PREMULTIPLIED space: lay color (cr,cg,cb,a) on top
-- of the accumulated premultiplied (pr,pg,pb,pa) and return the new accumulator.
-- Building bottom-to-top this way yields one straight-alpha pixel that, when the
-- ImageLabel draws it over the live scene, reproduces the stacked translucent
-- damage exactly.
local function over(pr, pg, pb, pa, cr, cg, cb, a)
	if a <= 0 then
		return pr, pg, pb, pa
	end
	local ia = 1 - a
	return cr * a + pr * ia, cg * a + pg * ia, cb * a + pb * ia, a + pa * ia
end

-- distance-to-band on a wrapped 0..1 axis, returns 1 at center fading to 0 at width
local function bandNear(value: number, center: number, width: number): number
	local d = abs(value - center)
	if d > 0.5 then
		d = 1 - d
	end
	return 1 - clamp(d / width, 0, 1)
end

-- =================================================================================
-- DIGITAL ISP path (trimmed): optics -> white balance -> sensor grain -> CCM ->
-- tone -> saturation -> vignette -> edge enhance -> grade.
-- =================================================================================
local function processDigital(src: buffer, out: buffer, W: number, H: number, p, frame: number)
	local invW = 1.0 / W
	local invH = 1.0 / H
	local maxDim = max(W, H)
	local fframe = frame + 0.0

	local barrel = p.barrel
	local ca = p.ca
	local rScale = 1.0 + ca / maxDim
	local bScale = 1.0 - 0.7 * ca / maxDim
	local wbR, wbG, wbB = p.wbR, p.wbG, p.wbB
	local c00, c01, c02 = p.ccm[1], p.ccm[2], p.ccm[3]
	local c10, c11, c12 = p.ccm[4], p.ccm[5], p.ccm[6]
	local c20, c21, c22 = p.ccm[7], p.ccm[8], p.ccm[9]
	local hiClip = max(p.hiClip, 1.0)
	local gamma = p.gamma
	local shadow = p.shadow
	local sat = p.sat
	local vignette = p.vignette
	local noise = p.noise
	local noiseScale = p.noiseScale
	local eeGain = p.eeGain
	local eeThresh = p.eeThresh
	local doEdge = eeGain > 0.01
	local ccdBloom = p.ccdBloom
	local bloomThr = p.ccdBloomThreshold
	local bloomDenom = max(1.0, 255.0 - bloomThr)
	local doBloom = ccdBloom > 0.01
	local scanlines = p.scanlines
	local lensSoftness = p.lensSoftness
	local doLens = lensSoftness > 0.01
	local power = p.power
	local bright = p.brightness + 1.0
	local contrast = p.contrast + 1.0

	-- vignette geometry
	local cx, cy = W * 0.5, H * 0.5
	local maxR = sqrt(cx * cx + cy * cy)

	for y = 0, H - 1 do
		local rowo = y * W
		for x = 0, W - 1 do
			local u = (x + 0.5) * invW
			local v = (y + 0.5) * invH

			-- barrel distortion (aspect-naive, matches reference)
			local dx = (u - 0.5) * 2.0
			local dy = (v - 0.5) * 2.0
			local r2 = dx * dx + dy * dy
			local factor = 1.0 + barrel * r2
			local bu = (dx / factor) * 0.5 + 0.5
			local bv = (dy / factor) * 0.5 + 0.5

			-- chromatic aberration: sample R/G/B at slightly different scales
			local gx = floor(bu * W)
			local gy = floor(bv * H)
			local sr, sg, sb = readRGB(src, W, H, gx, gy)
			local rr = readRGB(src, W, H, floor(((bu - 0.5) / rScale + 0.5) * W), gy)
			local _, _, bb = readRGB(src, W, H, gx, floor(((bv - 0.5) / bScale + 0.5) * H))
			local R, G, B = rr, sg, bb

			-- lens point-spread softness (cheap plus-shaped blur), optional
			if doLens then
				local n1, n2, n3 = readRGB(src, W, H, gx - 1, gy)
				local n4, n5, n6 = readRGB(src, W, H, gx + 1, gy)
				local n7, n8, n9 = readRGB(src, W, H, gx, gy - 1)
				local n10, n11, n12 = readRGB(src, W, H, gx, gy + 1)
				local soft = clamp(lensSoftness, 0.0, 1.0)
				R = mix(R, R * 0.4 + (n1 + n4 + n7 + n10) * 0.15, soft)
				G = mix(G, G * 0.4 + (n2 + n5 + n8 + n11) * 0.15, soft)
				B = mix(B, B * 0.4 + (n3 + n6 + n9 + n12) * 0.15, soft)
			end

			-- white balance
			R = R * wbR
			G = G * wbG
			B = B * wbB

			-- animated sensor grain (read + shot noise, signal dependent)
			local sl = clamp((R + G + B) * 0.0013072, 0.0, 1.0) -- /3/255
			local readStd = noise * 255.0 * (0.9 + (1.0 - sl) * 1.8) * noiseScale
			local lumGrain = gaussTemporal(x, y, fframe, 0.0) * readStd
			R += lumGrain + gaussTemporal(x, y, fframe, 37.0) * noise * 76.5 * noiseScale
			G += lumGrain
			B += lumGrain + gaussTemporal(x, y, fframe, 53.0) * noise * 76.5 * noiseScale

			-- color correction matrix
			local mr = R * c00 + G * c01 + B * c02
			local mg = R * c10 + G * c11 + B * c12
			local mb = R * c20 + G * c21 + B * c22
			R = clamp(mr, 0.0, 255.0)
			G = clamp(mg, 0.0, 255.0)
			B = clamp(mb, 0.0, 255.0)

			-- tone curve: highlight clip -> gamma -> shadow crush
			R = (min(R, hiClip) / hiClip) ^ gamma * 255.0
			G = (min(G, hiClip) / hiClip) ^ gamma * 255.0
			B = (min(B, hiClip) / hiClip) ^ gamma * 255.0
			if R < shadow then
				R = 0.0
			end
			if G < shadow then
				G = 0.0
			end
			if B < shadow then
				B = 0.0
			end

			-- saturation around per-pixel gray
			local gray = (R + G + B) * 0.3333333
			R = gray + (R - gray) * sat
			G = gray + (G - gray) * sat
			B = gray + (B - gray) * sat

			-- vignette
			local px = (x + 0.5) - cx
			local py = (y + 0.5) - cy
			local rd = sqrt(px * px + py * py) / maxR
			local ct = cos(rd * 0.7853982)
			local falloff = 1.0 - vignette * (1.0 - ct * ct * ct * ct)
			R = R * falloff
			G = G * falloff
			B = B * falloff

			-- CCD bloom: thresholded highlights smeared vertically (cheap stand-in
			-- for the multi-pass column-bleed), optional
			if doBloom then
				local smR, smG, smB = 0.0, 0.0, 0.0
				for dyb = -4, 4, 2 do
					local br, bg, bb2 = readRGB(src, W, H, gx, gy + dyb)
					local lum = max(max(br, bg), bb2)
					local m = clamp((lum - bloomThr) / bloomDenom, 0.0, 1.0)
					m = sqrt(m)
					smR += br * m
					smG += bg * m
					smB += bb2 * m
				end
				local k = ccdBloom * 0.2
				R += smR * k
				G += smG * k
				B += smB * k
			end

			-- edge enhancement (luma high-pass on source neighborhood), optional
			if doEdge then
				local lc = rgb2y(readRGB(src, W, H, gx, gy))
				local lN = rgb2y(readRGB(src, W, H, gx, gy - 1))
				local lS = rgb2y(readRGB(src, W, H, gx, gy + 1))
				local lE = rgb2y(readRGB(src, W, H, gx + 1, gy))
				local lW = rgb2y(readRGB(src, W, H, gx - 1, gy))
				local edge = lc * 4.0 - (lN + lS + lE + lW)
				if abs(edge) >= eeThresh then
					local boost = clamp(edge * eeGain, -40.0, 40.0)
					R += boost
					G += boost
					B += boost
				end
			end

			-- digital scanlines (subtle; analog mode has its own)
			if scanlines > 0.0 then
				local s = sin(y * 3.1415927) * 0.5 + 0.5
				local k = 1.0 - s * scanlines * 0.5
				R = R * k
				G = G * k
				B = B * k
			end

			-- blend over source, then output grade (brightness/contrast in 0..1)
			R = mix(sr, R, power)
			G = mix(sg, G, power)
			B = mix(sb, B, power)
			R = ((R * 0.0039216 * bright) - 0.5) * contrast + 0.5
			G = ((G * 0.0039216 * bright) - 0.5) * contrast + 0.5
			B = ((B * 0.0039216 * bright) - 0.5) * contrast + 0.5

			writePx(out, (rowo + x) * 4, R * 255.0, G * 255.0, B * 255.0)
		end
	end
end

-- =================================================================================
-- ANALOG VHS / NTSC path — faithful trim of stAnalogVhs. Tracking jitter, luma
-- pre-emphasis / ringing, chroma bleed + phase noise, color-subcarrier crawl,
-- dropouts, scanlines/interlace, and the head-switch tear band at the bottom.
-- The widest horizontal taps (±7px) are dropped to ±3 for speed.
-- =================================================================================
local function processAnalog(src: buffer, out: buffer, W: number, H: number, p, frame: number)
	local invW = 1.0 / W
	local invH = 1.0 / H
	local fframe = frame + 0.0
	local t = fframe * 0.037

	local strength = clamp(p.analogStrength, 0.0, 3.0)
	local tracking = clamp(p.analogTracking, 0.0, 3.0)
	local chromaBleed = clamp(p.analogChromaBleed, 0.0, 3.0)
	local ringing = clamp(p.analogRinging, 0.0, 3.0)
	local tapeNoise = clamp(p.analogTapeNoise, 0.0, 3.0)
	local bandMask = clamp(p.analogBandMask, 0.0, 3.0)
	local edgeWaveAmt = clamp(p.analogEdgeWave, 0.0, 3.0)
	local dropoutAmt = clamp(p.analogDropouts, 0.0, 3.0)
	local scanlines = clamp(p.analogScanlines, 0.0, 3.0)
	local headSwitch = clamp(p.analogHeadSwitch, 0.0, 3.0)
	local trackingRaw = p.analogTracking
	local active = strength > 0.001 and strength or 0.0
	local power = p.power
	local bright = p.brightness + 1.0
	local contrast = p.contrast + 1.0

	-- per-frame head-switch drift (constant across the frame)
	local headDrift = sin(fframe * 0.021) * 0.018 + (hash12(floor(fframe * 0.037), 8.1) - 0.5) * 0.014
	local headY = clamp(0.84 + headDrift, 0.78, 0.93)
	local lumaMixK = clamp(strength * 0.42, 0.0, 0.74)
	local chromaBlurK = clamp(chromaBleed * 0.28, 0.0, 0.55)
	local chromaMixK = clamp(chromaBleed * 0.58, 0.0, 0.9)
	local oversat = 1.0 + strength * 0.18
	local chromaDelayPx = 1.6 + chromaBleed * 3.2
	local wideDelayPx = chromaDelayPx + chromaBleed * 5.0

	local tF29 = floor(t * 29.0)
	local tF47 = floor(t * 47.0)
	local fF019 = floor(fframe * 0.19)
	local fF009 = floor(fframe * 0.09)
	local fF021 = floor(fframe * 0.21)
	local fF025 = fframe * 0.25
	local dropoutFrame = floor(fframe * 0.13)

	for y = 0, H - 1 do
		local rowo = y * W
		local v = (y + 0.5) * invH
		local fieldLine = floor(y / 2)

		-- per-row terms
		local rowNoise = hash12(y * 0.37 + 13.7, tF29 + 13.7) - 0.5
		local lineWave = sin(y * 0.073 + t * 5.3) + 0.55 * sin(y * 0.019 - t * 2.1)
		local belowHead = v - headY
		local afterHead = belowHead >= 0.0 and 1.0 or 0.0
		local headAttack = clamp(belowHead / 0.012, 0.0, 1.0)
		local headFalloff = exp(belowHead * -17.0) * afterHead
		local headTail = (1.0 - clamp(belowHead / 0.22, 0.0, 1.0)) * afterHead
		local headNoise = hash12(fieldLine * 0.73 + 91.3, tF47 + 91.3) - 0.5
		local headLineBreak = step(0.58, hash12(fieldLine * 1.91 + 117.0, fF019 + 117.0))
		local headPhaseShift = headNoise * 24.0 + headLineBreak * headNoise * 20.0
		local edgeStep = hash12(fieldLine * 0.17 + 41.0, fF009 + 41.0) - 0.5
		local edgeWave = sin(fieldLine * 0.37 + t * 1.7) * edgeStep * (edgeWaveAmt * 1.65)

		-- color subcarrier phase for this row
		local phaseBucket = (fieldLine + fF025) % 4.0
		local phaseOffset = phaseBucket * HALF_PI + trackingRaw * 0.35

		-- dropout line gating (per field line)
		local dropoutLineSeed = hash13(fieldLine * 2.37, dropoutFrame, 73.0)
		local dropoutSegW = 88.0 + hash12(fieldLine + 19.0, dropoutFrame + 19.0) * 96.0
		local dropoutLineGate = step(1.0 - clamp(dropoutAmt * 0.075, 0.0, 0.26), dropoutLineSeed)
		local bandDamage = dropoutAmt * bandMask

		for x = 0, W - 1 do
			local u = (x + 0.5) * invW

			-- head-switch mask (also needs per-column feather)
			local headXFeather = smoothBand(u, 0.012, 0.055) * (1.0 - smoothBand(u, 0.945, 0.988))
			local headMask =
				clamp(headAttack * (headFalloff * 0.8 + headTail * 0.2) * headXFeather * headSwitch, 0.0, 1.0)

			-- horizontal tracking jitter
			local xJitter = lineWave * (tracking * 0.85)
				+ rowNoise * (tracking * 2.0)
				+ edgeWave
				+ headPhaseShift * (headMask * tracking)
				+ headNoise * (headMask * tracking * 6.0)
			local bx = x + xJitter

			-- luma/chroma taps (trimmed to ±3 horizontal, ±2 vertical)
			local bY, bCb, bCr = sampleYcc(src, W, H, bx, y)
			local lY, lCb, lCr = sampleYcc(src, W, H, bx - 1.0, y)
			local rY, rCb, rCr = sampleYcc(src, W, H, bx + 1.0, y)
			local flY = (sampleYcc(src, W, H, bx - 3.0, y)) -- luma only (far-left)
			local frY = (sampleYcc(src, W, H, bx + 3.0, y)) -- luma only (far-right)
			local _, aCb, aCr = sampleYcc(src, W, H, bx, y - 2.0) -- chroma only (above)
			local _, beCb, beCr = sampleYcc(src, W, H, bx, y + 2.0) -- chroma only (below)
			local _, dCb, dCr = sampleYcc(src, W, H, bx + chromaDelayPx, y)
			local _, wCb, wCr = sampleYcc(src, W, H, bx + wideDelayPx, y)

			-- chroma bleed (horizontal smear + a touch of vertical)
			local chHorizCb = (lCb + bCb * 2.0 + rCb + dCb * 2.0 + wCb) / 7.0
			local chHorizCr = (lCr + bCr * 2.0 + rCr + dCr * 2.0 + wCr) / 7.0
			local chVertCb = (aCb + bCb * 2.0 + beCb) / 4.0
			local chVertCr = (aCr + bCr * 2.0 + beCr) / 4.0
			local chBlurCb = mix(chHorizCb, chVertCb, chromaBlurK)
			local chBlurCr = mix(chHorizCr, chVertCr, chromaBlurK)

			-- luma pre-emphasis / ringing
			local lumaBlur = (flY + 2.0 * lY + 4.0 * bY + 2.0 * rY + frY) / 10.0
			local lumaHigh = bY - lumaBlur
			local preemphasis = lumaHigh * (ringing * 0.95)
			local edge = rY - lY
			local ring2 = (flY - lY + rY - frY) * 0.16 + edge * 0.23
			local freqNoise = hash12(floor(x * 0.055), fieldLine + fF021) - 0.5
			local Y = mix(bY, lumaBlur + preemphasis, lumaMixK)
			Y += ring2 * (ringing * 1.35 + freqNoise * (tapeNoise * 0.52))

			-- color subcarrier crawl
			local satMag = (abs(bCb) + abs(bCr)) * 0.5
			local carrier = sin(x * HALF_PI + phaseOffset)
			local carrierQ = sin((x + 1.0) * HALF_PI + phaseOffset)
			local crawl = carrier * satMag * (chromaBleed * 0.32)
			Y += crawl * 0.55

			-- chroma: blur blend, phase rotation, tape noise, crawl
			local Cb = mix(bCb, chBlurCb, chromaMixK)
			local Cr = mix(bCr, chBlurCr, chromaMixK)
			local phaseNoise = rowNoise * (chromaBleed * 0.22) + headNoise * (headMask * 0.65)
			local ps = sin(phaseNoise)
			local pc = cos(phaseNoise)
			local Cb2 = Cb * pc - Cr * ps
			local Cr2 = Cb * ps + Cr * pc
			Cb = Cb2 + gaussTemporal(x, y, fframe, 121.0) * (tapeNoise * 1.35) + carrier * crawl * 0.34
			Cr = Cr2 + gaussTemporal(x, y, fframe, 177.0) * (tapeNoise * 1.35) + carrierQ * crawl * -0.22

			-- dropouts (segment gating along the line)
			if dropoutLineGate > 0.0 and bandDamage > 0.0 then
				local seg = floor(x / dropoutSegW)
				local segSeed = hash13(seg * 5.37 + dropoutLineSeed * 17.0, fieldLine * 3.11, dropoutFrame + 73.0)
				local segGate = step(1.0 - clamp(dropoutAmt * 0.32, 0.0, 0.92), segSeed)
				if segGate > 0.0 then
					local segPos = fract(x / dropoutSegW + dropoutLineSeed)
					local env = softBand(segPos, 0.04, 0.18) * (1.0 - softBand(segPos, 0.74, 0.96))
					local band = env
					local chromaLoss = clamp(band * (bandDamage * 0.85), 0.0, 1.0)
					Cb = mix(Cb, Cb * 0.08, chromaLoss)
					Cr = mix(Cr, Cr * 0.08, chromaLoss)
					local dStatic = hash13(x * 0.91, y * 1.73, fframe + 12.0) - 0.5
					Y += band * dStatic * (tapeNoise * bandDamage * 34.0)
				end
			end

			-- scanlines + interlace + broadband tape hiss
			local scan = sin(y * 3.1415927) * 0.5 + 0.5
			local interlace = step(0.5, (y + frame) % 2.0)
			Y = Y * (1.0 - scan * (scanlines * 0.055) - interlace * (scanlines * 0.025))
			Y += gaussTemporal(x, y, fframe, 211.0) * (tapeNoise * 1.6)

			-- head-switch tear band
			if headMask > 0.0 then
				local headLine = (1.0 - clamp(abs(belowHead) / 0.018, 0.0, 1.0)) * headXFeather * (headSwitch * 0.34)
				local headStatic = gaussTemporal(x, y, fframe, 319.0) * 0.62
					+ (hash13(x * 0.31, y * 1.7, fframe * 0.21) - 0.5)
				local headLumaNoise = headStatic * (tapeNoise * 38.0) * headMask
				local headLineNoise = headLineBreak * (hash12(x * 0.043, fieldLine + frame) - 0.5) * headMask
				local headTear = headMask
				Y = mix(Y, Y * 0.72 + headLumaNoise + headLineNoise * 48.0 + headLine * 42.0, headTear * 0.72)
				Cb = mix(Cb, Cb * 0.24 + headStatic * 18.0, headTear * 0.82)
				Cr = mix(Cr, Cr * 0.24 + headNoise * 12.0, headTear * 0.82)
			end

			-- right-edge wrap darkening
			local rightBorder = step(0.983, u) * clamp(strength * 0.72, 0.0, 1.0)
			Y = mix(Y, Y * 0.15, rightBorder)
			Cb = mix(Cb, Cb * 0.1, rightBorder)
			Cr = mix(Cr, Cr * 0.1, rightBorder)

			-- back to RGB
			Cb = Cb * oversat
			Cr = Cr * oversat
			local aR = Y + Cr * 1.402
			local aG = Y - Cb * 0.344136 - Cr * 0.714136
			local aB = Y + Cb * 1.772

			-- blend over the (undistorted) source by the analog activity amount
			local sr, sg, sb = readRGB(src, W, H, x, y)
			local R = mix(sr, clamp(aR, 0.0, 255.0), active)
			local G = mix(sg, clamp(aG, 0.0, 255.0), active)
			local B = mix(sb, clamp(aB, 0.0, 255.0), active)

			-- global power blend + output grade
			R = mix(sr, R, power)
			G = mix(sg, G, power)
			B = mix(sb, B, power)
			R = (((R * 0.0039216) * bright) - 0.5) * contrast + 0.5
			G = (((G * 0.0039216) * bright) - 0.5) * contrast + 0.5
			B = (((B * 0.0039216) * bright) - 0.5) * contrast + 0.5

			writePx(out, (rowo + x) * 4, R * 255.0, G * 255.0, B * 255.0)
		end
	end
end

-- =================================================================================
-- OVERLAY path — generates a translucent RGBA "damage" layer (no source image).
-- Drawn on top of everything, its alpha channel lets the live scene/UI below show
-- through while scanlines, grain, head-switch band, dropouts, color fringe,
-- vignette and a rolling bar degrade it into a VHS signal. Roblox can't read the
-- pixels below, so this composites damage rather than warping the actual content.
-- Fine 1px scanlines come from a separate tiled layer (generateScanline); here we
-- add only soft scanline shading so the two don't fight.
-- =================================================================================
local function processOverlay(out: buffer, W: number, H: number, p, frame: number)
	local invW = 1.0 / W
	local invH = 1.0 / H
	local fframe = frame + 0.0
	local t = fframe * 0.037

	local master = clamp(p.power, 0.0, 1.0) * clamp(p.analogStrength, 0.0, 3.0)
	local grainAmt = clamp(p.analogTapeNoise, 0.0, 3.0)
	local headAmt = clamp(p.analogHeadSwitch, 0.0, 3.0)
	local dropAmt = clamp(p.analogDropouts, 0.0, 3.0)
	local bandMask = clamp(p.analogBandMask, 0.0, 1.0)
	local vign = clamp(p.vignette, 0.0, 1.0)
	local tracking = clamp(p.analogTracking, 0.0, 3.0)
	local bleed = clamp(p.analogChromaBleed, 0.0, 3.0)
	local scanShade = clamp(p.analogScanlines, 0.0, 3.0)
	local bright = p.brightness

	local headY = 0.84 + sin(fframe * 0.021) * 0.02
	local rollY = (fframe * 0.006) % 1.0 -- rolling brightness bar
	local tearY = (fframe * 0.02 * (0.3 + tracking)) % 1.0 -- sweeping tracking band
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

			-- vignette (darken edges)
			local dxc = u - 0.5
			local dyc = v - 0.5
			local r = sqrt(dxc * dxc + dyc * dyc) * 1.41421
			local vigA = vign * clamp((r - 0.42) / 0.58, 0.0, 1.0) ^ 1.5 * 0.85
			pr, pg, pb, pa = over(pr, pg, pb, pa, 0.0, 0.0, 0.0, vigA)

			-- global brightness tint (darken or lift)
			if bright < 0 then
				pr, pg, pb, pa = over(pr, pg, pb, pa, 0.0, 0.0, 0.0, -bright * 0.7)
			elseif bright > 0 then
				pr, pg, pb, pa = over(pr, pg, pb, pa, 1.0, 1.0, 1.0, bright * 0.45)
			end

			-- soft scanline shading (the crisp lines are the tiled layer)
			local ss = 0.5 + 0.5 * sin(v * H * 3.1415927)
			pr, pg, pb, pa = over(pr, pg, pb, pa, 0.0, 0.0, 0.0, ss * scanShade * 0.05 * master)

			-- rolling brightness bar (subtle CRT roll)
			pr, pg, pb, pa = over(pr, pg, pb, pa, 1.0, 1.0, 1.0, rollBand * 0.06 * master)

			-- luminance grain (animated static over everything)
			local g = gaussTemporal(x, y, fframe, 0.0)
			local gv = clamp(0.5 + g * 0.35, 0.0, 1.0)
			local grainA = clamp(abs(g) * 0.05, 0.0, 0.45) * grainAmt * master
			pr, pg, pb, pa = over(pr, pg, pb, pa, gv, gv, gv, grainA)

			-- chroma fringe noise (fake color bleed) tied to chroma-bleed knob
			if bleed > 0.0 then
				local cn = gaussTemporal(x + 4.0, y, fframe, 121.0)
				local fringeA = clamp(abs(cn) * 0.04, 0.0, 0.3) * bleed * master
				-- alternate magenta / green-cyan fringe by sign, like mis-registered chroma
				if cn >= 0 then
					pr, pg, pb, pa = over(pr, pg, pb, pa, 0.9, 0.1, 0.7, fringeA)
				else
					pr, pg, pb, pa = over(pr, pg, pb, pa, 0.1, 0.9, 0.6, fringeA)
				end
			end

			-- dropouts (bright horizontal streaks)
			if dGate > 0.0 and dropAmt > 0.0 then
				local segPos = fract(x / dSegW + dSeed)
				local env = smoothBand(segPos, 0.0, 0.12) * (1.0 - smoothBand(segPos, 0.7, 1.0))
				if env > 0.0 then
					local ds = clamp(0.7 + (hash13(x * 0.91, y * 1.73, fframe + 12.0) - 0.5), 0.0, 1.0)
					local dropA = env * clamp(dropAmt * 0.5, 0.0, 1.0) * (0.4 + bandMask) * master
					pr, pg, pb, pa = over(pr, pg, pb, pa, ds, ds, ds, clamp(dropA, 0.0, 0.9))
				end
			end

			-- tracking sweep band (a noisy band that rolls through, sells "tracking")
			if tearBand > 0.0 then
				local tn = clamp(0.5 + (hash13(x * 0.4, fieldLine * 1.1, dFrame + 5.0) - 0.5) * 1.6, 0.0, 1.0)
				pr, pg, pb, pa = over(pr, pg, pb, pa, tn, tn, tn, tearBand * 0.5 * master)
			end

			-- head-switch tear band at the bottom (strong noise + edge feather)
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
				writeRGBA(out, o, 0.0, 0.0, 0.0, 0.0)
			end
		end
	end
end

-- public dispatch ----------------------------------------------------------------
function Pipeline.process(src: buffer, out: buffer, W: number, H: number, params, frame: number)
	if params.mode == "overlay" then
		processOverlay(out, W, H, params, frame)
	elseif params.mode == "analog" then
		processAnalog(src, out, W, H, params, frame)
	else
		processDigital(src, out, W, H, params, frame)
	end
end

-- Fill a small RGBA tile for the crisp scanline layer: one dark row every
-- `periodH` rows. The ImageLabel tiles this at native resolution (Pixelated), so
-- the lines stay 1px sharp regardless of screen size. `alpha` is 0..1.
function Pipeline.generateScanline(dst: buffer, w: number, periodH: number, alpha: number)
	local a = clampb(alpha * 255.0)
	for y = 0, periodH - 1 do
		local lineAlpha = (y == 0) and a or 0
		for x = 0, w - 1 do
			local o = (y * w + x) * 4
			writeu8(dst, o, 0)
			writeu8(dst, o + 1, 0)
			writeu8(dst, o + 2, 0)
			writeu8(dst, o + 3, lineAlpha)
		end
	end
end

-- =================================================================================
-- source helpers (run once on load / resolution change, not per frame)
-- =================================================================================

-- bilinear downscale of a native RGBA8 buffer into the small working buffer.
function Pipeline.resample(srcBuf: buffer, sw: number, sh: number, dst: buffer, dw: number, dh: number)
	local sxScale = sw / dw
	local syScale = sh / dh
	for y = 0, dh - 1 do
		local fy = (y + 0.5) * syScale - 0.5
		local y0 = floor(fy)
		local ty = fy - y0
		local y0c = clamp(y0, 0, sh - 1)
		local y1c = clamp(y0 + 1, 0, sh - 1)
		for x = 0, dw - 1 do
			local fx = (x + 0.5) * sxScale - 0.5
			local x0 = floor(fx)
			local tx = fx - x0
			local x0c = clamp(x0, 0, sw - 1)
			local x1c = clamp(x0 + 1, 0, sw - 1)
			local o00 = (y0c * sw + x0c) * 4
			local o10 = (y0c * sw + x1c) * 4
			local o01 = (y1c * sw + x0c) * 4
			local o11 = (y1c * sw + x1c) * 4
			local do_ = (y * dw + x) * 4
			for ch = 0, 2 do
				local top = mix(readu8(srcBuf, o00 + ch), readu8(srcBuf, o10 + ch), tx)
				local bot = mix(readu8(srcBuf, o01 + ch), readu8(srcBuf, o11 + ch), tx)
				writeu8(dst, do_ + ch, floor(mix(top, bot, ty) + 0.5))
			end
			writeu8(dst, do_ + 3, 255)
		end
	end
end

-- SMPTE-style test pattern (color bars + a gradient strip) so the effect has
-- something rich to chew on when no source asset is configured.
function Pipeline.generateTestPattern(dst: buffer, W: number, H: number)
	local bars = {
		{ 192, 192, 192 },
		{ 192, 192, 32 },
		{ 32, 192, 192 },
		{ 32, 192, 32 },
		{ 192, 32, 192 },
		{ 192, 32, 32 },
		{ 32, 32, 192 },
		{ 24, 24, 24 },
	}
	local barSplit = floor(H * 0.72)
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local o = (y * W + x) * 4
			local r, g, b
			if y < barSplit then
				local idx = floor(x / W * 8) + 1
				if idx > 8 then
					idx = 8
				end
				local c = bars[idx]
				r, g, b = c[1], c[2], c[3]
			else
				-- bottom: horizontal black->white gradient with a blue pluge step
				local t = x / W
				local v = floor(t * 255.0)
				if t < 0.15 then
					r, g, b = 16, 16, 48
				else
					r, g, b = v, v, v
				end
			end
			writeu8(dst, o, r)
			writeu8(dst, o + 1, g)
			writeu8(dst, o + 2, b)
			writeu8(dst, o + 3, 255)
		end
	end
end

return Pipeline
