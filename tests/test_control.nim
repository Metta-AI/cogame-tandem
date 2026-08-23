## The control layer: bounded, direction-preserving, deterministic, and the
## four knobs doing exactly what the schema says.

import std/random
import lib/helpers

proc boundedAndDeterministic() =
  var rng = initRand(20260823)
  var sim = carryingSim(testConfig())
  for _ in 0 ..< 1000:
    sim.pseudoWorld(rng)
    for seat in Seat:
      sim.activeOrder[ord(seat)] = pseudoOrder(rng)
    for seat in Seat:
      let a = sim.seatForce(seat)
      let b = sim.seatForce(seat)
      doAssert a.force == b.force,
        "the same (state, order) pair produced two different forces"
      doAssert a.gripLimit == b.gripLimit
      let magnitude = speedOf(a.force.x, a.force.y)
      doAssert magnitude <= MaxSeatForce + 1,
        "|F| = " & $magnitude & " mN exceeds MaxSeatForce"
      doAssert a.gripLimit >= GripLimitBase and
        a.gripLimit <= GripLimitBase + GripLimitBrace,
        "grip limit out of range: " & $a.gripLimit
  report "1000 randomised (state, order) pairs stay bounded and deterministic"

proc clampPreservesDirection() =
  ## The clamp is a proportional shortening, never per-axis clipping.
  var sim = carryingSim(testConfig())
  sim.headingQ = 0
  for i in 0 ..< SeatCount:
    sim.strainX[i] = 3_000_000
    sim.strainY[i] = 1_500_000
    sim.activeOrder[i] = emptyOrder()
    sim.activeOrder[i].yieldQ = 255
    sim.activeOrder[i].effort = 0
    sim.activeOrder[i].driveX = 0
    sim.activeOrder[i].driveY = 0
  for seat in Seat:
    let f = sim.seatForce(seat).force
    let wanted = bradsOfVectorI(3_000_000, 1_500_000)
    let got = bradsOfVectorI(f.x, f.y)
    var delta = abs(bradError(wanted, got))
    doAssert delta <= 2,
      "the clamp rotated the force by " & $delta & " brads"
    doAssert speedOf(f.x, f.y) <= MaxSeatForce + 1
  report "the force clamp preserves direction to +/-1 brad"

proc braceHalvesAndGrips() =
  var sim = carryingSim(testConfig())
  sim.headingQ = 0
  var bare = emptyOrder()
  bare.driveX = 4096
  bare.driveY = 0
  bare.effort = 255
  bare.yieldQ = 0
  var braced = bare
  braced.brace = 255
  for i in 0 ..< SeatCount:
    sim.strainX[i] = 0
    sim.strainY[i] = 0
  sim.activeOrder[0] = bare
  let full = sim.seatForce(Cobalt)
  sim.activeOrder[0] = braced
  let held = sim.seatForce(Cobalt)
  let ratio = speedOf(held.force.x, held.force.y) * 100 div
    max(1'i32, speedOf(full.force.x, full.force.y))
  doAssert ratio >= 48 and ratio <= 52,
    "brace = 1 scaled the drive to " & $ratio & "%, expected 50%"
  doAssert held.gripLimit == GripLimitBase + GripLimitBrace,
    "brace = 1 gives grip limit " & $held.gripLimit
  doAssert held.gripLimit == 1_300_000, "the braced grip limit is not 1300 N"
  report "brace halves the push and raises the grip limit to 1300 N"

proc zeroYieldIgnoresStrain() =
  var sim = carryingSim(testConfig())
  sim.headingQ = 512
  var order = emptyOrder()
  order.driveX = 4096
  order.effort = 128
  order.yieldQ = 0
  sim.activeOrder[0] = order
  sim.strainX[0] = 0
  sim.strainY[0] = 0
  let quiet = sim.seatForce(Cobalt).force
  sim.strainX[0] = 2_500_000
  sim.strainY[0] = -900_000
  let loud = sim.seatForce(Cobalt).force
  doAssert quiet == loud, "yield = 0 still let the strain through"
  order.yieldQ = 255
  sim.activeOrder[0] = order
  doAssert sim.seatForce(Cobalt).force != loud,
    "yield = 1 ignored the strain"
  report "yield = 0 makes the force independent of the felt strain"

proc twistIsACouple() =
  var sim = carryingSim(testConfig())
  for headingQ in [0'i32, 700'i32, 1900'i32, 3300'i32]:
    sim.headingQ = headingQ
    for i in 0 ..< SeatCount:
      sim.strainX[i] = 0
      sim.strainY[i] = 0
      var order = emptyOrder()
      order.driveX = 0
      order.driveY = 0
      order.effort = 0
      order.yieldQ = 0
      order.twist = 255
      sim.activeOrder[i] = order
    let a = sim.seatForce(Cobalt).force
    let b = sim.seatForce(Rust).force
    doAssert abs(a.x + b.x) <= 2 and abs(a.y + b.y) <= 2,
      "twist from both seats produced a net force of " & $(a.x + b.x) & "," &
        $(a.y + b.y)
    let r0 = sim.offsetWorld(CogOffsets[0])
    let r1 = sim.offsetWorld(CogOffsets[1])
    let torque = torqueOf(r0.x, r0.y, a.x, a.y) +
      torqueOf(r1.x, r1.y, b.x, b.y)
    doAssert torque > 0,
      "a positive twist from both seats produced torque " & $torque
  report "twist from both seats is a pure counter-clockwise couple"

proc pausedPhasesZeroTheForce() =
  var sim = carryingSim(testConfig())
  var order = emptyOrder()
  order.driveX = 4096
  order.effort = 255
  for i in 0 ..< SeatCount:
    sim.activeOrder[i] = order
  doAssert sim.seatForce(Cobalt).force != (0'i32, 0'i32)
  for phase in [Regrip, Delivered, GameOver, Lobby]:
    sim.phase = phase
    for seat in Seat:
      doAssert sim.seatForce(seat).force == (0'i32, 0'i32),
        "phase " & $phase & " still applied a force"
  report "regrip, delivered and game-over force F = 0"

when isMainModule:
  boundedAndDeterministic()
  clampPreservesDirection()
  braceHalvesAndGrips()
  zeroYieldIgnoresStrain()
  twistIsACouple()
  pausedPhasesZeroTheForce()
  echo "test_control: the control layer is bounded, legal and deterministic"
