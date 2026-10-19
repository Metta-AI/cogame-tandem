"""Episode-stable game wording, independent of course randomness."""

import hashlib
import json
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path


class PromptVariant(StrEnum):
    CANONICAL = "canonical"
    PLAIN = "plain"
    NUMBERED = "numbered"
    QUESTIONS = "questions"
    REORDERED = "reordered"
    HELDOUT_BRIEFING = "heldout-briefing"
    HELDOUT_REFERENCE = "heldout-reference"
    MIXED = "mixed"


BANK_VERSION = "tandem-rules-v1"
TRAINING_VARIANTS = tuple(PromptVariant)[:5]
INTRODUCTIONS = json.loads(Path(__file__).with_name("prompt_introductions.json").read_text())
CANONICAL_SYSTEM = Path(__file__).with_name("system_prompt.txt").read_text()


@dataclass(frozen=True)
class PromptSelection:
    variant: PromptVariant
    seed: int

    @classmethod
    def from_config(cls, config: dict) -> "PromptSelection":
        variant = PromptVariant(config["promptVariant"] if "promptVariant" in config else "canonical")
        seed = config["promptSeed"] if "promptSeed" in config else 0
        if type(seed) is not int or seed < 0:
            raise ValueError("promptSeed must be a nonnegative integer")
        if variant == PromptVariant.MIXED and "promptSeed" not in config:
            raise ValueError("mixed wording requires an explicit promptSeed")
        return cls(variant, seed)

    @property
    def selected(self) -> PromptVariant:
        return TRAINING_VARIANTS[self.seed % 5] if self.variant == PromptVariant.MIXED else self.variant

    def system(self) -> str:
        return INTRODUCTIONS[self.selected] + "\n" + CANONICAL_SYSTEM.partition("\n")[2]

    def metadata(self, system: str, user: str) -> dict:
        return {
            "bank": BANK_VERSION,
            "variant": self.selected.value,
            "selection": self.variant.value,
            "seed": self.seed,
            "system_sha256": hashlib.sha256(system.encode()).hexdigest(),
            "user_sha256": hashlib.sha256(user.encode()).hexdigest(),
        }
