# Tandem prompt diversity and training

The game and ordinary Python player share `players/ordinary/prompt_bank.json`.
The v2 bank varies force composition, privacy, timing, geometry, and damage
explanations. The response schema and strategic guidance remain fixed.
It states the actual delivery/non-delivery score formulas, correcting the
original vague claim that score comes half from time and half from condition.

Training presentations are `canonical`, `plain`, `numbered`, `questions`, and
`reordered`. `mixed` requires a nonnegative `promptSeed` and selects one of those
five once per episode, independently of course generation.
`heldout-briefing` and `heldout-reference` are evaluation-only; training exporters
reject them and bridge resets require `split: "validation"` or `split: "test"`.

## Complete-game collection

```sh
nim c -d:release --parallelBuild:1 --path:src -o:/tmp/tandem-train-bridge tools/train_bridge.nim
python3 tools/test_prompt_games.py /tmp/tandem-train-bridge
nim r --path:src tools/export_posttrain.nim /tmp/tandem-data 10 1 default mixed 0
```

Use `sprint` for the other certified variant. Exports contain `train.jsonl`,
`validation.jsonl`, and `manifest.json`. Every fifth seed belongs to validation.
Mixed wording cycles separately within each split. Scenario families group the
same course seed across variants, and rows retain exact message hashes.
Episode IDs include requested selection, resolved wording, and prompt seed to distinguish matched exports.
Both source views are frozen before orders are installed. Existing output
directories are rejected. Teacher orders use the native parser and simulator.

Ordinary players retain their original accepted-decision artifacts. The reader
preserves v1 wording and verifies stored messages without rewriting them;
new episodes use v2. See [ordinary collection](docs/TRAINING.md).

Complete-game comparisons establish mechanics and provenance, not learned
robustness. Learning comparisons must match game seeds, policies, and inference
settings, report failures and fallbacks, and reserve held-out wording until
training choices are frozen.

## Numeric training

The persistent bridge uses the certified variant configuration and each
seat's exact `seatViewJson` player view. It exposes 201 fixed numeric features,
including the local route, walls, pillars, own strain, and own last order.
The other seat's order is never included. Both seats decide from the same
pre-turn state. The five action heads are bearing in whole degrees, effort,
yield, and brace in 256 steps, and twist in 511 steps. The bridge converts
these choices to Tandem's six-field continuous order, then uses the production
parser, replay record, controller, and simulator. Bearing is an approximation
to the continuous drive direction. Both seats receive the game's joint score
and the bounded utility `2 * jointScore - 1` for policy optimization.

```sh
nim c -d:release --path:src -o:/tmp/tandem-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/tandem-train-bridge
```

From Metta, use `recipes.external.coworld_metta_rl.train` or
`recipes.external.coworld.train` with command
`["/tmp/tandem-train-bridge", "<source>/coworld_manifest_template.json", "default"]`
and `players=2`. Replace `default` with `sprint` for the second certified
variant. Set a finite timestep limit for either trainer.
