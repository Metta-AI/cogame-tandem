"""Use Coworld's pre-game readiness gate without extending gameplay deadlines."""

from __future__ import annotations

import os
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from urllib.parse import urlsplit


@contextmanager
def ready_before_game():
    url = os.environ.get("COWORLD_PLAYER_START_URL")
    if not url:
        if any(
            name in os.environ
            for name in ("TANDEM_STARTUP_PORT", "TANDEM_STARTUP_WAIT_SECONDS")
        ):
            raise ValueError("Startup settings require COWORLD_PLAYER_START_URL")
        yield
        return
    parsed = urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("COWORLD_PLAYER_START_URL must be an HTTP URL")
    port = int(os.environ.get("TANDEM_STARTUP_PORT", "8765"))
    seconds = float(os.environ.get("TANDEM_STARTUP_WAIT_SECONDS", "120"))
    if not 1024 <= port <= 65535 or not 0 < seconds <= 120:
        raise ValueError("Startup port or wait limit is outside its bounds")

    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from threading import Thread

    class Ready(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200 if self.path == "/healthz" else 404)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *args):
            pass

    with ThreadingHTTPServer(("0.0.0.0", port), Ready) as server:
        thread = Thread(
            target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True
        )
        thread.start()
        try:
            deadline = time.monotonic() + seconds
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("Game start gate exceeded its bounded wait")
                try:
                    with urllib.request.urlopen(
                        url, timeout=min(0.25, remaining)
                    ) as response:
                        if response.status != 200:
                            raise ValueError(
                                "Game start gate returned an unexpected status"
                            )
                    break
                except urllib.error.HTTPError as error:
                    if error.code != 503:
                        raise
                except (urllib.error.URLError, ConnectionError, TimeoutError):
                    # The game/worker may not exist yet during pre-game warmup.
                    pass
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("Game start gate exceeded its bounded wait")
                time.sleep(min(0.05, remaining))
            yield
        finally:
            server.shutdown()
            thread.join(timeout=2)
            if thread.is_alive():
                raise RuntimeError("Readiness server did not stop")
