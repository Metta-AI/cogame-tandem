"""Exercise the installed ordinary caller's optional thinking control over real HTTP."""

import json
import os
import subprocess
import sys
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Event, Thread


class NativeThinkingSystemTest(unittest.TestCase):
    def test_real_caller_preserves_defaults_records_disabled_and_keeps_timeout(self):
        requests = []
        profile = {"delay": 0}
        finished = Event()

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                raw = self.rfile.read(int(self.headers["Content-Length"]))
                requests.append(
                    (
                        self.path,
                        self.headers.get("X-Coworld-Player-Slot"),
                        json.loads(raw),
                    )
                )
                time.sleep(profile["delay"])
                reply = json.dumps(
                    {
                        "model": "fixture/optional-thinking",
                        "content": [
                            {
                                "type": "text",
                                "text": json.dumps(
                                    {
                                        "drive": [1, 0],
                                        "effort": 0.5,
                                        "twist": 0,
                                        "brace": 0,
                                        "yield": 0.2,
                                        "note": "",
                                        "say": "",
                                    }
                                ),
                            }
                        ],
                        "stop_reason": "end_turn",
                    }
                ).encode()
                try:
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(reply)))
                    self.end_headers()
                    self.wfile.write(reply)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                finally:
                    finished.set()

            def log_message(self, *args):
                pass

        script = """
import json
from player import choose
from test_policy import VIEW
evidence={}
turn={'view':VIEW,'seat':0,'turn':3,'attempt_id':'3-0-1',
      'prompt_configuration':{'promptVariant':'canonical','promptSeed':0}}
action,source,system,user=choose(turn,None,'carry carefully',evidence)
print(json.dumps({'action':action,'source':source,'evidence':evidence}))
"""
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = {
            name: value
            for name, value in os.environ.items()
            if not name.startswith(("COWORLD_LLM_", "TANDEM_CHECKPOINT_", "ANTHROPIC_"))
        }
        env.update(
            COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{server.server_port}",
            COWORLD_LLM_MODEL="fixture/optional-thinking",
        )

        def run(thinking=None):
            settings = dict(env)
            if thinking is not None:
                settings["COWORLD_LLM_THINKING"] = thinking
            return subprocess.run(
                [sys.executable, "-c", script],
                cwd=Path(__file__).resolve().parent,
                env=settings,
                capture_output=True,
                text=True,
                timeout=12,
                check=False,
            )

        try:
            legacy = run()
            self.assertEqual(legacy.returncode, 0, legacy.stderr)
            old = json.loads(legacy.stdout)
            self.assertEqual(requests[-1][:2], ("/v1/messages", "0"))
            old_request = requests[-1][2]
            self.assertEqual(
                set(old_request), {"model", "system", "messages", "max_tokens"}
            )
            self.assertEqual(old["evidence"]["request"], old_request)
            self.assertEqual(old["evidence"]["decoder"], {"max_tokens": 500})
            disabled = run("disabled")
            self.assertEqual(disabled.returncode, 0, disabled.stderr)
            new = json.loads(disabled.stdout)
            self.assertEqual(new["action"], old["action"])
            self.assertEqual(
                requests[-1][2], old_request | {"thinking": {"type": "disabled"}}
            )
            self.assertEqual(new["evidence"]["request"], requests[-1][2])
            self.assertEqual(
                new["evidence"]["decoder"],
                {"max_tokens": 500, "thinking": {"type": "disabled"}},
            )
            self.assertEqual(requests[-1][2]["max_tokens"], 500)
            self.assertIsNone(
                new["evidence"].get("platform_call_id"),
                "This fixture supplies no authenticated teacher receipt",
            )

            for value in ["", "enabled", "adaptive", "none"]:
                with self.subTest(invalid=value):
                    before = len(requests)
                    rejected = run(value)
                    self.assertNotEqual(rejected.returncode, 0)
                    self.assertIn("must be omitted or disabled", rejected.stderr)
                    self.assertEqual(len(requests), before)

            profile["delay"] = 6.2
            finished.clear()
            before = len(requests)
            start = time.monotonic()
            timed_out = run("disabled")
            elapsed = time.monotonic() - start
            self.assertNotEqual(timed_out.returncode, 0)
            self.assertIn("timed out", timed_out.stderr)
            self.assertGreaterEqual(elapsed, 5.5)
            self.assertLess(elapsed, 9)
            self.assertEqual(len(requests), before + 1, "No hidden timeout retry")
            self.assertTrue(finished.wait(2), "Own fixture request must finish")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
