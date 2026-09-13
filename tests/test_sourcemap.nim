import unittest
import std/[options, strutils, tables]

import ../src/bowdy/engine/vancodegen
import ../src/bowdy/engine/parser
import ../src/bowdy/engine/sourcemap

import pkg/vancode/interpreter/[ast, codegen, chunk, sym, vm, value]
import pkg/openparser/json

import ../src/bowdy/engine/stdlib/[libsystem, libarrays, libcolors, libcss]

proc decodeVlq(mappings: string): seq[seq[tuple[genCol, src, line, col: int]]] =
  ## Minimal base64-VLQ decoder for verifying test output.
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  var cur = [0, 0, 0, 0]
  for line in mappings.split(';'):
    var segs: seq[tuple[genCol, src, line, col: int]]
    for tok in line.split(','):
      if tok.len == 0: continue
      var
        vals: seq[int]
        shift = 0
        val = 0
      for ch in tok:
        let d = alphabet.find(ch)
        let cont = (d and 32) != 0
        val = val or ((d and 31) shl shift)
        shift += 5
        if not cont:
          var num = val shr 1
          if (val and 1) != 0: num = -num
          vals.add(num)
          shift = 0
          val = 0
      for i, v in vals:
        cur[i] += v
      segs.add((cur[0], cur[1], cur[2], cur[3]))
    result.add(segs)

suite "source map":
  test "VLQ encode round-trips known deltas":
    # [0,0,1,0] should encode to "AACA"
    check encode(@[0, 0, 1, 0]) == "AACA"
    check encode(@[1, 0, 1, 0]) == "CACA"
    check encode(@[0, 0, 0, 0]) == "AAAA"
    check encode(@[-1, 0, 0, 0]) == "DAAA"

  test "toSourceMap produces single-line mappings":
    var info = initSourceInfo()
    info.addSegment(0, 0, "a.bass", 1, 0)
    info.addSegment(0, 5, "a.bass", 2, 2)
    let sm = info.toSourceMap("out.css")
    check sm.version == 3
    check sm.file == "out.css"
    check sm.sources == @["a.bass"]
    check sm.mappings.len > 0

  test "compile produces per-selector and per-property source mappings":
    var program: Ast
    parser.parseScript(program, """
.btn {
  color: red;
  padding: 10px 20px;
}
.card
  border: 1px solid #ccc
  font-size: 16px
""", "test.bass")

    let mainChunk = newChunk("test.bass")
    var script = newScript(mainChunk)
    var module = newModule("test", some("test.bass"))
    let systemModule = libsystem.loadLibrary(script, newJObject(), newJObject())
    module.load(systemModule)
    module.load(libcolors.initColors(script, systemModule))
    module.load(libarrays.initArrays(script, systemModule))
    module.load(libcss.initCssTypes(script, systemModule))
    script.stdpos = script.procs.high

    var gen = initCodeGen(script, module, mainChunk)
    gen.genScript(program, none(string))

    let virtualMachine = newVirtualMachine(VMPreferences())
    let css = virtualMachine.interpret(script, mainChunk).stringVal[]
    check css == ".btn{color:#ff0000;padding:10px 20px}.card{border:1px solid #ccc;font-size:16px}"

    # Rebuild the source info from the VM's accumulated segments
    var info = initSourceInfo()
    check virtualMachine.globals.hasKey("__bro_sourcemap_segments")
    let segs = virtualMachine.globals["__bro_sourcemap_segments"].stringVal[]
    check segs.len > 0
    var count = 0
    for record in segs.split('\x02'):
      if record.len == 0: continue
      let parts = record.split('\x03')
      check parts.len >= 4
      let genCol = parseInt(parts[0])
      let line = parseInt(parts[1]) - 1
      let col = parseInt(parts[2])
      check parts[3] == "test.bass"
      info.addSegment(0, genCol, parts[3], line, col)
      inc count

    let sm = info.toSourceMap("test.css")
    # 6 segments: .btn + 2 props, .card + 2 props
    check count == 6
    check sm.sources == @["test.bass"]
    check sm.mappings.split(',').len >= 6
