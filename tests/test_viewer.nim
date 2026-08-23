## Static assertions over the chrome, the shell and the bundle recipe. The
## chrome is the STARTER'S — a from-scratch page that reuses its ids is a
## rewrite, not a fork — so this file pins the provenance as hard as it pins
## the readouts.

import std/[os, strutils]
import lib/helpers

const InheritedChromeIds = [
  "viewport", "stage", "board", "lightpool", "grain", "chrome", "scorebug",
  "plates-l", "plates-r", "clock", "clock-time", "clock-caption",
  "ffwd-mini", "mmwarn", "bannerlane", "killfeed", "transport",
  "btn-restart", "btn-back", "btn-play", "btn-fwd", "btn-end", "btn-loop",
  "btn-skip", "btn-spoilers", "ffwd-chip", "win-chip", "tick-clock",
  "speedchips", "scrub", "momentum", "scrub-fill", "lulls", "scrub-win",
  "scrub-head", "endcard", "ec-headline", "ec-wincond", "ec-how", "ec-teams",
  "ec-replay", "status", "lockerroom", "lk-art", "lk-bg", "lk-sprites",
  "lk-cap"
]

const AddedTandemIds = [
  "condbig", "routerail", "routerail-track", "routerail-fill", "doorcall",
  "doorcall-w", "arrowlegend"
]

## The board is FIXED (1110 x 630 logical) and always fits the frame, so the
## starter's zoom bar + minimap panel is DROPPED rather than hidden.
const RemovedZoomIds = [
  "viewpanel", "minimap", "minimap-canvas", "zoombar", "zoom-out",
  "zoom-slider", "zoom-in", "zoom-read"
]

const RemovedCtfIds = [
  "fpv", "fpv-canvas", "fpv-hud", "fpv-hp", "fpv-map", "fpv-map-canvas",
  "fpv-name", "fpv-cap", "fpv-gear", "fpv-grip", "povBadge"
]

const BeatKindsEmitted = [
  "doorway", "impact", "drop", "wrecked", "delivered", "over"
]

proc chromeIsTheStarters() =
  ## `chrome_common.js` is byte-identical to coworld-ctf's copy. The pin is a
  ## length + digest of the file, so a "small tidy-up" cannot slip through.
  let js = repoFile("client/chrome_common.js")
  doAssert js.len == 40_022,
    "client/chrome_common.js is " & $js.len & " bytes; the starter's is 40022" &
      " — it must be copied BYTE-FOR-BYTE"
  var checksum = 1469598103934665603'u64
  for ch in js:
    checksum = checksum xor uint64(ord(ch))
    checksum = checksum * 1099511628211'u64
  doAssert checksum == 0x6034cf58c85dd060'u64,
    "client/chrome_common.js has been edited (fnv1a " &
      toHex(checksum) & ")"
  doAssert "window.ChromeCommon = function (ctx)" in js
  report "chrome_common.js is byte-for-byte the starter's"

proc chromeMarkup() =
  let page = repoFile("client/replay_broadcast.html")
  for id in InheritedChromeIds:
    doAssert ("id=\"" & id & "\"") in page,
      "the inherited chrome id #" & id & " is gone"
  for id in AddedTandemIds:
    doAssert ("id=\"" & id & "\"") in page, "tandem's #" & id & " is missing"
  for id in RemovedCtfIds:
    doAssert ("id=\"" & id & "\"") notin page,
      "the CTF-only #" & id & " is still there"
  for id in RemovedZoomIds:
    doAssert ("id=\"" & id & "\"") notin page,
      "the zoom/minimap #" & id & " is still there"
  doAssert "core.attachMinimap" notin page and "core.zoomAt" notin page,
    "something still wires the zoom API"
  doAssert "TANDEM additions to the inherited coworld-ctf chrome" in page,
    "the appended game block has no provenance banner"
  report "the chrome markup: inherited ids kept, tandem ids added, CTF ids gone"

proc transportRules() =
  let page = repoFile("client/replay_broadcast.html")
  doAssert "function relayout()" in page, "relayout() is gone"
  doAssert "root.style.setProperty('--hudscale'" in page,
    "relayout no longer sets --hudscale on :root"
  doAssert "root.style.setProperty('--band'" in page,
    "relayout no longer reserves the transport band on :root"
  doAssert "root.style.setProperty('--topband'" in page
  doAssert "Math.max(0.5, Math.min(1.6, boardW / 760))" in page,
    "the --hudscale clamp changed"
  doAssert "classList.toggle('tiny'" in page, "the .tiny class is gone"
  doAssert "#endcard { bottom: var(--band" in page or
    "bottom: var(--band, 0px);" in page,
    "the endcard no longer stops at the transport band"
  doAssert "$('endcard').classList.remove('on')" in page,
    "a seek no longer dismisses the endcard"
  # No tandem overlay may sit IN the transport band.
  doAssert "bottom: calc(var(--band, 0px) + 10 * var(--u))" in page,
    "tandem's overlays are not offset from var(--band)"
  report "the transport rules hold: --band/--hudscale, nothing over the band"

proc beatsAreLabelledButtons() =
  let page = repoFile("client/replay_broadcast.html")
  doAssert "function markTandemBeat(tick, kind, team, label)" in page,
    "the game block's beat builder does not take a label"
  doAssert "document.createElement('button')" in page,
    "scrubber beats are not buttons"
  doAssert "mark.setAttribute('aria-label', text)" in page
  doAssert "mark.onclick" in page and "send('s:' + tick)" in page,
    "a beat marker does not seek on click"
  for kind in BeatKindsEmitted:
    doAssert (".beat-marker." & kind) in page,
      "no CSS rule for the `" & kind & "` beat kind"
  # The [spoilers] gate. chrome_common gates its own `markerEls`, a
  # closure-private array the byte-frozen file does not export, so the game
  # block runs the same rule over the buttons it created — otherwise every
  # beat AHEAD of the playhead is visible with spoilers off.
  doAssert "function applyTandemSpoilers(s)" in page,
    "tandem's beat markers have no spoiler gate"
  doAssert "getSpoilers()" in page, "the spoiler gate never reads the toggle"
  doAssert "applyTandemSpoilers(s);" in page,
    "the spoiler gate is never called from the per-frame hook"
  doAssert "el.__tick > (s.t || 0)" in page,
    "the spoiler gate does not compare the beat tick to the playhead"
  report "every beat kind is a labelled, clickable button with its own CSS"

proc identHead(text: string): string =
  ## The leading JS identifier of `text`, or "" if it does not start with one.
  for ch in text:
    if ch in IdentChars or ch == '$':
      result.add ch
    else:
      break
  if result.len > 0 and result[0] in Digits:
    result = ""

proc noAliasIsShadowed() =
  ## THE SCOPE CHECK. `beatsAreLabelledButtons` above is a text grep, and a
  ## text grep cannot see a binding: r2-F1 shipped with all four of its needles
  ## present and the code they name DEAD. The page's whole per-view script is
  ## ONE function scope, opened by `(function () {` and closed at the end of
  ## the file, and it starts by aliasing ~40 names out of the shared chrome
  ## (`var markBeat = C.markBeat, ...`). `var` and `function` declarations
  ## share that one scope, so a game-block `function markBeat(...)` below is
  ## hoisted at scope entry and then OVERWRITTEN by the alias assignment when
  ## the script runs — every call site silently resolves to chrome_common's
  ## copy, the game block's version never executes, and nothing in the source
  ## looks wrong.
  ##
  ## So: no name aliased from the shared chrome may also be declared by a
  ## top-level `function` or `var` of the same IIFE. This is a static
  ## scope-duplication check — it needs no browser, and it fails on the
  ## pre-fix page.
  for path in ["client/replay_broadcast.html", "client/league_replayer.html"]:
    let page = repoFile(path)
    let start = page.find("window.ChromeCommon({")
    doAssert start > 0, path & " no longer builds the shared chrome"
    var aliases: seq[string] = @[]
    var declared: seq[string] = @[]
    for raw in page[start .. ^1].splitLines():
      # The top level of the IIFE is indented by exactly two spaces; anything
      # deeper is a nested scope and cannot capture an alias.
      if not raw.startsWith("  ") or raw.startsWith("   "): continue
      let line = raw.strip()
      if line.startsWith("function "):
        let name = identHead(line[9 .. ^1].strip())
        if name.len > 0: declared.add name
      elif line.startsWith("var "):
        let parts = line[4 .. ^1].split(',')
        for index, part in parts.pairs:
          let piece = part.strip()
          # `var a = 1, b = 2` declares a and b; the tail of an object or array
          # literal spilled onto the same line declares nothing.
          if index > 0 and '=' notin piece: continue
          let name = identHead(piece)
          if name.len == 0: continue
          let rhs = if '=' in piece: piece.split('=', 1)[1].strip() else: ""
          if rhs.startsWith("C.") or rhs.startsWith("C["):
            aliases.add name
          else:
            declared.add name
    doAssert aliases.len >= 20,
      "only " & $aliases.len & " chrome aliases found in " & path &
        " — the scope check is not reading the alias block"
    doAssert declared.len >= 20,
      "only " & $declared.len & " top-level declarations found in " & path &
        " — the scope check is not reading the IIFE"
    for name in aliases:
      doAssert name notin declared,
        "`" & name & "` is BOTH aliased from chrome_common and declared at the" &
          " top level of the same scope in " & path & ": the alias assignment" &
          " wins at load and the local declaration is dead code (r2-F1). Give" &
          " the local one its own name."
  report "no chrome alias is shadowed by a declaration in the same scope"

proc feedRowsAreNotDoubleEscaped() =
  ## §Viewer readout 9: the match feed is where a spectator reads the LLM's
  ## own words. `esc()` returns HTML entities and `textContent` then displays
  ## them literally, so `esc()` into `textContent` renders a model's quote as
  ## `&quot;`. The feed row is assigned the raw string; `textContent` is what
  ## makes it inert.
  let page = repoFile("client/replay_broadcast.html")
  doAssert "row.textContent = line.text;" in page,
    "the feed row does not take the raw text"
  doAssert "textContent = esc(" notin page,
    "an escaped string is being written into textContent (double-escaped)"
  report "match-feed rows render the model's words, not HTML entities"

proc legibleAt360() =
  let page = repoFile("client/replay_broadcast.html")
  doAssert ".plate-name { flex: 1 1 auto; min-width: 3.2em" in page,
    "the .plate-name rule that stops policy names collapsing to an ellipsis"
  doAssert "@media (max-width: 640px)" in page,
    "the 640 px media block is missing"
  let block360 = page[page.find("@media (max-width: 640px)") .. ^1]
  for needle in [".strain-num", ".plate-blame", "#arrowlegend"]:
    doAssert needle in block360[0 ..< min(1200, block360.len)],
      needle & " is not hidden under 640 px"
  doAssert "#stage.tiny .strain-num" in page,
    "the .tiny density rules are missing"
  report "the scorebug stays legible at 360 px"

proc noCtfIdentifiersSurvive() =
  ## Nothing may still call itself `ctf` — with ONE deliberate exception:
  ## `client/chrome_common.js` is pinned BYTE-FOR-BYTE to the starter's copy,
  ## and its one `window.CTF_WIRE` read falls back to the literals that are
  ## already tandem's values (speeds [1,2,3,4,8,16], fps 24).
  for path in ["client/replay_broadcast.html", "client/broadcast_core.js",
               "client/league_replayer.html",
               "replay-viewer/static_replay.js",
               "replay-viewer/static_replay_worker.js",
               "replay-viewer/config.nims",
               "replay-viewer/tandem_replay.nim"]:
    let text = repoFile(path)
    doAssert "CTF_" notin text, "a CTF_ identifier survives in " & path
    doAssert "ctf_" notin text, "a ctf_ identifier survives in " & path
    doAssert "Ctf" notin text, "a Ctf identifier survives in " & path
  for path in ["sim.nim", "server.nim", "global.nim", "replays.nim",
               "broadcast.nim", "control.nim", "orders.nim"]:
    let text = repoFile("src/tandem/" & path)
    doAssert "CTF_" notin text and "ctf_" notin text,
      "a ctf identifier survives in src/tandem/" & path
  report "no ctf_/CTF_ identifier survives outside the pinned chrome_common.js"

proc broadcastCoreDiffersOnlyInTheWireName() =
  ## `broadcast_core.js` is the starter's, changed in EXACTLY the wire-constant
  ## identifier.
  let js = repoFile("client/broadcast_core.js")
  doAssert "window.TANDEM_WIRE" in js,
    "broadcast_core.js does not read the tandem wire constants"
  doAssert js.count("TANDEM_WIRE") == 2,
    "broadcast_core.js mentions TANDEM_WIRE " & $js.count("TANDEM_WIRE") &
      " times; the starter reads CTF_WIRE exactly twice on one line"
  doAssert "chromeSpriteId" in js
  report "broadcast_core.js differs from the starter only in the wire name"

proc shellContract() =
  let shell = repoFile("replay-viewer/static_replay.js")
  doAssert "data-replay-loaded" in shell,
    "the shell does not set data-replay-loaded on its first drawn frame"
  doAssert "data-replay-error" in shell,
    "the shell does not publish a machine-readable failure"
  doAssert "data-replay-mismatch-tick" in shell
  doAssert "static_replay_worker.js" in shell,
    "the shell no longer owns the wasm runtime in a Worker"
  doAssert "Module.onRuntimeInitialized" in
    repoFile("replay-viewer/static_replay_worker.js"),
    "the worker bootstrap is not the non-modularized form"
  let flags = repoFile("replay-viewer/config.nims")
  doAssert "MODULARIZE" notin flags,
    "config.nims gained MODULARIZE; the paintbot shell waits on " &
      "onRuntimeInitialized and would hang forever"
  doAssert "EXPORT_NAME" notin flags, "config.nims gained EXPORT_NAME"
  doAssert "_tandem_load_replay" in flags and "_tandem_frame" in flags
  doAssert "tandem_load_replay" in
    repoFile("replay-viewer/static_replay_worker.js")
  report "the shell and the emscripten link flags are a matched pair"

proc bundleRecipeIsComplete() =
  let dockerfile = repoFile("Dockerfile.replay-viewer")
  for asset in ["tandem_replay.wasm", "tandem_replay.data", "index.html",
                "static_replay.js", "static_replay_worker.js",
                "chrome_common.js", "wire_constants.js", "font.ttf",
                "art/walls/wall_h.jpg", "art/lockerroom/bg.jpg"]:
    doAssert asset in dockerfile, "the bundle does not ship " & asset
  doAssert "data-replay-loaded" in dockerfile and
    "data-replay-error" in dockerfile,
    "the bundle build does not assert the shell's load/error attributes"
  let hook = repoFile("tools/build_replay_viewer.sh")
  doAssert "static-replay-viewer" in hook, "the hook guards its output name"
  doAssert "Dockerfile.replay-viewer" in hook,
    "the hook does not fall back to the pinned emsdk container"
  doAssert "mkdir -p \"$(dirname \"${requested_output}\")\"" in hook,
    "the hook does not pre-create its output parent (it exits 1 on a fresh " &
      "CI checkout without this)"
  report "the bundle recipe lists every file the platform serves"

proc artIsReal() =
  for asset in ["client/art/walls/wall_h.jpg", "client/art/walls/wall_v.jpg",
                "client/art/lockerroom/bg.jpg",
                "client/art/lockerroom/blue_1.webp",
                "client/art/lockerroom/red_1.webp",
                "data/font.ttf"]:
    doAssert repoFile(asset).len > 1000,
      asset & " is not real art (" & $repoFile(asset).len & " bytes)"
  for livery in ["blue", "red"]:
    for segment in ["head", "arm_l", "arm_r", "leg_fl", "leg_fr", "leg_rear",
                    "wheel_l", "wheel_r", "wheel_rear"]:
      let path = "data/rig_real/" & livery & "/" & segment & ".png"
      doAssert repoFile(path).len > 3000,
        path & " is not the shipped rig art"
  report "the cogs are the starter's real rigs and the board art is real"

when isMainModule:
  chromeIsTheStarters()
  chromeMarkup()
  transportRules()
  beatsAreLabelledButtons()
  noAliasIsShadowed()
  feedRowsAreNotDoubleEscaped()
  legibleAt360()
  noCtfIdentifiersSurvive()
  broadcastCoreDiffersOnlyInTheWireName()
  shellContract()
  bundleRecipeIsComplete()
  artIsReal()
  echo "test_viewer: the chrome is the starter's and the bundle is complete"
