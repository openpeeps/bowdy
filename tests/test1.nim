import unittest
import std/[strutils, options, os, memfiles]
import pkg/openparser/json

import ../src/bowdy/engine/vancodegen
import ../src/bowdy/engine/lexer
import ../src/bowdy/engine/parser

import pkg/vancode/interpreter/ast

suite "lexer tests":
  test "tokenize css class selector":
    var lex = newLexer(".my-class { color: red; }")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens.len == 8
    assert tokens[0].kind == tkDot
    assert tokens[1].kind == tkIdentifier
    assert tokens[1].value == "my-class"
    assert tokens[2].kind == tkLBrace
    assert tokens[3].kind == tkIdentifier
    assert tokens[3].value == "color"
    assert tokens[4].kind == tkColon
    assert tokens[5].kind == tkIdentifier
    assert tokens[5].value == "red"
    assert tokens[6].kind == tkSemicolon
    assert tokens[7].kind == tkRBrace

  test "tokenize id selector":
    var lex = newLexer("#header { width: 100%; }")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkHash
    assert tokens[1].kind == tkIdentifier
    assert tokens[1].value == "header"

  test "tokenize variable declaration":
    var lex = newLexer("var x = 10")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkKeywordVar
    assert tokens[1].kind == tkIdentifier
    assert tokens[1].value == "x"
    assert tokens[2].kind == tkAssign
    assert tokens[3].kind == tkInt
    assert tokens[3].value == "10"

  test "tokenize from memfile matches string backend":
    let path = currentSourcePath().parentDir / "stylesheets" / "import_main.bass"
    var mf = memfiles.open(path, fmRead)
    defer: mf.close()
    var mlex = newLexer(mf.mem, mf.size)
    var slex = newLexer(readFile(path))
    while true:
      let a = mlex.getToken()
      let b = slex.getToken()
      assert a.kind == b.kind
      assert a.value == b.value
      assert a.line == b.line
      assert a.col == b.col
      assert a.pos == b.pos
      if a.kind == tkEOF: break

  test "lexeme retrieves raw source slice":
    var lex = newLexer(".a { color: red; }")
    assert lex.lexeme(0, 2) == ".a "
    assert lex.lexeme(5, 9) == "color"

  test "tokenize if elif else":
    var lex = newLexer("if x elif y else")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens.len == 5
    assert tokens[0].kind == tkKeywordIf
    assert tokens[1].kind == tkIdentifier
    assert tokens[1].value == "x"
    assert tokens[2].kind == tkKeywordElif
    assert tokens[3].kind == tkIdentifier
    assert tokens[3].value == "y"
    assert tokens[4].kind == tkKeywordElse

  test "tokenize for loop":
    var lex = newLexer("for item in items")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkKeywordFor
    assert tokens[1].kind == tkIdentifier
    assert tokens[1].value == "item"
    assert tokens[2].kind == tkKeywordIn
    assert tokens[3].kind == tkIdentifier
    assert tokens[3].value == "items"

  test "tokenize numbers with units":
    var lex = newLexer("16px 2.5em 100%")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens.len == 4
    assert tokens[0].kind == tkUnit
    assert tokens[0].value == "16px"
    assert tokens[1].kind == tkUnit
    assert tokens[1].value == "2.5em"
    assert tokens[2].kind == tkInt
    assert tokens[2].value == "100"
    assert tokens[3].kind == tkPercent

  test "tokenize unit edge cases":
    var lex = newLexer("1x 24deg -5px .5rem 1em 1e2px 10-2 5%3")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkUnit
    assert tokens[0].value == "1x"
    assert tokens[1].kind == tkUnit
    assert tokens[1].value == "24deg"
    assert tokens[2].kind == tkUnit
    assert tokens[2].value == "-5px"
    assert tokens[3].kind == tkUnit
    assert tokens[3].value == "0.5rem"
    assert tokens[4].kind == tkUnit
    assert tokens[4].value == "1em"
    assert tokens[5].kind == tkUnit
    assert tokens[5].value == "1e2px"
    assert tokens[6].kind == tkInt
    assert tokens[6].value == "10"
    assert tokens[7].kind == tkInt
    assert tokens[7].value == "-2"
    assert tokens[8].kind == tkInt
    assert tokens[8].value == "5"
    assert tokens[9].kind == tkPercent
    assert tokens[10].kind == tkInt
    assert tokens[10].value == "3"

  test "tokenize hex with leading digit":
    var lex = newLexer("#0d6efd")
    var tok = lex.getToken()
    assert tok.kind == tkHash
    tok = lex.getToken()
    assert tok.kind == tkUnit
    assert tok.value == "0d6efd"
    assert tok.wsno == 0

  test "tokenize operators":
    var lex = newLexer("+ - * / == != < > <= >= && || and or is isnot")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkPlus
    assert tokens[1].kind == tkMinus
    assert tokens[2].kind == tkAsterisk
    assert tokens[3].kind == tkDivide
    assert tokens[4].kind == tkDoubleEqual
    assert tokens[5].kind == tkNotEqual
    assert tokens[6].kind == tkLT
    assert tokens[7].kind == tkGT
    assert tokens[8].kind == tkLTE
    assert tokens[9].kind == tkGTE
    assert tokens[10].kind == tkAndAnd
    assert tokens[11].kind == tkOrOr
    assert tokens[12].kind == tkAnd
    assert tokens[13].kind == tkOr
    assert tokens[14].kind == tkKeywordIs
    assert tokens[15].kind == tkKeywordIsnot

  test "tokenize assignment operators":
    var lex = newLexer("= += -= *= /= %=")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkAssign
    assert tokens[1].kind == tkPlusAssign
    assert tokens[2].kind == tkMinusAssign
    assert tokens[3].kind == tkAsteriskAssign
    assert tokens[4].kind == tkSlashAssign
    assert tokens[5].kind == tkPercentAssign

  test "tokenize strings":
    var lex = newLexer("\"hello world\" \"escaped\\nstring\"")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens.len == 2
    assert tokens[0].kind == tkString
    assert tokens[0].value == "hello world"
    assert tokens[1].kind == tkString
    assert tokens[1].value == "escaped\nstring"

  test "tokenize booleans and null":
    var lex = newLexer("true false null undefined")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkKeywordTrue
    assert tokens[0].value == ""
    assert tokens[1].kind == tkKeywordFalse
    assert tokens[1].value == ""
    assert tokens[2].kind == tkKeywordNull
    assert tokens[2].value == ""
    assert tokens[3].kind == tkKeywordUndefined
    assert tokens[3].value == ""

  test "tokenize keywords":
    var lex = newLexer("var const function return while break continue import iterator")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkKeywordVar
    assert tokens[0].value == ""
    assert tokens[1].kind == tkKeywordConst
    assert tokens[1].value == ""
    assert tokens[2].kind == tkKeywordFunction
    assert tokens[2].value == ""
    assert tokens[3].kind == tkKeywordReturn
    assert tokens[3].value == ""
    assert tokens[4].kind == tkKeywordWhile
    assert tokens[5].kind == tkKeywordBreak
    assert tokens[6].kind == tkKeywordContinue
    assert tokens[7].kind == tkKeywordImport
    assert tokens[8].kind == tkKeywordIterator

  test "tokenize hex color":
    var lex = newLexer("#ff0000 #333")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkHash
    assert tokens[1].kind == tkIdentifier
    assert tokens[1].value == "ff0000"
    assert tokens[2].kind == tkHash
    assert tokens[3].kind == tkInt
    assert tokens[3].value == "333"

  test "tokenize css custom property":
    var lex = newLexer("--my-var: 10px;")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkCssVar
    assert tokens[0].value == "--my-var"
    assert tokens[1].kind == tkColon

  test "tokenize single-line comment":
    var lex = newLexer("// this is a comment\n.hello {}")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkComment
    assert tokens[0].value == " this is a comment"
    assert tokens[1].kind == tkDot
    assert tokens[2].kind == tkIdentifier
    assert tokens[2].value == "hello"

  test "tokenize block comment":
    var lex = newLexer("/* block comment */ .foo {}")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkComment
    assert tokens[0].value == " block comment "
    assert tokens[1].kind == tkDot

  test "tokenize doc block comment":
    var lex = newLexer("/** doc block */ .foo {}")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkDocBlock
    assert tokens[1].kind == tkDot

  test "tokenize identifier with dollar and underscore":
    var lex = newLexer("$myVar _private")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkIdentifier
    assert tokens[0].value == "$myVar"
    assert tokens[1].kind == tkIdentifier
    assert tokens[1].value == "_private"

  test "tokenize backtick string":
    var lex = newLexer("`template string`")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkBacktick
    assert tokens[0].value == "template string"

  test "multiline block comment tracks lines":
    var lex = newLexer("/* line1\nline2\r\nline3 */\n.foo {}")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkComment
    assert tokens[0].value == " line1\nline2\r\nline3 "
    assert tokens[1].kind == tkDot
    assert tokens[1].line == 4
    assert tokens[1].col == 0

  test "unterminated block comment runs to EOF":
    var lex = newLexer(".a {} /* never ends")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[^1].kind == tkComment
    assert tokens[^1].value == " never ends"

  test "multiline plain string tracks lines":
    var lex = newLexer("\"a\nb\"\n.foo {}")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkString
    assert tokens[0].value == "a\nb"
    assert tokens[1].kind == tkDot
    assert tokens[1].line == 3

  test "comment with lone stars stays one token":
    var lex = newLexer("/** a * b **/ .x {}")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkDocBlock
    assert tokens[0].value == "* a * b *"
    assert tokens[1].kind == tkDot

  test "tokenize comma separated selectors":
    var lex = newLexer("h1, h2, h3 {")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkIdentifier
    assert tokens[0].value == "h1"
    assert tokens[1].kind == tkComma
    assert tokens[2].kind == tkIdentifier
    assert tokens[2].value == "h2"
    assert tokens[3].kind == tkComma
    assert tokens[4].kind == tkIdentifier
    assert tokens[4].value == "h3"
    assert tokens[5].kind == tkLBrace

  test "tokenize parentheses and brackets":
    var lex = newLexer("( ) [ ] { }")
    var tokens: seq[TokenTuple]
    var tok = lex.getToken()
    while tok.kind != tkEOF:
      tokens.add(tok)
      tok = lex.getToken()
    assert tokens[0].kind == tkLParen
    assert tokens[1].kind == tkRParen
    assert tokens[2].kind == tkLBracket
    assert tokens[3].kind == tkRBracket
    assert tokens[4].kind == tkLBrace
    assert tokens[5].kind == tkRBrace

  test "tokenize pipe as unknown":
    var lex = newLexer("|")
    var tok = lex.getToken()
    assert tok.kind == tkUnknown

  test "tokenize wsno is zero for attached tokens":
    var lex = newLexer("16px")
    var tok = lex.getToken()
    assert tok.kind == tkUnit
    assert tok.value == "16px"
    assert tok.wsno == 0
    tok = lex.getToken()
    assert tok.kind == tkEOF

  test "tokenize wsno is positive for spaced tokens":
    var lex = newLexer("16 px")
    var tok = lex.getToken()
    assert tok.kind == tkInt
    assert tok.value == "16"
    tok = lex.getToken()
    assert tok.kind == tkIdentifier
    assert tok.wsno > 0

suite "parser tests":
  test "parse basic css":
    let sample = """
  .my-class {
    color: red;
    font-size: 16px;
    background-size: cover;
  }
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test1.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkClassSelector
    assert ast.nodes[0].children[0].ident == "my-class"
    assert ast.nodes[0].children[^1].kind == nkBlock
    for x in ast.nodes[0].children[^1]:
      assert x.kind == nkColon
      if x[0].ident == "color":
        assert x[1].kind == nkColor
        assert x[1][0].stringVal == "red"
      elif x[0].ident == "font-size":
        assert x[1].kind == nkUnit
        assert x[1][0].intVal == 16
        assert x[1][1].ident == "px"
      elif x[0].ident == "background-size":
        assert x[1].ident == "cover"

  test "parse multiple selectors":
    let sample = """
  h1, btn {
    color: red;
  }
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test2.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkElementSelector

  test "parse id selector":
    let sample = """
  #header {
    width: 100;
  }
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test3.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkIdSelector
    assert ast.nodes[0].children[0].ident == "header"

  test "parse pseudo selector":
    let sample = """
  :root {
    font-size: 16px;
  }
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test4.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkPseudoSelector
    assert ast.nodes[0].children[0].ident == "root"

  test "parse variable declarations":
    let sample = """
  var x = 10
  var name = "hello"
  const PI = 3.14
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_vars.css")
    assert ast.nodes.len == 3
    assert ast.nodes[0].kind == nkVar
    assert ast.nodes[1].kind == nkVar
    assert ast.nodes[2].kind == nkConst

  test "parse typed variable":
    let sample = """
  var x: int = 42
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_typed.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkVar

  test "parse if statement":
    let sample = """
  var x = 10
  if x > 5:
    color: red
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_if.css")
    assert ast.nodes.len == 2
    assert ast.nodes[1].kind == nkIf
    assert ast.nodes[1].children.len == 2
    assert ast.nodes[1].children[1].kind == nkBlock

  test "parse if elif else":
    let sample = """
  var x = 10
  if x > 10:
    color: red
  elif x == 10:
    color: blue
  else:
    color: green
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_elif.css")
    assert ast.nodes.len == 2
    assert ast.nodes[1].kind == nkIf
    assert ast.nodes[1].children.len >= 4

  test "parse for loop with single variable":
    let sample = """
  for $item in $items:
    color: $item
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_for.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkFor
    assert ast.nodes[0].children[0].kind == nkIdent
    assert ast.nodes[0].children[0].ident == "$item"
    assert ast.nodes[0].children[1].kind == nkIdent
    assert ast.nodes[0].children[1].ident == "$items"
    assert ast.nodes[0].children[2].kind == nkBlock

  test "parse for loop with two variables":
    let sample = """
  for $index, $value in $array:
    color: $value
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_for2.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkFor
    assert ast.nodes[0].children[0].kind == nkBracket
    assert ast.nodes[0].children[0].children.len == 2

  test "parse while loop":
    let sample = """
  var x = 0
  while x < 10
    color: red
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_while.css")
    assert ast.nodes.len == 2
    assert ast.nodes[1].kind == nkWhile
    assert ast.nodes[1].children.len == 2

  test "parse function definition":
    let sample = """
  function add(a, b)
    return a + b
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_fn.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkProc
    assert ast.nodes[0].children[0].ident == "add"
    assert ast.nodes[0].children[2].kind == nkFormalParams
    assert ast.nodes[0].children[3].kind == nkBlock

  test "parse function with return type":
    let sample = """
  function add(a: int, b: int): int
    return a + b
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_fn2.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkProc

  test "parse return statement":
    let sample = """
  function foo()
    return 42
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_return.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkProc
    let blk = ast.nodes[0].children[3]
    assert blk.kind == nkBlock
    assert blk.children[0].kind == nkReturn

  test "parse break and continue":
    let sample = """
  for $x in $items:
    if $x == 0:
      break
    if $x == 1:
      continue
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_bc.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkFor

  test "parse function call":
    let sample = """
  var result = myFunc(1, 2, 3)
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_call.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkVar

  test "parse nested selectors":
    let sample = """
  .parent
    .child
      color: blue
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_nest.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkClassSelector
    assert ast.nodes[0].children[0].ident == "parent"
    let parentBlock = ast.nodes[0].children[^1]
    assert parentBlock.kind == nkBlock

  test "parse string assignment":
    let sample = """
  var greeting = "hello world"
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_str.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkVar

  test "parse arithmetic expression":
    let sample = """
  var result = 10 + 20 * 3
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_arith.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkVar

  test "parse comparison expression":
    let sample = """
  if a == b and c > d:
    color: red
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_cmp.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkIf

  test "parse boolean literals":
    let sample = """
  var enabled = true
  var disabled = false
  var nothing = null
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_bool.css")
    assert ast.nodes.len == 3

  test "parse unit values multiple in property":
    let sample = """
  .box
    margin: 10px 20px 10px 20px
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_unit.css")
    assert ast.nodes.len == 1
    let blk = ast.nodes[0].children[^1]
    assert blk.children[0].kind == nkColon
    assert blk.children[0][0].ident == "margin"
    assert blk.children[0][1].kind == nkExprList

  test "parse css property without semicolon":
    let sample = """
  .foo
    color: red
    font-size: 14px
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_nosemi.css")
    assert ast.nodes.len == 1
    let blk = ast.nodes[0].children[^1]
    assert blk.children.len == 2

  test "parse multiple css properties":
    let sample = """
  .card
    padding: 1rem
    margin: 0
    border-radius: 4px
    background-color: #fff
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_props.css")
    assert ast.nodes.len == 1
    let blk = ast.nodes[0].children[^1]
    assert blk.children.len == 4

  test "parse css custom properties":
    let sample = """
  :root
    --primary-color: #333
    --spacing: 1rem
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_custom.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkPseudoSelector

  test "parse if statement with brace block":
    let sample = """
  if true {
    color: red;
  }
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_ifbrace.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkIf

  test "parse for loop with brace block":
    let sample = """
  for $item in $items {
    color: item;
  }
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_forbrace.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkFor

  test "parse complex nested if":
    let sample = """
  var x = 5
  var y = 10
  if $x > 0:
    if $y > 5:
      color: green
    else:
      color: yellow
  else:
    color: red
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_nestedif.css")
    assert ast.nodes.len == 3
    assert ast.nodes[2].kind == nkIf
    let outerIf = ast.nodes[2]
    assert outerIf.children[0].kind == nkInfix
    assert outerIf.children[1].kind == nkBlock
    assert outerIf.children[2].kind == nkBlock
    let innerBlock = outerIf.children[1]
    assert innerBlock.children[0].kind == nkIf

  test "parse selector with pseudo-class":
    let sample = """
  .btn:hover
    color: blue
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_pseudo.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkClassSelector

  test "parse multiple class selectors comma separated":
    let sample = """
  h1, .bar, .baz {
    color: red;
  }
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_commasel.css")
    assert ast.nodes.len == 1

  test "parse exported variable":
    let sample = """
  var x* = 42
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_export.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkVar

  test "parse iterator":
    let sample = """
  iterator myIter(n: int): int
    var i = 0
    while i < n
      yield i
      inc i
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_iter.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkIterator

  test "parse string escape sequences":
    let sample = """
  var s = "tab\there"
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_esc.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkVar

  test "parse number as float":
    let sample = """
  var pi = 3.14159
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_float.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkVar

  test "parse property with hex color value":
    let sample = """
  .box
    color: #ff0000
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_hex.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkClassSelector
    let blk = ast.nodes[0].children[^1]
    assert blk.children[0].kind == nkColon

  test "parse nested if elif else all at same indent":
    let sample = """
  if $a:
    if $b:
      color: red
    elif $c:
      color: blue
    else:
      color: green
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_nested_elif.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkIf
    let outerIf = ast.nodes[0]
    assert outerIf.children[0].kind == nkIdent
    assert outerIf.children[0].ident == "$a"
    let outerBlock = outerIf.children[1]
    assert outerBlock.kind == nkBlock
    let innerIf = outerBlock.children[0]
    assert innerIf.kind == nkIf
    assert innerIf.children.len == 5
    assert innerIf.children[0].kind == nkIdent
    assert innerIf.children[0].ident == "$b"
    assert innerIf.children[2].kind == nkIdent
    assert innerIf.children[2].ident == "$c"
    assert innerIf.children[^1].kind == nkBlock

  test "parse assignment in expression":
    let sample = """
  x = 42
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_assign.css")
    assert ast.nodes.len == 1

  test "parse multiple statements mixed":
    let sample = """
  var x = 1
  var y = 2
  const z = 3
  if x > 0:
    color: red
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_mixed.css")
    assert ast.nodes.len == 4

  test "parse function call with named args":
    let sample = """
  var result = myFunc(a = 1, b = 2)
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_named.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkVar

  test "parse inline comment before selector":
    let sample = """
  // comment before
  .foo
    color: red
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_comment.css")
    assert ast.nodes.len == 1

  test "parse not operator":
    let sample = """
  if not $x:
    color: red
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_not.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkIf

  test "parse is and isnot operators":
    let sample = """
  if type($x) is int:
    color: red
  if type($x) isnot string:
    color: blue
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_is.css")
    assert ast.nodes.len == 2
    assert ast.nodes[0].kind == nkIf
    assert ast.nodes[1].kind == nkIf

  test "invalid statement is a fatal error (no silent recovery)":
    let sample = """
  .good { color: red; }
  @@invalid@@
  .also-good { color: blue; }
  """
    var ast: Ast
    expect BroParserError:
      parser.parseScript(ast, sample, "test_recovery.css")

  test "parse null literal":
    let sample = """
  var nothing = null
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_null.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkVar

  test "parse class with pseudo selector":
    let sample = """
  .btn:hover
    color: blue
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_pseudo_class.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkClassSelector

  test "parse assignment expression":
    let sample = "x = 42"
    var ast: Ast
    parser.parseScript(ast, sample, "test_assign_expr.css")
    assert ast.nodes.len == 1

  test "parse deep nested if elif else":
    let sample = """
  if $a:
    if $b:
      color: red
    elif $c:
      color: blue
    else:
      color: green
  elif $d:
    color: yellow
  else:
    color: purple
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_deep_if.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkIf
    assert ast.nodes[0].children.len == 5

  test "parse while loop with condition expression":
    let sample = """
  var x = 0
  while x < 10
    color: x
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_while_cond.css")
    assert ast.nodes.len == 2
    assert ast.nodes[1].kind == nkWhile

  test "parse for loop with indent body":
    let sample = """
  for $item in $items:
    color: $item
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_for_brace.css")
    assert ast.nodes.len == 1

  test "parse @media at-rule":
    let sample = """
  @media (max-width: 768px)
    .foo
      color: red
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_media.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkAtRule
    assert ast.nodes[0][0].ident == "media"
    assert ast.nodes[0][1].kind == nkString
    assert ast.nodes[0][2].kind == nkBlock
    assert ast.nodes[0][2].children.len == 1
    assert ast.nodes[0][2].children[0].kind == nkElementSelector

  test "parse @supports with complex condition":
    let sample = """@supports (not (-webkit-appearance: -apple-pay-button)) or (contain-intrinsic-size: 1px) { .foo { color: red; } }"""
    var ast: Ast
    parser.parseScript(ast, sample, "test_supports.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkAtRule
    assert ast.nodes[0][0].ident == "supports"
    assert ast.nodes[0][1].stringVal.len > 0
    assert ast.nodes[0][2].children.len == 1

  test "parse @font-face":
    let sample = """
  @font-face {
    font-family: "Custom";
    src: url("custom.woff2");
  }
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_fontface.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkAtRule
    assert ast.nodes[0][0].ident == "font-face"
    assert ast.nodes[0][1].stringVal.len == 0
    assert ast.nodes[0][2].children.len == 2
    assert ast.nodes[0][2].children[0].kind == nkColon
    assert ast.nodes[0][2].children[1].kind == nkColon

  test "parse @keyframes with percentages":
    let sample = """
  @keyframes slide
    0%
      opacity: 0
    100%
      opacity: 1
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_keyframes.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkAtRule
    assert ast.nodes[0][0].ident == "keyframes"
    assert ast.nodes[0][2].children.len == 2
    assert ast.nodes[0][2].children[0].kind == nkElementSelector
    assert ast.nodes[0][2].children[0][0].children[0].ident == "0%"
    assert ast.nodes[0][2].children[1][0].children[0].ident == "100%"

  test "parse @import statement":
    let sample = """@import url("style.css");"""
    var ast: Ast
    parser.parseScript(ast, sample, "test_import.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkAtRule
    assert ast.nodes[0][0].ident == "import"
    assert ast.nodes[0][1].stringVal.len > 0
    assert ast.nodes[0][2].children.len == 0

  test "parse @layer with name":
    let sample = """
  @layer base
    .btn
      color: red
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_layer.css")
    assert ast.nodes.len == 1
    assert ast.nodes[0].kind == nkAtRule
    assert ast.nodes[0][0].ident == "layer"
    assert ast.nodes[0][1].stringVal == "base"
    assert ast.nodes[0][2].children.len == 1

  test "parse nested at-rule in selector":
    let sample = """
  .parent
    @media (max-width: 768px)
      .child
        color: blue
  """
    var ast: Ast
    parser.parseScript(ast, sample, "test_nested_atrule.css")
    check ast.nodes.len == 1
    check ast.nodes[0].kind == nkClassSelector
    check ast.nodes[0][3].children.len == 1
    check ast.nodes[0][3].children[0].kind == nkAtRule
    check ast.nodes[0][3].children[0][0].ident == "media"

  test "missing closing brace raises error":
    var ast: Ast
    expect BroParserError:
      parser.parseScript(ast, ".p-0{padding:0", "test_missing_brace.css")

  test "missing closing brace in at-rule raises error":
    var ast: Ast
    expect BroParserError:
      parser.parseScript(ast, "@media (max-width: 768px) { .foo { color: red; }", "test_missing_brace.css")

  test "missing closing paren raises error":
    var ast: Ast
    expect BroParserError:
      parser.parseScript(ast, "foo(", "test_missing_paren.css")

suite "strict error handling":
  test "selector without body (dedent) raises error":
    var ast: Ast
    expect BroParserError:
      parser.parseScript(ast, ".a\n.b\n  color: red\n", "strict1.css")

  test "selector at EOF without body raises error":
    var ast: Ast
    expect BroParserError:
      parser.parseScript(ast, ".a", "strict2.css")

  test "selector followed by same-column property raises error":
    var ast: Ast
    expect BroParserError:
      parser.parseScript(ast, ".a\ncolor: red\n", "strict3.css")

  test "brace-style empty rule is still valid":
    var ast: Ast
    parser.parseScript(ast, ".empty { }\n", "strict4.css")
    check ast.nodes.len == 1

  test "garbage statement raises instead of being skipped":
    var ast: Ast
    expect BroParserError:
      parser.parseScript(ast, "$$$\n.a { color: red }\n", "strict5.css")

  test "valid document still parses after strict checks":
    var ast: Ast
    parser.parseScript(ast, ".a\n  color: red\n  &:hover\n    color: blue\n.b { margin: 0 }\n", "strict6.css")
    check ast.nodes.len == 2
