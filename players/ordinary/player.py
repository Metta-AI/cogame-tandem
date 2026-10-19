"""Tandem decisions through the game's ordinary player WebSocket."""

from __future__ import annotations

import json
import os
import time
import urllib.request
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import websocket
from capture import Capture, append_evidence
from policy import default_order, prompt_for
from prompts import PromptSelection


def choose(turn: dict, generator, strategy: str) -> tuple[dict, str, str, str]:
    view = turn["view"]
    selection = PromptSelection.from_config(turn["prompt_configuration"])
    system, user = prompt_for(view, strategy, selection)
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
        endpoint = os.environ.get("COWORLD_LLM_ENDPOINT", "").rstrip("/")
        model = (
            os.environ.get("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
            if endpoint
            else os.environ.get("ANTHROPIC_MODEL", "claude-haiku-4-5-20251001")
        )
        body = json.dumps(
            {"model": model, "max_tokens": 500, "system": system, "messages": [{"role": "user", "content": user}]}
        ).encode()
        request = urllib.request.Request(
            (f"{endpoint}/v1/messages" if endpoint else "https://api.anthropic.com/v1/messages"),
            body,
            {
                "Content-Type": "application/json",
                "anthropic-version": "2023-06-01",
                "x-api-key": ("sidecar" if endpoint else os.environ["ANTHROPIC_API_KEY"]),
            },
            method="POST",
        )
        append_evidence(
            {
                "event_type": "request",
                "attempt_id": turn["attempt_id"],
                "turn": turn["turn"],
                "prompt_configuration": selection.metadata(system, user),
                "prompt": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                "request": json.loads(body),
            }
        )
        with urllib.request.urlopen(request, timeout=6) as response:
            raw_response = response.read().decode("utf-8")
            append_evidence(
                {
                    "event_type": "response",
                    "attempt_id": turn["attempt_id"],
                    "http_status": response.status,
                    "response_headers": dict(response.headers.items()),
                    "raw_response": raw_response,
                }
            )
            action = json.loads(json.loads(raw_response)["content"][0]["text"])
        return action, "llm", system, user
    return default_order(view), "heuristic", system, user


def main() -> None:
    trace = os.environ.get("TANDEM_PLAYER_TRACE_PATH", "")
    if trace:
        with os.fdopen(os.open(trace, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
            stream.write(
                json.dumps({"event_type": "player_start", "source_revision": os.environ["TANDEM_SOURCE_REVISION"]})
                + "\n"
            )
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
    pending: dict[int, tuple[str, str, dict, str, PromptSelection]] = {}
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
            action, source, system, user = choose(frame, generator, strategy)
            pending[frame["turn"]] = (
                system,
                user,
                action,
                source,
                PromptSelection.from_config(frame["prompt_configuration"]),
            )
            socket.send(
                json.dumps(
                    {
                        "type": "decision",
                        "turn": frame["turn"],
                        "attempt_id": frame["attempt_id"],
                        "action": action,
                        "source": source,
                    }
                )
            )
        elif kind == "decision_result":
            append_evidence({"event_type": "receipt", **frame})
            system, user, action, source, selection = pending.pop(frame["turn"])
            if artifact and frame["accepted"]:
                artifact.record(system, user, frame["executed_action"], source, frame["turn"], selection)
        elif kind == "final":
            append_evidence({"event_type": "final", **frame})
            if pending:
                raise RuntimeError("Tandem ended with unacknowledged decisions")
            if artifact:
                artifact.upload(frame["scores"], frame["reason"])
            break
    socket.close()
    print(f"Tandem ordinary player finished: slot={slot} backend={backend}", flush=True)


if __name__ == "__main__":
    main()
