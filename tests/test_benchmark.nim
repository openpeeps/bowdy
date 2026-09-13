import unittest
import std/[monotimes, options, os, strutils, times]
import pkg/openparser/json

import ../src/bowdy/engine/vancodegen
import ../src/bowdy/engine/parser

import pkg/vancode/interpreter/[ast, codegen, chunk, sym, vm, value]

import ../src/bowdy/engine/stdlib/[libsystem, libarrays, libcolors, libcss]

proc generate(count: int): string =
  var buf: string
  buf.add ":root {\n"
  for i in 0 ..< 30:
    buf.add "  --c" & $i & ": #0d6efd;\n"
  buf.add "}\n\n"
  for i in 0 ..< count:
    buf.add ".p-" & $i & " { padding: " & $i & "rem; }\n"
    buf.add ".component-" & $i & " {\n"
    buf.add "  color: #333;\n"
    buf.add "  background: var(--c" & $(i mod 30) & ");\n"
    buf.add "  .title { font-size: " & $(1 + i mod 3) & ".25rem; font-weight: bold; }\n"
    buf.add "  .body { line-height: 1.5; padding: 1rem; margin: -0.5rem -0.25rem; }\n"
    buf.add "}\n\n"
  for i in 0 ..< (count div 2):
    buf.add "@media (min-width: " & $(576 + i * 10) & "px) {\n"
    buf.add "  .component-" & $i & " .title { font-size: 2rem; }\n"
    buf.add "}\n\n"
  for i in 0 ..< (count div 2):
    buf.add "@keyframes slide-" & $i & " {\n"
    buf.add "  from { opacity: 0; }\n  to { opacity: 1; }\n"
    buf.add "}\n\n"
  result = buf

proc runCompile(code, path: string): (string, float, float, float) =
  ## Returns (css, parseSeconds, codegenSeconds, vmSeconds).
  var t = getMonoTime()
  var program: Ast
  parser.parseScript(program, code, path)
  let tParse = (getMonoTime() - t).inMilliseconds.float

  t = getMonoTime()
  let mainChunk = newChunk(path)
  var script = newScript(mainChunk)
  var module = newModule(path.extractFilename, some(path))
  let systemModule = libsystem.loadLibrary(script, newJObject(), newJObject())
  module.load(systemModule)
  module.load(libcolors.initColors(script, systemModule))
  module.load(libarrays.initArrays(script, systemModule))
  module.load(libcss.initCssTypes(script, systemModule))
  script.stdpos = script.procs.high
  var gen = initCodeGen(script, module, mainChunk)
  gen.genScript(program, none(string))
  let tCodegen = (getMonoTime() - t).inMilliseconds.float

  t = getMonoTime()
  let virtualMachine = newVirtualMachine(VMPreferences())
  let css = virtualMachine.interpret(script, mainChunk).stringVal[]
  let tVm = (getMonoTime() - t).inMilliseconds.float

  result = (css, tParse, tCodegen, tVm)

suite "benchmark (compile speed)":
  let stylesheetPath = currentSourcePath().parentDir / "stylesheets"
  test "parse+codegen+vm throughput":
    let code = generate(500)
    let (css, tParse, tCodegen, tVm) = runCompile(code, stylesheetPath / "bench.bass")
    # sanity: output must be non-trivial and contain expected selectors
    check css.len > 100_000
    check css.contains(".component-499")
    check css.contains(".p-499")
    check css.contains("@media (min-width: ")
    check css.contains("@keyframes slide-")
    let total = tParse + tCodegen + tVm
    echo ""
    echo "  input  : ", formatSize(code.len)
    echo "  output : ", formatSize(css.len)
    echo "  parse  : ", tParse, " ms"
    echo "  codegen: ", tCodegen, " ms"
    echo "  vm     : ", tVm, " ms"
    echo "  total  : ", total, " ms"
    # loose upper bound to catch catastrophic regressions only
    check total < 30_000.0
