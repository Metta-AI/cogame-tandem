## The turn loop against a fake LLM client: one PARALLEL batch per turn, the
## inter-batch floor, the deadlines, the budget guard, the endings and the
## no-show path.

import std/[json, monotimes, os, strutils, times]
import lib/helpers
import tandem/[decide, llm, server]

type Window = object
  startMs, endMs: int64

var windows: seq[Window]
var callLog: seq[seq[int]]

proc since(start: MonoTime): int64 =
  (getMonoTime() - start).inMilliseconds

proc fakeBatch(reply: string, delayMs = 0, fail = false): BatchFn =
  let origin = getMonoTime()
  result = proc (calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
      {.closure, gcsafe.} =
    {.gcsafe.}:
      var seats: seq[int] = @[]
      for call in calls:
        seats.add(call.seat)
      callLog.add(seats)
      let started = since(origin)
      if delayMs > 0:
        sleep(min(delayMs, timeoutSeconds * 1000))
      windows.add(Window(startMs: started, endMs: since(origin)))
    for call in calls:
      if fail:
        result.add BatchReply(seat: call.seat, error: "Timeout was reached")
      else:
        result.add BatchReply(seat: call.seat, ok: true, text: reply)

proc newEngine(batch: BatchFn): TurnEngine =
  result = newTurnEngine(nil, batch)
  for seat in Seat:
    result.policies[seat] = SeatPolicy(kind: pkLlm, prompt: "carry it",
      label: "test-llm", connected: true)

proc applyRecords(engine: TurnEngine, sim: var SimServer) =
  for record in engine.records:
    sim.applyRecord(record)

proc bothSeatsInOneBatch() =
  windows.setLen(0)
  callLog.setLen(0)
  var sim = carryingSim(testConfig())
  let engine = newEngine(fakeBatch(
    """{"drive":[1,0],"effort":0.5,"yield":0.2,"twist":0,"brace":0.1}""",
    delayMs = 60))
  engine.turn(sim, 0, 0)
  doAssert callLog.len == 1, "the seats were queried in " & $callLog.len &
    " batches, not one"
  doAssert callLog[0].len == 2, "the batch carried " & $callLog[0].len &
    " calls"
  doAssert callLog[0][0] != callLog[0][1], "both calls were the same seat"
  # In-flight windows for the two seats are the SAME window by construction:
  # one `makeRequests` call carries both.
  doAssert windows.len == 1
  doAssert windows[0].endMs >= windows[0].startMs
  engine.applyRecords(sim)
  doAssert sim.hasOrder[0] and sim.hasOrder[1],
    "the batch did not install both orders"
  doAssert sim.activeOrder[0].source == osLlm
  report "both seats' calls go out as ONE parallel batch"

proc interBatchFloor() =
  windows.setLen(0)
  callLog.setLen(0)
  var config = testConfig()
  config.minBatchSpacingMs = 400
  var sim = carryingSim(config)
  let engine = newEngine(fakeBatch(
    """{"drive":[1,0],"effort":0.5}""", delayMs = 5))
  let started = getMonoTime()
  engine.turn(sim, 0, 0)
  engine.applyRecords(sim)
  engine.turn(sim, 1, 0)
  engine.applyRecords(sim)
  let elapsed = (getMonoTime() - started).inMilliseconds
  doAssert elapsed >= 380,
    "two turns took " & $elapsed & " ms; the 400 ms floor was not applied"
  report "the inter-batch floor keeps consecutive batches apart"

proc retryThenFallback() =
  windows.setLen(0)
  callLog.setLen(0)
  var sim = carryingSim(testConfig())
  let engine = newEngine(fakeBatch("", fail = true))
  engine.turn(sim, 4, 0)
  doAssert callLog.len == 2,
    "a failing batch was attempted " & $callLog.len & " times, not twice"
  var fallbacks = 0
  var orders = 0
  for record in engine.records:
    let node = parseJson(record)
    case node["k"].getStr()
    of "fallback":
      inc fallbacks
      doAssert node["cause"].getStr() == "timeout",
        "a curl deadline was recorded as " & node["cause"].getStr()
    of "order":
      inc orders
      doAssert node["source"].getStr() == "fallback"
    else: discard
  doAssert fallbacks == 4, "expected four fallback records, got " & $fallbacks
  doAssert orders == 2
  engine.applyRecords(sim)
  doAssert sim.activeOrder[0].source == osFallback
  report "two consecutive failures fall back to porter with a record"

proc perTurnBudget() =
  windows.setLen(0)
  callLog.setLen(0)
  var config = testConfig()
  config.turnBudgetMs = 900
  config.attempt1Ms = 600
  config.retryMs = 200
  var sim = carryingSim(config)
  let engine = newEngine(fakeBatch("", delayMs = 5000, fail = true))
  let started = getMonoTime()
  engine.turn(sim, 2, 0)
  let elapsed = (getMonoTime() - started).inMilliseconds
  doAssert elapsed < 4000,
    "a hung client held the turn for " & $elapsed & " ms"
  report "the per-turn budget bounds a hung client"

proc budgetGuardEndsComplete() =
  var config = testConfig(maxTicks = 240)
  config.wallClockBudgetSeconds = 10
  var sim = carryingSim(config)
  let engine = newEngine(fakeBatch("""{"drive":[1,0],"effort":0.5}"""))
  engine.turn(sim, 0, 9)
  doAssert engine.llmOff, "the budget guard did not fire"
  var guarded = false
  for record in engine.records:
    if parseJson(record)["k"].getStr() == "budget_guard":
      guarded = true
  doAssert guarded, "no budget_guard record was written"
  engine.applyRecords(sim)
  while sim.phase != GameOver and sim.tickCount < 3000:
    sim.stepSim()
  doAssert sim.endReason == reasonComplete,
    "the guarded run ended " & reasonText(sim.endReason)
  report "the budget guard switches to scripted and the run ends complete"

proc wallClockStopIsDeadline() =
  var sim = carryingSim(testConfig())
  sim.wallClockStop()
  doAssert sim.endReason == reasonDeadline and sim.endRule == erWallClock
  report "the wall-clock stop yields deadline/wall_clock"

proc simFaultIsFault() =
  var sim = carryingSim(testConfig())
  sim.damage = -5
  sim.stepSim()
  doAssert sim.endReason == reasonFault and sim.endRule == erSimFault,
    "a tripped invariant ended " & reasonText(sim.endReason) & "/" &
      endRuleText(sim.endRule)
  report "a tripped invariant yields fault/sim_fault"

proc hostErrorIsFault() =
  var sim = carryingSim(testConfig())
  sim.hostErrorStop()
  doAssert sim.endReason == reasonFault and sim.endRule == erHostError
  report "an unexpected exception yields fault/host_error"

proc disconnectedSeatPlaysPorter() =
  var sim = carryingSim(testConfig())
  let engine = newTurnEngine(nil, nil)
  engine.policies[Cobalt] = SeatPolicy(kind: pkLlm, prompt: "x", connected: false)
  engine.policies[Rust] = SeatPolicy(kind: pkScripted, baseline: "porter")
  engine.turn(sim, 0, 0)
  engine.applyRecords(sim)
  doAssert sim.hasOrder[0] and sim.hasOrder[1],
    "a disconnected seat left a cog unactuated"
  var causes: seq[string] = @[]
  for record in engine.records:
    let node = parseJson(record)
    if node["k"].getStr() == "fallback":
      causes.add(node["cause"].getStr())
  doAssert causes == @["no_credentials"],
    "the no-transport fallback recorded " & $causes
  # And it revives: a live batch on the next turn is used.
  engine.batch = fakeBatch("""{"drive":[0,1],"effort":0.9}""")
  engine.turn(sim, 1, 0)
  engine.applyRecords(sim)
  doAssert sim.activeOrder[0].source == osLlm, "the seat did not revive"
  report "a seat with no transport plays porter and revives"

proc noShowIsDeclared() =
  let path = tempPath("player-failure.json")
  removeFile(path)
  putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & path)
  declarePlayerFailure(1, "never joined")
  delEnv("COGAME_PLAYER_FAILURE_URI")
  doAssert fileExists(path), "no player-failure artifact was written"
  let node = parseJson(readFile(path))
  doAssert node["failed_policy_index"].getInt() == 1
  doAssert node["message"].getStr().len > 0
  removeFile(path)
  # And the run still reaches a normal ending with one seat missing.
  var config = testConfig(maxTicks = 480)
  config.minPlayers = 2
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  discard sim.addPlayer("only-one", 0, "t0")
  sim.startGame()
  while sim.phase != GameOver and sim.tickCount < 4000:
    if sim.carrying():
      let elapsed = sim.tickCount - sim.gameStartTick
      if not (sim.hasOrder[0] and sim.hasOrder[1]) or
          elapsed mod sim.turnTicks() == 0:
        for seat in Seat:
          sim.applyRecord(capRecord($orderJson(sim, seat,
            sim.porterOrder(seat, elapsed div sim.turnTicks()))))
    sim.stepSim()
  doAssert sim.phase == GameOver, "the one-seat run never ended"
  doAssert sim.endReason == reasonComplete,
    "the one-seat run ended " & reasonText(sim.endReason)
  report "a lobby no-show is declared and the run still ends normally"

when isMainModule:
  bothSeatsInOneBatch()
  interBatchFloor()
  retryThenFallback()
  perTurnBudget()
  budgetGuardEndsComplete()
  wallClockStopIsDeadline()
  simFaultIsFault()
  hostErrorIsFault()
  disconnectedSeatPlaysPorter()
  noShowIsDeclared()
  echo "test_engine: the turn loop is parallel, bounded and degrade-never-hang"
