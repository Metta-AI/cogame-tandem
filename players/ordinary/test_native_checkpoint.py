"""Run the ordinary player caller against a real authenticated HTTP fixture."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

from policy import default_order
from test_policy import VIEW


class NativeCheckpointSystemTest(unittest.TestCase):
    def test_real_caller_requires_authentication_and_exact_identity(self):
        identity = {
            "model": "synthetic-checkpoint-fixture-no-weights",
            "checkpoint_sha256": "a" * 64,
            "tokenizer_sha256": "b" * 64,
            "chat_template_sha256": "c" * 64,
        }
        key = "synthetic-checkpoint-fixture-key"
        headers = {
            "X-Coworld-Checkpoint-Sha256": identity["checkpoint_sha256"],
            "X-Coworld-Tokenizer-Sha256": identity["tokenizer_sha256"],
            "X-Coworld-Chat-Template-Sha256": identity["chat_template_sha256"],
        }
        requests, profile = [], {"kind": "valid"}

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append((self.path, self.headers.get("Authorization"), body))
                response_headers = dict(headers)
                status = 200
                response_model = identity["model"]
                if profile["kind"] == "unauthorized":
                    status = 401
                    response_headers = {}
                elif profile["kind"] == "redirect":
                    status = 302
                    response_headers = {"Location": "/must-not-follow"}
                elif profile["kind"] == "missing":
                    response_headers = {}
                elif profile["kind"] == "wrong-model":
                    response_model = "a-different-checkpoint"
                elif profile["kind"] in headers:
                    response_headers[profile["kind"]] = "d" * 64
                raw = json.dumps(
                    {
                        "model": response_model,
                        "content": [{"type": "text", "text": json.dumps(default_order(VIEW))}],
                        "stop_reason": "end_turn",
                    }
                ).encode()
                self.send_response(status)
                for name, value in response_headers.items():
                    self.send_header(name, value)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def log_message(self, *args):
                pass

            def do_GET(self):
                requests.append((self.path, self.headers.get("Authorization"), None))
                self.send_error(500, "Checkpoint requests must not follow redirects")

        code = """
import json,os,sys
from checkpoint_client import CheckpointClient
from player import choose
from test_policy import VIEW
turn={'view':VIEW,'seat':0,'turn':3,'attempt_id':'3-0-1',
      'prompt_configuration':{'promptVariant':'canonical','promptSeed':0}}
evidence={}
action,source,system,user=choose(turn,None,os.environ['TEST_STRATEGY'],evidence,
                               checkpoint=CheckpointClient.from_environment())
print(json.dumps({'action':action,'source':source,'evidence':evidence,
                  'torch_loaded':'torch' in sys.modules,'peft_loaded':'peft' in sys.modules}))
"""
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix="tandem-checkpoint-http-system-") as temporary:
                attestation = Path(temporary) / "attestation.json"
                attestation.write_text(json.dumps(identity))
                env = {
                    **os.environ,
                    "TANDEM_CHECKPOINT_ENDPOINT": f"http://127.0.0.1:{server.server_port}",
                    "TANDEM_CHECKPOINT_API_KEY": key,
                    "TANDEM_CHECKPOINT_ATTESTATION": str(attestation),
                    "COWORLD_LLM_ENDPOINT": "http://127.0.0.1:1",
                    "COWORLD_LLM_MODEL": "must-not-use-provider-or-other-model",
                }
                env.pop("TANDEM_ADAPTER_DIR", None)

                def run(strategy="carry carefully"):
                    return subprocess.run(
                        [sys.executable, "-c", code],
                        cwd=Path(__file__).resolve().parent,
                        env=env | {"TEST_STRATEGY": strategy},
                        capture_output=True,
                        text=True,
                        timeout=15,
                    )

                for strategy in ["", "carry carefully"]:
                    result = run(strategy)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    value = json.loads(result.stdout)
                    self.assertEqual(value["action"], default_order(VIEW))
                    self.assertEqual(value["source"], "llm")
                    self.assertFalse(value["torch_loaded"])
                    self.assertFalse(value["peft_loaded"])
                    self.assertEqual(value["evidence"]["decoder"], {"max_tokens": 500})
                    self.assertEqual(value["evidence"]["model_identity"], "a" * 64)
                    self.assertEqual(value["evidence"]["tokenizer_identity"], "b" * 64)
                    self.assertEqual(value["evidence"]["chat_template_sha256"], "c" * 64)
                    self.assertNotIn(key, result.stdout + result.stderr)
                    self.assertEqual(requests[-1][0], "/v1/messages")
                    self.assertEqual(requests[-1][1], "Bearer " + key)
                    self.assertEqual(set(requests[-1][2]), {"model", "system", "messages", "max_tokens"})
                    self.assertEqual(requests[-1][2]["model"], identity["model"])

                for mode in [*headers, "missing", "wrong-model", "unauthorized", "redirect"]:
                    with self.subTest(mode=mode):
                        profile["kind"] = mode
                        before = len(requests)
                        result = run()
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(len(requests), before + 1, "No retry or provider fallback")
                        self.assertIn("ValueError", result.stderr)
                        self.assertNotIn(key, result.stdout + result.stderr)

                profile["kind"] = "valid"
                attestation.write_text(json.dumps(identity | {"checkpoint_sha256": "invalid"}))
                before = len(requests)
                result = run()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(requests), before, "Invalid expected identity fails before HTTP")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
