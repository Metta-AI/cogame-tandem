## Tolerant parsing and repair, and the rune-boundary truncation that keeps a
## replay parseable by a strict UTF-8 reader.

import std/[json, random, strutils, unicode]
import lib/helpers
import tandem/llm

proc parse(text: string, previous = emptyOrder(), hasPrevious = false):
    tuple[order: Order, usable: bool] =
  let payload = extractJsonObject(text)
  parseOrder(payload, previous, hasPrevious, emptyOrder(), 3)

proc prosePrefixed() =
  let got = parse("""Sure! Here is my carry plan:
```json
{"note":"easing in","drive":[0.6,-0.8],"effort":0.4,"yield":0.3,
 "twist":-0.5,"brace":0.9,"say":"you lead"}
```
Hope that helps.""")
  doAssert got.usable
  doAssert got.order.effort == 102, "effort quantised to " & $got.order.effort
  doAssert got.order.yieldQ == 77
  doAssert got.order.twist == -128, "twist quantised to " & $got.order.twist
  doAssert got.order.brace == 230
  doAssert got.order.note == "easing in"
  doAssert got.order.say == "you lead"
  let magnitude = speedOf(got.order.driveX, got.order.driveY)
  doAssert abs(magnitude - 4096) <= 2,
    "drive was not quantised to a unit vector: " & $magnitude
  report "a fenced, prose-prefixed reply parses"

proc percentagesAndStrings() =
  let got = parse("""{"drive":{"x":"1","y":"0"},"effort":"45","yield":80,
    "twist":"-25","brace":"0.5"}""")
  doAssert got.usable
  doAssert got.order.effort == 115, "45 % became " & $got.order.effort
  doAssert got.order.yieldQ == 204, "80 % became " & $got.order.yieldQ
  doAssert got.order.twist == -64, "-25 % became " & $got.order.twist
  doAssert got.order.brace == 128
  doAssert got.order.driveX == 4096 and got.order.driveY == 0
  report "integer percentages, numeric strings and object drive all repair"

proc missingAndNonFinite() =
  let got = parse("""{"note":"hm","drive":[0,0],"effort":null,"twist":"nope"}""")
  doAssert got.usable, "a reply with a usable note must not trigger the retry"
  doAssert got.order.effort == 128, "missing effort defaulted to " &
    $got.order.effort
  doAssert got.order.yieldQ == 64
  doAssert got.order.twist == 0
  doAssert got.order.brace == 0
  var previous = emptyOrder()
  previous.driveX = 0
  previous.driveY = 4096
  let kept = parse("""{"drive":[0,0],"effort":0.5}""", previous, true)
  doAssert kept.order.driveX == 0 and kept.order.driveY == 4096,
    "a zero drive did not fall back to last turn's"
  report "missing and non-finite fields repair to their documented defaults"

proc outOfRangeClamps() =
  let got = parse("""{"drive":[9,-9],"effort":4.5,"yield":-3,"twist":88,
    "brace":2}""")
  # 4.5 exceeds 1, so the percentage repair divides it by 100.
  doAssert got.order.effort == 11, "effort 4.5 became " & $got.order.effort
  doAssert got.order.yieldQ >= 0 and got.order.yieldQ <= 255
  doAssert got.order.twist >= -255 and got.order.twist <= 255
  doAssert got.order.brace >= 0 and got.order.brace <= 255
  doAssert speedOf(got.order.driveX, got.order.driveY) <= 4098
  report "out-of-range values clamp into the schema"

proc nothingUsable() =
  let got = parse("""{"weather":"fine"}""")
  doAssert not got.usable, "an empty object must trigger the retry"
  report "a reply with no usable field is not usable"

proc runeTruncation() =
  ## The 48th and 49th characters of `say` are a 4-byte emoji: the truncation
  ## must land on the RUNE boundary and the result must still round-trip
  ## through `%$` -> parseJson and decode as UTF-8.
  let padding = repeat("a", 47)
  let say = padding & "\u{1F6CB}\u{1F6CB}\u{1F6CB}"
  let note = repeat("n", 158) & "\u{1F6CB}\u{1F6CB}\u{1F6CB}"
  let body = $ %*{"note": note, "say": say, "drive": [1, 0], "effort": 0.5}
  let got = parse(body)
  doAssert got.usable
  doAssert got.order.say.runeLen <= MaxSayRunes,
    "say is " & $got.order.say.runeLen & " runes"
  doAssert got.order.note.runeLen <= MaxNoteRunes
  doAssert isValidUtf8(got.order.say), "say was cut mid-character"
  doAssert isValidUtf8(got.order.note), "note was cut mid-character"
  doAssert runeCount(got.order.say) == got.order.say.runeLen
  let record = capRecord($orderJson(carryingSim(testConfig()), Cobalt,
    got.order))
  doAssert isValidUtf8(record), "the order record is not valid UTF-8"
  let reparsed = parseJson(record)
  doAssert reparsed["k"].getStr() == "order"
  doAssert record.runeLen <= MaxOrderRecordRunes
  report "rune-boundary truncation survives a 4-byte emoji on the boundary"

proc oversizeRecordStaysJson() =
  ## An over-long record is shrunk STRUCTURALLY, so it is always parseable —
  ## a blind clip would cut the object mid-key and silently drop the order.
  var order = emptyOrder()
  order.note = repeat("\"\\", 200)
  order.say = repeat("\"\\", 100)
  let record = capRecord($orderJson(carryingSim(testConfig()), Rust, order))
  doAssert record.runeLen <= MaxOrderRecordRunes,
    "the record is " & $record.runeLen & " runes"
  let node = parseJson(record)
  doAssert node["k"].getStr() == "order"
  doAssert node.hasKey("q") and node["q"].len == 6,
    "the quantised order did not survive the structural shrink"
  report "an over-long order record shrinks structurally and stays JSON"

proc recordRoundTrips() =
  ## `orderJson` -> `orderFromRecord` is the exact path playback takes.
  var rng = initRand(4242)
  var sim = carryingSim(testConfig())
  for _ in 0 ..< 200:
    let order = pseudoOrder(rng)
    let record = capRecord($orderJson(sim, Cobalt, order))
    let back = orderFromRecord(parseJson(record))
    doAssert back.ok
    doAssert back.order.driveX == order.driveX
    doAssert back.order.driveY == order.driveY
    doAssert back.order.effort == order.effort
    doAssert back.order.yieldQ == order.yieldQ
    doAssert back.order.twist == order.twist
    doAssert back.order.brace == order.brace
  report "every quantised field round-trips through the replay record"

when isMainModule:
  prosePrefixed()
  percentagesAndStrings()
  missingAndNonFinite()
  outOfRangeClamps()
  nothingUsable()
  runeTruncation()
  oversizeRecordStaysJson()
  recordRoundTrips()
  echo "test_orders: parsing is tolerant and truncation is rune-safe"
