"""Identity-pinned access to a shared, already-running checkpoint gateway."""

from __future__ import annotations

import json
import os
import re
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlsplit


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


@dataclass(frozen=True)
class CheckpointClient:
    endpoint: str
    key: str = field(repr=False)
    identity: dict[str, str]

    @classmethod
    def from_environment(cls) -> CheckpointClient | None:
        names = (
            "TANDEM_CHECKPOINT_ENDPOINT",
            "TANDEM_CHECKPOINT_API_KEY",
            "TANDEM_CHECKPOINT_ATTESTATION",
        )
        values = [os.environ.get(name, "") for name in names]
        if not any(values):
            return None
        if not all(values):
            raise ValueError("Checkpoint endpoint, key and attestation are required together")
        if os.environ.get("TANDEM_ADAPTER_DIR"):
            raise ValueError("Checkpoint HTTP and legacy adapter modes cannot be combined")
        endpoint, key, filename = values
        parsed = urlsplit(endpoint)
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
            or any(not 33 <= ord(character) <= 126 for character in key)
        ):
            raise ValueError("Invalid checkpoint connection configuration")
        with Path(filename).open("rb") as stream:
            raw = stream.read(16385)
        if not 0 < len(raw) <= 16384:
            raise ValueError("Checkpoint attestation must be nonempty and at most 16KiB")
        identity = json.loads(raw)
        fields = {"model", "checkpoint_sha256", "tokenizer_sha256", "chat_template_sha256"}
        if not isinstance(identity, dict) or set(identity) != fields:
            raise ValueError("Checkpoint attestation has unsupported fields")
        if not isinstance(identity["model"], str) or not identity["model"].strip():
            raise ValueError("Checkpoint attestation requires a model name")
        if any(
            not isinstance(identity[name], str) or re.fullmatch(r"[0-9a-f]{64}", identity[name]) is None
            for name in fields - {"model"}
        ):
            raise ValueError("Checkpoint attestation requires SHA256 identities")
        return cls(endpoint.rstrip("/"), key, identity)

    def open(self, request: urllib.request.Request, timeout: float):
        return urllib.request.build_opener(_NoRedirect).open(request, timeout=timeout)

    def validate_headers(self, headers: dict[str, str]) -> None:
        expected = {
            "x-coworld-checkpoint-sha256": self.identity["checkpoint_sha256"],
            "x-coworld-tokenizer-sha256": self.identity["tokenizer_sha256"],
            "x-coworld-chat-template-sha256": self.identity["chat_template_sha256"],
        }
        actual = {name.lower(): value for name, value in headers.items()}
        if any(actual.get(name) != value for name, value in expected.items()):
            raise ValueError("Checkpoint response identity differs from the configured attestation")
