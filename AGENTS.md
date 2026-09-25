# Agent operating guide — cogame-tandem

Orientation for coding agents working in this repo. The rules live in
[docs/RULES.md](docs/RULES.md), the wire format in
[docs/PROTOCOL.md](docs/PROTOCOL.md), prompt-writing guidance in
[docs/CARRYING.md](docs/CARRYING.md), and the design this repo implements in
[docs/plans/2026-08-23-tandem-design.md](docs/plans/2026-08-23-tandem-design.md).
This file covers the things that are easy to get wrong.

Tandem is forked from **`Metta-AI/coworld-ctf`** (paintbot). Every convention
there holds here unless the design note says otherwise.

## The shape of the thing

Two cogs are rigidly gripped to the two handles of one couch and carry it
through a procedurally generated warehouse. The assembly obeys the **sum** of
the two seats' forces. There is **no communication channel** — the only signal
about the partner is the force felt through your own handle.

```
src/tandem.nim            entrypoint (/bin/tandem)
src/tandem_player.nim     the bundled scripted player (/bin/tandem-player)
players/ordinary/       ordinary prompt, Jev, heuristic and trained player
src/tandem/
  sim.nim sim_types.nim sim_state.nim sim_config.nim course.nim control.nim
                          THE DETERMINISM BOUNDARY (see below)
  trig.nim                the committed SinQ12 table, isqrt, integer atan2
  orders.nim              the six-field order, its tolerant parser, its record
  baselines.nim           porter / mule, and their {.intdefine.} tuning knobs
  decide.nim              private view and bounded simultaneous turn loop
  server.nim              ctf's mummy server with the five named edits
  replays.nim replay_runtime.nim broadcast.nim events.nim roster.nim
  global.nim rig_art.nim labels.nim wire_constants.nim   (render side; floats ok)
replay-viewer/            the static wasm bundle (never a pod)
client/                   the broadcast chrome
tools/                    build, forensics and the baseline grid harness
tests/                    run in CI in BOTH debug and -d:release
```

## The determinism contract (the one thing you cannot break)

A replay is re-simulated by the **emscripten/wasm32** build of the same modules
the **native amd64** server ran, and the per-tick `gameHash` chain must match
bit for bit.

- **No floating point at all** under `src/tandem/{sim, sim_types, sim_config,
  sim_state, course, control, trig}.nim`. No `sin`, `cos`, `arctan2`, `sqrt`,
  `pow`, `float`. `tests/test_determinism.nim` greps for those identifiers with
  comments and string literals stripped, so a comment mentioning "float" is
  fine and a variable is not.
- **Nim's `int` is 64-bit natively and 32-bit under `--cpu:wasm32`.** Every
  stored sim field is explicitly `int32`/`bool`/`enum`, and every product or
  quotient of two sim quantities is computed in `int64` and narrowed with an
  explicit `div`. Arithmetic that is silently fine natively traps in the
  viewer: `tools/wasm_replay_smoke.cjs` is the gate that catches it.
- **The control layer is inside the boundary.** `control.seatForce` is
  re-derived by the viewer from the recorded orders — that is why no per-tick
  action record exists and why the quantised orders are hashed.
- The sim draws random numbers for exactly one thing (course generation) and
  only at tick 0.
- `tests/data/golden_hashes.json` pins the hash at every 50th tick for seed
  4417231. **If the gate fails, the physics or a build flag changed — fix the
  code, never the test.** If a change legitimately moves the chain, regenerate
  the goldens in the same commit and say so in the message.

## GameVersion

`GameName`/`GameVersion` live in `src/tandem/sim_types.nim` and ride in every
replay header. Bump `GameVersion` in the same commit as any rules change, with
the prepend-only changelog comment; `tools/ci/check_gameversion.sh` is kept from
the starter.

## Things that are frozen

- **`client/chrome_common.js` is byte-identical to the starter's.**
  `tests/test_viewer.nim` pins its sha256 and length. Tandem-specific behaviour
  goes in the appended game block of `client/replay_broadcast.html`, under the
  banner comment — never above it, and never in chrome_common.
- **`replay-viewer/config.nims` and `static_replay*.js` come from the same
  starter.** No `MODULARIZE`, no `EXPORT_NAME`: the worker bootstrap is the
  non-modularized `var Module = {}` + `Module.onRuntimeInitialized` form.
  Splicing one starter's shell onto another's link flags deadlocks the viewer
  silently with every file present and every asset 200.
- **No channel.** A seat's observation contains nothing derived from the
  partner's order, note, `say`, effort, yield, twist, brace or felt strain —
  only the shared body's state and the map. `tests/test_no_channel.nim` asserts
  it against the private view over 200 randomised order pairs. Do
  not add a field to `seatViewJson` without checking it against that test.
- **Two name spaces.** In-game vocabulary is `Cobalt`/`Rust` only. Real policy
  names appear in the replay config roster, the chrome and `results.names`, and
  nowhere a seat can read.

## Tuning the scripted baselines

Every knob in `baselines.nim` is `{.intdefine.}`, so a sweep is a recompile:

```bash
nim r -d:release --path:src tools/tune_baselines.nim --eval
nim r -d:release --path:src tools/tune_baselines.nim --sweep TandemTwistGain=3,5,8
```

`--eval` with no defines is the shipped configuration. Record what you measure
in [docs/BASELINE-TUNING.md](docs/BASELINE-TUNING.md); a constant whose
docstring quotes a number the harness cannot reproduce is worse than no
docstring.

## Running the tests

```bash
# regenerate nim.cfg from your own package tree first (the committed one pins
# the author's paths; the Dockerfile and CI both rebuild it)
for pkg in "$HOME"/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\""; else echo "--path:\"$pkg\""; fi
done > nim.cfg
echo '--path:"src"' >> nim.cfg

for t in tests/*.nim; do nim r --hints:off --path:src "$t"; done
```

CI runs every test twice, debug and `-d:release` (debug's range/overflow checks
are the cheapest catch for a fixed-point overflow); the `NIM_TESTS_RELEASE_ONLY`
repo variable lists `tests/test_perf.nim`. Beyond the Nim tests, `ci.yml` builds
the image and runs a raw-Docker episode (`tools/ci/docker_smoke.sh`), then
builds the wasm bundle and **executes it in headless chromium** against the
replay that episode produced (`tools/ci/viewer_smoke.mjs`). A viewer that builds
but does not run is the failure mode that gate exists for.

## Artifacts and forensics

The replay is the starter's **binary `COWLDTDM`** format — the wasm viewer
parses exactly that, so `SMOKE_REQUIRE_REPLAY_JSON=0` in CI. For a human or a
strict parser, `tools/replay_summary.py` (Python 3 stdlib only) prints one
strict-UTF-8 JSON object from a `.replay` path: protocol, seed, roster, course,
every order record and the results document.

**Every string that reaches the replay is truncated on RUNE boundaries** —
`say`, `note`, prompts, policy labels, captured provider errors. Slicing a
`string` by byte index on any path to the replay is forbidden: a byte-truncated
multi-byte character renders in a browser and fails a strict parser.
