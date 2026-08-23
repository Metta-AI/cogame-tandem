## AN END-TO-END EPISODE WRITING A REPLAY: the artifacts, the codec, the hash
## chain, the strict-UTF-8 summary and the record vocabulary.

import std/[json, os, osproc, strutils, unicode]
import lib/helpers
import tandem/[replays, replay_runtime]

proc recordEpisode(path: string, seed = 4417231, maxTicks = 900): SimServer =
  ## A full scripted-vs-scripted episode through the REAL writer, the REAL
  ## record path and the REAL control layer. Deliberately carries a non-ASCII
  ## `say` and a non-ASCII policy label so the UTF-8 path is real.
  var config = testConfig(seed = seed, maxTicks = maxTicks)
  config.slots[0].name = "d\u00e4veey"
  var sim = seatedSim(config)
  var writer = openReplayWriter(path, config.configJson(sim.course))
  writer.lastMasks = newSeq[uint8](SeatCount)
  const ZeroMasks: array[SeatCount, uint8] = [0'u8, 0'u8]

  proc write(sim: var SimServer, writer: var ReplayWriter, text: string) =
    let record = capRecord(text)
    writer.writeChat(tickTime(sim.tickCount), 0, record)
    sim.applyRecord(record)

  for seat in Seat:
    sim.write(writer, $ %*{
      "k": "register", "seat": ord(seat), "alias": seatAlias(seat),
      "policy": "sc\u00e8ne-" & seatAlias(seat), "kind": "scripted",
      "baseline": (if seat == Cobalt: "porter" else: "mule")})
  writer.writeJoin(tickTime(0), 0, "d\u00e4veey", 0, "t0")
  writer.writeJoin(tickTime(0), 1, "rust-policy", 1, "t1")
  var guard = 0
  while sim.phase != GameOver and guard < maxTicks * 3 + 4000:
    inc guard
    if sim.carrying():
      let elapsed = sim.tickCount - sim.gameStartTick
      if not (sim.hasOrder[0] and sim.hasOrder[1]) or
          elapsed mod sim.turnTicks() == 0:
        let turn = elapsed div sim.turnTicks()
        for seat in Seat:
          var order = sim.baselineOrder(seat,
            (if seat == Cobalt: "porter" else: "mule"), turn)
          order.say = "\u00e9asy does it"
          sim.write(writer, $orderJson(sim, seat, order))
    writer.writeInputFrameMasks(tickTime(sim.tickCount), ZeroMasks)
    sim.stepSim()
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
  sim.write(writer, sim.resultRecordJson())
  writer.closeReplayWriter()
  sim

proc episodeWritesEverything() =
  let path = tempPath("episode.replay")
  removeFile(path)
  let sim = recordEpisode(path)
  doAssert fileExists(path), "no replay was written"
  doAssert getFileSize(path) > 4000, "the replay is suspiciously small"
  let results = parseJson(sim.playerResultsJson())
  doAssert results["names"].len == 2
  doAssert results["scores"][0].getFloat() == results["scores"][1].getFloat(),
    "the two seats did not receive the identical score"
  doAssert results["reason"].getStr() in
    ["complete", "deadline", "fault"]
  doAssert results["endRule"].getStr() in
    ["delivered", "wrecked", "out_of_time", "wall_clock", "sim_fault",
     "host_error"]
  report "an end-to-end episode writes results and a COWLDTDM replay"

proc replayReproducesEveryHash() =
  let path = tempPath("hashes.replay")
  removeFile(path)
  let recorded = recordEpisode(path)
  let data = parseReplayBytes(readFile(path))
  doAssert data.hashes.len > 100, "the hash chain is too short"
  var runtime = initReplayRuntime(data, mismatchQuit = true,
    gameEventLoggingEnabled = false)
  var sim = move(runtime.sim)
  var player = move(runtime.player)
  var steps = 0
  while sim.tickCount < player.replayMaxTick() and steps < 100_000:
    player.stepReplay(sim)
    inc steps
  doAssert player.hashMismatchTick == -1,
    "the replay diverged at tick " & $player.hashMismatchTick
  doAssert sim.damage == recorded.damage,
    "replay damage " & $sim.damage & " vs recorded " & $recorded.damage
  doAssert sim.bestProgressPermille == recorded.bestProgressPermille
  doAssert sim.deliveryTick == recorded.deliveryTick
  removeFile(path)
  report "re-simulating from the config and the order log reproduces every hash"

proc summaryIsStrictUtf8() =
  let path = tempPath("summary.replay")
  removeFile(path)
  discard recordEpisode(path)
  let script = repoPath("tools/replay_summary.py")
  let (output, code) = execCmdEx("python3 " & quoteShell(script) & " " &
    quoteShell(path))
  doAssert code == 0, "replay_summary.py exited " & $code & ":\n" & output
  doAssert isValidUtf8(output), "the summary is not valid UTF-8"
  let node = parseJson(output)
  doAssert node["protocol"].getStr() == "tandem/v1",
    "protocol is " & node["protocol"].getStr()
  doAssert node["gameVersion"].getStr() == GameVersion
  doAssert node["seed"].getInt() == 4417231
  doAssert node["tickCount"].getInt() > 100
  doAssert node["orders"].len > 0, "the summary found no order records"
  doAssert node["results"]["reason"].getStr().len > 0
  removeFile(path)
  report "tools/replay_summary.py emits strict-UTF-8 JSON with the orders"

proc configJsonCarriesTheCourse() =
  let path = tempPath("config.replay")
  removeFile(path)
  discard recordEpisode(path)
  let data = parseReplayBytes(readFile(path))
  doAssert isValidUtf8(data.configJson), "the config JSON is not valid UTF-8"
  let node = parseJson(data.configJson)
  doAssert node["seed"].getInt() == 4417231
  doAssert node.hasKey("course"), "the replay header carries no course"
  doAssert node["course"]["walls"].len > 10
  doAssert node["course"]["routeX"].len >= 3
  doAssert node["num_agents"].getInt() == 2
  let back = recordedCourse(data.configJson)
  doAssert back.digest == generateCourse(4417231).digest
  removeFile(path)
  report "the replay header carries the seed and the fully expanded course"

proc recordVocabulary() =
  let path = tempPath("records.replay")
  removeFile(path)
  discard recordEpisode(path)
  let data = parseReplayBytes(readFile(path))
  var kinds: seq[string] = @[]
  var perSeat = [0, 0]
  var results = 0
  var registers = 0
  for chat in data.chats:
    doAssert chat.message.runeLen <= MaxOrderRecordRunes,
      "a record is " & $chat.message.runeLen & " runes"
    doAssert isValidUtf8(chat.message), "a record is not valid UTF-8"
    let node = parseJson(chat.message)
    let k = node["k"].getStr()
    if k notin kinds:
      kinds.add(k)
    case k
    of "order": inc perSeat[node["seat"].getInt()]
    of "result": inc results
    of "register": inc registers
    else: discard
  doAssert "order" in kinds and "result" in kinds and "register" in kinds,
    "the record vocabulary is " & $kinds
  doAssert results == 1, "expected exactly one result record, got " & $results
  doAssert registers == 2
  doAssert perSeat[0] > 5 and perSeat[0] == perSeat[1],
    "orders per seat: " & $perSeat
  removeFile(path)
  report "the replay carries register, order and exactly one result record"

proc scrapesAndDoorways() =
  ## The stream contains at least one scrape and one doorway beat.
  proc kindsOf(cobalt, rust: string): seq[string] =
    var config = testConfig(seed = 4417231, maxTicks = 1800)
    var sim = seatedSim(config)
    var tracker = initBroadcastTracker()
    while sim.phase != GameOver and sim.tickCount < 6000:
      if sim.carrying():
        let elapsed = sim.tickCount - sim.gameStartTick
        if not (sim.hasOrder[0] and sim.hasOrder[1]) or
            elapsed mod sim.turnTicks() == 0:
          for seat in Seat:
            let name = if seat == Cobalt: cobalt else: rust
            sim.applyRecord(capRecord($orderJson(sim, seat,
              sim.baselineOrder(seat, name, elapsed div sim.turnTicks()))))
      sim.stepSim()
      let events = newJArray()
      sim.stepEvents(tracker, events)
      for event in events:
        let k = event["k"].getStr()
        if k notin result:
          result.add(k)
  let rough = kindsOf("mule", "mule")
  # §Tests 8 asks for at least one SCRAPE, not "a scrape or an impact": an
  # `or` passes on a run that only ever slams into walls, and the scrape path
  # (throttled one per disc per 6 ticks) is the one that could silently stop
  # firing.
  doAssert "scrape" in rough, "a full mule run produced no scrape: " & $rough
  doAssert "impact" in rough, "a full mule run produced no impact: " & $rough
  let clean = kindsOf("porter", "porter")
  doAssert "scrape" in clean, "a full porter run produced no scrape: " & $clean
  doAssert "doorway" in clean, "no doorway was ever cleared: " & $clean
  let kinds = clean
  doAssert "gameover" in kinds
  report "the derived event stream carries scrapes, doorways and game over"

when isMainModule:
  episodeWritesEverything()
  replayReproducesEveryHash()
  summaryIsStrictUtf8()
  configJsonCarriesTheCourse()
  recordVocabulary()
  scrapesAndDoorways()
  echo "test_replay: the replay is self-sufficient and reproduces every hash"
