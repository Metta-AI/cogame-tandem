## The tandem game entrypoint. Seed randomisation happens HERE, before
## `config.update`, so every seed-derived draw (the whole course generator)
## follows the final seed — ctf's rule, kept verbatim.

import
  std/[json, os, sysrand],
  bitworld/runtime,
  tandem/sim,
  tandem/server

const LegacyFixedSeed = DefaultSeed
  ## The compiled-in default seed. Hosted variant configs pin it, so it
  ## doubles as the "nobody chose a seed" sentinel: a config carrying it (or no
  ## seed at all) gets a fresh random seed, because with a public fixed seed
  ## the whole warehouse would be pre-computable and the maps would stop being
  ## procedurally novel — which is the coworld's whole anti-collusion claim.

proc seedPinned(configJson: string): bool =
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed") and
      node["seed"].getInt != LegacyFixedSeed
  except CatchableError:
    false  ## config.update reports the real parse error.

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(TandemError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc stripUnpinnedSeed(configJson: string): string =
  if configJson.len == 0:
    return configJson
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("seed"):
      node.delete("seed")
    $node
  except CatchableError:
    configJson

proc echoStartupConfig(config: GameConfig, runtimeConfig: RuntimeConfig) =
  ## Prints the effective startup config. Never a token, never a prompt.
  echo "tandem config: host=", runtimeConfig.host,
    " port=", runtimeConfig.port,
    " seed=", config.seed,
    " num_agents=", config.numAgents,
    " minPlayers=", config.minPlayers,
    " maxTicks=", config.maxTicks,
    " turnTicks=", config.turnTicks,
    " turnBudgetMs=", config.turnBudgetMs,
    " minBatchSpacingMs=", config.minBatchSpacingMs,
    " wallClockBudgetSeconds=", config.wallClockBudgetSeconds,
    " fastMode=", config.fastMode

when isMainModule:
  var runtimeConfig: RuntimeConfig
  try:
    runtimeConfig = readRuntimeConfig()
  except CatchableError as error:
    quit("tandem: " & error.msg, 1)

  var config = defaultGameConfig()
  try:
    if seedPinned(runtimeConfig.config):
      config.update(runtimeConfig.config)
    else:
      config.seed = randomSeed()
      config.update(stripUnpinnedSeed(runtimeConfig.config))
      echo "seed not pinned; randomized"
  except CatchableError as error:
    # A clean message and a non-zero exit, never a traceback: the runner reads
    # this line, and tests/test_startup.nim pins it.
    quit("tandem: bad config: " & error.msg, 1)
  config.echoStartupConfig(runtimeConfig)

  let localReplayPath =
    if runtimeConfig.replayUri.len > 0:
      getTempDir() / ("tandem-replay-" & $getCurrentProcessId() & ".replay")
    else:
      ""
  let loadReplayPath =
    if runtimeConfig.replayMode:
      let path = getTempDir() / ("tandem-load-replay-" &
        $getCurrentProcessId() & ".replay")
      writeFile(path, runtimeConfig.replay)
      path
    else:
      ""

  echo "starting tandem on ", runtimeConfig.host, ":", runtimeConfig.port
  runServerLoop(
    runtimeConfig.host,
    runtimeConfig.port,
    config,
    localReplayPath,
    loadReplayPath,
    "",
    runtimeConfig
  )
