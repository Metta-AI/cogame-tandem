# Tandem training

Build `Dockerfile.ordinary-player` and seat the resulting image as a normal
Coworld player. The original `baseline` roster remains the certification
fixture. An ordinary player uses the authenticated Sprite player socket. Each
turn, it receives a private view and constructs its own prompt and action.
The game parses its complete carry order and installs the quantized
order through the replay record.

The default policy builds a view-based carry order. `TANDEM_ADAPTER_DIR` loads a trained adapter from
the player image with its matching local base model, PyTorch, Transformers,
and PEFT installed. The player's `PLAYER_PROMPT` remains private to its seat.

Set `TANDEM_CAPTURE_TRAINING=1` and `TANDEM_SOURCE_REVISION` to upload
accepted decisions as the standard player artifact. The game sends an
acceptance receipt for each decision and a final score frame before it writes
results. Export at least two complete seeds:

```sh
python3 players/ordinary/export.py /tmp/tandem-dataset \
  /tmp/tandem-run-14 /tmp/tandem-run-15 \
  --source-revision <game-source-sha> --source heuristic
```

The exporter splits whole seeds into train and validation, rejects deadline
and fault endings, and checks the source revision and game scores. Output
uses `tandem-carry-v1`, matching the native exporter:

```sh
nim c -d:release --path:src -o:/tmp/tandem-posttrain tools/export_posttrain.nim
/tmp/tandem-posttrain /tmp/tandem-data 10 1 default
```

The other certified variant is `sprint`. Both methods emit Metta post-training
JSONL with player-constructed prompts and complete accepted actions. Use the [post-training research package](https://github.com/Metta-AI/posttraining-research/tree/main/packages/metta-posttraining)
for current training and adapter-packaging workflows.

Ordinary export IDs include the complete capture hash. Matched wording runs may
share a scenario seed and remain in the same split; duplicate captures are rejected.

## Prompt selection and stored artifacts

The game sends episode-stable `promptVariant` and `promptSeed` settings to the
ordinary player. The player and native bridge consume the same complete v2
bank. Deploy both game and ordinary player changes together.

Accepted-decision artifacts record exact message hashes. Export rejects held-out
wording and validates each stored bank against its original text. Original v1
artifacts remain readable, including canonical artifacts without prompt metadata.
Current v2 prompts correct the score description; stored messages are never rewritten.

See [prompt diversity](../TRAINING.md) for selection, exports, and evaluation.
