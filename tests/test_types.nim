import unittest
import std/[options, strutils, os]
import pkg/openparser/json

import ../src/bowdy/engine/vancodegen
import ../src/bowdy/engine/parser

import pkg/vancode/interpreter/[ast, codegen, chunk, sym, vm, value]

import ../src/bowdy/engine/stdlib/[libsystem, libarrays, libcolors, libcss]

proc compileExpectSuccess(code: string): string =
  ## Fresh script + full stdlib per test (mirrors production). A cached
  ## Script reused across mainChunk swaps cannot resolve cross-module calls.
  var program: Ast
  parser.parseScript(program, code, "test.bass")
  codegen.strictCss = true # suite default mirrors `bowdy c --strict`
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
  result = virtualMachine.interpret(script, mainChunk).stringVal[]

proc compileExpectError(code: string): string =
  try:
    discard compileExpectSuccess(code)
    ""
  except CatchableError as e:
    e.msg

suite "CSS type system — valid values":
  test "color: named color":
    let css = compileExpectSuccess(".a { color: red; }")
    check css == ".a{color:#ff0000}"

  test "color: hex value":
    let css = compileExpectSuccess(".a { color: #ff0000; }")
    check css == ".a{color:#ff0000}"

  test "color: rgb function":
    let css = compileExpectSuccess(".a { color: rgb(255, 0, 0); }")
    check css == ".a{color:rgb(255, 0, 0)}"

  test "color: CSS-wide keyword":
    let css = compileExpectSuccess(".a { color: inherit; }")
    check css == ".a{color:inherit}"

  test "width: px value":
    let css = compileExpectSuccess(".a { width: 100px; }")
    check css == ".a{width:100px}"

  test "width: em value":
    let css = compileExpectSuccess(".a { width: 2em; }")
    check css == ".a{width:2em}"

  test "width: percentage":
    let css = compileExpectSuccess(".a { width: 50%; }")
    check css == ".a{width:50%}"

  test "width: calc()":
    let css = compileExpectSuccess(".a { width: calc(100% - 20px); }")
    check css == ".a{width:calc(100% - 20px)}"

  test "width: auto keyword":
    let css = compileExpectSuccess(".a { width: auto; }")
    check css == ".a{width:auto}"

  test "font-size: px":
    let css = compileExpectSuccess(".a { font-size: 16px; }")
    check css == ".a{font-size:16px}"

  test "font-size: rem":
    let css = compileExpectSuccess(".a { font-size: 1.5rem; }")
    check css == ".a{font-size:1.5rem}"

  test "margin: shorthand":
    let css = compileExpectSuccess(".a { margin: 10px; }")
    check css == ".a{margin:10px}"

  test "margin: multi-value":
    let css = compileExpectSuccess(".a { margin: 10px 20px; }")
    check css == ".a{margin:10px 20px}"

  test "margin: four values":
    let css = compileExpectSuccess(".a { margin: 1px 2px 3px 4px; }")
    check css == ".a{margin:1px 2px 3px 4px}"

  test "padding: shorthand":
    let css = compileExpectSuccess(".a { padding: 1rem; }")
    check css == ".a{padding:1rem}"

  test "display: keyword":
    let css = compileExpectSuccess(".a { display: flex; }")
    check css == ".a{display:flex}"

  test "display: block":
    let css = compileExpectSuccess(".a { display: block; }")
    check css == ".a{display:block}"

  test "display: none":
    let css = compileExpectSuccess(".a { display: none; }")
    check css == ".a{display:none}"

  test "background-color: named":
    let css = compileExpectSuccess(".a { background-color: blue; }")
    check css == ".a{background-color:#0000ff}"

  test "background-color: transparent":
    let css = compileExpectSuccess(".a { background-color: transparent; }")
    check css == ".a{background-color:transparent}"

  test "font-family: string":
    let css = compileExpectSuccess(".a { font-family: \"Arial\"; }")
    check css == ".a{font-family:\"Arial\"}"

  test "font-family: sans-serif keyword":
    let css = compileExpectSuccess(".a { font-family: sans-serif; }")
    check css == ".a{font-family:sans-serif}"

  test "border: none":
    let css = compileExpectSuccess(".a { border: none; }")
    check css == ".a{border:none}"

  test "opacity: number":
    let css = compileExpectSuccess(".a { opacity: 0.5; }")
    check css == ".a{opacity:0.5}"

  test "opacity: integer":
    let css = compileExpectSuccess(".a { opacity: 1; }")
    check css == ".a{opacity:1}"

  test "z-index: integer":
    let css = compileExpectSuccess(".a { z-index: 10; }")
    check css == ".a{z-index:10}"

  test "line-height: unitless":
    let css = compileExpectSuccess(".a { line-height: 1.5; }")
    check css == ".a{line-height:1.5}"

  test "overflow: keyword":
    let css = compileExpectSuccess(".a { overflow: hidden; }")
    check css == ".a{overflow:hidden}"

  test "text-align: keyword":
    let css = compileExpectSuccess(".a { text-align: center; }")
    check css == ".a{text-align:center}"

  test "font-weight: keyword":
    let css = compileExpectSuccess(".a { font-weight: bold; }")
    check css == ".a{font-weight:bold}"

  test "font-weight: numeric":
    let css = compileExpectSuccess(".a { font-weight: 700; }")
    check css == ".a{font-weight:700}"

  test "cursor: keyword":
    let css = compileExpectSuccess(".a { cursor: pointer; }")
    check css == ".a{cursor:pointer}"

  test "position: keyword":
    let css = compileExpectSuccess(".a { position: absolute; }")
    check css == ".a{position:absolute}"

  test "top: length":
    let css = compileExpectSuccess(".a { top: 10px; }")
    check css == ".a{top:10px}"

  test "top: percentage":
    let css = compileExpectSuccess(".a { top: 50%; }")
    check css == ".a{top:50%}"

  test "visibility: keyword":
    let css = compileExpectSuccess(".a { visibility: hidden; }")
    check css == ".a{visibility:hidden}"

  test "flex-direction: keyword":
    let css = compileExpectSuccess(".a { flex-direction: row; }")
    check css == ".a{flex-direction:row}"

  test "justify-content: keyword":
    let css = compileExpectSuccess(".a { justify-content: center; }")
    check css == ".a{justify-content:center}"

  test "align-items: keyword":
    let css = compileExpectSuccess(".a { align-items: stretch; }")
    check css == ".a{align-items:stretch}"

  test "box-shadow: none":
    let css = compileExpectSuccess(".a { box-shadow: none; }")
    check css == ".a{box-shadow:none}"

  test "border-radius: px":
    let css = compileExpectSuccess(".a { border-radius: 4px; }")
    check css == ".a{border-radius:4px}"

  test "letter-spacing: normal":
    let css = compileExpectSuccess(".a { letter-spacing: normal; }")
    check css == ".a{letter-spacing:normal}"

  test "word-spacing: normal":
    let css = compileExpectSuccess(".a { word-spacing: normal; }")
    check css == ".a{word-spacing:normal}"

  test "white-space: keyword":
    let css = compileExpectSuccess(".a { white-space: nowrap; }")
    check css == ".a{white-space:nowrap}"

  test "float: keyword":
    let css = compileExpectSuccess(".a { float: left; }")
    check css == ".a{float:left}"

  test "clear: keyword":
    let css = compileExpectSuccess(".a { clear: both; }")
    check css == ".a{clear:both}"

  test "list-style: none":
    let css = compileExpectSuccess(".a { list-style: none; }")
    check css == ".a{list-style:none}"

  test "text-decoration: none":
    let css = compileExpectSuccess(".a { text-decoration: none; }")
    check css == ".a{text-decoration:none}"

  test "vertical-align: keyword":
    let css = compileExpectSuccess(".a { vertical-align: middle; }")
    check css == ".a{vertical-align:middle}"

  test "min-height: px":
    let css = compileExpectSuccess(".a { min-height: 100px; }")
    check css == ".a{min-height:100px}"

  test "max-width: percentage":
    let css = compileExpectSuccess(".a { max-width: 80%; }")
    check css == ".a{max-width:80%}"

  test "animation-duration: time":
    let css = compileExpectSuccess(".a { animation-duration: 300ms; }")
    check css == ".a{animation-duration:300ms}"

  test "transition-duration: time":
    let css = compileExpectSuccess(".a { transition-duration: 0.3s; }")
    check css == ".a{transition-duration:0.3s}"

  test "grid-template-columns: none":
    let css = compileExpectSuccess(".a { grid-template-columns: none; }")
    check css == ".a{grid-template-columns:none}"

  test "gap: px":
    let css = compileExpectSuccess(".a { gap: 10px; }")
    check css == ".a{gap:10px}"

  test "object-fit: keyword":
    let css = compileExpectSuccess(".a { object-fit: cover; }")
    check css == ".a{object-fit:cover}"

  test "outline: none":
    let css = compileExpectSuccess(".a { outline: none; }")
    check css == ".a{outline:none}"

  test "transform: none":
    let css = compileExpectSuccess(".a { transform: none; }")
    check css == ".a{transform:none}"

  test "filter: none":
    let css = compileExpectSuccess(".a { filter: none; }")
    check css == ".a{filter:none}"

suite "CSS type system — invalid values":
  # Invalid CSS values are hard errors (bowdy error), not [warn].
  test "color: integer":
    let err = compileExpectError(".a { color: 123; }")
    check err.len > 0
    check "color" in err

  test "width: multiple values":
    let err = compileExpectError(".a { width: 100 200; }")
    check err.len > 0
    check "width" in err

  test "width: string":
    let err = compileExpectError(".a { width: \"foo\"; }")
    check err.len > 0
    check "width" in err

  test "display: garbage":
    let err = compileExpectError(".a { display: yesplease; }")
    check err.len > 0
    check "display" in err

  test "z-index: px value":
    let err = compileExpectError(".a { z-index: 10px; }")
    check err.len > 0
    check "z-index" in err

  test "overflow: garbage":
    let err = compileExpectError(".a { overflow: sideways; }")
    check err.len > 0
    check "overflow" in err

  test "opacity: string":
    let err = compileExpectError(".a { opacity: \"half\"; }")
    check err.len > 0
    check "opacity" in err

  test "position: px":
    let err = compileExpectError(".a { position: 10px; }")
    check err.len > 0
    check "position" in err

  test "flex-direction: garbage":
    let err = compileExpectError(".a { flex-direction: diagonal; }")
    check err.len > 0
    check "flex-direction" in err

  test "color: unknown ident is invalid":
    let err = compileExpectError(".a { color: canBeAnything; }")
    check err.len > 0
    check "color" in err

  test "color: invalid hex is invalid":
    let err = compileExpectError(".a { color: #zzzzzz; }")
    check err.len > 0
    check "color" in err

suite "CSS named colors to hex":
  test "color: black converts to hex":
    check compileExpectSuccess(".a { color: black; }") == ".a{color:#000000}"

  test "color: named converts to lowercase hex":
    check compileExpectSuccess(".a { color: red; }") == ".a{color:#ff0000}"

  test "named colors convert inside gradients":
    check compileExpectSuccess(".a { background: linear-gradient(to right, red, blue); }") ==
      ".a{background:linear-gradient(to right, #ff0000, #0000ff)}"

  test "transparent and currentcolor stay keywords":
    check compileExpectSuccess(".a { color: transparent; }") == ".a{color:transparent}"
    check compileExpectSuccess(".a { color: currentcolor; }") == ".a{color:currentcolor}"

suite "CSS type system — variable type checking":
  test "var color used in width property (type error)":
    let err = compileExpectError("""
  var primary = red
  .a { width: $primary; }
  """)
    check err.len > 0

  test "var length used in length property":
    let css = compileExpectSuccess("""
  var size = 16px
  .a { font-size: $size; }
  """)
    check css == ".a{font-size:16px}"

  test "var length used in color property (type error)":
    let err = compileExpectError("""
  var size = 16px
  .a { color: $size; }
  """)
    check err.len > 0

  test "var number used in number property":
    let css = compileExpectSuccess("""
  var n = 10
  .a { z-index: $n; }
  """)
    check css == ".a{z-index:10}"

suite "CSS type system — strict typed values":
  test "length arithmetic in var":
    let css = compileExpectSuccess("""
var radius = 4px
var xxx = $radius - 3px
.a { width: $xxx; }
""")
    check css == ".a{width:1px}"

  test "length addition":
    check compileExpectSuccess("echo 4px + 3px") == ""
    let css = compileExpectSuccess("""
var x = 4px + 3px
.a { width: $x; }
""")
    check css == ".a{width:7px}"

  test "angle arithmetic":
    let css = compileExpectSuccess("""
var a = 45deg
var b = $a + 15deg
.a { rotate: $b; }
""")
    check css == ".a{rotate:60deg}"

  test "time subtraction":
    let css = compileExpectSuccess("""
var s = 2s
var t = $s - 1s
.a { transition-duration: $t; }
""")
    check css == ".a{transition-duration:1s}"

  test "mismatched units are hard errors":
    let err = compileExpectError("""
var s = 2s
var t = $s - 500ms
.a { transition-duration: $t; }
""")
    check err.len > 0
    check "Mismatched units" in err

  test "color function in color property":
    let css = compileExpectSuccess("""
var d = #336699
.a { color: lighten($d, 10); }
""")
    check css == ".a{color:#407fbf}"

  test "named color function args":
    let css = compileExpectSuccess(".a { color: mix(red, blue); }")
    check css == ".a{color:#800080}"

  test "echo typed length":
    check compileExpectSuccess("var r = 4px\necho $r") == ""

suite "CSS type system — CSS-wide keywords":
  test "inherit on color":
    let css = compileExpectSuccess(".a { color: inherit; }")
    check css == ".a{color:inherit}"

  test "initial on display":
    let css = compileExpectSuccess(".a { display: initial; }")
    check css == ".a{display:initial}"

  test "unset on width":
    let css = compileExpectSuccess(".a { width: unset; }")
    check css == ".a{width:unset}"

  test "revert on margin":
    let css = compileExpectSuccess(".a { margin: revert; }")
    check css == ".a{margin:revert}"
