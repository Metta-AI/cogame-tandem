# Tuning the scripted baselines

Every tuning constant in `src/tandem/baselines.nim` is `{.intdefine.}`, so one
point of the grid is one recompile. The harness is **`tools/tune_baselines.nim`**
and it needs nothing but a Nim compiler — no docker, no emsdk, no network, no
fixture:

```bash
# the shipped configuration, over the committed seed list
nim r -d:release --path:src tools/tune_baselines.nim --eval

# a grid: one recompile per point, table sorted by porter x porter mean score
nim r -d:release --path:src tools/tune_baselines.nim \
  --sweep TandemTwistGain=3,5,8 --sweep TandemTwistDamp=0,4,8
```

`--eval` plays `porter x porter`, `porter x mule` and `mule x mule` over
`baselines.TuningSeeds` — the same twenty seeds `tests/test_baselines.nim` pins
— through the real control layer and the real `applyRecord` path, and prints
one JSON line: delivery count, mean score, mean damage, mean ticks, mean
progress and drops, beside the 29 constants the binary was compiled with. With
no `-d:` flags that line **is** the shipped configuration, so a pasted sweep log
names its own grid point and cannot drift from the source.

## The shipped point

```
$ nim r -d:release --path:src tools/tune_baselines.nim --eval
{"constants":{"TandemLookahead":2600000,"TandemDoorNear":1500000,
"TandemOpenEffort":255,"TandemOpenYield":51,"TandemConflictYield":140,
"TandemLeadYield":26,"TandemFollowYield":153,"TandemConflictEffort":128,
"TandemBraceHigh":217,"TandemStrainBrace":600000,"TandemTwistDead":7,
"TandemTwistGain":5,"TandemTwistDamp":4,"TandemSpinDead":768,
"TandemRamp":3000000,"TandemIdleEffort":12,"TandemMuleEffort":140,
"TandemPivotBox":1400000,"TandemCommitHyst":800000,"TandemStuckReach":1500000,
"TandemCellLead":1600000,"TandemConflictCos":2048,"TandemAlignBrads":22,
"TandemAlignRange":3500000,"TandemTurnEffort":90,"TandemEscapeEffort":140,
"TandemStuckSpeed":8000,"TandemBackOff":2500000,"TandemDoorApproach":2000000},
"pairings":[
 {"pairing":"porterxporter","delivered":20,"episodes":20,"mean_score":0.793727,
  "mean_damage":219,"mean_ticks":1524,"mean_progress_permille":1000,"drops":0},
 {"pairing":"porterxmule","delivered":0,"episodes":20,"mean_score":0.021507,
  "mean_damage":107,"mean_ticks":2400,"mean_progress_permille":103,"drops":0},
 {"pairing":"mulexmule","delivered":0,"episodes":20,"mean_score":0.01648,
  "mean_damage":63,"mean_ticks":2400,"mean_progress_permille":75,"drops":0}]}
```

Those are the same three numbers `tests/test_baselines.nim` prints (`porter mean
0.794`, `porter+mule progress 103 score 0.022`, `mule+mule progress 75 score
0.016`), which is the point: the anti-regression pin and the sweep measure the
same episodes.

## The sweeps the shipped constants came out of

Single-axis sweeps from the shipped point. Every line below is harness output,
trimmed to the columns that decide the constant.

### `TandemMuleEffort` — why `mule` ships at 0.55, not the note's 1.0

```
-d:TandemMuleEffort=64    porterxmule  1/20 score 0.068 | mulexmule 0/20 score 0.017
-d:TandemMuleEffort=140   porterxmule  0/20 score 0.022 | mulexmule 0/20 score 0.016
-d:TandemMuleEffort=200   porterxmule  0/20 score 0.018 | mulexmule 0/20 score 0.015
-d:TandemMuleEffort=255   porterxmule  0/20 score 0.016 | mulexmule 0/20 score 0.015
```

At the note's `effort = 1.0` (255) the mixed pairing scores **0.016 against mule
x mule's 0.015** — the filler erases its partner instead of testing it, which is
the measurement quoted in `baselines.nim`. `porter x porter` is untouched by this
axis (20/20, 0.794) at every point, as it must be.

### `TandemOpenEffort` — the cruise headroom

```
-d:TandemOpenEffort=128   porterxporter 18/20 score 0.637 dmg  68 ticks 2068
-d:TandemOpenEffort=160   porterxporter 19/20 score 0.704 dmg 128 ticks 1841
-d:TandemOpenEffort=200   porterxporter 18/20 score 0.695 dmg 186 ticks 1765
-d:TandemOpenEffort=255   porterxporter 20/20 score 0.794 dmg 219 ticks 1524
```

Full effort buys 20/20 deliveries and ~0.09–0.16 of mean score over every
throttled point; the cost is real (219 mean damage against 68 at half effort)
and it is the trade the score's equal weighting of speed and condition prices.

### `TandemTwistGain` x `TandemTwistDamp` — the alignment controller

```
-d:TandemTwistGain=2                       porterxporter 11/20 score 0.418
-d:TandemTwistGain=3                       porterxporter 16/20 score 0.651
-d:TandemTwistGain=5                       porterxporter 20/20 score 0.794
-d:TandemTwistGain=8                       porterxporter  7/20 score 0.311
-d:TandemTwistGain=12                      porterxporter  0/20 score 0.069

-d:TandemTwistGain=3 -d:TandemTwistDamp=0  porterxporter 20/20 score 0.769
-d:TandemTwistGain=3 -d:TandemTwistDamp=4  porterxporter 16/20 score 0.651
-d:TandemTwistGain=3 -d:TandemTwistDamp=8  porterxporter 12/20 score 0.457
-d:TandemTwistGain=5 -d:TandemTwistDamp=0  porterxporter 20/20 score 0.802 dmg 176
-d:TandemTwistGain=5 -d:TandemTwistDamp=4  porterxporter 20/20 score 0.794 dmg 219
-d:TandemTwistGain=5 -d:TandemTwistDamp=8  porterxporter  6/20 score 0.281
-d:TandemTwistGain=8 -d:TandemTwistDamp=0  porterxporter 19/20 score 0.756
-d:TandemTwistGain=8 -d:TandemTwistDamp=4  porterxporter  7/20 score 0.311
-d:TandemTwistGain=8 -d:TandemTwistDamp=8  porterxporter  1/20 score 0.099
```

Gain 5 is a clear ridge: 2 and 3 under-rotate and hang up on the jambs, 8 and 12
pinwheel. **The damping term is not load-bearing at the shipped gain** — at gain
5 the grid gives 20/20 for damp 0, 2 and 4, and damp 0 is 0.008 of mean score
ahead. It is kept at 4 as shipped rather than re-tuned here: moving a sim
constant moves the per-tick `gameHash` chain and the golden fixture with it, and
0.802 against 0.794 does not buy that. Recorded so the next tuning pass starts
from the measurement instead of the comment.

### `TandemCommitHyst` — the approach/exit switch

```
-d:TandemCommitHyst=0        porterxporter 20/20 score 0.770 dmg 157 ticks 1669
-d:TandemCommitHyst=400000   porterxporter 20/20 score 0.823 dmg 205 ticks 1446
-d:TandemCommitHyst=800000   porterxporter 20/20 score 0.794 dmg 219 ticks 1524
-d:TandemCommitHyst=1600000  porterxporter 19/20 score 0.715 dmg 238 ticks 1703
```

### `TandemLeadYield` — the conflict branch's compliance

```
-d:TandemLeadYield=26   porterxporter 20/20 score 0.794 | porterxmule 0/20 score 0.022
-d:TandemLeadYield=90   porterxporter 17/20 score 0.708 | porterxmule 0/20 score 0.020
-d:TandemLeadYield=140  porterxporter 19/20 score 0.793 | porterxmule 0/20 score 0.020
```

The note's 0.55 (140) for this branch costs a delivery and gains nothing against
a stranger, which is the divergence `baselines.nim` records.

## Reading the docstrings against this file

The failure-mode anecdotes in `baselines.nim` ("four of twenty seeds stopped
0.45 m from the start", "the couch never cleared a doorway") were observed at
**intermediate** points of the tuning, before the other constants reached the
values they ship at — a single-axis sweep from the finished configuration does
not always reproduce them, because the rest of the carry has since been fixed
around them. The numbers in this file are what the committed harness reproduces
from `main` today. Where a docstring's claim is a single-axis claim, it is
stated in the harness's terms and can be re-run in one command.
