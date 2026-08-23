## Broadcast-side art: the cog compositor, the couch bake, the floor tiles and
## the small round/ring bakes the FX layers draw from.
##
## Everything here is BROADCAST-ONLY: no sim state enters `gameHash`, and no
## change here needs a GameVersion bump. Floats are legal (rendering never
## enters the hash), exactly as in ctf.
##
## THE COGS ARE REAL ART, NOT A PROCEDURAL RIG: `data/rig_real/blue/*` and
## `data/rig_real/red/*` are coworld-ctf's shipped nine-segment cog rigs, and
## `cogPixels` composes them (rear wheel, rear leg, front wheels, front legs,
## shoulders, head) into one upright cog per livery per heading step, exactly
## the draw order ctf's `global.nim` places them in. The couch, its scuff
## decals, the floor slabs and the FX discs are baked here with pixie —
## already a dependency, already how ctf bakes its board.

import
  std/[math, os, tables],
  pixie,
  sim_types

const
  RigSteps* = 16              ## baked heading steps (16 brads apart).
  RigCanvas* = 88             ## px square cog sprite canvas at 1x.
  RigFrame = 192              ## the master frame the rig segments are drawn in.
  CogBodyPx* = 30             ## the cog's footprint on the map at 1x.
  CouchCanvas* = 68           ## px square couch sprite canvas at 1x.
  ScuffPx* = 9

  RigSegments*: array[9, string] = [
    "wheel_rear", "leg_rear", "wheel_l", "wheel_r",
    "leg_fl", "leg_fr", "arm_l", "arm_r", "head"]
    ## Back-to-front draw order, ctf's z-order for the same nine segments.

var
  rigImages: array[SeatCount, seq[Image]]
  rigLoaded: array[SeatCount, bool]
  cogCache = initTable[int, seq[uint8]]()
  couchCache = initTable[int, seq[uint8]]()
  discCache = initTable[(int, uint8, uint8, uint8, uint8), seq[uint8]]()
    ## Keyed by a TUPLE, not a packed int: `int` is 32 bits under
    ## --cpu:wasm32 and a size-major packing overflows it.
  ringCache = initTable[(int, uint8, uint8, uint8, uint8), seq[uint8]]()

proc gameDir*(): string =
  ## Assets resolve against the process working directory, exactly as ctf does
  ## (the Dockerfile copies `data/` next to the binary and the emscripten build
  ## preloads it as `data`).
  getCurrentDir()

proc liveryDir(seat: Seat): string =
  if seat == Cobalt: "blue" else: "red"

proc ensureRigLoaded(seat: Seat) =
  if rigLoaded[ord(seat)]:
    return
  let dir = gameDir() / "data" / "rig_real" / liveryDir(seat)
  var images: seq[Image] = @[]
  for name in RigSegments:
    images.add(readImage(dir / name & ".png"))
  rigImages[ord(seat)] = images
  rigLoaded[ord(seat)] = true

proc canvasToPixels(canvas: Image): seq[uint8] =
  ## Straight-alpha RGBA for the Sprite v1 protocol (pixie stores
  ## premultiplied).
  result = newSeq[uint8](canvas.width * canvas.height * 4)
  for i in 0 ..< canvas.width * canvas.height:
    let c = canvas.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc seatColour*(seat: Seat): ColorRGBA {.inline.} =
  if seat == Cobalt: CobaltColor else: RustColor

proc headingStep*(headingQ: int32): int =
  ## Nearest of the RigSteps baked headings, from a 1/16-brad angle.
  let q = ((int(headingQ) mod HeadingQTurn) + HeadingQTurn) mod HeadingQTurn
  ((q * RigSteps + HeadingQTurn div 2) div HeadingQTurn) mod RigSteps

proc cogPixels*(seat: Seat, step: int, renderScale = 1): seq[uint8] =
  ## One cog at one heading step, composed from the shipped rig segments and
  ## rotated as a whole about the master frame's hub. Cached for the life of
  ## the process: 2 liveries x 16 steps.
  let
    b = ((step mod RigSteps) + RigSteps) mod RigSteps
    key = (ord(seat) * RigSteps + b) * 8 + renderScale
  if cogCache.hasKey(key):
    return cogCache[key]
  ensureRigLoaded(seat)
  let
    outCanvas = RigCanvas * renderScale
    centre = float32(outCanvas) / 2
    k = float32(renderScale)
    # The master art faces SOUTH, so the -90 degree turn makes the face lead
    # the heading. Angle increases counter-clockwise; screen y is down, so the
    # rotation is negated.
    angle = float32(b) * 2.0'f32 * float32(PI) / float32(RigSteps)
    rot = -angle - float32(PI) / 2.0'f32
    scale0 = float32(CogBodyPx) * k / 99.0'f32
  var canvas = newImage(outCanvas, outCanvas)
  # A soft ground shadow first, so the cog reads as standing on the floor.
  let shadow = newImage(outCanvas, outCanvas)
  let shadowCtx = newContext(shadow)
  shadowCtx.fillStyle = rgba(0, 0, 0, 70)
  shadowCtx.fillEllipse(vec2(centre, centre + 3.0'f32 * k),
    float32(CogBodyPx) * k * 0.55, float32(CogBodyPx) * k * 0.28)
  shadow.blur(2.0 * k)
  canvas.draw(shadow)
  let mat =
    translate(vec2(centre, centre)) *
    rotate(rot) *
    scale(vec2(scale0, scale0)) *
    translate(vec2(float32(-RigFrame) / 2.0'f32, float32(-RigFrame) / 2.0'f32))
  for image in rigImages[ord(seat)]:
    canvas.draw(image, mat)
  result = canvasToPixels(canvas)
  cogCache[key] = result

proc couchPixels*(step: int, renderScale = 1): seq[uint8] =
  ## The couch: shaded upholstery, two cushions, rolled arms and a drop
  ## shadow, baked once per heading step. 2.20 m x 0.90 m with rounded ends.
  let
    b = ((step mod RigSteps) + RigSteps) mod RigSteps
    key = b * 8 + renderScale
  if couchCache.hasKey(key):
    return couchCache[key]
  let
    outCanvas = CouchCanvas * renderScale
    centre = float32(outCanvas) / 2
    k = float32(renderScale)
    pxPerUm = float32(renderScale) / float32(MapScale)
    halfL = float32(CouchLengthUm) * pxPerUm / 2.0'f32
    halfW = float32(CouchWidthUm) * pxPerUm / 2.0'f32
    angle = float32(b) * 2.0'f32 * float32(PI) / float32(RigSteps)
  var flat = newImage(outCanvas, outCanvas)
  let ctx = newContext(flat)
  # drop shadow
  ctx.fillStyle = rgba(0, 0, 0, 90)
  ctx.fillRoundedRect(rect(centre - halfL, centre - halfW + 2.0'f32 * k,
    halfL * 2, halfW * 2), halfW * 0.9)
  # body
  ctx.fillStyle = CouchBody
  ctx.fillRoundedRect(rect(centre - halfL, centre - halfW, halfL * 2,
    halfW * 2), halfW * 0.85)
  # back rail (the long far edge reads as the couch back)
  ctx.fillStyle = CouchTrim
  ctx.fillRoundedRect(rect(centre - halfL * 0.98, centre - halfW * 0.98,
    halfL * 1.96, halfW * 0.52), halfW * 0.3)
  # two cushions
  ctx.fillStyle = rgba(142, 90, 108, 255)
  for side in [-1.0'f32, 1.0'f32]:
    ctx.fillRoundedRect(rect(centre + side * halfL * 0.06 -
      (if side < 0: halfL * 0.46 else: 0.0'f32),
      centre - halfW * 0.30, halfL * 0.40, halfW * 1.10), halfW * 0.22)
  # rolled arms at both ends
  ctx.fillStyle = rgba(96, 58, 74, 255)
  ctx.fillEllipse(vec2(centre - halfL * 0.92, centre), halfW * 0.42, halfW)
  ctx.fillEllipse(vec2(centre + halfL * 0.92, centre), halfW * 0.42, halfW)
  # the two handles the cogs grip
  ctx.fillStyle = rgba(216, 200, 176, 235)
  ctx.fillEllipse(vec2(centre - halfL - 2.0'f32 * k, centre), 2.4'f32 * k,
    halfW * 0.34)
  ctx.fillEllipse(vec2(centre + halfL + 2.0'f32 * k, centre), 2.4'f32 * k,
    halfW * 0.34)
  var canvas = newImage(outCanvas, outCanvas)
  canvas.draw(flat,
    translate(vec2(centre, centre)) * rotate(-angle) *
    translate(vec2(-centre, -centre)))
  result = canvasToPixels(canvas)
  couchCache[key] = result

proc scuffPixels*(stage: int, renderScale = 1): seq[uint8] =
  ## One accumulated scuff decal. `stage` 0..3 darkens and widens the mark, so
  ## damage reads as the couch collecting scars rather than a bar going down.
  let
    size = max(1, ScuffPx * renderScale)
    tone = uint8(120 - 22 * clamp(stage, 0, 3))
    alpha = uint8(120 + 34 * clamp(stage, 0, 3))
  var canvas = newImage(size, size)
  let
    ctx = newContext(canvas)
    r = float32(size) / 2.0
  ctx.strokeStyle = rgba(tone, tone - 30, tone - 40, alpha)
  ctx.lineWidth = max(1.0'f32, r * 0.35)
  ctx.strokeSegment(segment(vec2(r * 0.3, r * 1.4), vec2(r * 1.7, r * 0.5)))
  ctx.strokeSegment(segment(vec2(r * 0.45, r * 0.6), vec2(r * 1.3, r * 1.5)))
  canvasToPixels(canvas)

proc discPixels*(size: int, colour: ColorRGBA, feather = true): seq[uint8] =
  ## A soft round dot: the force arrows, the strain arrows, the sparks and the
  ## dust all draw from this one bake, keyed by (size, colour).
  let key = (size, colour.r, colour.g, colour.b, colour.a)
  if discCache.hasKey(key):
    return discCache[key]
  var canvas = newImage(max(1, size), max(1, size))
  let
    ctx = newContext(canvas)
    r = float32(max(1, size)) / 2.0
  ctx.fillStyle = colour
  ctx.fillEllipse(vec2(r, r), r * (if feather: 0.86 else: 1.0),
    r * (if feather: 0.86 else: 1.0))
  if feather:
    canvas.blur(max(0.6'f32, r * 0.20))
  result = canvasToPixels(canvas)
  discCache[key] = result

proc ringPixels*(size: int, colour: ColorRGBA, thickness: float32):
    seq[uint8] =
  ## A hollow ring: the doorway glow and the impact burst.
  let key = (size * 8 + int(thickness), colour.r, colour.g, colour.b, colour.a)
  if ringCache.hasKey(key):
    return ringCache[key]
  var canvas = newImage(max(1, size), max(1, size))
  let
    ctx = newContext(canvas)
    r = float32(max(1, size)) / 2.0
  ctx.strokeStyle = colour
  ctx.lineWidth = thickness
  ctx.strokeEllipse(vec2(r, r), max(1.0'f32, r - thickness),
    max(1.0'f32, r - thickness))
  result = canvasToPixels(canvas)
  ringCache[key] = result

proc invalidateArtCaches*() =
  ## Drops every process-wide cache derived from the art bakes. Needed when the
  ## serve loop hot-switches replays.
  cogCache.clear()
  couchCache.clear()
  discCache.clear()
  ringCache.clear()
