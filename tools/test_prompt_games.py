"""Complete carries preserve rules, outcomes and private views across wording choices."""

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "players/ordinary"))
from prompts import PromptSelection, PromptVariant  # noqa: E402


def play(binary: Path, variant: str, wording: str, prompt_seed: int, seed: int) -> str:
    process = subprocess.Popen(
        [str(binary), str(ROOT / "coworld_manifest_template.json"), variant, "text"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    assert process.stdin is not None and process.stdout is not None
    digest = hashlib.sha256()

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    def record(value: dict) -> None:
        digest.update(json.dumps(value, sort_keys=True).encode())

    selection = PromptSelection(PromptVariant(wording), prompt_seed)
    try:
        observation = request(
            {
                "kind": "reset",
                "players": 2,
                "seed": f"tandem-{seed}",
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "validation",
            }
        )
        decisions = 0
        first_view = None
        while observation["kind"] == "decision":
            system, user = [message["content"] for message in observation["messages"]]
            assert system == selection.system()
            view = observation["semantic_view"]
            assert view.pop("prompt_template") == selection.metadata(system, user)
            assert not {"seed", "partner_last_order", "prompt", "policies"} & view.keys()
            if observation["seat"] == 0:
                first_view = (view["clock"], view["couch"])
            else:
                assert (view["clock"], view["couch"]) == first_view
            observation["messages"][0]["content"] = "<game-owned rules>"
            record(observation)
            proposal = json.loads(request({"kind": "teacher"})["response"])
            proposal["note"] = f"private seat {observation['seat']} turn {observation['turn']}"
            proposal["say"] = "spectators only"
            response = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(proposal)}
            )
            assert response["kind"] == "accepted"
            record(response["action"])
            observation = response["observation"]
            decisions += 1
            assert decisions <= 120
        assert observation["kind"] == "terminal" and decisions > 0 and decisions % 2 == 0
        assert set(observation["scores"]) == {"0", "1"}
        assert observation["scores"]["0"] == observation["scores"]["1"]
        record(observation)
        return digest.hexdigest()
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=10) == 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    wordings = list(PromptVariant)[:-1]
    for variant in ("default", "sprint"):
        for seed in (17, 946001):
            reference = play(args.binary, variant, "canonical", 0, seed)
            for wording, prompt_seed in [(w.value, 0) for w in wordings[1:]] + [("mixed", 4)]:
                assert play(args.binary, variant, wording, prompt_seed, seed) == reference
        print(variant, "16 complete carries PASS", flush=True)
    for wording in wordings[-2:]:
        rejected = subprocess.run(
            [str(args.binary), str(ROOT / "coworld_manifest_template.json"), "default", "text"],
            input=json.dumps({"kind": "reset", "players": 2, "seed": "guard", "promptVariant": wording}) + "\n",
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        assert rejected.returncode != 0 and "held-out wording cannot enter training" in rejected.stderr
    print("32 complete carries and held-out exclusion PASS", flush=True)


if __name__ == "__main__":
    main()
