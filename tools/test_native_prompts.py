"""Complete native carries join player HTTP evidence to installed replay orders."""

import argparse
import json
import os
import socket
import subprocess
import sys
import threading
import time
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from uuid import NAMESPACE_URL, uuid5

from replay_summary import parse

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "players/ordinary"))
from policy import default_order  # noqa: E402
from prompts import PromptSelection  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--variant", choices=("default", "sprint"), default="default")
    parser.add_argument("--wording", default="canonical")
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--mode", choices=("accepted", "retry", "fallback"), default="accepted")
    args = parser.parse_args()
    assert not subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    manifest = json.loads((ROOT / "coworld_manifest_template.json").read_text())
    config = next(v["game_config"] for v in manifest["variants"] if v["id"] == args.variant)
    config.update(
        seed=args.seed,
        promptVariant=args.wording,
        promptSeed=4,
        tokens=["t0", "t1"],
        players=[{"name": f"policy-{i}"} for i in range(2)],
    )
    selection = PromptSelection.from_config(config)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    (output / "config.json").write_text(json.dumps(config))
    requests, counts = {}, {}
    lock = threading.Lock()

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, format, *arguments):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            user = body["messages"][0]["content"]
            view = json.loads(user[user.index("{") :])
            seat = ("Cobalt", "Rust").index(view["you"]["alias"])
            key = (view["turn"], seat)
            with lock:
                counts[key] = counts.get(key, 0) + 1
                attempt = counts[key]
            call_id = str(uuid5(NAMESPACE_URL, f"tandem-{key}-{attempt}"))
            proposal = default_order(view)
            proposal["note"] = f"fixture turn {view['turn']} seat {seat}"
            proposal["say"] = "spectators only"
            if args.mode == "fallback" or args.mode == "retry" and attempt == 1:
                proposal = {}
            raw = json.dumps({"content": [{"type": "text", "text": json.dumps(proposal)}]}).encode()
            with lock:
                requests[call_id] = {"body": body, "raw": raw.decode(), "seat": seat}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("X-Coworld-Call-Id", call_id)
            self.end_headers()
            self.wfile.write(raw)

    provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    thread.start()
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    env = os.environ.copy()
    for key in ("ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY_URI", "TANDEM_ADAPTER_DIR", "TANDEM_CAPTURE_TRAINING"):
        env.pop(key, None)
    env.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(output / "config.json").as_uri(),
        COGAME_RESULTS_URI=(output / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(output / "replay.bin").as_uri(),
        COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{provider.server_port}",
        COWORLD_LLM_MODEL="fixture/validation",
        TANDEM_HOST_TRACE_PATH=str(output / "host.jsonl"),
        TANDEM_SOURCE_REVISION=revision,
        PYTHONDONTWRITEBYTECODE="1",
    )
    processes, logs = [], []
    try:
        log = (output / "game.log").open("w")
        logs.append(log)
        game = subprocess.Popen([str(args.game.resolve())], cwd=ROOT, env=env, stdout=log, stderr=log)
        processes.append(game)
        for _ in range(400):
            assert game.poll() is None
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", port)) == 0:
                    break
            time.sleep(0.05)
        else:
            raise RuntimeError("host did not start")
        for seat in range(2):
            player_env = dict(
                env,
                PLAYER_PROMPT=f"PRIVATE-STRATEGY-{seat}: Deliver the couch.",
                TANDEM_PLAYER_TRACE_PATH=str(output / f"player-{seat}.jsonl"),
                TANDEM_CAPTURE_TRAINING="1",
                COWORLD_PLAYER_ARTIFACT_UPLOAD_URL=(output / f"policy_artifact_{seat}.zip").as_uri(),
                COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
            )
            log = (output / f"player-{seat}.log").open("w")
            logs.append(log)
            processes.append(
                subprocess.Popen(
                    [sys.executable, str(ROOT / "players/ordinary/player.py")],
                    cwd=ROOT,
                    env=player_env,
                    stdout=log,
                    stderr=log,
                )
            )
        assert game.wait(timeout=manifest["episode_timeout_minutes"] * 60 + 30) == 0
        for player in processes[1:]:
            assert player.wait(timeout=20) == 0
        result = json.loads((output / "results.json").read_text())
        assert result["reason"] == "complete"
        trace = output / "host.jsonl"
        rows = [json.loads(line) for line in trace.read_text().splitlines()]
        assert trace.stat().st_mode & 0o777 == 0o600
        assert rows[0]["source_revision"] == revision and rows[-1]["results"] == result
        decisions = [row for row in rows if row["event_type"] == "host_decision"]
        assert decisions and len(decisions) % 2 == 0
        replay = parse((output / "replay.bin").read_bytes())
        replay_orders = {(row["turn"], row["seat"]): row for row in replay["orders"]}
        used = set()
        for seat in range(2):
            path = output / f"player-{seat}.jsonl"
            assert path.stat().st_mode & 0o777 == 0o600
            events = [json.loads(line) for line in path.read_text().splitlines()]
            assert events[-1]["event_type"] == "final" and events[-1]["scores"] == result["scores"]
            sent = {e["attempt_id"]: e for e in events if e["event_type"] == "request"}
            received = {e["attempt_id"]: e for e in events if e["event_type"] == "response"}
            receipts = {e["turn"]: e for e in events if e["event_type"] == "receipt"}
            with zipfile.ZipFile(output / f"policy_artifact_{seat}.zip") as archive:
                artifact = json.loads(archive.read("trajectory.json"))
            assert artifact["complete"] and artifact["scores"] == result["scores"]
            accepted_rows = {row["tick"]: row for row in artifact["decisions"]}
            assert accepted_rows.keys() == {r["turn"] for r in decisions if r["seat"] == seat and r["accepted"]}
            for row in (r for r in decisions if r["seat"] == seat):
                assert replay_orders[(row["turn"], seat)]["q"] == row["q"]
                q = row["q"]
                action = row["executed_action"]
                assert action["drive"] == [q[0] / 4096, q[1] / 4096]
                assert [action[key] for key in ("effort", "yield", "twist", "brace")] == [
                    value / 255 for value in q[2:]
                ]
                assert receipts[row["turn"]]["executed_action"] == row["executed_action"]
                if row["accepted"]:
                    artifact_row = accepted_rows[row["turn"]]
                    assert json.loads(artifact_row["completion"][0]["content"]) == row["executed_action"]
                    assert artifact_row["prompt_template"] == sent[row["selected_attempt_id"]]["prompt_configuration"]
                assert len(row["attempts"]) == (1 if args.mode == "accepted" else 2)
                assert row["prompt_configuration"] == {
                    k: v for k, v in selection.metadata("", "").items() if not k.endswith("_sha256")
                }
                for index, attempt in enumerate(row["attempts"]):
                    identity = attempt["attempt_id"]
                    request, response = sent[identity], received[identity]
                    headers = {k.lower(): v for k, v in response["response_headers"].items()}
                    call_id = headers["x-coworld-call-id"]
                    assert call_id not in used
                    used.add(call_id)
                    expected = requests[call_id]
                    assert expected["seat"] == seat and expected["body"] == request["request"]
                    assert expected["raw"] == response["raw_response"] and response["http_status"] == 200
                    submitted = json.loads(attempt["raw_response"])
                    assert submitted["attempt_id"] == identity
                    assert submitted["action"] == json.loads(json.loads(response["raw_response"])["content"][0]["text"])
                    system, user = [m["content"] for m in request["prompt"]]
                    assert system == selection.system() and system == expected["body"]["system"]
                    assert request["prompt_configuration"] == selection.metadata(system, user)
                    assert user == expected["body"]["messages"][0]["content"]
                    assert json.loads(user[user.index("{") :]) == row["observation"]
                    assert f"PRIVATE-STRATEGY-{seat}:" in user
                    assert f"PRIVATE-STRATEGY-{1 - seat}:" not in user
                    assert attempt["accepted"] == (args.mode == "accepted" or args.mode == "retry" and index == 1)
                assert row["accepted"] == (args.mode != "fallback")
                assert receipts[row["turn"]]["selected_attempt_id"] == row["selected_attempt_id"]
                assert row["selected_attempt_id"] == (
                    "" if args.mode == "fallback" else row["attempts"][-1]["attempt_id"]
                )
        assert used == requests.keys()
        assert b"PRIVATE-STRATEGY-" not in (output / "replay.bin").read_bytes()
        (output / "proof.json").write_text(
            json.dumps(
                {
                    "source_revision": revision,
                    "variant": args.variant,
                    "wording": args.wording,
                    "mode": args.mode,
                    "decisions": len(decisions),
                    "http_requests": len(requests),
                }
            )
        )
        print(output.name, len(decisions), "decisions;", len(requests), "HTTP requests; PASS", flush=True)
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=10)
        for log in logs:
            log.close()
        provider.shutdown()
        provider.server_close()
        thread.join(timeout=10)


if __name__ == "__main__":
    main()
