## The websocket contract: registration interception, the redaction, the join
## gate, the artifact writes and the TWO NAME SPACES.

import std/[json, os, strutils, unicode]
import lib/helpers
import tandem/[decide, server]
import tandem_player

proc registrationBecomesARedactedRecord() =
  let previous = SeatPolicy()
  let reg = registrationOf($ %*{
    "type": "register", "prompt": "carry it gently and brace in the door",
    "scripted": newJNull(), "policy": "tandem-anchor"}, Cobalt, previous)
  doAssert reg.ok, "a registration object was not recognised"
  doAssert reg.policy.kind == pkLlm
  doAssert reg.policy.prompt.len > 0
  doAssert reg.record.len > 0, "no register record was produced"
  doAssert "carry it gently" notin reg.record,
    "THE PROMPT LEAKED INTO THE REPLAY RECORD"
  let node = parseJson(reg.record)
  doAssert node["k"].getStr() == "register"
  doAssert node["policy"].getStr() == "tandem-anchor"
  doAssert node["kind"].getStr() == "llm"
  doAssert not node.hasKey("prompt")
  report "registration is consumed and recorded REDACTED"

proc externalRegistrationUsesTheSamePlayerSocket() =
  let reg = registrationOf($ %*{
    "type": "register", "prompt": "private operator guidance",
    "scripted": newJNull(), "external": true,
    "policy": "tandem-jev"}, Cobalt, SeatPolicy())
  doAssert reg.ok and reg.policy.kind == pkExternal
  doAssert reg.policy.prompt == "private operator guidance"
  doAssert parseJson(reg.record)["kind"].getStr() == "external"
  doAssert "private operator guidance" notin reg.record
  report "external policy registers through the player socket without leaking guidance"

proc unchangedResendEarnsNoRecord() =
  let first = registrationOf($ %*{
    "type": "register", "prompt": "", "scripted": %"mule",
    "policy": "tandem-mule"}, Rust, SeatPolicy())
  doAssert first.ok and first.policy.baseline == "mule"
  let again = registrationOf($ %*{
    "type": "register", "prompt": "", "scripted": %"mule",
    "policy": "tandem-mule"}, Rust, first.policy)
  doAssert again.ok
  doAssert again.record.len == 0,
    "an unchanged re-send earned a second register record"
  report "an unchanged re-send earns no second record"

proc longPromptIsTruncatedNotRejected() =
  let prompt = repeat("carry ", 2000)
  let reg = registrationOf($ %*{
    "type": "register", "prompt": prompt, "scripted": newJNull(),
    "policy": repeat("n", 300)}, Cobalt, SeatPolicy())
  doAssert reg.ok, "a long prompt was REJECTED instead of truncated"
  doAssert reg.policy.prompt.runeLen <= MaxPromptRunes,
    "the prompt is " & $reg.policy.prompt.runeLen & " runes"
  doAssert reg.policy.label.runeLen <= MaxPolicyRunes
  report "an over-long prompt is truncated, never rejected"

proc oversizePacketIsTruncatedNotDropped() =
  ## THROUGH THE REAL FRAMING, not beside it. The Sprite v1 chat frame carries
  ## a u16 length, so a registration over 65 535 bytes used to wrap it, be
  ## discarded by `readSpriteChatRaw`, and silently turn a champion seat into a
  ## porter. The note's rule is truncate, never reject.
  let prompt = repeat("carry-the-couch.", 20_000)   ## 320 000 bytes.
  doAssert prompt.len > 65_535
  let packet = chatPacket(registrationPayload(prompt, "", "tandem-anchor"))
  doAssert packet.len < 65_535 + 3,
    "the registration frame is " & $packet.len & " bytes; the u16 length " &
      "field cannot carry it"
  let text = readSpriteChatRaw(packet)
  doAssert text.len > 0, "THE OVERSIZE REGISTRATION FRAME WAS DROPPED"
  let reg = registrationOf(text, Cobalt, SeatPolicy())
  doAssert reg.ok, "the oversize registration was not recognised"
  doAssert reg.policy.kind == pkLlm,
    "an oversize prompt made the seat " & $reg.policy.kind
  doAssert reg.policy.prompt.runeLen == MaxPromptRunes,
    "the prompt survived as " & $reg.policy.prompt.runeLen & " runes"
  doAssert reg.policy.label == "tandem-anchor"
  # A multi-byte prompt is cut on a rune boundary, not mid-codepoint.
  let wide = repeat("\u{1F6CB}", 20_000)
  let wideText = readSpriteChatRaw(
    chatPacket(registrationPayload(wide, "", "wide")))
  doAssert wideText.len > 0 and isValidUtf8(wideText)
  let wideReg = registrationOf(wideText, Rust, SeatPolicy())
  doAssert wideReg.ok and wideReg.policy.prompt.runeLen == MaxPromptRunes
  doAssert isValidUtf8(wideReg.policy.prompt)
  report "an oversize registration frame is truncated, never dropped"

proc nonRegistrationChatIsDropped() =
  for text in ["hello there", "{\"k\":\"order\"}", "", "{"]:
    let reg = registrationOf(text, Cobalt, SeatPolicy())
    doAssert not reg.ok, "chat text `" & text & "` was taken as registration"
    doAssert reg.record.len == 0
  report "any other chat text from a seat is dropped"

proc seatWithNeitherFieldIsPorter() =
  let reg = registrationOf($ %*{
    "type": "register", "prompt": "", "scripted": newJNull(),
    "policy": ""}, Rust, SeatPolicy())
  doAssert reg.ok
  doAssert reg.policy.kind == pkScripted
  doAssert reg.policy.baseline == "porter",
    "a seat with neither field defaulted to " & reg.policy.baseline
  report "a seat that registers neither field plays porter"

proc joinGate() =
  var config = testConfig()
  doAssert config.playerJoinAllowed("a", 0, "t0")
  doAssert not config.playerJoinAllowed("a", 0, "wrong"),
    "a bad token was allowed onto slot 0"
  doAssert not config.playerJoinAllowed("a", 2, "t0"),
    "slot 2 was allowed in a two-seat game"
  doAssert not config.playerJoinAllowed("a", 9, ""),
    "an out-of-range slot was allowed"
  report "a bad slot or token is refused before the upgrade"

proc artifactsGoToFileUris() =
  let path = tempPath("results.json")
  removeFile(path)
  var sim = carryingSim(testConfig(maxTicks = 120))
  while sim.phase != GameOver and sim.tickCount < 900:
    sim.stepSim()
  writeFile(path, sim.playerResultsJson())
  doAssert fileExists(path)
  let node = parseJson(readFile(path))
  doAssert node["names"].len == 2 and node["scores"].len == 2
  removeFile(path)
  report "results write to a file:// URI as valid JSON"

proc twoNameSpaces() =
  ## The composed LLM user message and the board labels carry NO real player
  ## name — even with `showPlayerLabels` forced TRUE, because the guarantee is
  ## the vocabulary, not the flag. The chrome roster and `results.names` do.
  var config = testConfig()
  config.showPlayerLabels = true
  var sim = carryingSim(config)
  let engine = newTurnEngine(nil, nil)
  for seat in Seat:
    engine.policies[seat] = SeatPolicy(kind: pkLlm, prompt: "go", label: "x")
  for seat in Seat:
    let message = engine.userMessage(sim, seat, 3)
    for player in sim.players:
      doAssert player.address notin message,
        "the real name `" & player.address & "` leaked into the LLM view"
    doAssert seatAlias(seat) in message, "the seat's own alias is missing"
  let chrome = sim.buildStateJson(newJArray(), true, 1.0, 2400, false, true,
    -1, -1)
  var found = 0
  for player in sim.players:
    if player.address in chrome:
      inc found
  doAssert found == sim.players.len,
    "the chrome roster does not carry the real policy names"
  let results = sim.playerResultsJson()
  doAssert "cobalt-policy" in results and "rust-policy" in results,
    "results.names does not carry the real policy names"
  report "two name spaces: aliases in-game, real names spectator-side only"

when isMainModule:
  registrationBecomesARedactedRecord()
  externalRegistrationUsesTheSamePlayerSocket()
  unchangedResendEarnsNoRecord()
  longPromptIsTruncatedNotRejected()
  oversizePacketIsTruncatedNotDropped()
  nonRegistrationChatIsDropped()
  seatWithNeitherFieldIsPorter()
  joinGate()
  artifactsGoToFileUris()
  twoNameSpaces()
  echo "test_server: the websocket contract and the two name spaces hold"
