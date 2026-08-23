## The entrypoint contract: a clean message and a non-zero exit on a bad
## config, seed randomisation when unpinned, and both binaries present in the
## image recipe.

import std/[json, os, strutils]
import lib/helpers

proc badConfigIsACleanError() =
  var config = defaultGameConfig()
  var raised = false
  try:
    config.update("not json at all")
  except TandemError as error:
    raised = true
    doAssert "config is not valid JSON" in error.msg,
      "the parse error is not quotable: " & error.msg
  doAssert raised, "a malformed config did not raise"
  raised = false
  try:
    config.update("[1, 2, 3]")
  except TandemError:
    raised = true
  doAssert raised, "a non-object config did not raise"
  report "a malformed config raises a clean, quotable error"

proc illegalConfigsAreRefused() =
  for body in [
      """{"num_agents": 3}""",
      """{"maxTicks": 0}""",
      """{"turnTicks": 0}""",
      """{"turnBudgetMs": 100, "attempt1Ms": 4500, "retryMs": 2000}""",
      """{"wallClockBudgetSeconds": 0}""",
      """{"minPlayers": 5}""",
      """{"damageCap": 0}"""]:
    var config = defaultGameConfig()
    var raised = false
    try:
      config.update(body)
    except TandemError:
      raised = true
    doAssert raised, "an illegal config was accepted: " & body
  report "every illegal config is refused before a socket opens"

proc seedIsHonouredWhenPinned() =
  var config = defaultGameConfig()
  config.update("""{"seed": 991}""")
  doAssert config.seed == 991
  let a = initSimServer(config)
  let b = initSimServer(config)
  doAssert a.courseDigest == b.courseDigest
  var other = defaultGameConfig()
  other.update("""{"seed": 992}""")
  let c = initSimServer(other)
  doAssert c.courseDigest != a.courseDigest,
    "two different seeds generated the same warehouse"
  report "a pinned seed is honoured and drives the whole course"

proc seedIsRandomisedWhenUnpinned() =
  ## The entrypoint's sentinel: a config carrying the compiled-in default (or
  ## no seed at all) is treated as unpinned, so a public fixed seed can never
  ## make the warehouse pre-computable.
  let source = repoFile("src/tandem.nim")
  doAssert "LegacyFixedSeed = DefaultSeed" in source
  doAssert "proc seedPinned" in source
  doAssert "config.seed = randomSeed()" in source
  doAssert "seed not pinned; randomized" in source
  var config = defaultGameConfig()
  doAssert config.seed == DefaultSeed
  report "an unpinned seed is randomised at the entrypoint"

proc bothEntrypointsAreBuilt() =
  let dockerfile = repoFile("Dockerfile")
  doAssert "--out:tandem src/tandem.nim" in dockerfile,
    "the game binary is not built"
  doAssert "--out:tandem-player src/tandem_player.nim" in dockerfile,
    "the player binary is not built"
  doAssert "COPY --from=build /workspace/tandem/tandem /bin/tandem" in dockerfile
  doAssert "COPY --from=build /workspace/tandem/tandem-player /bin/tandem-player" in
    dockerfile
  doAssert "CMD [\"/bin/tandem\"]" in dockerfile
  doAssert "COPY --from=build /workspace/tandem/data ./data" in dockerfile,
    "the runtime stage does not carry data/ (the cog rigs live there)"
  doAssert "COPY --from=build /workspace/tandem/client ./client" in dockerfile
  report "one image, two entrypoints, and the art travels with them"

proc playerSelectsItsPolicyByEnv() =
  let source = repoFile("src/tandem_player.nim")
  doAssert "PLAYER_PROMPT" in source and "PLAYER_SCRIPTED" in source
  doAssert "\"porter\", \"mule\"" in source,
    "the player does not accept both baselines"
  doAssert "else: \"porter\"" in source,
    "a seat with neither env var must default to porter"
  doAssert "except CatchableError" in source,
    "the receive loop is not wrapped; whisky RAISES on a close frame"
  report "one image, env-switched: PLAYER_PROMPT vs PLAYER_SCRIPTED"

when isMainModule:
  badConfigIsACleanError()
  illegalConfigsAreRefused()
  seedIsHonouredWhenPinned()
  seedIsRandomisedWhenUnpinned()
  bothEntrypointsAreBuilt()
  playerSelectsItsPolicyByEnv()
  echo "test_startup: the entrypoints refuse a bad config and build as one image"
