## Roster machinery: slot identities and limits, join/auth resolution, reward
## accounts, addPlayer/removePlayerAt, and `playerResultsJson`. Kept in ctf's
## shape; sole runtime consumer beyond the sim loop is server.nim.
##
## The results document must equal the manifest's `results_schema` KEY FOR KEY:
## that schema is `additionalProperties: false` and the certifier rejects any
## unknown field. ctf carries the scar (`shotsFired`/`shotsHit` were pulled
## back out of the payload for exactly this reason), so adding or removing a
## key here means editing coworld_manifest_template.json in the same commit —
## tests/test_manifest.nim fails until they agree.

import
  std/json,
  sim, orders

proc canAddPlayer*(sim: SimServer): bool {.inline.} =
  sim.players.len < MaxPlayers

proc nextPlayerSlot*(sim: SimServer): int {.inline.} =
  ## Joins are strictly slot-sequential, so the seat a lobby is stuck waiting
  ## on is exactly this.
  sim.players.len

proc slotOfAddress(sim: SimServer, address: string): int =
  for i, player in sim.players:
    if player.address == address:
      return i
  -1

proc resolvePlayerSlot*(
  sim: SimServer,
  address: string,
  token: string,
  requestedSlot: int
): int =
  ## Where a pending connection wants to sit. An explicit slot wins; a token
  ## that matches a configured slot comes next; otherwise the next free seat.
  if requestedSlot >= 0 and requestedSlot < MaxPlayers:
    return requestedSlot
  if token.len > 0:
    for i, entry in sim.config.slots:
      if entry.token.len > 0 and entry.token == token:
        return i
  let existing = sim.slotOfAddress(address)
  if existing >= 0:
    return existing
  sim.nextPlayerSlot()

proc rewardAccountFor*(sim: var SimServer, address: string): int =
  for i in 0 ..< sim.rewardAccounts.len:
    if sim.rewardAccounts[i].address == address:
      return i
  sim.rewardAccounts.add RewardAccount(
    address: address, slotIndex: int32(sim.rewardAccounts.len))
  sim.rewardAccounts.len - 1

proc addPlayer*(
  sim: var SimServer,
  address: string,
  requestedSlot: int,
  token: string,
  trusted = false
): int =
  ## Seats one connection. Slot 0 is Cobalt (the FORE handle), slot 1 is Rust
  ## (the AFT handle) — the seat is a property of the SLOT, never of the
  ## connection order, so a replay re-seats exactly as the live episode did.
  if sim.players.len >= MaxPlayers:
    raise newException(TandemError, "the couch already has two carriers")
  let slot = sim.players.len
  if not trusted and requestedSlot >= 0 and requestedSlot != slot:
    raise newException(TandemError,
      "player slot " & $requestedSlot & " is not the next open seat")
  let seat = if slot == 0: Cobalt else: Rust
  sim.players.add Player(
    address: address,
    joinOrder: int32(slot),
    seat: seat,
    policyLabel: policyName(address),
    policyKind: pkScripted,
    baseline: "porter"
  )
  let account = sim.rewardAccountFor(address)
  sim.rewardAccounts[account].seat = seat
  sim.rewardAccounts[account].hasSeat = true
  inc sim.rewardAccounts[account].games[seat]
  sim.nextJoinOrder = int32(sim.players.len)
  sim.logGameEvent("cog joined: " & address & " as " & seatAlias(seat) &
    " (" & handleText(seat) & " handle)")
  discard token
  slot

proc removePlayerAt*(sim: var SimServer, index: int) =
  ## Removes a roster entry. THE ASSEMBLY IS NOT TOUCHED: both cogs stay
  ## gripped for the whole episode, so unlike ctf (a per-player game) nothing
  ## renumbers when a seat leaves — see the second named edit in replays.nim.
  if index < 0 or index >= sim.players.len:
    return
  sim.logGameEvent("cog left: " & sim.players[index].address)
  sim.players.delete(index)

proc recordGameAbandon*(sim: var SimServer, index: int) =
  if index < 0 or index >= sim.players.len:
    return
  let account = sim.rewardAccountFor(sim.players[index].address)
  sim.rewardAccounts[account].abandoned = true

proc playerFor*(sim: SimServer, seat: Seat): int =
  for i, player in sim.players:
    if player.seat == seat:
      return i
  -1

proc seatName*(sim: SimServer, seat: Seat): string =
  ## The REAL policy name (spectator side). Falls back to the configured slot
  ## name, then to the alias, so results are never empty.
  let index = sim.playerFor(seat)
  if index >= 0 and sim.players[index].address.len > 0:
    return sim.players[index].address
  let slot = ord(seat)
  if slot < sim.config.slots.len and sim.config.slots[slot].name.len > 0:
    return sim.config.slots[slot].name
  seatAlias(seat)

proc seatPolicyKind*(sim: SimServer, seat: Seat): PolicyKind =
  let index = sim.playerFor(seat)
  if index >= 0: sim.players[index].policyKind else: pkScripted

proc jointScore*(sim: SimServer): float =
  ## The ONE number both seats receive. Computed in integer millionths and
  ## divided once, so the two copies are bit-identical.
  float(sim.scoreMicros()) / 1_000_000.0

proc playerResultsJson*(sim: SimServer): string =
  ## The results artifact. Exactly the keys the manifest's `results_schema`
  ## declares, every per-seat array of length two, in seat order.
  let score = sim.jointScore()
  var
    names = newJArray()
    aliases = newJArray()
    kinds = newJArray()
    scores = newJArray()
    win = newJArray()
    strainPeak = newJArray()
    blame = newJArray()
    llmTurns = newJArray()
    fallbackTurns = newJArray()
  for seat in Seat:
    names.add(%sim.seatName(seat))
    aliases.add(%seatAlias(seat))
    kinds.add(%policyKindText(sim.seatPolicyKind(seat)))
    scores.add(%score)
    win.add(%sim.delivered())
    strainPeak.add(%int(sim.stats[seat].strainPeak div 1000))
    blame.add(%int(sim.stats[seat].blame))
    llmTurns.add(%int(sim.stats[seat].llmTurns))
    fallbackTurns.add(%int(sim.stats[seat].fallbackTurns))
  $(%*{
    "names": names,
    "aliases": aliases,
    "policyKinds": kinds,
    "scores": scores,
    "win": win,
    "jointScore": score,
    "delivered": sim.delivered(),
    "damage": int(sim.damage),
    "condition": round6(float(sim.conditionPermille()) / 1000.0),
    "deliveryTicks":
      (if sim.delivered(): int(sim.deliveryTick) else: sim.tickCount),
    "parTicks": sim.parTicks(),
    "progress": round6(float(sim.bestProgressPermille) / 1000.0),
    "drops": int(sim.drops),
    "impacts": int(sim.impacts),
    "scrapeTicks": int(sim.scrapeTicks),
    "strainPeakNewtons": strainPeak,
    "blame": blame,
    "llmTurns": llmTurns,
    "fallbackTurns": fallbackTurns,
    "reason": reasonText(sim.endReason),
    "endRule": endRuleText(sim.endRule),
    "finalTick": sim.tickCount,
    "seed": sim.config.seed
  })

proc resultRecordJson*(sim: SimServer): string =
  ## The `result` replay chat record: the full results document, written once
  ## at game over so `tools/replay_summary.py` can report the outcome from the
  ## bytes alone.
  $(%*{"k": "result", "results": parseJson(sim.playerResultsJson())})
