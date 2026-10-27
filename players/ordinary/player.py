"""Tandem decisions through the game's ordinary player WebSocket."""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import websocket
from capture import Capture
from policy import default_order, prompt_for
from prompts import PromptSelection


def choose(
    turn: dict, generator, strategy: str, evidence: dict | None = None, stage=None
) -> tuple[dict, str, str, str]:
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
            {
                "model": model,
                "max_tokens": 500,
                "system": system,
                "messages": [{"role": "user", "content": user}],
            }
        ).encode()
        payload = json.loads(body)
        if evidence is not None:
            evidence.update(
                origin="model",
                model=model,
                request=payload,
                prompt=[
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
                decoder={"max_tokens": 500},
            )
            if stage:
                stage("attempt_started", evidence)
        request = urllib.request.Request(
            (
                f"{endpoint}/v1/messages"
                if endpoint
                else "https://api.anthropic.com/v1/messages"
            ),
            body,
            {
                "Content-Type": "application/json",
                "anthropic-version": "2023-06-01",
                **(
                    {"X-Coworld-Player-Slot": str(turn["seat"])}
                    if endpoint and "seat" in turn
                    else {}
                ),
                **({} if endpoint else {"x-api-key": os.environ["ANTHROPIC_API_KEY"]}),
            },
            method="POST",
        )
        started = time.monotonic()
        try:
            response = urllib.request.urlopen(request, timeout=6)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read().decode("utf-8")
            headers = dict(response.headers.items())
            status = response.status
            if status is None:
                raise ValueError("provider response has no HTTP status")
        if evidence is not None:
            lower = {name.lower(): value for name, value in headers.items()}
            evidence.update(
                raw_response=raw,
                response_headers=headers,
                provider_request_id=lower.get("request-id", lower.get("x-request-id")),
                platform_call_id=lower.get("x-softmax-llm-call-id"),
                latency_ms=(time.monotonic() - started) * 1000,
                model_identity=lower.get("x-coworld-checkpoint-sha256"),
                tokenizer_identity=lower.get("x-coworld-tokenizer-sha256"),
                chat_template_sha256=lower.get("x-coworld-chat-template-sha256"),
            )
            if stage:
                stage("attempt_response", evidence)
        if not 200 <= status < 300:
            raise ValueError(f"provider HTTP {status}")
        payload = json.loads(raw)
        text = "".join(
            block.get("text", "")
            for block in payload["content"]
            if block.get("type", "text") == "text"
        )
        if evidence is not None:
            evidence.update(
                response=text,
                model=payload.get("model", model),
                stop_reason=payload.get("stop_reason"),
                input_tokens=payload.get("usage", {}).get("input_tokens"),
                output_tokens=payload.get("usage", {}).get("output_tokens"),
            )
            sampling = payload.get("sampling_evidence")
            if sampling:
                evidence.update(
                    prompt_token_ids=sampling["prompt_token_ids"],
                    sampled_token_ids=sampling["completion_token_ids"],
                    behavior_logprobs=sampling.get("behavior_log_probs"),
                )
        action = json.loads(text)
        if not isinstance(action, dict):
            raise ValueError("Tandem prompt response must be a JSON object")
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
    artifact = (
        Capture(slot, backend)
        if os.environ.get("TANDEM_CAPTURE_TRAINING") == "1"
        else None
    )
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
            evidence = {
                key: None
                for key in (
                    "model",
                    "prompt",
                    "request",
                    "response",
                    "raw_response",
                    "response_headers",
                    "provider_request_id",
                    "decoder",
                    "platform_call_id",
                    "rejection_reason",
                    "model_identity",
                    "tokenizer_identity",
                    "chat_template_sha256",
                    "stop_reason",
                    "latency_ms",
                    "input_tokens",
                    "output_tokens",
                    "prompt_token_ids",
                    "sampled_token_ids",
                    "behavior_logprobs",
                )
            }
            evidence.update(
                attempt_id=frame["attempt_id"], policy=backend, origin="unknown"
            )

            def stage(kind: str, retained: dict, issued: dict = frame) -> None:
                socket.send(
                    json.dumps(
                        {
                            "type": kind,
                            "turn": issued["turn"],
                            "attempt_id": issued["attempt_id"],
                            "training_attempt": retained,
                        }
                    )
                )

            try:
                action, source, system, user = choose(
                    frame, generator, strategy, evidence, stage
                )
            except (OSError, ValueError, KeyError, TypeError) as error:
                # Send an explicit rejected attempt so the game can retry inside its deadline.
                action, source = {}, "fallback"
                system, user = prompt_for(
                    frame["view"],
                    strategy,
                    PromptSelection.from_config(frame["prompt_configuration"]),
                )
                evidence["rejection_reason"] = type(error).__name__
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
                        "training_attempt": evidence,
                    }
                )
            )
        elif kind == "decision_result":
            system, user, action, source, selection = pending.pop(frame["turn"])
            if artifact and frame["accepted"]:
                artifact.record(system, user, action, source, frame["turn"], selection)
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
