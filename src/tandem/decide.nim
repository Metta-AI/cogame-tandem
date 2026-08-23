## The turn engine: one decision every 48 ticks, BOTH seats issued as ONE
## parallel batch, two bounded attempts, then the scripted fallback.
##
## Timing (docs/RULES.md §Budget):
##   inter-batch wall floor      4.5 s   (config minBatchSpacingMs)
##   attempt 1 batch deadline    4.5 s   (config attempt1Ms)
##   retry batch deadline        2.0 s   (config retryMs)
##   outer monotonic turn cap    7.0 s   (config turnBudgetMs)
## curly's transport timeout is whole seconds and a batch in flight cannot be
## interrupted, so the per-attempt allowance is FLOORED to whole seconds before
## it is handed over: 4 s + 2 s = 6 s realised worst case, inside the 7 s cap.
## 50 turns x 7.0 s = 350 s against a 720 s budget, with a 660 s engine stop.
##
## The inter-batch floor is not padding: the Bedrock sidecar caps 30 requests
## per minute PER EPISODE, and 2 requests per 4.5 s = 26.7 rpm, safely under it
## (raid round 2, 2026-08-23). The wait is a bounded sleep.
##
## Seats are NEVER queried sequentially — this is a simultaneous-decision game.
## The transport is injected as a `BatchFn` so tests/test_engine.nim can hand in
## a fake that records each call's in-flight window and assert the two windows
## intersect.

import
  std/[json, monotimes, os, strutils, times],
  curly,
  sim, orders, baselines, llm

const SystemPrompt* = """You are one of two cogs carrying a couch through a warehouse obstacle course.
You and your partner are gripped to opposite ends of the same rigid couch: you
hold one handle, your partner holds the other. The couch moves according to the
SUM of the two forces you apply, and it TURNS according to the difference. If you
both push the same way it slides; if you disagree it spins into a wall.
THERE IS NO COMMUNICATION CHANNEL. You cannot talk to your partner and your
partner never sees anything you write. The only information you get about your
partner is the force you feel through your own handle ("strain") and where their
end of the couch is. Read the strain: it tells you whether to lead or to yield.
Every 2 seconds you set your carry parameters for the next 2 seconds. A
deterministic controller executes them at 24 Hz.
The couch is 2.20 m long and 0.90 m wide. Doorways are between 1.05 m and 2.20 m
wide; the last one is 1.05 m. Scraping a wall and slamming into one both damage
the couch; if the strain in your hands stays too high for too long you drop it,
which costs 2 seconds and a chunk of condition. Your score is the SAME as your
partner's and comes half from delivery time and half from the couch's condition.
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"note":"<=160 chars",
 "drive":[x,y],    // direction to push, metres frame, each in [-1,1]; magnitude ignored
 "effort":0..1,    // how hard you push along drive (1 = your full 600 N)
 "yield":0..1,     // how much of the force you FEEL you push along with
                   // (1 = pure follower, 0 = ignore your partner completely)
 "twist":-1..1,    // rotate the couch: +1 counter-clockwise, -1 clockwise, 0 none
 "brace":0..1,     // plant your feet: halves your push, raises your grip limit
 "say":"<=48 chars"}   // spectators only; your partner NEVER sees this"""

type
  BatchCall* = object
    seat*: int
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
    prompt*: string            ## never recorded, never echoed.
    baseline*: string
    label*: string
    connected*: bool

  TurnEngine* = ref object
    client*: LlmClient
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

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc userMessage*(
  engine: TurnEngine,
  sim: SimServer,
  seat: Seat,
  turn: int
): string =
  operatorBlock(engine.policies[seat].prompt) &
    $engine.seatViewJson(sim, seat, turn)

# --------------------------------------------------------------------------
# The transport
# --------------------------------------------------------------------------

proc curlyBatch*(client: LlmClient): BatchFn =
  ## The production transport: ONE `curly.makeRequests` call per attempt, so
  ## BOTH seats are in flight together. curly's timeout is whole seconds and
  ## nothing interrupts a batch already in flight, so the caller rounds the
  ## allowance DOWN (floor, with a one-second minimum) before handing it over.
  result = proc (calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
      {.closure, gcsafe.} =
    result = @[]
    if calls.len == 0:
      return
    var batch: RequestBatch
    for call in calls:
      let request = client.requestFor(call.system, call.user)
      batch.post(request.url, request.headers, request.body, $call.seat)
    let responses = client.curl.makeRequests(batch, max(1, timeoutSeconds))
    for i, call in calls:
      var reply = BatchReply(seat: call.seat)
      if i >= responses.len:
        reply.error = "no response"
        result.add(reply)
        continue
      let (response, error) = responses[i]
      if error.len > 0:
        reply.error = error
      else:
        try:
          reply.text = client.completionText(response.code, response.body)
          reply.ok = true
        except CatchableError as failure:
          reply.error = failure.msg
      result.add(reply)

# --------------------------------------------------------------------------
# The turn
# --------------------------------------------------------------------------

proc newTurnEngine*(client: LlmClient, batch: BatchFn): TurnEngine =
  result = TurnEngine(client: client, batch: batch, guardTurn: -1)
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
  engine.damageAtTurnStart = sim.damage
  let
    deadline = getMonoTime() + initDuration(
      milliseconds = max(1, sim.config.turnBudgetMs))
    budget = sim.config.wallClockBudgetSeconds
    perTurn = (sim.config.turnBudgetMs + 999) div 1000

  # Budget guard: switch the LLM off for the rest of the episode rather than
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
    if policy.kind == pkScripted:
      resolved[seat] = sim.baselineOrder(seat, policy.baseline, turnIndex)
      settled[seat] = true
    elif engine.llmOff or engine.batch.isNil or
        (not engine.client.isNil and engine.client.disabled):
      # A nil CLIENT with a live batch is the test seam (tests/test_engine.nim
      # injects a fake transport); a nil BATCH is the real no-credentials path.
      resolved[seat] = engine.fallbackFor(sim, seat, turnIndex)
      settled[seat] = true
      let rejected =
        not engine.client.isNil and engine.client.transport != ltNone
      let cause =
        if engine.llmOff: "budget_guard"
        elif rejected: "transport_error"
        else: "no_credentials"
      let detail =
        if rejected: "credentials rejected; the client is disabled for the " &
          "rest of the episode"
        else: ""
      engine.addRecord(%*{
        "k": "fallback", "turn": turnIndex, "seat": ord(seat),
        "attempt": 1, "cause": cause,
        "detail": clipRunes(detail, MaxDetailRunes)
      })
    else:
      calls.add BatchCall(
        seat: ord(seat),
        system: SystemPrompt,
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
      # FLOOR, not ceiling: curly's timeout is whole seconds and a batch in
      # flight is not interruptible, so rounding 2000 ms up to 2 s is fine but
      # rounding 4500 ms up to 5 s would let the attempt run past the turn
      # budget the outer deadline is supposed to enforce.
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
          let payload = extractJsonObject(reply.text)
          let parsed = parseOrder(payload, engine.previous[seat],
            engine.hasPrevious[seat], sim.porterOrder(seat, turnIndex),
            turnIndex)
          if parsed.usable:
            resolved[seat] = parsed.order
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
    of osScripted: discard
    # The record is the ONE source: the server writes it to the replay AND
    # folds it back through `applyRecord`, which is what INSTALLS the order.
    engine.addRecord(orderJson(sim, seat, resolved[seat]))
