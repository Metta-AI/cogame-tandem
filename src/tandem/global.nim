## The board renderer: the baked warehouse floor and walls, the couch, the two
## cogs, the force and strain arrows, the scuff decals, the scrape sparks, the
## drop dust and the doorway glow, composed as Sprite v1 sprite/object
## messages.
##
## This replaces ctf's `global.nim` (7 700 lines of fog of war, vision cones,
## first-person raycasting, killfeed art and item sprites). Two people carrying
## a couch can see the room and each other, so tandem is PERFECT INFORMATION:
## there is no fog, and the two builders differ only in the self marker and the
## seat's own-alias marker.
##
## Floats are legal here — rendering never enters `gameHash`, exactly as in
## ctf. The floor bake lives here rather than in `course.nim` because that
## module sits inside the float-free grep guard and pixie is a float API.

import
  std/[math, tables],
  pixie,
  bitworld/spriteprotocol,
  sim, control, labels, rig_art

const
  BoardScale* = 2
    ## Board pixels per LOGICAL map pixel. The chrome reports this as `bs` and
    ## converts board <-> world with it. 2 is comfortably inside the wasm32
    ## viewer's address space: the whole 2220x1260 floor bake is 11 MB.
  BoardW* = MapWidth * BoardScale
  BoardH* = MapHeight * BoardScale
  MapLayerId* = 0
  MapBandRows = 96 * BoardScale

  MaxSupersampledMapPixels* = 8_000_000
    ## Above this the board would be emitted at 1x. Tandem has ONE board size
    ## (1110 x 630 logical = 2220 x 1260 at BoardScale), so this never trips;
    ## the constant is kept because `tandem_replay.nim` asserts against the
    ## same budget ctf's viewer does.
  WasmViewerBudgetBytes* = 1_400_000_000
    ## The wasm32 viewer has a 2 GB address space; refuse a board whose render
    ## buffers would not fit BEFORE baking starts, so the page gets a clean
    ## diagnostic instead of an OOM abort.

  # ---- sprite ids -----------------------------------------------------------
  MapBandSpriteBase = 30
  MaxMapBands = 32
  CouchSpriteBase = 100        ## one per heading step.
  CogSpriteBase = 140          ## 2 liveries x RigSteps.
  ScuffSpriteBase = 200        ## one per scuff stage.
  ForceDotSpriteBase = 210     ## one per seat.
  StrainDotSpriteId = 214
  SparkSpriteId = 216
  DustSpriteId = 218
  DoorRingSpriteId = 220
  SelfMarkerSpriteId = 222
  OwnSeatSpriteId = 224
  BroadcastChromeSpriteId* = 4090
    ## The reserved 1x1 sprite whose LABEL carries the chrome JSON. Kept from
    ## ctf, id and all, so the shared client code needs no change.

  # ---- object ids -----------------------------------------------------------
  MapBandObjectBase = 30
  CouchObjectId = 1000
  CogObjectBase = 1010
  SelfMarkerObjectId = 1020
  OwnSeatObjectId = 1022
  ForceObjectBase = 1100       ## 2 seats x ArrowDots
  StrainObjectBase = 1140
  ScuffObjectBase = 1200
  ScuffSlots = 48
  SparkObjectBase = 1300
  SparkSlots = 48
  DustObjectBase = 1400
  DustSlots = 12
  DoorObjectBase = 1420
  DoorSlots = 3

  ArrowDots = 9
  ArrowDotPx = 5
  StrainDots = 7
  ForceArrowMetres = 1_500_000 ## a full 600 N arrow is 1.5 m on the board.
  SparkTicks = 8
  DustTicks = 36

  BoardObjectPools: array[5, tuple[name: string, base, width: int]] = [
    ("map", MapBandObjectBase, MaxMapBands),
    ("scuffs", ScuffObjectBase, ScuffSlots),
    ("sparks", SparkObjectBase, SparkSlots),
    ("dust", DustObjectBase, DustSlots),
    ("arrows", ForceObjectBase, 2 * ArrowDots)
  ]

type
  SpriteDefinition = ref object
    spriteId: int
    width, height: int
    label: string
    pixels: seq[uint8]

  GlobalViewerState* = object
    initialized*: bool
    mouseX*, mouseY*, mouseLayer*: int
    mouseDown*: bool
    clickPending*: bool
    selectedJoinOrder*: int
    povJoinOrder*: int
    povSelectPending*: int
    scrubbingReplay*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]
    momentumSent*: bool
    spriteDefs: seq[SpriteDefinition]

  PlayerViewerState* = ref object
    initialized*: bool
    sentPlacements*: seq[array[12, uint8]]
    spriteDefs: seq[SpriteDefinition]

proc predictedViewerRenderBytes*(mapWidth, mapHeight: int): int64 =
  ## The render buffers the browser viewer would need for a board of this size
  ## (the banded RGBA bake, plus the working image it is cut from).
  int64(mapWidth) * int64(mapHeight) * int64(BoardScale) *
    int64(BoardScale) * 4'i64 * 2'i64

proc boardObjectPoolName*(objectId: int): string =
  ## Names the fixed object pool an object id belongs to, for traffic metrics.
  for (name, base, width) in BoardObjectPools:
    if objectId >= base and objectId < base + width:
      return name
  "core"

proc boardRenderScaleFor*(mapWidth, mapHeight: int): int =
  ## The board's supersample factor. Fixed here: tandem has exactly one board
  ## size and it is small enough to render at BoardScale on every target.
  if mapWidth * mapHeight * BoardScale * BoardScale > MaxSupersampledMapPixels:
    1
  else:
    BoardScale

proc initGlobalViewerState*(): GlobalViewerState =
  result.mouseLayer = MapLayerId
  result.selectedJoinOrder = -1
  result.povJoinOrder = -1
  result.povSelectPending = -2   ## -2 = no request; -1 = clear; >= 0 = slot.
  result.replaySeekTick = -1
  result.replayCommands = @[]

proc initPlayerViewerState*(): PlayerViewerState =
  new(result)

# --------------------------------------------------------------------------
# Client -> server messages
# --------------------------------------------------------------------------

proc applyGlobalViewerMessage*(state: var GlobalViewerState, message: string) =
  ## Applies one or more global protocol client messages. Whole-string
  ## commands (`s:<tick>`, `v:<slot>`) are intercepted before the legacy
  ## char-by-char transport path, so a multi-digit tick is never mangled into
  ## speed keystrokes. Kept from ctf.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientMouseMoveMessage:
      state.mouseX = item.x
      state.mouseY = item.y
      state.mouseLayer = if item.hasLayer: item.layer else: MapLayerId
    of SpriteClientMouseButtonMessage:
      if item.button == 0x01'u8:
        state.mouseDown = item.down
        if state.mouseDown:
          state.clickPending = true
        else:
          state.scrubbingReplay = false
    of SpriteClientChatMessage:
      if item.text.len > 2 and item.text[0] == 's' and item.text[1] == ':':
        var tick = 0
        var ok = item.text.len > 2
        for i in 2 ..< item.text.len:
          if item.text[i] notin {'0' .. '9'}:
            ok = false
            break
          tick = tick * 10 + (ord(item.text[i]) - ord('0'))
        if ok:
          state.replaySeekTick = tick
      elif item.text.len > 2 and item.text[0] == 'v' and item.text[1] == ':':
        var slot = 0
        var ok = true
        var negative = false
        for i in 2 ..< item.text.len:
          if i == 2 and item.text[i] == '-':
            negative = true
            continue
          if item.text[i] notin {'0' .. '9'}:
            ok = false
            break
          slot = slot * 10 + (ord(item.text[i]) - ord('0'))
        if ok:
          state.povSelectPending = if negative: -slot else: slot
      else:
        for ch in item.text:
          state.replayCommands.add(ch)
    of SpriteClientInputMessage, SpriteClientReadyMessage,
        SpriteClientDebugSpriteMessage:
      discard

proc applyPlayerViewerMessage*(
  state: var PlayerViewerState,
  message: string,
  inputMask: var uint8,
  pressedMask: var uint8,
  chatText: var string
) =
  ## A seat sends NO inputs (the server computes both force vectors), so the
  ## input bits are read and dropped. Its ONE chat message is its
  ## registration; the server intercepts it and never writes it to the replay
  ## chat stream. ctf's 0x86 debug-sprite channel is deleted rather than left
  ## dangling.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      chatText.add(item.text)
    of SpriteClientInputMessage:
      pressedMask = 0
      inputMask = 0
    else:
      discard
  discard state

# --------------------------------------------------------------------------
# Packet plumbing (kept from ctf: generic, sprite-protocol level)
# --------------------------------------------------------------------------

proc chunkSpritePacket*(packet: seq[uint8], maxBytes: int): seq[seq[uint8]] =
  ## Splits one sprite-protocol packet into WS-frame-sized chunks at MESSAGE
  ## boundaries. The hosted replay closes any frame over 1 MiB (1009), and the
  ## client accumulates sprite/object state across binary messages, so N
  ## frames are equivalent to one — as long as no frame is cut mid-message.
  result = @[]
  if packet.len == 0:
    return
  var
    offset = 0
    chunkStart = 0
  while offset < packet.len:
    let msgStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:
      let clen = packet.readU32(offset + 6)
      offset += 10 + clen
      let llen = packet.readU16(offset)
      offset += 2 + llen
    of 0x02: offset += 11
    of 0x03: offset += 2
    of 0x04: discard
    of 0x05: offset += 5
    of 0x06: offset += 3
    else:
      break
    if offset - chunkStart > maxBytes and msgStart > chunkStart:
      result.add(packet[chunkStart ..< msgStart])
      chunkStart = msgStart
  if chunkStart < packet.len:
    result.add(packet[chunkStart ..< packet.len])

proc stripSpritePixels*(packet: seq[uint8], keepLabel = ""): seq[uint8] =
  ## Rewrites one packet for a Sprites Off (0x87) client: sprite definitions
  ## keep id, dimensions and label but ship a zero-length pixel payload.
  result = newSeqOfCap[uint8](packet.len)
  var offset = 0
  while offset < packet.len:
    let messageStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:
      let compressedLen = packet.readU32(offset + 6)
      let labelStart = offset + 10 + compressedLen
      let labelLen = packet.readU16(labelStart)
      let messageEnd = labelStart + 2 + labelLen
      var label = newString(labelLen)
      for i in 0 ..< labelLen:
        label[i] = char(packet[labelStart + 2 + i])
      if keepLabel.len > 0 and label == keepLabel:
        for i in messageStart ..< messageEnd:
          result.add(packet[i])
      else:
        for i in messageStart ..< offset + 6:
          result.add(packet[i])
        result.addU32(0)
        for i in labelStart ..< messageEnd:
          result.add(packet[i])
      offset = messageEnd
    of 0x02, 0x03, 0x04, 0x05, 0x06:
      offset += (
        case messageType
        of 0x02: 11
        of 0x03: 2
        of 0x05: 5
        of 0x06: 3
        else: 0
      )
      for i in messageStart ..< offset:
        result.add(packet[i])
    else:
      for i in messageStart ..< packet.len:
        result.add(packet[i])
      break

proc dedupObjectPlacements*(
  packet: seq[uint8],
  sentPlacements: var seq[array[12, uint8]]
): seq[uint8] =
  ## Drops Define Object messages whose full payload matches what this viewer
  ## already holds. The protocol is retained-mode, so re-sending an identical
  ## placement is pure wire noise. Kept from ctf.
  result = newSeqOfCap[uint8](packet.len)
  if sentPlacements.len == 0:
    sentPlacements.setLen(65536)
  var
    offset = 0
    keepStart = 0
  template flushKept(upTo: int) =
    if upTo > keepStart:
      let start = result.len
      result.setLen(start + upTo - keepStart)
      copyMem(addr result[start], unsafeAddr packet[keepStart],
        upTo - keepStart)
  while offset < packet.len:
    let messageStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:
      offset += 10 + packet.readU32(offset + 6)
      offset += 2 + packet.readU16(offset)
    of 0x02:
      var payload: array[12, uint8]
      copyMem(addr payload[0], unsafeAddr packet[offset], 11)
      payload[11] = 1
      offset += 11
      let objectId = int(payload[0]) or (int(payload[1]) shl 8)
      if sentPlacements[objectId] == payload:
        flushKept(messageStart)
        keepStart = offset
      else:
        sentPlacements[objectId] = payload
    of 0x03:
      sentPlacements[packet.readU16(offset)][11] = 0
      offset += 2
    of 0x04:
      zeroMem(addr sentPlacements[0], sentPlacements.len * 12)
    of 0x05, 0x06:
      offset += (if messageType == 0x05: 5 else: 3)
    else:
      offset = packet.len
  flushKept(packet.len)


# --------------------------------------------------------------------------
# The floor bake
# --------------------------------------------------------------------------

var
  floorBands: seq[seq[uint8]]
  floorBandRows: seq[int]
  floorDigest: int32 = 0
  floorBaked = false

proc worldToBoard(x: int32): int {.inline.} =
  int((int64(x) * int64(BoardScale)) div int64(MapScale))

proc bakeFloorImage*(course: Course): Image =
  ## Stained concrete slabs with expansion joints, painted safety hatching
  ## along the route walls, the warehouse walls, the pillars, the painted
  ## loading-bay goal pad and a dark vignette. Baked once per course at
  ## startup with pixie.
  result = newImage(BoardW, BoardH)
  let
    ctx = newContext(result)
    px = float32(BoardScale) / float32(MapScale)
  proc bx(x: int32): float32 = float32(x) * px
  proc by(y: int32): float32 = float32(y) * px
  # Slabs.
  ctx.fillStyle = FloorDark
  ctx.fillRect(rect(0, 0, float32(BoardW), float32(BoardH)))
  var sy = 0'i32
  var row = 0
  while sy < WorldH:
    var sx = 0'i32
    var col = 0
    while sx < WorldW:
      if (row + col) mod 2 == 0:
        ctx.fillStyle = FloorLight
        ctx.fillRect(rect(bx(sx), by(sy), bx(2_400_000'i32), by(2_400_000'i32)))
      sx += 2_400_000'i32
      inc col
    sy += 2_400_000'i32
    inc row
  # Expansion joints.
  ctx.strokeStyle = rgba(34, 34, 38, 170)
  ctx.lineWidth = max(1.0'f32, bx(30_000'i32))
  var jx = 0'i32
  while jx <= WorldW:
    ctx.strokeSegment(segment(vec2(bx(jx), 0), vec2(bx(jx), float32(BoardH))))
    jx += 2_400_000'i32
  var jy = 0'i32
  while jy <= WorldH:
    ctx.strokeSegment(segment(vec2(0, by(jy)), vec2(float32(BoardW), by(jy))))
    jy += 2_400_000'i32
  # The goal pad: a painted loading bay with chevrons.
  ctx.fillStyle = rgba(88, 78, 46, 255)
  ctx.fillRect(rect(bx(course.goalX0), by(course.goalY0),
    bx(course.goalX1 - course.goalX0), by(course.goalY1 - course.goalY0)))
  ctx.strokeStyle = GoalPadColor
  ctx.lineWidth = max(2.0'f32, bx(90_000'i32))
  ctx.strokeSegment(segment(vec2(bx(course.goalX0), by(course.goalY0)),
    vec2(bx(course.goalX1), by(course.goalY0))))
  ctx.strokeSegment(segment(vec2(bx(course.goalX0), by(course.goalY1)),
    vec2(bx(course.goalX1), by(course.goalY1))))
  ctx.strokeSegment(segment(vec2(bx(course.goalX0), by(course.goalY0)),
    vec2(bx(course.goalX0), by(course.goalY1))))
  ctx.strokeSegment(segment(vec2(bx(course.goalX1), by(course.goalY0)),
    vec2(bx(course.goalX1), by(course.goalY1))))
  var cx = course.goalX0 + 400_000'i32
  while cx < course.goalX1 - 400_000'i32:
    ctx.strokeSegment(segment(
      vec2(bx(cx), by(course.goalY0 + 300_000'i32)),
      vec2(bx(cx + 600_000'i32), by((course.goalY0 + course.goalY1) div 2))))
    ctx.strokeSegment(segment(
      vec2(bx(cx + 600_000'i32), by((course.goalY0 + course.goalY1) div 2)),
      vec2(bx(cx), by(course.goalY1 - 300_000'i32))))
    cx += 900_000'i32
  # Walls.
  for wall in course.walls:
    let
      x0 = max(0'i32, wall.x0)
      y0 = max(0'i32, wall.y0)
      x1 = min(WorldW, wall.x1)
      y1 = min(WorldH, wall.y1)
    if x1 <= x0 or y1 <= y0:
      continue
    ctx.fillStyle =
      case wall.kind
      of 0: rgba(64, 60, 60, 255)
      of 1: rgba(122, 110, 100, 255)
      of 2: rgba(52, 50, 54, 255)
      else: rgba(140, 122, 96, 255)
    ctx.fillRect(rect(bx(x0), by(y0), bx(x1 - x0), by(y1 - y0)))
    ctx.strokeStyle = rgba(24, 22, 24, 220)
    ctx.lineWidth = max(1.0'f32, bx(40_000'i32))
    ctx.strokeSegment(segment(vec2(bx(x0), by(y1)), vec2(bx(x1), by(y1))))
    # Safety hatching on every wall face that borders the route corridor.
    if wall.kind == 1 or wall.kind == 3:
      ctx.strokeStyle = HatchColor
      ctx.lineWidth = max(1.0'f32, bx(50_000'i32))
      var hx = x0
      while hx < x1:
        ctx.strokeSegment(segment(vec2(bx(hx), by(y0)),
          vec2(bx(min(x1, hx + 200_000'i32)), by(y1))))
        hx += 400_000'i32
  # Vignette.
  let vignette = newImage(BoardW, BoardH)
  let vctx = newContext(vignette)
  vctx.fillStyle = rgba(0, 0, 0, 62)
  vctx.fillRect(rect(0, 0, float32(BoardW), float32(BoardH)))
  vctx.fillStyle = rgba(0, 0, 0, 0)
  vctx.fillEllipse(vec2(float32(BoardW) / 2, float32(BoardH) / 2),
    float32(BoardW) * 0.62, float32(BoardH) * 0.72)
  vignette.blur(56.0)
  result.draw(vignette)

proc invalidateBoardMapCaches*() =
  ## Drops every process-wide cache derived from the board bake. Needed when
  ## the serve loop hot-switches replays.
  floorBands = @[]
  floorBandRows = @[]
  floorBaked = false
  floorDigest = 0
  invalidateArtCaches()

proc ensureFloorBands(course: Course) =
  if floorBaked and floorDigest == course.digest:
    return
  floorBands = @[]
  floorBandRows = @[]
  let image = bakeFloorImage(course)
  var y = 0
  while y < BoardH:
    let rows = min(MapBandRows, BoardH - y)
    var band = newSeq[uint8](BoardW * rows * 4)
    for r in 0 ..< rows:
      for x in 0 ..< BoardW:
        let
          c = image.data[(y + r) * BoardW + x].rgba()
          o = (r * BoardW + x) * 4
        band[o] = c.r
        band[o + 1] = c.g
        band[o + 2] = c.b
        band[o + 3] = c.a
    floorBands.add(band)
    floorBandRows.add(rows)
    y += rows
  doAssert floorBands.len <= MaxMapBands, "floor band pool overflow"
  floorBaked = true
  floorDigest = course.digest

proc warmBoardRenderCaches*(sim: SimServer) =
  ## Pre-bakes every process-wide render cache at server startup so the first
  ## viewer's init packet is assembled instantly. Without this the first
  ## connection pays the whole bake, which trips the coworld certifier's
  ## first-message timeout. Idempotent.
  ensureFloorBands(sim.course)
  for step in 0 ..< RigSteps:
    discard couchPixels(step, BoardScale)
    for seat in Seat:
      discard cogPixels(seat, step, BoardScale)

# --------------------------------------------------------------------------
# Emission helpers
# --------------------------------------------------------------------------

proc addSpriteOnce(
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition],
  spriteId, width, height: int,
  pixels: seq[uint8],
  label: string
) =
  ## Emits a sprite definition only when this viewer has not already been sent
  ## an identical one. Sprite definitions are the expensive half of the wire.
  for existing in defs:
    if existing.spriteId == spriteId:
      if existing.width == width and existing.height == height and
          existing.label == label and existing.pixels == pixels:
        return
      existing.width = width
      existing.height = height
      existing.label = label
      existing.pixels = pixels
      packet.addSprite(spriteId, width, height, pixels, label)
      return
  defs.add SpriteDefinition(spriteId: spriteId, width: width, height: height,
    label: label, pixels: pixels)
  packet.addSprite(spriteId, width, height, pixels, label)

proc addBoardChrome(
  sim: SimServer,
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition]
) =
  ## Viewport, layers and the banded warehouse floor. Emitted once per viewer.
  ensureFloorBands(sim.course)
  packet.addViewport(MapLayerId, BoardW, BoardH)
  packet.addLayer(MapLayerId, 0, SpriteLayerZoomableFlag)
  var y = 0
  for i, band in floorBands:
    packet.addSpriteOnce(defs, MapBandSpriteBase + i, BoardW, floorBandRows[i],
      band, LabelFloor)
    packet.addObject(MapBandObjectBase + i, 0, y, -1000, MapLayerId,
      MapBandSpriteBase + i)
    y += floorBandRows[i]

proc addCouchAndCogs(
  sim: SimServer,
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition],
  selfSeat: int
) =
  const
    couchHalf = CouchCanvas * BoardScale div 2
    cogHalf = RigCanvas * BoardScale div 2
  let step = headingStep(sim.headingQ)
  packet.addSpriteOnce(defs, CouchSpriteBase + step, CouchCanvas * BoardScale,
    CouchCanvas * BoardScale, couchPixels(step, BoardScale), LabelCouch)
  packet.addObject(CouchObjectId,
    worldToBoard(sim.posX) - couchHalf, worldToBoard(sim.posY) - couchHalf,
    100, MapLayerId, CouchSpriteBase + step)
  for seat in Seat:
    let
      spriteId = CogSpriteBase + ord(seat) * RigSteps + step
      p = sim.handlePos(seat)
    packet.addSpriteOnce(defs, spriteId, RigCanvas * BoardScale,
      RigCanvas * BoardScale, cogPixels(seat, step, BoardScale),
      LabelCog & " " & seatAlias(seat))
    packet.addObject(CogObjectBase + ord(seat),
      worldToBoard(p.x) - cogHalf, worldToBoard(p.y) - cogHalf,
      120 + ord(seat), MapLayerId, spriteId)
  if selfSeat >= 0:
    const markerPx = 10 * BoardScale
    packet.addSpriteOnce(defs, SelfMarkerSpriteId, markerPx, markerPx,
      discPixels(markerPx, rgba(255, 244, 190, 210)), LabelSelfMarker)
    let p = sim.handlePos(Seat(selfSeat and 1))
    packet.addObject(SelfMarkerObjectId,
      worldToBoard(p.x) - markerPx div 2,
      worldToBoard(p.y) - cogHalf - markerPx,
      300, MapLayerId, SelfMarkerSpriteId)

proc addArrow(
  packet: var seq[uint8],
  fromX, fromY: int32,
  vecX, vecY: int32,
  fullScale: int32,
  spriteId, objectBase, dots, zIndex: int
) =
  ## One arrow, drawn as a tapering chain of dots from a handle along a vector.
  ## Sprite v1 has no per-object scaling, so an arrow is a placed CHAIN rather
  ## than one stretched bitmap — which also means it costs a single sprite
  ## definition and re-derives identically in the viewer.
  let magnitude = distI(vecX, vecY)
  var used = 0
  if magnitude > 0 and fullScale > 0:
    let
      lengthUm = int32(min(int64(ForceArrowMetres),
        (int64(ForceArrowMetres) * int64(magnitude)) div int64(fullScale)))
      unit = unitQ12(vecX, vecY)
      shown = max(1, min(dots, int((int64(lengthUm) * int64(dots)) div
        int64(ForceArrowMetres))))
    for i in 0 ..< shown:
      let
        along = int32((int64(lengthUm) * int64(i + 1)) div int64(shown))
        px = fromX + q12Scale(along, unit.x)
        py = fromY + q12Scale(along, unit.y)
      packet.addObject(objectBase + i,
        worldToBoard(px) - ArrowDotPx * BoardScale div 2,
        worldToBoard(py) - ArrowDotPx * BoardScale div 2,
        zIndex, MapLayerId, spriteId)
    used = shown
  for i in used ..< dots:
    packet.addDeleteObject(objectBase + i)

proc addArrows(
  sim: SimServer,
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition]
) =
  ## The idea's headline readout: an arrow from each cog in its livery colour,
  ## length proportional to the force that seat is applying, plus a thinner
  ## white strain arrow at each handle showing the force it FEELS. Drawn
  ## Nim-side as sprite objects, so they are identical live and in replay and
  ## cost no extra replay bytes.
  const dotPx = ArrowDotPx * BoardScale
  packet.addSpriteOnce(defs, StrainDotSpriteId, dotPx, dotPx,
    discPixels(dotPx, rgba(242, 232, 216, 190)), LabelStrainArrow)
  for seat in Seat:
    let
      colour = seatColour(seat)
      spriteId = ForceDotSpriteBase + ord(seat)
      handle = sim.handlePos(seat)
      compiled = sim.seatForce(seat)
    packet.addSpriteOnce(defs, spriteId, dotPx, dotPx,
      discPixels(dotPx, rgba(colour.r, colour.g, colour.b, 225)),
      LabelForceArrow & " " & seatAlias(seat))
    packet.addArrow(handle.x, handle.y, compiled.force.x, compiled.force.y,
      int32(sim.config.maxSeatForceMilliNewtons), spriteId,
      ForceObjectBase + ord(seat) * ArrowDots, ArrowDots, 400 + ord(seat))
    packet.addArrow(handle.x, handle.y,
      sim.strainX[ord(seat)], sim.strainY[ord(seat)],
      max(1'i32, compiled.gripLimit), StrainDotSpriteId,
      StrainObjectBase + ord(seat) * StrainDots, StrainDots, 410 + ord(seat))

proc addScuffs(
  sim: SimServer,
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition]
) =
  ## Damage reads as accumulating scuffs on the couch, keyed to the hull disc
  ## that took it, in 100-point steps.
  const size = ScuffPx * BoardScale
  for stage in 0 .. 3:
    packet.addSpriteOnce(defs, ScuffSpriteBase + stage, size, size,
      scuffPixels(stage, BoardScale), LabelScuff)
  let count = min(sim.scuffs.len, ScuffSlots)
  for slot in 0 ..< ScuffSlots:
    let index = sim.scuffs.len - count + slot
    if slot >= count:
      packet.addDeleteObject(ScuffObjectBase + slot)
      continue
    let
      mark = sim.scuffs[index]
      offset = sim.discOffsetWorld(int(mark.disc))
      normal = sim.bodyNormal()
      jitter = int32((int(mark.tick) mod 7) - 3) * 60_000'i32
      px = sim.posX + offset.x + q12Scale(jitter, normal.x)
      py = sim.posY + offset.y + q12Scale(jitter, normal.y)
      stage = clamp(int(sim.damage) div 250, 0, 3)
    packet.addObject(ScuffObjectBase + slot,
      worldToBoard(px) - size div 2, worldToBoard(py) - size div 2,
      200, MapLayerId, ScuffSpriteBase + stage)

proc addFx(
  sim: SimServer,
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition]
) =
  ## Scrape sparks, drop dust and the doorway glow.
  const
    sparkPx = 6 * BoardScale
    dustPx = 30 * BoardScale
  packet.addSpriteOnce(defs, SparkSpriteId, sparkPx, sparkPx,
    discPixels(sparkPx, rgba(255, 214, 140, 235)), LabelSpark)
  packet.addSpriteOnce(defs, DustSpriteId, dustPx, dustPx,
    discPixels(dustPx, rgba(190, 176, 156, 130)), LabelDust)
  var slot = 0
  for spark in sim.sparks:
    let age = sim.tickCount - int(spark.tick)
    if age < 0 or age >= SparkTicks or slot >= SparkSlots:
      continue
    packet.addObject(SparkObjectBase + slot,
      worldToBoard(spark.x) - sparkPx div 2,
      worldToBoard(spark.y) - sparkPx div 2,
      500, MapLayerId, SparkSpriteId)
    inc slot
  while slot < SparkSlots:
    packet.addDeleteObject(SparkObjectBase + slot)
    inc slot
  var dust = 0
  for drop in sim.dropFx:
    let age = sim.tickCount - int(drop.tick)
    if age < 0 or age >= DustTicks or dust >= DustSlots:
      continue
    let spread = int32(age) * 40_000'i32
    packet.addObject(DustObjectBase + dust,
      worldToBoard(drop.x - spread) - dustPx div 2,
      worldToBoard(drop.y) - dustPx div 2,
      520, MapLayerId, DustSpriteId)
    inc dust
    if dust < DustSlots:
      packet.addObject(DustObjectBase + dust,
        worldToBoard(drop.x + spread) - dustPx div 2,
        worldToBoard(drop.y) - dustPx div 2,
        520, MapLayerId, DustSpriteId)
      inc dust
  while dust < DustSlots:
    packet.addDeleteObject(DustObjectBase + dust)
    inc dust
  # The doorway the couch is heading for glows: the whole joke is the last one,
  # 105 cm against a 90 cm couch.
  const ringPx = 26 * BoardScale
  packet.addSpriteOnce(defs, DoorRingSpriteId, ringPx, ringPx,
    ringPixels(ringPx, rgba(232, 163, 61, 200), float32(2 * BoardScale)),
    LabelDoorGlow)
  var door = 0
  if sim.doorsCleared < int32(sim.course.doorways.len):
    let d = sim.course.doorways[sim.doorsCleared]
    let half = d.width div 2
    let edges =
      if d.vertical: [(d.cx, d.cy - half), (d.cx, d.cy), (d.cx, d.cy + half)]
      else: [(d.cx - half, d.cy), (d.cx, d.cy), (d.cx + half, d.cy)]
    for edge in edges:
      if door >= DoorSlots:
        break
      packet.addObject(DoorObjectBase + door,
        worldToBoard(edge[0]) - ringPx div 2,
        worldToBoard(edge[1]) - ringPx div 2,
        90, MapLayerId, DoorRingSpriteId)
      inc door
  while door < DoorSlots:
    packet.addDeleteObject(DoorObjectBase + door)
    inc door

# --------------------------------------------------------------------------
# The two builders
# --------------------------------------------------------------------------

proc buildBoard(
  sim: SimServer,
  defs: var seq[SpriteDefinition],
  initialized: var bool,
  selfSeat: int
): seq[uint8] =
  if not initialized:
    sim.addBoardChrome(result, defs)
    initialized = true
  sim.addFx(result, defs)
  sim.addCouchAndCogs(result, defs, selfSeat)
  sim.addScuffs(result, defs)
  sim.addArrows(result, defs)

proc buildSpriteProtocolUpdates*(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  tick: int,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int
): seq[uint8] =
  ## The SPECTATOR / replay board. Perfect information: no fog, no vision cone,
  ## no first-person inset — two cogs carrying a couch can see the room.
  nextState = state
  result = buildBoard(sim, nextState.spriteDefs, nextState.initialized, -1)
  discard tick
  discard playing
  discard speed
  discard maxTick
  discard looping
  discard transportEnabled
  discard mismatchTick

proc buildSpriteProtocolPlayerUpdates*(
  sim: var SimServer,
  playerIndex: int,
  state: PlayerViewerState,
  nextState: var PlayerViewerState,
  spritesOff = false
): seq[uint8] =
  ## One seat's stream. It sees the whole warehouse and both cogs — plus a self
  ## marker on its own cog and an invisible `own seat <alias>` marker naming
  ## it. It never sees a real player name, and that is STRUCTURAL rather than a
  ## switch: every board label is built from `seatAlias()` in `labels.nim`, so
  ## there is no code path that could put `player.address` on the board and
  ## nothing for `config.showPlayerLabels` to gate. The flag stays because the
  ## manifest's config_schema declares it and it defaults false;
  ## tests/test_server.nim asserts the guarantee holds with it forced TRUE,
  ## which is the only way to show the mechanism is the vocabulary and not the
  ## flag.
  nextState = state
  if nextState.isNil:
    nextState = initPlayerViewerState()
  let seat =
    if playerIndex >= 0 and playerIndex < sim.players.len:
      ord(sim.players[playerIndex].seat)
    else:
      -1
  result = buildBoard(sim, nextState.spriteDefs, nextState.initialized, seat)
  if seat >= 0:
    result.addSpriteOnce(nextState.spriteDefs, OwnSeatSpriteId, 1, 1,
      @[0'u8, 0, 0, 0], LabelOwnSeat & " " & seatAlias(Seat(seat and 1)))
    result.addObject(OwnSeatObjectId, 0, 0, 999, MapLayerId, OwnSeatSpriteId)
  discard spritesOff
