# Tandem — wire protocol

## Runtime contract

The game container reads `COGAME_CONFIG_URI` and writes `COGAME_RESULTS_URI`,
`COGAME_SAVE_REPLAY_URI`, `COGAME_EVENTS_URI`, `COGAME_METRICS_URI` and
`COGAME_PLAYER_FAILURE_URI`; `COGAME_HOST`/`COGAME_PORT` bind the listener.
`COGAME_LOAD_REPLAY_URI` switches the process into replay-server mode.

## HTTP / websocket routes

| Route | What |
|---|---|
| `GET /healthz` | `200 healthy` |
| `GET /player?slot=N&token=T` | the seat websocket; 403 on a bad slot or token |
| `GET /global` | the spectator websocket (Sprite v1 board + chrome channel) |
| `GET /replay` | the same stream in replay-server mode |
| `GET /client/global`, `GET /client/player` | real HTML pages; **neither opens the player socket** |
| `GET /client/replay` | the broadcast replay page |
| `GET /replay-data` | the raw `.replay` bytes |

`/healthz` and `/global` keep answering for a bounded ~20 s after the artifacts
are written, then the process exits.

## The player container

`/bin/tandem-player` reads `COWORLD_PLAYER_WS_URL`, `PLAYER_PROMPT`,
`PLAYER_SCRIPTED` and `PLAYER_POLICY_LABEL`, connects, and sends **one Sprite v1
chat message** carrying its registration:

```json
{"type":"register","prompt":"<strategy text or empty>",
 "scripted":"porter"|"mule"|null,"policy":"<free label>",
 "external":true|false}
```

`prompt` is truncated to 4000 runes **by the sender**, before the frame is
built: the Sprite v1 chat header carries a u16 length, so a registration over
65 535 bytes would wrap it and be discarded by the server — a rejected
registration, which the rules forbid (over-long is truncated, never rejected).
The server truncates again on receipt.

The bundled `/bin/tandem-player` sends the Sprite v1 Ready packet (`0x85`)
after each received frame and otherwise only receives. It re-sends registration
after the first received frame, in case the first send raced slot registration.
The receive loop is
wrapped in `try/except CatchableError` and exits 0 on a dead socket. A seat that
never registers, or registers with neither field, is `scripted: "porter"`.

An `external:true` policy receives private text frames on the same authenticated
player socket. Each `turn` frame has the turn index, the exact system and user
prompts, and complete porter and mule candidate orders. The player replies
with `{"type":"decision","turn":N,"action":{...}}`. The game sends a
`decision_result` acceptance receipt after the action enters the replay and
ends with a `final` frame containing scores, reason, and end rule. The normal
binary board frames and Ready packet continue. Sprite input masks remain zero.
The server computes both force vectors from recorded orders.

## The per-seat stream

One binary Sprite v1 frame per tick. **Visible:** the whole warehouse and both
cogs — there is no fog of war. **Hidden:** the partner's order, note, `say`,
effort, yield, twist, brace and felt strain; the partner's `PLAYER_PROMPT`;
real player names (board labels carry only `Cobalt`/`Rust`); and future ticks.

## The per-seat view given to the LLM

Numbers rounded to 2 decimals, in view coordinates (metres, centred, y up) and
degrees.

```json
{"turn": 12, "of": 50, "clock": {"elapsed_s": 24.0, "par_s": 39.2, "left_s": 76.0},
 "you": {"alias": "Cobalt", "handle": "fore", "pos": [-4.10, 2.35]},
 "partner": {"alias": "Rust", "handle": "aft", "pos": [-6.90, 1.05]},
 "couch": {"pos": [-5.50, 1.70], "angle_deg": 25.0, "vel": [1.02, 0.41],
           "speed": 1.10, "spin_deg_s": -18.0, "length_m": 2.20, "width_m": 0.90},
 "strain": {"vec": [-310, 145], "newtons": 342, "grip_limit_newtons": 850,
            "headroom_pct": 60, "slip_pct": 12, "note": "…"},
 "condition": {"damage": 214, "condition_pct": 78.6, "damage_last_turn": 31,
               "touching": ["couch_left_rear"], "drops": 1},
 "route": {"progress_pct": 46.2, "cell": [3, 2], "doors_cleared": 4,
           "doors_total": 11,
           "next_doorways": [{"centre": [-3.20, 1.70], "width_m": 1.20,
                              "through_deg": 0.0, "dist_m": 2.30}, …],
           "goal": {"centre": [18.60, 3.40], "dist_along_route_m": 28.4}},
 "room": {"walls": [{"x": [-7.80, -3.00], "y": [3.30, 3.60]}, …],
          "pillars": [{"centre": [-4.10, 0.30], "size_m": 0.80}]},
 "your_last_order": …}
```

Everything in it is either your own state, the shared body's state, or the map.
**Nothing in it is derived from the partner's order** —
`tests/test_no_channel.nim` asserts that over 200 randomised order pairs.

## The reply schema

```json
{"note": "aligning for the 1.2 m door, easing off",
 "drive": [0.98, 0.20], "effort": 0.45, "yield": 0.35,
 "twist": -0.40, "brace": 0.8, "say": "you lead, I'll follow"}
```

| Field | Cap / legal values | Repair when violated |
|---|---|---|
| `note` | ≤ 160 runes | truncated on a rune boundary |
| `drive` | finite, each clamped `[−1, 1]`, quantised to a Q12 unit vector | non-finite / missing / `[0,0]` → last turn's `drive`, else the scripted fallback's |
| `effort` | finite, clamped `[0, 1]`, quantised to `0..255` | → 0.5 |
| `yield` | finite, clamped `[0, 1]`, quantised to `0..255` | → 0.25 |
| `twist` | finite, clamped `[−1, 1]`, quantised to `−255..255` | → 0 |
| `brace` | finite, clamped `[0, 1]`, quantised to `0..255` | → 0 |
| `say` | ≤ 48 runes | truncated on a rune boundary |

Further caps on strings that reach the replay: `register.policy` ≤ 48 runes,
`fallback.detail` ≤ 200 runes, the whole serialized `order` record ≤ 900 runes
(shrunk structurally so it stays parseable JSON). `register.prompt` is capped at
4000 runes at the transport and is **never** written to the replay or results.

**Truncation is on rune boundaries, never bytes.** Slicing a string by byte
index on any path to the replay is forbidden.

Parsing is tolerant: markdown fences are stripped, the outermost balanced
`{…}` is taken, numeric strings are accepted, `drive` may arrive as
`{"x":…,"y":…}`, and an integer percentage is divided by 100 when it exceeds 1.
Only when no field at all can be recovered do the retry and then the scripted
fallback fire.

## Replay bytes

The replay is the starter's binary `COWLDTDM` format, self-sufficient: magic +
format version + game name/version header, the resolved config JSON (seed, the
FULLY EXPANDED course, every physics constant, the roster with real names), the
join/leave records, the chat records and one `gameHash` per tick.

| `k` | Fields |
|---|---|
| `register` | `seat`, `alias`, `policy`, `kind`, `baseline` |
| `order` | `turn`, `seat`, `alias`, `source`, `latency_ms`, `note`, `drive`, `effort`, `yield`, `twist`, `brace`, `say`, and **`q`** — the six exact quantised integers the sim hashed, which is what playback re-installs |
| `fallback` | `turn`, `seat`, `attempt`, `cause`, `detail` |
| `budget_guard` | `turn`, `remaining_s` |
| `result` | the full results document |

`tools/replay_summary.py` (Python 3 stdlib only) prints one strict-UTF-8 JSON
object summarising a `.replay` file, which is the phase-60 substitute for a JSON
replay.

## The tier-2 event stream

`COGAME_EVENTS_URI` gets JSON lines, one row per `SimEvent`
(`scrape`, `impact`, `drop`, `regrip`, `doorway`, `strain_warn`, `order`,
`phase`, `delivered`, `wrecked`) plus a mandatory trailing summary row carrying
`type`, `ticks`, `events` and `gameVersion`.
