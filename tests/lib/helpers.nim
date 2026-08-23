## Shared helpers for the tandem test suite.
##
## Every test runs from the repo ROOT (assets resolve via `data/`), twice: once
## debug — where Nim's range and overflow checks are the cheapest catch for a
## fixed-point overflow — and once `-d:release`.

import std/[json, os, random, strutils]
import tandem/[baselines, broadcast, control, decide, orders, roster, sim]

export sim, control, baselines, orders, decide, roster, broadcast

proc testConfig*(seed = 4417231, maxTicks = DefaultMaxTicks): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.maxTicks = maxTicks
  result.minPlayers = 2
  result.startWaitTicks = 1
  result.gameOverTicks = 2
  result.minBatchSpacingMs = 0
  result.slots = @[
    PlayerSlotConfig(name: "cobalt-policy", token: "t0", alias: "Cobalt"),
    PlayerSlotConfig(name: "rust-policy", token: "t1", alias: "Rust")
  ]

proc seatedSim*(config: GameConfig): SimServer =
  ## A sim with both seats already joined THROUGH `addPlayer`, logging off.
  ## Adding roster entries by hand would leave `nextJoinOrder` behind, and that
  ## field IS hashed — a replay of such a recording diverges at tick 1.
  result = initSimServer(config)
  result.gameEventLoggingEnabled = false
  discard result.addPlayer("cobalt-policy", 0, "t0")
  discard result.addPlayer("rust-policy", 1, "t1")

proc carryingSim*(config: GameConfig): SimServer =
  ## A sim already carrying, past the lobby.
  result = seatedSim(config)
  result.startGame()

proc stepIdle*(sim: var SimServer, ticks = 1) =
  for _ in 0 ..< ticks:
    sim.step(ZeroForces)

proc stepForces*(sim: var SimServer, forces: SeatForces, ticks = 1) =
  for _ in 0 ..< ticks:
    sim.step(forces)

type ScriptedRun* = object
  delivered*: bool
  damage*: int
  ticks*: int
  parTicks*: int
  progress*: int
  drops*: int
  score*: float
  reason*: EndReason
  rule*: EndRule
  orders*: seq[string]

proc runScripted*(
  config: GameConfig,
  cobalt = "porter",
  rust = "porter",
  collectOrders = false
): ScriptedRun =
  ## A whole episode driven by the scripted baselines through the REAL control
  ## layer AND the REAL record path — the same route the server takes, minus
  ## the sockets: the order is serialized to its replay record and installed by
  ## `applyRecord`, exactly as the viewer installs it.
  var sim = seatedSim(config)
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
          let record = capRecord($orderJson(sim, seat,
            sim.baselineOrder(seat, name, turn)))
          if collectOrders:
            result.orders.add(record)
          sim.applyRecord(record)
    sim.stepSim()
  result.delivered = sim.delivered()
  result.damage = int(sim.damage)
  result.ticks = sim.tickCount
  result.parTicks = sim.parTicks()
  result.progress = int(sim.bestProgressPermille)
  result.drops = int(sim.drops)
  result.score = sim.jointScore()
  result.reason = sim.endReason
  result.rule = sim.endRule

proc sourceText*(path: string): string =
  ## Reads a source file with `##`/`#` comments and string literals stripped,
  ## so a guard can grep for IDENTIFIERS without tripping over prose.
  let raw = readFile(path)
  var
    stripped = newStringOfCap(raw.len)
    inString = false
    inChar = false
    escaped = false
    comment = false
    prev = ' '
  for ch in raw:
    if comment:
      if ch == '\n':
        comment = false
        stripped.add(ch)
      continue
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    if inChar:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '\'': inChar = false
      continue
    case ch
    of '#':
      comment = true
    of '"':
      inString = true
    of '\'':
      # A quote after an alphanumeric is a NUMERIC SUFFIX (`1'i64`), not a
      # char literal. Missing that swallows half the file and makes this guard
      # silently useless.
      if prev in {'0' .. '9', 'A' .. 'Z', 'a' .. 'z', '_'}:
        stripped.add(ch)
      else:
        inChar = true
    else:
      stripped.add(ch)
    prev = ch
  stripped

proc identifiers*(text: string): seq[string] =
  ## Every maximal [A-Za-z0-9_] run in `text`.
  var current = ""
  for ch in text:
    if ch in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}:
      current.add(ch)
    elif current.len > 0:
      result.add(current)
      current = ""
  if current.len > 0:
    result.add(current)

proc tempPath*(name: string): string =
  getTempDir() / ("tandem-test-" & $getCurrentProcessId() & "-" & name)

proc report*(name: string) =
  echo "  ok  ", name

proc pseudoWorld*(sim: var SimServer, rng: var Rand) =
  ## Scatters the assembly over the warehouse deterministically — the state
  ## generator the bounded-orders and control tests sweep over.
  sim.posX = int32(3_000_000 + rng.rand(int(WorldW) - 6_000_000))
  sim.posY = int32(3_000_000 + rng.rand(int(WorldH) - 6_000_000))
  sim.velX = int32(rng.rand(2 * int(MaxSpeedUm)) - int(MaxSpeedUm))
  sim.velY = int32(rng.rand(2 * int(MaxSpeedUm)) - int(MaxSpeedUm))
  sim.headingQ = int32(rng.rand(HeadingQTurn - 1))
  sim.spin = int32(rng.rand(2 * int(MaxSpinQ)) - int(MaxSpinQ))
  sim.damage = int32(rng.rand(999))
  for seat in 0 ..< SeatCount:
    sim.strainX[seat] = int32(rng.rand(4_000_000) - 2_000_000)
    sim.strainY[seat] = int32(rng.rand(4_000_000) - 2_000_000)
    sim.slip[seat] = int32(rng.rand(int(SlipDropThreshold) - 1))

proc pseudoOrder*(rng: var Rand): Order =
  result = emptyOrder()
  let u = unitQ12(int32(rng.rand(8192) - 4096), int32(rng.rand(8192) - 4096))
  result.driveX = u.x
  result.driveY = u.y
  result.effort = int32(rng.rand(255))
  result.yieldQ = int32(rng.rand(255))
  result.twist = int32(rng.rand(510) - 255)
  result.brace = int32(rng.rand(255))
  result.note = "note-" & $rng.rand(1_000_000)
  result.say = "say-" & $rng.rand(1_000_000)

proc runeCount*(text: string): int =
  ## Codepoints, not bytes — the unit every recorded string is capped in.
  var count = 0
  var i = 0
  while i < text.len:
    let b = text[i].uint8
    let width =
      if b < 0x80: 1
      elif b < 0xE0: 2
      elif b < 0xF0: 3
      else: 4
    i += width
    inc count
  count

proc isValidUtf8*(text: string): bool =
  ## A byte-truncated multi-byte character is exactly the bug the rune
  ## discipline exists to prevent, so the tests check for it directly.
  var i = 0
  while i < text.len:
    let b = text[i].uint8
    var extra = 0
    if b < 0x80: extra = 0
    elif b >= 0xC2 and b <= 0xDF: extra = 1
    elif b >= 0xE0 and b <= 0xEF: extra = 2
    elif b >= 0xF0 and b <= 0xF4: extra = 3
    else: return false
    if i + extra >= text.len and extra > 0:
      return false
    for k in 1 .. extra:
      let c = text[i + k].uint8
      if c < 0x80 or c > 0xBF:
        return false
    i += extra + 1
  true

proc repoFile*(path: string): string =
  for candidate in [path, ".." / path]:
    if fileExists(candidate):
      return readFile(candidate)
  raise newException(IOError, "repo file not found: " & path)

proc repoPath*(path: string): string =
  for candidate in [path, ".." / path]:
    if fileExists(candidate) or dirExists(candidate):
      return candidate
  path

proc manifest*(): JsonNode =
  parseJson(repoFile("coworld_manifest_template.json"))
