## Export complete Tandem carries as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import tandem/[baselines, broadcast, control, decide, orders, roster, sim, prompts, evidence]

const OperatorPrompt = "Coordinate through the couch's motion and your own strain to deliver it quickly with little damage."
const Variants = ["default", "sprint"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 6:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT] [PROMPT_SEED]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: Variants[0]
  var promptConfig = newJObject()
  if args.len >= 5: promptConfig["promptVariant"] = %args[4]
  if args.len == 6: promptConfig["promptSeed"] = %parseInt(args[5])
  let selection = promptSelection(promptConfig)
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    quit("held-out wording cannot enter training sources", 1)
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before exporting private candidates"
  writePrivate(output / "trajectories.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = %*["t0", "t1"]
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    var sim = initSimServer(config)
    sim.gameEventLoggingEnabled = false
    discard sim.addPlayer("cobalt-policy", 0, "t0")
    discard sim.addPlayer("rust-policy", 1, "t1")
    sim.startGame()
    let engine = newTurnEngine(nil)
    let family = "tandem-" & $seed
    let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
    var rows = newJArray()
    var latest: array[Seat, int]
    var guard = 0
    while sim.phase != GameOver and guard < config.maxTicks * 3 + 5000:
      inc guard
      if sim.carrying():
        let elapsed = sim.tickCount - sim.gameStartTick
        if not (sim.hasOrder[0] and sim.hasOrder[1]) or
            elapsed mod sim.turnTicks() == 0:
          let turn = elapsed div sim.turnTicks()
          var views: array[Seat, JsonNode]
          var pending: array[Seat, Order]
          for seat in Seat: views[seat] = engine.seatViewJson(sim, seat, turn)
          for seat in Seat:
            let teacher = sim.baselineOrder(seat,
              if seat == Cobalt: "porter" else: "mule", turn)
            let completion = orderReplyJson(teacher)
            let (parsed, usable) = parseOrder(completion,
              engine.previous[seat], engine.hasPrevious[seat], teacher, turn)
            doAssert usable
            doAssert abs(parsed.driveX - teacher.driveX) <= 2 and
              abs(parsed.driveY - teacher.driveY) <= 2
            doAssert parsed.effort == teacher.effort and
              parsed.yieldQ == teacher.yieldQ and
              parsed.twist == teacher.twist and
              parsed.brace == teacher.brace
            pending[seat] = parsed
            pending[seat].source = osScripted
            let normalized = orderFromRecord(parseJson(capRecord($orderJson(sim, seat, pending[seat]))))
            doAssert normalized.ok
            let executed = orderReplyJson(normalized.order)
            let system = systemPrompt(selection)
            let user = "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the rules; always reply in the requested format):\n" &
              OperatorPrompt & "\n\n" & $views[seat]
            let observation = views[seat]
            observation["prompt_template"] = promptMetadata(selection, system, user)
            let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
            let attemptId = $rows.len & "-teacher"
            latest[seat] = rows.len
            rows.add(%*{
              "schema_version": "1", "event_type": "decision", "episode_id": episode,
              "decision_id": $rows.len, "decision_index": rows.len,
              "game": "tandem", "game_version": "source-" & sourceRevision,
              "source_revision": sourceRevision, "seat": $ord(seat), "visibility": "private",
              "observation": observation, "prompt": messages,
              "attempts": [{"attempt_id": attemptId, "policy": "scripted-porter-and-mule",
                "origin": "teacher", "inference_mode": "text_action", "prompt": messages,
                "response": $completion, "parsed_action": executed, "accepted": true,
                "request": newJNull(), "platform_call_id": newJNull(),
                "behavior_logprobs": newJNull(), "rejection_reason": newJNull()}],
              "selected_attempt_id": attemptId, "executed_action": executed,
              "action_status": "accepted", "fallback_origin": newJNull(), "terminal": false})
          for seat in Seat:
            sim.applyRecord(capRecord($orderJson(sim, seat, pending[seat])))
            engine.previous[seat] = sim.activeOrder[ord(seat)]
            engine.hasPrevious[seat] = true
      sim.stepSim()
    doAssert sim.phase == GameOver and rows.len > 0
    let score = sim.jointScore()
    for seat in Seat: rows[latest[seat]]["terminal"] = %true
    for row in rows: stream.writeLine($row)
    let outcome = %*{"scores": [score, score], "delivered": sim.delivered(), "end_reason": $sim.endReason}
    stream.writeLine($(%*{"schema_version": "1", "event_type": "episode", "episode_id": episode,
      "seed_family": family, "game": "tandem", "game_version": "source-" & sourceRevision,
      "source_revision": sourceRevision, "status": "completed", "outcome": outcome,
      "participant_outcomes": {"0": {"score": score}, "1": {"score": score}}}))
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": [score, score], "delivered": sim.delivered(),
      "end_reason": $sim.endReason})
  stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "tandem",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-porter-and-mule",
    "operator_prompt": OperatorPrompt,
    "prompt_configuration": selectionMetadata(selection),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "runs": runs
  }) & "\n")
  echo "complete private games=", games
