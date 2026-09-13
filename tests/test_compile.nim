import ../src/bro/engine/vancodegen
import unittest
import std/[options, strutils, tables, os]
import pkg/openparser/json

import ../src/bro/engine/parser

import pkg/vancode/interpreter/[ast, codegen, chunk, sym, vm, value]
import pkg/vancode/interpreter/resolver

import ../src/bro/engine/stdlib/[libsystem, libarrays, libcolors, libcss]

proc loadFullStdlib(script: Script, module: Module) =
  ## Mirror the production CLI: system + colors + arrays + cssTypes.
  ## Typed CSS literals (4px, red, #fff) need the constructor procs.
  let systemModule = libsystem.loadLibrary(script, newJObject(), newJObject())
  module.load(systemModule)
  module.load(libcolors.initColors(script, systemModule))
  module.load(libarrays.initArrays(script, systemModule))
  module.load(libcss.initCssTypes(script, systemModule))

proc compile(code: string): string =
  var program: Ast
  parser.parseScript(program, code, "test.bass")
  codegen.strictCss = true # suite default mirrors `bro c --strict`
  codegen.resetCustomProps()
  codegen.collectCustomProps(program)

  let mainChunk = newChunk("test.bass")
  var script = newScript(mainChunk)
  var module = newModule("test", some("test.bass"))

  loadFullStdlib(script, module)
  script.stdpos = script.procs.high

  var gen = initCodeGen(script, module, mainChunk)
  gen.genScript(program, none(string))

  let virtualMachine = newVirtualMachine(VMPreferences())
  result = virtualMachine.interpret(script, mainChunk).stringVal[]

proc compileFile(path: string): string =
  ## Full pipeline for a real file on disk — mirrors the CLI build path,
  ## including the import parserCallback so `.bass` imports resolve.
  proc cb(astProgram: var Ast, p: string, resolver: FileResolver) =
    parser.parseScriptFile(astProgram, p)
    codegen.collectCustomProps(astProgram)

  var program: Ast
  parser.parseScriptFile(program, path)
  codegen.strictCss = true # suite default mirrors `bro c --strict`
  codegen.resetCustomProps()
  codegen.collectCustomProps(program)
  let mainChunk = newChunk(path)
  var script = newScript(mainChunk)
  var module = newModule(path.extractFilename, some(path))
  loadFullStdlib(script, module)
  script.stdpos = script.procs.high

  var gen = initCodeGen(script, module, mainChunk, manager = nil, parserCallback = cb)
  gen.genScript(program, none(string))

  let virtualMachine = newVirtualMachine(VMPreferences())
  result = virtualMachine.interpret(script, mainChunk).stringVal[]

suite "compilation tests":
  test "compile simple class selector":
    let css = compile(".foo { color: red; }")
    check css == ".foo{color:#ff0000}"

  test "compile class with multiple properties":
    let css = compile("""
  .card {
    color: blue;
    font-size: 16px;
  }
  """)
    check css == ".card{color:#0000ff;font-size:16px}"

  test "compile id selector":
    let css = compile("#header { width: 100px; }")
    check css == "#header{width:100px}"

  test "compile pseudo selector":
    let css = compile(":root { font-size: 16px; }")
    check css == ":root{font-size:16px}"

  test "compile element selector":
    let css = compile("h1 { color: red; }")
    check css == "h1{color:#ff0000}"

  test "compile multiple selectors comma separated":
    let css = compile("h1, btn { color: red; }")
    check css == "h1,btn{color:#ff0000}"

  test "compile element selector followed by rules on same line":
    let css = compile("a, btn:hover { padding-top: 10px; }.p-0 { padding: 0; }")
    check css == "a,btn:hover{padding-top:10px}.p-0{padding:0}"

  test "compile attribute selector":
    let css = compile("[data-bs-theme=dark] { color: red; }")
    check css == "[data-bs-theme=dark]{color:#ff0000}"

  test "compile attribute selector with quoted value":
    let css = compile("[data-bs-theme=\"dark\"] { color: red; }")
    check css == "[data-bs-theme=\"dark\"]{color:#ff0000}"

  test "compile attribute selector on class":
    let css = compile(".dropdown[data-bs-popper] { padding: 0; }")
    check css == ".dropdown[data-bs-popper]{padding:0}"

  test "compile attribute selector with caret operator":
    let css = compile("a[href^=\"http\"] { color: blue; }")
    check css == "a[href^=\"http\"]{color:#0000ff}"

  test "compile attribute selector with tilde operator":
    let css = compile("[data-x~=foo] { display: block; }")
    check css == "[data-x~=foo]{display:block}"

  test "compile attribute selector with dollar operator":
    let css = compile("[data-x$=\"suffix\"] { display: none; }")
    check css == "[data-x$=\"suffix\"]{display:none}"

  test "compile attribute selector with pipe operator":
    let css = compile("[data-x|=en] { width: 10px; }")
    check css == "[data-x|=en]{width:10px}"

  test "compile element with attribute and pseudo":
    let css = compile("input[type=\"checkbox\"]:checked { color: green; }")
    check css == "input[type=\"checkbox\"]:checked{color:#008000}"

  test "compile minified css without spaces":
    let css = compile("body{color:red}.foo{padding:0}")
    check css == "body{color:#ff0000}.foo{padding:0}"

  test "compile hex color starting with digit":
    let css = compile(".foo{color:#0d6efd}")
    check css == ".foo{color:#0d6efd}"

  test "compile leading-dot float":
    let css = compile(".foo{margin-top:.125rem}")
    check css == ".foo{margin-top:0.125rem}"

  test "compile descendant selector after attribute":
    let css = compile("[data-bs-theme=\"dark\"] .dropdown-menu { color: red; }")
    check css == "[data-bs-theme=\"dark\"] .dropdown-menu{color:#ff0000}"

  test "compile attribute with comma-separated selectors":
    let css = compile("a[href^=\"http\"], [data-x^=\"y\"] { color: blue; }")
    check css == "a[href^=\"http\"],[data-x^=\"y\"]{color:#0000ff}"

  test "compile adjacent sibling combinator":
    let css = compile(".btn-check:checked+.btn { color: red; }")
    check css == ".btn-check:checked+.btn{color:#ff0000}"

  test "compile child combinator":
    let css = compile(".parent>.child { color: red; }")
    check css == ".parent>.child{color:#ff0000}"

  test "compile var() css function":
    let css = compile(".btn { color: var(--bs-btn-hover-color); }")
    check css == ".btn{color:var(--bs-btn-hover-color)}"

  test "compile css variable declarations":
    let css = compile(":root { --bs-blue: #0d6efd; --bs-breakpoint-md: 768px; }")
    check css == ":root{--bs-blue:#0d6efd;--bs-breakpoint-md:768px}"

  test "compile pseudo-element":
    let css = compile(".foo::before { display: block; }")
    check css == ".foo::before{display:block}"

  test "compile important modifier":
    let css = compile(".foo { color: red !important; }")
    check css == ".foo{color:#ff0000 !important}"

  test "compile descendant element selectors":
    let css = compile("""
  ol ol,
  ul ul,
  ol ul,
  ul ol {
    margin-bottom: 0;
  }
  """)
    check css == "ol ol,ul ul,ol ul,ul ol{margin-bottom:0}"

  test "compile nested element selector in at-rule":
    let css = compile("@media (min-width: 768px) { ol li { color: blue; } }")
    check css == "@media (min-width: 768px){ol li{color:#0000ff}}"

  test "compile is() functional pseudo":
    let css = compile(".table :is(thead,tbody,tfoot)>tr>th,td { padding: .5rem; }")
    check css == ".table :is(thead,tbody,tfoot)>tr>th,td{padding:0.5rem}"

  test "compile not() functional pseudo":
    let css = compile(".visually-hidden:not(caption) { position: absolute; }")
    check css == ".visually-hidden:not(caption){position:absolute}"

  test "compile nth-child functional pseudo":
    let css = compile(".x:nth-child(2n+1) { color: red; }")
    check css == ".x:nth-child(2n+1){color:#ff0000}"

  test "compile compound class selector":
    let css = compile(".offcanvas.offcanvas-start { color: red; }")
    check css == ".offcanvas.offcanvas-start{color:#ff0000}"

  test "compile duplicate property keys (vendor fallback)":
    let css = compile("th { text-align: inherit; text-align: -webkit-match-parent; }")
    check css == "th{text-align:inherit;text-align:-webkit-match-parent}"

  test "compile negative space-separated values":
    let css = compile(".x { margin: -0.375rem -0.75rem; }")
    check css == ".x{margin:-0.375rem -0.75rem}"

  test "compile nested comma-separated values":
    let css = compile(".x { background-position: right 0.75rem center, center right 2.25rem; }")
    check css == ".x{background-position:right 0.75rem center, center right 2.25rem}"

  test "compile indent based class selector":
    let css = compile("""
  .foo
    color: red
    font-size: 14px
  """)
    check css == ".foo{color:#ff0000;font-size:14px}"

  test "compile nested selector":
    let css = compile("""
  .parent
    .child
      color: blue
  """)
    check css == ".parent .child{color:#0000ff}"

  test "compile class with pseudo selector":
    let css = compile("""
  .btn:hover
    color: blue
  """)
    check css == ".btn:hover{color:#0000ff}"

  test "compile unit values":
    let css = compile(".box { width: 100px; }")
    check css == ".box{width:100px}"

  test "compile float values":
    let css = compile(".a { size: 1.5; }")
    check css == ".a{size:1.5}"

  test "compile string value":
    let css = compile(".c { font-family: \"Arial\"; }")
    check css == ".c{font-family:\"Arial\"}"

  test "compile multiple values":
    let css = compile(".pad { margin: 10px 20px; }")
    check css == ".pad{margin:10px 20px}"

  test "compile multiple nested selectors":
    let css = compile("""
  .a
    .b
      color: red
    .c
      color: blue
  """)
    check css == ".a .b{color:#ff0000}.a .c{color:#0000ff}"

  test "compile deeply nested selectors":
    let css = compile("""
  .x
    .y
      .z
        color: red
  """)
    check css == ".x .y .z{color:#ff0000}"

  test "compile css custom property":
    let css = compile("""
  :root {
    --primary: #333;
  }
  """)
    check css == ":root{--primary:#333}"

  test "compile hex color value":
    let css = compile(".foo { color: #ff0000; }")
    check css == ".foo{color:#ff0000}"

  test "compile empty selector":
    let css = compile(".empty { }")
    check css == ".empty{}"

  test "compile multiple top-level selectors":
    let css = compile("""
  .a { color: red; }
  .b { color: blue; }
  """)
    check css == ".a{color:#ff0000}.b{color:#0000ff}"

  test "compile indent based with braces":
    let css = compile("""
  .foo {
    color: red
  }
  """)
    check css == ".foo{color:#ff0000}"

  test "compile variable declaration and usage":
    let css = compile("""
  var $primary = red
  .foo { color: $primary; }
  """)
    check css == ".foo{color:#ff0000}"

  test "compile var declaration":
    let css = compile("""
  var $size = 16px
  .foo { font-size: $size; }
  """)
    check css == ".foo{font-size:16px}"

  test "compile multiple variable usage":
    let css = compile("""
  var $a = 10
  var $b = 20
  .foo { width: $a; height: $b; }
  """)
    check css == ".foo{width:10;height:20}"

  test "bare declaration registers dollar var":
    let css = compile("""
  var $radius = 4px
  var xxx = $radius - 3px
  .foo { width: $xxx; }
  """)
    check css == ".foo{width:1px}"

  test "bare declaration of named color keeps hex conversion":
    let css = compile("""
  var accent = red
  .foo { color: $accent; }
  """)
    check css == ".foo{color:#ff0000}"

  test "bare exported declaration":
    let css = compile("""
  var accent* = blue
  .foo { color: $accent; }
  """)
    check css == ".foo{color:#0000ff}"

  test "compile variable reference in selector block":
    let css = compile("""
  var $col = blue
  .foo
    color: $col
    background: $col
  """)
    check css == ".foo{color:#0000ff;background:#0000ff}"

  test "compile arithmetic in value":
    let css = compile("""
  var $base = 10
  .foo { width: $base + 5; }
  """)
    check css == ".foo{width:15}"

  test "compile string variable":
    let css = compile("""
  var $name = "hello"
  .foo { content: $name; }
  """)
    check css == ".foo{content:hello}"

  test "compile @media query":
    let css = compile("""
  @media (max-width: 768px)
    .foo
      color: red
  """)
    check css == "@media (max-width: 768px){.foo{color:#ff0000}}"

  test "compile @supports":
    let css = compile("""
  @supports (display: grid)
    .foo { color: red; }
  """)
    check css == "@supports (display: grid){.foo{color:#ff0000}}"

  test "compile @font-face":
    let css = compile("""
  @font-face {
    font-family: "Custom";
    src: url("custom.woff2");
  }
  """)
    check css == "@font-face{font-family:\"Custom\";src:url(\"custom.woff2\")}"

  test "compile @keyframes":
    let css = compile("""
  @keyframes slide
    from
      opacity: 0
    to
      opacity: 1
  """)
    check css == "@keyframes slide{from{opacity:0}to{opacity:1}}"

  test "compile @import":
    let css = compile("@import url(\"style.css\");")
    check css == "@import url(\"style.css\");"

  test "compile @media with comma-separated selectors":
    let css = compile("""
  @media (min-width: 480px)
    .foo, .bar
      color: blue
  """)
    check css == "@media (min-width: 480px){.foo,.bar{color:#0000ff}}"

  test "compile nested @media inside selector":
    let css = compile("""
  .parent
    @media (max-width: 768px)
      .child
        color: blue
  """)
    check css == ".parent{@media (max-width: 768px){.child{color:#0000ff}}}"

  test "compile @media brace-delimited":
    let css = compile("@media (max-width: 768px) { .foo { color: red; } }")
    check css == "@media (max-width: 768px){.foo{color:#ff0000}}"

  test "compile @supports simple":
    let css = compile("@supports (display: grid) { .foo { color: red; } }")
    check css == "@supports (display: grid){.foo{color:#ff0000}}"

  test "compile @supports with not":
    let css = compile("@supports not (display: grid) { .foo { color: red; } }")
    check css == "@supports not (display: grid){.foo{color:#ff0000}}"

  test "compile @layer unnamed":
    let css = compile("""
  @layer
    .foo
      color: red
  """)
    check css == "@layer{.foo{color:#ff0000}}"

  test "compile @layer multiple named":
    let css = compile("@layer base, theme;")
    check css == "@layer base, theme;"

  test "compile @font-face with single descriptor":
    let css = compile("@font-face { font-family: \"Custom\"; }")
    check css == "@font-face{font-family:\"Custom\"}"

  test "compile @keyframes brace-delimited":
    let css = compile("@keyframes slide { from { opacity: 0; } to { opacity: 1; } }")
    check css == "@keyframes slide{from{opacity:0}to{opacity:1}}"

  test "compile @keyframes with percentage":
    let css = compile("""
  @keyframes slide
    0%
      opacity: 0
    100%
      opacity: 1
  """)
    check css == "@keyframes slide{0%{opacity:0}100%{opacity:1}}"

  test "compile @charset":
    let css = compile("@charset \"utf-8\";")
    check css == "@charset \"utf-8\";"

  test "compile @namespace":
    let css = compile("@namespace url(\"http://www.w3.org/1999/xhtml\");")
    check css == "@namespace url(\"http://www.w3.org/1999/xhtml\");"

  test "compile property after @media":
    let css = compile("""
  @media (max-width: 768px)
    .foo
      color: red
  .bar
    color: blue
  """)
    check css == "@media (max-width: 768px){.foo{color:#ff0000}}.bar{color:#0000ff}"

suite "Phase 1: universal selector":
  test "compile universal selector (brace)":
    check compile("* { margin: 0; }") == "*{margin:0}"

  test "compile universal selector (indent)":
    check compile("*\n  margin: 0") == "*{margin:0}"

  test "compile universal selector with properties":
    check compile("* { box-sizing: border-box; margin: 0; padding: 0; }") ==
      "*{box-sizing:border-box;margin:0;padding:0}"

suite "Phase 1: keyframes comma selectors":
  test "compile keyframes with comma-separated selectors (brace)":
    check compile("@keyframes slide { 0%, 100% { opacity: 1; } 50% { opacity: 0; } }") ==
      "@keyframes slide{0%,100%{opacity:1}50%{opacity:0}}"

  test "compile keyframes with comma-separated selectors (indent)":
    check compile("@keyframes slide\n  0%, 100%\n    opacity: 1\n  50%\n    opacity: 0") ==
      "@keyframes slide{0%,100%{opacity:1}50%{opacity:0}}"

  test "compile keyframes from/to":
    check compile("@keyframes fade { from { opacity: 0; } to { opacity: 1; } }") ==
      "@keyframes fade{from{opacity:0}to{opacity:1}}"

  test "compile keyframes percentage range":
    check compile("@keyframes move { 0% { left: 0; } 25%, 75% { left: 50%; } 100% { left: 100%; } }") ==
      "@keyframes move{0%{left:0}25%,75%{left:50%}100%{left:100%}}"

suite "Phase 1: opaque call-arg parsing":
  test "compile rgb with commas":
    check compile(".a { color: rgb(255, 0, 0); }") == ".a{color:rgb(255, 0, 0)}"

  test "compile rgb with spaces (modern syntax)":
    check compile(".a { color: rgb(13 110 253); }") == ".a{color:rgb(13 110 253)}"

  test "compile rgb with slash alpha (modern syntax)":
    check compile(".a { color: rgb(13 110 253 / 50%); }") == ".a{color:rgb(13 110 253 / 50%)}"

  test "compile rgba":
    check compile(".a { color: rgba(255, 0, 0, 0.5); }") == ".a{color:rgba(255, 0, 0, 0.5)}"

  test "compile linear-gradient spaces preserved":
    check compile(".a { background: linear-gradient(to right, red, blue); }") ==
      ".a{background:linear-gradient(to right, #ff0000, #0000ff)}"

  test "compile linear-gradient with angle":
    check compile(".a { background: linear-gradient(45deg, red, blue); }") ==
      ".a{background:linear-gradient(45deg, #ff0000, #0000ff)}"

  test "compile radial-gradient":
    check compile(".a { background: radial-gradient(circle at center, red, blue); }") ==
      ".a{background:radial-gradient(circle at center, #ff0000, #0000ff)}"

  test "compile url unquoted":
    check compile(".a { background: url(img.png); }") == ".a{background:url(img.png)}"

  test "compile url quoted":
    check compile(".a { background: url(\"img.png\"); }") == ".a{background:url(\"img.png\")}"

  test "compile calc":
    check compile(".a { width: calc(100% - 2rem); }") == ".a{width:calc(100% - 2rem)}"

  test "compile clamp":
    check compile(".a { width: clamp(1rem, 2.5vw, 2rem); }") ==
      ".a{width:clamp(1rem, 2.5vw, 2rem)}"

  test "compile min":
    check compile(".a { width: min(100%, 500px); }") == ".a{width:min(100%, 500px)}"

  test "compile max":
    check compile(".a { width: max(100%, 500px); }") == ".a{width:max(100%, 500px)}"

  test "compile env":
    check compile(".a { padding-top: env(safe-area-inset-top); }") ==
      ".a{padding-top:env(safe-area-inset-top)}"

  test "compile counter":
    check compile(".a::before { content: counter(x, upper-roman); }") ==
      ".a::before{content:counter(x, upper-roman)}"

  test "compile attr":
    check compile(".a::before { content: attr(data-label); }") ==
      ".a::before{content:attr(data-label)}"

  test "compile repeat/minmax":
    check compile(".a { grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); }") ==
      ".a{grid-template-columns:repeat(auto-fill, minmax(200px, 1fr))}"

  test "compile box-shadow multi-value":
    check compile(".a { box-shadow: 0 1px 2px rgba(0,0,0,.3), inset 0 0 0 1px red; }") ==
      ".a{box-shadow:0 1px 2px rgba(0,0,0,.3), inset 0 0 0 1px #ff0000}"

  test "compile var() with fallback":
    check compile(".a { color: var(--x, red); }") == ".a{color:var(--x, #ff0000)}"

  test "compile nested function calls":
    check compile(".a { background: linear-gradient(to right, rgb(255, 0, 0), rgb(0, 0, 255)); }") ==
      ".a{background:linear-gradient(to right, rgb(255, 0, 0), rgb(0, 0, 255))}"

  test "compile filter drop-shadow":
    check compile(".a { filter: drop-shadow(0 0 5px rgba(0,0,0,.5)); }") ==
      ".a{filter:drop-shadow(0 0 5px rgba(0,0,0,.5))}"

  test "compile transform functions":
    check compile(".a { transform: translate(-50%, -50%) rotate(45deg); }") ==
      ".a{transform:translate(-50%, -50%) rotate(45deg)}"

  test "compile transition shorthand":
    check compile(".a { transition: all .3s ease-in-out; }") ==
      ".a{transition:all 0.3s ease-in-out}"

suite "Phase 1: true/false/null values":
  test "compile true value":
    check compile(".a { inherits: true; }") == ".a{inherits:true}"

  test "compile false value":
    check compile(".a { inherits: false; }") == ".a{inherits:false}"

  test "compile null value":
    check compile(".a { content: null; }") == ".a{content:null}"

  test "compile true value (indent)":
    check compile(".a\n  inherits: true") == ".a{inherits:true}"

  test "compile false value (indent)":
    check compile(".a\n  inherits: false") == ".a{inherits:false}"

  test "compile multiple keyword values":
    check compile(".a { inherits: false; content: null; }") ==
      ".a{inherits:false;content:null}"

suite "Phase 1: string escape round-trip":
  test "compile unicode escape":
    check compile(".a { content: \"\\201E\"; }") == ".a{content:\"\\201E\"}"

  test "compile backslash escape":
    check compile(".a { content: \"a\\\\b\"; }") == ".a{content:\"a\\b\"}"

  test "compile escaped quote":
    check compile(".a { content: \"a\\\"b\"; }") == ".a{content:\"a\\\"b\"}"

suite "Phase 1: attribute selector flags":
  test "compile attribute with case-insensitive flag":
    check compile("[data-x=foo i] { display: block; }") ==
      "[data-x=foo i]{display:block}"

  test "compile attribute with case-insensitive flag on class":
    check compile(".a[data-x=bar s] { color: red; }") ==
      ".a[data-x=bar s]{color:#ff0000}"

  test "compile attribute flag preserves spacing":
    check compile("[type=\"text\" i] { border: 1px; }") ==
      "[type=\"text\" i]{border:1px}"

suite "Phase 1: at-rule prelude quoting":
  test "compile @charset preserves quotes":
    check compile("@charset \"utf-8\";") == "@charset \"utf-8\";"

  test "compile @import preserves url quotes":
    check compile("@import url(\"style.css\");") == "@import url(\"style.css\");"

  test "compile @namespace preserves url quotes":
    check compile("@namespace url(\"http://www.w3.org/1999/xhtml\");") ==
      "@namespace url(\"http://www.w3.org/1999/xhtml\");"

  test "compile @import unquoted":
    check compile("@import url(style.css);") == "@import url(style.css);"

suite "Phase 1: validator warn-only (no crash)":
  test "compile box-shadow multi-value (no crash)":
    let css = compile(".a { box-shadow: 0 1px 2px rgba(0,0,0,.3), inset 0 0 0 1px red; }")
    check css.len > 0
    check "box-shadow" in css

  test "compile repeat/minmax (no crash)":
    let css = compile(".a { grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); }")
    check css.len > 0
    check "repeat" in css

  test "compile color-mix (no crash)":
    let css = compile(".a { background: color-mix(in oklab, red, blue); }")
    check css.len > 0

  test "compile oklch (no crash)":
    let css = compile(".a { color: oklch(0.5 0.2 120 / 40%); }")
    check css.len > 0

suite "Phase 1: mixed brace/indent syntax":
  test "compile brace rule with indent-nested rule":
    check compile(".foo {\n  .bar\n    color: red\n}") == ".foo .bar{color:#ff0000}"

  test "compile indent rule with brace-nested rule":
    check compile(".foo\n  .bar {\n    color: red\n  }") == ".foo .bar{color:#ff0000}"

  test "compile brace @media with indent selectors":
    check compile("@media (max-width: 768px) {\n  .foo\n    color: red\n}") ==
      "@media (max-width: 768px){.foo{color:#ff0000}}"

  test "compile indent @media with brace selectors":
    check compile("@media (max-width: 768px)\n  .foo { color: red; }") ==
      "@media (max-width: 768px){.foo{color:#ff0000}}"

suite "Phase 2: Sass-style nesting":
  test "simple descendant nesting (indent)":
    check compile(".parent\n  .child\n    color: blue") == ".parent .child{color:#0000ff}"

  test "simple descendant nesting (brace)":
    check compile(".parent { .child { color: blue } }") == ".parent .child{color:#0000ff}"

  test "& hover pseudo-class":
    check compile(".card\n  &:hover\n    color: red") == ".card:hover{color:#ff0000}"

  test "& compound class":
    check compile(".card\n  &.active\n    color: red") == ".card.active{color:#ff0000}"

  test "& child combinator":
    check compile(".parent\n  & > .item\n    margin: 0") == ".parent > .item{margin:0}"

  test "& adjacent sibling":
    check compile(".parent\n  & + .item\n    margin: 0") == ".parent + .item{margin:0}"

  test "& general sibling":
    check compile(".parent\n  & ~ .item\n    margin: 0") == ".parent ~ .item{margin:0}"

  test "deep descendant nesting":
    check compile(".x\n  .y\n    .z\n      color: red") == ".x .y .z{color:#ff0000}"

  test "parent with properties + nested child":
    check compile(".card\n  color: red\n  .child\n    color: blue") ==
      ".card{color:#ff0000}.card .child{color:#0000ff}"

  test "multiple nested children":
    check compile(".parent\n  .a\n    color: red\n  .b\n    color: blue") ==
      ".parent .a{color:#ff0000}.parent .b{color:#0000ff}"

  test "nested child with multiple properties":
    check compile(".parent\n  .child\n    color: red\n    font-size: 14px") ==
      ".parent .child{color:#ff0000;font-size:14px}"

  test "mixed properties and nesting":
    check compile(".card\n  padding: 1rem\n  .title\n    font-weight: bold\n  .body\n    line-height: 1.5") ==
      ".card{padding:1rem}.card .title{font-weight:bold}.card .body{line-height:1.5}"

  test "at-rule inside nested selector":
    check compile(".parent\n  @media (max-width: 768px)\n    .child\n      color: blue") ==
      ".parent{@media (max-width: 768px){.child{color:#0000ff}}}"

  test "nesting with var() reference":
    check compile("var $col = blue\n.parent\n  .child\n    color: $col") ==
      ".parent .child{color:#0000ff}"

  test "nesting preserves selector type (id)":
    check compile("#app\n  .child\n    color: red") == "#app .child{color:#ff0000}"

  test "nesting preserves selector type (pseudo)":
    check compile(":root\n  .child\n    color: red") == ":root .child{color:#ff0000}"

  test "& multiple comma-separated":
    check compile(".card\n  &:hover, &.active\n    color: red") ==
      ".card:hover, .card.active{color:#ff0000}"

  test "nesting with !important":
    check compile(".parent\n  .child\n    color: red !important") ==
      ".parent .child{color:#ff0000 !important}"

  test "comma-separated parent selectors (indent)":
    check compile(".a, .b\n  .child\n    color: red") ==
      ".a .child, .b .child{color:#ff0000}"

  test "comma-separated parent selectors (brace)":
    check compile(".a, .b {\n  .child {\n    color: red\n  }\n}") ==
      ".a .child, .b .child{color:#ff0000}"

  test "comma-separated parent with properties":
    check compile(".a, .b\n  color: red") ==
      ".a,.b{color:#ff0000}"

  test "comma-separated parent multiple nested children":
    check compile(".a, .b\n  .x\n    color: red\n  .y\n    color: blue") ==
      ".a .x, .b .x{color:#ff0000}.a .y, .b .y{color:#0000ff}"

  test "nesting with pseudo-element":
    check compile(".card\n  &::before\n    content: \"\"") ==
      ".card::before{content:\"\"}"

  test "nesting with attribute selector":
    check compile("[data-theme] {\n  .child {\n    color: red\n  }\n}") ==
      "[data-theme] .child{color:#ff0000}"

  test "nesting with float value":
    check compile(".a\n  .b\n    opacity: .5") ==
      ".a .b{opacity:0.5}"

  test "deep nesting with & at each level":
    check compile(".a\n  &:hover\n    .b\n      &.active\n        color: red") ==
      ".a:hover .b.active{color:#ff0000}"

  test "nesting with !important on child":
    check compile(".parent\n  .child\n    color: red !important\n    font-size: 14px") ==
      ".parent .child{color:#ff0000 !important;font-size:14px}"

  test "nesting with var() on child":
    check compile("var $c = red\n.parent\n  .child\n    color: $c") ==
      ".parent .child{color:#ff0000}"

  test "nesting + at-rule interleave":
    check compile(".a\n  color: red\n  @media (max-width: 768px)\n    .b\n      color: blue\n  .c\n    color: green") ==
      ".a{color:#ff0000}@media (max-width: 768px){.a .b{color:#0000ff}}.a .c{color:#008000}"

  test "nesting with selector on same line as parent":
    check compile(".a { .b { color: red } .c { color: blue } }") ==
      ".a .b{color:#ff0000}.a .c{color:#0000ff}"

  test "nesting preserves hex colors":
    check compile(".parent\n  .child\n    color: #ff0000") ==
      ".parent .child{color:#ff0000}"

  test "nesting with multiple values":
    check compile(".parent\n  .child\n    margin: 10px 20px") ==
      ".parent .child{margin:10px 20px}"

  test "nesting with empty parent (no props)":
    check compile(".wrapper\n  .content\n    padding: 1rem") ==
      ".wrapper .content{padding:1rem}"

  test "nesting id selector":
    check compile("#app\n  .sidebar\n    width: 250px") ==
      "#app .sidebar{width:250px}"

  test "nesting pseudo-class selector":
    check compile(":root\n  .child\n    color: red") ==
      ":root .child{color:#ff0000}"

  test "comma-separated children with &":
    check compile(".card\n  &:hover, &:focus\n    outline: 2px") ==
      ".card:hover, .card:focus{outline:2px}"

  test "multiple comma parents with &":
    check compile(".a, .b\n  &:hover\n    color: red") ==
      ".a:hover, .b:hover{color:#ff0000}"

suite "Phase 4: numeric edge cases":
  test "scientific notation integer":
    check compile(".a { width: 1e3; }") == ".a{width:1000}"

  test "scientific notation with unit":
    check compile(".a { width: 1e3px; }") == ".a{width:1000px}"

  test "scientific notation fractional":
    check compile(".a { letter-spacing: 1.5e-2px; }") == ".a{letter-spacing:0.015px}"

  test "scientific notation uppercase E":
    check compile(".a { z-index: 1E1; }") == ".a{z-index:10}"

  test "negative scientific notation":
    check compile(".a { margin-left: -1e2px; }") == ".a{margin-left:-100px}"

  test "scientific notation time unit":
    check compile(".a { transition-duration: 5e-1s; }") == ".a{transition-duration:0.5s}"

  test "leading plus with unit (brace)":
    check compile(".a { width: +5px; }") == ".a{width:5px}"

  test "leading plus with unit (indent)":
    check compile(".a\n  width: +5px") == ".a{width:5px}"

  test "leading plus float":
    check compile(".a { opacity: +.5; }") == ".a{opacity:0.5}"

  test "leading plus in comma list":
    check compile(".a { margin: 5px, +10px; }") == ".a{margin:5px, 10px}"

  test "leading plus plain number":
    check compile(".a { order: +2; }") == ".a{order:2}"

  test "hex color with e digit run survives":
    check compile(".a { color: #0e3f; }") == ".a{color:#0e3f}"

  test "hex color full e-run survives":
    check compile(".a { color: #1e1e1e; }") == ".a{color:#1e1e1e}"

  test "unit suffix not confused with exponent":
    check compile(".a { width: 12em; }") == ".a{width:12em}"

  test "arithmetic still uses infix plus":
    check compile("var $base = 10\n.a { width: $base + 5; }") == ".a{width:15}"

  test "integral float renders without .0":
    check compile(".a { opacity: 1.0; }") == ".a{opacity:1}"

  test "compile mixed brace/indent at-rule in selector":
    check compile(".parent {\n  @media (max-width: 768px)\n    .child\n      color: blue\n}") ==
      ".parent{@media (max-width: 768px){.child{color:#0000ff}}}"

suite "Phase 5: mixins":
  test "basic mixin with typed parameter":
    check compile("mixin btn(color: color) =\n  color: $color\n  border-radius: 4px\n.a\n  @btn(red)") ==
      ".a{color:#ff0000;border-radius:4px}"

  test "mixin without parameters":
    check compile("mixin reset() =\n  margin: 0\n  padding: 0\n.a\n  @reset()") ==
      ".a{margin:0;padding:0}"

  test "mixin with eq-form body":
    check compile("mixin pad(n: number) =\n  padding: $n\n.a\n  @pad(1rem)") ==
      ".a{padding:1rem}"

  test "mixin with brace body":
    check compile("mixin btn(color: color) {\n  color: $color\n}\n.a {\n  @btn(red)\n}") ==
      ".a{color:#ff0000}"

  test "mixin with multiple parameters":
    check compile("mixin box(w: length, h: length) =\n  width: $w\n  height: $h\n.a\n  @box(10px, 20px)") ==
      ".a{width:10px;height:20px}"

  test "mixin with variable argument":
    check compile("mixin btn(color: color) =\n  color: $color\nvar $c = blue\n.a\n  @btn($c)") ==
      ".a{color:#0000ff}"

  test "mixin named arguments (dollar form)":
    check compile("mixin box(w: length, h: length) =\n  width: $w\n  height: $h\n.a\n  @box($h = 5px, $w = 10px)") ==
      ".a{width:10px;height:5px}"

  test "mixin named arguments (bare form)":
    check compile("mixin box(w: length, h: length) =\n  width: $w\n  height: $h\n.a\n  @box(h = 5px, w = 10px)") ==
      ".a{width:10px;height:5px}"

  test "mixin called multiple times":
    check compile("mixin pad(n: number) =\n  padding: $n\n.a\n  @pad(1px)\n.b\n  @pad(2px)") ==
      ".a{padding:1px}.b{padding:2px}"

  test "mixin preserves parent property order":
    check compile("mixin m(c: color) =\n  color: $c\n.a\n  color: red\n  @m(green)\n  background: blue") ==
      ".a{color:#ff0000;color:#008000;background:#0000ff}"

  test "nested selector inside mixin (full splice)":
    check compile("mixin card =\n  .title\n    font-weight: bold\n.a\n  color: red\n  @card()") ==
      ".a{color:#ff0000}.a .title{font-weight:bold}"

  test "mixin definition emits no CSS":
    check compile("mixin unused(color: color) =\n  background: $color") == ""

  test "missing argument raises error":
    expect CatchableError:
      discard compile("mixin btn(color: color) =\n  color: $color\n.a\n  @btn()")

  test "mixin with equals before indented body":
    check compile("mixin btn(color: color) =\n  color: $color\n  border-radius: 4px\n.a\n  @btn(red)") ==
      ".a{color:#ff0000;border-radius:4px}"

  test "mixin with equals before brace body":
    check compile("mixin btn(color: color) = {\n  color: $color;\n}\n.a {\n  @btn(blue)\n}") ==
      ".a{color:#0000ff}"

  test "mixin without equals raises error":
    expect CatchableError:
      discard compile("mixin btn(color: color)\n  color: $color\n.a\n  @btn(red)")

  test "parse error carries source context":
    var msg = ""
    try:
      discard compile(".a { color: red;")
    except CatchableError as e:
      msg = e.msg
    check msg.len > 0
    check ".a { color: red;" in msg
    check "^" in msg
    check "(1:16)" in msg

  test "errorContextFor renders snippet and caret from file":
    let path = currentSourcePath().parentDir / "stylesheets" / "import_main.bass"
    let ctx = parser.errorContextFor(path, 2, 0)
    check ".a" in ctx
    check "^" in ctx

  test "mixin body resolves outer length var":
    check compile("var $radius = 4px\nmixin btn(color: color) =\n  color: $color\n  border-radius: $radius\n.a\n  @btn(red)") ==
      ".a{color:#ff0000;border-radius:4px}"

  test "mixin arg accepts outer color var":
    check compile("var $primary = #0d6efd\nmixin btn(color: color) =\n  color: $color\n.a\n  @btn($primary)") ==
      ".a{color:#0d6efd}"

  test "mixin bro-call with named color arg":
    check compile("mixin m(c: color) =\n  color: darken($c, 10)\n.a\n  @m(red)") ==
      ".a{color:#cc0000}"

  test "mixin nested selector resolves outer var":
    check compile("var $primary = #0d6efd\nmixin card =\n  .icon\n    color: $primary\n.a\n  @card()") ==
      ".a .icon{color:#0d6efd}"

  test "mixin parent ref in indented body":
    check compile("mixin btn(color: color) =\n  color: $color\n  &:hover\n    color: blue\n.a\n  @btn(red)") ==
      ".a{color:#ff0000}.a:hover{color:#0000ff}"

  test "mixin parent ref in brace body":
    check compile("mixin btn(color: color) {\n  color: $color\n  &:hover\n    color: blue\n}\n.a {\n  @btn(red)\n}") ==
      ".a{color:#ff0000}.a:hover{color:#0000ff}"

  test "comments interleaved with loops and nesting":
    check compile("// lead\nvar $debug = true\nfor $i in range(1, 2):\n  .z-${$i}\n    z-index: $i\n// mid\n.card\n  color: #333\n  // inner\n  .title\n    font-weight: bold\n// trail") ==
      ".z-1{z-index:1}.z-2{z-index:2}.card{color:#333}.card .title{font-weight:bold}"

  test "multi-value with vars evaluates":
    check compile("var $a = 1px\nvar $b = 2px\n.a\n  margin: $a $b") ==
      ".a{margin:1px 2px}"

  test "multi-value mixing literals and vars":
    check compile("var $c = red\n.a\n  border: 1px solid $c") ==
      ".a{border:1px solid #ff0000}"

  test "multi-value comma list with vars":
    check compile("var $c = red\nvar $d = blue\n.a\n  box-shadow: 0 1px $c, inset 0 0 $d") ==
      ".a{box-shadow:0 1px #ff0000, inset 0 0 #0000ff}"

  test "multi-value with vars in mixin body":
    check compile("var $a = 1px\nvar $b = 2px\nmixin m =\n  margin: $a $b\n.a\n  @m()") ==
      ".a{margin:1px 2px}"

  test "multi-value with loop var and static":
    check compile("for $i in range(1, 3):\n  .p-${$i}\n    margin: ${$i}px auto") ==
      ".p-1{margin:1px auto}.p-2{margin:2px auto}.p-3{margin:3px auto}"

  test "static multi-value still validates strictly":
    expect CatchableError:
      discard compile(".a\n  width: 0 foo")

suite "Phase 5: control flow inside rule bodies":
  test "if true emits contained property":
    check compile(".a\n  if true:\n    color: red") == ".a{color:#ff0000}"

  test "if false skips contained property":
    check compile(".a\n  if false:\n    color: red\n  color: blue") == ".a{color:#0000ff}"

  test "if with variable condition":
    check compile("var $debug = true\n.a\n  if $debug:\n    outline: 1px") == ".a{outline:1px}"

  test "if else branches":
    check compile("var $m = false\n.a\n  if $m:\n    color: red\n  else:\n    color: blue") == ".a{color:#0000ff}"

  test "for range loop emits repeated properties":
    check compile(".a\n  for $i in range(1, 3):\n    z-index: $i") == ".a{z-index:1;z-index:2;z-index:3}"

  test "loop var with attached unit suffix":
    check compile("for $i in range(1, 3):\n  .p-${$i}\n    padding: ${$i}px") ==
      ".p-1{padding:1px}.p-2{padding:2px}.p-3{padding:3px}"

  test "loop var arithmetic with units":
    check compile("for $i in range(1, 3):\n  .p-${$i}\n    padding: $i * 1px") ==
      ".p-1{padding:1px}.p-2{padding:2px}.p-3{padding:3px}"

  test "loop var arithmetic with units reversed":
    check compile("for $i in range(1, 3):\n  .p-${$i}\n    padding: 1px * $i") ==
      ".p-1{padding:1px}.p-2{padding:2px}.p-3{padding:3px}"

  test "interpolation with attached literal unit":
    check compile(".a\n  width: ${3}px") == ".a{width:3px}"

  test "for over array of objects":
    check compile("var $s = [{k: 0, v: 0}, {k: 1, v: 0.25rem}]\nfor $item in $s:\n  .p-${$item.k}\n    padding: $item.v") == ".p-0{padding:0}.p-1{padding:0.25rem}"

  test "for over inline array of objects":
    check compile("for $s in [{k: 0, v: 0}, {k: 1, v: 1rem}]:\n  .m-${$s.k}\n    margin: $s.v") == ".m-0{margin:0}.m-1{margin:1rem}"

  test "control flow with surrounding properties":
    check compile("var $on = true\n.a\n  color: red\n  if $on:\n    top: 1px\n  background: blue") == ".a{color:#ff0000;top:1px;background:#0000ff}"

  test "property before taken if keeps separator":
    check compile("var $on = true\n.a\n  color: red\n  if $on:\n    outline: 1px") == ".a{color:#ff0000;outline:1px}"

  test "property before untaken if has no trailing semicolon":
    check compile("var $on = false\n.a\n  color: red\n  if $on:\n    outline: 1px") == ".a{color:#ff0000}"

  test "if inside nested rule stays inside the block":
    check compile("var $on = true\n.card\n  color: red\n  .title\n    font-weight: bold\n  if $on:\n    outline: 1px") ==
      ".card{color:#ff0000;outline:1px}.card .title{font-weight:bold}"

  test "while loop with counter":
    check compile("var $i = 0\n.a\n  while $i < 2\n    z-index: $i\n    $i = $i + 1") == ".a{z-index:0;z-index:1}"

  test "control flow inside mixin":
    check compile("var $v = true\nmixin m =\n  if $v:\n    color: green\n.a\n  @m()") == ".a{color:#008000}"

  test "at-rule still parses after @ in rule bodies":
    check compile(".a\n  @media (max-width: 768px)\n    color: red") ==
      ".a{@media (max-width: 768px){color:#ff0000}}"

suite "Phase 5: fn / func aliases":
  test "fn keyword evaluates in expression position":
    check compile("fn dbl($n: int): int\n  return $n * 2\nvar $p = dbl(21)\n.a { z-index: $p }") ==
      ".a{z-index:42}"

  test "func alias works identically":
    check compile("func dbl($n: int): int\n  return $n * 2\nvar $p = dbl(21)\n.a { z-index: $p }") ==
      ".a{z-index:42}"

  test "fn with equals before indented body":
    check compile("fn dbl($n: int): int =\n  return $n * 2\nvar $p = dbl(21)\n.a { z-index: $p }") ==
      ".a{z-index:42}"

  test "fn with equals before brace body":
    check compile("fn dbl($n: int): int = {\n  return $n * 2\n}\nvar $p = dbl(21)\n.a { z-index: $p }") ==
      ".a{z-index:42}"

suite "Phase 6: modules (.bass imports)":
  let fixturesDir = currentSourcePath().parentDir / "stylesheets"

  test "import resolves and splices rules + exported vars":
    let css = compileFile(fixturesDir / "import_main.bass")
    check css == ".base{color:#808080}.a{color:#0d6efd;border-radius:4px}"

  test "sourcemap segments attribute imported file correctly":
    proc compileFileVm(path: string): tuple[css: string, vm: Vm] =
      proc cb(astProgram: var Ast, p: string, resolver: FileResolver) =
        parser.parseScriptFile(astProgram, p)
        codegen.collectCustomProps(astProgram)
      var program: Ast
      parser.parseScriptFile(program, path)
      codegen.resetCustomProps()
      codegen.collectCustomProps(program)
      let mainChunk = newChunk(path)
      var script = newScript(mainChunk)
      var module = newModule(path.extractFilename, some(path))
      loadFullStdlib(script, module)
      script.stdpos = script.procs.high
      var gen = initCodeGen(script, module, mainChunk, manager = nil, parserCallback = cb)
      gen.genScript(program, none(string))
      let virtualMachine = newVirtualMachine(VMPreferences())
      result.css = virtualMachine.interpret(script, mainChunk).stringVal[]
      result.vm = virtualMachine

    let (css, machine) = compileFileVm(fixturesDir / "import_main.bass")
    check css.len > 0
    let segs = machine.globals.getOrDefault("__bro_sourcemap_segments").stringVal[]
    var files: seq[string]
    for record in segs.split('\x02'):
      if record.len == 0: continue
      let parts = record.split('\x03')
      if parts.len >= 4 and parts[3] notin files:
        files.add(parts[3])
    check (fixturesDir / "_vars.bass") in files
    check (fixturesDir / "import_main.bass") in files

  test "missing import raises":
    expect CatchableError:
      discard compileFile(fixturesDir / "nonexistent.bass")

proc compilePretty(code: string): string =
  ## compile() with --pretty semantics: VM emits newlines + indentation.
  var program: Ast
  parser.parseScript(program, code, "test.bass")
  codegen.strictCss = true # suite default mirrors `bro c --strict`
  codegen.resetCustomProps()
  codegen.collectCustomProps(program)
  let mainChunk = newChunk("test.bass")
  var script = newScript(mainChunk)
  var module = newModule("test", some("test.bass"))
  loadFullStdlib(script, module)
  script.stdpos = script.procs.high
  var gen = initCodeGen(script, module, mainChunk)
  gen.genScript(program, none(string))
  let virtualMachine = newVirtualMachine(VMPreferences())
  virtualMachine.globals["__bro_pretty"] = initValue(true)
  result = virtualMachine.interpret(script, mainChunk).stringVal[]

suite "Phase 6: pretty output":
  test "single rule with one property":
    check compilePretty(".a { color: red; }") == ".a{\n  color:#ff0000\n}\n"

  test "multiple properties on separate lines":
    check compilePretty(".a { color: red; padding: 0; }") ==
      ".a{\n  color:#ff0000;\n  padding:0\n}\n"

  test "sibling rules separated by newline":
    check compilePretty(".a { color: red; }\n.b { color: blue; }") ==
      ".a{\n  color:#ff0000\n}\n.b{\n  color:#0000ff\n}\n"

  test "empty rule collapses to brace pair lines":
    check compilePretty(".a {}") == ".a{\n}\n"

  test "nested rules indent via raw path":
    check compilePretty(".parent\n  color: red\n  .child\n    color: blue") ==
      ".parent{\n  color:#ff0000\n}\n.parent .child{\n  color:#0000ff\n}\n"

  test "at-rule nesting indents inner rule":
    check compilePretty("@media (max-width: 768px) {\n  .a { color: red; }\n}") ==
      "@media (max-width: 768px){\n  .a{\n    color:#ff0000\n  }\n}\n"

  test "duplicate properties stay on separate lines (raw path)":
    check compilePretty("th { text-align: inherit; text-align: -webkit-match-parent; }") ==
      "th{\n  text-align:inherit;\n  text-align:-webkit-match-parent\n}\n"

  test "statement at-rule gets its own line":
    check compilePretty("@charset \"utf-8\";") == "@charset \"utf-8\";\n"

  test "keyframes indent their steps":
    check compilePretty("@keyframes slide { from { opacity: 0; } to { opacity: 1; } }") ==
      "@keyframes slide{\n  from{\n    opacity:0\n  }\n  to{\n    opacity:1\n  }\n}\n"

suite "Phase 6: doc-block preservation":
  test "bang banner preserved before rule (minified)":
    check compile("/*! bro v1 */\n.a { color: red }") == "/*! bro v1 */\n.a{color:#ff0000}"

  test "double-star docblock preserved with original flavor":
    check compile("/** section note */\n.b { color: blue }") == "/** section note */\n.b{color:#0000ff}"

  test "plain block comment still stripped":
    check compile("/* gone */\n.c { color: green }") == ".c{color:#008000}"

  test "banner inside rule body precedes the rule":
    check compile(".a\n  /*! inner */\n  color: red") == "/*! inner */\n.a{color:#ff0000}"

  test "multiple banners keep source order":
    check compile("/*! first */\n/** second */\n.d { margin: 0 }") ==
      "/*! first */\n/** second */\n.d{margin:0}"

  test "banner between rules":
    check compile(".e { color: red }\n/*! mid */\n.f { color: blue }") ==
      ".e{color:#ff0000}/*! mid */\n.f{color:#0000ff}"

  test "pretty mode keeps banner on its own line":
    check compilePretty("/*! b */\n.a { color: red }") == "/*! b */\n.a{\n  color:#ff0000\n}\n"

  test "pretty mode banner inside nested rule body":
    check compilePretty(".p\n  color: red\n  .c\n    color: blue") ==
      ".p{\n  color:#ff0000\n}\n.p .c{\n  color:#0000ff\n}\n"

suite "Phase 6: typed var() references":
  test "size custom prop in color position errors":
    expect CatchableError:
      discard compile(":root\n  --fs-medium: 1rem\n.card\n  color: var(--fs-medium)")

  test "color custom prop in color position passes":
    check compile(":root\n  --brand: red\n.card\n  color: var(--brand)") ==
      ":root{--brand:red}.card{color:var(--brand)}"

  test "undeclared var warns but compiles":
    var warned: seq[string] = @[]
    let prevHandler = codegen.warnHandler
    codegen.warnHandler = proc(msg: string) {.gcsafe.} =
      {.cast(gcsafe).}: # single-threaded suite: safe to record locally
        warned.add(msg)
    try:
      check compile(".card\n  color: var(--missing)") ==
        ".card{color:var(--missing)}"
    finally:
      codegen.warnHandler = prevHandler
    check warned.len == 1
    check "var(--missing) is not declared" in warned[0]

  test "unknown var with matching fallback compiles":
    check compile(".a\n  color: var(--missing, red)") ==
      ".a{color:var(--missing, #ff0000)}"

  test "unknown var with mismatching fallback errors":
    expect CatchableError:
      discard compile(".a\n  color: var(--missing, 2px)")

  test "declared mismatch errors even with matching fallback":
    expect CatchableError:
      discard compile(":root\n  --size: 2px\n.a\n  color: var(--size, red)")

  test "color custom prop in length position errors":
    expect CatchableError:
      discard compile(":root\n  --brand: red\n.w\n  width: var(--brand)")

  test "compound value with mistyped var errors":
    # A time inhabits no border slot, so it errors. (A length would pass:
    # border accepts lengths via <line-width>; kinds checking is blind to
    # which shorthand slot a var lands in.)
    expect CatchableError:
      discard compile(":root\n  --bad: 2s\n.b\n  border: 1px solid var(--bad)")

  test "chained var alias resolves":
    expect CatchableError:
      discard compile(":root\n  --a: 1px\n  --b: var(--a)\n.c\n  color: var(--b)")

  test "bro var alias resolves":
    check compile("var $c = red\n:root\n  --a: $c\n.b\n  color: var(--a)") ==
      ":root{--a:#ff0000}.b{color:var(--a)}"

  test "bro call declaration infers color":
    check compile(":root\n  --d: darken(red, 10)\n.c\n  color: var(--d)") ==
      ":root{--d:#cc0000}.c{color:var(--d)}"

  test "keyword declaration stays unchecked":
    check compile(":root\n  --t: transparent\n.a\n  color: var(--t)") ==
      ":root{--t:transparent}.a{color:var(--t)}"

  test "bare number declaration coerces to length":
    check compile(":root\n  --n: 2\n.w\n  width: var(--n)") ==
      ":root{--n:2}.w{width:var(--n)}"

  test "use before declaration registers":
    check compile(".a\n  color: var(--later)\n:root\n  --later: red") ==
      ".a{color:var(--later)}:root{--later:red}"

  test "nested fallback var is checked":
    expect CatchableError:
      discard compile(":root\n  --sz: 2px\n.a\n  color: var(--x, var(--sz))")

  test "env() is untouched":
    check compile(".e\n  padding-top: env(safe-area-inset-top)") ==
      ".e{padding-top:env(safe-area-inset-top)}"

  test "keyword-named custom props stay atomic":
    check compile(":root\n  --color-gray-100: #f8f9fa\n.c\n  background: var(--color-gray-100)") ==
      ":root{--color-gray-100:#f8f9fa}.c{background:var(--color-gray-100)}"

  test "keyword-only custom prop name stays verbatim":
    check compile(":root\n  --red: red\n.c\n  color: var(--red)") ==
      ":root{--red:red}.c{color:var(--red)}"

  test "hyphenated custom prop in length position":
    check compile(":root\n  --red-500: 2px\n.w\n  width: var(--red-500)") ==
      ":root{--red-500:2px}.w{width:var(--red-500)}"

  test "keyword-named prop in compound value":
    check compile(":root\n  --brand-gray: #333\n.b\n  border: 1px solid var(--brand-gray)") ==
      ":root{--brand-gray:#333}.b{border:1px solid var(--brand-gray)}"

  test "var name from $var renders":
    check compile("var $n = \"--brand\"\n:root\n  --brand: red\n.c\n  color: var($n)") ==
      ":root{--brand:red}.c{color:var(--brand)}"

  test "empty var() is a parse error":
    expect CatchableError:
      discard compile(".a\n  color: var()")

  test "fallback message names the var":
    var msg = ""
    try:
      discard compile(".a\n  color: var(--nope, 2px)")
    except CatchableError as e:
      msg = e.msg
    check "var(--nope)" in msg
    check "fallback" in msg

  test "loop var as var() fallback":
    check compile("for $i in range(1, 2):\n  .z-${$i}\n    z-index: var(--z, $i)") ==
      ".z-1{z-index:var(--z, 1)}.z-2{z-index:var(--z, 2)}"

  test "keyword fallback stays verbatim":
    check compile(".a\n  color: var(--x, none)") ==
      ".a{color:var(--x, none)}"

  test "opaque call fallback stays verbatim":
    check compile(".a\n  transform: var(--x, translate3d(0.25em, 0, 0))") ==
      ".a{transform:var(--x, translate3d(0.25em,0,0))}"

  test "keywords in dynamic compound stay verbatim":
    check compile(".a\n  background: transparent var(--x) center/1em auto no-repeat") ==
      ".a{background:transparent var(--x) center / 1em auto no-repeat}"

  test "glued units compile":
    check compile(".a\n  color: #0d6efd\n  width: 10px\n  margin: -0.25em 1e2px .5rem") ==
      ".a{color:#0d6efd;width:10px;margin:-0.25em 100px 0.5rem}"

  test "spaced number and keyword stay separate":
    check compile(".a\n  margin: 1px auto") ==
      ".a{margin:1px auto}"

  test "resolution suffix compiles":
    check compile(".a\n  background-image: image-set(\"a.png\" 1x, \"b.png\" 2x)") ==
      ".a{background-image:image-set(\"a.png\" 1x, \"b.png\" 2x)}"

  test "dynamic triplet with alpha stays verbatim":
    check compile(":root\n  --t: 13, 110, 253\n.a\n  color: rgba(var(--t), 0.5)") ==
      ":root{--t:13, 110, 253}.a{color:rgba(var(--t), 0.5)}"

  test "dynamic triplet alone stays verbatim":
    check compile(":root\n  --t: 13, 110, 253\n.a\n  border-color: rgb(var(--t))") ==
      ":root{--t:13, 110, 253}.a{border-color:rgb(var(--t))}"

  test "dynamic alpha in 4-arg form stays verbatim":
    check compile(".a\n  outline-color: rgba(13, 110, 253, var(--a))") ==
      ".a{outline-color:rgba(13, 110, 253, var(--a))}"

  test "dynamic channel in 3-arg form stays verbatim":
    check compile(".a\n  background: rgb(var(--r), 0, 0)") ==
      ".a{background:rgb(var(--r), 0, 0)}"

  test "static 2-arg color call still errors":
    expect CatchableError:
      discard compile(".a\n  color: rgba(red, 0.5)")

  test "many-stop gradient compiles":
    check compile(".a\n  background-image: linear-gradient(45deg, rgba(255, 255, 255, 0.15) 25%, transparent 25%, transparent 50%, rgba(255, 255, 255, 0.15) 50%, rgba(255, 255, 255, 0.15) 75%, transparent 75%, transparent)") ==
      ".a{background-image:linear-gradient(45deg, rgba(255, 255, 255, 0.15) 25%, transparent 25%, transparent 50%, rgba(255, 255, 255, 0.15) 50%, rgba(255, 255, 255, 0.15) 75%, transparent 75%, transparent)}"

proc compileLenient(code: string): tuple[css: string, warned: seq[string]] =
  ## compile() with the default `bro c` semantics: no static CSS type
  ## system, VM/JIT types only, silent on unknown custom properties.
  var program: Ast
  parser.parseScript(program, code, "test.bass")
  codegen.strictCss = false
  codegen.resetCustomProps()
  let prevHandler = codegen.warnHandler
  var warned: seq[string] = @[]
  codegen.warnHandler = proc(msg: string) {.gcsafe.} =
    {.cast(gcsafe).}:
      warned.add(msg)
  try:
    let mainChunk = newChunk("test.bass")
    var script = newScript(mainChunk)
    var module = newModule("test", some("test.bass"))
    loadFullStdlib(script, module)
    script.stdpos = script.procs.high
    var gen = initCodeGen(script, module, mainChunk)
    gen.genScript(program, none(string))
    let virtualMachine = newVirtualMachine(VMPreferences())
    result = (virtualMachine.interpret(script, mainChunk).stringVal[], warned)
  finally:
    codegen.warnHandler = prevHandler

suite "lenient mode (default bro c, no --strict)":
  test "$var type mismatch compiles":
    let (css, warned) = compileLenient("var $c = red\n.a\n  width: $c")
    check css == ".a{width:#ff0000}"
    check warned.len == 0

  test "var() declared-type mismatch compiles":
    let (css, warned) = compileLenient(":root\n  --s: 1rem\n.a\n  color: var(--s)")
    check css == ":root{--s:1rem}.a{color:var(--s)}"
    check warned.len == 0

  test "invalid color compiles":
    let (css, warned) = compileLenient(".a\n  color: #zzzzzz")
    check css == ".a{color:#zzzzzz}"
    check warned.len == 0

  test "unknown var is silent":
    let (css, warned) = compileLenient(".a\n  color: var(--nope)")
    check css == ".a{color:var(--nope)}"
    check warned.len == 0

  test "output parity with strict mode":
    check compileLenient(":root\n  --brand: red\n.c\n  color: var(--brand)")[0] ==
      compile(":root\n  --brand: red\n.c\n  color: var(--brand)")

  test "VM types still enforced":
    expect CatchableError:
      discard compileLenient(".a\n  color: lighten(1px, 10)")[0]

  test "bootstrap triplet pattern compiles":
    let (css, warned) = compileLenient(".a\n  color: rgba(var(--t), var(--a, 1))")
    check css == ".a{color:rgba(var(--t), var(--a, 1))}"
    check warned.len == 0
