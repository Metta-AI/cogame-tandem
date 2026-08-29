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
  var dmgs: seq[int] = @[]
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

proc beatsAreTheNotesBeats() =
  ## §Record vocabulary B: the scrubber's beat list is `doorway`, `impact`
  ## (>= 20 points), `drop`, `wrecked`, `delivered`, `gameover`. The sim emits
  ## an `impact` event from 8 points up (feed + sparks), so the precomputed
  ## list has to apply the 20-point floor itself — unfiltered, every 8-point
  ## nudge became a scrubber marker while the page filtered only the LIVE
  ## events, so the two lists disagreed.
  ##
  ## This fixture is chosen because it emits impacts on BOTH sides of the
  ## floor: 41 and 14 points. With the filter removed the 14 comes back and
  ## this assertion fires.
  let path = tempPath("beats.replay")
  removeFile(path)
  discard recordEpisode(path, seed = 606606, maxTicks = 2400)
  let data = parseReplayBytes(readFile(path))
  var runtime = initReplayRuntime(data, false, false)
  runtime.player.advanceReplayScan(int.high)
  var impacts = 0
  var kinds: seq[string] = @[]
  for beat in runtime.player.beatEvents:
    let kind = beat["k"].getStr()
    if kind notin kinds:
      kinds.add(kind)
    doAssert kind in BeatKinds, "`" & kind & "` is not a beat kind"
    if kind == "impact":
      inc impacts
      doAssert beat{"dmg"}.getInt() >= ImpactBeatDamage,
        "a " & $beat{"dmg"}.getInt() & "-point impact became a scrubber beat"
  doAssert impacts > 0, "the fixture emitted no impact beat at all: " & $kinds
  doAssert "gameover" in kinds, "the beat list has no game over: " & $kinds
  removeFile(path)
  report "the precomputed beat list is the note's beat list"

proc deliveryIsABeat() =
  ## §Record vocabulary B lists `delivered` among the BEATS, and the page has a
  ## `.beat-marker.delivered` rule plus a `case 'delivered'` banner arm for it.
  ## The sim enters `Delivered` in step 7 and finishes the game in step 10 of
  ## the SAME tick, and every caller derives events AFTER the whole tick, so a
  ## `phase == Delivered` reading is unreachable: the beat has to be derived
  ## from the delivery itself. A delivered episode must produce exactly one
  ## `delivered` event, on the frame that carries the delivery (the derived
  ## events of a tick are stamped with the frame tick, as every other kind is),
  ## ahead of that same frame's `gameover`.
  var config = testConfig(seed = 4417231, maxTicks = 2400)
  var sim = seatedSim(config)
  var tracker = initBroadcastTracker()
  var kinds: seq[string] = @[]
  var delivereds = 0
  var deliveredTick = -1
  var deliveredBeforeGameOver = false
  while sim.phase != GameOver and sim.tickCount < 8000:
    if sim.carrying():
      let elapsed = sim.tickCount - sim.gameStartTick
      if not (sim.hasOrder[0] and sim.hasOrder[1]) or
          elapsed mod sim.turnTicks() == 0:
        for seat in Seat:
          sim.applyRecord(capRecord($orderJson(sim, seat,
            sim.baselineOrder(seat, "porter", elapsed div sim.turnTicks()))))
    sim.stepSim()
    let events = newJArray()
    sim.stepEvents(tracker, events)
    var sawDelivered = false
    for event in events:
      let k = event["k"].getStr()
      if k notin kinds:
        kinds.add(k)
      if k == "delivered":
        inc delivereds
        sawDelivered = true
        deliveredTick = event["t"].getInt()
        doAssert event["ticks"].getInt() == int(sim.deliveryTick)
      if k == "gameover" and sawDelivered:
        deliveredBeforeGameOver = true
  doAssert sim.delivered(),
    "the porter x porter fixture no longer delivers: " & $sim.endRule
  doAssert delivereds == 1,
    "a delivered episode emitted " & $delivereds & " `delivered` events" &
      " (kinds: " & $kinds & ")"
  doAssert deliveredTick - int(sim.deliveryTick) in 0 .. 1,
    "the delivered beat is at tick " & $deliveredTick & ", delivery was at " &
      $sim.deliveryTick
  doAssert deliveredBeforeGameOver,
    "the delivered beat does not precede the game-over beat of its tick"
  doAssert "delivered" in BeatKinds,
    "`delivered` is not a scrubber beat kind"
  report "a delivery emits its `delivered` beat"

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

proc halfSpeedIsAReplayOnlyCrawl() =
  ## The fleet-wide 1/2x replay speed: command '5' selects
  ## ReplayHalfSpeedIndex, the chrome shows 0.5, and the step budget spends
  ## one tick every OTHER frame (halfPhase parity) outside a lull. Inside a
  ## lull with skip-lulls on, the boost still wins — half speed slows the
  ## ACTION, it does not re-slow the dead time the boost exists to skip.
  var replay = ReplayPlayer()
  replay.speedIndex = 0
  applySpeedCommand(replay.speedIndex, '5')
  doAssert replay.speedIndex == ReplayHalfSpeedIndex, "'5' must select 1/2x"
  doAssert replay.replayDisplaySpeed() == 0.5,
    "the chrome speed at 1/2x is 0.5, got " & $replay.replayDisplaySpeed()
  doAssert replay.replaySpeed() == 1,
    "the integer speed clamps to 1x at 1/2x (live loop safety)"
  replay.skipLulls = false
  replay.halfPhase = false
  doAssert replay.replayStepBudget(0) == 0, "even frame at 1/2x spends no tick"
  replay.halfPhase = true
  doAssert replay.replayStepBudget(0) == 1, "odd frame at 1/2x spends one tick"
  replay.skipLulls = true
  replay.lullSpans = @[[0, 10]]
  replay.halfPhase = false
  doAssert replay.replayStepBudget(0) == LullSpeedBoost,
    "the lull boost must survive half speed"
  applySpeedCommand(replay.speedIndex, '+')
  doAssert replay.speedIndex == 0, "'+' from 1/2x lands on 1x"
  applySpeedCommand(replay.speedIndex, '-')
  doAssert replay.speedIndex == ReplayHalfSpeedIndex, "'-' from 1x lands on 1/2x"
  applySpeedCommand(replay.speedIndex, '-')
  doAssert replay.speedIndex == ReplayHalfSpeedIndex, "1/2x is the floor"
  doAssert replay.replayDisplaySpeed() == 0.5
  report "1/2x is a replay-only crawl: '5', 0.5 on the wire, every other frame"

proc halfSpeedAdvancesEveryOtherFrame() =
  ## The parity is flipped by advanceReplayPlayback itself, so a REAL playback
  ## run at 1/2x covers half the ticks a 1x run of the same frame count does.
  let path = tempPath("halfspeed.replay")
  removeFile(path)
  discard recordEpisode(path)
  let data = parseReplayBytes(readFile(path))

  proc ticksOver(frames: int, command: char): int =
    var runtime = initReplayRuntime(data, mismatchQuit = false,
      gameEventLoggingEnabled = false)
    var sim = move(runtime.sim)
    var player = move(runtime.player)
    player.skipLulls = false
    player.looping = false
    applySpeedCommand(player.speedIndex, command)
    let startTick = sim.tickCount
    for _ in 0 ..< frames:
      player.advanceReplayPlayback(sim, proc () = discard, proc () = discard)
    sim.tickCount - startTick

  let full = ticksOver(40, '1')
  let half = ticksOver(40, '5')
  doAssert full == 40, "1x advanced " & $full & " ticks over 40 frames"
  doAssert half == 20, "1/2x advanced " & $half & " ticks over 40 frames"
  removeFile(path)
  report "40 playback frames spend 40 ticks at 1x and 20 at 1/2x"

when isMainModule:
  episodeWritesEverything()
  replayReproducesEveryHash()
  summaryIsStrictUtf8()
  configJsonCarriesTheCourse()
  recordVocabulary()
  beatsAreTheNotesBeats()
  deliveryIsABeat()
  scrapesAndDoorways()
  halfSpeedIsAReplayOnlyCrawl()
  halfSpeedAdvancesEveryOtherFrame()
  echo "test_replay: the replay is self-sufficient and reproduces every hash"
