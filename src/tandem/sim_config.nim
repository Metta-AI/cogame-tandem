## GameConfig lifecycle: defaults, the JSON reader, validation, update, and the
## config echo (`configJson`) that every replay carries in its header. Kept in
## ctf's shape (`sim_config.nim`), with tandem's fields.
##
## Every field read here must appear in `game.config_schema` in
## coworld_manifest_template.json — `tests/test_manifest.nim` asserts the two
## agree, because the certifier rejects an unknown config key.
##
## No `getFloat` and no floating point: this module is inside the float-free
## grep guard (tests/test_determinism.nim §2d).

import
  std/[json, strutils],
  sim_types, course

proc defaultGameConfig*(): GameConfig =
  ## The default tandem delivery: two seats, 50 decision turns, 100 s of carry.
  GameConfig(
    seed: DefaultSeed,
    speed: 1,
    numAgents: SeatCount,
    minPlayers: DefaultMinPlayers,
    startWaitTicks: DefaultStartWaitTicks,
    lobbyJoinTimeoutTicks: DefaultLobbyJoinTimeoutTicks,
    gameOverTicks: DefaultGameOverTicks,
    maxTicks: DefaultMaxTicks,
    maxGames: DefaultMaxGames,
    turnTicks: DefaultTurnTicks,
    turnBudgetMs: DefaultTurnBudgetMs,
    attempt1Ms: DefaultAttempt1Ms,
    retryMs: DefaultRetryMs,
    minBatchSpacingMs: DefaultMinBatchSpacingMs,
    wallClockBudgetSeconds: DefaultWallClockBudgetSeconds,
    regripTicks: DefaultRegripTicks,
    fastMode: true,
    showPlayerLabels: false,
    closedRoster: false,
    model: DefaultModel,
    maxOutputTokens: DefaultMaxOutputTokens,
    maxSeatForceMilliNewtons: int(MaxSeatForce),
    gripLimitMilliNewtons: int(GripLimitBase),
    damageCap: int(DamageCapPoints),
    slots: @[]
  )

proc readInt(node: JsonNode, key: string, target: var int) =
  if node.hasKey(key) and node[key].kind == JInt:
    target = node[key].getInt()

proc readBool(node: JsonNode, key: string, target: var bool) =
  if node.hasKey(key) and node[key].kind == JBool:
    target = node[key].getBool()

proc readStr(node: JsonNode, key: string, target: var string) =
  if node.hasKey(key) and node[key].kind == JString:
    target = node[key].getStr()

proc readSlots(node: JsonNode, config: var GameConfig) =
  ## `slots` names each seat's alias; `players` names the policies; `tokens`
  ## authorises them. All three are positional and the platform always sends
  ## them together, so one pass fills the slot table.
  var count = 0
  for key in ["slots", "players", "tokens"]:
    if node.hasKey(key) and node[key].kind == JArray:
      count = max(count, node[key].len)
  if count == 0:
    return
  var slots = newSeq[PlayerSlotConfig](count)
  for i in 0 ..< count:
    slots[i].alias = seatAlias(if i == 0: Cobalt else: Rust)
  if node.hasKey("slots") and node["slots"].kind == JArray:
    for i in 0 ..< node["slots"].len:
      let entry = node["slots"][i]
      if i >= count or entry.kind != JObject:
        continue
      if entry.hasKey("alias") and entry["alias"].kind == JString:
        slots[i].alias = entry["alias"].getStr()
  if node.hasKey("players") and node["players"].kind == JArray:
    for i in 0 ..< node["players"].len:
      let entry = node["players"][i]
      if i >= count:
        continue
      case entry.kind
      of JString:
        slots[i].name = entry.getStr()
      of JObject:
        if entry.hasKey("name") and entry["name"].kind == JString:
          slots[i].name = entry["name"].getStr()
      else:
        discard
  if node.hasKey("tokens") and node["tokens"].kind == JArray:
    for i in 0 ..< node["tokens"].len:
      let entry = node["tokens"][i]
      if i < count and entry.kind == JString:
        slots[i].token = entry.getStr()
  config.slots = slots

proc validate*(config: GameConfig) =
  ## Rejects a config that cannot produce a legal episode, loudly and before
  ## any socket opens (ctf's contract: the entrypoint dies with a clean
  ## message).
  if config.numAgents != SeatCount:
    raise newException(TandemError,
      "num_agents must be " & $SeatCount & ", got " & $config.numAgents)
  if config.maxTicks <= 0:
    raise newException(TandemError, "maxTicks must be positive")
  if config.turnTicks <= 0:
    raise newException(TandemError, "turnTicks must be positive")
  if config.turnBudgetMs < config.attempt1Ms + config.retryMs:
    raise newException(TandemError,
      "turnBudgetMs must cover attempt1Ms + retryMs")
  if config.wallClockBudgetSeconds <= 0:
    raise newException(TandemError, "wallClockBudgetSeconds must be positive")
  if config.minPlayers < 1 or config.minPlayers > SeatCount:
    raise newException(TandemError, "minPlayers must be 1 or 2")
  if config.regripTicks < 0:
    raise newException(TandemError, "regripTicks must not be negative")
  if config.damageCap <= 0:
    raise newException(TandemError, "damageCap must be positive")

proc update*(config: var GameConfig, configJson: string) =
  ## Folds one runtime config document into the defaults. Unknown keys are
  ## ignored (the platform adds fields); a malformed document raises.
  if configJson.strip().len == 0:
    config.validate()
    return
  var node: JsonNode
  try:
    node = parseJson(configJson)
  except CatchableError as error:
    raise newException(TandemError, "config is not valid JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(TandemError, "config must be a JSON object")
  node.readInt("seed", config.seed)
  node.readInt("speed", config.speed)
  node.readInt("num_agents", config.numAgents)
  node.readInt("minPlayers", config.minPlayers)
  node.readInt("startWaitTicks", config.startWaitTicks)
  node.readInt("lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  node.readInt("gameOverTicks", config.gameOverTicks)
  node.readInt("maxTicks", config.maxTicks)
  node.readInt("maxGames", config.maxGames)
  node.readInt("turnTicks", config.turnTicks)
  node.readInt("turnBudgetMs", config.turnBudgetMs)
  node.readInt("attempt1Ms", config.attempt1Ms)
  node.readInt("retryMs", config.retryMs)
  node.readInt("minBatchSpacingMs", config.minBatchSpacingMs)
  node.readInt("wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  node.readInt("regripTicks", config.regripTicks)
  node.readBool("fastMode", config.fastMode)
  node.readBool("showPlayerLabels", config.showPlayerLabels)
  node.readBool("closedRoster", config.closedRoster)
  node.readStr("model", config.model)
  node.readInt("maxOutputTokens", config.maxOutputTokens)
  node.readInt("maxSeatForceMilliNewtons", config.maxSeatForceMilliNewtons)
  node.readInt("gripLimitMilliNewtons", config.gripLimitMilliNewtons)
  node.readInt("damageCap", config.damageCap)
  node.readSlots(config)
  if config.speed <= 0:
    config.speed = 1
  config.validate()

proc recordedCourse*(configJson: string): Course =
  ## The fully expanded course out of a replay's config JSON, or an empty
  ## course when the document does not carry one.
  if configJson.strip().len == 0:
    return
  try:
    let node = parseJson(configJson)
    if node.kind == JObject:
      return courseFromJson(node{"course"})
  except CatchableError:
    discard

proc configuredPlayerName*(config: GameConfig, slot: int, token: string):
    string =
  ## The configured display name for a joining seat, matched by slot then by
  ## token. "" when the roster does not name it.
  if slot >= 0 and slot < config.slots.len and config.slots[slot].name.len > 0:
    return config.slots[slot].name
  if token.len > 0:
    for entry in config.slots:
      if entry.token.len > 0 and entry.token == token:
        return entry.name
  ""

proc playerJoinAllowed*(
  config: GameConfig,
  address: string,
  slot: int,
  token: string
): bool =
  ## The 403 gate: a slot outside the roster, or a token that does not match
  ## the slot it claims, is refused before the websocket upgrade.
  discard address
  if slot >= MaxPlayers:
    return false
  if slot >= 0 and slot < config.slots.len:
    let want = config.slots[slot].token
    if want.len > 0 and token != want:
      return false
    return true
  if slot >= config.slots.len and config.closedRoster:
    return false
  if token.len > 0:
    for entry in config.slots:
      if entry.token.len > 0 and entry.token == token:
        return true
    if config.closedRoster:
      return false
  true

proc configJson*(config: GameConfig, course: Course): string =
  ## The RESOLVED config echoed into the replay header. Playback re-derives the
  ## identical world from these bytes — including the FULLY EXPANDED course, so
  ## the viewer never regenerates it — and nothing the sim reads is missing.
  ## Tokens are the one exception a replay legitimately carries (ctf writes
  ## them in the join records too).
  var slots = newJArray()
  var players = newJArray()
  var tokens = newJArray()
  for entry in config.slots:
    slots.add(%*{"alias": entry.alias})
    players.add(%*{"name": entry.name})
    tokens.add(%entry.token)
  $(%*{
    "seed": config.seed,
    "speed": config.speed,
    "num_agents": config.numAgents,
    "minPlayers": config.minPlayers,
    "startWaitTicks": config.startWaitTicks,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "gameOverTicks": config.gameOverTicks,
    "maxTicks": config.maxTicks,
    "maxGames": config.maxGames,
    "turnTicks": config.turnTicks,
    "turnBudgetMs": config.turnBudgetMs,
    "attempt1Ms": config.attempt1Ms,
    "retryMs": config.retryMs,
    "minBatchSpacingMs": config.minBatchSpacingMs,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "regripTicks": config.regripTicks,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels,
    "closedRoster": config.closedRoster,
    "model": config.model,
    "maxOutputTokens": config.maxOutputTokens,
    "maxSeatForceMilliNewtons": config.maxSeatForceMilliNewtons,
    "gripLimitMilliNewtons": config.gripLimitMilliNewtons,
    "damageCap": config.damageCap,
    "worldW": int(WorldW),
    "worldH": int(WorldH),
    "mapScale": int(MapScale),
    "totalMassGrams": int(TotalMassGrams),
    "inertiaMilliKgM2": int(InertiaMilliKgM2),
    "couchLengthUm": int(CouchLengthUm),
    "couchWidthUm": int(CouchWidthUm),
    "hullRadiusUm": int(HullRadius),
    "cogRadiusUm": int(CogRadius),
    "twistForceMilliNewtons": int(TwistForce),
    "course": courseToJson(course),
    "slots": slots,
    "players": players,
    "tokens": tokens
  })
