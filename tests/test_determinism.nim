## THE DETERMINISM GATE. If this fails, the physics or a build flag changed —
## fix the code, never the test.
##
## Six halves live here; the seventh — the cross-BUILD half — runs in the
## `wasm-viewer` CI job, where `node tools/wasm_replay_smoke.cjs` re-simulates
## the smoke replay through the emscripten wasm32 build and fails if
## `tandem_mismatch_tick() != -1`. That is the only place a wasm32 32-bit `int`
## overflow can be caught, because `int` is 64 bits here.

import std/[json, math, os, strutils, tables]
import lib/helpers

const GoldenPath = "tests/data/golden_hashes.json"
const GoldenSeed = 4417231
const GoldenStride = 50

proc replayOrders(config: GameConfig, orders: seq[string]): seq[uint64] =
  ## Re-runs an episode from its recorded order log alone — the exact thing the
  ## wasm viewer does.
  var sim = seatedSim(config)
  var cursor = 0
  while sim.phase != GameOver and sim.tickCount < config.maxTicks * 2 + 500:
    if sim.carrying():
      let elapsed = sim.tickCount - sim.gameStartTick
      if not (sim.hasOrder[0] and sim.hasOrder[1]) or
          elapsed mod sim.turnTicks() == 0:
        for _ in 0 ..< SeatCount:
          if cursor < orders.len:
            sim.applyRecord(orders[cursor])
            inc cursor
    sim.stepSim()
    result.add(sim.gameHash())

proc sameSeedSameLog() =
  ## (a) Same seed + same order log => identical gameHash at every tick, twice
  ## in one process and once in a fresh sim.
  let config = testConfig(maxTicks = DefaultMaxTicks)
  let recorded = runScripted(config, "porter", "mule", collectOrders = true)
  doAssert recorded.orders.len > 20,
    "the recording is too short to prove much: " & $recorded.orders.len
  let first = replayOrders(config, recorded.orders)
  let second = replayOrders(config, recorded.orders)
  doAssert first.len > 100, "the replay is too short: " & $first.len
  doAssert first == second, "two runs in one process disagreed"
  let third = replayOrders(config, recorded.orders)
  for i in 0 ..< first.len:
    doAssert third[i] == first[i], "a fresh sim diverged at tick " & $i
  report "the same seed and order log reproduce every tick's hash"

proc oneBitMatters() =
  ## (b) A one-unit change in any quantised order field changes the final hash.
  let config = testConfig(maxTicks = 600)
  let recorded = runScripted(config, "porter", "porter", collectOrders = true)
  doAssert recorded.orders.len >= 2
  let baseChain = replayOrders(config, recorded.orders)
  let base = baseChain[^1]
  var proven = 0
  for field in ["effort", "yield", "twist", "brace"]:
    var index = 0
    case field
    of "effort": index = 2
    of "yield": index = 3
    of "twist": index = 4
    else: index = 5
    var mutated = recorded.orders
    var moved = false
    for i in 0 ..< mutated.len:
      var node = parseJson(mutated[i])
      var q = node["q"]
      let old = q[index].getInt()
      q.elems[index] = %(if old < 255: old + 1 else: old - 1)
      node["q"] = q
      mutated[i] = $node
      let after = replayOrders(config, mutated)
      if after.len != baseChain.len or after[^1] != base:
        moved = true
        break
      mutated = recorded.orders
    doAssert moved, "nudging `" & field & "` never moved the final hash"
    inc proven
  doAssert proven == 4
  report "a one-unit change in any order field changes the hash chain"

proc goldenHashes() =
  ## (c) The committed golden fixture pins the hash at every 50th tick.
  let config = testConfig(seed = GoldenSeed, maxTicks = DefaultMaxTicks)
  let recorded = runScripted(config, "porter", "porter", collectOrders = true)
  let hashes = replayOrders(config, recorded.orders)
  var produced = newJObject()
  produced["seed"] = %GoldenSeed
  produced["stride"] = %GoldenStride
  produced["ticks"] = %hashes.len
  var values = newJArray()
  var tick = 0
  while tick < hashes.len:
    values.add(%($hashes[tick]))
    tick += GoldenStride
  produced["hashes"] = values
  if not fileExists(GoldenPath):
    echo "::error::", GoldenPath, " is missing. Commit exactly this file:"
    echo pretty(produced)
    doAssert false, "the golden hash fixture is not committed"
  let golden = parseJson(readFile(GoldenPath))
  doAssert golden["seed"].getInt() == GoldenSeed
  doAssert golden["stride"].getInt() == GoldenStride
  doAssert golden["ticks"].getInt() == hashes.len,
    "the run length changed: golden " & $golden["ticks"].getInt() &
      ", now " & $hashes.len
  doAssert golden["hashes"].len == values.len,
    "the golden fixture has " & $golden["hashes"].len & " entries, the run " &
      $values.len
  for i in 0 ..< values.len:
    doAssert golden["hashes"][i].getStr() == values[i].getStr(),
      "golden hash mismatch at tick " & $(i * GoldenStride) & ": golden " &
        golden["hashes"][i].getStr() & ", now " & values[i].getStr()
  report "the committed golden hash chain still holds"

const GuardedSources = [
  "src/tandem/sim.nim",
  "src/tandem/sim_types.nim",
  "src/tandem/sim_config.nim",
  "src/tandem/sim_state.nim",
  "src/tandem/course.nim",
  "src/tandem/control.nim",
  "src/tandem/trig.nim"
]

const BannedIdentifiers = [
  "sin", "cos", "tan", "arctan", "arcsin", "arccos", "arctan2",
  "exp", "ln", "log2", "log10", "pow", "sqrt", "hypot",
  "float", "float32", "float64", "cfloat", "cdouble"
]

proc sourceGuard() =
  ## (d) No floating point and no libm in the sim's own modules. Comments and
  ## string literals are stripped first, so this greps IDENTIFIERS — prose
  ## about "floating point" is fine, a call to `sqrt` is not.
  var banned: Table[string, bool]
  for name in BannedIdentifiers:
    banned[name] = true
  for path in GuardedSources:
    let file = repoPath(path)
    doAssert fileExists(file), "guarded source is missing: " & path
    let code = sourceText(file)
    for ident in identifiers(code):
      doAssert not banned.hasKey(ident),
        "banned identifier `" & ident & "` in " & path &
          " — the sim must stay integer-only (docs/RULES.md §Determinism)"
    doAssert "std/math" notin code, "`std/math` is imported by " & path
  for path in ["Dockerfile", "Dockerfile.replay-viewer",
               "replay-viewer/config.nims", ".github/workflows/ci.yml"]:
    doAssert "-ffast-math" notin repoFile(path), "-ffast-math in " & path
  report "the sim modules are float-free and libm-free"

proc trigTable() =
  ## (e) SinQ12 re-derived from math.sin entry by entry, and isqrt checked
  ## exhaustively below 2^16 and on perfect squares to 2^40.
  for b in 0 ..< 256:
    let want = int32(round(4096.0 * sin(2.0 * PI * float(b) / 256.0)))
    doAssert SinQ12[b] == want,
      "SinQ12[" & $b & "] is " & $SinQ12[b] & ", math.sin says " & $want
  doAssert cosQ12(0) == 4096
  doAssert sinQ12(64) == 4096
  for v in 0 ..< 65536:
    let r = isqrt(int64(v))
    doAssert r * r <= int64(v) and (r + 1) * (r + 1) > int64(v),
      "isqrt(" & $v & ") = " & $r
  var probe = 1'i64
  while probe < (1'i64 shl 20):
    let square = probe * probe
    doAssert isqrt(square) == probe, "isqrt of a perfect square failed at " &
      $probe
    doAssert isqrt(square - 1) == probe - 1
    probe = probe * 3 div 2 + 1
  report "the sine table and the integer square root are exact"

proc atan2Agrees() =
  ## (f) `bradsOfVectorI` agrees with a float arctan2 reference to +/-1 brad
  ## and is exactly antisymmetric under (dx, dy) -> (dx, -dy).
  var state = 12345'u64
  proc nextInt(): int32 =
    state = state * 6364136223846793005'u64 + 1442695040888963407'u64
    int32(int((state shr 33) and 0xffffff'u64) - 0x800000)
  for _ in 0 ..< 100_000:
    let dx = nextInt()
    let dy = nextInt()
    if dx == 0 and dy == 0:
      continue
    let got = bradsOfVectorI(dx, dy)
    var want = arctan2(-float(dy), float(dx)) * 128.0 / PI
    while want < 0: want += 256.0
    let wanted = int32(round(want)) mod 256
    var delta = abs(got - wanted)
    if delta > 128: delta = 256 - delta
    doAssert delta <= 1,
      "bradsOfVectorI(" & $dx & "," & $dy & ") = " & $got & ", arctan2 says " &
        $wanted
    let mirrored = bradsOfVectorI(dx, -dy)
    doAssert mirrored == ((256 - got) mod 256),
      "bradsOfVectorI is not antisymmetric at " & $dx & "," & $dy
  report "the integer atan2 matches arctan2 and is exactly antisymmetric"

when isMainModule:
  sameSeedSameLog()
  oneBitMatters()
  goldenHashes()
  sourceGuard()
  trigTable()
  atan2Agrees()
  echo "test_determinism: the gate holds"
