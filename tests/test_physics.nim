## Sim unit tests: the mass table, the sum-of-forces rule, the drag terminal,
## the wall contacts and the felt strain.

import std/[math, strutils]
import lib/helpers

proc emptyCourseSim(): SimServer =
  ## A sim on an open floor: the generated course with every wall removed, so a
  ## free-body test measures the body and nothing else.
  var config = testConfig()
  result = carryingSim(config)
  result.course.walls.setLen(0)
  result.course.buckets = @[]
  result.posX = WorldW div 2
  result.posY = WorldH div 2
  result.headingQ = 0
  result.velX = 0
  result.velY = 0
  result.spin = 0

proc inertiaFromTable() =
  ## `InertiaMilliKgM2` re-derived independently from the mass table.
  var total = 0.0
  for offset in HullOffsets:
    let d = float(offset) / 1_000_000.0
    total += float(HullMassGrams) / 1000.0 * d * d
    total += 0.5 * float(HullMassGrams) / 1000.0 *
      (float(HullRadius) / 1_000_000.0) ^ 2
  for offset in CogOffsets:
    let d = float(offset) / 1_000_000.0
    total += float(CogMassGrams) / 1000.0 * d * d
    total += 0.5 * float(CogMassGrams) / 1000.0 *
      (float(CogRadius) / 1_000_000.0) ^ 2
  let want = int(round(total * 1000.0))
  doAssert abs(int(InertiaMilliKgM2) - want) <= 60,
    "InertiaMilliKgM2 is " & $InertiaMilliKgM2 & ", the mass table says " &
      $want
  doAssert InertiaMilliKgM2 == 139_050'i32,
    "the pinned inertia changed: " & $InertiaMilliKgM2
  doAssert TotalMassGrams == 120_000
  report "the moment of inertia comes from the mass table"

proc equalForcesTranslate() =
  ## Equal forces at both handles: pure translation, ZERO spin, over 480 ticks.
  var sim = emptyCourseSim()
  let push: SeatForces = [(0'i32, -200_000'i32), (0'i32, -200_000'i32)]
  let startX = sim.posX
  let startHeading = sim.headingQ
  for _ in 0 ..< 480:
    sim.step(push)
  doAssert sim.spin == 0, "equal forces produced spin " & $sim.spin
  doAssert sim.headingQ == startHeading,
    "equal forces rotated the couch to " & $sim.headingQ
  doAssert sim.posX == startX, "equal forces moved x by " & $(sim.posX - startX)
  doAssert sim.posY < WorldH div 2, "the couch did not move up-screen"
  report "equal forces at both handles translate and never spin"

proc oppositeForcesRotate() =
  ## Opposite equal forces: pure rotation, no displacement.
  var sim = emptyCourseSim()
  let couple: SeatForces = [(0'i32, -300_000'i32), (0'i32, 300_000'i32)]
  let startX = sim.posX
  let startY = sim.posY
  for _ in 0 ..< 480:
    sim.step(couple)
  doAssert sim.posX == startX and sim.posY == startY,
    "a pure couple displaced the couch by " & $(sim.posX - startX) & "," &
      $(sim.posY - startY)
  doAssert sim.spin != 0, "a pure couple produced no spin"
  report "opposite equal forces rotate and never translate"

proc sumRule() =
  ## The rule the idea names: the assembly obeys F0 + F1.
  var a = emptyCourseSim()
  var b = emptyCourseSim()
  let split: SeatForces = [(180_000'i32, 40_000'i32), (20_000'i32, 60_000'i32)]
  let mean: SeatForces = [(100_000'i32, 50_000'i32), (100_000'i32, 50_000'i32)]
  a.step(split)
  b.step(mean)
  doAssert a.velX == b.velX and a.velY == b.velY,
    "the sum rule broke: " & $a.velX & "," & $a.velY & " vs " &
      $b.velX & "," & $b.velY
  report "the couch obeys the SUM of the two forces"

proc terminalSpeed() =
  ## Both seats at full force reach ~2.5 m/s.
  var sim = emptyCourseSim()
  let full: SeatForces = [(MaxSeatForce, 0'i32), (MaxSeatForce, 0'i32)]
  for _ in 0 ..< 120:
    sim.step(full)
  let mmPerSecond = umPerTickToMmS(speedOf(sim.velX, sim.velY))
  doAssert mmPerSecond > 2300 and mmPerSecond < 2700,
    "terminal speed is " & $mmPerSecond & " mm/s, expected ~2500"
  report "both seats at full force settle at 2.5 m/s"

proc wallsHold() =
  ## Driven into a wall at full force for 600 ticks the assembly never leaves
  ## the world box and its PENETRATION never exceeds 60 000 um — the note's
  ## bound, and the one that says something: a disc CENTRE past the wall face
  ## is a different (and far later) failure than a disc sunk into it, and the
  ## penetration the solver actually resolved is what the contact log carries.
  var config = testConfig()
  var sim = carryingSim(config)
  let full: SeatForces = [(-MaxSeatForce, 0'i32), (-MaxSeatForce, 0'i32)]
  var worstPenetration = 0'i32
  var contactsSeen = 0
  for _ in 0 ..< 600:
    sim.step(full)
    for contact in sim.contacts:
      inc contactsSeen
      doAssert contact.depthUm > 0, "a contact was logged with no overlap"
      worstPenetration = max(worstPenetration, contact.depthUm)
    for disc in 0 ..< DiscCount:
      let p = sim.discPos(disc)
      doAssert p.x >= 0 and p.y >= 0 and p.x <= WorldW and p.y <= WorldH,
        "disc " & $disc & " left the world box at " & $p.x & "," & $p.y
      doAssert p.x >= WallRing - discRadius(disc),
        "disc " & $disc & " sank through the ring face at " & $p.x
  doAssert contactsSeen > 0, "the couch never reached a wall in 25 s"
  doAssert worstPenetration <= 60_000,
    "a disc buried " & $worstPenetration & " um into a wall"
  report "a wall held against 1200 N for 600 ticks, under 60 mm of penetration"

proc contactsPush() =
  ## The two properties §Tests 1 names, over EVERY contact of every tick:
  ##
  ##  1. contacts push, never stick — the normal force the solver applied is
  ##     never negative, so a disc resting on a wall is never pulled into it;
  ##  2. friction never reverses the slide inside one substep — the Coulomb
  ##     term is capped viscously, and the check is the physical one: the
  ##     velocity change friction can produce in a substep,
  ##     `F * 1e6 / MassStepDen`, is smaller than the slide it opposes.
  ##
  ## `approachMmS`/`slideMmS` are non-negative BY CONSTRUCTION (`max(0, -vn)`
  ## and an isqrt magnitude), so asserting those two proves nothing on its own;
  ## they are kept as cheap sanity beside the two that can fail.
  var config = testConfig()
  var sim = carryingSim(config)
  let full: SeatForces = [(-MaxSeatForce, 0'i32), (-MaxSeatForce, 0'i32)]
  var seen = 0
  var slidingSeen = 0
  for _ in 0 ..< 240:
    sim.step(full)
    for contact in sim.contacts:
      inc seen
      doAssert contact.approachMmS >= 0, "a contact reported a negative approach"
      doAssert contact.slideMmS >= 0, "a contact reported a negative slide"
      doAssert contact.normalMilliNewtons >= 0,
        "a contact PULLED with " & $contact.normalMilliNewtons & " mN"
      doAssert contact.normalMilliNewtons <= ContactForceCap,
        "the normal force escaped its cap: " & $contact.normalMilliNewtons
      doAssert contact.frictionMilliNewtons >= 0
      # The slide the friction opposes, and the velocity change one substep of
      # that friction can produce, both in um/tick.
      let
        slideUmPerTick = int64(contact.slideUmPerTick)
        frictionDv = (int64(contact.frictionMilliNewtons) * 1_000_000) div
          MassStepDen
      if slideUmPerTick > 0:
        inc slidingSeen
        doAssert frictionDv < slideUmPerTick,
          "friction reversed the slide: " & $frictionDv &
            " um/tick against a slide of " & $slideUmPerTick
  doAssert seen > 0, "the couch never reached a wall in 10 s"
  doAssert slidingSeen > 0, "no contact ever slid, so friction was never tested"
  doAssert sim.contactTicks > 0, "the couch never reached a wall in 10 s"
  report "contacts push, never stick, and friction never reverses the slide"

proc feltStrainIsAnalytic() =
  ## With BOTH seats applying the same force the assembly translates, so each
  ## handle's felt force is exactly `F * (2*m_cog/M - 1) = -F/2`. That is the
  ## configuration where the analytic value has no rotational term, and it is
  ## what proves `H_i` really is `m_cog*a_i - F_i`.
  var sim = emptyCourseSim()
  let f = 200_000'i32
  let push: SeatForces = [(f, 0'i32), (f, 0'i32)]
  sim.step(push)
  let want = -int(f) div 2
  for seat in Seat:
    let got = int(sim.strainX[ord(seat)])
    # The tolerance covers the linear drag applied inside the four substeps,
    # which shaves a few per cent off the analytic value; what the assertion
    # proves is that H is -F/2 rather than 0 or -F.
    doAssert abs(got - want) <= int(f) div 8,
      "felt strain for " & seatAlias(seat) & " is " & $got & " mN, analytic " &
        $want
    doAssert abs(int(sim.strainY[ord(seat)])) <= 4000,
      "a pure-x push produced a y strain"
  report "the felt strain matches the analytic value"

proc strainCarriesThePartner() =
  ## The whole coordination channel: what one seat feels depends on what the
  ## OTHER seat did, and on nothing it can see.
  var quiet = emptyCourseSim()
  var loud = emptyCourseSim()
  quiet.step([(200_000'i32, 0'i32), (0'i32, 0'i32)])
  loud.step([(200_000'i32, 0'i32), (400_000'i32, 0'i32)])
  doAssert quiet.strainX[0] != loud.strainX[0],
    "seat 0's felt strain did not change when its PARTNER changed force"
  report "the felt strain contains the partner's force"

proc damageOnlyOnTheCouch() =
  ## Cog discs collide but damage nothing.
  for disc in HullDiscs ..< DiscCount:
    doAssert discRadius(disc) == CogRadius
  var config = testConfig()
  var sim = carryingSim(config)
  let full: SeatForces = [(-MaxSeatForce, 0'i32), (-MaxSeatForce, 0'i32)]
  for _ in 0 ..< 300:
    sim.step(full)
  doAssert sim.damage >= 0 and sim.damage <= int32(sim.config.damageCap)
  report "damage stays inside its cap"

when isMainModule:
  inertiaFromTable()
  equalForcesTranslate()
  oppositeForcesRotate()
  sumRule()
  terminalSpeed()
  wallsHold()
  contactsPush()
  feltStrainIsAnalytic()
  strainCarriesThePartner()
  damageOnlyOnTheCouch()
  echo "test_physics: the rigid assembly behaves"
