## The deterministic gameplay core: the rigid-assembly physics, the penalty
## contacts, the damage model, the grip/drop rule, route progress and the
## per-tick step loop. Types, consts, course geometry, config and state
## services live in the sibling modules this file imports and re-exports,
## exactly as ctf's `sim.nim` does.
##
## THE DETERMINISM CONTRACT (docs/RULES.md §Determinism):
##
## * every stored field is an explicit `int32` / `bool` / enum — never a bare
##   `int`, which is 64-bit natively and 32-bit under `--cpu:wasm32`;
## * every product or quotient of two sim quantities is taken in `int64` and
##   narrowed with an explicit truncating `div` (Nim's `div` truncates toward
##   zero, so the arithmetic is symmetric under negation — which is what makes
##   the two handles exactly fair);
## * there is no floating point in this module, and no libm call anywhere: the
##   only trigonometry is the committed `SinQ12` table in `trig.nim`, the only
##   square root is `isqrt`, and the only atan2 is `bradsOfVectorI`.
##
## The recorded action log is the two seats' quantised `Order`s, one per
## decision turn. UNLIKE ctf and cogball the control layer is INSIDE this
## boundary: the viewer re-compiles the same forces from the same orders, and
## the per-tick `gameHash` chain proves it.

import std/random

import sim_types, trig, course, sim_config, sim_state
export sim_types, trig, course, sim_config, sim_state

type
  ForceVec* = tuple[x, y: int32]
  SeatForces* = array[SeatCount, ForceVec]
  GripLimits* = array[SeatCount, int32]

const
  ZeroForces*: SeatForces = [(0'i32, 0'i32), (0'i32, 0'i32)]

# --------------------------------------------------------------------------
# Small integer helpers. Every one of these takes its product in int64.
# --------------------------------------------------------------------------

proc bodyAxis*(sim: SimServer): tuple[x, y: int32] {.inline.} =
  ## The Q12 unit vector along the couch's long axis, fore-positive. Screen
  ## convention: `headingQ` counts counter-clockwise ON SCREEN from +x, and
  ## screen y points down, so the y component is negated.
  (cosQ12i(sim.headingQ), -sinQ12i(sim.headingQ))

proc bodyNormal*(sim: SimServer): tuple[x, y: int32] {.inline.} =
  ## The Q12 unit vector 90 degrees counter-clockwise on screen from the couch
  ## axis — the direction a positive `twist` pushes the FORE handle.
  let q = sim.headingQ + QuarterTurnQ
  (cosQ12i(q), -sinQ12i(q))

proc offsetWorld*(sim: SimServer, localX: int32): tuple[x, y: int32] {.inline.} =
  ## A body-local offset along the couch axis, rotated into world micrometres.
  let axis = sim.bodyAxis()
  (q12Scale(localX, axis.x), q12Scale(localX, axis.y))

proc discOffsetWorld*(sim: SimServer, disc: int): tuple[x, y: int32] {.inline.} =
  sim.offsetWorld(discOffset(disc))

proc discPos*(sim: SimServer, disc: int): tuple[x, y: int32] {.inline.} =
  let offset = sim.discOffsetWorld(disc)
  (sim.posX + offset.x, sim.posY + offset.y)

proc handlePos*(sim: SimServer, seat: Seat): tuple[x, y: int32] {.inline.} =
  sim.discPos(cogDisc(seat))

const RotNum = 25736'i64
const RotDen = 16777216'i64 * int64(SpinFine)
  ## 25736 / 2^24 = 2*PI / 4096, divided again by `SpinFine`: converts (spin,
  ## in 1/256 of a headingQ step per tick) times a radius in micrometres into
  ## micrometres per tick.

proc rotVel*(spin: int32, rx, ry: int32): tuple[x, y: int32] {.inline.} =
  ## omega (counter-clockwise ON SCREEN) crossed with a world offset, in
  ## micrometres per tick. In world components (y down) that is
  ## `(omega * ry, -omega * rx)`.
  let w = int64(spin)
  (int32((w * int64(ry) * RotNum) div RotDen),
   int32(-((w * int64(rx) * RotNum) div RotDen)))

proc pointVel*(sim: SimServer, rx, ry: int32): tuple[x, y: int32] {.inline.} =
  let rot = rotVel(sim.spin, rx, ry)
  (sim.velX + rot.x, sim.velY + rot.y)

proc torqueOf*(rx, ry, fx, fy: int32): int64 {.inline.} =
  ## The counter-clockwise-on-screen z-torque of a force at an offset, in
  ## micrometre-millinewtons. With screen y down that is `ry*fx - rx*fy`.
  int64(ry) * int64(fx) - int64(rx) * int64(fy)

proc umPerTickToMmS*(v: int32): int32 {.inline.} =
  ## micrometres per tick -> millimetres per second (24 ticks a second).
  int32((int64(v) * int64(TargetFps)) div 1000)

# --------------------------------------------------------------------------
# Construction
# --------------------------------------------------------------------------

proc initSimServer*(config: GameConfig): SimServer =
  ## Builds a fresh sim from a resolved config. No sockets, no rendering.
  ## The course is generated here from `config.seed`; `initReplayRuntime`
  ## overwrites it with the course RECORDED in the replay header, so a future
  ## generator change can never desynchronise an old replay.
  result.config = config
  result.rng = initRand(config.seed)
  result.phase = Lobby
  result.endReason = reasonComplete
  result.endRule = erDelivered
  result.gameStartTick = -1
  result.deliveryTick = -1
  result.lastLobbyPlayersLogged = -1
  result.lastLobbyNeededLogged = -1
  result.lastLobbySecondsLogged = -1
  result.lastDropTick = -1
  result.lastDoorTick = -1
  result.lastImpactTick = -1
  result.lastScrapeTick = -1
  result.lastRegripTick = -1
  result.gameEventLoggingEnabled = true
  result.course = generateCourse(int64(config.seed))
  result.courseDigest = result.course.digest
  let pose = result.course.startPose()
  result.posX = pose.x
  result.posY = pose.y
  result.headingQ = ((pose.headingQ mod HeadingQTurn) + HeadingQTurn) mod
    HeadingQTurn
  # Every seat has an order from tick zero, so no failure mode — not even a
  # turn that never ran — can leave a cog unactuated.
  for seat in 0 ..< SeatCount:
    result.activeOrder[seat] = Order(
      turn: -1, source: osScripted, driveX: 4096, driveY: 0,
      effort: 0, yieldQ: 64, twist: 0, brace: 0)

proc adoptCourse*(sim: var SimServer, replacement: Course) =
  ## Installs a recorded course over the generated one (playback only).
  if replacement.routeX.len < 2 or replacement.walls.len == 0:
    return
  sim.course = replacement
  sim.courseDigest = replacement.digest
  let pose = sim.course.startPose()
  sim.posX = pose.x
  sim.posY = pose.y
  sim.headingQ = ((pose.headingQ mod HeadingQTurn) + HeadingQTurn) mod
    HeadingQTurn

proc effectiveMaxTicks*(sim: SimServer): int {.inline.} =
  sim.config.maxTicks

proc turnTicks*(sim: SimServer): int {.inline.} =
  max(1, sim.config.turnTicks)

proc turnCount*(sim: SimServer): int {.inline.} =
  max(1, sim.config.maxTicks div sim.turnTicks())

proc gameTicksElapsed*(sim: SimServer): int {.inline.} =
  if sim.gameStartTick < 0: 0 else: max(0, sim.tickCount - sim.gameStartTick)

proc currentTurn*(sim: SimServer): int {.inline.} =
  sim.gameTicksElapsed() div sim.turnTicks()

proc carrying*(sim: SimServer): bool {.inline.} =
  sim.phase == Carrying or sim.phase == Regrip

proc parTicks*(sim: SimServer): int {.inline.} =
  max(1, int(sim.course.parTicks))

proc conditionPermille*(sim: SimServer): int {.inline.} =
  1000 - clamp(int(sim.damage), 0, 1000)

proc gripLimitOf*(sim: SimServer, seat: Seat): int32 {.inline.} =
  int32(sim.config.gripLimitMilliNewtons) +
    (GripLimitBrace * sim.activeOrder[ord(seat)].brace) div 255

proc strainMagnitude*(sim: SimServer, seat: Seat): int32 {.inline.} =
  distI(sim.strainX[ord(seat)], sim.strainY[ord(seat)])

proc delivered*(sim: SimServer): bool {.inline.} =
  sim.deliveryTick >= 0

# --------------------------------------------------------------------------
# Scoring
# --------------------------------------------------------------------------

proc scoreMicros*(sim: SimServer): int64 =
  ## The joint score, in millionths. Both seats receive this ONE number.
  ##
  ##   delivered      0.30 + 0.35 * speed + 0.35 * condition
  ##   not delivered  0.25 * progress * condition
  ##
  ## `speed = clamp(2 - t/par, 0, 1)`. Computed once, in integers, so the two
  ## copies written into `results.scores` are bit-identical.
  let
    par = int64(sim.parTicks())
    t = int64(if sim.delivered(): sim.deliveryTick else: int32(sim.tickCount))
    condMicros = int64(sim.conditionPermille()) * 1000
  if sim.delivered():
    let speedMicros = clamp(2_000_000'i64 - (t * 1_000_000'i64) div par,
      0'i64, 1_000_000'i64)
    300_000'i64 + (35'i64 * speedMicros) div 100 + (35'i64 * condMicros) div 100
  else:
    let progress = int64(clamp(sim.bestProgressPermille, 0'i32, 1000'i32))
    (((250_000'i64 * progress) div 1000) * condMicros) div 1_000_000

# --------------------------------------------------------------------------
# Endings
# --------------------------------------------------------------------------

proc finishGame*(sim: var SimServer, reason: EndReason, rule: EndRule) =
  ## Ends the episode. Idempotent: the first ending wins, so a wall-clock stop
  ## landing on the same tick as the delivery cannot overwrite the verdict.
  if sim.phase == GameOver:
    return
  sim.endReason = reason
  sim.endRule = rule
  sim.ended = true
  sim.emitPhaseChange(GameOver)
  sim.phase = GameOver
  sim.gameOverTimer = sim.config.gameOverTicks
  sim.logGameEvent("game over: " & reasonText(reason) & "/" &
    endRuleText(rule) & " damage=" & $sim.damage &
    " progress=" & $sim.bestProgressPermille)

proc startGame*(sim: var SimServer) =
  sim.emitPhaseChange(Carrying)
  sim.phase = Carrying
  sim.gameStartTick = sim.tickCount
  sim.logGameEvent("carry start on a " & $sim.course.routeCols.len &
    "-cell route, par " & $sim.course.parTicks & " ticks")

proc wallClockStop*(sim: var SimServer) =
  ## The engine's hard stop. The state at this instant stands, the replay is
  ## complete up to this tick, and the game-over frame is written.
  if sim.carrying() or sim.phase == Delivered:
    sim.finishGame(reasonDeadline, erWallClock)

proc hostErrorStop*(sim: var SimServer) =
  if sim.phase != GameOver:
    sim.finishGame(reasonFault, erHostError)

# --------------------------------------------------------------------------
# Contacts
# --------------------------------------------------------------------------

type
  ContactAccum = object
    fx, fy: int64
    torque: int64

proc closestOnRect(
  px, py: int32,
  rect: WallRect
): tuple[nx, ny, depth: int32, hit: bool] =
  ## The outward normal (Q12) and penetration of a disc CENTRE against an
  ## axis-aligned rectangle. `depth` is measured against the disc radius by the
  ## caller; here `depth` is the distance from the centre to the surface, as a
  ## NEGATIVE number when the centre is inside the rectangle.
  let
    cx = clamp(px, rect.x0, rect.x1)
    cy = clamp(py, rect.y0, rect.y1)
  if cx != px or cy != py:
    let u = unitQ12(px - cx, py - cy)
    return (u.x, u.y, u.d, true)
  # The centre is inside: push out along the nearest face. The ring rects
  # overhang the world box, so for them the nearest face is always the
  # interior one.
  var
    best = px - rect.x0
    nx = -4096'i32
    ny = 0'i32
  if rect.x1 - px < best:
    best = rect.x1 - px
    nx = 4096
    ny = 0
  if py - rect.y0 < best:
    best = py - rect.y0
    nx = 0
    ny = -4096
  if rect.y1 - py < best:
    best = rect.y1 - py
    nx = 0
    ny = 4096
  (nx, ny, -best, true)

proc accumulateContacts(sim: var SimServer, accum: var ContactAccum) =
  ## Step 4.1: every disc, in index order, against every rect its broadphase
  ## bucket holds. Contacts PUSH, never stick, and the friction term is capped
  ## viscously so it cannot reverse the slide inside one substep.
  for disc in 0 ..< DiscCount:
    let
      offset = sim.discOffsetWorld(disc)
      px = sim.posX + offset.x
      py = sim.posY + offset.y
      radius = discRadius(disc)
    for index in sim.course.nearbyWalls(px, py):
      let probe = closestOnRect(px, py, sim.course.walls[index])
      let depth = radius - probe.depth
      if depth <= 0:
        continue
      let
        contact = sim.pointVel(offset.x, offset.y)
        vn = int32((int64(contact.x) * int64(probe.nx) +
          int64(contact.y) * int64(probe.ny)) div 4096)
        vtx = contact.x - q12Scale(vn, probe.nx)
        vty = contact.y - q12Scale(vn, probe.ny)
      var normal = int64(ContactStiffness) * int64(depth)
      if vn < 0:
        normal += int64(ContactDamping) * int64(-vn)
      if normal < 0:
        normal = 0
      if normal > int64(ContactForceCap):
        normal = int64(ContactForceCap)
      let
        slide = unitQ12(vtx, vty)
        coulomb = (normal * int64(FrictionNum)) div int64(FrictionDen)
        viscous = int64(slide.d) * int64(FrictionViscous)
        friction = if coulomb < viscous: coulomb else: viscous
        fx = q12Scale(int32(normal), probe.nx) -
          int32((friction * int64(slide.x)) div 4096)
        fy = q12Scale(int32(normal), probe.ny) -
          int32((friction * int64(slide.y)) div 4096)
      accum.fx += int64(fx)
      accum.fy += int64(fy)
      accum.torque += torqueOf(offset.x, offset.y, fx, fy)
      sim.contacts.add Contact(
        disc: int32(disc), x: px, y: py,
        approachMmS: umPerTickToMmS(max(0'i32, -vn)),
        slideMmS: umPerTickToMmS(slide.d),
        depthUm: depth,
        slideUmPerTick: slide.d,
        normalMilliNewtons: int32(normal),
        frictionMilliNewtons: int32(friction))

proc runSubstep(sim: var SimServer, forces: SeatForces, strain: var array[
    SeatCount, tuple[x, y: int64]]) =
  ## One 1/96 s substep: contacts, the sum of forces, semi-implicit Euler, the
  ## pose update, and the felt strain at each handle.
  var before: array[SeatCount, tuple[x, y: int32]]
  for seat in 0 ..< SeatCount:
    let offset = sim.offsetWorld(CogOffsets[seat])
    before[seat] = sim.pointVel(offset.x, offset.y)

  var accum = ContactAccum()
  sim.accumulateContacts(accum)

  # 4.2 — the sum of forces, the rule the idea names.
  var
    fx = accum.fx
    fy = accum.fy
    torque = accum.torque
  for seat in 0 ..< SeatCount:
    let offset = sim.offsetWorld(CogOffsets[seat])
    fx += int64(forces[seat].x)
    fy += int64(forces[seat].y)
    torque += torqueOf(offset.x, offset.y, forces[seat].x, forces[seat].y)

  # 4.3 — velocity (semi-implicit Euler) with linear and angular drag.
  let
    dvx = int32((fx * 1_000_000'i64) div MassStepDen)
    dvy = int32((fy * 1_000_000'i64) div MassStepDen)
  sim.velX += dvx
  sim.velY += dvy
  sim.velX -= int32((int64(sim.velX) * int64(LinearDragNum)) div
    int64(DragDen))
  sim.velY -= int32((int64(sim.velY) * int64(LinearDragNum)) div
    int64(DragDen))
  let torqueMilliNm = torque div 1_000_000'i64
  sim.spin += int32((torqueMilliNm * SpinStepNum * int64(SpinFine)) div
    (int64(InertiaMilliKgM2) * SpinStepDen))
  sim.spin -= int32((int64(sim.spin) * int64(AngularDragNum)) div
    int64(DragDen))
  capVector(sim.velX, sim.velY, MaxSpeedUm)
  sim.spin = clamp(sim.spin, -MaxSpinQ, MaxSpinQ)

  # 4.4 — pose. The heading carries a REMAINDER across substeps: `spin` is in
  # 1/16-brad per TICK and a substep is a quarter of one, so a plain
  # `spin div Substeps` truncates every spin under 4 to zero and the couch
  # simply cannot turn slowly. That dead zone froze four of twenty scripted
  # runs solid on the first corner.
  sim.posX += sim.velX div Substeps
  sim.posY += sim.velY div Substeps
  sim.spinRem += sim.spin
  let turn = sim.spinRem div (Substeps * SpinFine)
  sim.spinRem -= turn * Substeps * SpinFine
  sim.headingQ = (sim.headingQ + turn + HeadingQTurn) mod HeadingQTurn

  # 4.5 — felt strain. `H_i = m_cog * a_i - F_i` is the force the cog's hand
  # is carrying, and it contains the partner's force by construction because
  # `a_i` depends on `F0 + F1`. This is the ENTIRE coordination channel.
  for seat in 0 ..< SeatCount:
    let
      offset = sim.offsetWorld(CogOffsets[seat])
      after = sim.pointVel(offset.x, offset.y)
      ax = int64(after.x - before[seat].x) * 96
      ay = int64(after.y - before[seat].y) * 96
    strain[seat].x += (int64(CogMassGrams) * ax * int64(TargetFps)) div
      1_000_000'i64 - int64(forces[seat].x)
    strain[seat].y += (int64(CogMassGrams) * ay * int64(TargetFps)) div
      1_000_000'i64 - int64(forces[seat].y)

# --------------------------------------------------------------------------
# Damage, grip and progress
# --------------------------------------------------------------------------

proc blameSeat(disc: int): Seat {.inline.} =
  ## The seat whose handle is nearer the damaging disc. A spectator meter
  ## only; it is not in the score.
  if discOffset(disc) >= 0: Cobalt else: Rust

proc applyDamage(sim: var SimServer) =
  ## Step 5, once per tick, over the tick's contact log in disc index order.
  ## Cog discs damage nothing: bruised cogs, unscuffed couch.
  var
    seen: array[DiscCount, bool]
    peakApproach: array[DiscCount, int32]
    peakSlide: array[DiscCount, int32]
    where: array[DiscCount, tuple[x, y: int32]]
  for contact in sim.contacts:
    let disc = int(contact.disc)
    seen[disc] = true
    if contact.approachMmS > peakApproach[disc]:
      peakApproach[disc] = contact.approachMmS
    if contact.slideMmS > peakSlide[disc]:
      peakSlide[disc] = contact.slideMmS
    where[disc] = (contact.x, contact.y)
  sim.touching.setLen(0)
  var anyContact = false
  for disc in 0 ..< DiscCount:
    if seen[disc]:
      anyContact = true
      sim.touching.add(discName(disc))
  if anyContact:
    inc sim.contactTicks

  var added = 0'i32
  for disc in 0 ..< HullDiscs:
    if not seen[disc]:
      continue
    var damage = 0'i32
    if not sim.contactLast[disc] and
        peakApproach[disc] > ImpactSpeedFloorMmS:
      damage = clamp(
        ((peakApproach[disc] - ImpactSpeedFloorMmS) * ImpactDamageNum) div 1000,
        0'i32, ImpactDamageMax)
      if damage >= ImpactEventFloor:
        inc sim.impacts
        sim.lastImpactTick = int32(sim.tickCount)
        sim.sparks.add SparkFx(x: where[disc].x, y: where[disc].y,
          tick: int32(sim.tickCount), strength: peakApproach[disc])
        sim.emitEvent(Impact, source = disc, seat = ord(blameSeat(disc)),
          amount = int(damage), x = where[disc].x, y = where[disc].y,
          speed = peakApproach[disc])
        sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "impact",
          seat: int32(ord(blameSeat(disc))),
          text: "IMPACT - " & discName(disc) & ", -" & $damage & " condition")
    elif sim.contactLast[disc] and peakSlide[disc] > ScrapeSlideFloorMmS:
      damage = clamp(peakSlide[disc] div ScrapeDamageDen, 1'i32,
        ScrapeDamageMax)
      inc sim.scrapeTicks
      if sim.scrapeThrottle[disc] <= 0:
        sim.scrapeThrottle[disc] = ScrapeThrottleTicks
        sim.lastScrapeTick = int32(sim.tickCount)
        sim.sparks.add SparkFx(x: where[disc].x, y: where[disc].y,
          tick: int32(sim.tickCount), strength: peakSlide[disc])
        sim.emitEvent(Scrape, source = disc, seat = ord(blameSeat(disc)),
          amount = int(damage), x = where[disc].x, y = where[disc].y,
          speed = peakSlide[disc])
        sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "scrape",
          seat: int32(ord(blameSeat(disc))),
          text: "SCRAPE - " & discName(disc) & ", -" & $damage & " condition")
    if damage > 0:
      added += damage
      sim.stats[blameSeat(disc)].blame += damage
      sim.scuffs.add ScuffMark(disc: int32(disc), tick: int32(sim.tickCount))
  if added > 0:
    sim.damage = min(int32(sim.config.damageCap), sim.damage + added)
  for disc in 0 ..< DiscCount:
    sim.contactLast[disc] = seen[disc]
    if sim.scrapeThrottle[disc] > 0:
      dec sim.scrapeThrottle[disc]
  while sim.scuffs.len > 64:
    sim.scuffs.delete(0)
  while sim.sparks.len > 48:
    sim.sparks.delete(0)

proc dropCouch(sim: var SimServer, seat: Seat) =
  ## Step 6: either seat's slip drops the couch — it takes two to hold it.
  let speed = speedOf(sim.velX, sim.velY)
  sim.emitEvent(Drop, seat = ord(seat), amount = int(sim.strainMagnitude(seat)),
    x = sim.posX, y = sim.posY, speed = speed)
  sim.damage = min(int32(sim.config.damageCap), sim.damage + DropDamageBase +
    clamp(umPerTickToMmS(speed) div DropDamageSpeedDen, 0'i32,
      DropDamageSpeedMax))
  sim.velX = 0
  sim.velY = 0
  sim.spin = 0
  sim.emitPhaseChange(Regrip)
  sim.phase = Regrip
  sim.regripUntil = int32(sim.tickCount) + int32(max(1, sim.config.regripTicks))
  for i in 0 ..< SeatCount:
    sim.slip[i] = 0
    sim.strainX[i] = 0
    sim.strainY[i] = 0
  inc sim.drops
  sim.lastDropTick = int32(sim.tickCount)
  sim.dropFx.add DropFx(x: sim.posX, y: sim.posY, tick: int32(sim.tickCount),
    seat: int32(ord(seat)))
  sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "drop",
    seat: int32(ord(seat)),
    text: "DROP - " & seatAlias(seat) & "'s grip went at " &
      $(sim.strainMagnitude(seat) div 1000) & " N")
  sim.logGameEvent("drop by " & seatAlias(seat) & " at tick " & $sim.tickCount)

proc applyGrip(sim: var SimServer) =
  for seat in Seat:
    let
      index = ord(seat)
      strain = sim.strainMagnitude(seat)
      limit = sim.gripLimitOf(seat)
      excess = max(0'i32, (strain - limit) div SlipExcessDen)
    if strain > sim.stats[seat].strainPeak:
      sim.stats[seat].strainPeak = strain
    sim.stats[seat].forceIntegral += int64(strain)
    if int64(strain) * 100 >= int64(limit) * int64(StrainWarnPct) and
        sim.tickCount mod 12 == 0:
      sim.emitEvent(StrainWarn, seat = index, amount = int(strain))
    sim.slip[index] = max(0'i32,
      sim.slip[index] + excess - SlipRecoverPerTick)
    if sim.slip[index] >= SlipDropThreshold:
      sim.dropCouch(seat)
      return

proc pastDoorway(sim: SimServer, door: Doorway): bool =
  ## True when ALL FIVE hull-disc centres are past a doorway plane.
  for disc in 0 ..< HullDiscs:
    let p = sim.discPos(disc)
    if door.vertical:
      let side = int64(p.x - door.cx) * int64(door.throughX)
      if side <= 0:
        return false
    else:
      let side = int64(p.y - door.cy) * int64(door.throughY)
      if side <= 0:
        return false
  true

proc allHullInGoal(sim: SimServer): bool =
  for disc in 0 ..< HullDiscs:
    let p = sim.discPos(disc)
    if not sim.course.inGoalPad(p.x, p.y):
      return false
  true

proc applyProgress(sim: var SimServer) =
  ## Step 7: route progress, doorway beats and delivery.
  let arc = sim.course.arcAlongRoute(sim.posX, sim.posY)
  let permille = int32(clamp((1000'i64 * arc) div int64(sim.course.routeLen),
    0'i64, 1000'i64))
  if permille > sim.bestProgressPermille:
    sim.bestProgressPermille = permille
  while sim.doorsCleared < int32(sim.course.doorways.len) and
      sim.pastDoorway(sim.course.doorways[sim.doorsCleared]):
    let door = sim.course.doorways[sim.doorsCleared]
    inc sim.doorsCleared
    sim.lastDoorTick = int32(sim.tickCount)
    sim.emitEvent(DoorwayEvent, amount = int(sim.doorsCleared),
      x = door.cx, y = door.cy, speed = door.width)
    sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "doorway", seat: -1,
      text: "DOORWAY " & $sim.doorsCleared & " CLEARED - " &
        $(door.width div 10_000) & " cm")
  if not sim.delivered() and sim.allHullInGoal():
    sim.deliveryTick = int32(sim.tickCount)
    sim.bestProgressPermille = 1000
    sim.emitPhaseChange(Delivered)
    sim.phase = Delivered
    sim.emitEvent(DeliveredEvent, amount = int(sim.deliveryTick),
      x = sim.posX, y = sim.posY)
    sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "delivered",
      seat: -1,
      text: "DELIVERED in " & $(int(sim.deliveryTick) div TargetFps) & " s")

proc physicsGuardTripped(sim: SimServer): bool =
  ## Step 10's invariant guard: a disc outside the world box, a velocity or
  ## spin above the clamp, negative damage, or a heading outside 0..4095.
  if sim.damage < 0:
    return true
  if sim.headingQ < 0 or sim.headingQ >= HeadingQTurn:
    return true
  if speedOf(sim.velX, sim.velY) > MaxSpeedUm + 1:
    return true
  if sim.spin > MaxSpinQ or sim.spin < -MaxSpinQ:
    return true
  for disc in 0 ..< DiscCount:
    let p = sim.discPos(disc)
    if p.x < 0 or p.y < 0 or p.x > WorldW or p.y > WorldH:
      return true
  false

# --------------------------------------------------------------------------
# The step loop
# --------------------------------------------------------------------------

proc installOrder*(sim: var SimServer, seat: Seat, order: Order) =
  ## The ONE path an order takes into the hashed state. Both the live server
  ## and the replay reach it through the `order` chat record, so the two
  ## install bit-identical integers.
  sim.activeOrder[ord(seat)] = order
  sim.hasOrder[ord(seat)] = true

proc stepCarrying(sim: var SimServer, forces: SeatForces) =
  sim.contacts.setLen(0)
  var strain: array[SeatCount, tuple[x, y: int64]]

  if sim.phase == Regrip and int32(sim.tickCount) < sim.regripUntil:
    # Step 2: the regrip gate. The couch is on the floor; steps 3-6 are
    # skipped, steps 7-10 still run.
    sim.velX = 0
    sim.velY = 0
    sim.spin = 0
  else:
    if sim.phase == Regrip:
      sim.emitPhaseChange(Carrying)
      sim.phase = Carrying
      for i in 0 ..< SeatCount:
        sim.slip[i] = 0
        sim.strainX[i] = 0
        sim.strainY[i] = 0
      sim.lastRegripTick = int32(sim.tickCount)
      sim.emitEvent(RegripEvent, x = sim.posX, y = sim.posY)
      sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "regrip",
        seat: -1, text: "Both cogs re-grip the couch")
    for _ in 0 ..< Substeps:
      sim.runSubstep(forces, strain)
    for seat in 0 ..< SeatCount:
      sim.strainX[seat] = int32(strain[seat].x div Substeps)
      sim.strainY[seat] = int32(strain[seat].y div Substeps)
    sim.applyDamage()
    sim.applyGrip()

  sim.applyProgress()

  for seat in Seat:
    let order = sim.activeOrder[ord(seat)]
    if order.yieldQ > order.effort:
      inc sim.stats[seat].yieldTicks

  # Step 10 — the end checks, in this order.
  if sim.phase == Delivered:
    sim.finishGame(reasonComplete, erDelivered)
    return
  if sim.damage >= int32(sim.config.damageCap):
    sim.emitEvent(Wrecked, x = sim.posX, y = sim.posY)
    sim.finishGame(reasonComplete, erWrecked)
    return
  # `out_of_time` BEFORE the invariant guard, which is the note's order
  # (Delivered -> wrecked -> wall_clock -> out_of_time -> fault). The wall-clock
  # stop is checked in the server loop before the tick (EDIT 4), so on the one
  # tick where a run would end `complete/out_of_time` AND a guard trips, the
  # legible ending wins instead of `fault/sim_fault` — a `fault` is the flag the
  # league discards the episode on, so a tie must not manufacture one.
  if sim.tickCount + 1 - sim.gameStartTick >= sim.config.maxTicks:
    sim.finishGame(reasonComplete, erOutOfTime)
    return
  if sim.physicsGuardTripped():
    sim.finishGame(reasonFault, erSimFault)

proc step*(sim: var SimServer, forces: SeatForces) =
  ## Advances the sim by one tick. `forces` are the two seats' compiled force
  ## vectors, in millinewtons, produced by `control.seatForce` from the state
  ## at the START of this tick — the control layer is inside the determinism
  ## boundary, so the viewer computes the identical pair.
  case sim.phase
  of Lobby:
    if sim.players.len < sim.config.minPlayers:
      inc sim.lobbyWaitTimer
      sim.startWaitTimer = 0
      sim.logLobbyWaiting()
    else:
      sim.logLobbyWaiting()
      if sim.startWaitTimer <= 0:
        sim.startWaitTimer = max(1, sim.config.startWaitTicks)
      sim.logLobbyCountdown()
      dec sim.startWaitTimer
      if sim.startWaitTimer <= 0:
        sim.startGame()
  of Carrying, Regrip:
    sim.stepCarrying(forces)
  of Delivered:
    sim.finishGame(reasonComplete, erDelivered)
  of GameOver:
    if sim.gameOverTimer > 0:
      dec sim.gameOverTimer
  inc sim.tickCount
  while sim.feed.len > 64:
    sim.feed.delete(0)
  while sim.dropFx.len > 8:
    sim.dropFx.delete(0)
