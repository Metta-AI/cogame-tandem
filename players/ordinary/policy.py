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
