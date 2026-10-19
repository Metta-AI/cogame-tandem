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
uses `tandem-carry-v1`. These legacy player artifacts contain proposals and
acceptance flags, not authoritative installed-action evidence. They do not qualify
new prompt-fuzzing training data. The native scripted exporter produces private,
review-gated trajectory candidates instead:

```sh
nim c -d:release --path:src -o:/tmp/tandem-posttrain tools/export_posttrain.nim
/tmp/tandem-posttrain /tmp/tandem-data 10 1 default
```

The other certified variant is `sprint`. See [prompt selection and candidate
review](../TRAINING.md) for the native exporter and text bridge. The following
command applies only to previously prepared, reviewed training datasets:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/tandem-dataset --output /tmp/tandem-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```
