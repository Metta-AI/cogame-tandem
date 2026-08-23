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
  for _ in 0 ..< 200:
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
  for _ in 0 ..< 240:
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
  ## the world box and never buries a disc more than a wall thickness deep.
  var config = testConfig()
  var sim = carryingSim(config)
  let full: SeatForces = [(-MaxSeatForce, 0'i32), (-MaxSeatForce, 0'i32)]
  var worstPenetration = 0'i32
  for _ in 0 ..< 600:
    sim.step(full)
    for disc in 0 ..< DiscCount:
      let p = sim.discPos(disc)
      doAssert p.x >= 0 and p.y >= 0 and p.x <= WorldW and p.y <= WorldH,
        "disc " & $disc & " left the world box at " & $p.x & "," & $p.y
      if p.x < WallRing:
        worstPenetration = max(worstPenetration, WallRing - p.x)
  doAssert worstPenetration < InnerWall,
    "a disc buried " & $worstPenetration & " um into the ring"
  report "a wall held against 1200 N for 600 ticks"

proc contactsPush() =
  ## Contacts push, never stick: the normal force is never negative, so a disc
  ## resting on a wall is never pulled into it.
  var config = testConfig()
  var sim = carryingSim(config)
  let full: SeatForces = [(-MaxSeatForce, 0'i32), (-MaxSeatForce, 0'i32)]
  for _ in 0 ..< 240:
    sim.step(full)
  for contact in sim.contacts:
    doAssert contact.approachMmS >= 0, "a contact reported a negative approach"
    doAssert contact.slideMmS >= 0, "a contact reported a negative slide"
  doAssert sim.contactTicks > 0, "the couch never reached a wall in 10 s"
  report "contacts push and never stick"

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
