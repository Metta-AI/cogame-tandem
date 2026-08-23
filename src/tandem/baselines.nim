## The two scripted baselines. Both emit the SAME order object on the same
## 2.0 s cadence as an LLM seat, so their output is legal by construction and
## directly comparable — which is what makes the bounded-orders test in
## tests/test_baselines.nim meaningful.
##
## Both are PURE FUNCTIONS OF THE OBSERVATION A SEAT WOULD RECEIVE. Neither
## reads `sim.activeOrder[other(seat)]`, and neither could: the only thing
## either knows about its partner is `sim.strainX/Y[seat]` — the force in its
## OWN hands — and the shared body's pose. `tests/test_no_channel.nim` asserts
## the signature cannot carry the partner's order.
##
## `porter` is the certification player, the fallback order when the LLM fails
## twice, and the default for a seat that registers neither field. `mule` is
## the second filler: deliberately weaker and different in shape.

import
  std/strutils,
  sim, orders, control

const TuningSeeds* = [
  4417231, 7, 991, 20260823, 31337, 555, 12, 909_090, 4242, 6161,
  777_001, 88, 246_802, 13_579, 101_101, 202_202, 303_303, 404_404,
  505_505, 606_606
]
  ## The committed seed list every tuning claim below was measured over.
  ## `tools/tune_baselines.nim` sweeps against it and `tests/test_baselines.nim`
  ## pins the shipped configuration's outcome on it, so a constant that was
  ## tuned on one set of courses cannot be pinned on another.

## The tuning constants are `{.intdefine.}` so the grid harness can sweep them
## from the command line (`-d:TandemLookahead=2800000`) without editing the
## source. The harness is `tools/tune_baselines.nim` — run it with `--eval` to
## reproduce the numbers quoted below for the shipped defaults, or with
## `--sweep TandemMuleEffort=64,140,255` to re-run a grid. The sweeps these
## constants came out of are logged in `docs/BASELINE-TUNING.md`.
const
  Lookahead* {.intdefine: "TandemLookahead".} = 2_600_000
    ## micrometres of pure-pursuit lead along the route polyline. The polyline
    ## interleaves cell centres and doorway centres, so with this lead the
    ## target IS the next doorway centre through the whole approach — the rule
    ## the design note states — and the next cell centre once the couch is
    ## through it.
  DoorNear* {.intdefine: "TandemDoorNear".} = 1_500_000
    ## within this of a doorway plane the carrier braces.
  OpenEffort* {.intdefine: "TandemOpenEffort".} = 255      ## 1.00
    ## Both seats at full effort settle at 2.5 m/s, which is 1.56x the 1.6 m/s
    ## reference pace `parTicks` is built from. That headroom is not optional:
    ## a carry that cruises AT par has nothing left for the corners, the
    ## bracing and the doorway approaches. Swept over the committed seed list
    ## (`tools/tune_baselines.nim --sweep TandemOpenEffort=128,160,200,255`):
    ## 18/20, 19/20, 18/20, 20/20 deliveries at mean scores 0.637, 0.704,
    ## 0.695, 0.794. Full effort costs condition (219 mean damage against 68
    ## at half) and buys the deliveries anyway. See docs/BASELINE-TUNING.md.
  OpenYield* {.intdefine: "TandemOpenYield".} = 51         ## 0.20
  ConflictYield* {.intdefine: "TandemConflictYield".} = 140 ## 0.55
  LeadYield* {.intdefine: "TandemLeadYield".} = 26          ## 0.10
  FollowYield* {.intdefine: "TandemFollowYield".} = 153     ## 0.60
  ConflictEffort* {.intdefine: "TandemConflictEffort".} = 128 ## 0.50
  BraceHigh* {.intdefine: "TandemBraceHigh".} = 217        ## 0.85
  StrainBraceMilliNewtons* {.intdefine: "TandemStrainBrace".} = 600_000
  TwistDeadBrads* {.intdefine: "TandemTwistDead".} = 7     ## ~10 degrees
  TwistGain* {.intdefine: "TandemTwistGain".} = 5
    ## twist units per brad of heading error. A full twist from both seats
    ## accelerates the assembly at ~8 rad/s^2 against ~8 1/s of angular drag,
    ## so it settles at ~1 rad/s -- 115 degrees in one 2 s turn. A gain that
    ## turns a 45 degree error into a full twist therefore overshoots by a
    ## factor of three and the couch pinwheels; 3 units per brad asks for
    ## exactly the rate that closes the error inside one turn.
  TwistDamp* {.intdefine: "TandemTwistDamp".} = 4
    ## twist units per 1/16-brad-per-tick of spin, subtracted: the D term that
    ## stops the alignment being a pure P controller on a low-drag rigid body.
    ## Measured on the shipped gain it is NOT load-bearing -- the
    ## `TandemTwistGain=3,5,8` x `TandemTwistDamp=0,4,8` grid gives 20/20 at
    ## gain 5 for damp 0, 2 and 4, with damp 0 0.008 of mean score ahead. It is
    ## kept at 4 because re-tuning a sim constant moves the per-tick gameHash
    ## chain and the golden fixture with it. docs/BASELINE-TUNING.md has the
    ## whole grid.
  SpinDeadQ* {.intdefine: "TandemSpinDead".} = 3 * 256
  RampUm* {.intdefine: "TandemRamp".} = 3_000_000
    ## the couch is asked for full effort beyond this distance from its
    ## target, and for a proportionally smaller one inside it. Stopping from
    ## the 2.5 m/s cap on drag alone takes about 0.6 m, so a 3 m ramp arrives
    ## without overshooting.
  IdleEffort* {.intdefine: "TandemIdleEffort".} = 12
  MuleEffort* {.intdefine: "TandemMuleEffort".} = 140      ## 0.55
    ## The design note gives `mule` effort 1.0. Measured, that makes it not a
    ## bad partner but an IMMOVABLE one: two cogs have the same 600 N, so a
    ## mule shoving straight at the goal pins the couch against the first wall
    ## in the way and a porter on the other handle cannot free it — porter x
    ## mule scored exactly what mule x mule scored (0.016), which is a filler
    ## that erases its partner rather than testing it. At 0.55 the mule is
    ## still stubborn, still never yields and still never braces, but a
    ## carrier at full effort can out-pull it and steer.
  PivotBoxUm* {.intdefine: "TandemPivotBox".} = 1_400_000
    ## how close to the cell centre the couch must be before it will pivot.
    ## A 3.40 m assembly needs a 3.40 m circle and the cell is 4.80 m, so the
    ## legal pivot centres are a 1.40 m box — half of that is 0.70 m.
  CommitHyst* {.intdefine: "TandemCommitHyst".} = 800_000
    ## how far short of the staging point the carry commits to driving on
    ## through the gap. See `doorPlan`.
  StuckReachUm* {.intdefine: "TandemStuckReach".} = 1_500_000
    ## a stall closer than this to the target is an ARRIVAL, not a jam.
  CellLead* {.intdefine: "TandemCellLead".} = 1_600_000
    ## beyond `DoorApproach + CellLead` from the doorway plane the carry aims
    ## at the CELL CENTRE first, so a 90-degree corner is taken as two straight
    ## moves instead of one diagonal that clips both jambs.
  ConflictCos* {.intdefine: "TandemConflictCos".} = 2048
    ## Q12 cosine (0.5 = 60 degrees). The partner's force is ESTIMATED from
    ## the felt strain, and wall contacts pollute that estimate, so only a
    ## strong disagreement counts as a conflict — a bare sign test fires on
    ## noise and pins the carry at follower effort for the whole run.
  AlignBrads* {.intdefine: "TandemAlignBrads".} = 22
    ## 22.5 degrees. Beyond this the carrier stops shoving and rotates.
  AlignRange* {.intdefine: "TandemAlignRange".} = 3_500_000
    ## within this of a doorway plane, line up with the gap's THROUGH
    ## direction; further out, line up with where you are actually going.
  TurnEffort* {.intdefine: "TandemTurnEffort".} = 90       ## 0.35
  EscapeEffort* {.intdefine: "TandemEscapeEffort".} = 140  ## 0.55
  StuckSpeedUm* {.intdefine: "TandemStuckSpeed".} = 8_000
    ## micrometres per tick (0.19 m/s). Below this AND in contact is wedged.
  BackOff* {.intdefine: "TandemBackOff".} = 2_500_000
    ## how far back from the doorway plane a wedged carry re-aims.
  DoorApproach* {.intdefine: "TandemDoorApproach".} = 2_000_000
    ## the staging point short of the doorway plane, and the point just past
    ## it the carry drives out to.

proc lookaheadTarget*(
  sim: SimServer
): tuple[x, y, dirX, dirY: int32] =
  ## The pure-pursuit point on the route polyline, `Lookahead` micrometres
  ## ahead of the couch's projection, plus the route's local direction there.
  ## In the goal cell that saturates at the goal-pad centre.
  let arc = sim.course.arcAlongRoute(sim.posX, sim.posY)
  sim.course.pointAtArc(arc + int64(Lookahead))

proc distanceToNextDoor*(sim: SimServer): int32 =
  ## Distance from the couch centre to the plane of the doorway it is heading
  ## for, or a large number in the goal cell.
  if sim.doorsCleared >= int32(sim.course.doorways.len):
    return high(int32)
  let door = sim.course.doorways[sim.doorsCleared]
  if door.vertical: abs(sim.posX - door.cx) else: abs(sim.posY - door.cy)

proc throughDirection*(sim: SimServer): tuple[x, y: int32] =
  ## The direction the couch axis should be lined up with: the traversal
  ## direction of the doorway it is heading for, or the route direction at the
  ## lookahead point once every doorway is behind it.
  if sim.doorsCleared < int32(sim.course.doorways.len):
    let door = sim.course.doorways[sim.doorsCleared]
    (door.throughX, door.throughY)
  else:
    let target = sim.lookaheadTarget()
    (target.dirX, target.dirY)

proc partnerForce*(sim: SimServer, seat: Seat): tuple[x, y: int32] =
  ## What the OTHER cog is pushing with, estimated from the only thing this
  ## seat can measure: the force in its own hands.
  ##
  ## The physics gives `H = (m_cog/M)*(F_self + F_partner) - F_self`, and with
  ## m_cog/M = 1/4 that is `H = F_partner/4 - 3*F_self/4`, so
  ## `F_partner = 4*H + 3*F_self`. Reading the raw strain instead would be
  ## backwards: two cogs pushing the SAME way both feel a strain pointing the
  ## other way (the couch's inertia resisting), which is cooperation, not
  ## conflict. `F_self` is this seat's own compiled force from its own last
  ## order — no partner state is read anywhere.
  let mine = sim.seatForce(seat).force
  let index = ord(seat)
  var
    x = 4 * sim.strainX[index] + 3 * mine.x
    y = 4 * sim.strainY[index] + 3 * mine.y
  capVector(x, y, 4 * MaxSeatForce)
  (x, y)

proc alignQ12(ax, ay, bx, by: int32): int32 {.inline.} =
  ## cos of the angle between two vectors, in Q12. Zero vectors read as 0.
  let
    ua = unitQ12(ax, ay)
    ub = unitQ12(bx, by)
  if ua.d == 0 or ub.d == 0:
    return 0
  int32((int64(ua.x) * int64(ub.x) + int64(ua.y) * int64(ub.y)) div 4096)

proc axisError*(sim: SimServer, dirX, dirY: int32): int32 =
  ## The signed brad error between the couch axis and a world direction,
  ## folded into +/-90 degrees so the couch is happy either way round (a couch
  ## carried backwards is still a couch through a door).
  let
    want = bradsOfVectorI(dirX, dirY)
    have = bradsOfVectorI(sim.bodyAxis().x, sim.bodyAxis().y)
  var err = bradError(want, have)
  if err > 64: err -= 128
  elif err < -64: err += 128
  err

proc porterCellCentre*(sim: SimServer): tuple[x, y: int32] =
  ## The centre of the route cell the carry is working out of: the cell BEFORE
  ## the next uncleared doorway, which is the only place a 3.40 m assembly can
  ## turn inside a 4.80 m cell (it needs a 3.40 m circle; the cell leaves a
  ## 1.40 m box of legal centres).
  let k = min(int(sim.doorsCleared), sim.course.routeCols.len - 1)
  (cellCentreX(int(sim.course.routeCols[k])),
   cellCentreY(int(sim.course.routeRows[k])))

proc doorPlan*(
  sim: SimServer
): tuple[targetX, targetY, alignX, alignY, s: int32] =
  ## Where a carrier is heading and which line the couch AXIS must be on.
  ##
  ## The route polyline interleaves cell centres and doorway centres, but a
  ## 3.40 m assembly cannot pivot INSIDE a 1.05 m gap, so the plan is stated in
  ## terms of the next doorway: line the couch up with the gap's THROUGH
  ## direction while parked at the cell centre, drive to a staging point
  ## `DoorApproach` short of the plane, then drive straight out the far side.
  ## `s` is the signed distance from the doorway plane along that direction.
  ##
  ## Crabbing sideways is free here — the floor is frictionless and the only
  ## contacts are walls — so the couch only ever has to turn to change which
  ## way it POINTS, never to change where it is going.
  if sim.doorsCleared < int32(sim.course.doorways.len):
    let door = sim.course.doorways[sim.doorsCleared]
    let s = int32((int64(sim.posX - door.cx) * int64(door.throughX) +
      int64(sim.posY - door.cy) * int64(door.throughY)) div 4096)
    # HYSTERESIS on the approach/exit switch. Without it the staging point is
    # exactly the point the cruise controller asymptotes to, so the carry
    # parks on the switch and never commits to the gap (measured: four of
    # twenty seeds stopped 0.45 m from the start and stayed there for the
    # whole run).
    let reach = if s < -(int32(DoorApproach) + int32(CommitHyst)):
                  -int32(DoorApproach)
                else: int32(DoorApproach)
    result.targetX = door.cx + q12Scale(reach, door.throughX)
    result.targetY = door.cy + q12Scale(reach, door.throughY)
    result.alignX = door.throughX
    result.alignY = door.throughY
    result.s = s
  else:
    let goal = sim.course.goalCentre()
    result.targetX = goal.x
    result.targetY = goal.y
    result.alignX = goal.x - sim.posX
    result.alignY = goal.y - sim.posY
    result.s = high(int32)

proc porterOrder*(sim: SimServer, seat: Seat, turn: int): Order =
  ## Strain-arbitrated leader/follower with NO communication. Both copies run
  ## this rule, so two porters converge within a turn or two without any
  ## convention — and against a stranger the same rule still arbitrates, which
  ## is the point.
  ##
  ## The carry is a four-state machine, all of it derived from what a SEAT can
  ## see — the shared body's pose, the map, and the force in its own hands:
  ##
  ##   recentre  the couch axis is more than AlignBrads off the corridor it is
  ##             about to enter, and it is not parked in the middle of its
  ##             cell. Drive to the cell centre WITHOUT twisting: rotating a
  ##             3.4 m assembly while it travels is what grinds the upholstery
  ##             off against the jambs.
  ##   turning   parked in the middle, misaligned: pivot, holding station.
  ##   stuck     stalled well short of the target and in contact: back onto the
  ##             gap's own axis and re-approach down the middle.
  ##   carrying  aligned: cruise to the staging point and straight out the far
  ##             side, twisting only to hold the line.
  result = emptyOrder()
  result.turn = int32(turn)
  result.source = osScripted

  let
    plan = sim.doorPlan()
    centre = sim.porterCellCentre()
    doorDist = sim.distanceToNextDoor()
    speed = speedOf(sim.velX, sim.velY)
    strain = sim.strainMagnitude(seat)
    touching = sim.contacts.len > 0
    err = sim.axisError(plan.alignX, plan.alignY)
    offCentre = distI(centre.x - sim.posX, centre.y - sim.posY)
    misaligned = abs(err) > int32(AlignBrads)
    # "Parked" is EITHER inside the pivot box or simply stopped: the cruise
    # controller settles a metre short of the centre as often as not, and a
    # carrier that will only pivot inside a hard box deadlocks there forever
    # (measured: four of twenty seeds never moved again).
    parked = offCentre <= int32(PivotBoxUm) or speed < int32(StuckSpeedUm)
    recentring = misaligned and not parked and plan.s < 0
    turning = misaligned and parked and plan.s < 0

  # 1. The target.
  var
    targetX = plan.targetX
    targetY = plan.targetY
  if recentring or turning:
    targetX = centre.x
    targetY = centre.y
  let toGo = distI(targetX - sim.posX, targetY - sim.posY)
  # WEDGED, not merely slow: the cruise controller deliberately brings the
  # couch to a stop ON its target, so "not moving and touching something" is
  # the NORMAL end of a leg. Only a stall well short of the target is a jam.
  let stuck = speed < int32(StuckSpeedUm) and touching and
    toGo > int32(StuckReachUm) and not turning
  if stuck and sim.doorsCleared < int32(sim.course.doorways.len):
    # Back off ONTO the gap's own axis, not just backwards from wherever the
    # couch happens to have jammed: re-approaching down the middle is what
    # stops the escape from turning into a wedge-escape-wedge loop.
    let door = sim.course.doorways[sim.doorsCleared]
    targetX = door.cx - q12Scale(int32(BackOff), door.throughX)
    targetY = door.cy - q12Scale(int32(BackOff), door.throughY)

  # 2. Drive AT the target and regulate the speed with EFFORT, never with the
  # drive direction.
  #
  # This is the shape the 2 s decision turn forces. An order is held constant
  # for 48 ticks, so any velocity feedback folded into the drive vector runs
  # at 0.5 Hz against a body whose drag time constant is 0.25 s: a brake
  # command issued because the couch is closing too fast is still being obeyed
  # two seconds later, and the carry settles into a stable limit cycle,
  # shuttling a metre back and forth in front of the first doorway forever
  # (measured on four of twenty seeds).
  #
  # A constant force gives a terminal speed of `effort` x 2.5 m/s, and the
  # couch reaches it in about a quarter of a second, so ramping the EFFORT
  # down with the distance left is a position controller with no feedback in
  # the direction at all — and it cannot oscillate.
  let
    toTarget = unitQ12(targetX - sim.posX, targetY - sim.posY)
    approach = int32(min(255'i64,
      (255'i64 * int64(toTarget.d)) div int64(RampUm)))
  let felt = sim.partnerForce(seat)
  let drive = quantUnitFromWorld(targetX - sim.posX, targetY - sim.posY)
  if drive.x != 0 or drive.y != 0:
    result.driveX = drive.x
    result.driveY = drive.y

  # 3. Strain arbitration. A partner's force is ESTIMATED from the strain (see
  # `partnerForce`); when it opposes where you want to go by more than 60
  # degrees your partner has committed elsewhere, so yield to them rather than
  # spin the couch.
  #
  # `drive` is a VIEW-frame unit vector (y up); the estimate is in world
  # components (y down), so the comparison flips the y axis.
  let align = alignQ12(felt.x, felt.y, result.driveX, -result.driveY)
  let cruiseEffort = clamp(approach, int32(IdleEffort), int32(OpenEffort))
  if stuck:
    result.effort = max(cruiseEffort, int32(EscapeEffort))
    result.yieldQ = int32(OpenYield)
  elif turning:
    result.effort = min(cruiseEffort, int32(TurnEffort))
    result.yieldQ = int32(OpenYield)
  elif align < -int32(ConflictCos):
    # The partner is pushing somewhere else. LEAD: drop the compliance to
    # almost nothing and take the couch yourself.
    #
    # The design note has this branch yield 0.55 and ease to 0.35 instead.
    # Measured, that is a trap against a stubborn partner: porter simply
    # follows a `mule` into the nearest wall and stays there for the whole
    # run (0 of 20 deliveries, 7.6 % progress — exactly mule x mule's number).
    # Leading is also what the note's own champion #2 prompt prescribes for
    # the same reading of the strain.
    result.yieldQ = int32(LeadYield)
    result.effort = cruiseEffort
  elif align > int32(ConflictCos):
    # The partner is leading well: add force along the SAME line and comply.
    result.yieldQ = int32(FollowYield)
    result.effort = min(cruiseEffort, int32(ConflictEffort))
  else:
    result.yieldQ = int32(OpenYield)
    result.effort = cruiseEffort

  # 4. Line the couch axis up with the corridor it is about to enter. This is
  # allowed while RECENTRING (the target is the middle of the cell, which is
  # open floor) but the drive above never aims a rotating assembly at a
  # doorway: the couch is always square to the gap before it commits to it.
  if abs(err) > int32(TwistDeadBrads) or abs(sim.spin) > int32(SpinDeadQ):
    result.twist = clamp(
      int32(err) * int32(TwistGain) -
        (sim.spin * int32(TwistDamp)) div SpinFine,
      -255'i32, 255'i32)

  # 5. Plant your feet in a doorway or under load — but never while turning or
  # escaping, because a brace halves the push that has to move the couch.
  if not turning and not stuck and
      (doorDist <= int32(DoorNear) or strain > int32(StrainBraceMilliNewtons)):
    result.brace = int32(BraceHigh)

  result.note = "line up, ease through, hold the corner"
  result.say =
    if stuck: "backing off, we are wedged"
    elif recentring: "back to the middle first"
    elif turning: "swinging the ends round"
    elif align < -int32(ConflictCos): "you lead, I'll follow"
    elif doorDist <= int32(DoorNear): "easing into the gap"
    else: "walking it on"

proc muleOrder*(sim: SimServer, seat: Seat, turn: int): Order =
  ## A stubborn carrier who never yields and never braces: drive straight at
  ## the goal pad, ignoring the route. It scrapes constantly, drops often, and
  ## usually still delivers on wide courses. It exists to give the ladder a
  ## spread and to be the "bad partner" a champion has to cope with.
  discard seat
  result = emptyOrder()
  result.turn = int32(turn)
  result.source = osScripted
  let goal = sim.course.goalCentre()
  let drive = quantUnitFromWorld(goal.x - sim.posX, goal.y - sim.posY)
  if drive.x != 0 or drive.y != 0:
    result.driveX = drive.x
    result.driveY = drive.y
  result.effort = int32(MuleEffort)
  result.yieldQ = 0
  result.twist = 0
  result.brace = 0
  result.note = "straight at the goal, full effort"
  result.say = "push"

proc baselineOrder*(
  sim: SimServer,
  seat: Seat,
  name: string,
  turn: int
): Order =
  ## Dispatch by baseline name. An unknown name is `porter` — a seat that sets
  ## neither PLAYER_PROMPT nor PLAYER_SCRIPTED plays it too.
  if name.strip().toLowerAscii() == "mule":
    sim.muleOrder(seat, turn)
  else:
    sim.porterOrder(seat, turn)

proc baselineNames*(): seq[string] = @["porter", "mule"]
