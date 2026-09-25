"""Tandem decisions through the game's ordinary player WebSocket."""

from __future__ import annotations

import json
import os
import time
import urllib.request
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import websocket
from capture import Capture
from policy import default_order, prompt_for


def choose(turn: dict, generator, strategy: str) -> tuple[dict, str, str, str]:
    view = turn["view"]
    system, user = prompt_for(view, strategy)
    if generator:
        completion = generator(
            [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ]
        )
        action = json.loads(completion)
        if not isinstance(action, dict):
            raise ValueError("trained Tandem decision must be a JSON object")
        return action, "trained", system, user
    if strategy:
        body = json.dumps({"model": os.environ.get("ANTHROPIC_MODEL", "claude-haiku-4-5"),
                           "max_tokens": 500, "system": system,
                           "messages": [{"role": "user", "content": user}]}).encode()
        request = urllib.request.Request(
            "https://api.anthropic.com/v1/messages", body,
            {"Content-Type": "application/json", "anthropic-version": "2023-06-01",
             "x-api-key": os.environ["ANTHROPIC_API_KEY"]}, method="POST")
        with urllib.request.urlopen(request, timeout=6) as response:
            action = json.loads(json.load(response)["content"][0]["text"])
        return action, "llm", system, user
    return default_order(view), "heuristic", system, user


def main() -> None:
    url = os.environ["COWORLD_PLAYER_WS_URL"]
    slot = int(parse_qs(urlsplit(url).query)["slot"][0])
    adapter = os.environ.get("TANDEM_ADAPTER_DIR")
    generator = None
    if adapter:
        from posttrain import TransformersGenerator

        generator = TransformersGenerator(Path(adapter))
    strategy = os.environ.get("PLAYER_PROMPT", "")
    backend = "trained" if adapter else "llm" if strategy else "heuristic"
    artifact = Capture(slot, backend) if os.environ.get("TANDEM_CAPTURE_TRAINING") == "1" else None
    registration = json.dumps(
        {
            "type": "register",
            "scripted": None,
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
    pending: dict[int, tuple[str, str, dict, str]] = {}
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
            if frame["turn"] not in pending:
                action, source, system, user = choose(frame, generator, strategy)
                pending[frame["turn"]] = (system, user, action, source)
            _, _, action, source = pending[frame["turn"]]
            socket.send(json.dumps({"type": "decision", "turn": frame["turn"],
                                    "action": action, "source": source}))
        elif kind == "decision_result":
            system, user, action, source = pending.pop(frame["turn"])
            if artifact and frame["accepted"]:
                artifact.record(system, user, action, source, frame["turn"])
        elif kind == "final":
            if pending:
                raise RuntimeError("Tandem ended with unacknowledged decisions")
            if artifact:
                artifact.upload(frame["scores"], frame["reason"])
            break
    socket.close()
    print(f"Tandem ordinary player finished: slot={slot} backend={backend}", flush=True)


if __name__ == "__main__":
    main()
