## The turn engine: one decision every 48 ticks, BOTH player sockets queried
## within one deadline, two bounded attempts, then the scripted fallback.
##
## Timing (docs/RULES.md §Budget):
##   inter-batch wall floor      4.5 s   (config minBatchSpacingMs)
##   attempt 1 batch deadline    4.5 s   (config attempt1Ms)
##   retry batch deadline        2.0 s   (config retryMs)
##   outer monotonic turn cap    7.0 s   (config turnBudgetMs)
## The socket transport takes a whole-second timeout. The per-attempt allowance
## is floored to whole seconds: 4 s + 2 s, inside the 7 s cap.
## 50 turns x 7.0 s = 350 s against a 720 s budget, with a 660 s engine stop.
##
## The inter-turn floor is a bounded sleep between player requests.
##
## Seats are NEVER queried sequentially — this is a simultaneous-decision game.
## The transport is injected as a `BatchFn` so tests/test_engine.nim can hand in
## a fake that records each call's in-flight window and assert the two windows
## intersect.

import
  std/[json, monotimes, os, strutils, times],
  sim, orders, baselines

type
  BatchCall* = object
    seat*: int
    turn*: int
    system*, user*: string

  BatchReply* = object
    seat*: int
    ok*: bool
    text*: string
    error*: string

  BatchFn* = proc (
    calls: seq[BatchCall],
    timeoutSeconds: int
  ): seq[BatchReply] {.closure, gcsafe.}

  SeatPolicy* = object
    kind*: PolicyKind
    baseline*: string
    label*: string
    connected*: bool

  TurnEngine* = ref object
    batch*: BatchFn
    policies*: array[Seat, SeatPolicy]
    previous*: array[Seat, Order]
    hasPrevious*: array[Seat, bool]
    damageAtTurnStart*: int32
    llmOff*: bool
    guardTurn*: int
    lastBatchAt*: MonoTime
    hasBatched*: bool
    records*: seq[string]      ## the replay chat records this turn produced.
    externalAccepted*: array[Seat, bool]

# --------------------------------------------------------------------------
# The per-seat view
# --------------------------------------------------------------------------

proc doorwayJson(sim: SimServer, index: int): JsonNode =
  let
    door = sim.course.doorways[index]
    dist = distI(door.cx - sim.posX, door.cy - sim.posY)
  %*{
    "centre": [round2(viewX(door.cx)), round2(viewY(door.cy))],
    "width_m": round2(viewLen(door.width)),
    "through_deg": degOfVectorView(door.throughX, door.throughY),
    "dist_m": round2(viewLen(dist))
  }

proc roomJson(sim: SimServer): JsonNode =
  ## Every wall rect and pillar within 6 m of the couch. Map only — nothing
  ## here is derived from the partner's order.
  const Reach = 6_000_000'i32
  var walls = newJArray()
  var pillars = newJArray()
  for wall in sim.course.walls:
    let
      nx = clamp(sim.posX, wall.x0, wall.x1)
      ny = clamp(sim.posY, wall.y0, wall.y1)
    if distI(sim.posX - nx, sim.posY - ny) > Reach:
      continue
    if wall.kind == 3:
      pillars.add(%*{
        "centre": [round2(viewX((wall.x0 + wall.x1) div 2)),
                   round2(viewY((wall.y0 + wall.y1) div 2))],
        "size_m": round2(viewLen(wall.x1 - wall.x0))})
    else:
      walls.add(%*{
        "x": [round2(viewX(wall.x0)), round2(viewX(wall.x1))],
        "y": [round2(viewY(wall.y1)), round2(viewY(wall.y0))]})
    if walls.len >= 24:
      break
  %*{"walls": walls, "pillars": pillars}

proc seatViewJson*(
  engine: TurnEngine,
  sim: SimServer,
  seat: Seat,
  turn: int
): JsonNode =
  ## Everything this seat sees, in view coordinates (metres, centred, y up) and
  ## degrees, rounded to two decimals.
  ##
  ## **NO CHANNEL.** Every field is either this seat's own state, the shared
  ## body's state, or the map. Nothing is derived from the partner's order,
  ## note, `say`, effort, yield, twist, brace or felt strain — only the
  ## partner's BODY position, which is visible because both cogs are gripping
  ## the same object. tests/test_no_channel.nim asserts it over 200 randomised
  ## order pairs.
  let
    index = ord(seat)
    partner = other(seat)
    me = sim.handlePos(seat)
    them = sim.handlePos(partner)
    elapsed = sim.gameTicksElapsed()
    strain = sim.strainMagnitude(seat)
    limit = sim.gripLimitOf(seat)
  var doors = newJArray()
  var shown = 0
  var i = int(sim.doorsCleared)
  while i < sim.course.doorways.len and shown < 3:
    doors.add(doorwayJson(sim, i))
    inc shown
    inc i
  var touching = newJArray()
  for name in sim.touching:
    touching.add(%name)
  let
    goal = sim.course.goalCentre()
    cell = cellOf(sim.posX, sim.posY)
    goalArc = int64(sim.course.routeLen) -
      sim.course.arcAlongRoute(sim.posX, sim.posY)
  %*{
    "turn": turn,
    "of": sim.turnCount(),
    "clock": {
      "elapsed_s": round2(float(elapsed) / float(TargetFps)),
      "par_s": round2(float(sim.parTicks()) / float(TargetFps)),
      "left_s": round2(float(max(0, sim.config.maxTicks - elapsed)) /
        float(TargetFps))},
    "you": {"alias": seatAlias(seat), "handle": handleText(seat),
            "pos": [round2(viewX(me.x)), round2(viewY(me.y))]},
    "partner": {"alias": seatAlias(partner), "handle": handleText(partner),
                "pos": [round2(viewX(them.x)), round2(viewY(them.y))]},
    "couch": {
      "pos": [round2(viewX(sim.posX)), round2(viewY(sim.posY))],
      "angle_deg": degOfQ(sim.headingQ),
      "vel": [round2(viewSpeed(sim.velX)), round2(-viewSpeed(sim.velY))],
      "speed": round2(viewSpeed(speedOf(sim.velX, sim.velY))),
      "spin_deg_s": spinDegPerSecond(sim.spin),
      "length_m": round2(viewLen(CouchLengthUm)),
      "width_m": round2(viewLen(CouchWidthUm))},
    "strain": {
      "vec": [int(sim.strainX[index] div 1000),
              int(-sim.strainY[index] div 1000)],
      "newtons": int(strain div 1000),
      "grip_limit_newtons": int(limit div 1000),
      "headroom_pct": int(clamp(100 - (int64(strain) * 100) div
        int64(max(1'i32, limit)), 0'i64, 100'i64)),
      "slip_pct": int(clamp(int(sim.slip[index]) * 100 div
        int(SlipDropThreshold), 0, 100)),
      "note": "this is the force in YOUR hands; it is the only thing your " &
        "partner can send you"},
    "condition": {
      "damage": int(sim.damage),
      "condition_pct": round2(float(sim.conditionPermille()) / 10.0),
      # The damage taken during the PREVIOUS turn: `damageAtTurnStart` is the
      # snapshot the last `turn()` left behind, so this is the cost of the 48
      # ticks since. Snapshotting it at the TOP of `turn()` made the
      # subtraction `sim.damage - sim.damage` and the field structurally 0.
      "damage_last_turn": int(max(0'i32, sim.damage - engine.damageAtTurnStart)),
      "touching": touching,
      "drops": int(sim.drops)},
    "route": {
      "progress_pct": round2(float(sim.bestProgressPermille) / 10.0),
      "cell": [int(cell.col), int(cell.row)],
      "doors_cleared": int(sim.doorsCleared),
      "doors_total": sim.course.doorways.len,
      "next_doorways": doors,
      "goal": {
        "centre": [round2(viewX(goal.x)), round2(viewY(goal.y))],
        "dist_along_route_m": round2(float(max(0'i64, goalArc)) / 1_000_000.0)}},
    "room": roomJson(sim),
    "your_last_order": (
      if engine.hasPrevious[seat]: orderJson(sim, seat, engine.previous[seat])
      else: newJNull())
  }

proc userMessage*(
  engine: TurnEngine,
  sim: SimServer,
  seat: Seat,
  turn: int
): string =
  $engine.seatViewJson(sim, seat, turn)

# --------------------------------------------------------------------------
# The transport
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# The turn
# --------------------------------------------------------------------------

proc newTurnEngine*(batch: BatchFn): TurnEngine =
  result = TurnEngine(batch: batch, guardTurn: -1)
  for seat in Seat:
    result.previous[seat] = emptyOrder()

proc addRecord(engine: TurnEngine, node: JsonNode) =
  engine.records.add(capRecord($node))

proc fallbackFor(
  engine: TurnEngine,
  sim: SimServer,
  seat: Seat,
  turn: int
): Order =
  ## The `porter` order is the fallback for every failure mode.
  discard engine
  result = sim.porterOrder(seat, turn)
  result.source = osFallback

proc waitForBatchFloor(engine: TurnEngine, sim: SimServer, budgetLeftMs: int) =
  ## The inter-batch wall floor. A bounded sleep, never a spin, and never past
  ## what the wall-clock budget has left.
  if not engine.hasBatched or sim.config.minBatchSpacingMs <= 0:
    return
  let sinceMs = (getMonoTime() - engine.lastBatchAt).inMilliseconds
  var waitMs = sim.config.minBatchSpacingMs - int(sinceMs)
  if waitMs <= 0:
    return
  waitMs = min(waitMs, sim.config.minBatchSpacingMs)
  waitMs = min(waitMs, max(0, budgetLeftMs))
  if waitMs > 0:
    sleep(waitMs)

proc turn*(
  engine: TurnEngine,
  sim: var SimServer,
  turnIndex: int,
  elapsedSeconds: int
) =
  ## Runs one decision turn: the inter-batch floor, then at most one parallel
  ## batch plus at most one parallel retry, all inside a monotonic
  ## `turnBudgetMs` bound, then writes the records. The RECORDS are the only
  ## path an order takes into hashed state — the server folds each one back
  ## through `applyRecord`, so the live sim and the replay install bit-identical
  ## integers.
  engine.records.setLen(0)
  engine.externalAccepted = [false, false]
  let
    deadline = getMonoTime() + initDuration(
      milliseconds = max(1, sim.config.turnBudgetMs))
    budget = sim.config.wallClockBudgetSeconds
    perTurn = (sim.config.turnBudgetMs + 999) div 1000

  # Budget guard: switch the ordinary player requests off rather than
  # let it end `deadline`. Microseconds per turn from here on.
  if not engine.llmOff and elapsedSeconds + 2 * perTurn > budget:
    engine.llmOff = true
    engine.guardTurn = turnIndex
    engine.addRecord(%*{
      "k": "budget_guard",
      "turn": turnIndex,
      "remaining_s": budget - elapsedSeconds
    })
    echo "tandem: budget guard at turn ", turnIndex,
      "; falling back to the scripted layer for the rest of the run"

  var
    resolved: array[Seat, Order]
    settled: array[Seat, bool]
    calls: seq[BatchCall]
  for seat in Seat:
    let policy = engine.policies[seat]
    if policy.kind == pkScripted or not policy.connected:
      # DEGRADE, NEVER HANG. A scripted seat plays its baseline; a disconnected
      # ordinary seat degrades to `porter` instead of waiting on its socket. It revives
      # the moment a reconnect re-registers it — `registrationOf` sets
      # `connected` again. A seat that has not registered at all is
      # pkScripted/porter already.
      resolved[seat] = sim.baselineOrder(seat, policy.baseline, turnIndex)
      settled[seat] = true
    elif engine.llmOff or engine.batch.isNil:
      resolved[seat] = engine.fallbackFor(sim, seat, turnIndex)
      settled[seat] = true
      let cause = if engine.llmOff: "budget_guard" else: "no_transport"
      engine.addRecord(%*{
        "k": "fallback", "turn": turnIndex, "seat": ord(seat),
        "attempt": 1, "cause": cause,
        "detail": ""
      })
    else:
      calls.add BatchCall(
        seat: ord(seat),
        turn: turnIndex,
        system: "",
        user: engine.userMessage(sim, seat, turnIndex))

  if calls.len > 0:
    engine.waitForBatchFloor(sim, (budget - elapsedSeconds) * 1000)

  var attempt = 1
  while calls.len > 0 and attempt <= 2:
    let
      remainingMs = (deadline - getMonoTime()).inMilliseconds
      wantMs = if attempt == 1: sim.config.attempt1Ms else: sim.config.retryMs
      allowedMs = min(wantMs, int(max(0'i64, remainingMs)))
    if allowedMs <= 0:
      break
    let started = getMonoTime()
    engine.lastBatchAt = started
    engine.hasBatched = true
    var replies: seq[BatchReply]
    try:
      # The socket transport takes whole seconds. Round down so the first
      # attempt cannot consume the retry budget.
      replies = engine.batch(calls, max(1, allowedMs div 1000))
    except CatchableError as failure:
      replies = @[]
      for call in calls:
        replies.add BatchReply(seat: call.seat, error: failure.msg)
    let latency = int32((getMonoTime() - started).inMilliseconds)
    var retry: seq[BatchCall]
    for reply in replies:
      let seat = Seat(reply.seat and 1)
      var cause = ""
      var detail = reply.error
      if not reply.ok:
        # curl words its deadline several ways ("Timeout was reached",
        # "Operation timed out after ...", "Connection timed out"), so match on
        # the lowercased text and on both spellings.
        let text = reply.error.toLowerAscii()
        cause =
          if text.contains("timeout") or text.contains("timed out"): "timeout"
          else: "transport_error"
      else:
        try:
          var payload = parseJson(reply.text)
          if engine.policies[seat].kind == pkExternal:
            if payload["type"].getStr() != "decision" or
                payload["turn"].getInt() != turnIndex:
              raise newException(TandemError,
                "external decision differs from the pending turn")
            payload = payload["action"]
          let parsed = parseOrder(payload, engine.previous[seat],
            engine.hasPrevious[seat], sim.porterOrder(seat, turnIndex),
            turnIndex)
          if parsed.usable:
            resolved[seat] = parsed.order
            if engine.policies[seat].kind == pkExternal:
              resolved[seat].source = osExternal
              engine.externalAccepted[seat] = true
            resolved[seat].latencyMs = latency
            settled[seat] = true
          else:
            cause = "parse_error"
            detail = "no usable order field"
        except CatchableError as failure:
          cause = "parse_error"
          detail = failure.msg
      if cause.len > 0:
        engine.addRecord(%*{
          "k": "fallback", "turn": turnIndex, "seat": ord(seat),
          "attempt": attempt, "cause": cause,
          "detail": clipRunes(detail, MaxDetailRunes)
        })
        for call in calls:
          if call.seat == reply.seat:
            retry.add call
    calls = retry
    inc attempt

  for call in calls:
    # Two consecutive failures: the seat plays `porter` this turn.
    let seat = Seat(call.seat and 1)
    resolved[seat] = engine.fallbackFor(sim, seat, turnIndex)
    settled[seat] = true

  for seat in Seat:
    if not settled[seat]:
      resolved[seat] = engine.fallbackFor(sim, seat, turnIndex)
    resolved[seat].turn = int32(turnIndex)
    engine.previous[seat] = resolved[seat]
    engine.hasPrevious[seat] = true
    case resolved[seat].source
    of osLlm: inc sim.stats[seat].llmTurns
    of osFallback: inc sim.stats[seat].fallbackTurns
    of osExternal: discard
    of osScripted: discard
    # The record is the ONE source: the server writes it to the replay AND
    # folds it back through `applyRecord`, which is what INSTALLS the order.
    engine.addRecord(orderJson(sim, seat, resolved[seat]))

  # AFTER both seats' messages were composed, not before: the seat view's
  # `damage_last_turn` is `sim.damage` now minus `sim.damage` at the previous
  # turn boundary.
  engine.damageAtTurnStart = sim.damage
