## The sim's shared vocabulary: the core constants (including GameVersion and
## its changelog), the gameplay/wire types, and the pure helpers both sides of
## every seam need. Split out of sim.nim exactly as coworld-ctf splits its own,
## so the leaf modules (rig_art, course, sim_config, sim_state, roster) share
## them without importing gameplay.
##
## MOVED VERBATIM in spirit from ctf: SimServer and friends are flatty-
## serialized POSITIONALLY into replay keyframes, so declaration/field order
## here is wire format — reorder nothing without a GameVersion bump.
##
## EVERY hashed field is an explicit fixed width (`int32` / `bool` / enum).
## Nim's `int` is 64-bit natively and 32-bit under `--cpu:wasm32`, and the same
## sim module compiles both ways (native server records, emscripten viewer
## re-simulates), so a bare `int` in hashed state is a native/wasm divergence
## waiting to happen. See docs/RULES.md §Determinism.

import
  std/random,
  pixie

const
  GameName* = "tandem"
  GameVersion* = "1"  ## GV1 (first rules): two cogs rigidly gripped to one
    ## couch carry it through a procedurally generated 9x5-cell warehouse.
    ## Integer micrometre physics at 24 Hz with four substeps a tick, one
    ## continuous six-field order per seat per 48-tick decision turn as the
    ## recorded action log, penalty-contact damage, a 48-tick regrip after a
    ## drop and a 660 s wall-clock stop.
    ##
    ## Prepend-only changelog, ctf's discipline: say what the number means and
    ## what it obsoletes, keeping the `GVnn (short rule name): HEADLINE` shape.
    ## `tools/ci/check_gameversion.sh` diffs this headline, not the digits.

  TargetFps* = 24
  ReplayFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]
    ## Replay/live playback speed steps. Kept from ctf verbatim: every
    ## speed-coupled layer (the transport keymap, the lull scan, the JS
    ## clients' wire constants) derives from this ONE table.

  # ---- world geometry, micrometres -----------------------------------------
  WorldW* = 44_400_000'i32     ## 44.4 m
  WorldH* = 25_200_000'i32     ## 25.2 m
  MapScale* = 40_000           ## micrometres per rendered map pixel.
  MapWidth* = 1110             ## WorldW div MapScale
  MapHeight* = 630             ## WorldH div MapScale

  WallRing* = 600_000'i32      ## the 0.6 m outer wall ring.
  CellSize* = 4_800_000'i32    ## one warehouse cell, 4.8 m square.
  CellCols* = 9
  CellRows* = 5
  InnerWall* = 300_000'i32     ## internal wall thickness, 0.30 m.
  PillarSize* = 800_000'i32    ## 0.8 m square pillar.
  GoalInset* = 100_000'i32     ## the goal pad is the goal cell inset by this.

  DoorWidths*: array[5, int32] = [
    1_050_000'i32, 1_200_000'i32, 1_400_000'i32, 1_700_000'i32, 2_200_000'i32]
  FinalDoorWidth* = 1_050_000'i32
  DoorEdgeMargin* = 200_000'i32
  DoorOffsetSpan* = 1_200_000'i32
  NarrowDoorWidth* = 1_400_000'i32   ## a door under this counts as narrow.
  PillarClear* = 1_300_000'i32       ## min clearance from a cell's through-line.

  # ---- the assembly ---------------------------------------------------------
  HullDiscs* = 5
  CogDiscs* = 2
  DiscCount* = HullDiscs + CogDiscs
  SeatCount* = 2

  HullOffsets*: array[HullDiscs, int32] = [
    -650_000'i32, -325_000'i32, 0'i32, 325_000'i32, 650_000'i32]
  HullRadius* = 450_000'i32
  HullMassGrams* = 12_000'i32
  CogOffsets*: array[CogDiscs, int32] = [1_400_000'i32, -1_400_000'i32]
    ## Seat 0 (Cobalt) grips the FORE handle at body-local x = +1.40 m;
    ## seat 1 (Rust) the AFT handle at x = -1.40 m.
  CogRadius* = 300_000'i32
  CogMassGrams* = 30_000'i32

  CouchLengthUm* = 2_200_000'i32
  CouchWidthUm* = 900_000'i32

  TotalMassGrams* = HullDiscs * HullMassGrams + CogDiscs * CogMassGrams
    ## 120 000 g.

  InertiaMilliKgM2* = block:
    ## Sigma m_i d_i^2 + 1/2 m_i r_i^2 about the assembly centre (the couch
    ## centre, by symmetry), in milli-kg.m^2, derived HERE from the mass table
    ## so the constant and the table can never disagree. Worked in g.mm^2
    ## (= 1e-9 kg.m^2) and narrowed by 1e6. tests/test_physics.nim re-derives
    ## it independently and asserts the value is 139 050.
    var total = 0'i64
    for offset in HullOffsets:
      let d = int64(offset) div 1000
      total += int64(HullMassGrams) * d * d
      total += (int64(HullMassGrams) * (int64(HullRadius) div 1000) *
        (int64(HullRadius) div 1000)) div 2
    for offset in CogOffsets:
      let d = int64(offset) div 1000
      total += int64(CogMassGrams) * d * d
      total += (int64(CogMassGrams) * (int64(CogRadius) div 1000) *
        (int64(CogRadius) div 1000)) div 2
    int32(total div 1_000_000)

  Substeps* = 4

  # ---- physics tuning (all integer, all inside the determinism boundary) ----
  ContactStiffness* = 200'i32       ## mN per micrometre of penetration.
  ContactDamping* = 29'i32          ## mN per (micrometre/tick) of approach.
  ContactForceCap* = 40_000_000'i32 ## mN
  FrictionNum* = 354'i32            ## Coulomb mu = 354/1024 = 0.346.
  FrictionDen* = 1024'i32
  FrictionViscous* = 200'i32        ## mN per (micrometre/tick) of slide.
  LinearDragNum* = 171'i32          ## v -= v*171/4096 per substep (4.0 1/s).
  AngularDragNum* = 341'i32         ## spin -= spin*341/4096 per substep.
  DragDen* = 4096'i32
  MaxSpeedUm* = 145_833'i32         ## 3.5 m/s, in micrometres per tick.
  SpinFine* = 256'i32
    ## `spin` is carried at 1/256 of a `headingQ` step per tick, not at one.
    ## The coarse unit is 0.037 rad/s, and a realistic twist torque of 220 N.m
    ## accelerates the assembly by 0.005 of it per substep — which truncates to
    ## ZERO. At the coarse resolution the couch could only spin in jumps and
    ## the angular drag did nothing below 12 units, so a carry could neither
    ## turn slowly nor stop turning. Every angular quantity below is in these
    ## fine units.
  MaxSpinQ* = 68'i32 * SpinFine     ## 2.5 rad/s.

  MassStepDen* = int64(TotalMassGrams) * 96 * 24
    ## dv_um_per_tick = F_mN * 1e6 / (mass_g * 96 * 24).
  SpinStepNum* = 28_294'i64
    ## dspin = tau_mNm * 28294 / (I_milli * 100000).
  SpinStepDen* = 100_000'i64

  # ---- damage ---------------------------------------------------------------
  DamageCapPoints* = 1000'i32
  ImpactSpeedFloorMmS* = 250'i32
  ImpactDamageNum* = 40'i32
  ImpactDamageMax* = 200'i32
  ImpactEventFloor* = 8'i32
  ScrapeSlideFloorMmS* = 50'i32
  ScrapeDamageDen* = 800'i32
  ScrapeDamageMax* = 4'i32
  ScrapeThrottleTicks* = 6'i32
  DropDamageBase* = 60'i32
  DropDamageSpeedDen* = 60'i32
  DropDamageSpeedMax* = 40'i32

  # ---- grip -----------------------------------------------------------------
  MaxSeatForce* = 600_000'i32       ## mN, one seat at effort 1.0.
  TwistForce* = 400_000'i32         ## mN, one seat at |twist| = 1.
  GripLimitBase* = 850_000'i32      ## mN
  GripLimitBrace* = 450_000'i32     ## mN added at brace 1.0.
  YieldGainQ* = 3277'i32            ## 0.80 in Q12.
  SlipExcessDen* = 100_000'i32
  SlipRecoverPerTick* = 4'i32
  SlipDropThreshold* = 240'i32
  StrainWarnPct* = 80'i32

  # ---- match shape ----------------------------------------------------------
  DefaultMaxTicks* = 2400      ## 100 s at 24 Hz.
  DefaultTurnTicks* = 48       ## 2.0 s of sim time per decision turn.
  DefaultTurnBudgetMs* = 7000
  DefaultAttempt1Ms* = 4500
  DefaultRetryMs* = 2000
  DefaultMinBatchSpacingMs* = 4500
    ## The inter-batch wall floor. The Bedrock sidecar caps 30 requests per
    ## minute per episode; 2 requests per 4.5 s = 26.7 rpm, safely under it.
  DefaultWallClockBudgetSeconds* = 660
  DefaultLobbyJoinTimeoutTicks* = 2400   ## 100 s of lobby ticks.
  DefaultStartWaitTicks* = 24
  DefaultGameOverTicks* = 48
  DefaultRegripTicks* = 48     ## 2.0 s on the floor after a drop.
  ReferenceCarryMmS* = 1600    ## the par pace, 1.6 m/s.
  NarrowDoorParTicks* = 36     ## 1.5 s of fiddling per tight door.

  DefaultSeed* = 0x7A0DE0
    ## The compiled-in default seed, and the "nobody chose a seed" sentinel a
    ## hosted variant config carries when it pins nothing (src/tandem.nim).
    ## Deliberately NOT 4417231: that is the certification fixture's seed, and
    ## a fixture seed must be a real pin.
  DefaultMinPlayers* = 2
  MaxPlayers* = SeatCount
  DefaultMaxGames* = 1
  DefaultModel* = "claude-haiku-4-5-20251001"
  DefaultMaxOutputTokens* = 900

  # ---- reply caps (runes, never bytes) --------------------------------------
  MaxNoteRunes* = 160
  MaxSayRunes* = 48
  MaxPolicyRunes* = 48
  MaxDetailRunes* = 200
  MaxOrderRecordRunes* = 900
  MaxPromptRunes* = 4000

  AimBradsTurn* = 256          ## brads per full turn; ctf's convention.
  HeadingQTurn* = 4096         ## headingQ resolution: 1/16 brad.
  QuarterTurnQ* = 1024         ## 64 brads, in headingQ units.

  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"
  ReplayWebSocketPath* = "/replay"

type
  TandemError* = object of ValueError

  Seat* = enum
    ## Seat 0 grips the FORE handle, seat 1 the AFT handle. Ordinals are wire
    ## format (flatty stores them positionally in replay keyframes): APPEND new
    ## members, never insert.
    Cobalt
    Rust

  GamePhase* = enum
    Lobby
    Carrying
    Regrip
    Delivered
    GameOver

  EndRule* = enum
    ## The detail behind `results.reason`; see docs/RULES.md §End conditions.
    erDelivered
    erWrecked
    erOutOfTime
    erWallClock
    erSimFault
    erHostError

  EndReason* = enum
    reasonComplete
    reasonDeadline
    reasonFault

  OrderSource* = enum
    osScripted
    osLlm
    osFallback

  PolicyKind* = enum
    pkScripted
    pkLlm

  Order* = object
    ## One seat's carry parameters for one 48-tick decision turn, ALREADY
    ## QUANTISED: this object is what the control layer compiles and what
    ## `gameHash` mixes, so the viewer must re-install exactly these integers
    ## from the recorded `order` chat record.
    ##
    ## `drive` is a Q12 unit vector in VIEW coordinates (metres, centred,
    ## y UP). `effort`/`brace`/`yieldQ` are 0..255; `twist` is -255..255.
    turn*: int32
    source*: OrderSource
    latencyMs*: int32
    driveX*, driveY*: int32
    effort*: int32
    yieldQ*: int32
    twist*: int32
    brace*: int32
    note*: string              ## <= MaxNoteRunes runes. Never hashed.
    say*: string               ## <= MaxSayRunes runes. Never hashed.

  WallRect* = object
    ## An axis-aligned static obstacle, world micrometres, inclusive bounds.
    x0*, y0*, x1*, y1*: int32
    kind*: int32               ## 0 ring, 1 partition, 2 block, 3 pillar.

  Doorway* = object
    ## A gap punched through a shared face between two consecutive route
    ## cells. `vertical` is true when the shared face is a vertical wall (the
    ## couch passes through travelling in x).
    cx*, cy*: int32            ## gap centre, world micrometres.
    width*: int32
    vertical*: bool
    throughX*, throughY*: int32  ## Q12 unit vector of the traversal direction.

  Course* = object
    ## The generated warehouse. Static for the whole episode, excluded from
    ## replay keyframes (it is already in the config JSON — ctf's own rule for
    ## static map bakes) and mixed into `gameHash` only through `digest`.
    seed*: int32
    startCol*, startRow*: int32
    goalCol*, goalRow*: int32
    routeCols*: seq[int32]
    routeRows*: seq[int32]
    doorways*: seq[Doorway]
    walls*: seq[WallRect]
    routeX*: seq[int32]        ## the route polyline, world micrometres.
    routeY*: seq[int32]
    routeLen*: int32
    parTicks*: int32
    goalX0*, goalY0*, goalX1*, goalY1*: int32
    digest*: int32
    bucketW*, bucketH*: int32  ## broadphase grid dimensions, in buckets.
    buckets*: seq[seq[int32]]  ## rect indices per bucket.

  Contact* = object
    ## One disc/rect overlap resolved this substep; the tick's contact log
    ## feeds damage and FX. Never hashed.
    disc*: int32
    x*, y*: int32
    approachMmS*: int32
    slideMmS*: int32

  SeatStats* = object
    strainPeak*: int32         ## mN
    forceIntegral*: int64      ## mN.ticks; analysis only.
    yieldTicks*: int32
    blame*: int32
    llmTurns*: int32
    fallbackTurns*: int32

  RewardAccount* = object
    address*: string
    slotIndex*: int32
    seat*: Seat
    hasSeat*: bool
    won*: bool
    abandoned*: bool
    reward*: int32
    games*: array[Seat, int32]
    wins*: array[Seat, int32]

  PlayerSlotConfig* = object
    name*: string
    token*: string
    alias*: string

  Player* = object
    ## One CONNECTION. Two per episode; each drives one cog.
    address*: string           ## the real policy name (spectator side only).
    joinOrder*: int32
    seat*: Seat
    policyLabel*: string       ## <= MaxPolicyRunes runes, from `register`.
    policyKind*: PolicyKind
    baseline*: string          ## scripted baseline name, "" for an LLM seat.
    registered*: bool
    reward*: int32

  SimEventKind* = enum
    ## Tier-2 analysis event channel (the Logs substrate). Analysis-only:
    ## never enters gameHash.
    Scrape
    Impact
    Drop
    RegripEvent
    DoorwayEvent
    StrainWarn
    OrderEvent
    PhaseChange
    DeliveredEvent
    Wrecked

  SimEvent* = object
    tick*: int
    kind*: SimEventKind
    source*: int               ## acting disc index, -1 = n/a.
    target*: int
    seat*: int                 ## acting seat, -1 = n/a.
    amount*: int
    x*, y*: int32              ## world micrometres.
    speed*: int32
    content*: string

  GameConfig* = object
    ## Every field a coworld variant may set. `sim_config.update` reads them;
    ## `configJson` echoes them into the replay header so playback re-derives
    ## the identical world. Adding a field here means adding it to
    ## `game.config_schema` in coworld_manifest_template.json in the same
    ## commit (tests/test_manifest.nim enforces it).
    seed*: int
    speed*: int
    numAgents*: int
    minPlayers*: int
    startWaitTicks*: int
    lobbyJoinTimeoutTicks*: int
    gameOverTicks*: int
    maxTicks*: int
    maxGames*: int
    turnTicks*: int
    turnBudgetMs*: int
    attempt1Ms*: int
    retryMs*: int
    minBatchSpacingMs*: int
    wallClockBudgetSeconds*: int
    regripTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    closedRoster*: bool
    model*: string
    maxOutputTokens*: int
    maxSeatForceMilliNewtons*: int
    gripLimitMilliNewtons*: int
    damageCap*: int
    slots*: seq[PlayerSlotConfig]

  ScuffMark* = object
    ## A baked scuff decal on the couch, keyed to the hull disc that took the
    ## damage. Cosmetic; never hashed.
    disc*: int32
    tick*: int32

  SparkFx* = object
    x*, y*: int32
    tick*: int32
    strength*: int32

  DropFx* = object
    x*, y*: int32
    tick*: int32
    seat*: int32

  FeedLine* = object
    tick*: int32
    kind*: string
    seat*: int32
    text*: string

  SimServer* = object
    ## Flatty-serialized POSITIONALLY into replay keyframes. Append only.
    config*: GameConfig
    players*: seq[Player]
    rewardAccounts*: seq[RewardAccount]
    rng*: Rand
    nextJoinOrder*: int32
    tickCount*: int
    gameStartTick*: int
    startWaitTimer*: int
    lobbyWaitTimer*: int
    phase*: GamePhase
    gameOverTimer*: int
    endReason*: EndReason
    endRule*: EndRule
    ended*: bool
    # ---- the assembly (all hashed) -----------------------------------------
    posX*, posY*: int32
    velX*, velY*: int32
    headingQ*: int32
    spin*: int32
    spinRem*: int32
    damage*: int32
    slip*: array[SeatCount, int32]
    strainX*, strainY*: array[SeatCount, int32]
    bestProgressPermille*: int32
    deliveryTick*: int32
    regripUntil*: int32
    drops*: int32
    doorsCleared*: int32
    courseDigest*: int32
    activeOrder*: array[SeatCount, Order]
    ## --- outside the hash from here on ---
    course*: Course            ## static; EXCLUDED from replay keyframes.
    hasOrder*: array[SeatCount, bool]
    stats*: array[Seat, SeatStats]
    contactLast*: array[DiscCount, bool]
    scrapeThrottle*: array[DiscCount, int32]
    contacts*: seq[Contact]
    contactTicks*: int32
    scrapeTicks*: int32
    impacts*: int32
    lastDamageTurn*: int32
    damageAtTurnStart*: int32
    scuffs*: seq[ScuffMark]
    sparks*: seq[SparkFx]
    dropFx*: seq[DropFx]
    feed*: seq[FeedLine]
    touching*: seq[string]
    gameEventLoggingEnabled*: bool
    collectEvents*: bool
    events*: seq[SimEvent]
    lastLobbyPlayersLogged*: int
    lastLobbyNeededLogged*: int
    lastLobbySecondsLogged*: int
    lastDropTick*: int32
    lastDoorTick*: int32
    lastImpactTick*: int32
    lastScrapeTick*: int32
    lastRegripTick*: int32
    needsReregister*: bool

const
  CobaltColor* = rgba(63, 124, 196, 255)   ## matches data/rig_real/blue.
  RustColor* = rgba(224, 82, 58, 255)      ## matches data/rig_real/red.
  FloorDark* = rgba(58, 58, 62, 255)
  FloorLight* = rgba(72, 72, 76, 255)
  HatchColor* = rgba(214, 176, 62, 190)
  CouchBody* = rgba(122, 74, 92, 255)
  CouchTrim* = rgba(158, 104, 122, 255)
  GoalPadColor* = rgba(210, 176, 74, 210)

proc seatText*(seat: Seat): string {.inline.} =
  case seat
  of Cobalt: "cobalt"
  of Rust: "rust"

proc seatAlias*(seat: Seat): string {.inline.} =
  case seat
  of Cobalt: "Cobalt"
  of Rust: "Rust"

proc handleText*(seat: Seat): string {.inline.} =
  case seat
  of Cobalt: "fore"
  of Rust: "aft"

proc other*(seat: Seat): Seat {.inline.} =
  if seat == Cobalt: Rust else: Cobalt

proc cogDisc*(seat: Seat): int {.inline.} =
  ## The disc index of a seat's cog: hull discs occupy 0..4.
  HullDiscs + ord(seat)

proc seatOffset*(seat: Seat): int32 {.inline.} =
  CogOffsets[ord(seat)]

proc sourceText*(source: OrderSource): string {.inline.} =
  case source
  of osScripted: "scripted"
  of osLlm: "llm"
  of osFallback: "fallback"

proc reasonText*(reason: EndReason): string {.inline.} =
  case reason
  of reasonComplete: "complete"
  of reasonDeadline: "deadline"
  of reasonFault: "fault"

proc endRuleText*(rule: EndRule): string {.inline.} =
  case rule
  of erDelivered: "delivered"
  of erWrecked: "wrecked"
  of erOutOfTime: "out_of_time"
  of erWallClock: "wall_clock"
  of erSimFault: "sim_fault"
  of erHostError: "host_error"

proc policyKindText*(kind: PolicyKind): string {.inline.} =
  case kind
  of pkScripted: "scripted"
  of pkLlm: "llm"

proc discRadius*(disc: int): int32 {.inline.} =
  if disc < HullDiscs: HullRadius else: CogRadius

proc discOffset*(disc: int): int32 {.inline.} =
  if disc < HullDiscs: HullOffsets[disc] else: CogOffsets[disc - HullDiscs]

proc discMass*(disc: int): int32 {.inline.} =
  if disc < HullDiscs: HullMassGrams else: CogMassGrams

proc discName*(disc: int): string =
  ## The plain-language name the feed and the seat view use for a hull disc.
  case disc
  of 0: "couch_left_rear"
  of 1: "couch_rear"
  of 2: "couch_middle"
  of 3: "couch_front"
  of 4: "couch_right_front"
  of 5: "cobalt_cog"
  else: "rust_cog"

proc policyName*(address: string): string =
  ## The policy identity behind a connection address: the hosted runtime
  ## appends a per-seat " (N)" suffix to the same policy's several connections,
  ## and the join path turns spaces into underscores. Kept from ctf.
  result = address
  var cut = result.len
  var i = result.len - 1
  while i >= 0 and result[i] in {' ', '\t'}:
    dec i
  if i >= 0 and result[i] == ')':
    var j = i - 1
    while j >= 0 and result[j] in {'0' .. '9'}:
      dec j
    if j >= 0 and j < i - 1 and result[j] == '(':
      dec j
      while j >= 0 and result[j] in {' ', '_', '\t'}:
        dec j
      cut = j + 1
  if cut < result.len:
    result = result[0 ..< cut]

proc mapPxX*(x: int32): int {.inline.} = int(x) div MapScale
proc mapPxY*(y: int32): int {.inline.} = int(y) div MapScale
