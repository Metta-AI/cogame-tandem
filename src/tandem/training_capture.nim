## Game-owned private carry decisions, quantised orders and post-tick hashes.
import std/[json, options]
import bitworld/decision_trajectory
import sim, roster, decide, prompts

type MatchCapture* = ref object
  trajectory*: DecisionTrajectory
  pending: bool
  startTick: int
  initialHash: uint64
  decisions: array[Seat, TurnDecision]
  hashes: seq[string]

proc newMatchCapture*(episodeId, version, revision: string, seed: int): MatchCapture =
  MatchCapture(trajectory: newDecisionTrajectory(episodeId, "tandem-" & $seed,
    "tandem", version, revision))

proc flushTurn*(capture: MatchCapture, endTick: int, terminal = false) =
  if not capture.pending: return
  doAssert capture.hashes.len == endTick - capture.startTick
  for seat in Seat:
    let issued = capture.decisions[seat]
    var observation = copy(issued.observation)
    observation["execution"] = %*{"start_tick": capture.startTick, "end_tick": endTick,
      "tick_hz": TargetFps, "control_encoding": "tandem-quantised-order",
      "order": issued.executedAction, "initial_hash": $capture.initialHash,
      "post_tick_hashes": capture.hashes}
    capture.trajectory.recordDecision($capture.startTick & "-" & $ord(seat), $ord(seat),
      observation, issued.attempts, issued.selectedAttemptId, issued.executedAction,
      issued.status, terminal, if issued.status == asFallback: some("engine-porter") else: none(string))
  capture.pending = false

proc beginTurn*(capture: MatchCapture, engine: TurnEngine, sim: SimServer,
    selection: PromptSelection) =
  capture.flushTurn(sim.tickCount)
  capture.pending = true
  capture.startTick = sim.tickCount
  capture.initialHash = sim.gameHash()
  capture.hashes = @[]
  capture.decisions = engine.decisions
  for seat in Seat:
    var metadata = newJArray()
    for attempt in capture.decisions[seat].attempts:
      if attempt.prompt.kind == JArray and attempt.prompt.len == 2:
        metadata.add(%*{"attempt_id": attempt.attemptId, "prompt_template": selection.promptMetadata(
          attempt.prompt[0]["content"].getStr(), attempt.prompt[1]["content"].getStr())})
    capture.decisions[seat].observation["prompt_attempts"] = metadata

proc recordTick*(capture: MatchCapture, sim: SimServer) =
  if capture.pending: capture.hashes.add($sim.gameHash())

proc finishMatch*(capture: MatchCapture, sim: SimServer) =
  capture.flushTurn(sim.tickCount, true)
  let results = parseJson(sim.playerResultsJson())
  results["engine_version"] = %GameVersion
  let reason = results["reason"].getStr()
  let status = if reason == "complete": esCompleted elif reason == "deadline": esTruncated else: esFailed
  capture.trajectory.finish(status, results, newJNull())
