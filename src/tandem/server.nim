## The episode server: the mummy HTTP/websocket server, `/healthz`,
## `/player?slot&token`, `/global`, `/replay`, `/client/*`, `/replay-data`,
## join/auth, the frame limiter, the replay-switch path, the `COGAME_*` runtime
## contract, `declarePlayerFailure` and the artifact-write block.
##
## This is ctf's `server.nim` with the FIVE named edits from the design note:
##
## 1. **Input source.** Where ctf reads `appState.inputMasks` (the socket) into
##    `inputs[playerIndex]`, tandem calls `control.seatForce` for the two seats
##    (through `control.stepSim`) and passes the force pair into `sim.step`.
##    `masks` stays a two-element array of zero masks so ctf's frame plumbing
##    is untouched; `writeInputFrameMasks` is still called and simply never
##    records a change. PLAYER SOCKETS CONTRIBUTE NO INPUT.
## 2. **Turn boundary.** Immediately before stepping a tick where
##    `tick mod turnTicks == 0`, the loop runs `decide.turn`, which enforces
##    the inter-batch floor, issues the ONE parallel batch, applies the
##    deadlines and writes the `order`/`fallback` records — all inside a
##    monotonic `turnBudgetMs` bound. `recordAndWrite` then folds each record
##    back through `applyRecord`, which is what INSTALLS the order.
## 3. **Registration interception.** A player's Sprite v1 chat message whose
##    text parses as a registration object is consumed as registration and is
##    NOT written to the replay chat stream: the server writes a redacted
##    `register` record instead (policy label and kind, never the prompt). Any
##    other chat text from a player is dropped.
## 4. **Wall-clock stop.** A `wallClockBudgetSeconds` check inside the tick
##    loop forces `phase = GameOver`, `reason = deadline`,
##    `endRule = wall_clock`.
## 5. **Shutdown grace.** `/healthz` and `/global` keep answering for a bounded
##    ~20 s after the artifacts are written, then the process exits (lantern
##    0.1.3: the episode runner pings `/global` with a 2 s deadline AFTER the
##    player pods start, and a short episode can already be gone).
##
## The whole loop is wrapped so an unexpected exception becomes
## `fault/host_error` with best-effort artifacts written before it is re-raised
## (docs/RULES.md "End conditions"): the runner gets a results.json and a
## partial replay instead of an unattributable episode.

import
  std/[json, locks, monotimes, nativesockets, os, strutils, tables, times],
  bitworld/client as bitworldClient,
  bitworld/runtime,
  bitworld/spriteprotocol,
  mummy,
  sim, roster, control, orders, baselines, llm, decide,
  global, broadcast, replays, replay_runtime, events, wire_constants

when defined(posix):
  from std/posix import SHUT_RDWR, shutdown

type
  WebSocketSocketFields = object
    server: Server
    clientSocket: SocketHandle
    clientId: uint64

  WebSocketAppState = object
    lock: Lock
    replayServerMode: bool
    replayLoaded: bool
    pendingReplayUri: string
    loadingReplayUri: string
    currentReplayUri: string
    chatMessages: Table[WebSocket, string]
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    playerReady: Table[WebSocket, bool]
    globalViewers: Table[WebSocket, GlobalViewerState]
    playerViewers: Table[WebSocket, PlayerViewerState]
    closedSockets: seq[WebSocket]
    nextAnonymousPlayer: int
    config: GameConfig

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

const
  HealthPath = "/healthz"
  ReplayDataPath = "/replay-data"
  ClientGlobalPath = "/client/global"
  ClientPlayerPath = "/client/player"
  ShutdownGraceSeconds* = 20
    ## EDIT 5. The episode runner pings `/global` with a 2 s deadline AFTER the
    ## player pods start, so a short episode that exits the instant its
    ## artifacts are written can be gone before the ping lands.
  BroadcastFontPath = "/client/font.ttf"
  LeagueReplayerPath = "/client/league"
  MaxWsFrameBytes* = 900_000
    ## Hosted replay closes any WS frame larger than 1 MiB (1009). Chunk under
    ## a margin below that so no single frame trips it.
  # The designed broadcast replay client, embedded at compile time. Final
  # in-page script order: wire constants, shared chrome, core, page IIFE.
  EmbeddedBroadcastReplayHtml = staticRead("../../client/replay_broadcast.html").replace(
    "<!-- CHROME_COMMON -->",
    "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
  ).replace(
    "<!-- BROADCAST_CORE -->",
    "<script>" & staticRead("../../client/broadcast_core.js") & "</script>"
  ).spliceWireConstants()
  EmbeddedLeagueReplayerHtml = staticRead("../../client/league_replayer.html").replace(
    "<!-- CHROME_COMMON -->",
    "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
  ).spliceWireConstants()
  BroadcastFont = staticRead("../../data/font.ttf")

var appState: WebSocketAppState
var replayBytesForClients {.threadvar.}: string

proc initAppState() =
  initLock(appState.lock)
  appState.chatMessages = initTable[WebSocket, string]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerAddresses = initTable[WebSocket, string]()
  appState.playerSlots = initTable[WebSocket, int]()
  appState.playerTokens = initTable[WebSocket, string]()
  appState.playerReady = initTable[WebSocket, bool]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.closedSockets = @[]
  appState.nextAnonymousPlayer = 1
  appState.config = defaultGameConfig()

proc markSocketClosed(websocket: WebSocket): bool =
  result = websocket notin appState.closedSockets
  if result:
    appState.closedSockets.add(websocket)

proc disconnectWebSocket(websocket: WebSocket) =
  when defined(posix):
    let fields = cast[WebSocketSocketFields](websocket)
    discard shutdown(fields.clientSocket, SHUT_RDWR)
  else:
    websocket.close()

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc cleanPlayerName(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc playerSlotOf(request: Request): int =
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return MaxPlayers
  if result < 0 or result >= MaxPlayers:
    return MaxPlayers

proc playerTokenOf(request: Request): string =
  request.queryParams.getOrDefault("token", "").strip()

proc nextAnonymousPlayerIdentity(): string =
  {.gcsafe.}:
    withLock appState.lock:
      if appState.nextAnonymousPlayer <= 0:
        appState.nextAnonymousPlayer = 1
      result = "Player" & $appState.nextAnonymousPlayer
      inc appState.nextAnonymousPlayer

proc playerIdentity(request: Request, slot: int, token: string): string =
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.configuredPlayerName(slot, token)
      if result.len > 0:
        return
  result = nextAnonymousPlayerIdentity()

proc respondForbiddenWebSocket(request: Request, reason: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(403, headers, reason & "\n")

proc hasPlayerCredentialParams(request: Request): bool =
  request.queryParams.getOrDefault("name", "").strip().len > 0 or
    request.queryParams.getOrDefault("slot", "").strip().len > 0 or
    request.queryParams.getOrDefault("token", "").strip().len > 0

proc joinError(
  config: GameConfig,
  address: string,
  slot: int,
  token: string
): string =
  if config.playerJoinAllowed(address, slot, token):
    return ""
  if slot >= MaxPlayers:
    return "Player slot must be between 0 and " & $(MaxPlayers - 1) & "."
  if slot >= 0 and slot < config.slots.len and
      config.slots[slot].token.len > 0 and token != config.slots[slot].token:
    return "Player token does not match configured slot " & $slot & "."
  "Player credentials do not match configured roster."

proc readSpriteChatRaw*(message: string): string =
  ## Reads a Sprite v1 chat packet's payload WITHOUT the ASCII filter
  ## `parseSpriteClientMessages` applies. Registration is JSON that may carry
  ## a non-ASCII policy label, and the whole point of the rune discipline is
  ## that such a label survives to the replay intact.
  if message.len < 3 or message[0].uint8 != SpriteClientChat:
    return ""
  let length = int(uint16(message[1].uint8) or (uint16(message[2].uint8) shl 8))
  if 3 + length > message.len:
    return ""
  message[3 ..< 3 + length]

proc isPlayerReadyPacket(message: string): bool =
  message.len == 1 and message[0].uint8 == SpriteClientReady

proc httpHandler(request: Request) =
  if request.path == HealthPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, "healthy")
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      slot = request.playerSlotOf()
      token = request.playerTokenOf()
      identity = request.playerIdentity(slot, token)
    {.gcsafe.}:
      withLock appState.lock:
        let error = appState.config.joinError(identity, slot, token)
        if error.len > 0:
          request.respondForbiddenWebSocket(error)
          return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers.del(websocket)
        appState.playerViewers[websocket] = initPlayerViewerState()
        appState.playerAddresses[websocket] = identity
        appState.playerSlots[websocket] = slot
        appState.playerTokens[websocket] = token
        appState.playerIndices[websocket] =
          if appState.replayLoaded: -1 else: 0x7fffffff
        appState.playerReady[websocket] = false
    echo "player connected: ", identity
  elif request.path in [GlobalWebSocketPath, ReplayWebSocketPath] and
      request.httpMethod == "GET" and request.isWebSocketUpgrade():
    if request.hasPlayerCredentialParams():
      request.respondForbiddenWebSocket(
        "Viewer websocket cannot include player name, slot, or token.")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = initGlobalViewerState()
  elif request.path == BroadcastFontPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "font/ttf"
    headers["Cache-Control"] = "public, max-age=3600"
    request.respond(200, headers, BroadcastFont)
  elif request.path == ReplayDataPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "application/octet-stream"
    headers["Cache-Control"] = "no-cache"
    {.gcsafe.}:
      request.respond(200, headers, replayBytesForClients)
  elif request.path in [
      bitworldClient.ReplayClientRoute,
      bitworldClient.CoworldReplayClientRoute,
      LeagueReplayerPath
    ] and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    if request.path == LeagueReplayerPath:
      request.respond(200, headers, EmbeddedLeagueReplayerHtml)
    else:
      request.respond(200, headers, EmbeddedBroadcastReplayHtml)
  elif request.path in [ClientGlobalPath, ClientPlayerPath] and
      request.httpMethod == "GET" and not request.isWebSocketUpgrade():
    # The certifier probes GET /client/player?slot=0&token=<t> and
    # GET /client/global BEFORE it starts any player pod, and neither may open
    # the player socket (lantern 0.1.1). Both serve the real broadcast page,
    # registered here — ahead of any catch-all asset route.
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    {.gcsafe.}:
      request.respond(200, headers, EmbeddedBroadcastReplayHtml)
  elif bitworldClient.serveClientRoute(
      request, bitworldClient.GlobalClientRoute):
    discard
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "tandem server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    if message.kind == Ping:
      websocket.send(message.data, Pong)
    elif message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if message.data.isPlayerReadyPacket() and
              websocket in appState.playerReady:
            appState.playerReady[websocket] = true
          elif websocket in appState.globalViewers:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data)
          elif websocket in appState.playerViewers:
            # EDIT 3: a seat's chat is its registration. Read the raw payload
            # so a non-ASCII policy label survives; the input bits a seat may
            # send are read and dropped (the server computes every mask).
            let text = readSpriteChatRaw(message.data)
            if text.len > 0:
              appState.chatMessages[websocket] = text
  of ErrorEvent, CloseEvent:
    var who = ""
    {.gcsafe.}:
      withLock appState.lock:
        if markSocketClosed(websocket) and
            websocket in appState.playerAddresses:
          who = appState.playerAddresses[websocket]
    if who.len > 0:
      echo "player disconnected: ", who

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

type FrameAdvance = enum
  LateFrame, SkippedFrame, WaitedFrame

proc allPlayersReady(
  sockets: openArray[WebSocket],
  playerIndices: openArray[int],
  playerCount: int
): bool =
  var active = 0
  {.gcsafe.}:
    withLock appState.lock:
      for i, websocket in sockets:
        if i >= playerIndices.len or playerIndices[i] < 0 or
            playerIndices[i] >= playerCount:
          continue
        inc active
        if not appState.playerReady.getOrDefault(websocket, false):
          return false
  active > 0

proc runFrameLimiter(
  previousTick: var MonoTime,
  fastMode: bool,
  sockets: openArray[WebSocket],
  playerIndices: openArray[int],
  playerCount: int
): FrameAdvance =
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  var slept = false
  while true:
    let elapsed = getMonoTime() - previousTick
    if elapsed >= frameDuration:
      result = if slept: WaitedFrame else: LateFrame
      break
    if fastMode and sockets.allPlayersReady(playerIndices, playerCount):
      result = SkippedFrame
      break
    let remaining = frameDuration - elapsed
    sleep(max(1, min(2, int(remaining.inMilliseconds))))
    slept = true
  previousTick = getMonoTime()

proc declarePlayerFailure*(slot: int, message: string) =
  ## Publishes the game-declared terminal player failure the platform runner
  ## polls for, so a lobby no-show is charged to the seat that caused it
  ## instead of poisoning the whole episode unattributed. Best-effort.
  ## Exported so tests/test_engine.nim can drive it against a real
  ## file:// target and assert the JSON shape the runner polls for.
  try:
    writeCogameEnv(
      "COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json"
    )
  except CatchableError as e:
    echo "player-failure declaration failed: ", e.msg

proc parseRegistration*(text: string): tuple[ok: bool, node: JsonNode] =
  try:
    let node = parseJson(text)
    if node.kind == JObject and node{"type"}.getStr() == "register":
      return (true, node)
  except CatchableError:
    discard
  (false, newJNull())

proc registrationOf*(
  text: string,
  seat: Seat,
  previous: SeatPolicy
): tuple[ok: bool, policy: SeatPolicy, record: string] =
  ## EDIT 3, as a pure function: one chat payload from a seat becomes a policy
  ## and, when it CHANGES that seat's policy, the redacted `register` record
  ## the replay carries. Nothing here echoes the payload -- the prompt is read
  ## into the policy and never into the record -- and any text that is not a
  ## registration object is dropped (`ok` false, no record).
  ##
  ## Exported so tests/test_server.nim can assert the contract on the SAME code
  ## the loop runs, instead of re-implementing the predicate beside it.
  let parsed = parseRegistration(text)
  if not parsed.ok:
    return (false, previous, "")
  var policy = SeatPolicy(connected: true)
  let prompt = clipRunes(parsed.node{"prompt"}.getStr(), MaxPromptRunes)
  let scripted = parsed.node{"scripted"}
  let label = clipRunes(parsed.node{"policy"}.getStr(), MaxPolicyRunes)
  if prompt.len > 0:
    policy.kind = pkLlm
    policy.prompt = prompt
    policy.baseline = ""
  else:
    policy.kind = pkScripted
    policy.baseline =
      if scripted.kind == JString and scripted.getStr().len > 0:
        scripted.getStr()
      else:
        "porter"
  policy.label = if label.len > 0: label else: policyKindText(policy.kind)
  # The player re-sends its registration once after the first frame (in case
  # the first send raced the slot registration), so only an ACTUAL change earns
  # a second record.
  let unchanged =
    previous.connected and
    previous.kind == policy.kind and
    previous.baseline == policy.baseline and
    previous.label == policy.label and
    previous.prompt == policy.prompt
  if unchanged:
    return (true, policy, "")
  (true, policy, $(%*{
    "k": "register",
    "seat": ord(seat),
    "alias": seatAlias(seat),
    "policy": policy.label,
    "kind": policyKindText(policy.kind),
    "baseline": policy.baseline
  }))

const ZeroMasks: array[SeatCount, uint8] = [0'u8, 0'u8]
  ## EDIT 1: the seats send no inputs, so every recorded mask frame is this.

proc runServerLoop*(
  host = DefaultHost,
  port = DefaultPort,
  initialConfig = defaultGameConfig(),
  saveReplayPath = "",
  loadReplayPath = "",
  saveScoresPath = "",
  runtimeConfig = RuntimeConfig()
) =
  initAppState()
  # The wall-clock budget starts HERE, before the board bake and before the
  # listener opens, so every second the process spends is charged against the
  # 660 s engine stop (`wallClockBudgetSeconds`) and the 720 s settle
  # requirement -- not just the seconds after setup finished.
  let episodeStart = getMonoTime()
  if saveReplayPath.len > 0 and loadReplayPath.len > 0:
    raise newException(ReplayError, "Cannot save and load a replay together")
  var replayLoaded = loadReplayPath.len > 0
  var replayData =
    if replayLoaded:
      try:
        loadReplay(loadReplayPath)
      except CatchableError as e:
        echo "replay load failed (serving without replay): ", e.msg
        replayLoaded = false
        ReplayData()
    else:
      ReplayData()
  var initializedReplay =
    if replayLoaded: initReplayRuntime(replayData, runtimeConfig.mismatchQuit)
    else: InitializedReplay()
  var config =
    if replayLoaded: move(initializedReplay.config) else: initialConfig
  # The sim is constructed BEFORE the replay writer, because the replay header
  # carries the RESOLVED config INCLUDING the fully expanded course — playback
  # re-derives the identical warehouse from the bytes alone rather than
  # regenerating it — and `initSimServer` is what generates that course from
  # `config.seed`.
  var sim =
    if replayLoaded: move(initializedReplay.sim) else: initSimServer(config)
  var
    replayWriter = openReplayWriter(saveReplayPath,
      config.configJson(sim.course))
    replayPlayer =
      if replayLoaded: move(initializedReplay.player) else: ReplayPlayer()
  defer:
    replayWriter.closeReplayWriter()
  appState.replayLoaded = replayLoaded
  appState.replayServerMode = replayLoaded
  appState.config = config

  let eventsPath = block:
    let uri = getEnv("COGAME_EVENTS_URI")
    if uri.len == 0: ""
    elif uri.startsWith("file://"): uri[7 .. ^1]
    else:
      raise newException(ValueError,
        "COGAME_EVENTS_URI must be a file:// path, got: " & uri)

  var
    lastTick = getMonoTime()
    collectedEvents: seq[SimEvent] = @[]
  sim.collectEvents = eventsPath.len > 0
  replayWriter.lastMasks = newSeq[uint8](SeatCount)

  block:
    # Bake the board render caches BEFORE the listener opens: a viewer's
    # first-message clock starts at its successful connect, so nothing may be
    # accepted until every frame the loop will build can be assembled
    # instantly.
    let warmStart = getMonoTime()
    sim.warmBoardRenderCaches()
    echo "board render caches baked in ",
      (getMonoTime() - warmStart).inMilliseconds,
      " ms (charged against wallClockBudgetSeconds=",
      config.wallClockBudgetSeconds, ")"

  let client = if replayLoaded: nil else: newLlmClient(config)
  var engine = newTurnEngine(client,
    if client.isNil: nil else: curlyBatch(client))
  for seat in Seat:
    engine.policies[seat] = SeatPolicy(
      kind: pkScripted, baseline: "porter", label: "porter")

  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 4)
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()

  var
    liveSpeedIndex = 0
    broadcastTracker =
      if replayLoaded: move(initializedReplay.tracker)
      else: initBroadcastTracker()
    quitAfterFrame = false
    failureDeclared = false
    resultRecordWritten = false

  proc recordAndWrite(text: string) =
    ## The ONE path a chat record takes: capped, into the replay AND back
    ## through `applyRecord`, so the broadcast feed reads identically live and
    ## in playback. The cap is applied HERE, not only in `engine.addRecord`, so
    ## `register` and `result` obey it too -- a long policy name is otherwise
    ## unbounded on its way to the replay. `capRecord` shrinks structurally, so
    ## a record over the cap stays parseable JSON.
    let record = capRecord(text)
    replayWriter.writeChat(tickTime(sim.tickCount), 0, record)
    sim.applyRecord(record)

  proc writeArtifacts() =
    ## Closes the replay and publishes every artifact the runner reads. Called
    ## on the normal exit AND from the host-error handler, which is what makes
    ## `fault/host_error` a real ending rather than a declared one: the note
    ## promises best-effort artifacts before re-raising.
    replayWriter.closeReplayWriter()
    if saveReplayPath.len > 0 and fileExists(saveReplayPath):
      echo "Replay written: ", saveReplayPath,
        " (", getFileSize(saveReplayPath), " bytes)"
      runtimeConfig.writeReplay(readFile(saveReplayPath))
    if eventsPath.len > 0:
      writeFile(eventsPath, collectedEvents.eventsJsonl(sim.tickCount))
      echo "Events written: ", eventsPath, " (", collectedEvents.len,
        " events)"
    if runtimeConfig.resultsUri.len > 0:
      runtimeConfig.writeResults(sim.playerResultsJson() & "\n")
    elif saveScoresPath.len > 0:
      writeFile(saveScoresPath, sim.playerResultsJson() & "\n")
    echo "Results: ", sim.playerResultsJson()

  proc stopServing() =
    httpServer.close()
    joinThread(serverThread)

  try:
    while true:
      var
        sockets: seq[WebSocket] = @[]
        playerIndices: seq[int] = @[]
        playerViewerStates: seq[PlayerViewerState] = @[]
        globalViewers: seq[WebSocket] = @[]
        globalStates: seq[GlobalViewerState] = @[]
        replayCommands: seq[char] = @[]
        replaySeekTicks: seq[int] = @[]
        registrations: seq[tuple[seat: int, text: string]] = @[]

      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.closedSockets:
            if not replayLoaded and websocket in appState.playerIndices:
              let index = appState.playerIndices[websocket]
              if index >= 0 and index < sim.players.len:
                # DEGRADE, NEVER HANG: the seat keeps playing, but from the
                # scripted layer. Without this the turn engine kept issuing
                # (and waiting on) LLM calls for a seat whose socket was gone.
                # A reconnect re-registers and revives it.
                engine.policies[sim.players[index].seat].connected = false
                sim.recordGameAbandon(index)
                replayWriter.writeLeave(tickTime(sim.tickCount), index)
                sim.removePlayerAt(index)
                for ws, value in appState.playerIndices.mpairs:
                  if value > index:
                    dec value
            appState.playerViewers.del(websocket)
            appState.playerIndices.del(websocket)
            appState.playerAddresses.del(websocket)
            appState.playerSlots.del(websocket)
            appState.playerTokens.del(websocket)
            appState.playerReady.del(websocket)
            appState.chatMessages.del(websocket)
            appState.globalViewers.del(websocket)
          appState.closedSockets.setLen(0)

          if not replayLoaded:
            # Joins are strictly slot-sequential.
            var progressed = true
            while progressed:
              progressed = false
              for websocket in appState.playerIndices.keys:
                if appState.playerIndices[websocket] != 0x7fffffff:
                  continue
                if sim.phase != Lobby or not sim.canAddPlayer():
                  appState.playerIndices[websocket] = -1
                  continue
                let
                  address = appState.playerAddresses.getOrDefault(
                    websocket, "unknown")
                  slot = appState.playerSlots.getOrDefault(websocket, -1)
                  token = appState.playerTokens.getOrDefault(websocket, "")
                  resolved = sim.resolvePlayerSlot(address, token, slot)
                if resolved != sim.nextPlayerSlot():
                  continue
                try:
                  let index = sim.addPlayer(address, resolved, token)
                  appState.playerIndices[websocket] = index
                  replayWriter.writeJoin(tickTime(sim.tickCount), index,
                    address, resolved, token)
                  progressed = true
                except TandemError:
                  appState.playerIndices[websocket] = -1
                break

          for websocket, index in appState.playerIndices.pairs:
            if websocket notin appState.playerViewers:
              continue
            sockets.add(websocket)
            playerIndices.add(index)
            playerViewerStates.add(appState.playerViewers[websocket])
            if index >= 0 and index < sim.players.len:
              let text = appState.chatMessages.getOrDefault(websocket, "")
              if text.len > 0:
                registrations.add((ord(sim.players[index].seat), text))
          appState.chatMessages.clear()

          for websocket, state in appState.globalViewers.pairs:
            globalViewers.add(websocket)
            globalStates.add(state)
            if state.replaySeekTick >= 0:
              replaySeekTicks.add(state.replaySeekTick)
            for command in state.replayCommands:
              replayCommands.add(command)
            appState.globalViewers[websocket].replayCommands.setLen(0)
            appState.globalViewers[websocket].replaySeekTick = -1

      # EDIT 3: registration is consumed here and NEVER written to the replay
      # chat stream. `registrationOf` returns the redacted `register` record
      # instead, and returns nothing at all for any other chat text.
      for entry in registrations:
        let seat = Seat(entry.seat and 1)
        let reg = registrationOf(entry.text, seat, engine.policies[seat])
        if not reg.ok:
          continue                     ## any other chat text is dropped.
        engine.policies[seat] = reg.policy
        if reg.record.len == 0:
          continue                     ## an unchanged re-send earns no record.
        let index = sim.playerFor(seat)
        if index >= 0:
          sim.players[index].policyKind = reg.policy.kind
          sim.players[index].baseline = reg.policy.baseline
          sim.players[index].policyLabel = reg.policy.label
          sim.players[index].registered = true
        recordAndWrite(reg.record)

      # A seat that never connects does NOT end the episode: the no-show is
      # declared, its cog is driven by the `porter` baseline for the whole
      # run, and the run plays to a normal ending.
      if not replayLoaded and sim.lobbyJoinTimedOut() and not failureDeclared:
        failureDeclared = true
        let stuck = sim.nextPlayerSlot()
        declarePlayerFailure(stuck,
          "player slot " & $stuck & " never joined the lobby within " &
            $config.lobbyJoinTimeoutTicks & " lobby ticks (~" &
            $(config.lobbyJoinTimeoutTicks div TargetFps) & "s)")
        echo "tandem: lobby join timeout on slot ", stuck,
          "; starting with the porter baseline in that seat"
        sim.startGame()

      var frameEvents = newJArray()
      if replayLoaded:
        frameEvents = replayPlayer.advanceReplayFrame(
          sim, broadcastTracker, replaySeekTicks, replayCommands)
      else:
        for command in replayCommands:
          liveSpeedIndex.applySpeedCommand(command)
        for _ in 0 ..< playbackSpeed(liveSpeedIndex):
          if sim.phase == GameOver and sim.gameOverTimer <= 0:
            break
          # EDIT 4: the wall-clock stop. Inside the tick loop, not once per
          # outer iteration: a spectator can raise liveSpeedIndex to 5, which
          # steps up to 16 ticks per iteration, and the stop must not be
          # coarser than the thing it is stopping.
          if sim.carrying():
            let elapsed = int((getMonoTime() - episodeStart).inSeconds)
            if elapsed >= config.wallClockBudgetSeconds:
              echo "tandem: wall-clock budget reached at ", elapsed,
                "s; stopping"
              sim.wallClockStop()
          # EDIT 2: the turn boundary, immediately before the tick it governs.
          if sim.carrying():
            let elapsedTicks = sim.tickCount - sim.gameStartTick
            # The phase flips INSIDE a step, so the first carrying tick is
            # never a boundary. Turn 0 therefore fires on the first tick that
            # has no order yet — otherwise the opening two seconds would be
            # played on the compiled-in default.
            let opening = not (sim.hasOrder[0] and sim.hasOrder[1])
            if opening or elapsedTicks mod sim.turnTicks() == 0:
              let seconds = int((getMonoTime() - episodeStart).inSeconds)
              engine.turn(sim, elapsedTicks div sim.turnTicks(), seconds)
              # The records are the ONE source: writing them into the replay
              # AND folding them back through `applyRecord` is what installs
              # each seat's quantised order into hashed state, so the live sim
              # and the viewer compile bit-identical forces.
              for record in engine.records:
                recordAndWrite(record)
          # EDIT 1: the seats send no inputs; the control layer compiles both
          # force vectors from the recorded orders. The mask frame is still
          # written so ctf's plumbing is untouched, and never changes.
          replayWriter.writeInputFrameMasks(tickTime(sim.tickCount), ZeroMasks)
          sim.stepSim()
          replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())
          if sim.collectEvents:
            for event in sim.events:
              collectedEvents.add(event)
            sim.events.setLen(0)
          sim.stepEvents(broadcastTracker, frameEvents)
          if sim.phase == GameOver and sim.gameOverTimer <= 0:
            # The `result` record is written at the very END, so its finalTick is
            # the same number results.json reports.
            if not resultRecordWritten:
              resultRecordWritten = true
              recordAndWrite(sim.resultRecordJson())
            quitAfterFrame = true
            break

      for i in 0 ..< sockets.len:
        var nextState: PlayerViewerState
        let framePacket = sim.buildSpriteProtocolPlayerUpdates(
          playerIndices[i], playerViewerStates[i], nextState)
        {.gcsafe.}:
          withLock appState.lock:
            if sockets[i] in appState.playerViewers:
              appState.playerViewers[sockets[i]] = nextState
              appState.playerReady[sockets[i]] = false
        let wirePacket = dedupObjectPlacements(framePacket,
          nextState.sentPlacements)
        try:
          if wirePacket.len == 0:
            sockets[i].send("", BinaryMessage)
          for chunk in chunkSpritePacket(wirePacket, MaxWsFrameBytes):
            sockets[i].send(blobFromBytes(chunk), BinaryMessage)
        except:
          {.gcsafe.}:
            withLock appState.lock:
              discard markSocketClosed(sockets[i])

      for i in 0 ..< globalViewers.len:
        var nextState: GlobalViewerState
        var packet =
          if replayLoaded:
            sim.buildReplayViewerPacket(
              replayPlayer, globalStates[i], nextState, frameEvents)
          else:
            sim.buildSpriteProtocolUpdates(
              globalStates[i], nextState, sim.tickCount, true,
              playbackSpeed(liveSpeedIndex), config.maxTicks, false, false, -1)
        if not replayLoaded:
          # The chrome channel rides the SAME binary sprite stream as the board,
          # as the label of a reserved never-drawn 1x1 sprite, because that is
          # the only channel that survives a hosted replay.
          packet.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0],
            sim.buildStateJson(frameEvents, true,
              playbackSpeed(liveSpeedIndex), config.maxTicks, false, false, -1,
              -1, @[], 0, 0, false, false, false, @[], nil))
        if packet.len == 0:
          continue
        try:
          for chunk in chunkSpritePacket(packet, MaxWsFrameBytes):
            globalViewers[i].send(blobFromBytes(chunk), BinaryMessage)
          {.gcsafe.}:
            withLock appState.lock:
              if globalViewers[i] in appState.globalViewers:
                let pending = appState.globalViewers[globalViewers[i]]
                var merged = nextState
                merged.mouseX = pending.mouseX
                merged.mouseY = pending.mouseY
                merged.mouseLayer = pending.mouseLayer
                merged.mouseDown = pending.mouseDown
                if pending.clickPending:
                  merged.clickPending = true
                if pending.replaySeekTick >= 0:
                  merged.replaySeekTick = pending.replaySeekTick
                if pending.replayCommands.len > 0:
                  merged.replayCommands.add(pending.replayCommands)
                appState.globalViewers[globalViewers[i]] = merged
        except:
          {.gcsafe.}:
            withLock appState.lock:
              discard markSocketClosed(globalViewers[i])

      if quitAfterFrame:
        writeArtifacts()
        # EDIT 5: keep /healthz and /global answering for a bounded grace
        # before the listener closes, then exit. The runner waits on process
        # exit anyway, so this costs the episode nothing and removes a race
        # that fails certification on a short episode (lantern 0.1.3).
        let graceUntil = getMonoTime() +
          initDuration(seconds = ShutdownGraceSeconds)
        echo "tandem: artifacts written; serving for a further ",
          ShutdownGraceSeconds, "s before exit"
        while getMonoTime() < graceUntil:
          sleep(200)
        stopServing()
        break

      discard runFrameLimiter(lastTick, not replayLoaded and config.fastMode,
        sockets, playerIndices, sim.players.len)
  except CatchableError as failure:
    # fault/host_error. An unexpected exception used to unwind straight out of
    # `isMainModule` with a traceback and NO results.json, no replay upload and
    # no events file, which left the runner with an unattributable episode and
    # made `hostErrorStop` (and the manifest's `host_error` endRule) code that
    # nothing could reach. Now the verdict is recorded, the artifacts are
    # written best-effort, and the exception is re-raised unchanged so the exit
    # status and the traceback still say what happened.
    echo "tandem: host error: ", failure.msg
    sim.hostErrorStop()
    try:
      if not resultRecordWritten:
        resultRecordWritten = true
        recordAndWrite(sim.resultRecordJson())
      writeArtifacts()
    except CatchableError as artifactFailure:
      echo "tandem: artifact write after host error failed: ",
        artifactFailure.msg
    try:
      stopServing()
    except CatchableError:
      discard
    raise
