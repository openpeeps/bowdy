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
    let file = getEnv("MEM_FILE", "")
    var allOk = true
    for i in 1..iters:
      let r =
        if file.len > 0: compileStylesheetFile(file)
        else: compileStylesheet(sample)
      allOk = allOk and r.ok
      echo "iter=" & $i &
        " occupied=" & $getOccupiedMem() &
        " total=" & $getTotalMem()
    check allOk
    if getEnv("MEM_SLEEP", "0") == "1":
      echo "READY pid=" & $getCurrentProcessId()
      stdout.flushFile()
      while true: sleep(60_000)
