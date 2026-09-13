import bowdy
import unittest
import std/[os, strutils]

const sample = """:root
  --bg: #0d6efd
  --gap: 1rem
.a
  color: var(--bg)
  margin: var(--gap)
  display: flex
.b
  color: darken(#0d6efd, 10)
  width: 100px
"""

suite "mem harness (temporary)":
  test "loop compiles and report GC mem":
    let iters =
      try: parseInt(getEnv("MEM_ITERS", "20"))
      except: 20
    let useJit = getEnv("MEM_JIT", "0") == "1"
    let file = getEnv("MEM_FILE", "")
    var allOk = true
    for i in 1..iters:
      let r =
        if file.len > 0: compileStylesheetFile(file, jit = useJit)
        else: compileStylesheet(sample, jit = useJit)
      allOk = allOk and r.ok
      echo "iter=" & $i & " jit=" & $useJit &
        " occupied=" & $getOccupiedMem() &
        " total=" & $getTotalMem()
    check allOk
    if getEnv("MEM_SLEEP", "0") == "1":
      echo "READY pid=" & $getCurrentProcessId()
      stdout.flushFile()
      while true: sleep(60_000)
