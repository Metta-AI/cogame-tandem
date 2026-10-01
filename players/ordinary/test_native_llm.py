import json
import os
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from unittest.mock import patch

from player import choose
from policy import default_order
from test_policy import VIEW


class NativeLlmTest(unittest.TestCase):
    def test_prompt_policy_prefers_native_sidecar_without_provider_key(self):
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append((self.path, body))
                reply = json.dumps({"content": [{"text": json.dumps(default_order(VIEW))}]}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(reply)))
                self.end_headers()
                self.wfile.write(reply)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with patch.dict(os.environ, {
                "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{server.server_port}",
                "COWORLD_LLM_MODEL": "anthropic/claude-sonnet-4.6",
            }, clear=True):
                action, source, _, _ = choose({"view": VIEW}, None, "carry carefully")
                self.assertEqual(action, default_order(VIEW))
                self.assertEqual(source, "llm")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0][0], "/v1/messages")
        self.assertEqual(requests[0][1]["model"], "anthropic/claude-sonnet-4.6")
        self.assertNotIn("anthropic_version", requests[0][1])
