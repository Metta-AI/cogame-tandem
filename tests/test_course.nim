## The course generator: 500 seeds of structural invariants, plus the
## generate-vs-recorded agreement that keeps the two paths honest.

import std/[json, strutils]
import lib/helpers

proc structure() =
  var narrowSeen = 0
  var pillarsSeen = 0
  for seed in 1 .. 500:
    let c = generateCourse(int64(seed))
    doAssert c.routeCols.len >= MinRouteCells and
      c.routeCols.len <= MaxRouteCells,
      "seed " & $seed & " route length " & $c.routeCols.len
    doAssert c.routeCols[0] == 0, "seed " & $seed & " does not start in column 0"
    doAssert c.routeCols[^1] == int32(CellCols - 1),
      "seed " & $seed & " does not end in column 8"
    # self-avoiding, and every step is a single orthogonal move
    var seen: seq[int] = @[]
    for i in 0 ..< c.routeCols.len:
      let key = int(c.routeRows[i]) * CellCols + int(c.routeCols[i])
      doAssert key notin seen, "seed " & $seed & " revisits a cell"
      seen.add(key)
      if i > 0:
        let step = abs(int(c.routeCols[i] - c.routeCols[i - 1])) +
          abs(int(c.routeRows[i] - c.routeRows[i - 1]))
        doAssert step == 1, "seed " & $seed & " jumps cells"
        doAssert c.routeCols[i] >= c.routeCols[i - 1],
          "seed " & $seed & " steps west"
    doAssert c.doorways.len == c.routeCols.len - 1
    for k, door in c.doorways:
      var legal = false
      for w in DoorWidths:
        if door.width == w: legal = true
      doAssert legal, "seed " & $seed & " door " & $k & " width " & $door.width
      if door.width < NarrowDoorWidth:
        inc narrowSeen
      # the gap stays inside its face with the edge margin
      let centreOnFace = if door.vertical: door.cy else: door.cx
      let cellCentre =
        if door.vertical: cellCentreY(int(c.routeRows[k]))
        else: cellCentreX(int(c.routeCols[k]))
      let offset = abs(centreOnFace - cellCentre)
      doAssert offset + door.width div 2 <= CellSize div 2 - DoorEdgeMargin,
        "seed " & $seed & " door " & $k & " overruns its face"
    doAssert c.doorways[^1].width == FinalDoorWidth,
      "seed " & $seed & " last door is " & $c.doorways[^1].width
    let lastCentre =
      if c.doorways[^1].vertical: c.doorways[^1].cy else: c.doorways[^1].cx
    let lastCell =
      if c.doorways[^1].vertical: cellCentreY(int(c.routeRows[^2]))
      else: cellCentreX(int(c.routeCols[^2]))
    doAssert lastCentre == lastCell, "seed " & $seed & " last door is off-centre"
    # every non-ring rect is inside the world box; the ring deliberately
    # overhangs it so a contact from inside always pushes toward the interior
    for wall in c.walls:
      if wall.kind == 0:
        continue
      doAssert wall.x0 >= 0 and wall.y0 >= 0 and wall.x1 <= WorldW and
        wall.y1 <= WorldH, "seed " & $seed & " has a rect outside the world"
      doAssert wall.x1 > wall.x0 and wall.y1 > wall.y0
      if wall.kind == 3:
        inc pillarsSeen
        doAssert wall.x1 - wall.x0 == PillarSize
    doAssert c.routeLen > 0 and c.parTicks > 0
    doAssert c.goalX1 > c.goalX0 and c.goalY1 > c.goalY0
    doAssert c.routeX.len == 2 * c.doorways.len + 1
    # the broadphase holds every rect that overlaps its bucket's cell
    doAssert c.buckets.len == int(c.bucketW) * int(c.bucketH)
    let digest = c.digest
    let again = generateCourse(int64(seed))
    doAssert again.digest == digest, "seed " & $seed & " is not reproducible"
    doAssert again.walls.len == c.walls.len
    doAssert again.routeX == c.routeX and again.routeY == c.routeY
  doAssert narrowSeen >= 500, "narrow doors never appeared"
  doAssert pillarsSeen > 100, "pillars never appeared: " & $pillarsSeen
  report "500 seeds generate a legal, reproducible warehouse"

proc broadphaseCovers() =
  ## Every rect that overlaps a bucket's own cell is registered in it.
  let c = generateCourse(4417231)
  for by in 0 ..< int(c.bucketH):
    for bx in 0 ..< int(c.bucketW):
      let
        x0 = int32(bx) * BucketSize
        y0 = int32(by) * BucketSize
        x1 = x0 + BucketSize
        y1 = y0 + BucketSize
      for i, wall in c.walls:
        if wall.x1 < x0 or wall.x0 > x1 or wall.y1 < y0 or wall.y0 > y1:
          continue
        var found = false
        for index in c.buckets[by * int(c.bucketW) + bx]:
          if int(index) == i:
            found = true
            break
        doAssert found,
          "rect " & $i & " overlaps bucket " & $bx & "," & $by &
            " but is not registered in it"
  report "the broadphase buckets cover every overlapping rect"

proc pillarsKeepTheThroughLine() =
  for seed in 1 .. 200:
    let c = generateCourse(int64(seed))
    for i in 1 ..< c.routeCols.len - 1:
      let
        inDoor = c.doorways[i - 1]
        outDoor = c.doorways[i]
      for wall in c.walls:
        if wall.kind != 3:
          continue
        let
          cx = (wall.x0 + wall.x1) div 2
          cy = (wall.y0 + wall.y1) div 2
        let cell = cellOf(cx, cy)
        if cell.col != c.routeCols[i] or cell.row != c.routeRows[i]:
          continue
        let d = segmentDistance(cx, cy, inDoor.cx, inDoor.cy,
          outDoor.cx, outDoor.cy)
        doAssert d >= int64(PillarClear) + int64(PillarSize div 2),
          "seed " & $seed & " pillar blocks the through-line (" & $d & " um)"
  report "no pillar comes inside 1.30 m of its cell's through-line"

proc parIsMonotone() =
  var shortest = high(int32)
  var longest = 0'i32
  for seed in 1 .. 200:
    let c = generateCourse(int64(seed))
    doAssert c.parTicks > 0
    shortest = min(shortest, c.routeLen)
    longest = max(longest, c.routeLen)
    let bare = (int64(c.routeLen) div 1000) * 24 div 1600
    doAssert int64(c.parTicks) >= bare,
      "par is under the bare carry time for seed " & $seed
  doAssert longest > shortest, "every course had the same route length"
  report "parTicks tracks route length and the narrow-door surcharge"

proc recordedCourseRoundTrips() =
  ## `generateCourse(recorded.seed) == recorded.course`: the JSON path and the
  ## generator path cannot drift apart.
  for seed in [4417231, 7, 991, 20260823]:
    let c = generateCourse(int64(seed))
    var config = defaultGameConfig()
    config.seed = seed
    let json = config.configJson(c)
    let back = recordedCourse(json)
    doAssert back.digest == c.digest, "digest drifted for seed " & $seed
    doAssert back.walls.len == c.walls.len
    doAssert back.routeX == c.routeX and back.routeY == c.routeY
    doAssert back.parTicks == c.parTicks and back.routeLen == c.routeLen
    doAssert back.goalX0 == c.goalX0 and back.goalY1 == c.goalY1
    doAssert back.doorways.len == c.doorways.len
    for i in 0 ..< c.doorways.len:
      doAssert back.doorways[i].width == c.doorways[i].width
      doAssert back.doorways[i].cx == c.doorways[i].cx
      doAssert back.doorways[i].cy == c.doorways[i].cy
    doAssert back.buckets.len == c.buckets.len
  report "the recorded course round-trips through the replay config JSON"

proc startPoseIsInside() =
  for seed in 1 .. 200:
    var config = testConfig(seed = seed)
    let sim = initSimServer(config)
    for disc in 0 ..< DiscCount:
      let p = sim.discPos(disc)
      doAssert p.x > 0 and p.y > 0 and p.x < WorldW and p.y < WorldH,
        "seed " & $seed & " starts a disc outside the world"
  report "every seed starts the assembly inside the warehouse"

when isMainModule:
  structure()
  broadphaseCovers()
  pillarsKeepTheThroughLine()
  parIsMonotone()
  recordedCourseRoundTrips()
  startPoseIsInside()
  echo "test_course: the warehouse generator is sound"
