import std/[options, strutils]
import pkg/openparser/json
import ../src/bowdy/engine/vancodegen
import ../src/bowdy/engine/parser
import pkg/vancode/interpreter/[ast, codegen, chunk, sym, vm, value]

proc tryParse(label, code: string) =
  var program: Ast
  try:
    parser.parseScript(program, code, "t.bass")
    echo label, ": ", program.nodes.len, " nodes"
  except CatchableError as e:
    echo label, ": EXC ", e.msg[:60]

tryParse("lone semi", ".a {\n  ;\n}")
tryParse("prop+semi+semi", ".a {\n  color: red;;\n}")
tryParse("call+semi indent", ".a\n  btn(red);\n")
