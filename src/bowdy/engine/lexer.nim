# A super fast stylesheet language for cool kids!
#
# (c) 2026 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/bowdy

import std/strutils
from pkg/openparser/private/lexutils import getContext
import ./simdscan

type
  TokenKind* = enum
    tkUnknown
    tkEOF
    tkIdentifier
    tkCssVar # css custom property, e.g. --my-var
    tkInt
    tkFloat
    tkUnit # number with glued unit suffix, e.g. `10px`, `1x`, `24deg`
    tkString
    tkSemicolon = ";"
    tkColon = ":"
    tkComma = ","
    tkDot = "."
    tkHash = "#"
    tkLParen = "("
    tkRParen = ")"
    tkLBrace = "{"
    tkRBrace = "}"
    tkLBracket = "["
    tkRBracket = "]"
    tkPlus = "+"
    tkMinus = "-"
    tkAsterisk = "*"
    tkDivide = "/"
    tkPercent = "%"
    tkEqual = "="
    tkDoubleEqual = "=="
    tkNotEqual = "!="
    tkLT = "<"
    tkLTE = "<="
    tkGT = ">"
    tkGTE = ">="
    tkAmp = "&"
    tkAndAnd = "&&"
    tkOrOr = "||"
    tkOr = "or"
    tkKeywordIs = "is"
    tkKeywordIsnot = "isnot"
    tkAnd = "and"
    tkKeywordNot = "not"
    tkBacktick = "`"
    tkAt = "@"
    tkAssign = "="
    tkPlusAssign = "+="
    tkMinusAssign = "-="
    tkAsteriskAssign = "*="
    tkSlashAssign = "/="
    tkPercentAssign = "%="
    tkBang = "!"
    tkTilde = "~"
    tkTildeAssign = "~="
    tkCaret = "^"
    tkCaretAssign = "^="
    tkPipeAssign = "|="
    tkDollarAssign = "$="
    tkKeywordVar = "var"
    tkKeywordConst = "const"
    tkKeywordFunction = "function"
    tkKeywordReturn = "return"
    tkKeywordIf = "if"
    tkKeywordElse = "else"
    tkKeywordElif = "elif"
    tkKeywordWhile = "while"
    tkKeywordFor = "for"
    tkKeywordIn = "in"
    tkKeywordOf = "of"
    tkKeywordCase = "case"
    tkKeywordBreak = "break"
    tkKeywordContinue = "continue"
    tkKeywordEcho = "echo"
    tkKeywordTrue = "true"
    tkKeywordFalse = "false"
    tkKeywordNull = "null"
    tkKeywordUndefined = "undefined"
    tkKeywordImport = "import"
    tkKeywordIterator = "iterator"
    tkKeywordMixin = "mixin"

    tkComment
    tkDocBlock
    tkDocBlockBang


  TokenTuple* = tuple
    kind: TokenKind
    value: string
    line: int
    col: int
    pos: int
    wsno: int

  Lexer* = object
    input*: string # string backend; empty when reading from `data`
    data*: ptr UncheckedArray[char] # memfile backend; nil for strings
    base*: ptr UncheckedArray[char] # backend-unified read pointer; nil iff len == 0
    len*: int # readable length in chars, either backend
    pos*, line*, col*: int
    current*: char
    strbuf*: string # For building strings


proc charAt*(lex: Lexer, idx: int): char {.inline.} =
  ## Backend-agnostic read via the unified base pointer (nil iff len == 0,
  ## so the bounds check below always fires first for empty inputs).
  if idx < 0 or idx >= lex.len: return '\0'
  lex.base[idx]

proc newLexer*(input: string): Lexer =
  result.input = input
  result.data = nil
  result.len = input.len
  if input.len > 0:
    result.base = cast[ptr UncheckedArray[char]](unsafeAddr result.input[0])
  result.pos = 0
  result.line = 1
  result.col = 0
  result.strbuf = ""
  result.current = result.charAt(0)

proc newLexer*(mem: pointer, size: int): Lexer =
  ## Lexer over memory-mapped file contents. The mapping must outlive lexing;
  ## token values are always copied out, so closing right after parsing is safe.
  result.data = cast[ptr UncheckedArray[char]](mem)
  result.base = result.data
  result.len = size
  result.pos = 0
  result.line = 1
  result.col = 0
  result.strbuf = ""
  result.current = result.charAt(0)

proc sliceText*(lex: Lexer, startPos, stopPos: int): string {.inline.} =
  ## Copy source text over `[startPos, stopPos)` via the unified base pointer.
  ## Empty or inverted ranges yield "". Callers must keep stopPos <= lex.len
  ## (token scans never advance past EOF, so this always holds).
  let n = stopPos - startPos
  if n <= 0: return ""
  result = newString(n)
  copyMem(addr result[0], unsafeAddr lex.base[startPos], n)

proc lexeme*(lex: Lexer, startPos, endPos: int): string =
  ## Retrieve raw source text between offsets (inclusive), either backend.
  ## Used where tokens are collected verbatim (raw CSS calls).
  result = lex.sliceText(startPos, min(endPos, lex.len - 1) + 1)

proc errorContext*(lex: Lexer, posOverride = -1, maxContext = 80): string =
  ## Source window around an error position (openparser json-module style):
  ## capped snippet with ellipsis plus a caret marker line.
  getContext(lex, posOverride, maxContext)

proc advance(lex: var Lexer) =
  if lex.pos < lex.len:
    if lex.current == '\n':
      inc lex.line
      lex.col = 0
    else:
      inc lex.col
    inc lex.pos
    lex.current = lex.charAt(lex.pos)

proc advanceBy(lex: var Lexer, n: int) {.inline.} =
  ## Bulk advance over a span known to hold no newlines (spaces, ident tails,
  ## digit runs). Line stays untouched; col tracks the raw advance so error
  ## positions match the per-char path exactly.
  if n <= 0: return
  lex.pos += n
  lex.col += n
  lex.current = lex.charAt(lex.pos)

proc advanceSpan(lex: var Lexer, startPos, stopPos: int) {.inline.} =
  ## Bulk advance over a span that may hold newlines (string/comment bodies).
  ## Matches per-char `advance` exactly: only `'\n'` folds the line (`'\r'`
  ## is an ordinary char here; the `'\r'`/`'\r\n'` folding lives in the
  ## `nextToken` whitespace prologue, which sees identical state after this).
  var i = startPos
  while true:
    let run = offsetUntilByte(lex.base, i, stopPos, '\n')
    lex.col += run
    i += run
    if i >= stopPos: break
    inc lex.line
    lex.col = 0
    inc i # skip '\n'
  lex.pos = stopPos
  lex.current = lex.charAt(stopPos)

proc peek*(lex: Lexer, offset = 1): char =
  lex.charAt(lex.pos + offset)

proc skipWhitespace*(lex: var Lexer) =
  while lex.current in {' ', '\t', '\r'}:
    lex.advance()

proc initToken*(lex: var Lexer, kind: static TokenKind, line, col, pos, wsno: int): TokenTuple =
  (kind, "", line, col, pos, wsno)

proc initToken*(lex: var Lexer, value: sink string, kind: TokenKind, line, col, pos, wsno: int): TokenTuple =
  (kind, value, line, col, pos, wsno)

proc initToken*(lex: var Lexer, kind: static TokenKind): TokenTuple =
  (kind, "", lex.line, lex.col, lex.pos, 0)

proc tryLexExponent(lex: var Lexer): bool =
  ## Consume a scientific-notation exponent (`e10`, `E+5`, `e-2`) when one
  ## follows the mantissa. Returns true if an exponent was consumed. The
  ## consumed text stays in place: number values are sliced from source, so
  ## no buffer building happens here.
  if lex.current notin {'e', 'E'}:
    return false
  let c1 = peek(lex, 1)
  if not (c1.isDigit() or (c1 in {'+', '-'} and peek(lex, 2).isDigit())):
    return false
  lex.advance() # consume 'e'/'E'
  if lex.current in {'+', '-'}:
    lex.advance()
  lex.advanceBy(scanDigits(lex.base, lex.pos, lex.len))
  result = true

proc tryLexUnitSuffix(lex: var Lexer): bool =
  ## Consume an adjacent unit suffix (`px`, `em`, `x`, `deg`, ...) in place.
  ## Only fires when ident chars immediately follow a number token, so spaced
  ## forms (`1 px`), operators (`10-2`), and modulo (`5%3`, `%` stays its own
  ## token) are untouched. Any suffix glues, known or not: `1x` becomes one
  ## `tkUnit` token and unknown suffixes keep the legacy string rendering.
  if not lex.current.isAlphaAscii():
    return false
  let run = scanUnitTail(lex.base, lex.pos, lex.len)
  if run == 0:
    return false
  lex.advanceBy(run)
  result = true

proc wordEq(base: ptr UncheckedArray[char], start: int, lit: string): bool {.inline.} =
  ## Allocation-free compare of source text at `start` against `lit`.
  ## Callers only invoke it with `lit.len` equal to the scanned word length,
  ## so the read stays inside `[start, start + lit.len)`.
  if lit.len == 0: return false
  equalMem(addr base[start], unsafeAddr lit[0], lit.len)

proc keywordKindAt(base: ptr UncheckedArray[char], start, len: int): TokenKind {.inline.} =
  ## Length-dispatched keyword lookup directly on source text: at most one
  ## equalMem per identifier instead of ~25 string compares, and keyword
  ## tokens never materialize a string (callers slice true identifiers only).
  ## Buckets cover every keyword arm; anything else is a plain identifier.
  case len
  of 2:
    case base[start]
    of 'f':
      if wordEq(base, start, "fn"): tkKeywordFunction else: tkIdentifier
    of 'i':
      if wordEq(base, start, "if"): tkKeywordIf
      elif wordEq(base, start, "in"): tkKeywordIn
      elif wordEq(base, start, "is"): tkKeywordIs
      else: tkIdentifier
    of 'o':
      if wordEq(base, start, "or"): tkOr
      elif wordEq(base, start, "of"): tkKeywordOf
      else: tkIdentifier
    else: tkIdentifier
  of 3:
    case base[start]
    of 'v':
      if wordEq(base, start, "var"): tkKeywordVar else: tkIdentifier
    of 'f':
      if wordEq(base, start, "for"): tkKeywordFor else: tkIdentifier
    of 'a':
      if wordEq(base, start, "and"): tkAnd else: tkIdentifier
    of 'n':
      if wordEq(base, start, "not"): tkKeywordNot else: tkIdentifier
    else: tkIdentifier
  of 4:
    case base[start]
    of 'f':
      if wordEq(base, start, "func"): tkKeywordFunction else: tkIdentifier
    of 'e':
      if wordEq(base, start, "else"): tkKeywordElse
      elif wordEq(base, start, "elif"): tkKeywordElif
      elif wordEq(base, start, "echo"): tkKeywordEcho
      else: tkIdentifier
    of 'c':
      if wordEq(base, start, "case"): tkKeywordCase else: tkIdentifier
    of 't':
      if wordEq(base, start, "true"): tkKeywordTrue else: tkIdentifier
    of 'n':
      if wordEq(base, start, "null"): tkKeywordNull else: tkIdentifier
    else: tkIdentifier
  of 5:
    case base[start]
    of 'c':
      if wordEq(base, start, "const"): tkKeywordConst else: tkIdentifier
    of 'w':
      if wordEq(base, start, "while"): tkKeywordWhile else: tkIdentifier
    of 'i':
      if wordEq(base, start, "isnot"): tkKeywordIsnot else: tkIdentifier
    of 'b':
      if wordEq(base, start, "break"): tkKeywordBreak else: tkIdentifier
    of 'f':
      if wordEq(base, start, "false"): tkKeywordFalse else: tkIdentifier
    of 'm':
      if wordEq(base, start, "mixin"): tkKeywordMixin else: tkIdentifier
    else: tkIdentifier
  of 6:
    case base[start]
    of 'r':
      if wordEq(base, start, "return"): tkKeywordReturn else: tkIdentifier
    of 'i':
      if wordEq(base, start, "import"): tkKeywordImport else: tkIdentifier
    else: tkIdentifier
  of 8:
    case base[start]
    of 'f':
      if wordEq(base, start, "function"): tkKeywordFunction else: tkIdentifier
    of 'c':
      if wordEq(base, start, "continue"): tkKeywordContinue else: tkIdentifier
    of 'i':
      if wordEq(base, start, "iterator"): tkKeywordIterator else: tkIdentifier
    else: tkIdentifier
  of 9:
    if wordEq(base, start, "undefined"): tkKeywordUndefined else: tkIdentifier
  else: tkIdentifier

proc nextToken(lex: var Lexer): TokenTuple =
  # Retrieve the next token from the input
  var wsno = 0
  while true:
    # spaces/tabs carry no line info: skip the whole run vectorized.
    let run = scanSpaces(lex.base, lex.pos, lex.len)
    wsno += run
    lex.advanceBy(run)
    if lex.current == '\n':
      lex.advance()
      wsno = 0
      continue
    elif lex.current == '\r':
      lex.advance()
      if lex.current == '\n':
        lex.advance()
      else:
        inc lex.line
      lex.col = 0
      wsno = 0
      continue
    break
  let
    startLine = lex.line
    startCol = lex.col
    startPos = lex.pos
  case lex.current
  of '\0':
    result = initToken(lex, tkEOF, startLine, startCol, startPos, wsno)
  of ';':
    lex.advance()
    result = initToken(lex, tkSemicolon, startLine, startCol, startPos, wsno)
  of ':':
    lex.advance()
    result = initToken(lex, tkColon, startLine, startCol, startPos, wsno)
  of ',':
    lex.advance()
    result = initToken(lex, tkComma, startLine, startCol, startPos, wsno)
  of '.':
    if peek(lex).isDigit():
      # leading-dot float: .125, .5rem, .5e2
      # (values keep the legacy leading-zero spelling: `0.5rem`)
      let fracStart = lex.pos # at '.'
      lex.advance() # consume '.'
      lex.advanceBy(scanDigits(lex.base, lex.pos, lex.len))
      discard tryLexExponent(lex)
      var nkind = tkFloat
      if tryLexUnitSuffix(lex):
        nkind = tkUnit
      result = initToken(lex, "0" & lex.sliceText(fracStart, lex.pos),
        nkind, startLine, startCol, startPos, wsno)
    else:
      lex.advance()
      result = initToken(lex, tkDot, startLine, startCol, startPos, wsno)
  of '#':
    lex.advance()
    result = initToken(lex, tkHash, startLine, startCol, startPos, wsno)
  of '(':
    lex.advance()
    result = initToken(lex, tkLParen, startLine, startCol, startPos, wsno)
  of ')':
    lex.advance()
    result = initToken(lex, tkRParen, startLine, startCol, startPos, wsno)
  of '{':
    lex.advance()
    result = initToken(lex, tkLBrace, startLine, startCol, startPos, wsno)
  of '}':
    lex.advance()
    result = initToken(lex, tkRBrace, startLine, startCol, startPos, wsno)
  of '[':
    lex.advance()
    result = initToken(lex, tkLBracket, startLine, startCol, startPos, wsno)
  of ']':
    lex.advance()
    result = initToken(lex, tkRBracket, startLine, startCol, startPos, wsno)
  of '+':
    lex.advance()
    if lex.current == '=':
      lex.advance()
      result = initToken(lex, tkPlusAssign, startLine, startCol, startPos, wsno)
    else:
      result = initToken(lex, tkPlus, startLine, startCol, startPos, wsno)
  of '-':
    # CSS custom property: starts with `--`
    if peek(lex) == '-':
      # consume both '-' characters
      lex.advance() # first '-'
      lex.advance() # second '-'
      # allow letters, digits, underscores and hyphens in the rest of the name
      lex.advanceBy(scanIdentTail(lex.base, lex.pos, lex.len))
      result = initToken(lex, lex.sliceText(startPos, lex.pos),
        tkCssVar, startLine, startCol, startPos, wsno)
    elif peek(lex).isAlphaAscii():
      # vendor-prefixed identifier: -webkit-..., -moz-..., -ms-...
      lex.advance() # consume '-'
      lex.advanceBy(scanIdentTail(lex.base, lex.pos, lex.len))
      result = initToken(lex, lex.sliceText(startPos, lex.pos),
        tkIdentifier, startLine, startCol, startPos, wsno)
    elif peek(lex).isDigit():
      # negative number: -0.375, -5, -1e2  (single token so `-0.375rem -0.75rem` are two values)
      lex.advance() # consume '-'
      lex.advanceBy(scanDigits(lex.base, lex.pos, lex.len))
      var isFloat = false
      if lex.current == '.' and peek(lex).isDigit():
        lex.advance() # consume '.'
        lex.advanceBy(scanDigits(lex.base, lex.pos, lex.len))
        isFloat = true
      if tryLexExponent(lex):
        isFloat = true
      var nkind = if isFloat: tkFloat else: tkInt
      if tryLexUnitSuffix(lex):
        nkind = tkUnit
      result = initToken(lex, lex.sliceText(startPos, lex.pos),
        nkind, startLine, startCol, startPos, wsno)
    else:
      lex.advance()
      if lex.current == '=':
        lex.advance()
        result = initToken(lex, tkMinusAssign, startLine, startCol, startPos, wsno)
      else:
        result = initToken(lex, tkMinus, startLine, startCol, startPos, wsno)
  of '*':
    lex.advance()
    if lex.current == '=':
      lex.advance()
      result = initToken(lex, tkAsteriskAssign, startLine, startCol, startPos, wsno)
    else:
      result = initToken(lex, tkAsterisk, startLine, startCol, startPos, wsno)
  of '/':
    # handle divide, assignment, and comments:
    lex.advance() # moved past '/'
    if lex.current == '=':
      lex.advance()
      result = initToken(lex, tkSlashAssign, startLine, startCol, startPos, wsno)
    elif lex.current == '/':
      # single-line comment: '//' ... until newline (don't consume newline here)
      lex.advance() # move to first char of comment body
      let bodyStart = lex.pos
      # body holds no newlines by construction: plain bulk advance
      lex.advanceBy(offsetUntilEither(lex.base, lex.pos, lex.len, '\n', '\r'))
      result = initToken(lex, lex.sliceText(bodyStart, lex.pos),
        tkComment, startLine, startCol, startPos, wsno)
    elif lex.current == '*':
      # block comment: '/* ... */' and docblocks '/** ... */' or '/*! ... */'
      # (banner convention for license headers that must survive minification)
      let isBang = peek(lex, 1) == '!'
      let isDoc = peek(lex, 1) == '*' or isBang
      # consume the '*' we are currently on, then hop between '*' runs
      # until '*/' or EOF (bodies may span lines: advanceSpan fix-up)
      lex.advance()
      let bodyStart = lex.pos
      var bodyEnd = lex.pos
      while true:
        lex.advanceSpan(lex.pos,
          lex.pos + offsetUntilByte(lex.base, lex.pos, lex.len, '*'))
        if lex.current == '*' and peek(lex) == '/':
          bodyEnd = lex.pos
          lex.advance() # '*'
          lex.advance() # '/'
          break
        if lex.current == '\0': # EOF: unterminated comment
          bodyEnd = lex.pos
          break
        lex.advance() # lone '*', keep scanning
      result = initToken(lex, lex.sliceText(bodyStart, bodyEnd),
        if isBang: tkDocBlockBang elif isDoc: tkDocBlock else: tkComment,
        startLine, startCol, startPos, wsno)
    else:
      result = initToken(lex, tkDivide, startLine, startCol, startPos, wsno)
  of '%':
    lex.advance()
    if lex.current == '=':
      lex.advance()
      result = initToken(lex, tkPercentAssign, startLine, startCol, startPos, wsno)
    else:
      result = initToken(lex, tkPercent, startLine, startCol, startPos, wsno)
  of '=':
    lex.advance()
    if lex.current == '=':
      lex.advance()
      result = initToken(lex, tkDoubleEqual, startLine, startCol, startPos, wsno)
    else:
      result = initToken(lex, tkAssign, startLine, startCol, startPos, wsno)
  of '!':
    lex.advance()
    if lex.current == '=':
      lex.advance()
      result = initToken(lex, tkNotEqual, startLine, startCol, startPos, wsno)
    else:
      result = initToken(lex, tkBang, startLine, startCol, startPos, wsno)
  of '<':
    lex.advance()
    if lex.current == '=':
      lex.advance()
      result = initToken(lex, tkLTE, startLine, startCol, startPos, wsno)
    else:
      result = initToken(lex, tkLT, startLine, startCol, startPos, wsno)
  of '>':
    lex.advance()
    if lex.current == '=':
      lex.advance()
      result = initToken(lex, tkGTE, startLine, startCol, startPos, wsno)
    else:
      result = initToken(lex, tkGT, startLine, startCol, startPos, wsno)
  of '&':
    lex.advance()
    if lex.current == '&':
      lex.advance()
      result = initToken(lex, tkAndAnd, startLine, startCol, startPos, wsno)
    else:
      result = initToken(lex, tkAmp, startLine, startCol, startPos, wsno)
  of '|':
    lex.advance()
    if lex.current == '|':
      lex.advance()
      result = initToken(lex, tkOrOr, startLine, startCol, startPos, wsno)
    elif lex.current == '=':
      lex.advance()
      result = initToken(lex, tkPipeAssign, startLine, startCol, startPos, wsno)
    else:
      result = initToken(lex, tkUnknown, startLine, startCol, startPos, wsno)
  of '"', '\'':
    let quote = lex.current
    lex.advance()
    let bodyStart = lex.pos
    let stop = bodyStart + offsetUntilEither(lex.base, bodyStart, lex.len, quote, '\\')
    if stop < lex.len and lex.base[stop] == '\\':
      # escape path (rare): original scalar loop, lexer state untouched above
      lex.strbuf.setLen(0)
      while lex.current != quote and lex.current != '\0':
        if lex.current == '\\':
          lex.advance()
          case lex.current
          of 'n': lex.strbuf.add('\n')
          of 't': lex.strbuf.add('\t')
          of 'r': lex.strbuf.add('\r')
          of '"': lex.strbuf.add('"')
          of '\'': lex.strbuf.add('\'')
          of '\\': lex.strbuf.add('\\')
          else:
            # CSS strings: preserve the backslash for unrecognized escapes
            # e.g. `\201E` → `\201E`, `\3B` → `\3B`
            lex.strbuf.add('\\')
            lex.strbuf.add(lex.current)
        else:
          lex.strbuf.add(lex.current)
        lex.advance()
      lex.advance() # skip closing quote
      result = initToken(lex, move(lex.strbuf), tkString, startLine, startCol, startPos, wsno)
    else:
      # no escapes: verbatim slice (bodies may span lines: advanceSpan fix-up)
      lex.advanceSpan(bodyStart, stop)
      if lex.current == quote:
        lex.advance() # skip closing quote
      result = initToken(lex, lex.sliceText(bodyStart, stop),
        tkString, startLine, startCol, startPos, wsno)
  of '0'..'9':
    # integer part
    lex.advanceBy(scanDigits(lex.base, lex.pos, lex.len))
    var isFloat = false
    # fractional part?
    if lex.current == '.' and peek(lex).isDigit():
      lex.advance() # consume '.'
      lex.advanceBy(scanDigits(lex.base, lex.pos, lex.len))
      isFloat = true
    # scientific notation? e.g. 1e3, 2.5E-2
    if tryLexExponent(lex):
      isFloat = true
    var nkind = if isFloat: tkFloat else: tkInt
    if tryLexUnitSuffix(lex):
      nkind = tkUnit
    result = initToken(lex, lex.sliceText(startPos, lex.pos),
      nkind, startLine, startCol, startPos, wsno)

  of '$':
    if peek(lex) == '=':
      lex.advance()
      lex.advance()
      result = initToken(lex, tkDollarAssign, startLine, startCol, startPos, wsno)
    else:
      lex.advance() # skip '$'
      lex.advanceBy(scanIdentTail(lex.base, lex.pos, lex.len))
      result = initToken(lex, lex.sliceText(startPos, lex.pos),
        tkIdentifier, startLine, startCol, startPos, wsno)
  of '_':
    lex.advanceBy(scanIdentTail(lex.base, lex.pos, lex.len)) # '_' is in the tail class
    result = initToken(lex, lex.sliceText(startPos, lex.pos),
      tkIdentifier, startLine, startCol, startPos, wsno)
  of '~':
    lex.advance()
    if lex.current == '=':
      lex.advance()
      result = initToken(lex, tkTildeAssign, startLine, startCol, startPos, wsno)
    else:
      result = initToken(lex, tkTilde, startLine, startCol, startPos, wsno)
  of '^':
    lex.advance()
    if lex.current == '=':
      lex.advance()
      result = initToken(lex, tkCaretAssign, startLine, startCol, startPos, wsno)
    else:
      result = initToken(lex, tkCaret, startLine, startCol, startPos, wsno)
  of '`':
    lex.advance()
    let bodyStart = lex.pos
    # body stops at backtick/newline/EOF, so no line folding: plain advance
    lex.advanceBy(offsetUntilEither(lex.base, lex.pos, lex.len, '`', '\n'))
    let bodyEnd = lex.pos
    if lex.current == '`':
      lex.advance()
    result = initToken(lex, lex.sliceText(bodyStart, bodyEnd),
      tkBacktick, startLine, startCol, startPos, wsno)
  of '@':
    lex.advance()
    result = initToken(lex, tkAt, startLine, startCol, startPos, wsno)
  else:
    if lex.current.isAlphaAscii() or lex.current in {'_', '-'}:
      let wordStart = lex.pos
      lex.advanceBy(scanIdentTail(lex.base, lex.pos, lex.len))
      # Keywords never materialize a string: match on source text first,
      # slice only for true identifiers.
      let kw = keywordKindAt(lex.base, wordStart, lex.pos - wordStart)
      # `fn` / `func` are canonical aliases for `function` (see keywordKindAt)
      if kw == tkIdentifier:
        result = initToken(lex, lex.sliceText(wordStart, lex.pos), tkIdentifier,
          startLine, startCol, startPos, wsno)
      else:
        result = (kw, "", startLine, startCol, startPos, wsno)
    else:
      lex.advance()
      result = initToken(lex, tkUnknown, startLine, startCol, startPos, wsno)  

proc getToken*(lex: var Lexer): TokenTuple =
  ## Returns the next token from the input
  result = nextToken(lex)

proc getTokens*(lex: var Lexer, buf: var openArray[TokenTuple]): int =
  ## Batch fill: lex up to `buf.len` tokens, always fully filled (the lexer
  ## repeats `tkEOF` once exhausted, so parsers can drain unconditionally).
  ## Returns `buf.len`. Backs the parser prefetch buffer; single-token
  ## `getToken` stays for lookahead and tests.
  for i in 0 ..< buf.len:
    buf[i] = nextToken(lex)
  result = buf.len