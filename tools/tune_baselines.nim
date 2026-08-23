## The grid harness the porter/mule tuning constants were swept with.
##
## Every tuning constant in `src/tandem/baselines.nim` is `{.intdefine.}`, so
## one point of the grid is one recompile: `-d:TandemMuleEffort=200`. This tool
## is both halves of that sweep.
##
## **Evaluate the constants compiled into this binary** — with no `-d:` flags
## that is exactly the shipped configuration:
##
## ```
## nim r -d:release --path:src tools/tune_baselines.nim --eval
## ```
##
## It plays `porter x porter`, `porter x mule` and `mule x mule` over the
## committed seed list (`baselines.TuningSeeds`, the same twenty seeds
## `tests/test_baselines.nim` pins) through the REAL control layer and the REAL
## record path, and prints one JSON line per pairing: delivery rate, mean
## score, mean damage, mean ticks, mean progress and drops.
##
## **Sweep** — the driver expands the cartesian product of the `--sweep`
## flags, recompiles this file once per point with those `-d:` defines, runs
## each build in `--eval` mode and prints the table sorted by
## `porter x porter` mean score:
##
## ```
## nim r -d:release --path:src tools/tune_baselines.nim \
##   --sweep TandemMuleEffort=64,140,255 --sweep TandemTwistGain=3,5,8
## ```
##
## No infrastructure beyond a Nim compiler: no docker, no network, no fixture.
## `docs/BASELINE-TUNING.md` records the sweeps the shipped constants came out
## of, with the harness output pasted in.

import
  std/[algorithm, json, os, osproc, strformat, strutils],
  tandem/[baselines, broadcast, control, orders, roster, sim]

type
  PairingResult = object
    name: string
    delivered: int
    episodes: int
    meanScore: float
    meanDamage: int
    meanTicks: int
    meanProgress: int
    drops: int

proc runEpisode(seed: int, cobalt, rust: string): tuple[
    delivered: bool, damage, ticks, progress, drops: int, score: float] =
  ## One scripted episode, driven exactly the way the server drives one: the
  ## order is serialized to its replay chat record and installed by
  ## `applyRecord`, so what the sweep measures is what a real run does.
  var config = defaultGameConfig()
  config.seed = seed
  config.minPlayers = 2
  config.startWaitTicks = 1
  config.gameOverTicks = 2
  config.minBatchSpacingMs = 0
  config.slots = @[
    PlayerSlotConfig(name: "cobalt-policy", token: "t0", alias: "Cobalt"),
    PlayerSlotConfig(name: "rust-policy", token: "t1", alias: "Rust")
  ]
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  discard sim.addPlayer("cobalt-policy", 0, "t0")
  discard sim.addPlayer("rust-policy", 1, "t1")
  var guard = 0
  while sim.phase != GameOver and guard < config.maxTicks * 3 + 5000:
    inc guard
    if sim.carrying():
      let elapsed = sim.tickCount - sim.gameStartTick
      if not (sim.hasOrder[0] and sim.hasOrder[1]) or
          elapsed mod sim.turnTicks() == 0:
        let turn = elapsed div sim.turnTicks()
        for seat in Seat:
          let name = if seat == Cobalt: cobalt else: rust
          sim.applyRecord(capRecord($orderJson(sim, seat,
            sim.baselineOrder(seat, name, turn))))
    sim.stepSim()
  (sim.delivered(), int(sim.damage), sim.tickCount,
   int(sim.bestProgressPermille), int(sim.drops), sim.jointScore())

proc evaluate(cobalt, rust: string): PairingResult =
  result.name = cobalt & "x" & rust
  result.episodes = TuningSeeds.len
  var
    score = 0.0
    damage = 0
    ticks = 0
    progress = 0
  for seed in TuningSeeds:
    let run = runEpisode(seed, cobalt, rust)
    if run.delivered:
      inc result.delivered
    score += run.score
    damage += run.damage
    ticks += run.ticks
    progress += run.progress
    result.drops += run.drops
  result.meanScore = score / float(result.episodes)
  result.meanDamage = damage div result.episodes
  result.meanTicks = ticks div result.episodes
  result.meanProgress = progress div result.episodes

proc constantsJson(): JsonNode =
  ## Every swept constant as this binary was compiled with it. The `--eval`
  ## line is self-describing, so a pasted sweep log names its own grid point.
  %*{
    "TandemLookahead": Lookahead,
    "TandemDoorNear": DoorNear,
    "TandemOpenEffort": OpenEffort,
    "TandemOpenYield": OpenYield,
    "TandemConflictYield": ConflictYield,
    "TandemLeadYield": LeadYield,
    "TandemFollowYield": FollowYield,
    "TandemConflictEffort": ConflictEffort,
    "TandemBraceHigh": BraceHigh,
    "TandemStrainBrace": StrainBraceMilliNewtons,
    "TandemTwistDead": TwistDeadBrads,
    "TandemTwistGain": TwistGain,
    "TandemTwistDamp": TwistDamp,
    "TandemSpinDead": SpinDeadQ,
    "TandemRamp": RampUm,
    "TandemIdleEffort": IdleEffort,
    "TandemMuleEffort": MuleEffort,
    "TandemPivotBox": PivotBoxUm,
    "TandemCommitHyst": CommitHyst,
    "TandemStuckReach": StuckReachUm,
    "TandemCellLead": CellLead,
    "TandemConflictCos": ConflictCos,
    "TandemAlignBrads": AlignBrads,
    "TandemAlignRange": AlignRange,
    "TandemTurnEffort": TurnEffort,
    "TandemEscapeEffort": EscapeEffort,
    "TandemStuckSpeed": StuckSpeedUm,
    "TandemBackOff": BackOff,
    "TandemDoorApproach": DoorApproach
  }

proc evalMode() =
  ## One grid point: the pairings that decide whether a configuration ships.
  var pairings = newJArray()
  for (cobalt, rust) in [("porter", "porter"), ("porter", "mule"),
      ("mule", "mule")]:
    let outcome = evaluate(cobalt, rust)
    pairings.add(%*{
      "pairing": outcome.name,
      "delivered": outcome.delivered,
      "episodes": outcome.episodes,
      "mean_score": round6(outcome.meanScore),
      "mean_damage": outcome.meanDamage,
      "mean_ticks": outcome.meanTicks,
      "mean_progress_permille": outcome.meanProgress,
      "drops": outcome.drops
    })
  echo $(%*{"constants": constantsJson(), "pairings": pairings})

proc parseSweep(spec: string): tuple[name: string, values: seq[string]] =
  let parts = spec.split('=', 1)
  if parts.len != 2 or parts[0].len == 0 or parts[1].len == 0:
    quit("--sweep wants NAME=v1,v2,... (got `" & spec & "`)", 1)
  result.name = parts[0].strip()
  for value in parts[1].split(','):
    let trimmed = value.strip()
    if trimmed.len == 0:
      continue
    discard parseInt(trimmed)     ## a define is an integer or nothing.
    result.values.add(trimmed)

proc points(axes: seq[tuple[name: string, values: seq[string]]]):
    seq[seq[string]] =
  ## The cartesian product, as `-d:NAME=VALUE` strings.
  result = @[newSeq[string]()]
  for axis in axes:
    var grown: seq[seq[string]] = @[]
    for prefix in result:
      for value in axis.values:
        grown.add(prefix & ("-d:" & axis.name & "=" & value))
    result = grown

proc sweepMode(axes: seq[tuple[name: string, values: seq[string]]]) =
  let nim = findExe("nim")
  if nim.len == 0:
    quit("tune_baselines: no `nim` on PATH; the sweep is a recompile per " &
      "grid point", 1)
  let
    source = currentSourcePath()
    workDir = getTempDir() / "tandem-tune"
  createDir(workDir)
  let grid = points(axes)
  echo "sweeping ", grid.len, " grid point(s) over ", TuningSeeds.len,
    " seeds each"
  var rows: seq[tuple[score: float, line: string]] = @[]
  for index, defines in grid:
    let binary = workDir / ("tune-" & $index)
    var argv = @["c", "--hints:off", "--verbosity:0", "-d:release",
      "--path:src", "-o:" & binary]
    argv.add(defines)
    argv.add(source)
    let build = execProcess(nim, args = argv, options = {poStdErrToStdOut})
    if not fileExists(binary):
      echo "  BUILD FAILED for ", defines.join(" "), "\n", build
      continue
    let output = execProcess(binary, args = ["--eval"], options = {})
    var report: JsonNode
    try:
      report = parseJson(output.strip().splitLines()[^1])
    except CatchableError as failure:
      echo "  UNREADABLE OUTPUT for ", defines.join(" "), ": ", failure.msg
      continue
    var
      headline = 0.0
      summary = ""
    for pairing in report["pairings"]:
      let name = pairing["pairing"].getStr()
      if name == "porterxporter":
        headline = pairing["mean_score"].getFloat()
      summary.add(&"{name} {pairing[\"delivered\"].getInt()}/" &
        &"{pairing[\"episodes\"].getInt()} " &
        &"score {pairing[\"mean_score\"].getFloat():.3f} " &
        &"dmg {pairing[\"mean_damage\"].getInt()} " &
        &"ticks {pairing[\"mean_ticks\"].getInt()} | ")
    let label = if defines.len == 0: "(shipped defaults)"
                else: defines.join(" ")
    rows.add((headline, &"{label:<44} {summary}"))
    echo "  ", rows[^1].line
  rows.sort(proc (a, b: tuple[score: float, line: string]): int =
    cmp(b.score, a.score))
  echo "\n=== sorted by porter x porter mean score ==="
  for row in rows:
    echo row.line

when isMainModule:
  var
    axes: seq[tuple[name: string, values: seq[string]]] = @[]
    doEval = false
    index = 1
  while index <= paramCount():
    case paramStr(index)
    of "--eval":
      doEval = true
    of "--sweep":
      inc index
      if index > paramCount():
        quit("--sweep wants NAME=v1,v2,...", 1)
      axes.add(parseSweep(paramStr(index)))
    of "--help", "-h":
      echo "usage: tune_baselines [--eval] [--sweep NAME=v1,v2,...]..."
      quit(0)
    else:
      quit("unknown argument `" & paramStr(index) & "`", 1)
    inc index
  if doEval or axes.len == 0:
    evalMode()
  else:
    sweepMode(axes)
