## The replay codec wrapper: keyframes, sim (de)serialization, the incremental
## whole-match scan, lull spans, beat events, seek/speed/transport commands and
## `checkReplayHash`. Kept from ctf's `replays.nim` with TWO named edits and
## the magic/name/version swap.
##
## **Edit 1 — `serializeReplaySim`/`deserializeReplaySim` cover the new sim
## fields and EXCLUDE the course.** Keyframes are how the viewer seeks and the
## control layer reads the whole assembly state, so `pos`, `vel`, `headingQ`,
## `spin`, `damage`, `slip[]`, the felt strain, `bestProgressPermille`,
## `deliveryTick`, `phase`, `regripUntil` and both `activeOrder`s all ride in
## the keyframe (flatty writes `SimServer` positionally, so they do by
## construction). The `Course` is deliberately NOT written: it is static and
## already in the config JSON — ctf's own rule for static map bakes — so it is
## moved aside before the write and restored from the donor afterwards.
##
## **Edit 2 — the action log is the ORDER RECORDS, so no input record is ever
## written.** `lastMasks` is sized to the two seats and every mask stays zero,
## which keeps ctf's frame plumbing untouched while the recorded action log
## lives entirely in the `order` chat records. `stepReplay` therefore compiles
## both seats' forces with the SAME `control.stepSim` the live server runs —
## the control layer is inside tandem's determinism boundary — and the per-tick
## `gameHash` chain proves it derived the same pair.

import
  std/json,
  flatty,
  bitworld/spriteprotocol,
  bitworld/replays as replayCodec,
  broadcast, sim, control, roster

type
  ReplayKeyframe* = object
    tick*: int
    simBytes*: string
    joinIndex*: int
    leaveIndex*: int
    chatIndex*: int
    inputIndex*: int
    hashIndex*: int
    masks*: seq[uint8]
    lastAppliedMasks*: seq[uint8]
    hashValidationFailed*: bool
    hashMismatchTick*: int

  ReplayPlayer* = object
    data*: ReplayData
    joinIndex*: int
    leaveIndex*: int
    chatIndex*: int
    inputIndex*: int
    hashIndex*: int
    masks*: seq[uint8]
    lastAppliedMasks*: seq[uint8]
    playing*: bool
    looping*: bool
    speedIndex*: int
    mismatchQuit*: bool
    hashValidationFailed*: bool
    hashMismatchTick*: int
    keyframes*: seq[ReplayKeyframe]
    startTick*: int
      ## First tick the couch is actually being CARRIED. Playback auto-starts
      ## here, loops back here, and the scrubber is offset by it.
    leadSeries*: seq[seq[int]]
      ## [tick, conditionPermille] change-points across the WHOLE run, so the
      ## momentum graph draws the condition curve at once.
    endHoldFrames*: int
    skipLulls*: bool
    lullSpans*: seq[array[2, int]]
    beatEvents*: JsonNode
    scan: ReplayScan
    scanDone: bool

  ReplayScan* = ref object
    sim: SimServer
    builder: ReplayPlayer
    beatTracker: BroadcastTracker
    beatTicks: seq[int]
    lastCondition: seq[int]
    interval: int
    maxTick: int

export PlaybackSpeeds

const
  ReplayKeyframeTicks* = 100
  ReplayEndHoldSeconds* = 10
  LullLeadTicks* = 2 * ReplayFps
  MinLullTicks* = 6 * ReplayFps
  LullSpeedBoost* = 8
  MaxLullTicksPerFrame* = 64
  BeatKinds* = ["doorway", "impact", "drop", "wrecked", "delivered",
    "gameover"]
    ## The scrubber markers. `scrape` is deliberately absent: it is throttled
    ## to one per disc per 6 ticks and would still bury the real beats.
  ImpactBeatDamage* = 20
    ## ...and an `impact` is a beat only at 20 points or more (design note
    ## §Record vocabulary B, "`impact` (>= 20 points)"). The SIM emits the
    ## event from 8 points up, for the feed and the spark FX, so the filter
    ## belongs here, where the scrubber's list is built — the page already
    ## filters the LIVE events at the same number.
  LullBreakingKinds* = ["doorway", "impact", "drop", "regrip", "wrecked",
    "delivered", "gameover"]
  TandemReplayMagic* = "COWLDTDM"
  TandemReplayFormatVersion = 1'u16
  TandemReplaySpec = ReplaySpec(
    magic: TandemReplayMagic,
    formatVersion: TandemReplayFormatVersion,
    gameName: GameName,
    gameVersion: GameVersion,
    joinKind: rjkNameSlotToken,
    allowChat: true,
    allowCompressed: true,
    hashOrder: rhoStop
  )

export replayCodec

proc tickTime*(tick: int): uint32 =
  replayCodec.tickTime(tick, ReplayFps)

proc openReplayWriter*(path: string, configJson: string): ReplayWriter =
  replayCodec.openReplayWriter(path, configJson, TandemReplaySpec)

proc writeInputFrameMasks*(
  replayWriter: var ReplayWriter,
  time: uint32,
  masks: array[SeatCount, uint8]
) =
  ## EDIT 2: the seats send no inputs and the server computes both force
  ## vectors, so every mask is zero and this never records a change. It is
  ## still called every tick, so ctf's frame plumbing is untouched.
  for i in 0 ..< SeatCount:
    if i >= replayWriter.lastMasks.len:
      continue
    if replayWriter.lastMasks[i] == masks[i]:
      continue
    replayWriter.writeInput(ReplayInput(
      time: time, player: uint8(i), keys: masks[i]))
    replayWriter.lastMasks[i] = masks[i]

proc parseReplayBytes*(bytes: string): ReplayData =
  replayCodec.parseReplayBytes(bytes, TandemReplaySpec)

proc loadReplay*(path: string): ReplayData =
  replayCodec.loadReplay(path, TandemReplaySpec)

proc serializeReplaySim*(sim: var SimServer): string =
  ## EDIT 1: the course is moved aside for the write and put back afterwards,
  ## so a keyframe never carries the static warehouse.
  var saved = move(sim.course)
  result = sim.toFlatty()
  sim.course = move(saved)

proc deserializeReplaySim*(bytes: string, donor: var SimServer): SimServer =
  ## The course comes from the DONOR (the live sim, whose course was built from
  ## the replay's config JSON), never from the keyframe bytes.
  result = bytes.fromFlatty(SimServer)
  result.course = donor.course
  result.courseDigest = donor.courseDigest

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  result.data = data
  result.masks = newSeq[uint8](SeatCount)
  result.lastAppliedMasks = newSeq[uint8](SeatCount)
  result.playing = true
  result.looping = true
  result.speedIndex = 0
  result.skipLulls = true
  result.hashMismatchTick = -1

proc replaySpeed*(replay: ReplayPlayer): int =
  PlaybackSpeeds[clamp(replay.speedIndex, 0, PlaybackSpeeds.high)]

proc replayMaxTick*(replay: ReplayPlayer): int =
  if replay.data.hashes.len == 0:
    return 0
  int(replay.data.hashes[^1].tick)

proc replayStartTick*(replay: ReplayPlayer): int =
  clamp(max(0, replay.startTick), 0, replay.replayMaxTick())

proc resetReplay*(replay: var ReplayPlayer) =
  replay.joinIndex = 0
  replay.leaveIndex = 0
  replay.chatIndex = 0
  replay.inputIndex = 0
  replay.hashIndex = 0
  replay.hashValidationFailed = false
  replay.hashMismatchTick = -1
  replay.masks = newSeq[uint8](SeatCount)
  replay.lastAppliedMasks = newSeq[uint8](SeatCount)

proc saveReplayKeyframe(
  replay: ReplayPlayer,
  sim: var SimServer
): ReplayKeyframe =
  ReplayKeyframe(
    tick: sim.tickCount,
    simBytes: serializeReplaySim(sim),
    joinIndex: replay.joinIndex,
    leaveIndex: replay.leaveIndex,
    chatIndex: replay.chatIndex,
    inputIndex: replay.inputIndex,
    hashIndex: replay.hashIndex,
    masks: replay.masks,
    lastAppliedMasks: replay.lastAppliedMasks,
    hashValidationFailed: replay.hashValidationFailed,
    hashMismatchTick: replay.hashMismatchTick
  )

proc restoreReplayKeyframe(
  replay: var ReplayPlayer,
  sim: var SimServer,
  keyframe: ReplayKeyframe
) =
  let gameEventLoggingEnabled = sim.gameEventLoggingEnabled
  var restored = deserializeReplaySim(keyframe.simBytes, sim)
  restored.gameEventLoggingEnabled = gameEventLoggingEnabled
  sim = move(restored)
  replay.joinIndex = keyframe.joinIndex
  replay.leaveIndex = keyframe.leaveIndex
  replay.chatIndex = keyframe.chatIndex
  replay.inputIndex = keyframe.inputIndex
  replay.hashIndex = keyframe.hashIndex
  replay.masks = keyframe.masks
  replay.lastAppliedMasks = keyframe.lastAppliedMasks
  replay.hashValidationFailed = keyframe.hashValidationFailed
  replay.hashMismatchTick = keyframe.hashMismatchTick

proc replayKeyframeIndex(replay: ReplayPlayer, tick: int): int =
  for i, keyframe in replay.keyframes:
    if keyframe.tick > tick:
      break
    result = i

proc applyReplayEvents(replay: var ReplayPlayer, sim: var SimServer) =
  ## Applies replay joins, leaves, inputs and chat records for the current
  ## tick, BEFORE the step — which is exactly where the live server writes
  ## them, so an `order` record installs on the same tick either way.
  let time = tickTime(sim.tickCount)
  while replay.leaveIndex < replay.data.leaves.len and
      replay.data.leaves[replay.leaveIndex].time <= time:
    let leave = replay.data.leaves[replay.leaveIndex]
    if int(leave.player) < 0 or int(leave.player) >= sim.players.len:
      raise newException(ReplayError, "Replay player leave is invalid")
    sim.removePlayerAt(int(leave.player))
    inc replay.leaveIndex

  while replay.joinIndex < replay.data.joins.len and
      replay.data.joins[replay.joinIndex].time <= time:
    let join = replay.data.joins[replay.joinIndex]
    if int(join.player) != sim.players.len:
      raise newException(ReplayError, "Replay player join order is invalid")
    discard sim.addPlayer(join.name, join.slot, join.token, trusted = true)
    inc replay.joinIndex

  while replay.inputIndex < replay.data.inputs.len and
      replay.data.inputs[replay.inputIndex].time <= time:
    let input = replay.data.inputs[replay.inputIndex]
    if int(input.player) < SeatCount:
      replay.masks[int(input.player)] = input.keys
    inc replay.inputIndex

  while replay.chatIndex < replay.data.chats.len and
      replay.data.chats[replay.chatIndex].time <= time:
    sim.applyRecord(replay.data.chats[replay.chatIndex].message)
    inc replay.chatIndex

proc checkReplayHash(replay: var ReplayPlayer, sim: SimServer) =
  ## The integrity chain. A single divergent bit is caught at the tick it
  ## happens and surfaced as `mismatchTick`.
  if replay.hashValidationFailed:
    if sim.tickCount >= replay.replayMaxTick():
      replay.playing = false
    return
  if replay.hashIndex >= replay.data.hashes.len:
    replay.playing = false
    return
  let expected = replay.data.hashes[replay.hashIndex]
  if int(expected.tick) < sim.tickCount:
    let message = "Replay hash tick is missing at tick " & $sim.tickCount & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  if int(expected.tick) > sim.tickCount:
    return
  let hash = sim.gameHash()
  if hash != expected.hash:
    let message = "Replay hash mismatch at tick " & $sim.tickCount &
      "; expected " & $expected.hash & ", got " & $hash & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  inc replay.hashIndex

proc stepReplay*(replay: var ReplayPlayer, sim: var SimServer) =
  ## Apply this tick's records (which INSTALL the orders), then compile both
  ## seats' forces with the same `control.stepSim` the live server runs.
  replay.applyReplayEvents(sim)
  for i in 0 ..< SeatCount:
    replay.lastAppliedMasks[i] = replay.masks[i]
  sim.stepSim()
  replay.checkReplayHash(sim)

proc buildLullSpans*(
  beatTicks: seq[int],
  startTick, maxTick: int
): seq[array[2, int]] =
  ## Turns the ascending beat-tick list into the quiet spans between beats,
  ## keeping LullLeadTicks of context on both sides.
  var prevBeat = startTick
  for i in 0 .. beatTicks.len:
    let nextBeat =
      if i < beatTicks.len: beatTicks[i]
      else: maxTick + LullLeadTicks + 1
    let
      a = prevBeat + LullLeadTicks + 1
      b = min(nextBeat - LullLeadTicks - 1, maxTick)
    if b - a + 1 >= MinLullTicks:
      result.add([a, b])
    if i < beatTicks.len:
      prevBeat = nextBeat

proc scanCondition(sim: SimServer): seq[int] =
  @[sim.conditionPermille()]

proc scanSeriesPoint(tick: int, condition: seq[int]): seq[int] =
  result = @[tick]
  result.add(condition)

proc scanComplete*(replay: ReplayPlayer): bool =
  replay.scanDone

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int)

proc initReplayScan*(
  replay: var ReplayPlayer,
  initialSim: SimServer,
  interval = ReplayKeyframeTicks
) =
  ## Starts the whole-match precompute walk: seek keyframes, the goal-difference
  ## change-point series, the story beats, and the beat ticks the lull map
  ## derives from.
  replay.keyframes = @[]
  replay.leadSeries = @[]
  replay.lullSpans = @[]
  replay.beatEvents = newJArray()
  replay.scanDone = false
  var scan = ReplayScan(interval: max(interval, 1))
  scan.sim = initialSim
  scan.sim.gameEventLoggingEnabled = false
  scan.builder = initReplayPlayer(replay.data)
  scan.builder.looping = false
  scan.builder.mismatchQuit = replay.mismatchQuit
  scan.maxTick = scan.builder.replayMaxTick()
  replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim))
  scan.lastCondition = scanCondition(scan.sim)
  replay.leadSeries.add(scanSeriesPoint(scan.sim.tickCount,
    scan.lastCondition))
  scan.beatTracker = initBroadcastTracker()
  scan.beatTracker.resync(scan.sim)
  replay.startTick =
    if scan.sim.carrying(): scan.sim.gameStartTick else: -1
  replay.scan = scan
  replay.advanceReplayScan(0)

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int) =
  ## Advances the precompute walk by up to `maxTicks` sim ticks; when it stops
  ## it derives the lull spans and marks the lead chrome ready.
  if replay.scan == nil:
    return
  let scan = replay.scan
  var stepsLeft = maxTicks
  while stepsLeft > 0 and scan.builder.playing and
      scan.sim.tickCount < scan.maxTick:
    try:
      scan.builder.stepReplay(scan.sim)
    except ReplayError as error:
      if replay.mismatchQuit:
        raise
      echo "replay scan stopped at tick ", scan.sim.tickCount, ": ", error.msg
      scan.builder.playing = false
      break
    if replay.startTick < 0 and scan.sim.carrying():
      replay.startTick = scan.sim.gameStartTick
    let condition = scanCondition(scan.sim)
    if condition != scan.lastCondition:
      replay.leadSeries.add(scanSeriesPoint(scan.sim.tickCount, condition))
      scan.lastCondition = condition
    var stepBeats = newJArray()
    scan.sim.stepEvents(scan.beatTracker, stepBeats)
    for event in stepBeats:
      if event["k"].getStr() notin BeatKinds:
        continue
      if event["k"].getStr() == "impact" and
          event{"dmg"}.getInt() < ImpactBeatDamage:
        continue
      replay.beatEvents.add(event)
    for event in stepBeats:
      if event["k"].getStr() in LullBreakingKinds:
        scan.beatTicks.add(scan.sim.tickCount)
        break
    if scan.sim.tickCount mod scan.interval == 0 or
        scan.sim.tickCount == scan.maxTick:
      replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim))
    dec stepsLeft
  if scan.builder.playing and scan.sim.tickCount < scan.maxTick:
    return
  if replay.leadSeries.len == 0 or
      replay.leadSeries[^1][0] != scan.sim.tickCount:
    replay.leadSeries.add(scanSeriesPoint(scan.sim.tickCount,
      scan.lastCondition))
  replay.lullSpans = buildLullSpans(
    scan.beatTicks, replay.replayStartTick(), scan.maxTick)
  replay.scan = nil
  replay.scanDone = true

proc replayScanTicksPerFrame*(sim: SimServer): int =
  ## Deterministic scan slice per presentation frame (frame-counted, no clock
  ## reads — machine speed must not change what any frame contains).
  discard sim
  96

proc buildReplayKeyframes*(
  replay: var ReplayPlayer,
  initialSim: SimServer,
  interval = ReplayKeyframeTicks
) =
  replay.initReplayScan(initialSim, interval)
  replay.advanceReplayScan(int.high)

proc isLullTick*(replay: ReplayPlayer, tick: int): bool =
  for span in replay.lullSpans:
    if tick < span[0]:
      return false
    if tick <= span[1]:
      return true
  false

proc replayStepBudget*(replay: ReplayPlayer, tick: int): int =
  let speed = replay.replaySpeed()
  if replay.skipLulls and replay.isLullTick(tick):
    return min(speed * LullSpeedBoost, MaxLullTicksPerFrame)
  speed

proc seekReplay*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(
      sim, replay.keyframes[replay.replayKeyframeIndex(tick)])
  else:
    let gameEventLoggingEnabled = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = gameEventLoggingEnabled
    replay.resetReplay()
  while sim.tickCount < tick and replay.hashIndex < replay.data.hashes.len:
    replay.stepReplay(sim)

proc applyReplaySeek*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  replay.playing = false
  replay.seekReplay(sim,
    clamp(tick, replay.replayStartTick(), replay.replayMaxTick()))

proc applySpeedCommand*(speedIndex: var int, command: char) =
  case command
  of '+', '=': speedIndex = min(speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_': speedIndex = max(speedIndex - 1, 0)
  of '1': speedIndex = 0
  of '2': speedIndex = 1
  of '3': speedIndex = 2
  of '4': speedIndex = 3
  of '8': speedIndex = 4
  of '6': speedIndex = 5
  else: discard

proc applyReplayCommand*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  command: char
) =
  case command
  of ' ':
    replay.playing = not replay.playing
  of 'p':
    replay.playing = true
  of 'P':
    replay.playing = false
  of '+', '=', '-', '_', '1', '2', '3', '4', '8', '6':
    applySpeedCommand(replay.speedIndex, command)
  of ',', '<':
    replay.playing = false
    replay.seekReplay(sim, replay.replayStartTick())
  of 'b':
    replay.playing = false
    replay.seekReplay(sim, max(replay.replayStartTick(), sim.tickCount - 1))
  of 'e':
    replay.playing = false
    replay.seekReplay(sim, replay.replayMaxTick())
  of 'r':
    replay.looping = not replay.looping
  of 'f':
    replay.skipLulls = not replay.skipLulls
  of '.', '>':
    replay.playing = false
    replay.seekReplay(sim, sim.tickCount + ReplayFps * 5)
  else:
    discard

proc cancelEndHold*(replay: var ReplayPlayer) =
  replay.endHoldFrames = 0

proc endHoldSecondsLeft*(replay: ReplayPlayer): int =
  if replay.endHoldFrames <= 0: 0
  else: (replay.endHoldFrames + ReplayFps - 1) div ReplayFps

proc advanceReplayPlayback*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  onStep: proc () {.closure.},
  onJump: proc () {.closure.}
) =
  ## Advances one real-time playback frame. A LOOPING replay does not restart
  ## the moment playback stops: the final game-over frame holds for
  ## ReplayEndHoldSeconds first.
  replay.advanceReplayScan(sim.replayScanTicksPerFrame())
  if replay.playing and replay.endHoldFrames > 0:
    replay.endHoldFrames = 0
    replay.seekReplay(sim, replay.replayStartTick())
    onJump()
  if replay.playing:
    replay.endHoldFrames = 0
    var stepsTaken = 0
    while replay.playing and
        stepsTaken < replay.replayStepBudget(sim.tickCount):
      replay.stepReplay(sim)
      onStep()
      inc stepsTaken
    if replay.looping and not replay.playing:
      replay.endHoldFrames = ReplayEndHoldSeconds * ReplayFps
  elif replay.endHoldFrames > 0:
    dec replay.endHoldFrames
    if replay.endHoldFrames == 0 and replay.looping:
      replay.seekReplay(sim, replay.replayStartTick())
      replay.playing = true
      onJump()

proc playbackSpeed*(speedIndex: int): int =
  PlaybackSpeeds[clamp(speedIndex, 0, PlaybackSpeeds.high)]
