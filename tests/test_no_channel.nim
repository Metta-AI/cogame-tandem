## NO CHANNEL. The hard invariant of the whole design, asserted against the
## composed LLM user message over 200 randomised order pairs.

import std/[json, random, strutils]
import lib/helpers
import tandem/decide

proc engineFor(sim: SimServer): TurnEngine =
  result = newTurnEngine(nil)
  for seat in Seat:
    result.policies[seat] = SeatPolicy(kind: pkExternal,
      label: "x", connected: true)
  discard sim

proc numericFields(order: Order): seq[string] =
  ## Every numeric field of an order, as the strings they would serialize to.
  @[$order.driveX, $order.driveY, $order.effort, $order.yieldQ,
    $order.twist, $order.brace]

proc viewCarriesNothingOfThePartner() =
  var rng = initRand(6060)
  var sim = carryingSim(testConfig())
  let engine = engineFor(sim)
  for i in 0 ..< 200:
    sim.pseudoWorld(rng)
    var orders: array[SeatCount, Order]
    for seat in Seat:
      var order = pseudoOrder(rng)
      # Give the partner's strings a shape that could not occur by accident.
      order.note = "PARTNERNOTE" & $rng.rand(1_000_000_000) & "Z"
      order.say = "PARTNERSAY" & $rng.rand(1_000_000_000) & "Z"
      order.effort = int32(200 + rng.rand(55))
      order.brace = int32(180 + rng.rand(70))
      orders[ord(seat)] = order
      sim.activeOrder[ord(seat)] = order
      engine.previous[seat] = order
      engine.hasPrevious[seat] = true
    for seat in Seat:
      let partner = other(seat)
      let message = engine.userMessage(sim, seat, i)
      doAssert orders[ord(partner)].note notin message,
        "the partner's NOTE reached seat " & $ord(seat)
      doAssert orders[ord(partner)].say notin message,
        "the partner's SAY reached seat " & $ord(seat)
      # The partner's own strings must be absent, and the message must carry
      # the seat's OWN last order (which is what `your_last_order` is for).
      doAssert orders[ord(seat)].note in message,
        "the seat's own last note is missing from its own view"
      let node = parseJson(message[message.find('{') .. ^1])
      doAssert not node.hasKey("partner_order")
      let partnerView = node["partner"]
      doAssert partnerView.len == 3,
        "the partner block carries " & $partnerView.len & " fields, not 3"
      doAssert partnerView.hasKey("alias") and partnerView.hasKey("handle") and
        partnerView.hasKey("pos"),
        "the partner block is not {alias, handle, pos}"
  report "200 randomised order pairs: no partner note or say ever crosses"

proc numericOrderFieldsDoNotCross() =
  ## A weaker but sharper check: give the partner an order whose numeric fields
  ## are impossible values elsewhere in the view, and look for them.
  var sim = carryingSim(testConfig())
  let engine = engineFor(sim)
  var loud = emptyOrder()
  loud.effort = 251
  loud.yieldQ = 249
  loud.twist = -253
  loud.brace = 247
  loud.note = "LOUD"
  loud.say = "LOUD"
  sim.activeOrder[ord(Rust)] = loud
  engine.previous[Rust] = loud
  engine.hasPrevious[Rust] = true
  let message = engine.userMessage(sim, Cobalt, 5)
  let node = parseJson(message[message.find('{') .. ^1])
  let serialized = $node
  for field in numericFields(loud):
    doAssert ("\"q\":[" & field) notin serialized
  doAssert "LOUD" notin serialized, "a partner string reached the view"
  report "no quantised field of the partner's order reaches the other seat"

proc controlLayerCannotPeek() =
  ## Structural: `control.seatForce` reads ONLY this seat's order and this
  ## seat's felt strain. Changing the PARTNER's order alone cannot change this
  ## seat's force.
  var rng = initRand(4321)
  var sim = carryingSim(testConfig())
  for _ in 0 ..< 200:
    sim.pseudoWorld(rng)
    sim.activeOrder[ord(Cobalt)] = pseudoOrder(rng)
    sim.activeOrder[ord(Rust)] = pseudoOrder(rng)
    let before = sim.seatForce(Cobalt)
    sim.activeOrder[ord(Rust)] = pseudoOrder(rng)
    let after = sim.seatForce(Cobalt)
    doAssert before.force == after.force,
      "the partner's order changed this seat's compiled force"
    doAssert before.gripLimit == after.gripLimit
  report "the control layer's force depends only on this seat's own order"

proc theOnlyChannelIsPhysics() =
  ## And the channel that DOES exist: what a seat feels depends on what the
  ## partner did, through the body and nothing else.
  var a = carryingSim(testConfig())
  var b = carryingSim(testConfig())
  a.step([(300_000'i32, 0'i32), (0'i32, 0'i32)])
  b.step([(300_000'i32, 0'i32), (300_000'i32, 0'i32)])
  doAssert a.strainX[0] != b.strainX[0],
    "the felt strain did not change when the PARTNER's force did"
  report "the only channel is the force in your own hands"

when isMainModule:
  viewCarriesNothingOfThePartner()
  numericOrderFieldsDoNotCross()
  controlLayerCannotPeek()
  theOnlyChannelIsPhysics()
  echo "test_no_channel: there is no communication channel"
