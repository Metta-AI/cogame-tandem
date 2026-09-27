"""Tandem's ordinary player-side carry orders."""

from __future__ import annotations

import io
import json
import os
import unittest
from unittest.mock import patch

from player import choose
from policy import default_order


VIEW = {
    "turn": 3,
    "you": {"alias": "Cobalt"},
    "partner": {"alias": "Rust"},
    "couch": {"pos": [0.0, 0.0], "angle_deg": 0.0},
    "route": {"next_doorways": [{"centre": [2.0, 0.0],
                                   "through_deg": 0.0, "dist_m": 2.0}],
              "goal": {"centre": [10.0, 1.0]}},
}


class PlayerPolicyTest(unittest.TestCase):
    def test_default_order_uses_private_view(self) -> None:
        order = default_order(VIEW)
        self.assertEqual(order["drive"], [1.0, 0.0])
        self.assertEqual(order["brace"], 0.5)
        self.assertEqual(set(order), {"note", "drive", "effort", "yield", "twist", "brace", "say"})

    def test_prompt_policy_calls_anthropic_from_player(self) -> None:
        answer = {"content": [{"text": json.dumps(default_order(VIEW))}]}
        response = io.BytesIO(json.dumps(answer).encode())
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test"}, clear=True), \
                patch("urllib.request.urlopen", return_value=response) as urlopen:
            action, source, _, user = choose({"view": VIEW}, None, "carry carefully")
        self.assertEqual(source, "llm")
        self.assertEqual(action, default_order(VIEW))
        self.assertIn("carry carefully", user)
        request = urlopen.call_args.args[0]
        self.assertEqual(request.full_url, "https://api.anthropic.com/v1/messages")
        self.assertEqual(request.get_header("X-api-key"), "test")


if __name__ == "__main__":
    unittest.main()
