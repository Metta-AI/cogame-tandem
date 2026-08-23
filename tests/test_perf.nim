## Release-only: a full run of physics plus control compilation has to be fast
## enough that sim time is never what makes an episode overrun. The engine
## target is under 5 s on a CI runner; the bound here is deliberately loose so
## a slow shared runner does not go red for the wrong reason.

import std/[monotimes, strutils, times]
import lib/helpers

proc fullRunIsFast() =
  let started = getMonoTime()
  let run = runScripted(testConfig(maxTicks = DefaultMaxTicks),
    "porter", "porter")
  let elapsed = (getMonoTime() - started).inMilliseconds
  echo "    ", run.ticks, " ticks in ", elapsed, " ms (",
    formatFloat(float(elapsed) * 1000.0 / float(max(1, run.ticks)),
      ffDecimal, 1), " us/tick)"
  doAssert run.ticks > 100, "the run was too short to time"
  doAssert elapsed < 60_000,
    $run.ticks & " ticks took " & $elapsed & " ms, over the 60 s bound"
  report "a full run of physics and control compilation fits the budget"

proc courseGenerationIsFast() =
  let started = getMonoTime()
  for seed in 1 .. 200:
    discard generateCourse(int64(seed))
  let elapsed = (getMonoTime() - started).inMilliseconds
  echo "    200 courses in ", elapsed, " ms"
  doAssert elapsed < 20_000, "course generation took " & $elapsed & " ms"
  report "the course generator is fast enough to run at every episode start"

when isMainModule:
  fullRunIsFast()
  courseGenerationIsFast()
  echo "test_perf: sim time is never the bottleneck"
