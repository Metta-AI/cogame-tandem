## The HTTP/websocket routes the certifier and the runner actually probe.
##
## §Tests 9 asks for `/healthz`; a `/global` snapshot -> ticks -> game over;
## `/client/global` and `/client/player` serving real pages without opening the
## player socket; and both still answering 15 s after the artifacts are written
## (EDIT 5's shutdown grace). Every one of those is a LIVE-SERVER property —
## `registrationOf` and friends cannot show it — so this file starts the real
## `runServerLoop` on a private port and talks to it.
##
## Timing: the episode is 120 ticks with a 1 s lobby timeout, then the bounded
## 20 s shutdown grace, which is the window the 15 s probe measures.

import std/[httpclient, json, monotimes, options, os, strutils, times]
import lib/helpers
import tandem/server
import whisky

const
  TestPort = 34817
  Base = "http://127.0.0.1:" & $TestPort

var scoresPath = ""

proc serverMain(path: string) {.thread.} =
  {.gcsafe.}:
    var config = testConfig(maxTicks = 120)
    config.lobbyJoinTimeoutTicks = 24      ## 1 s of lobby, then play anyway.
    config.gameOverTicks = 2
    runServerLoop(
      host = "127.0.0.1",
      port = TestPort,
      initialConfig = config,
      saveScoresPath = path)

proc get(path: string, timeoutMs = 4000): tuple[code: int, body: string] =
  var client = newHttpClient(timeout = timeoutMs)
  try:
    let response = client.request(Base & path, httpMethod = HttpGet)
    result = (response.code.int, response.body)
  finally:
    client.close()

proc waitForHealth(deadlineMs: int): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = deadlineMs)
  while getMonoTime() < deadline:
    try:
      if get("/healthz").code == 200:
        return true
    except CatchableError:
      discard
    sleep(100)
  false

proc routesAnswerAndTheGraceHolds() =
  scoresPath = tempPath("routes-scores.json")
  removeFile(scoresPath)
  var thread: Thread[string]
  createThread(thread, serverMain, scoresPath)

  doAssert waitForHealth(60_000), "the server never answered /healthz"
  let health = get("/healthz")
  doAssert health.code == 200 and "healthy" in health.body,
    "/healthz answered " & $health.code & " " & health.body

  # BOTH client routes serve the real broadcast page, and NEITHER opens the
  # player socket: the certifier probes them before any player pod starts
  # (lantern 0.1.1). A plain GET that reached the websocket branch would 403 or
  # hang; it must return the page.
  for path in ["/client/global", "/client/player?slot=0&token=t0"]:
    let page = get(path)
    doAssert page.code == 200, path & " answered " & $page.code
    doAssert "<html" in page.body.toLowerAscii(), path & " served no page"
    doAssert "id=\"scorebug\"" in page.body and "id=\"transport\"" in page.body,
      path & " served something that is not the broadcast chrome"
    doAssert page.body.len > 100_000,
      path & " served a " & $page.body.len & "-byte stub"

  # The /global spectator websocket: snapshot -> ticks -> game over. Opened
  # with the same client the player container uses.
  let viewer = newWebSocket("ws://127.0.0.1:" & $TestPort & "/global")
  var frames = 0
  var sawGameOver = false
  let deadline = getMonoTime() + initDuration(seconds = 45)
  while getMonoTime() < deadline and not sawGameOver:
    let message = viewer.receiveMessage(5000)
    if message.isNone:
      break
    inc frames
    # The chrome state JSON rides the binary sprite stream as the label of a
    # reserved 1x1 sprite — that is the only channel that survives a hosted
    # replay — so the phase is a substring of the frame's bytes.
    if "\"ph\":\"gameover\"" in message.get().data:
      sawGameOver = true
  viewer.close()
  doAssert frames > 0, "the /global socket never sent a frame"
  doAssert sawGameOver,
    "the /global stream never reached game over in " & $frames & " frames"

  # A bad token is refused BEFORE the upgrade.
  var refused = false
  try:
    let bad = newWebSocket(
      "ws://127.0.0.1:" & $TestPort & "/player?slot=0&token=wrong")
    bad.close()
  except CatchableError:
    refused = true
  doAssert refused, "a bad player token was upgraded instead of 403'd"

  # EDIT 5: the artifacts are written and the listener keeps answering for a
  # bounded grace. The runner pings /global with a 2 s deadline AFTER the
  # player pods start, and a short episode can already be gone.
  let artifactDeadline = getMonoTime() + initDuration(seconds = 60)
  while getMonoTime() < artifactDeadline and not fileExists(scoresPath):
    sleep(200)
  doAssert fileExists(scoresPath), "the episode never wrote its results"
  let results = parseJson(readFile(scoresPath))
  doAssert results["reason"].getStr().len > 0
  sleep(15_000)
  let late = get("/healthz")
  doAssert late.code == 200,
    "/healthz stopped answering 15 s after the artifacts were written (" &
      $late.code & ")"
  doAssert get("/client/global").code == 200,
    "/client/global stopped answering inside the shutdown grace"

  joinThread(thread)
  doAssert not waitForHealth(2000),
    "the server was still listening after the grace expired"
  removeFile(scoresPath)
  report "the routes answer, the /global stream runs to game over, and the " &
    "grace holds 15 s past the artifacts"

when isMainModule:
  routesAnswerAndTheGraceHolds()
  echo "test_routes: /healthz, /global and both /client routes are real"
