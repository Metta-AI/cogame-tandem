## The manifest is a CONTRACT, not documentation: the ladder schedules zero
## episodes without `num_agents`, and the certifier rejects an unknown key in
## either the config or the results.

import std/[json, os, sets, strutils]
import lib/helpers

proc numAgentsEverywhere() =
  let m = manifest()
  doAssert m["variants"].len == 2, "expected two variants"
  for variant in m["variants"]:
    let cfg = variant["game_config"]
    doAssert cfg["num_agents"].getInt() == 2,
      "variant " & variant["id"].getStr() & " has num_agents " &
        $cfg["num_agents"].getInt()
    doAssert cfg["players"].len == 2 and cfg["slots"].len == 2
    doAssert variant["description"].getStr().len > 0,
      "variant " & variant["id"].getStr() & " has no description"
    doAssert cfg["wallClockBudgetSeconds"].getInt() <= 720,
      "a variant may not sit outside 60 % of episodeTimeoutSeconds"
    doAssert cfg["attempt1Ms"].getInt() + cfg["retryMs"].getInt() <=
      cfg["turnBudgetMs"].getInt(),
      "attempt1Ms + retryMs must fit inside turnBudgetMs"
  let cert = m["certification"]
  doAssert cert["game_config"]["num_agents"].getInt() == 2,
    "the certification fixture has no num_agents = 2"
  doAssert cert["players"].len == 2
  doAssert cert["game_config"]["players"].len == 2
  doAssert cert["game_config"]["slots"].len == 2
  report "num_agents is 2 in every variant and in the cert fixture"

proc everyDeclaredPlayerIsSeated() =
  let m = manifest()
  var declared = initHashSet[string]()
  for entry in m["player"]:
    declared.incl(entry["id"].getStr())
    doAssert entry["type"].getStr() == "player"
    doAssert entry["name"].getStr().len > 0
    doAssert entry["description"].getStr().len > 0
    doAssert entry["image"].getStr() == "{{TANDEM_IMAGE}}"
    doAssert entry["run"][0].getStr() == "/bin/tandem-player"
  var seated = initHashSet[string]()
  for slot in m["certification"]["players"]:
    seated.incl(slot["player_id"].getStr())
  for id in declared:
    doAssert id in seated,
      "player[" & id & "] has no certification slot (cert would fail " &
        "players_missing)"
  report "every declared player occupies a certification slot"

proc resultsSchemaMatchesTheDocument() =
  let m = manifest()
  var sim = carryingSim(testConfig(maxTicks = 120))
  while sim.phase != GameOver and sim.tickCount < 900:
    sim.stepSim()
  let produced = parseJson(sim.playerResultsJson())
  let schema = m["game"]["results_schema"]
  doAssert not schema["additionalProperties"].getBool()
  var declared = initHashSet[string]()
  for key in schema["properties"].keys:
    declared.incl(key)
  var written = initHashSet[string]()
  for key in produced.keys:
    written.incl(key)
  doAssert declared == written,
    "results_schema declares " & $declared.len & " keys, the document writes " &
      $written.len & "; difference: " & $(declared - written) & " / " &
      $(written - declared)
  for required in schema["required"]:
    doAssert required.getStr() in written,
      "a required results key is never written: " & required.getStr()
  let reasons = schema["properties"]["reason"]["enum"]
  doAssert reasons.len == 3
  var reasonSet = initHashSet[string]()
  for r in reasons:
    reasonSet.incl(r.getStr())
  doAssert reasonSet == toHashSet(["complete", "deadline", "fault"])
  var ruleSet = initHashSet[string]()
  for r in schema["properties"]["endRule"]["enum"]:
    ruleSet.incl(r.getStr())
  doAssert ruleSet == toHashSet(["delivered", "wrecked", "out_of_time",
    "wall_clock", "sim_fault", "host_error"])
  for key in ["scores", "win", "names", "aliases", "policyKinds",
              "strainPeakNewtons", "blame", "llmTurns", "fallbackTurns"]:
    doAssert schema["properties"][key]["minItems"].getInt() == 2 and
      schema["properties"][key]["maxItems"].getInt() == 2,
      key & " is not pinned to exactly two entries"
  report "results_schema matches playerResultsJson key for key"

proc configSchemaCoversEveryReadField() =
  ## Every key `sim_config.update` reads must be settable, and nothing else.
  let m = manifest()
  let schema = m["game"]["config_schema"]
  doAssert not schema["additionalProperties"].getBool()
  var declared = initHashSet[string]()
  for key in schema["properties"].keys:
    declared.incl(key)
  let source = sourceText(repoPath("src/tandem/sim_config.nim"))
  let raw = repoFile("src/tandem/sim_config.nim")
  discard source
  for key in ["seed", "speed", "num_agents", "minPlayers", "startWaitTicks",
              "lobbyJoinTimeoutTicks", "gameOverTicks", "maxTicks", "maxGames",
              "turnTicks", "turnBudgetMs", "attempt1Ms", "retryMs",
              "minBatchSpacingMs", "wallClockBudgetSeconds", "regripTicks",
              "fastMode", "showPlayerLabels", "closedRoster", "model",
              "maxOutputTokens", "maxSeatForceMilliNewtons",
              "gripLimitMilliNewtons", "damageCap", "slots", "players",
              "tokens"]:
    doAssert key in declared, "config_schema does not declare " & key
    doAssert ("\"" & key & "\"") in raw,
      "sim_config.nim never reads " & key
  doAssert "tokens" in declared and "players" in declared
  for required in schema["required"]:
    doAssert required.getStr() in declared
  report "config_schema covers every field sim_config.update reads"

proc docsAndProtocols() =
  let m = manifest()
  let protocols = m["game"]["protocols"]
  for key in ["player", "global"]:
    doAssert protocols.hasKey(key), "game.protocols is missing " & key
    doAssert protocols[key]["type"].getStr() == "text"
    doAssert protocols[key]["value"].getStr().len > 400,
      "the " & key & " protocol text is too thin"
  let docs = m["game"]["docs"]
  doAssert docs["readme"]["type"].getStr() == "text"
  doAssert docs["readme"]["value"].getStr().len > 400
  doAssert docs["pages"].len == 3
  var ids: seq[string] = @[]
  for page in docs["pages"]:
    ids.add(page["id"].getStr())
    doAssert page["title"].getStr().len > 0
    doAssert page["content"]["type"].getStr() == "text"
    doAssert page["content"]["value"].getStr().len > 400,
      "docs page " & page["id"].getStr() & " is empty"
  doAssert ids == @["rules.md", "protocol.md", "carrying.md"]
  report "game.docs and game.protocols are non-empty TEXT, both protocols"

proc uploadContract() =
  let m = manifest()
  doAssert m.hasKey("$schema")
  doAssert m["episode_timeout_minutes"].getInt() == 20
  doAssert m["tags"].len >= 3
  let runnable = m["game"]["runnable"]
  doAssert runnable["type"].getStr() == "game"
  doAssert runnable["image"].getStr() == "{{TANDEM_IMAGE}}"
  doAssert runnable["run"][0].getStr() == "/bin/tandem"
  doAssert runnable["env"]["ANTHROPIC_API_KEY_URI"].getStr() ==
    "secret://coworld/tandem/anthropic_api_key",
    "the game runnable does not receive the anthropic secret; every league " &
      "episode would play scripted"
  doAssert runnable["source_url"].getStr().startsWith("https://github.com/")
  doAssert m["game"]["replay_viewer"]["bundle"].getStr() ==
    "static-replay-viewer"
  report "the 0.1.42 upload contract is satisfied"

proc composeAndImageAgree() =
  let compose = repoFile("compose.yaml")
  doAssert "  tandem:" in compose,
    "the compose SERVICE must be named for the coworld: the manifest " &
      "placeholder is derived from it"
  doAssert "image: coworld-tandem:latest" in compose
  doAssert "platform: linux/amd64" in compose
  doAssert "network: host" in compose
  let ci = repoFile(".github/workflows/ci.yml")
  doAssert "IMAGE: coworld-tandem" in ci
  doAssert "SLUG: tandem" in ci
  report "compose.yaml, the manifest placeholder and ci.yml agree"

proc policiesAreTheCanonicalSet() =
  let policies = parseJson(repoFile("tools/ci/policies.json"))
  doAssert policies.len == 4, "expected four policies"
  var prompts = 0
  var scripted: seq[string] = @[]
  var champion2 = false
  for entry in policies:
    doAssert entry["run"].getStr() == "/bin/tandem-player"
    doAssert entry["name"].getStr().startsWith("tandem-")
    if entry["env"].hasKey("PLAYER_PROMPT"):
      inc prompts
      doAssert entry["env"]["PLAYER_PROMPT"].getStr().len > 200,
        entry["name"].getStr() & " has a thin prompt"
      if entry.hasKey("player"):
        champion2 = true
        doAssert entry["player"].getStr() ==
          "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    else:
      scripted.add(entry["env"]["PLAYER_SCRIPTED"].getStr())
  doAssert prompts == 2, "both champions must be PLAYER_PROMPT policies"
  doAssert champion2, "champion #2 must carry the daveey-1 player id"
  doAssert scripted == @["porter", "mule"],
    "the fillers are " & $scripted
  doAssert policies[0]["env"]["PLAYER_PROMPT"].getStr() !=
    policies[1]["env"]["PLAYER_PROMPT"].getStr(),
    "identical prompts dedupe to the same policy version"
  report "the policy set is two LLM champions and two scripted fillers"

when isMainModule:
  numAgentsEverywhere()
  everyDeclaredPlayerIsSeated()
  resultsSchemaMatchesTheDocument()
  configSchemaCoversEveryReadField()
  docsAndProtocols()
  uploadContract()
  composeAndImageAgree()
  policiesAreTheCanonicalSet()
  echo "test_manifest: the manifest is the contract the platform reads"
