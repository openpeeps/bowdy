import unittest
import std/strutils
import ../src/bro/engine/simdscan

proc buf(s: string): ptr UncheckedArray[char] =
  if s.len == 0: cast[ptr UncheckedArray[char]](unsafeAddr s)
  else: cast[ptr UncheckedArray[char]](unsafeAddr s[0])

suite "simdscan span scanners":
  test "spaces: empty, mixed, newlines stop the run":
    check scanSpaces(buf(""), 0, 0) == 0
    check scanSpaces(buf("   \t  x"), 0, 7) == 6
    check scanSpaces(buf("  \n  "), 0, 5) == 2
    check scanSpaces(buf("  \r  "), 0, 5) == 2
    check scanSpaces(buf("x   "), 0, 4) == 0

  test "digits stop at first non-digit":
    check scanDigits(buf(""), 0, 0) == 0
    check scanDigits(buf("12345px"), 0, 7) == 5
    check scanDigits(buf("12e5"), 0, 4) == 2
    check scanDigits(buf("px"), 0, 2) == 0

  test "ident tail includes dash, unit tail excludes it":
    check scanIdentTail(buf("my-class_2 x"), 0, 11) == 10
    check scanUnitTail(buf("px-2"), 0, 4) == 2
    check scanUnitTail(buf("em2_ x"), 0, 5) == 4
    check scanIdentTail(buf("-webkit-x"), 0, 9) == 9

  test "high bytes never classify (signed-range guard)":
    let s = "a\x80\xFF" & "b"
    check scanIdentTail(buf(s), 0, s.len) == 1
    check scanDigits(buf("\xB0" & "12"), 0, 3) == 0
    check scanSpaces(buf("\xA0 "), 0, 2) == 0

  test "vector-boundary sweeps agree end to end":
    # every length 0..64 around the 16-byte stride, every offset pattern
    let alpha = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    for n in 0 .. 64:
      let s = alpha.repeat((n div alpha.len) + 1)[0 ..< n] & "!"
      var expUnit = n
      for i in 0 ..< n:
        if s[i] == '-': expUnit = i; break
      check scanIdentTail(buf(s), 0, s.len) == n
      check scanUnitTail(buf(s), 0, s.len) == expUnit
    for n in 0 .. 64:
      let s = " ".repeat(n) & "\t " & "x"
      check scanSpaces(buf(s), 0, s.len) == n + 2
    for n in 0 .. 64:
      let s = "0123456789".repeat((n div 10) + 1)[0 ..< n] & "x"
      check scanDigits(buf(s), 0, s.len) == n

  test "every byte value classifies exactly like the scalar predicate":
    for b in 0 .. 255:
      let c = chr(b)
      let s = ($c).repeat(32) & "!"
      let isSpace = c == ' ' or c == '\t'
      let isDigit = c in {'0'..'9'}
      let isIdent = c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}
      let isUnit = c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}
      check scanSpaces(buf(s), 0, s.len) == (if isSpace: 32 else: 0)
      check scanDigits(buf(s), 0, s.len) == (if isDigit: 32 else: 0)
      check scanIdentTail(buf(s), 0, s.len) == (if isIdent: 32 else: 0)
      check scanUnitTail(buf(s), 0, s.len) == (if isUnit: 32 else: 0)

  test "offsetUntilByte finds first hit or reports end":
    check offsetUntilByte(buf(""), 0, 0, '*') == 0
    check offsetUntilByte(buf("abc*def"), 0, 7, '*') == 3
    check offsetUntilByte(buf("abcdef"), 0, 6, '*') == 6
    check offsetUntilByte(buf("*abcdef"), 0, 7, '*') == 0
    check offsetUntilByte(buf("abcdef*"), 0, 7, '*') == 6
    # every hit position across two vector strides
    for n in 0 .. 40:
      let s = "x".repeat(n) & "*" & "y".repeat(40 - n)
      check offsetUntilByte(buf(s), 0, s.len, '*') == n
    # absent over all lengths incl. exact multiples of 16
    for n in [0, 1, 15, 16, 17, 31, 32, 33, 48, 64]:
      check offsetUntilByte(buf("x".repeat(n)), 0, n, '*') == n

  test "offsetUntilEither stops at either byte":
    check offsetUntilEither(buf(""), 0, 0, '\n', '\r') == 0
    check offsetUntilEither(buf("ab\ncd"), 0, 5, '\n', '\r') == 2
    check offsetUntilEither(buf("ab\rcd"), 0, 5, '\n', '\r') == 2
    check offsetUntilEither(buf("abcdef"), 0, 6, '\n', '\r') == 6
    for n in 0 .. 40:
      let s1 = "x".repeat(n) & "\n" & "y".repeat(40 - n)
      check offsetUntilEither(buf(s1), 0, s1.len, '\n', '\r') == n
      let s2 = "x".repeat(n) & "\r" & "y".repeat(40 - n)
      check offsetUntilEither(buf(s2), 0, s2.len, '\n', '\r') == n
    # quote-or-backslash (string fast path): first of either wins
    check offsetUntilEither(buf("ab\\cd\"ef"), 0, 8, '"', '\\') == 2
    check offsetUntilEither(buf("abcd\"ef"), 0, 7, '"', '\\') == 4

  test "mid-buffer offsets and straddled tails":
    let s = "ab  \t  cd1234-ef  px  "
    check scanSpaces(buf(s), 2, s.len) == 5
    check scanIdentTail(buf(s), 7, s.len) == 9
    check scanDigits(buf(s), 9, s.len) == 4
    check scanUnitTail(buf(s), 18, s.len) == 2
    check scanSpaces(buf(s), s.len, s.len) == 0
