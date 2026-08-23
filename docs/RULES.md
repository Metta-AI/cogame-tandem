# Tandem — rules

Two cogs are rigidly gripped to the two handles of one couch and carry it
through a procedurally generated warehouse obstacle course, room by room,
doorway by doorway, **with no communication channel of any kind**.

## Seats

`num_agents` = 2. One seat = one cog.

| Seat | Alias | Handle | Body-local x |
|---|---|---|---|
| 0 | Cobalt (blue rig) | fore | +1.40 m |
| 1 | Rust (red rig) | aft | −1.40 m |

The seats are not symmetric in the world (fore vs aft handle) but they are
symmetric in rules, scoring and observation shape, so a policy is never
advantaged by its slot. Which handle a seat holds is stated in its own
observation (`"you": {"handle": "fore"}`).

## World and units

Everything in `src/tandem/{sim,course,control,trig}.nim` is **integers**, because
replays are re-simulated by the emscripten/wasm32 build of the same Nim module
the native amd64 server ran, and their per-tick `gameHash` chain must match
bit for bit.

| Quantity | Unit | Type |
|---|---|---|
| Position | micrometres (µm) | `int32` |
| Linear velocity | µm per tick | `int32` |
| Angle (`headingQ`) | 1/16 brad, 0..4095 (256 brads = 1 turn, 0 = +x, ccw on screen) | `int32` |
| Angular velocity (`spin`) | 1/16 brad per tick | `int32` |
| Force | millinewtons (mN) | `int32` |
| Torque | millinewton-metres | `int64` accumulator |
| Mass | grams | `int32` const |
| Moment of inertia | milli-kg·m² | `int32` const |
| Damage | scuff points, 0..1000 | `int32` |

World box: `x ∈ [0, 44 400 000] µm`, `y ∈ [0, 25 200 000] µm` (44.4 m × 25.2 m),
origin top-left, y down. Map render scale 1 map pixel = 40 000 µm →
`MapWidth = 1110`, `MapHeight = 630`.

**View coordinates** — the only coordinates a policy ever sees or sends — are
metres, origin at the world centre, **y up**:
`X = (x_µm − 22 200 000) / 1 000 000`, `Y = (12 600 000 − y_µm) / 1 000 000`.
Angles reported to policies are degrees ccw from +X, rounded to 1°.

## The course

A 9 × 5 grid of 4.8 m cells inside a 0.6 m outer wall ring. `generateCourse`
draws from one seeded `std/random` stream, integer draws only, in this order:

1. **Route.** `r0 = rand(0..4)`, `r1 = rand(0..4)`. A self-avoiding walk from
   `(0, r0)` steps east / north / south with weights 60 / 20 / 20, never west,
   never off the grid, never a revisit; a dead end backtracks one cell and
   re-draws with the failed direction excluded. It ends when it enters
   `(8, r1)`. Route length outside 9..15 re-runs the walk; after 64 failures the
   generator falls back to the monotone path along `r0`.
2. **Doorways.** One per consecutive route pair: width from
   `{1.05, 1.20, 1.40, 1.70, 2.20} m`, centre offset uniform in `±1.20 m`,
   clamped so the gap edges stay ≥ 0.20 m inside the shared face. **The last
   doorway is forced to 1.05 m, centred** — against a 0.90 m couch that is
   75 mm of clearance a side.
3. **Blocks.** Every off-route cell is one solid 4.8 m rect. Every boundary
   between two non-consecutive route cells is a full 0.30 m wall; every
   consecutive boundary is two stubs either side of the gap. The outer ring is
   four rects that deliberately overhang the world box, so a contact resolved
   from inside a rect always pushes toward the interior.
4. **Pillars.** Each intermediate route cell, 45 % of the time, gets one 0.8 m
   square offset `(±1.40, ±1.40) m` from the cell centre — skipped if it comes
   within 1.30 m of the segment joining that cell's two doorway centres, so
   every cell keeps a through-line wider than the couch.
5. **Route polyline and par.** `routePts` interleaves cell centres and doorway
   centres in traversal order. `parTicks = (routeLen_mm · 24) / 1600 +
   36 · narrowDoors` — a reference carry at 1.6 m/s plus 1.5 s per tight door.
6. **Goal pad.** The goal cell's interior, inset 0.10 m.
7. **Digest.** FNV-1a over the serialized course, mixed into `gameHash` every
   tick. The FULLY EXPANDED course is written into the replay's config JSON;
   playback reads it back rather than regenerating.

## The assembly

One rigid body, seven collision discs, one pose.

| Part | Local offsets (m) | Radius | Mass |
|---|---|---|---|
| Couch hull discs ×5 | −0.65, −0.325, 0, +0.325, +0.65 | 0.45 m | 12 000 g each |
| Cog discs ×2 | +1.40 (Cobalt), −1.40 (Rust) | 0.30 m | 30 000 g each |

`TotalMassGrams = 120 000`; `InertiaMilliKgM2 = 139 050`, derived at compile
time from the mass table. Cogs cannot let go, walk around or change grip: the
compliance knob is `yield`.

## Time

24 Hz, four substeps of 1/96 s a tick. A run is at most `maxTicks = 2400`
(100 s), divided into 50 decision turns of `turnTicks = 48` (2.0 s).

## Resolution order, every tick

1. **Turn boundary.** On `t mod 48 == 0` the collected order becomes each
   seat's `activeOrder`, quantised to integers, INSTALLED THROUGH THE `order`
   REPLAY RECORD — the one path, live and in playback. `activeOrder` is mixed
   into `gameHash`, because here the order *is* the action log.
2. **Regrip gate.** While `t < regripUntil` both forces are zero and `vel`/
   `spin` are held at 0; steps 3–6 are skipped. At `regripUntil` the cogs
   re-attach, slip and strain reset, and a `regrip` event fires.
3. **Control compile**, seat 0 then 1: `control.seatForce` is a pure integer
   function of (assembly state, that seat's order, that seat's felt strain).
   **This is inside the determinism boundary** — the viewer runs it too.
4. **Four substeps**, each: contacts → sum of forces → semi-implicit Euler with
   drag → pose → felt strain.
   - Contacts: disc vs axis-aligned rect. `Fn = 200·δ_µm + 29·max(0, −v_n)`,
     clamped to ≥ 0 and ≤ 40 000 000 mN; `Ft = −min(354·Fn/1024, |v_t|·200)·û(v_t)`.
   - **Sum of forces**: `F = F₀ + F₁ + F_contact`;
     `τ = (r₀×F₀ + r₁×F₁)/10⁶ + τ_contact`.
   - `Δv = F_mN·10⁶ / (120 000 · 96 · 24)`, then `v −= v·171/4096`;
     `Δspin = τ·28 294 / (139 050 · 100 000)`, then `spin −= spin·341/4096`.
     Clamps: `|v| ≤ 145 833` µm/tick (3.5 m/s), `|spin| ≤ 68` (2.5 rad/s).
   - **Felt strain**: `H_i = m_cog·a_i − F_i`, the force in that cog's hands.
     It contains the partner's force by construction, because `a_i` depends on
     `F₀ + F₁`. **This is the entire coordination channel.**
5. **Damage**, once per tick, hull discs only (bruised cogs, unscuffed couch).
   Impact: first contact above 250 mm/s approach →
   `clamp((mm/s − 250)·40/1000, 0, 200)`. Scrape: continuing contact sliding
   above 50 mm/s → `clamp(mm/s / 800, 1, 4)` a tick, event-throttled to one per
   disc per 6 ticks. The seat whose handle is nearer takes the `blame` — a
   spectator meter, **not** part of the score.
6. **Grip.** `slip += max(0, (|H| − gripLimit)/100 000) − 4`, floored at 0.
   `slip ≥ 240` → **drop**: +60 damage plus up to 40 for speed, velocity and
   spin zeroed, 48 ticks of regrip. Either seat's slip drops the couch.
7. **Progress and delivery.** The couch centre is projected onto `routePts`;
   `bestProgressPermille` is monotone. A `doorway` beat fires the first time
   all five hull-disc centres are past a doorway plane. All five inside the
   goal pad → delivered.
8. **Stats** (contact ticks, scrape ticks, impacts, peak strain, blame).
9. **Hash**: one `gameHash` per tick, mixing tick, phase, pose, velocity,
   damage, slip, felt strain, progress, delivery, BOTH quantised orders and the
   course digest. Never FX, notes, `say`, feed text or policy labels.
10. **End checks**, in order: delivered → `complete/delivered`; damage ≥ 1000 →
    `complete/wrecked`; invariant guard → `fault/sim_fault`; `maxTicks` →
    `complete/out_of_time`. The wall-clock stop is checked by the server loop
    and yields `deadline/wall_clock`.

**There is no rescue rule.** A pair that wedges the couch and cannot free it
burns the clock and ends `out_of_time` with partial credit.

## Scoring

The game is **fully cooperative**: both seats receive the identical score,
computed once, in integers.

```
par      = course.parTicks
t        = deliveryTick if delivered else finalTick
cond     = (1000 - damage) / 1000
speed    = clamp(2 - t/par, 0, 1)
progress = bestProgressPermille / 1000

delivered:      score = 0.30 + 0.35*speed + 0.35*cond    in [0.30, 1.00]
not delivered:  score = 0.25 * progress * cond           in [0.00, 0.25)
```

Higher is better. Any delivery beats every non-delivery; a wrecked couch scores
0.000. The league ranks by the seat's **mean `results.scores` across its
episodes** — Elo cannot separate anybody when every episode is a draw.

## End conditions

| `reason` | `endRule` | When |
|---|---|---|
| `complete` | `delivered` | all five hull-disc centres inside the goal pad |
| `complete` | `wrecked` | damage reached 1000 |
| `complete` | `out_of_time` | `maxTicks` reached, undelivered and intact |
| `deadline` | `wall_clock` | `wallClockBudgetSeconds` (660) elapsed first |
| `fault` | `sim_fault` | a step-10 invariant guard tripped |
| `fault` | `host_error` | an unexpected server-side exception |

A seat that never connects does not end the episode: the no-show is reported to
`COGAME_PLAYER_FAILURE_URI`, its cog is driven by `porter`, and the run plays to
a normal ending.

## Determinism

Every stored sim field is an explicit `int32`/`bool`/enum. Every product or
quotient of two sim quantities is taken in `int64` and narrowed with an explicit
truncating `div`. No floating point and no libm anywhere under
`src/tandem/{sim,course,control,trig,sim_types,sim_config,sim_state}.nim` —
trigonometry is the committed `SinQ12` table, the only square root is `isqrt`,
the only atan2 is `bradsOfVectorI`. The sim draws no random numbers after
tick 0.
