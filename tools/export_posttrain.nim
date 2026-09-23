## Export complete Tandem carries as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import tandem/[baselines, broadcast, control, decide, orders, roster, sim]

const OperatorPrompt = "Coordinate through the couch's motion and your own strain to deliver it quickly with little damage."
const Variants = ["default", "sprint"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: Variants[0]
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
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
    let engine = newTurnEngine(nil, nil)
    for seat in Seat:
      engine.policies[seat].prompt = OperatorPrompt
    var rows: seq[string]
    var guard = 0
    while sim.phase != GameOver and guard < config.maxTicks * 3 + 5000:
      inc guard
      if sim.carrying():
        let elapsed = sim.tickCount - sim.gameStartTick
        if not (sim.hasOrder[0] and sim.hasOrder[1]) or
            elapsed mod sim.turnTicks() == 0:
          let turn = elapsed div sim.turnTicks()
          for seat in Seat:
            let teacher = sim.baselineOrder(seat,
              if seat == Cobalt: "porter" else: "mule", turn)
            let completion = %*{
              "note": teacher.note,
              "drive": [float(teacher.driveX) / 4096.0,
                        float(teacher.driveY) / 4096.0],
              "effort": float(teacher.effort) / 255.0,
              "yield": float(teacher.yieldQ) / 255.0,
              "twist": float(teacher.twist) / 255.0,
              "brace": float(teacher.brace) / 255.0,
              "say": teacher.say
            }
            let (parsed, usable) = parseOrder(completion,
              engine.previous[seat], engine.hasPrevious[seat], teacher, turn)
            doAssert usable
            doAssert abs(parsed.driveX - teacher.driveX) <= 2 and
              abs(parsed.driveY - teacher.driveY) <= 2
            doAssert parsed.effort == teacher.effort and
              parsed.yieldQ == teacher.yieldQ and
              parsed.twist == teacher.twist and
              parsed.brace == teacher.brace
            rows.add($(%*{
              "episode_id": "tandem-" & variant & "-" & $seed,
              "seed": "tandem-" & variant & "-" & $seed,
              "decision_id": rows.len,
              "prompt": [
                {"role": "system", "content": SystemPrompt},
                {"role": "user", "content": engine.userMessage(sim,
                  seat, turn)}
              ],
              "completion": [{"role": "assistant", "content": $completion}],
              "game": "tandem",
              "action_schema_revision": "tandem-carry-v1"
            }))
            var applied = parsed
            applied.source = osScripted
            sim.applyRecord(capRecord($orderJson(sim, seat, applied)))
            engine.previous[seat] = applied
            engine.hasPrevious[seat] = true
      sim.stepSim()
    doAssert sim.phase == GameOver and rows.len > 0
    let score = sim.jointScore()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": [score, score], "delivered": sim.delivered(),
      "end_reason": $sim.endReason})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "tandem",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-porter-and-mule",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
