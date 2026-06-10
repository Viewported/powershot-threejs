# PowerSHOT for Roblox

A Luau port of the [PowerSHOT](../README.md) realtime ISP / analog-VHS filter,
running on the CPU through an `EditableImage` and displayed fullscreen. Built for
a lobby screen: the effect animates live and every knob is exposed in a tuner
panel you toggle with **J**.

> **Heads up — what this is and isn't.** Roblox has no shader/GPU access, so the
> whole pipeline runs per-pixel in Luau on a small `EditableImage` that's
> stretched to fill the screen (pixelated upscale — which is perfect for the
> retro look). The cheap, high-impact stages are ported faithfully; the
> expensive multi-pass ones (full Bayer mosaic/demosaic, 8×8 JPEG DCT, 25-tap
> bilateral NR) are approximated, because running them per pixel per frame in
> Luau is not realtime. See [Fidelity](#fidelity-vs-the-threejs-version).
>
> These scripts were written against the `EditableImage` API but **not executed
> in Studio from here** — drop them in and validate. If an API call differs in
> your engine version, it'll be one of the calls flagged in
> [Troubleshooting](#troubleshooting).

## Files & where they go

Four files. Three are `ModuleScript`s under one folder; one is a `LocalScript`.

```
ReplicatedStorage
└── PowerShot                     ← create a Folder named exactly "PowerShot"
    ├── Config      (ModuleScript)   ← Config.luau
    ├── Pipeline    (ModuleScript)   ← Pipeline.luau
    └── Tuner       (ModuleScript)   ← Tuner.luau

StarterPlayer
└── StarterPlayerScripts
    └── PowerShotClient (LocalScript) ← PowerShotClient.client.luau
```

Step by step in Studio:

1. In **ReplicatedStorage**, insert a **Folder**, rename it `PowerShot`.
2. Inside it, insert three **ModuleScript**s named `Config`, `Pipeline`, `Tuner`
   and paste in the matching `.luau` file contents.
3. In **StarterPlayer › StarterPlayerScripts**, insert a **LocalScript** named
   `PowerShotClient` and paste in `PowerShotClient.client.luau`.
4. Press **Play**. You should see the test pattern with the effect running, and
   pressing **J** opens the tuner.

(The `.client.luau` / `.luau` suffixes are [Rojo](https://rojo.space) naming
conventions — when pasting by hand the suffix doesn't matter, just match the
instance **type** and **name** above. If you do use Rojo, the names already map
correctly.)

## Using your own image

By default it renders a built-in SMPTE-style test pattern so you can see every
effect immediately. To run it on your lobby art instead:

1. Upload the image to Roblox (it **must be an asset you own** — `EditableImage`
   refuses to read assets you don't have rights to).
2. In `Config`, set:
   ```lua
   Config.SOURCE_ASSET_ID = "rbxassetid://YOUR_ID_HERE"
   ```

The source is read once and downscaled to the working resolution; the per-frame
effect runs on that.

> Roblox can't capture the live 3D scene into an `EditableImage` (there's no
> framebuffer read), so the source is always a static image asset. The effect
> animates on top of it.

## Controls

- **J** — show/hide the tuner panel.
- **Mode** — switch between the digital-camera ISP look and the analog VHS look.
- **Tape: LIVE/FROZEN** — pause the animated grain/tape noise on a still frame.
- **Preset** — cycle the five camera presets (Cyber-shot, PowerShot, etc.).
- **Resolution** — working resolution scale. **Lower this first if it's heavy.**
- Every other slider maps 1:1 to a pipeline parameter (see `Tuner.luau`'s
  `SPECS`).

## Performance

It processes `BASE_WIDTH × BASE_HEIGHT` (default `192 × 108` ≈ 20k pixels) at
`TARGET_FPS` (default 24), decoupled from render framerate. Cost scales with
pixel count, so the **Resolution** slider is your main dial. If the lobby drops
frames:

1. Drag **Resolution** down (or lower `TARGET_FPS` / `BASE_*` in `Config`).
2. The analog path is the heaviest (most taps). Digital is cheaper.

Want more headroom at higher res? The per-pixel kernels in `Pipeline` are pure
functions over a buffer, so they're ready to be split across **parallel Luau
Actors** (each worker processes a horizontal band into its slice of the output
buffer, then the main thread writes the assembled buffer to the EditableImage).
That's the natural next step but adds real complexity (Actor setup + buffer
hand-off), so this drop-in version is single-threaded and verified-by-design;
parallelizing is left as an opt-in upgrade.

## Fidelity vs the three.js version

**Ported faithfully (per-pixel):**
- Barrel distortion, chromatic aberration, lens-PSF softness
- White balance, color-correction matrix, tone curve (highlight clip / gamma /
  shadow crush), saturation, vignette, edge enhancement
- Animated sensor grain (Box-Muller read+shot noise, same hashes)
- The full **analog VHS** stage: tracking jitter, luma pre-emphasis/ringing,
  chroma bleed + phase noise, color-subcarrier crawl, dropouts, scanlines /
  interlace, head-switch tear band, edge wave, right-edge wrap
- Output brightness/contrast grade and source/effect power blend

**Approximated or omitted (too slow per-frame in Luau):**
- **CCD bloom** → a cheap 5-tap vertical highlight smear instead of the
  3-pass quarter-res integration.
- **Bayer mosaic → demosaic** → skipped; sensor noise is applied directly in RGB
  (at this resolution a full CFA round-trip wouldn't read anyway).
- **JPEG DCT compression** and **joint-bilateral Bayer NR / chroma NR** →
  omitted (8×8 DCT blocks and 25-tap bilateral filters per pixel per frame).
- Analog horizontal taps are trimmed from ±7px to ±3px.

The numeric constants and color-space math match the reference 1:1, so a given
preset/slider lands in the same place visually, just at lower resolution.

## Troubleshooting

- **Black screen / "EditableImage unavailable":** check the Output window. The
  two API calls to confirm against your engine version are
  `AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })` and
  `imageLabel.ImageContent = Content.fromObject(editableImage)`.
- **"could not load SOURCE_ASSET_ID":** the asset isn't owned by you / the place,
  or the id is wrong. It falls back to the test pattern automatically.
- **Tuner won't open:** make sure another GUI isn't eating the J key, and that
  the LocalScript is under StarterPlayerScripts (not ServerScriptService).
- **Choppy:** lower the **Resolution** slider — see [Performance](#performance).
