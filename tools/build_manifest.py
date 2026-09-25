#!/usr/bin/env python3
"""Regenerate coworld_manifest_template.json.

The manifest inlines README.md, docs/RULES.md, docs/PROTOCOL.md and
docs/CARRYING.md as `game.docs` text values, so the coworld page and the repo
can never drift. Run it after editing any of those, and commit the result:
`coworld build` reads the committed template, not this script.

    python3 tools/build_manifest.py
"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = "https://github.com/Metta-AI/cogame-tandem/tree/main"
IMAGE = "{{TANDEM_IMAGE}}"


def read(name):
    return (ROOT / name).read_text(encoding="utf-8")


def text(value):
    return {"type": "text", "value": value}


SEATS = [{"name": "Cobalt"}, {"name": "Rust"}]
SLOTS = [{"alias": "Cobalt"}, {"alias": "Rust"}]

PLAYER_PROTOCOL = """Two seats, one couch. Each seat connects to
ws://<host>:<port>/player?slot=N&token=T (0 = Cobalt, the fore handle;
1 = Rust, the aft handle) and immediately sends ONE Sprite v1 chat message
carrying its registration:

  {"type":"register","scripted":"porter"|"mule"|null,
   "policy":"<free label>"}

A bundled player with `scripted` set plays that baseline. A player with no
scripted baseline submits ordinary actions. Registration is re-sent once after
the first received frame, in case the first send raced slot registration. The
server records a `register` replay record with policy label and kind, and
drops any other chat text. Strategy prompts remain inside player containers.

An ordinary policy uses the same authenticated socket. Every turn it receives
a private JSON text frame with `type:turn`, `turn`, and `view`. It constructs
its own prompt and action, then replies with
`{"type":"decision","turn":N,"action":{...}}`. The game parses,
quantizes, and records that action through the same replay path as every
reply, then sends `{"type":"decision_result","turn":N,"accepted":true|false}`.
The final text frame carries the shared scores and end reason. The binary
Sprite frames and Ready packet remain unchanged, and no seat receives the
partner's private order.

After registration every seat receives one binary Sprite v1 frame per tick and
answers each with the Ready packet (0x85). The server computes both force
vectors from the recorded orders; Sprite input masks are ignored.

Every 48 ticks (2.0 s of sim time) the game requests both seats' actions
before waiting for either response. An action is one JSON object:

  {"note":"<=160 chars","drive":[x,y],"effort":0..1,"yield":0..1,
   "twist":-1..1,"brace":0..1,"say":"<=48 chars"}

`drive` is a direction in view coordinates (metres, world centre origin, y up);
its magnitude is ignored. `effort` scales the push along it (1 = 600 N).
`yield` is the compliance knob: at 1 the seat pushes 80 % of the way the force
it FEELS is already pulling it. `twist` rotates the couch (+1 = ccw); a positive
twist from both seats is a pure couple. `brace` halves the push and raises the
grip limit. `note` and `say` go to the spectator feed and are NEVER delivered to
the partner: there is no communication channel of any kind.

Parsing is tolerant (fences, prose prefixes, numeric strings, `drive` as an
object, integer percentages), a failed attempt is retried once, and two failures
fall back to the `porter` scripted order with a `fallback` record. Every
recorded string is truncated on RUNE boundaries."""

GLOBAL_PROTOCOL = """GET /global (websocket) is the spectator snapshot: the same
Sprite v1 binary stream as a seat's, with no self markers, plus the broadcast
chrome channel -- a reserved never-drawn 1x1 sprite (id 4090) whose LABEL
carries the chrome JSON frame (tick, phase, transport state, condition,
progress, doors cleared, both carriers' strain/grip/blame, the roster with REAL
policy names, the derived beat events, the whole-run condition curve and the
end-card state).

GET /healthz answers `healthy`. GET /client/global, GET /client/player and
GET /client/replay serve real HTML pages and none of them opens the player
socket. GET /replay-data returns the raw `.replay` bytes. /healthz and /global
keep answering for a bounded ~20 s after the artifacts are written.

REPLAYS ARE A STATIC WASM BUNDLE, NEVER A POD. The repo ships
tools/build_replay_viewer.sh, which compiles the SAME src/tandem/sim.nim and
src/tandem/control.nim to wasm32 through emscripten and bundles them with the
chrome; the manifest declares "replay_viewer": {"bundle":
"static-replay-viewer"}. The browser re-simulates every tick from the recorded
orders and checks its own gameHash against the recorded chain, so everything the
viewer needs is in the replay bytes and no server is contacted except S3 for the
file."""

CONFIG_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["tokens", "players"],
    "properties": {
        "tokens": {"type": "array", "minItems": 2, "maxItems": 2,
                   "items": {"type": "string"},
                   "description": "Per-slot auth tokens, positional."},
        "players": {"type": "array", "minItems": 2, "maxItems": 2,
                    "items": {"type": "object",
                              "properties": {"name": {"type": "string"}},
                              "additionalProperties": True},
                    "description": "Per-slot policy names (spectator side)."},
        "slots": {"type": "array", "minItems": 2, "maxItems": 2,
                  "items": {"type": "object",
                            "properties": {"alias": {"type": "string"}},
                            "additionalProperties": True},
                  "description": "Per-slot in-game aliases: Cobalt then Rust."},
        "closedRoster": {"type": "boolean", "default": False},
        "seed": {"type": "integer",
                 "description": "Course generator seed; randomised when unpinned."},
        "num_agents": {"type": "integer", "minimum": 2, "maximum": 2,
                       "default": 2},
        "minPlayers": {"type": "integer", "minimum": 1, "maximum": 2,
                       "default": 2},
        "maxTicks": {"type": "integer", "minimum": 1, "default": 2400},
        "maxGames": {"type": "integer", "minimum": 1, "default": 1},
        "turnTicks": {"type": "integer", "minimum": 1, "default": 48},
        "turnBudgetMs": {"type": "integer", "minimum": 1, "default": 7000},
        "attempt1Ms": {"type": "integer", "minimum": 1, "default": 4500},
        "retryMs": {"type": "integer", "minimum": 1, "default": 2000},
        "minBatchSpacingMs": {"type": "integer", "minimum": 0, "default": 4500,
                              "description": "Inter-turn wall floor for ordinary player decisions."},
        "wallClockBudgetSeconds": {"type": "integer", "minimum": 1,
                                   "maximum": 720, "default": 660},
        "lobbyJoinTimeoutTicks": {"type": "integer", "minimum": 0,
                                  "default": 2400},
        "startWaitTicks": {"type": "integer", "minimum": 0, "default": 24},
        "gameOverTicks": {"type": "integer", "minimum": 0, "default": 48},
        "regripTicks": {"type": "integer", "minimum": 0, "default": 48},
        "fastMode": {"type": "boolean", "default": True},
        "showPlayerLabels": {"type": "boolean", "default": False},
        "speed": {"type": "integer", "minimum": 1, "default": 1},
        "maxSeatForceMilliNewtons": {"type": "integer", "minimum": 1,
                                     "default": 600000},
        "gripLimitMilliNewtons": {"type": "integer", "minimum": 1,
                                  "default": 850000},
        "damageCap": {"type": "integer", "minimum": 1, "default": 1000},
    },
}

PAIR_INT = {"type": "array", "minItems": 2, "maxItems": 2,
            "items": {"type": "integer"}}
PAIR_STR = {"type": "array", "minItems": 2, "maxItems": 2,
            "items": {"type": "string"}}
PAIR_NUM = {"type": "array", "minItems": 2, "maxItems": 2,
            "items": {"type": "number"}}
PAIR_BOOL = {"type": "array", "minItems": 2, "maxItems": 2,
             "items": {"type": "boolean"}}

RESULTS_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["names", "scores", "win", "reason", "endRule", "delivered",
                 "damage", "jointScore"],
    "properties": {
        "names": PAIR_STR,
        "aliases": PAIR_STR,
        "policyKinds": PAIR_STR,
        "scores": PAIR_NUM,
        "win": PAIR_BOOL,
        "jointScore": {"type": "number"},
        "delivered": {"type": "boolean"},
        "damage": {"type": "integer"},
        "condition": {"type": "number"},
        "deliveryTicks": {"type": "integer"},
        "parTicks": {"type": "integer"},
        "progress": {"type": "number"},
        "drops": {"type": "integer"},
        "impacts": {"type": "integer"},
        "scrapeTicks": {"type": "integer"},
        "strainPeakNewtons": PAIR_INT,
        "blame": PAIR_INT,
        "llmTurns": PAIR_INT,
        "fallbackTurns": PAIR_INT,
        "reason": {"type": "string",
                   "enum": ["complete", "deadline", "fault"]},
        "endRule": {"type": "string",
                    "enum": ["delivered", "wrecked", "out_of_time",
                             "wall_clock", "sim_fault", "host_error"]},
        "finalTick": {"type": "integer"},
        "seed": {"type": "integer"},
    },
}


def variant(vid, name, description, max_ticks, wall_clock):
    return {
        "id": vid,
        "name": name,
        "description": description,
        "game_config": {
            "players": SEATS,
            "slots": SLOTS,
            "num_agents": 2,
            "minPlayers": 2,
            "maxTicks": max_ticks,
            "maxGames": 1,
            "turnTicks": 48,
            "turnBudgetMs": 7000,
            "attempt1Ms": 4500,
            "retryMs": 2000,
            "minBatchSpacingMs": 4500,
            "wallClockBudgetSeconds": wall_clock,
            "lobbyJoinTimeoutTicks": 2400,
            "startWaitTicks": 24,
            "gameOverTicks": 48,
            "regripTicks": 48,
            "fastMode": True,
            "showPlayerLabels": False,
        },
    }


manifest = {
    "$schema": "https://softmax.com/schemas/coworld-manifest-v1.json",
    "episode_timeout_minutes": 20,
    "tags": ["physics", "cooperative", "carrying", "continuous", "llm"],
    "game": {
        "name": "tandem",
        "owner": "daveey@gmail.com",
        "description": ("Two cogs, one couch, no channel: they are rigidly "
                        "gripped to opposite handles and must carry it through "
                        "a procedurally generated warehouse. The couch obeys "
                        "the SUM of their forces, so coordination happens "
                        "through the physics itself. Each player chooses a "
                        "carry order from its private view."),
        "runnable": {
            "type": "game",
            "image": IMAGE,
            "run": ["/bin/tandem"],
            "env": {},
            "source_url": SOURCE,
        },
        "replay_viewer": {"bundle": "static-replay-viewer"},
        "protocols": {
            "player": text(PLAYER_PROTOCOL),
            "global": text(GLOBAL_PROTOCOL),
        },
        "docs": {
            "readme": text(read("README.md")),
            "pages": [
                {"id": "rules.md", "title": "Rules",
                 "content": text(read("docs/RULES.md"))},
                {"id": "protocol.md", "title": "Wire protocol",
                 "content": text(read("docs/PROTOCOL.md"))},
                {"id": "carrying.md", "title": "Writing a tandem prompt",
                 "content": text(read("docs/CARRYING.md"))},
            ],
        },
        "config_schema": CONFIG_SCHEMA,
        "results_schema": RESULTS_SCHEMA,
    },
    "player": [
        {
            "id": "baseline",
            "type": "player",
            "name": "Tandem Porter Baseline",
            "description": ("Strain-arbitrated scripted carrier; no LLM. It "
                            "heads for the next doorway centre, lines the "
                            "couch axis up with the corridor, braces in the "
                            "gap and yields whenever the force it feels "
                            "opposes where it wants to go."),
            "image": IMAGE,
            "run": ["/bin/tandem-player"],
            "env": {"PLAYER_SCRIPTED": "porter"},
            "source_url": SOURCE,
            "resources": {
                "requests": {"cpu": "100m", "memory": "64Mi"},
                "limits": {"cpu": "1"},
            },
        }
    ],
    "variants": [
        variant("default", "Delivery (2 cogs, 100 s)",
                "Full course, 50 decision turns of 2 s.", 2400, 660),
        variant("sprint", "Sprint (2 cogs, 60 s)",
                "Same course generator, 30 decision turns, for cheap ladder "
                "rounds.", 1440, 420),
    ],
    "certification": {
        "players": [{"player_id": "baseline"}, {"player_id": "baseline"}],
        "game_config": {
            "players": SEATS,
            "slots": SLOTS,
            "num_agents": 2,
            "minPlayers": 2,
            "seed": 4417231,
            "maxTicks": 900,
            "maxGames": 1,
            "turnTicks": 48,
            "turnBudgetMs": 7000,
            "minBatchSpacingMs": 0,
            "wallClockBudgetSeconds": 180,
            "lobbyJoinTimeoutTicks": 1440,
            "fastMode": True,
        },
    },
}

out = ROOT / "coworld_manifest_template.json"
out.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
               encoding="utf-8")
print("wrote", out, out.stat().st_size, "bytes")
