import bowdy/engine/vancodegen
import std/[options, os, tables]
import pkg/openparser/json
import pkg/vancode/interpreter/[ast, codegen, chunk, sym, vm, value,
  resolver]
import pkg/vancode/interpreter/jit/jit
import pkg/vancode/interpreter/jit/compiler_bridge
import bowdy/engine/parser
import bowdy/engine/stdlib/[libsystem, libarrays, libcolors, libcss, cssvalues]
import bowdy/engine/jitbridge
import unittest

const sampleFull = """:root
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

const sampleMini = """.a
  color: red
"""

proc mem(tag: string) =
  echo tag & " occupied=" & $getOccupiedMem()

var reusedVm: Vm = nil

proc oneIter(program: Ast): string =
  codegen.resetCustomProps()
  let mainChunk = newChunk("input.bass")
  var script = newScript(mainChunk)
  var module = newModule("input.bass", some("input.bass"))
  let systemModule = libsystem.loadLibrary(script, newJObject(), newJObject())
  module.load(systemModule)
  module.load(libcolors.initColors(script, systemModule))
  module.load(libarrays.initArrays(script, systemModule))
  module.load(libcss.initCssTypes(script, systemModule))
  script.stdpos = script.procs.high
  mem("  post-stdlib")
  if getEnv("MEM_SKIP", "") == "stdlib":
    return ""
  var gen = initCodeGen(script, module, mainChunk,
    manager = nil, parserCallback = nil)
  gen.genScript(program, none(string))
  mem("  post-codegen")
  if reusedVm == nil or getEnv("MEM_REUSEVM", "0") != "1":
    reusedVm = newVirtualMachine(VMPreferences(
      enableHotCodeDetection: true,
      hotProcThreshold: 10,
      hotChunkThreshold: 1
    ))
  let virtualMachine = reusedVm
  if getEnv("MEM_NOJIT", "0") != "1":
    resetJitState()
    mem("  post-reset")
    virtualMachine.prewarmScriptOps(script)
    mem("  post-prewarm")
    virtualMachine.installJit()
    initBroJit(virtualMachine)
    mem("  post-install")
  if getEnv("MEM_SKIP", "") == "interpret":
    return ""
  result = virtualMachine.interpret(script, mainChunk).stringVal[]
  mem("  post-interpret")
  var a, b, c, d: int
  jitDebugCounts(a, b, c, d)
  echo "  census meta=" & $a & " strs=" & $b & " floats=" & $c & " live=" & $d &
    " cachedAst=" & $codegen.codegenCache.cachedAst.len &
    " ring=" & $jitRingOccupancy()
  if getEnv("MEM_RINGTEST", "0") == "1":
    jitClearRing()
    GC_fullCollect()
    mem("  post-ringclear-test")
  if getEnv("MEM_COLLECT", "0") == "1":
    GC_fullCollect()
    mem("  post-collect")

type LeakProbe = object
  s: string

var probeDestroyed = 0

proc `=destroy`(p: var LeakProbe) =
  inc probeDestroyed

suite "phase attribution (temporary)":
  test "probe destroy dispatch":
    block:
      var q = LeakProbe(s: "hi")
      doAssert q.s == "hi"
    GC_fullCollect()
    echo "probe-destroyed=" & $probeDestroyed
    check probeDestroyed == 1

  test "destroy dispatch check":
    let before = cssvalues.cssPayloadFreed
    block:
      let v = initCssPayload(ord(ttyCssVar), CssVar(name: "--x", fallback: ""),
        "var(--x)")
      check v.objectVal.foreign.data != nil
    GC_fullCollect()
    echo "made=1 freed-delta=" & $(cssvalues.cssPayloadFreed - before)
    check (cssvalues.cssPayloadFreed - before) == 1

  test "per-step mem over 6 iters":
    let sample = if getEnv("MEM_SAMPLE", "") == "mini": sampleMini
      else: sampleFull
    let file = getEnv("MEM_FILE", "")
    for i in 1..6:
      var program: Ast
      if file.len > 0:
        parser.parseScript(program, readFile(file), file)
      else:
        parser.parseScript(program, sample, "input.bass")
      mem("post-parse")
      echo "iter=" & $i & " made=" & $cssvalues.cssPayloadMade &
        " freed=" & $cssvalues.cssPayloadFreed
      let css = oneIter(program)
      if getEnv("MEM_SKIP", "").len == 0:
        check css.len > 0
      mem("end iter")
    check true
