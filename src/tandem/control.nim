## The control layer: a pure, integer-only function of
## `(assembly state, this seat's order, this seat's felt strain, the course)`
## returning one force vector in millinewtons plus that seat's grip limit.
##
## Both LLM orders and scripted orders are compiled by THIS code, so the two
## policy kinds are strictly comparable. UNLIKE ctf and cogball the layer sits
## INSIDE the determinism boundary: the wasm viewer runs this same function
## over the same recorded orders and the per-tick `gameHash` chain proves it
## derived the same forces. That is what buys a replay carrying 100 order
## records instead of 4 800 action records, and force arrows the viewer can
## draw exactly.
##
## It contains NO path planning, NO obstacle avoidance and NO automatic
## braking. The only reflex it implements is the one the idea asks for —
## compliance with the felt force — and its strength is a policy parameter
## (`yield`), not a constant. Everything else is the policies' problem.
##
## No floating point: `tests/test_determinism.nim` greps this file.

import sim

proc seatForce*(
  sim: SimServer,
  seat: Seat
): tuple[force: ForceVec, gripLimit: int32] =
  ## One seat's force for one tick, and the grip limit its brace has earned.
  let
    index = ord(seat)
    order = sim.activeOrder[index]
    maxForce = int32(sim.config.maxSeatForceMilliNewtons)
  result.gripLimit = int32(sim.config.gripLimitMilliNewtons) +
    (GripLimitBrace * order.brace) div 255

  # 5. Regrip / delivered / game-over phases force F = 0.
  if sim.phase != Carrying:
    result.force = (0'i32, 0'i32)
    return

  # 1. Drive. `drive` is a Q12 unit vector in VIEW coordinates (y UP); the
  # world has y down, so the y component flips on the way in.
  var
    fx = 0'i32
    fy = 0'i32
  if order.driveX != 0 or order.driveY != 0:
    let d = unitQ12(order.driveX, -order.driveY)
    let scale = (int64(maxForce) * int64(order.effort)) div 255
    fx += int32((scale * int64(d.x)) div 4096)
    fy += int32((scale * int64(d.y)) div 4096)

  # 2. Twist. `n_fore` is the body normal 90 degrees counter-clockwise on
  # screen; the aft seat pushes the other way, so a positive twist from BOTH
  # seats is a pure couple: torque, no net force.
  if order.twist != 0:
    let normal = sim.bodyNormal()
    let sign = if seat == Cobalt: 1'i64 else: -1'i64
    let scale = (int64(TwistForce) * int64(order.twist) * sign) div 255
    fx += int32((scale * int64(normal.x)) div 4096)
    fy += int32((scale * int64(normal.y)) div 4096)

  # 3. Yield: the compliance knob. At yield = 1 you push 80 % of the way the
  # handle is already pulling you, i.e. you go where your partner is taking
  # you. This is the only channel the idea allows.
  if order.yieldQ != 0:
    var
      yx = int32((int64(sim.strainX[index]) * int64(order.yieldQ) *
        int64(YieldGainQ)) div (255'i64 * 4096'i64))
      yy = int32((int64(sim.strainY[index]) * int64(order.yieldQ) *
        int64(YieldGainQ)) div (255'i64 * 4096'i64))
    capVector(yx, yy, maxForce)
    fx += yx
    fy += yy

  # 4. Brace halves your push and raises your grip limit. The final clamp is a
  # PROPORTIONAL shortening, never per-axis clipping, so the direction survives.
  if order.brace != 0:
    let keep = 255'i64 - int64(order.brace) div 2
    fx = int32((int64(fx) * keep) div 255)
    fy = int32((int64(fy) * keep) div 255)
  capVector(fx, fy, maxForce)
  result.force = (fx, fy)

proc compileForces*(sim: SimServer): SeatForces =
  ## Both seats' forces for one tick, in seat order 0 then 1.
  for seat in Seat:
    result[ord(seat)] = sim.seatForce(seat).force

proc stepSim*(sim: var SimServer) =
  ## The ONE tick entry point the live server and the replay player share:
  ## compile both seats' forces from the state at the start of the tick, then
  ## step. Having a single definition is what makes the native and wasm builds
  ## structurally incapable of drifting apart.
  if sim.phase == Carrying or sim.phase == Regrip:
    sim.step(sim.compileForces())
  else:
    sim.step(ZeroForces)
