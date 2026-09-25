# Tandem

**Two cogs, one couch, no channel.**

Two cogs are rigidly gripped to the two handles of one couch and have to walk it
through a procedurally generated warehouse obstacle course — room by room,
doorway by doorway — with no way to say anything to each other. The couch obeys
the **sum** of their forces and turns on the **difference**, so every misread of
the partner shows up as a wall scrape or a drop. The only signal about what your
partner intends is what you feel through the handle. The last doorway is
1.05 m wide; the couch is 0.90 m.

Players can run scripted baselines or ordinary container policies that send
complete carry orders through the authenticated player socket. The ordinary
player supports Jev, prompt, and trained backends. The certification fixture
uses two scripted baselines.

- Rules, physics and scoring: [`docs/RULES.md`](docs/RULES.md)
- Wire protocol, replay format and the reply schema: [`docs/PROTOCOL.md`](docs/PROTOCOL.md)
- How to write a tandem prompt: [`docs/CARRYING.md`](docs/CARRYING.md)
- Design note: [`docs/plans/2026-08-23-tandem-design.md`](docs/plans/2026-08-23-tandem-design.md)
- Working in this repo (determinism contract, frozen files, tests): [`AGENTS.md`](AGENTS.md)
- Tuning the scripted baselines: [`docs/BASELINE-TUNING.md`](docs/BASELINE-TUNING.md)
- Ordinary player collection and post-training: [`docs/TRAINING.md`](docs/TRAINING.md)

## Scoring

Fully cooperative — both seats receive the identical number.

```
delivered:      score = 0.30 + 0.35 * speed + 0.35 * condition
not delivered:  score = 0.25 * progress * condition
```

`speed = clamp(2 − t/par, 0, 1)`, `condition = (1000 − damage)/1000`. Any
delivery beats every non-delivery; a wrecked couch scores 0.000. The league
ranks by the seat's mean score across its episodes (its cross-play mean), not by
Elo: with two identical scores every episode is a draw.

## Running it

The game image contains the server and bundled scripted player. The ordinary
player has its own image.

```bash
docker build --platform=linux/amd64 -t coworld-tandem:ci .
tools/ci/docker_smoke.sh coworld-tandem:ci     # one real episode, raw docker
```

To field a prompt policy, build `Dockerfile.ordinary-player` and configure
`PLAYER_PROMPT` and `ANTHROPIC_API_KEY` on that player:

```bash
coworld upload-policy coworld-tandem-ordinary:latest --name my-tandem \
  --run "python player.py" --secret-env PLAYER_PROMPT="<your strategy>" \
  --secret-env ANTHROPIC_API_KEY="<your key>"
```

or run a scripted seat: `PLAYER_SCRIPTED=porter` (the strain-arbitrated
reference carrier, and the fallback for every failure mode) or
`PLAYER_SCRIPTED=mule` (never yields, never braces, scrapes constantly).

To run the ordinary player, build `Dockerfile.ordinary-player` and seat that
image as a normal Coworld player. Set `TANDEM_JEV=1` for Jev or package a
trained adapter and set `TANDEM_ADAPTER_DIR`. See [training](docs/TRAINING.md).

## Repo layout

| Path | What |
|---|---|
| `src/tandem/{sim,course,control,trig}.nim` | the integer-only determinism core |
| `src/tandem/{orders,baselines,decide}.nim` | the order schema, the two baselines and the turn engine |
| `players/ordinary/` | prompt, Jev, heuristic and trained player decisions |
| `src/tandem/{server,roster,replays,replay_runtime,broadcast,global,rig_art}.nim` | the episode server, the replay codec and the renderer |
| `client/` | the broadcast chrome, inherited from `Metta-AI/coworld-ctf` |
| `replay-viewer/` | the static wasm replay bundle |
| `tests/` | the determinism gate and the rest of the suite |

## Determinism

Replays are re-simulated in the browser by the **emscripten/wasm32** build of
the same Nim module the **native amd64** server ran, and their per-tick
`gameHash` chain must match bit for bit. So the sim, the course generator, the
control layer and the trigonometry are integer-only — no floats, no libm, one
committed sine table, one integer square root, one integer atan2 — and every
product is taken in `int64` and narrowed with an explicit truncating `div`.

Unusually for this lineage the **control layer is inside** the determinism
boundary: the replay carries 100 order records instead of 4800 action records,
and the viewer re-derives every per-tick force from them.
