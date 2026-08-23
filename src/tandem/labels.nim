## Sprite-label vocabulary: the machine-readable CONTRACT between the engine
## (the producer, `global.nim`) and anything reading the wire — the seat
## streams, the inspector, the sprite-dedup audit.
##
## A label is not a debug tag: it is the observation schema. Labels are
## computed at render time and never serialized (flatty writes `SimServer`
## positionally, so replays carry no label bytes) and nothing type-checks a
## label string, so renaming one is silent. Hoisting the strings to consts
## makes producer and consumer share one definition.
##
## **This module must keep ZERO imports.** Kept from ctf verbatim in spirit.

const
  LabelFloor* = "floor"
    ## One horizontal band of the baked warehouse floor. The board is banded so
    ## no single websocket frame exceeds the hosted replay's 1 MiB ceiling.
  LabelWall* = "wall"
    ## One static obstacle rectangle: the outer ring, a partition, a blocked
    ## cell or a pillar.
  LabelCouch* = "couch"
    ## The couch, drawn at the assembly pose. Its object position IS the
    ## couch centre in map pixels.
  LabelScuff* = "scuff"
    ## An accumulated damage decal on the couch.
  LabelCog* = "cog"
    ## One of the two carriers. The full label is `cog Cobalt` / `cog Rust` —
    ## the anonymous in-game identity, never a policy name.
  LabelForceArrow* = "force"
    ## The applied-force arrow at a handle, in that seat\'s livery colour.
  LabelStrainArrow* = "strain"
    ## The felt-strain arrow at a handle, in white. Together with the force
    ## arrow this is what makes "who pulled the wrong way" legible with no
    ## labels at all.
  LabelSpark* = "spark"
    ## A scrape spark burst at a contact point.
  LabelDust* = "dust"
    ## The dust cloud of a drop.
  LabelGoalPad* = "goal pad"
    ## The painted loading-bay rectangle the couch has to be delivered into.
  LabelDoorGlow* = "doorway"
    ## The glow on the doorway the couch is heading for.
  LabelSelfMarker* = "own cog"
    ## Marks the receiving seat\'s own cog. Player streams only.
  LabelOwnSeat* = "own seat"
    ## An invisible 1x1 marker naming the receiving seat\'s alias
    ## (`own seat Cobalt`). Player streams only; it is how a seat learns which
    ## cog is its own without ever seeing a real player name.
  LabelChrome* = "broadcast chrome"
    ## The reserved never-drawn 1x1 sprite whose LABEL carries the broadcast
    ## chrome JSON. It rides the binary sprite channel because that is the only
    ## channel that survives a hosted replay.

  ContractLabels*: array[13, string] = [
    LabelFloor, LabelWall, LabelCouch, LabelScuff, LabelCog, LabelForceArrow,
    LabelStrainArrow, LabelSpark, LabelDust, LabelGoalPad, LabelDoorGlow,
    LabelSelfMarker, LabelOwnSeat
  ]
    ## The golden vocabulary. `tests/test_viewer.nim` asserts the renderer
    ## emits nothing outside it (plus LabelChrome, which is not drawn).
