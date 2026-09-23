"""Play both certified Tandem variants through the numeric training protocol."""

import json
import random
import subprocess
import sys
from pathlib import Path


def play(binary: Path, variant: str, teacher: bool) -> None:
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    process = subprocess.Popen(
        [str(binary), str(manifest), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(17)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": f"tandem-{variant}-{teacher}", "players": 2})
        widths = set()
        first_view = None
        decisions = 0
        while observation["kind"] == "decision":
            encoding = request({"kind": "encode"})
            assert encoding["decision_id"] == observation["decision_id"]
            widths.add(len(encoding["values"]))
            heads = encoding["action_heads"]
            assert [len(head["choices"]) for head in heads] == [360, 256, 256, 511, 256]
            for head in heads:
                assert observation["action_schema"]["properties"][head["name"]]["enum"] == head["choices"]
            view = observation["semantic_view"]
            assert "seed" not in view and "your_last_order" in view
            assert "partner_last_order" not in view
            if observation["seat"] == 0:
                first_view = (view["clock"], view["couch"])
            else:
                assert (view["clock"], view["couch"]) == first_view
            if teacher:
                action = json.loads(request({"kind": "teacher"})["response"])
            else:
                action = {head["name"]: rng.choice(head["choices"]) for head in heads}
            result = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions <= 120
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == {"0", "1"}
        assert observation["scores"]["0"] == observation["scores"]["1"]
        assert -1 <= observation["utilities"]["0"] <= 1
        assert observation["utilities"]["0"] == observation["utilities"]["1"]
        assert len(widths) == 1
        print(variant, "teacher" if teacher else "random", decisions, widths.pop(), "features")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


def check_no_channel(binary: Path) -> None:
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    partner_views = []
    for bearing in (0, 180):
        process = subprocess.Popen(
            [str(binary), str(manifest), "default"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert process.stdin is not None and process.stdout is not None

        def request(payload: dict) -> dict:
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        request({"kind": "reset", "seed": "tandem-no-channel", "players": 2})
        action = {"bearing_deg": bearing, "effort": 255, "yield": 0, "twist": 0, "brace": 0}
        partner = request({"kind": "step", "decision_id": 0, "response": json.dumps(action)})["observation"]
        assert partner["seat"] == 1
        partner_views.append(partner["semantic_view"])
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0
    assert partner_views[0] == partner_views[1]


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    check_no_channel(binary)
    for variant in ("default", "sprint"):
        for teacher in (True, False):
            play(binary, variant, teacher)
