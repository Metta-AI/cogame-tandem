## Private evidence artifacts: exclusive creation, no spectator publication.
import std/[json, os, posix]
import crunchy
import prompts

type EvidenceError* = object of Defect

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  result = selection.selectionMetadata()
  result["system_sha256"] = %sha256(system).toHex
  result["user_sha256"] = %sha256(user).toHex

proc writePrivate*(destination, content: string) =
  let parent = destination.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
    setFilePermissions(parent, {fpUserRead, fpUserWrite, fpUserExec})
  let descriptor = posix.open(destination.cstring, O_WRONLY or O_CREAT or O_EXCL, Mode(0o600))
  if descriptor < 0:
    raise newException(EvidenceError, "cannot create private evidence: " & $osLastError())
  var output: File
  if not open(output, FileHandle(descriptor), fmWrite):
    let code = osLastError()
    discard posix.close(descriptor)
    raise newException(EvidenceError, "cannot open private evidence: " & $code)
  defer: output.close()
  if output.writeBuffer(content.cstring, content.len) != content.len:
    raise newException(EvidenceError, "incomplete private evidence write")

proc appendPrivate*(destination: string, record: JsonNode) =
  ## The owning host creates this file privately before starting its workers.
  var output: File
  if not open(output, destination, fmAppend):
    raise newException(EvidenceError, "cannot append private evidence")
  defer: output.close()
  let content = $record & "\n"
  if output.writeBuffer(content.cstring, content.len) != content.len:
    raise newException(EvidenceError, "incomplete private evidence append")
