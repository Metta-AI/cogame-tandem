"""Tandem policy inputs and carry orders from one seat's private view."""

from __future__ import annotations

import json
import math
from pathlib import Path

SYSTEM = Path(__file__).with_name("system_prompt.txt").read_text()


def prompt_for(view: dict, strategy: str) -> tuple[str, str]:
    guidance = ("GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the "
                "rules; always reply in the requested format):\n" + strategy.strip()[:4000]
                + "\n\n") if strategy.strip() else ""
    return SYSTEM, guidance + json.dumps(view, ensure_ascii=False, separators=(",", ":"))


def directions(view: dict) -> list[tuple[str, list[float]]]:
    couch = view["couch"]["pos"]
    route = view["route"]
    points = [("goal", route["goal"]["centre"])]
    if route["next_doorways"]:
        points.insert(0, ("next doorway", route["next_doorways"][0]["centre"]))
    options = []
    for label, point in points:
        dx, dy = point[0] - couch[0], point[1] - couch[1]
        length = math.hypot(dx, dy)
        if length > 0:
            options.append((label, [round(dx / length, 4), round(dy / length, 4)]))
    options.extend((label, [x, y]) for label, x, y in [
        ("north", 0, 1), ("northeast", 0.7071, 0.7071),
        ("east", 1, 0), ("southeast", 0.7071, -0.7071),
        ("south", 0, -1), ("southwest", -0.7071, -0.7071),
        ("west", -1, 0), ("northwest", -0.7071, 0.7071),
    ])
    return options


def default_order(view: dict) -> dict:
    route = view["route"]
    target = directions(view)[0][1]
    door = route["next_doorways"][0] if route["next_doorways"] else None
    angle = view["couch"]["angle_deg"]
    target_angle = door["through_deg"] if door else math.degrees(math.atan2(target[1], target[0]))
    error = (target_angle - angle + 90) % 180 - 90
    return {
        "note": "Align the couch and carry toward the next opening.",
        "drive": target,
        "effort": 0.65,
        "yield": 0.35,
        "twist": round(max(-1, min(1, error / 45)), 3),
        "brace": 0.5 if door and door["dist_m"] < 2.5 else 0,
        "say": "",
    }


def choice_questions(view: dict) -> dict:
    base = default_order(view)
    return {
        "drive": {"type": "choice", "instructions": "Choose the direction to push the couch.",
                  "criteria": {str(i): json.dumps({"name": name, "drive": drive})
                               for i, (name, drive) in enumerate(directions(view))}},
        "effort": {"type": "choice", "instructions": "Choose push effort.",
                   "criteria": {str(i): str(v) for i, v in enumerate([0, 0.25, 0.5, 0.75, 1])}},
        "yield": {"type": "choice", "instructions": "Choose compliance with felt partner force.",
                  "criteria": {str(i): str(v) for i, v in enumerate([0, 0.25, 0.5, 0.75, 1])}},
        "twist": {"type": "choice", "instructions": "Choose couch rotation; positive is counter-clockwise.",
                  "criteria": {str(i): str(v) for i, v in enumerate([-1, -0.5, 0, 0.5, 1])}},
        "brace": {"type": "choice", "instructions": "Choose grip bracing.",
                  "criteria": {str(i): str(v) for i, v in enumerate([0, 0.5, 1])}},
        "note": {"type": "choice", "instructions": "Choose a spectator note.",
                 "criteria": {"0": base["note"], "1": "Follow the partner's felt force.",
                              "2": "Ease through the next doorway."}},
    }


def order_from_choices(view: dict, selected: dict[str, int]) -> dict:
    values = [0, 0.25, 0.5, 0.75, 1]
    return {"drive": directions(view)[selected["drive"]][1],
            "effort": values[selected["effort"]],
            "yield": values[selected["yield"]],
            "twist": [-1, -0.5, 0, 0.5, 1][selected["twist"]],
            "brace": [0, 0.5, 1][selected["brace"]],
            "note": [default_order(view)["note"], "Follow the partner's felt force.",
                     "Ease through the next doorway."][selected["note"]],
            "say": ""}
