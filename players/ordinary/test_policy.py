"""Tandem's player-side carry order and System One questions."""

from __future__ import annotations

import io
import json
import os
import unittest
from unittest.mock import patch

from player import choose
from policy import choice_questions, default_order


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

    def test_jev_can_select_each_action_field(self) -> None:
        questions = choice_questions(VIEW)
        answers = {}
        for name, question in questions.items():
            count = len(question["criteria"])
            answers[name] = {"type": "choice", "probabilities": {
                str(i): 1.0 if i == count - 1 else 0.0 for i in range(count)
            }}
        response = io.BytesIO(json.dumps({"answers": answers}).encode())
        with patch.dict(os.environ, {"TANDEM_JEV": "1", "TYPESAFE_API_KEY": "test"}), \
                patch("urllib.request.urlopen", return_value=response) as urlopen:
            action, source, system, user = choose({"view": VIEW}, None, "")
        self.assertEqual(source, "jev")
        self.assertEqual(action["effort"], 1)
        self.assertEqual(action["yield"], 1)
        self.assertEqual(action["twist"], 1)
        self.assertEqual(action["brace"], 1)
        self.assertIn('"alias":"Cobalt"', user)
        self.assertIn("NO COMMUNICATION CHANNEL", system)
        body = json.loads(urlopen.call_args.args[0].data)
        self.assertEqual(set(body["questions"]), set(questions))

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
