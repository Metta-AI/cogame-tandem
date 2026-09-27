## Persistent JSONL bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:tandem-train-bridge tools/train_bridge.nim

import std/[json, math, os]
import tandem/[baselines, broadcast, control, decide, orders, roster, sim]

const
  OperatorPrompt = "Coordinate through the couch's motion and your own strain to deliver it quickly with little damage."
  SystemPrompt = staticRead("../players/ordinary/system_prompt.txt")
  Variants = ["default", "sprint"]
  Fields = ["bearing_deg", "effort", "yield", "twist", "brace"]

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32) + 1

proc heads(): JsonNode =
  result = newJArray()
  for field in Fields:
    var options = newJArray()
    let bounds = case field
      of "bearing_deg": (0, 359)
      of "twist": (-255, 255)
      else: (0, 255)
    for value in bounds[0] .. bounds[1]:
      options.add(%value)
    result.add(%*{"name": field, "choices": options})

proc number(node: JsonNode): float =
  case node.kind
  of JInt: node.getInt().float
  of JFloat: node.getFloat()
  else: raise newException(ValueError, "expected numeric observation")

proc addNumbers(result: var JsonNode, node: JsonNode) =
  for value in node:
    result.add(%value.number())

proc values(view: JsonNode, variant: string): JsonNode =
  result = newJArray()
  for name in Variants:
    result.add(%(if variant == name: 1 else: 0))
  for field in ["turn", "of"]:
    result.add(%view[field].number())
  for field in ["elapsed_s", "par_s", "left_s"]:
    result.add(%view["clock"][field].number())
  for actor in ["you", "partner"]:
    result.addNumbers(view[actor]["pos"])
  let couch = view["couch"]
  result.addNumbers(couch["pos"])
  result.addNumbers(couch["vel"])
  for field in ["angle_deg", "speed", "spin_deg_s", "length_m", "width_m"]:
    result.add(%couch[field].number())
  let strain = view["strain"]
  result.addNumbers(strain["vec"])
  for field in ["newtons", "grip_limit_newtons", "headroom_pct", "slip_pct"]:
    result.add(%strain[field].number())
  let condition = view["condition"]
  for field in ["damage", "condition_pct", "damage_last_turn", "drops"]:
    result.add(%condition[field].number())
  result.add(%condition["touching"].len)
  let route = view["route"]
  for field in ["progress_pct", "doors_cleared", "doors_total"]:
    result.add(%route[field].number())
  result.addNumbers(route["cell"])
  result.addNumbers(route["goal"]["centre"])
  result.add(%route["goal"]["dist_along_route_m"].number())
  for index in 0 ..< 3:
    if index < route["next_doorways"].len:
      let door = route["next_doorways"][index]
      result.add(%1)
      result.addNumbers(door["centre"])
      for field in ["width_m", "through_deg", "dist_m"]:
        result.add(%door[field].number())
    else:
      for _ in 0 ..< 6: result.add(%0)
  let room = view["room"]
  for (name, limit, width) in [("walls", 24, 4), ("pillars", 13, 3)]:
    let items = room[name]
    doAssert items.len <= limit
    result.add(%items.len)
    for index in 0 ..< limit:
      if index < items.len:
        if name == "walls":
          result.addNumbers(items[index]["x"])
          result.addNumbers(items[index]["y"])
        else:
          result.addNumbers(items[index]["centre"])
          result.add(%items[index]["size_m"].number())
      else:
        for _ in 0 ..< width: result.add(%0)
  let last = view["your_last_order"]
  result.add(%(if last.kind == JNull: 0 else: 1))
  if last.kind == JNull:
    for _ in 0 ..< 6: result.add(%0)
  else:
    result.addNumbers(last["drive"])
    for field in ["effort", "yield", "twist", "brace"]:
      result.add(%last[field].number())

proc angleOf(order: Order): int =
  (int(round(arctan2(float(order.driveY), float(order.driveX)) *
    180.0 / PI)) + 360) mod 360

proc action(order: Order): JsonNode =
  %*{"bearing_deg": angleOf(order), "effort": order.effort,
    "yield": order.yieldQ, "twist": order.twist, "brace": order.brace}

proc hostedOrder(candidate: JsonNode): JsonNode =
  let angle = float(candidate["bearing_deg"].getInt()) * PI / 180.0
  %*{"drive": [cos(angle), sin(angle)],
    "effort": float(candidate["effort"].getInt()) / 255.0,
    "yield": float(candidate["yield"].getInt()) / 255.0,
    "twist": float(candidate["twist"].getInt()) / 255.0,
    "brace": float(candidate["brace"].getInt()) / 255.0}

proc decision(engine: TurnEngine, game: SimServer, seat: Seat,
    turn, id: int): JsonNode =
  let view = engine.seatViewJson(game, seat, turn)
  var properties = newJObject()
  var required = newJArray()
  for head in heads():
    let name = head["name"].getStr()
    properties[name] = %*{"enum": head["choices"]}
    required.add(%name)
  %*{"kind": "decision", "game": "tandem", "decision_id": id,
    "seat": ord(seat), "engine_seat": ord(seat), "turn": turn,
    "semantic_view": view, "inbox": [],
    "messages": [{"role": "system", "content": SystemPrompt},
      {"role": "user", "content": "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the rules; always reply in the requested format):\n" &
        OperatorPrompt & "\n\n" & engine.userMessage(game, seat, turn)}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": required}, "typed_question": newJNull()}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: tandem-train-bridge MANIFEST VARIANT", 1)
  let variant = args[1]
  doAssert variant in Variants
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var game: SimServer
  var engine: TurnEngine
  var views: array[Seat, JsonNode]
  var seat = Cobalt
  var turn = 0
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == 2
      var config = defaultGameConfig()
      let runtime = copy(variantConfig)
      runtime["tokens"] = %*["t0", "t1"]
      runtime["seed"] = %seedOf(request["seed"].getStr())
      config.update($runtime)
      game = initSimServer(config)
      game.gameEventLoggingEnabled = false
      discard game.addPlayer("policy-0", 0, "t0")
      discard game.addPlayer("policy-1", 1, "t1")
      game.startGame()
      engine = newTurnEngine(nil)
      turn = 0
      id = 0
      seat = Cobalt
      for actor in Seat: views[actor] = engine.seatViewJson(game, actor, turn)
      response = engine.decision(game, seat, turn, id)
    of "encode":
      doAssert game.phase != GameOver
      response = %*{"decision_id": id, "values": views[seat].values(variant),
        "action_heads": heads()}
    of "teacher":
      doAssert game.phase != GameOver
      let baseline = game.baselineOrder(seat,
        if seat == Cobalt: "porter" else: "mule", turn)
      response = %*{"response": $action(baseline)}
    of "step":
      doAssert game.phase != GameOver and request["decision_id"].getInt() == id
      let candidate = parseJson(request["response"].getStr())
      for head in heads():
        doAssert candidate[head["name"].getStr()] in head["choices"]
      let baseline = game.baselineOrder(seat,
        if seat == Cobalt: "porter" else: "mule", turn)
      let (parsed, usable) = parseOrder(candidate.hostedOrder(),
        engine.previous[seat], engine.hasPrevious[seat], baseline, turn)
      doAssert usable
      game.applyRecord(capRecord($orderJson(game, seat, parsed)))
      engine.previous[seat] = parsed
      engine.hasPrevious[seat] = true
      inc id
      var observation: JsonNode
      if seat == Cobalt:
        seat = Rust
        observation = engine.decision(game, seat, turn, id)
      else:
        engine.damageAtTurnStart = game.damage
        let endTick = game.tickCount + game.turnTicks()
        while game.phase != GameOver and game.tickCount < endTick:
          game.stepSim()
        if game.phase == GameOver:
          let score = game.jointScore()
          observation = %*{"kind": "terminal", "scores": {"0": score,
            "1": score}, "utilities": {"0": 2.0 * score - 1.0,
            "1": 2.0 * score - 1.0}}
        else:
          inc turn
          seat = Cobalt
          for actor in Seat:
            views[actor] = engine.seatViewJson(game, actor, turn)
          observation = engine.decision(game, seat, turn, id)
      response = %*{"kind": "accepted", "action": candidate,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
