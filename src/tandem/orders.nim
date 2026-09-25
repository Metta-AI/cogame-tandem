## Orders: the six-field carry object a seat plays for one 48-tick decision
## turn, its tolerant parser/repairer, its quantisation, its replay record, and
## the view-coordinate transform every policy sees the world through.
##
## Two hard rules live here and are pinned by tests/test_orders.nim:
##
## 1. **Every recorded string is truncated on RUNE boundaries, never bytes.**
##    A byte-truncated multi-byte character is exactly the bug that makes
##    replay bytes render in a browser but fail a strict parser.
## 2. **Parsing is tolerant and never fails hard.** Markdown fences, prose
##    prefixes, numeric strings, `drive` as an object, integer percentages,
##    NaN, absent and out-of-range fields — all repair. Only when no object
##    with at least one usable field can be recovered do the retry and then the
##    scripted fallback fire.
##
## Floats are legal here: this module is OUTSIDE the float-free grep guard,
## because the quantised integers it produces — and only those — are what the
## sim hashes. The `q` array in the replay record carries exactly those
## integers so playback re-installs them bit for bit.

import
  std/[json, math, strutils, unicode],
  sim

# --------------------------------------------------------------------------
# View coordinates: metres from the world centre, y UP. The ONLY coordinates a
# policy ever sees or sends.
# --------------------------------------------------------------------------

const
  ViewHalfW* = 22.2
  ViewHalfH* = 12.6

proc viewX*(x: int32): float {.inline.} =
  float(int(x) - int(WorldW div 2)) / 1_000_000.0

proc viewY*(y: int32): float {.inline.} =
  float(int(WorldH div 2) - int(y)) / 1_000_000.0

proc viewLen*(v: int32): float {.inline.} =
  float(v) / 1_000_000.0

proc viewSpeed*(v: int32): float {.inline.} =
  ## micrometres per tick -> metres per second.
  float(v) * float(TargetFps) / 1_000_000.0

proc round2*(value: float): float {.inline.} =
  ## Two decimals, the precision every number in the seat view carries.
  round(value * 100.0) / 100.0

proc round6*(value: float): float {.inline.} =
  round(value * 1_000_000.0) / 1_000_000.0

proc degOfQ*(headingQ: int32): float {.inline.} =
  ## A headingQ angle as degrees counter-clockwise from +X, rounded to 1.
  round(float(((headingQ mod HeadingQTurn) + HeadingQTurn) mod HeadingQTurn) *
    360.0 / 4096.0)

proc degOfVectorView*(dx, dy: int32): float {.inline.} =
  ## The bearing of a WORLD vector, reported to policies as degrees ccw from
  ## +X in view coordinates.
  round(float(bradsOfVectorI(dx, dy)) * 360.0 / 256.0)

proc spinDegPerSecond*(spin: int32): float {.inline.} =
  round(float(spin) / float(SpinFine) * 360.0 / 4096.0 * float(TargetFps) *
    10.0) / 10.0

# --------------------------------------------------------------------------
# Rune-boundary truncation
# --------------------------------------------------------------------------

proc clipRunes*(text: string, maxRunes: int): string =
  ## Truncates on a RUNE boundary (babel's `cleanNotes`, ported). Slicing a
  ## `string` by byte index on any path to the replay is forbidden.
  result = text.strip()
  var clean = newStringOfCap(result.len)
  for rune in result.runes:
    # Control characters would corrupt a replay chat record and a JSON line.
    if int32(rune) >= 32 or int32(rune) == 9:
      clean.add($rune)
  result = clean
  if maxRunes <= 0:
    return ""
  if result.runeLen <= maxRunes:
    return
  result = result.runeSubStr(0, maxRunes - 1) & "\u2026"

# --------------------------------------------------------------------------
# Quantisation
# --------------------------------------------------------------------------

proc quantUnit*(x, y: float): tuple[x, y: int32] =
  ## A finite pair clamped to [-1, 1] and quantised to a Q12 unit vector in
  ## VIEW coordinates. A zero vector stays zero, which the caller repairs.
  let
    cx = clamp(x, -1.0, 1.0)
    cy = clamp(y, -1.0, 1.0)
    ix = int32(round(cx * 4096.0))
    iy = int32(round(cy * 4096.0))
  if ix == 0 and iy == 0:
    return (0'i32, 0'i32)
  let u = unitQ12(ix, iy)
  (u.x, u.y)

proc quantUnitFromWorld*(dx, dy: int32): tuple[x, y: int32] =
  ## A WORLD delta as a VIEW-frame Q12 unit vector (the y axis flips).
  if dx == 0 and dy == 0:
    return (0'i32, 0'i32)
  let u = unitQ12(dx, -dy)
  (u.x, u.y)

proc quantUnsigned*(value: float): int32 {.inline.} =
  int32(clamp(round(clamp(value, 0.0, 1.0) * 255.0), 0.0, 255.0))

proc quantSigned*(value: float): int32 {.inline.} =
  int32(clamp(round(clamp(value, -1.0, 1.0) * 255.0), -255.0, 255.0))

proc unitFloat(value: int32): float {.inline.} =
  round2(float(value) / 255.0)

# --------------------------------------------------------------------------
# Construction and serialization
# --------------------------------------------------------------------------

proc emptyOrder*(): Order =
  Order(turn: -1, source: osScripted, driveX: 4096, driveY: 0,
    effort: 0, yieldQ: 64, twist: 0, brace: 0)

proc orderReplyJson*(order: Order): JsonNode =
  ## The complete player reply represented by one quantised game order.
  %*{
    "note": order.note,
    "drive": [float(order.driveX) / 4096.0,
              float(order.driveY) / 4096.0],
    "effort": float(order.effort) / 255.0,
    "yield": float(order.yieldQ) / 255.0,
    "twist": float(order.twist) / 255.0,
    "brace": float(order.brace) / 255.0,
    "say": order.say
  }

proc orderJson*(sim: SimServer, seat: Seat, order: Order): JsonNode =
  ## The `order` replay chat record — the action log. `q` carries the EXACT
  ## quantised integers the sim hashed, so playback re-installs them bit for
  ## bit; the float fields beside it are for the feed, `replay_summary.py` and
  ## human eyes.
  discard sim
  %*{
    "k": "order",
    "turn": order.turn,
    "seat": ord(seat),
    "alias": seatAlias(seat),
    "source": sourceText(order.source),
    "latency_ms": order.latencyMs,
    "note": order.note,
    "drive": [round2(float(order.driveX) / 4096.0),
              round2(float(order.driveY) / 4096.0)],
    "effort": unitFloat(order.effort),
    "yield": unitFloat(order.yieldQ),
    "twist": round2(float(order.twist) / 255.0),
    "brace": unitFloat(order.brace),
    "say": order.say,
    "q": [order.driveX, order.driveY, order.effort, order.yieldQ,
          order.twist, order.brace]
  }

proc orderFromRecord*(node: JsonNode): tuple[order: Order, ok: bool] =
  ## The inverse of `orderJson`, reading ONLY the exact `q` integers. This is
  ## the single path an order takes back into hashed state at playback.
  let q = node{"q"}
  if q.isNil or q.kind != JArray or q.len < 6:
    return
  for item in q:
    if item.kind != JInt:
      return
  var order = emptyOrder()
  order.turn = int32(node{"turn"}.getInt(-1))
  order.driveX = clamp(int32(q[0].getInt()), -4096'i32, 4096'i32)
  order.driveY = clamp(int32(q[1].getInt()), -4096'i32, 4096'i32)
  order.effort = clamp(int32(q[2].getInt()), 0'i32, 255'i32)
  order.yieldQ = clamp(int32(q[3].getInt()), 0'i32, 255'i32)
  order.twist = clamp(int32(q[4].getInt()), -255'i32, 255'i32)
  order.brace = clamp(int32(q[5].getInt()), 0'i32, 255'i32)
  order.note = node{"note"}.getStr()
  order.say = node{"say"}.getStr()
  order.source =
    case node{"source"}.getStr()
    of "llm": osLlm
    of "fallback": osFallback
    of "external": osExternal
    else: osScripted
  (order, true)

proc clipJsonStrings(node: JsonNode, budget: int): JsonNode =
  ## A copy of `node` with every STRING VALUE clipped to `budget` runes. Keys
  ## are untouched, so the shape a reader matches on survives.
  case node.kind
  of JString:
    result = %clipRunes(node.getStr(), budget)
  of JArray:
    result = newJArray()
    for item in node:
      result.add(clipJsonStrings(item, budget))
  of JObject:
    result = newJObject()
    for key, value in node:
      result[key] = clipJsonStrings(value, budget)
  else:
    result = node

proc capRecord*(text: string): string =
  ## Every replay chat record is capped at MaxOrderRecordRunes runes, on a rune
  ## boundary.
  ##
  ## The cap is on the SERIALIZED record, and JSON escaping is what makes that
  ## non-obvious: a `"` or a `\` inside a note or a say costs two runes on the
  ## wire. Blindly clipping the serialized text at 900 would cut the object
  ## mid-key — still valid UTF-8 on a rune boundary, but no longer JSON —
  ## and `broadcast.applyRecord` would then silently drop the order, which is
  ## exactly what phase 60 counts. So an over-long record is shrunk
  ## STRUCTURALLY: parse it, clip its string values to a halving budget until
  ## the serialization fits, and only fall back to the blind rune clip when the
  ## text is not a JSON object at all. A record already inside the cap is
  ## returned byte for byte.
  if text.runeLen <= MaxOrderRecordRunes:
    return clipRunes(text, MaxOrderRecordRunes)
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return clipRunes(text, MaxOrderRecordRunes)
  if node.kind != JObject:
    return clipRunes(text, MaxOrderRecordRunes)
  var budget = MaxNoteRunes
  while budget > 0:
    budget = budget div 2
    let shrunk = $clipJsonStrings(node, budget)
    if shrunk.runeLen <= MaxOrderRecordRunes:
      return shrunk
  clipRunes(text, MaxOrderRecordRunes)

# --------------------------------------------------------------------------
# The tolerant parser
# --------------------------------------------------------------------------

proc numberOf(node: JsonNode, ok: var bool): float =
  ## Accepts a JSON number OR a numeric string; anything else, or a non-finite
  ## value, reports `ok = false`.
  ok = false
  if node.isNil:
    return 0.0
  case node.kind
  of JInt:
    ok = true
    return float(node.getInt())
  of JFloat:
    let value = node.getFloat()
    if value != value or value == Inf or value == NegInf:
      return 0.0
    ok = true
    return value
  of JString:
    var text = node.getStr().strip()
    if text.endsWith("%"):
      text = text[0 ..< text.high]
    try:
      let value = parseFloat(text.strip())
      if value != value or value == Inf or value == NegInf:
        return 0.0
      ok = true
      return value
    except ValueError:
      return 0.0
  else:
    return 0.0

proc unitNumber(node: JsonNode, ok: var bool): float =
  ## A 0..1 field. An integer percentage (`45`) is divided by 100 when the
  ## value exceeds 1, which is the single most common model mistake.
  result = numberOf(node, ok)
  if ok and (result > 1.0 or result < -1.0):
    result = result / 100.0

proc parseOrder*(
  payload: JsonNode,
  previous: Order,
  hasPrevious: bool,
  fallback: Order,
  turn: int
): tuple[order: Order, usable: bool] =
  ## Repairs one reply into a legal, quantised order. `usable` is false when no
  ## field at all could be recovered — the only case that triggers the retry.
  var order = fallback
  order.turn = int32(turn)
  order.source = osLlm
  order.note = clipRunes(payload{"note"}.getStr(), MaxNoteRunes)
  order.say = clipRunes(payload{"say"}.getStr(), MaxSayRunes)
  var usable = order.note.len > 0 or order.say.len > 0

  # drive: two finite numbers, or {"x": .., "y": ..}.
  var
    okX = false
    okY = false
    dx = 0.0
    dy = 0.0
  let drive = payload{"drive"}
  if not drive.isNil and drive.kind == JArray and drive.len >= 2:
    dx = numberOf(drive[0], okX)
    dy = numberOf(drive[1], okY)
  elif not drive.isNil and drive.kind == JObject:
    dx = numberOf(drive{"x"}, okX)
    dy = numberOf(drive{"y"}, okY)
  if okX and okY:
    let quantised = quantUnit(dx, dy)
    if quantised.x != 0 or quantised.y != 0:
      order.driveX = quantised.x
      order.driveY = quantised.y
      usable = true
    elif hasPrevious:
      order.driveX = previous.driveX
      order.driveY = previous.driveY
  elif hasPrevious:
    # Missing or non-finite `drive`: LAST TURN'S drive, and only then the
    # scripted fallback's (which `order` already carries, being a copy of it).
    # Guarding this on a zero fallback inverted the note's precedence, because
    # the porter fallback always emits a non-zero drive.
    order.driveX = previous.driveX
    order.driveY = previous.driveY

  var ok = false
  let effort = unitNumber(payload{"effort"}, ok)
  order.effort = if ok: quantUnsigned(effort) else: 128'i32
  if ok: usable = true

  ok = false
  let yielded = unitNumber(payload{"yield"}, ok)
  order.yieldQ = if ok: quantUnsigned(yielded) else: 64'i32
  if ok: usable = true

  ok = false
  let twist = unitNumber(payload{"twist"}, ok)
  order.twist = if ok: quantSigned(twist) else: 0'i32
  if ok: usable = true

  ok = false
  let brace = unitNumber(payload{"brace"}, ok)
  order.brace = if ok: quantUnsigned(brace) else: 0'i32
  if ok: usable = true

  (order, usable)
