"""Tandem decisions through the game's ordinary player WebSocket."""

from __future__ import annotations

import json
import math
import os
import time
import urllib.request
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import websocket
from capture import Capture


def choose(turn: dict, generator) -> tuple[dict, str]:
    candidates = turn["candidates"]
    if generator:
        completion = generator(
            [
                {"role": "system", "content": turn["system"]},
                {"role": "user", "content": turn["user"]},
            ]
        )
        action = json.loads(completion)
        if not isinstance(action, dict):
            raise ValueError("trained Tandem decision must be a JSON object")
        return action, "trained"
    if os.environ.get("TANDEM_JEV") != "1":
        return candidates[0], "canned"
    sidecar = os.environ.get("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "").strip()
    capture = os.environ.get("METTA_CAPTURE_URL", "").strip()
    if sidecar:
        endpoint, model, key = sidecar, "typesafe/jev-1.13", ""
    elif capture:
        endpoint = capture
        model = os.environ.get("METTA_CAPTURE_MODEL", "jev-latest")
        key = os.environ["METTA_CAPTURE_KEY"]
    else:
        endpoint = os.environ.get("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
        model = os.environ.get("TYPESAFE_DEFAULT_MODEL", "jev-latest")
        key = os.environ["TYPESAFE_API_KEY"]
    criteria = {
        str(index): json.dumps(candidate, sort_keys=True)
        for index, candidate in enumerate(candidates)
    }
    body = json.dumps(
        {
            "model": model,
            "state": {"policy": turn["system"], "summary": turn["user"]},
            "questions": {
                "action": {
                    "type": "choice",
                    "instructions": "Choose one complete Tandem carry order.",
                    "criteria": criteria,
                }
            },
        }
    ).encode()
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    request = urllib.request.Request(
        endpoint.rstrip("/") + "/v1/systemone", body, headers, method="POST"
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        answer = json.load(response)["answers"]["action"]
    if answer["type"] != "choice" or len(answer["probabilities"]) != len(candidates):
        raise ValueError("Jev returned the wrong Tandem decision catalog")
    probabilities = [answer["probabilities"][str(i)] for i in range(len(candidates))]
    if (
        any(
            not isinstance(p, (int, float)) or not math.isfinite(p) or p < 0 or p > 1
            for p in probabilities
        )
        or abs(sum(probabilities) - 1) > len(candidates) * 0.005 + 1e-6
    ):
        raise ValueError("Jev returned invalid Tandem decision probabilities")
    return candidates[max(range(len(candidates)), key=probabilities.__getitem__)], "jev"


def main() -> None:
    url = os.environ["COWORLD_PLAYER_WS_URL"]
    slot = int(parse_qs(urlsplit(url).query)["slot"][0])
    adapter = os.environ.get("TANDEM_ADAPTER_DIR")
    if adapter and os.environ.get("TANDEM_JEV") == "1":
        raise ValueError("select one Tandem policy backend")
    generator = None
    if adapter:
        from posttrain import TransformersGenerator

        generator = TransformersGenerator(Path(adapter))
    backend = "trained" if adapter else "jev" if os.environ.get("TANDEM_JEV") == "1" else "canned"
    artifact = Capture(slot, backend) if os.environ.get("TANDEM_CAPTURE_TRAINING") == "1" else None
    registration = json.dumps(
        {
            "type": "register",
            "prompt": os.environ.get("PLAYER_PROMPT", "")[:4000],
            "scripted": None,
            "external": True,
            "policy": os.environ.get("PLAYER_POLICY_LABEL", backend)[:128],
        }
    ).encode()
    packet = bytes([0x81]) + len(registration).to_bytes(2, "little") + registration
    deadline = time.monotonic() + 90
    while True:
        try:
            socket = websocket.create_connection(url, timeout=10)
            break
        except OSError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.25)
    socket.settimeout(120)
    socket.send(packet, opcode=websocket.ABNF.OPCODE_BINARY)
    re_registered = False
    calls = 0
    pending: dict[int, tuple[dict, dict, str]] = {}
    while True:
        opcode, data = socket.recv_data(control_frame=True)
        if opcode == websocket.ABNF.OPCODE_CLOSE:
            raise RuntimeError("Tandem closed before the final frame")
        if opcode == websocket.ABNF.OPCODE_BINARY:
            if not re_registered:
                socket.send(packet, opcode=websocket.ABNF.OPCODE_BINARY)
                re_registered = True
            socket.send(bytes([0x85]), opcode=websocket.ABNF.OPCODE_BINARY)
            continue
        if opcode != websocket.ABNF.OPCODE_TEXT:
            continue
        frame = json.loads(data)
        kind = frame["type"]
        if kind == "turn":
            action, source = choose(frame, generator)
            if source == "jev":
                calls += 1
            pending[frame["turn"]] = (frame, action, source)
            socket.send(json.dumps({"type": "decision", "turn": frame["turn"], "action": action}))
        elif kind == "decision_result":
            turn, action, source = pending.pop(frame["turn"])
            if artifact and frame["accepted"]:
                artifact.record(turn["system"], turn["user"], action, source, frame["turn"])
        elif kind == "final":
            if pending:
                raise RuntimeError("Tandem ended with unacknowledged decisions")
            if artifact:
                artifact.upload(frame["scores"], frame["reason"])
            break
    socket.close()
    print(f"Tandem ordinary player finished: slot={slot} backend={backend} Jev calls={calls}", flush=True)


if __name__ == "__main__":
    main()
