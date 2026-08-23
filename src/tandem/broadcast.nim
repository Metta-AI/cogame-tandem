## Replay broadcast state channel.
##
## Three jobs:
##
## 1. `applyRecord` folds a replay chat record back into the sim. For tandem
##    this is LOAD-BEARING, not cosmetic: an `order` record's quantised `q`
##    integers are INSTALLED into `sim.activeOrder`, which `gameHash` mixes.
##    The live server writes each record and folds it back through this same
##    function, so the live sim and the replay install bit-identical integers
##    and the control layer compiles bit-identical forces. Everything else it
##    touches (the feed) is outside the hash.
## 2. `stepEvents` derives the beat events from state deltas ONE SIM STEP AT A
##    TIME, accumulated by the caller across a playback frame, so attribution
##    stays exact even at 16x. Kept from ctf; the vocabulary is tandem's.
## 3. `buildStateJson` assembles the broadcast chrome frame, keeping ctf's key
##    names (`t, mt, ph, pl, sp, mx, st, lp, sk, ff, en, mm, bs, teams, roster,
##    events, lead, beats, lulls, over, hold`) so `chrome_common.js` runs
##    unmodified against tandem values.

import
  std/[json, strutils],
  sim, orders, roster, global

type
  BroadcastTracker* = object
    ## Per-server snapshot used to diff one sim step against the previous one.
    initialized: bool
    prevTick: int
    prevPhase: GamePhase
    damage: int32
    drops: int32
    doorsCleared: int32
    impacts: int32
    lastDropTick: int32
    lastDoorTick: int32
    lastImpactTick: int32
    lastRegripTick: int32
    turn: int

proc initBroadcastTracker*(): BroadcastTracker =
  result.prevPhase = Lobby
  result.lastDropTick = -1
  result.lastDoorTick = -1
  result.lastImpactTick = -1
  result.lastRegripTick = -1
  result.turn = -1

proc snapshot(tracker: var BroadcastTracker, sim: SimServer) =
  tracker.damage = sim.damage
  tracker.drops = sim.drops
  tracker.doorsCleared = sim.doorsCleared
  tracker.impacts = sim.impacts
  tracker.lastDropTick = sim.lastDropTick
  tracker.lastDoorTick = sim.lastDoorTick
  tracker.lastImpactTick = sim.lastImpactTick
  tracker.lastRegripTick = sim.lastRegripTick
  tracker.prevTick = sim.tickCount
  tracker.prevPhase = sim.phase
  tracker.turn = sim.currentTurn()
  tracker.initialized = true

proc resync*(tracker: var BroadcastTracker, sim: SimServer) =
  ## Snapshots without emitting events, after a seek/loop/skip. The next
  ## `stepEvents` then diffs against this frame, so no phantom beats fire.
  tracker.snapshot(sim)

proc doorWidthCm(sim: SimServer, index: int32): int =
  if index >= 0 and index < int32(sim.course.doorways.len):
    int(sim.course.doorways[index].width div 10_000)
  else:
    0

proc stepEvents*(
  sim: SimServer,
  tracker: var BroadcastTracker,
  events: JsonNode
) =
  ## Appends the beat events produced by the transition from the tracker's last
  ## snapshot to the current sim tick, then advances the tracker. `doorway`,
  ## `impact` (>= 20 points), `drop`, `wrecked`, `delivered` and `gameover` are
  ## BEATS: scrubber markers. `scrape` is throttled by the sim to at most one
  ## per disc per 6 ticks.
  if not tracker.initialized:
    tracker.snapshot(sim)
    return
  let tick = sim.tickCount

  if sim.phase != tracker.prevPhase:
    events.add(%*{"t": tick, "k": "phase",
      "phase": ($sim.phase).toLowerAscii})
    if sim.phase == GameOver:
      events.add(%*{
        "t": tick,
        "k": "gameover",
        "winner": "",
        "draw": false,
        "reason": reasonText(sim.endReason),
        "endRule": endRuleText(sim.endRule),
        "delivered": sim.delivered(),
        "score": sim.jointScore()
      })
    elif sim.phase == Delivered:
      events.add(%*{"t": tick, "k": "delivered",
        "ticks": int(sim.deliveryTick)})

  if sim.doorsCleared > tracker.doorsCleared:
    events.add(%*{"t": tick, "k": "doorway",
      "n": int(sim.doorsCleared),
      "cm": doorWidthCm(sim, sim.doorsCleared - 1)})
  if sim.drops > tracker.drops and sim.lastDropTick != tracker.lastDropTick:
    events.add(%*{"t": tick, "k": "drop",
      "team": (if sim.slip[0] >= sim.slip[1]: "cobalt" else: "rust")})
  if sim.impacts > tracker.impacts and
      sim.lastImpactTick != tracker.lastImpactTick:
    events.add(%*{"t": tick, "k": "impact",
      "dmg": int(max(0'i32, sim.damage - tracker.damage))})
  if sim.lastRegripTick >= 0 and sim.lastRegripTick != tracker.lastRegripTick:
    events.add(%*{"t": tick, "k": "regrip"})
  if sim.damage >= int32(sim.config.damageCap) and
      tracker.damage < int32(sim.config.damageCap):
    events.add(%*{"t": tick, "k": "wrecked"})
  if sim.damage > tracker.damage and sim.impacts == tracker.impacts:
    events.add(%*{"t": tick, "k": "scrape",
      "dmg": int(sim.damage - tracker.damage)})
  if sim.phase == Carrying and sim.currentTurn() != tracker.turn and
      tracker.turn >= 0:
    events.add(%*{"t": tick, "k": "turn_end", "turn": tracker.turn})
  for seat in Seat:
    let limit = sim.gripLimitOf(seat)
    if int64(sim.strainMagnitude(seat)) * 100 >=
        int64(limit) * int64(StrainWarnPct) and tick mod 12 == 0:
      events.add(%*{"t": tick, "k": "strain_warn", "team": seatText(seat)})

  tracker.snapshot(sim)

# --------------------------------------------------------------------------
# Replay chat records -> the sim
# --------------------------------------------------------------------------

proc applyRecord*(sim: var SimServer, text: string) =
  ## Folds ONE replay chat record back into the sim. This is the single place
  ## an `order` is installed into hashed state and the single place the feed is
  ## written, so a live broadcast and a replay tell exactly the same story AND
  ## compile exactly the same forces.
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject:
    return
  let kind = node{"k"}.getStr()
  let seatIndex = node{"seat"}.getInt(-1)
  case kind
  of "register":
    if seatIndex in 0 ..< SeatCount:
      let seat = Seat(seatIndex and 1)
      for i in 0 ..< sim.players.len:
        if sim.players[i].seat == seat:
          sim.players[i].policyLabel = node{"policy"}.getStr()
          sim.players[i].policyKind =
            if node{"kind"}.getStr() == "llm": pkLlm else: pkScripted
          sim.players[i].baseline = node{"baseline"}.getStr()
          sim.players[i].registered = true
      sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "register",
        seat: int32(seatIndex),
        text: seatAlias(seat) & ": " & node{"kind"}.getStr() & " policy")
  of "order":
    if seatIndex notin 0 ..< SeatCount:
      return
    let seat = Seat(seatIndex and 1)
    let parsed = orderFromRecord(node)
    if parsed.ok:
      sim.installOrder(seat, parsed.order)
    let note = parsed.order.note
    if note.len > 0:
      sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "note",
        seat: int32(seatIndex), text: seatAlias(seat) & ": " & note)
    let say = parsed.order.say
    if say.len > 0:
      sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "say",
        seat: int32(seatIndex), text: seatAlias(seat) & ": " & say)
  of "fallback":
    sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "fallback",
      seat: int32(seatIndex),
      text: "seat fell back (" & node{"cause"}.getStr() & ")")
  of "budget_guard":
    sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "fallback",
      seat: -1, text: "budget guard: scripted for the rest of the carry")
  else:
    discard
  while sim.feed.len > 64:
    sim.feed.delete(0)

# --------------------------------------------------------------------------
# The chrome frame
# --------------------------------------------------------------------------

proc seatPoliciesJson(sim: SimServer, seat: Seat): JsonNode =
  ## The policy identities on one handle. REAL names, SPECTATOR side only —
  ## the board labels and the LLM view never carry them.
  result = newJArray()
  for player in sim.players:
    if player.seat == seat and player.address.len > 0:
      result.add(%policyName(player.address))
  if result.len == 0:
    let slot = ord(seat)
    if slot < sim.config.slots.len and sim.config.slots[slot].name.len > 0:
      result.add(%sim.config.slots[slot].name)

proc seatStateJson(sim: SimServer, seat: Seat): JsonNode =
  ## One carrier's scorebug state. `teams.<side>` carries
  ## {strain, load, headroom, drops, blame, policies} in place of ctf's
  ## {lives, flag, carrier, prog}.
  let
    strain = sim.strainMagnitude(seat)
    limit = max(1'i32, sim.gripLimitOf(seat))
  %*{
    "strain": int(strain div 1000),
    "limit": int(limit div 1000),
    "load": int(clamp((int64(strain) * 100) div int64(limit), 0'i64, 200'i64)),
    "headroom": int(clamp(100 - (int64(strain) * 100) div int64(limit),
      0'i64, 100'i64)),
    "slip": int(clamp(int(sim.slip[ord(seat)]) * 100 div
      int(SlipDropThreshold), 0, 100)),
    "drops": int(sim.drops),
    "blame": int(sim.stats[seat].blame),
    "policies": sim.seatPoliciesJson(seat)
  }

proc rosterJson(sim: SimServer): JsonNode =
  ## One entry per CONNECTION (two), keyed by stable join slot. The chrome
  ## reads `name`/`pol` for the scorebug headline; the board never does.
  result = newJArray()
  for player in sim.players:
    result.add(%*{
      "s": int(player.joinOrder),
      "team": seatText(player.seat),
      "name": player.address,
      "pol": policyName(player.address),
      "kind": policyKindText(player.policyKind),
      "alive": true
    })

proc feedJson(sim: SimServer): JsonNode =
  result = newJArray()
  for line in sim.feed:
    result.add(%*{
      "t": int(line.tick), "k": line.kind,
      "team": (if line.seat >= 0: seatText(Seat(line.seat and 1)) else: ""),
      "text": line.text
    })

proc buildStateJson*(
  sim: SimServer,
  events: JsonNode,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int,
  povSlot: int,
  leadSeries: seq[seq[int]] = @[],
  startTick: int = 0,
  endHoldSeconds: int = 0,
  includeFpMap: bool = false,
  skipLulls: bool = false,
  fastForwarding: bool = false,
  lullSpans: seq[array[2, int]] = @[],
  beatEvents: JsonNode = nil
): string =
  ## Assembles the broadcast chrome frame. Board-derived STATE (condition,
  ## progress, roster, verdict) is always present, so even a frame reached by a
  ## seek hydrates the scorebug and end card with no events.
  var teams = newJObject()
  for seat in Seat:
    teams[seatText(seat)] = sim.seatStateJson(seat)

  var nextDoor = newJNull()
  if sim.doorsCleared < int32(sim.course.doorways.len):
    let door = sim.course.doorways[sim.doorsCleared]
    nextDoor = %*{
      "cm": int(door.width div 10_000),
      "n": int(sim.doorsCleared) + 1,
      "dist_m": round2(float(distI(door.cx - sim.posX, door.cy - sim.posY)) /
        1_000_000.0)}

  var state = %*{
    "t": sim.tickCount,
    "mt": sim.effectiveMaxTicks(),
    "ph": ($sim.phase).toLowerAscii,
    "lob": sim.lobbyStartSecondsRemaining(),
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    "bs": boardRenderScaleFor(MapWidth, MapHeight),
    "pov": povSlot,
    "turn": sim.currentTurn(),
    "turns": sim.turnCount(),
    "cond": sim.conditionPermille(),
    "dmg": int(sim.damage),
    "prog": int(sim.bestProgressPermille),
    "par": sim.parTicks(),
    "doors": [int(sim.doorsCleared), sim.course.doorways.len],
    "nextDoor": nextDoor,
    "teams": teams,
    "roster": sim.rosterJson(),
    "feed": sim.feedJson(),
    "events": (if events.isNil: newJArray() else: events)
  }

  # The full-timeline condition curve (sent ONCE per HUD viewer) so the
  # momentum graph draws its whole-timeline shape immediately instead of
  # accumulating to the playhead. ONE series, so chrome_common draws a single
  # paper-white line rather than a two-sided tug of war.
  if leadSeries.len > 0:
    var points = newJArray()
    for point in leadSeries:
      var row = newJArray()
      for value in point:
        row.add(%value)
      points.add(row)
    state["lead"] = %*{"teams": ["condition"], "pts": points}

  if not beatEvents.isNil and beatEvents.len > 0:
    state["beats"] = beatEvents

  if lullSpans.len > 0:
    var spans = newJArray()
    for span in lullSpans:
      spans.add(%*[span[0], span[1]])
    state["lulls"] = spans

  # The end card is STATE, not an event: present on every game-over frame so a
  # viewer who seeks straight to the end still sees the verdict.
  if sim.phase == GameOver:
    var names = newJArray()
    var strainPeak = newJArray()
    var blame = newJArray()
    for seat in Seat:
      names.add(%sim.seatName(seat))
      strainPeak.add(%int(sim.stats[seat].strainPeak div 1000))
      blame.add(%int(sim.stats[seat].blame))
    state["over"] = %*{
      "winner": "",
      "draw": false,
      "reason": reasonText(sim.endReason),
      "endRule": endRuleText(sim.endRule),
      "delivered": sim.delivered(),
      "score": sim.jointScore(),
      "cond": sim.conditionPermille(),
      "prog": int(sim.bestProgressPermille),
      "ticks": (if sim.delivered(): int(sim.deliveryTick) else: sim.tickCount),
      "par": sim.parTicks(),
      "drops": int(sim.drops),
      "impacts": int(sim.impacts),
      "scrapeTicks": int(sim.scrapeTicks),
      "strainPeak": strainPeak,
      "blame": blame,
      "names": names
    }
    if endHoldSeconds > 0:
      state["hold"] = %endHoldSeconds
  discard includeFpMap
  $state
