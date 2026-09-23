# Metta post-training data

The native simulator and published `porter` and `mule` policies export
supervised examples for both certified Tandem variants:

```sh
nimby sync nimby.lock
for variant in default sprint; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/tandem-${variant}" 10 1 "$variant"
done
```

Each run reads the variant configuration from the Coworld manifest, adds the
per-seat tokens supplied by the hosted platform, and plays complete seeded
carries through the production order-record and control paths. At each
simultaneous turn, it records the seat's hosted system and user prompts and a
continuous order accepted by the game's reply parser. The parsed order drives
the simulation. `porter` controls Cobalt and `mule` controls Rust. Whole
carries stay in one split. The output manifest records source revision,
variant, joint score, delivery, ending reason, and row counts. Existing
output directories are never overwritten.

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/tandem-default \
  --output /tmp/tandem-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten complete carries yielded 800 training and 200 validation examples for
Default, and 480 and 120 for Sprint. All 1,600 examples fit the
Qwen2.5-0.5B-Instruct tokenizer in 4,096 tokens; the maximum was 1,555.
These examples distill scripted teachers; they do not establish stronger
league play.
One CPU optimizer step per variant with a local tiny model included every
example and reduced heldout loss, verifying the Metta post-training path.

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
