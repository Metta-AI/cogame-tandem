## The course: the 9x5-cell warehouse generator, the wall list, the broadphase
## buckets, the route polyline and `parTicks`.
##
## ctf generates, validates, mirrors and pools its terrain; tandem generates
## exactly one warehouse per episode from `config.seed`, so `arena.nim`,
## `map_art.nim`, `map_pool.nim`, `mapgen_styles.nim` and the whole
## editor/mapkit tree are DELETED rather than ported. The floor BAKE lives in
## `global.nim` with the rest of the rendering: this module is inside the
## float-free grep guard (tests/test_determinism.nim) and pixie is a float API.
##
## Generation is INTEGER-ONLY and draws from one dedicated `std/random` stream
## in a fixed order, so `generateCourse(seed)` is byte-identical on the native
## amd64 server and in the emscripten wasm32 viewer.

import std/[json, random]

import sim_types, trig

const
  BucketSize* = 2_400_000'i32
  RingOverhang* = 2_000_000'i32
  MaxWalkAttempts* = 64
  MinRouteCells* = 9
  MaxRouteCells* = 15
  WalkStepGuard = 4000

  DirEast = 0
  DirNorth = 1
  DirSouth = 2
  DirWeights: array[3, int] = [60, 20, 20]

proc cellIndex(col, row: int): int {.inline.} = row * CellCols + col

proc cellX0*(col: int): int32 {.inline.} =
  WallRing + CellSize * int32(col)

proc cellY0*(row: int): int32 {.inline.} =
  WallRing + CellSize * int32(row)

proc cellCentreX*(col: int): int32 {.inline.} =
  cellX0(col) + CellSize div 2

proc cellCentreY*(row: int): int32 {.inline.} =
  cellY0(row) + CellSize div 2

proc stepCell(col, row, dir: int): tuple[col, row: int] {.inline.} =
  case dir
  of DirEast: (col + 1, row)
  of DirNorth: (col, row - 1)
  else: (col, row + 1)

proc inGrid(col, row: int): bool {.inline.} =
  col >= 0 and col < CellCols and row >= 0 and row < CellRows

proc dirBetween(fromCol, fromRow, toCol, toRow: int): int {.inline.} =
  if toCol > fromCol: DirEast
  elif toRow < fromRow: DirNorth
  else: DirSouth

# --------------------------------------------------------------------------
# Integer geometry helpers
# --------------------------------------------------------------------------

proc projectOnSegment*(
  px, py, ax, ay, bx, by: int32
): tuple[cx, cy: int64, along, length: int64] =
  ## The closest point on a segment, its arc length from the segment's start
  ## and the segment's own length — all in micrometres.
  ##
  ## The projection parameter is carried as a LENGTH, not as a
  ## numerator/denominator pair: `t` over `|ab|^2` would need `abx * t`, and
  ## with world coordinates of 4.4e7 um that product reaches 1e20 and
  ## overflows `int64` in debug builds. Dividing by `|ab|` once keeps every
  ## intermediate under 1e15.
  let
    abx = int64(bx) - int64(ax)
    aby = int64(by) - int64(ay)
    length = isqrt(abx * abx + aby * aby)
  if length == 0:
    return (int64(ax), int64(ay), 0'i64, 0'i64)
  var along = ((int64(px) - int64(ax)) * abx +
    (int64(py) - int64(ay)) * aby) div length
  if along < 0: along = 0
  elif along > length: along = length
  ((int64(ax) + (abx * along) div length),
   (int64(ay) + (aby * along) div length), along, length)

proc segmentDistance*(px, py, ax, ay, bx, by: int32): int64 =
  ## Distance from a point to a segment, in micrometres.
  let p = projectOnSegment(px, py, ax, ay, bx, by)
  if p.length == 0:
    return isqrt((int64(px) - int64(ax)) * (int64(px) - int64(ax)) +
      (int64(py) - int64(ay)) * (int64(py) - int64(ay)))
  let
    dx = int64(px) - p.cx
    dy = int64(py) - p.cy
  isqrt(dx * dx + dy * dy)

proc rectOf(x0, y0, x1, y1: int32, kind: int32): WallRect {.inline.} =
  WallRect(x0: x0, y0: y0, x1: x1, y1: y1, kind: kind)

# --------------------------------------------------------------------------
# The self-avoiding walk
# --------------------------------------------------------------------------

proc walkOnce(
  rng: var Rand,
  startRow, goalRow: int
): tuple[cols, rows: seq[int32]] =
  ## One attempt at the route. East / north / south with weights 60 / 20 / 20,
  ## never west, never off the grid, never a revisit; a dead end backtracks one
  ## cell and re-draws with the direction that failed excluded.
  var
    pathCol: seq[int] = @[0]
    pathRow: seq[int] = @[startRow]
    tried: seq[int] = @[0]
    visited: array[CellCols * CellRows, bool]
  visited[cellIndex(0, startRow)] = true
  var guard = 0
  while guard < WalkStepGuard:
    inc guard
    let
      col = pathCol[^1]
      row = pathRow[^1]
    if col == CellCols - 1 and row == goalRow:
      for i in 0 ..< pathCol.len:
        result.cols.add(int32(pathCol[i]))
        result.rows.add(int32(pathRow[i]))
      return
    var
      total = 0
      usable: array[3, bool]
    for dir in 0 .. 2:
      let next = stepCell(col, row, dir)
      usable[dir] = inGrid(next.col, next.row) and
        not visited[cellIndex(next.col, next.row)] and
        (tried[^1] and (1 shl dir)) == 0
      if usable[dir]:
        total += DirWeights[dir]
    if total == 0:
      if pathCol.len <= 1:
        return (@[], @[])
      visited[cellIndex(col, row)] = false
      let taken = dirBetween(pathCol[^2], pathRow[^2], col, row)
      discard pathCol.pop()
      discard pathRow.pop()
      discard tried.pop()
      tried[^1] = tried[^1] or (1 shl taken)
      continue
    var roll = rng.rand(total - 1)
    var chosen = DirEast
    for dir in 0 .. 2:
      if not usable[dir]:
        continue
      if roll < DirWeights[dir]:
        chosen = dir
        break
      roll -= DirWeights[dir]
    let next = stepCell(col, row, chosen)
    pathCol.add(next.col)
    pathRow.add(next.row)
    tried.add(0)
    visited[cellIndex(next.col, next.row)] = true
  (@[], @[])

# --------------------------------------------------------------------------
# The digest
# --------------------------------------------------------------------------

proc mixDigest(hash: var uint32, value: int32) {.inline.} =
  ## FNV-1a over the serialized course, byte by byte.
  var v = cast[uint32](value)
  for _ in 0 ..< 4:
    hash = hash xor (v and 0xff'u32)
    hash = hash * 16777619'u32
    v = v shr 8

proc computeDigest(course: Course): int32 =
  var hash = 2166136261'u32
  hash.mixDigest(course.startCol)
  hash.mixDigest(course.startRow)
  hash.mixDigest(course.goalCol)
  hash.mixDigest(course.goalRow)
  for value in course.routeCols: hash.mixDigest(value)
  for value in course.routeRows: hash.mixDigest(value)
  for door in course.doorways:
    hash.mixDigest(door.cx)
    hash.mixDigest(door.cy)
    hash.mixDigest(door.width)
    hash.mixDigest(if door.vertical: 1'i32 else: 0'i32)
  for wall in course.walls:
    hash.mixDigest(wall.x0)
    hash.mixDigest(wall.y0)
    hash.mixDigest(wall.x1)
    hash.mixDigest(wall.y1)
    hash.mixDigest(wall.kind)
  hash.mixDigest(course.routeLen)
  hash.mixDigest(course.parTicks)
  cast[int32](hash)

# --------------------------------------------------------------------------
# Broadphase
# --------------------------------------------------------------------------

proc buildBuckets(course: var Course) =
  ## A uniform 2.4 m grid over the world. Every rect is registered in every
  ## bucket its AABB **expanded by the largest disc radius** overlaps, so a
  ## query is exactly one bucket lookup with no dedup pass: a disc whose CENTRE
  ## is in bucket B can only touch a rect whose expanded AABB covers B.
  ## (The registration is a superset of "the rects that overlap this bucket's
  ## cell", which is what tests/test_course.nim asserts.)
  course.bucketW = (WorldW + BucketSize - 1) div BucketSize
  course.bucketH = (WorldH + BucketSize - 1) div BucketSize
  course.buckets = newSeq[seq[int32]](int(course.bucketW) * int(course.bucketH))
  for i, wall in course.walls:
    let
      bx0 = clamp((wall.x0 - HullRadius) div BucketSize, 0'i32,
        course.bucketW - 1)
      bx1 = clamp((wall.x1 + HullRadius) div BucketSize, 0'i32,
        course.bucketW - 1)
      by0 = clamp((wall.y0 - HullRadius) div BucketSize, 0'i32,
        course.bucketH - 1)
      by1 = clamp((wall.y1 + HullRadius) div BucketSize, 0'i32,
        course.bucketH - 1)
    for by in by0 .. by1:
      for bx in bx0 .. bx1:
        course.buckets[int(by) * int(course.bucketW) + int(bx)].add(int32(i))

proc bucketAt*(course: Course, x, y: int32): int {.inline.} =
  let
    bx = clamp(x div BucketSize, 0'i32, course.bucketW - 1)
    by = clamp(y div BucketSize, 0'i32, course.bucketH - 1)
  int(by) * int(course.bucketW) + int(bx)

iterator nearbyWalls*(course: Course, x, y: int32): int32 =
  ## Every rect index a disc centred at (x, y) could possibly touch.
  if course.buckets.len > 0:
    for index in course.buckets[course.bucketAt(x, y)]:
      yield index

# --------------------------------------------------------------------------
# Generation
# --------------------------------------------------------------------------

proc addDoorwayWalls(
  course: var Course,
  door: Doorway,
  faceLo, faceHi: int32,
  wallLo, wallHi: int32
) =
  ## The two stubs either side of a gap. `faceLo/faceHi` bound the shared face
  ## along its own axis; `wallLo/wallHi` are the wall's thickness bounds.
  let
    half = door.width div 2
    gapLo = door.cy - half
    gapHi = door.cy + half
  if door.vertical:
    if gapLo > faceLo:
      course.walls.add(rectOf(wallLo, faceLo, wallHi, gapLo, 1))
    if gapHi < faceHi:
      course.walls.add(rectOf(wallLo, gapHi, wallHi, faceHi, 1))
  else:
    if gapLo > faceLo:
      course.walls.add(rectOf(faceLo, wallLo, gapLo, wallHi, 1))
    if gapHi < faceHi:
      course.walls.add(rectOf(gapHi, wallLo, faceHi, wallHi, 1))

proc generateCourse*(seed: int64): Course =
  ## The whole warehouse, deterministically, from one seeded integer stream.
  var rng = initRand(seed)
  result.seed = int32(seed and 0x7fff_ffff)

  # 1. Route.
  let startRow = rng.rand(CellRows - 1)
  let goalRow = rng.rand(CellRows - 1)
  var cols: seq[int32] = @[]
  var rows: seq[int32] = @[]
  for attempt in 0 ..< MaxWalkAttempts:
    let walk = walkOnce(rng, startRow, goalRow)
    if walk.cols.len >= MinRouteCells and walk.cols.len <= MaxRouteCells:
      cols = walk.cols
      rows = walk.rows
      break
  var effectiveGoalRow = goalRow
  if cols.len == 0:
    # The deterministic fallback: the monotone path along the start row.
    effectiveGoalRow = startRow
    for col in 0 ..< CellCols:
      cols.add(int32(col))
      rows.add(int32(startRow))
  result.startCol = 0
  result.startRow = int32(startRow)
  result.goalCol = int32(CellCols - 1)
  result.goalRow = int32(effectiveGoalRow)
  result.routeCols = cols
  result.routeRows = rows

  var onRoute: array[CellCols * CellRows, bool]
  var routeAt: array[CellCols * CellRows, int]
  for i in 0 ..< routeAt.len:
    routeAt[i] = -1
  for i in 0 ..< cols.len:
    onRoute[cellIndex(int(cols[i]), int(rows[i]))] = true
    routeAt[cellIndex(int(cols[i]), int(rows[i]))] = i

  # 2. Doorways, in route order.
  let doorCount = cols.len - 1
  for k in 0 ..< doorCount:
    let
      aCol = int(cols[k])
      aRow = int(rows[k])
      bCol = int(cols[k + 1])
      bRow = int(rows[k + 1])
      final = k == doorCount - 1
    var width = DoorWidths[rng.rand(DoorWidths.high)]
    var offset = int32(rng.rand(2 * int(DoorOffsetSpan))) - DoorOffsetSpan
    if final:
      width = FinalDoorWidth
      offset = 0
    let span = CellSize div 2 - DoorEdgeMargin - width div 2
    offset = clamp(offset, -span, span)
    var door = Doorway(width: width)
    if bCol != aCol:
      door.vertical = true
      door.cx = cellX0(max(aCol, bCol))
      door.cy = cellCentreY(aRow) + offset
      door.throughX = if bCol > aCol: 4096'i32 else: -4096'i32
      door.throughY = 0
    else:
      door.vertical = false
      door.cx = cellCentreX(aCol) + offset
      door.cy = cellY0(max(aRow, bRow))
      door.throughX = 0
      door.throughY = if bRow > aRow: 4096'i32 else: -4096'i32
    result.doorways.add(door)

  # 3. Blocks and partitions. The outer ring first, then the solid non-route
  # cells, then every internal boundary. The ring rects deliberately extend
  # `RingOverhang` OUTSIDE the world box: the contact solver pushes a disc that
  # has ended up inside a rect out along its NEAREST face, and an overhanging
  # ring guarantees that face is always the interior one, so no penetration
  # spike can ever eject the assembly through the outer wall.
  result.walls.add(rectOf(-RingOverhang, -RingOverhang,
    WorldW + RingOverhang, WallRing, 0))
  result.walls.add(rectOf(-RingOverhang, WorldH - WallRing,
    WorldW + RingOverhang, WorldH + RingOverhang, 0))
  result.walls.add(rectOf(-RingOverhang, -RingOverhang,
    WallRing, WorldH + RingOverhang, 0))
  result.walls.add(rectOf(WorldW - WallRing, -RingOverhang,
    WorldW + RingOverhang, WorldH + RingOverhang, 0))
  for row in 0 ..< CellRows:
    for col in 0 ..< CellCols:
      if onRoute[cellIndex(col, row)]:
        continue
      result.walls.add(rectOf(cellX0(col), cellY0(row),
        cellX0(col) + CellSize, cellY0(row) + CellSize, 2))
  let half = InnerWall div 2
  for row in 0 ..< CellRows:
    for col in 0 ..< CellCols:
      if not onRoute[cellIndex(col, row)]:
        continue
      for dir in [DirEast, DirSouth]:
        let next = stepCell(col, row, dir)
        if not inGrid(next.col, next.row):
          continue
        if not onRoute[cellIndex(next.col, next.row)]:
          continue
        let
          a = routeAt[cellIndex(col, row)]
          b = routeAt[cellIndex(next.col, next.row)]
          consecutive = (a - b == 1) or (b - a == 1)
        if dir == DirEast:
          let line = cellX0(col + 1)
          if consecutive:
            let k = min(a, b)
            result.addDoorwayWalls(result.doorways[k],
              cellY0(row), cellY0(row) + CellSize, line - half, line + half)
          else:
            result.walls.add(rectOf(line - half, cellY0(row),
              line + half, cellY0(row) + CellSize, 1))
        else:
          let line = cellY0(row + 1)
          if consecutive:
            let k = min(a, b)
            var door = result.doorways[k]
            # `addDoorwayWalls` bounds the gap on the face axis, which for a
            # horizontal face is x. Re-express the gap centre in that axis.
            door.cy = door.cx
            result.addDoorwayWalls(door,
              cellX0(col), cellX0(col) + CellSize, line - half, line + half)
          else:
            result.walls.add(rectOf(cellX0(col), line - half,
              cellX0(col) + CellSize, line + half, 1))

  # 4. Pillars, on every route cell that is neither start nor goal.
  for i in 0 ..< cols.len:
    if i == 0 or i == cols.len - 1:
      continue
    if rng.rand(99) >= 45:
      continue
    let quadrant = rng.rand(3)
    let
      col = int(cols[i])
      row = int(rows[i])
      cx = cellCentreX(col) + (if (quadrant and 1) == 0: -1_400_000'i32
                               else: 1_400_000'i32)
      cy = cellCentreY(row) + (if (quadrant and 2) == 0: -1_400_000'i32
                               else: 1_400_000'i32)
      inDoor = result.doorways[i - 1]
      outDoor = result.doorways[i]
      clearance = segmentDistance(cx, cy, inDoor.cx, inDoor.cy,
        outDoor.cx, outDoor.cy)
    if clearance < int64(PillarClear) + int64(PillarSize div 2):
      continue
    result.walls.add(rectOf(cx - PillarSize div 2, cy - PillarSize div 2,
      cx + PillarSize div 2, cy + PillarSize div 2, 3))

  # 5. The route polyline: cell centres and doorway centres interleaved.
  result.routeX.add(cellCentreX(int(cols[0])))
  result.routeY.add(cellCentreY(int(rows[0])))
  for k in 0 ..< doorCount:
    result.routeX.add(result.doorways[k].cx)
    result.routeY.add(result.doorways[k].cy)
    result.routeX.add(cellCentreX(int(cols[k + 1])))
    result.routeY.add(cellCentreY(int(rows[k + 1])))
  var total = 0'i64
  for i in 1 ..< result.routeX.len:
    total += int64(distI(result.routeX[i] - result.routeX[i - 1],
      result.routeY[i] - result.routeY[i - 1]))
  result.routeLen = int32(max(1'i64, total))
  var narrowDoors = 0
  for door in result.doorways:
    if door.width < NarrowDoorWidth:
      inc narrowDoors
  result.parTicks = int32(
    (int64(result.routeLen) div 1000) * int64(TargetFps) div
      int64(ReferenceCarryMmS) + int64(NarrowDoorParTicks) * int64(narrowDoors))
  if result.parTicks <= 0:
    result.parTicks = 1

  # 6. The goal pad.
  let
    gCol = int(cols[^1])
    gRow = int(rows[^1])
  result.goalX0 = cellX0(gCol) + GoalInset
  result.goalY0 = cellY0(gRow) + GoalInset
  result.goalX1 = cellX0(gCol) + CellSize - GoalInset
  result.goalY1 = cellY0(gRow) + CellSize - GoalInset

  # 7. The digest and the broadphase.
  result.digest = computeDigest(result)
  result.buildBuckets()

proc startPose*(course: Course): tuple[x, y: int32, headingQ: int32] =
  ## Where the assembly starts: the start cell's centre, the couch axis lined
  ## up with the first leg of the route.
  let
    x = cellCentreX(int(course.routeCols[0]))
    y = cellCentreY(int(course.routeRows[0]))
    dx = course.routeX[1] - x
    dy = course.routeY[1] - y
  (x, y, bradsOfVectorI(dx, dy) * 16)

proc inGoalPad*(course: Course, x, y: int32): bool {.inline.} =
  x >= course.goalX0 and x <= course.goalX1 and
    y >= course.goalY0 and y <= course.goalY1

proc goalCentre*(course: Course): tuple[x, y: int32] {.inline.} =
  ((course.goalX0 + course.goalX1) div 2, (course.goalY0 + course.goalY1) div 2)

proc arcAlongRoute*(course: Course, x, y: int32): int64 =
  ## The clamped arc length of the projection of a point onto the route
  ## polyline, in micrometres. Ties by lowest segment index.
  var
    bestDist = high(int64)
    bestArc = 0'i64
    arc = 0'i64
  for i in 1 ..< course.routeX.len:
    let
      ax = course.routeX[i - 1]
      ay = course.routeY[i - 1]
      bx = course.routeX[i]
      by = course.routeY[i]
      p = projectOnSegment(x, y, ax, ay, bx, by)
      dx = int64(x) - p.cx
      dy = int64(y) - p.cy
      dist = isqrt(dx * dx + dy * dy)
    if dist < bestDist:
      bestDist = dist
      bestArc = arc + p.along
    arc += p.length
  bestArc

proc cellOf*(x, y: int32): tuple[col, row: int32] {.inline.} =
  ## The grid cell a world point falls in, clamped to the grid.
  (clamp((x - WallRing) div CellSize, 0'i32, int32(CellCols - 1)),
   clamp((y - WallRing) div CellSize, 0'i32, int32(CellRows - 1)))

proc routeIndexOf*(course: Course, x, y: int32): int =
  ## The route position of the cell a point is in, or the nearest route index
  ## when the point is off the route (which the physics makes rare but not
  ## impossible while a couch is wedged through a doorway).
  let cell = cellOf(x, y)
  for i in 0 ..< course.routeCols.len:
    if course.routeCols[i] == cell.col and course.routeRows[i] == cell.row:
      return i
  var
    best = 0
    bestDist = high(int64)
  for i in 0 ..< course.routeCols.len:
    let d = segmentDistance(x, y,
      cellCentreX(int(course.routeCols[i])),
      cellCentreY(int(course.routeRows[i])),
      cellCentreX(int(course.routeCols[i])),
      cellCentreY(int(course.routeRows[i])))
    if d < bestDist:
      bestDist = d
      best = i
  best

proc nextDoorIndex*(course: Course, x, y: int32): int =
  ## The index of the doorway the assembly is heading for: the outgoing
  ## doorway of the route cell it currently occupies. -1 in the goal cell.
  let i = course.routeIndexOf(x, y)
  if i >= course.doorways.len:
    -1
  else:
    i

# --------------------------------------------------------------------------
# The course in the replay's config JSON
# --------------------------------------------------------------------------
#
# The FULLY EXPANDED course is written into the replay header alongside the
# seed, and playback reads it back rather than regenerating: a future change to
# `generateCourse` can then never desynchronise an old replay.
# `tests/test_course.nim` asserts `generateCourse(recorded.seed) ==
# recorded.course` for the committed fixtures, which keeps the two paths
# honest. Everything here is integers and bools -- no `getFloat`, so this
# module stays inside the float-free grep guard.

proc intArray(values: seq[int32]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%int(value))

proc readIntArray(node: JsonNode): seq[int32] =
  if node.isNil or node.kind != JArray:
    return
  for item in node:
    if item.kind == JInt:
      result.add(int32(item.getInt()))

proc courseToJson*(course: Course): JsonNode =
  var doors = newJArray()
  for door in course.doorways:
    doors.add(%*{
      "cx": int(door.cx), "cy": int(door.cy), "w": int(door.width),
      "v": door.vertical,
      "tx": int(door.throughX), "ty": int(door.throughY)})
  var walls = newJArray()
  for wall in course.walls:
    walls.add(%*[int(wall.x0), int(wall.y0), int(wall.x1), int(wall.y1),
      int(wall.kind)])
  %*{
    "seed": int(course.seed),
    "start": [int(course.startCol), int(course.startRow)],
    "goal": [int(course.goalCol), int(course.goalRow)],
    "routeCols": intArray(course.routeCols),
    "routeRows": intArray(course.routeRows),
    "doorways": doors,
    "walls": walls,
    "routeX": intArray(course.routeX),
    "routeY": intArray(course.routeY),
    "routeLen": int(course.routeLen),
    "parTicks": int(course.parTicks),
    "goalPad": [int(course.goalX0), int(course.goalY0),
                int(course.goalX1), int(course.goalY1)],
    "digest": int(course.digest)
  }

proc courseFromJson*(node: JsonNode): Course =
  ## Rebuilds a recorded course. Returns an empty course (`routeX.len == 0`)
  ## when the node is not a course object, so the caller can fall back to
  ## `generateCourse`.
  if node.isNil or node.kind != JObject or not node.hasKey("walls"):
    return
  result.seed = int32(node{"seed"}.getInt())
  let start = node{"start"}
  if not start.isNil and start.kind == JArray and start.len >= 2:
    result.startCol = int32(start[0].getInt())
    result.startRow = int32(start[1].getInt())
  let goal = node{"goal"}
  if not goal.isNil and goal.kind == JArray and goal.len >= 2:
    result.goalCol = int32(goal[0].getInt())
    result.goalRow = int32(goal[1].getInt())
  result.routeCols = readIntArray(node{"routeCols"})
  result.routeRows = readIntArray(node{"routeRows"})
  for door in node{"doorways"}:
    result.doorways.add Doorway(
      cx: int32(door{"cx"}.getInt()), cy: int32(door{"cy"}.getInt()),
      width: int32(door{"w"}.getInt()), vertical: door{"v"}.getBool(),
      throughX: int32(door{"tx"}.getInt()),
      throughY: int32(door{"ty"}.getInt()))
  for wall in node{"walls"}:
    if wall.kind == JArray and wall.len >= 5:
      result.walls.add(rectOf(int32(wall[0].getInt()), int32(wall[1].getInt()),
        int32(wall[2].getInt()), int32(wall[3].getInt()),
        int32(wall[4].getInt())))
  result.routeX = readIntArray(node{"routeX"})
  result.routeY = readIntArray(node{"routeY"})
  result.routeLen = int32(max(1, node{"routeLen"}.getInt(1)))
  result.parTicks = int32(max(1, node{"parTicks"}.getInt(1)))
  let pad = node{"goalPad"}
  if not pad.isNil and pad.kind == JArray and pad.len >= 4:
    result.goalX0 = int32(pad[0].getInt())
    result.goalY0 = int32(pad[1].getInt())
    result.goalX1 = int32(pad[2].getInt())
    result.goalY1 = int32(pad[3].getInt())
  result.digest = int32(node{"digest"}.getInt())
  result.buildBuckets()

proc pointAtArc*(course: Course, arc: int64): tuple[x, y, dirX, dirY: int32] =
  ## The point a given arc length along the route polyline, plus the Q12 unit
  ## direction of the segment it lands on. Clamped at both ends.
  if course.routeX.len == 0:
    return (0'i32, 0'i32, 4096'i32, 0'i32)
  if course.routeX.len == 1:
    return (course.routeX[0], course.routeY[0], 4096'i32, 0'i32)
  var walked = 0'i64
  for i in 1 ..< course.routeX.len:
    let
      ax = course.routeX[i - 1]
      ay = course.routeY[i - 1]
      bx = course.routeX[i]
      by = course.routeY[i]
      segLen = int64(distI(bx - ax, by - ay))
    if segLen <= 0:
      continue
    let u = unitQ12(bx - ax, by - ay)
    if arc <= walked + segLen:
      let t = max(0'i64, arc - walked)
      return (int32(int64(ax) + ((int64(bx) - int64(ax)) * t) div segLen),
              int32(int64(ay) + ((int64(by) - int64(ay)) * t) div segLen),
              u.x, u.y)
    walked += segLen
  let last = course.routeX.len - 1
  let u = unitQ12(course.routeX[last] - course.routeX[last - 1],
    course.routeY[last] - course.routeY[last - 1])
  (course.routeX[last], course.routeY[last], u.x, u.y)
