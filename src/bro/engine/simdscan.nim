# Bound-safe span scanners for the bro lexer (SIMD fast paths + scalar fallback).
#
# Contract every proc honors: inputs satisfy 0 <= pos <= stop <= readableLen,
# and no proc ever reads at or past `stop`. That keeps mmap/memfiles tails
# safe (over-read off a mapping end segfaults). Full 16-byte vectors load
# only while `i + 16 <= stop`; the remainder goes scalar.
#
# Backend notes:
# - amd64 uses SSE2 only (baseline on x86_64, no runtime check needed).
# - arm64 Neon lands in Phase 3; until then arm64 uses the scalar fallback.
# - All SIMD procs stay on value types (M128i) in `func {.inline.}` so the
#   ORC/`deepcopy:on` build flags never interact with vector state.
# - Byte classification is ASCII-only and high bytes (>= 0x80) are never
#   treated as ident/digit/space, matching the scalar `strutils` predicates.
#
# (c) 2026 George Lemon | LGPL License

when defined(amd64):
  import pkg/nimsimd/sse2
elif defined(arm64):
  import pkg/nimsimd/neon
import std/bitops

const simdBackend* =
  when defined(amd64): "sse2"
  elif defined(arm64): "neon"
  else: "scalar"

# ---------------------------------------------------------------- scalar ---

func scanSpacesScalar(p: ptr UncheckedArray[char], pos, stop: int): int {.inline.} =
  var i = pos
  while i < stop and (p[i] == ' ' or p[i] == '\t'): inc i
  i - pos

func scanDigitsScalar(p: ptr UncheckedArray[char], pos, stop: int): int {.inline.} =
  var i = pos
  while i < stop and p[i] in {'0'..'9'}: inc i
  i - pos

func scanIdentTailScalar(p: ptr UncheckedArray[char], pos, stop: int): int {.inline.} =
  ## `[A-Za-z0-9_-]*` run (matches the lexer's ident loop incl. `-`).
  var i = pos
  while i < stop:
    let c = p[i]
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}: inc i
    else: break
  i - pos

func scanUnitTailScalar(p: ptr UncheckedArray[char], pos, stop: int): int {.inline.} =
  ## `[A-Za-z0-9_]*` run (matches `tryLexUnitSuffix`, no `-`).
  var i = pos
  while i < stop:
    let c = p[i]
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: inc i
    else: break
  i - pos

func offsetUntilByteScalar(p: ptr UncheckedArray[char], pos, stop: int, b: char): int {.inline.} =
  ## Offset of the first `b` at or after pos, or `stop - pos` when absent.
  var i = pos
  while i < stop and p[i] != b: inc i
  i - pos

func offsetUntilEitherScalar(p: ptr UncheckedArray[char], pos, stop: int, b1, b2: char): int {.inline.} =
  ## Offset of the first `b1`/`b2` at or after pos, or `stop - pos`.
  var i = pos
  while i < stop and p[i] != b1 and p[i] != b2: inc i
  i - pos

# ------------------------------------------------------------------- SSE2 ---

when defined(amd64):
  func trailingRun(mask: int32): int {.inline.} =
    ## Length of the leading 1-run in the low 16 bits of mask.
    ## Caller guarantees at least one zero bit in the low 16.
    countTrailingZeroBits(cast[uint32](not mask))

  func scanSpacesSse2(p: ptr UncheckedArray[char], pos, stop: int): int {.inline.} =
    var i = pos
    let sp = mm_set1_epi8(' ')
    let tb = mm_set1_epi8('\t')
    while i + 16 <= stop:
      let v = mm_loadu_si128(cast[ptr M128i](addr p[i]))
      let m = mm_or_si128(mm_cmpeq_epi8(v, sp), mm_cmpeq_epi8(v, tb))
      let mask = mm_movemask_epi8(m)
      if mask != 0xFFFF'i32:
        return i + trailingRun(mask) - pos
      i += 16
    while i < stop and (p[i] == ' ' or p[i] == '\t'): inc i
    i - pos

  func rangeMaskSse2(v, high, lo, n: M128i, zero: M128i): M128i {.inline.} =
    ## 0xFF per lane whose byte is in `[lo, lo+n)`. SSE2 compares signed,
    ## so a `sub`+`cmplt` check alone accepts bytes *below* lo (the
    ## difference wraps negative, which is `< n`). Lanes are rejected when
    ## the raw byte has the sign bit set (`high`, i.e. >= 0x80) or the
    ## difference is negative (byte < lo); the survivors satisfy `t < n`.
    let t = mm_sub_epi8(v, lo)
    let bad = mm_or_si128(high, mm_cmplt_epi8(t, zero))
    mm_andnot_si128(bad, mm_cmplt_epi8(t, n))

  func classMaskSse2(v: M128i, allowDash: bool): M128i {.inline.} =
    ## Bitmask vector: 0xFF per lane whose byte is [0-9A-Za-z_] (+ `-`).
    let zero = mm_setzero_si128()
    let high = mm_cmplt_epi8(v, zero)
    let isDigit = rangeMaskSse2(v, high, mm_set1_epi8('0'), mm_set1_epi8(10), zero)
    let isUpper = rangeMaskSse2(v, high, mm_set1_epi8('A'), mm_set1_epi8(26), zero)
    let isLower = rangeMaskSse2(v, high, mm_set1_epi8('a'), mm_set1_epi8(26), zero)
    var m = mm_or_si128(mm_or_si128(isDigit, isUpper), isLower)
    m = mm_or_si128(m, mm_cmpeq_epi8(v, mm_set1_epi8('_')))
    if allowDash:
      m = mm_or_si128(m, mm_cmpeq_epi8(v, mm_set1_epi8('-')))
    m

  func scanClassSse2(p: ptr UncheckedArray[char], pos, stop: int, allowDash: bool): int {.inline.} =
    var i = pos
    while i + 16 <= stop:
      let v = mm_loadu_si128(cast[ptr M128i](addr p[i]))
      let mask = mm_movemask_epi8(classMaskSse2(v, allowDash))
      if mask != 0xFFFF'i32:
        return i + trailingRun(mask) - pos
      i += 16
    if allowDash:
      while i < stop:
        let c = p[i]
        if c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}: inc i
        else: break
    else:
      while i < stop:
        let c = p[i]
        if c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: inc i
        else: break
    i - pos

  func scanDigitsSse2(p: ptr UncheckedArray[char], pos, stop: int): int {.inline.} =
    var i = pos
    let zero = mm_setzero_si128()
    let ten = mm_set1_epi8(10)
    let zc = mm_set1_epi8('0')
    while i + 16 <= stop:
      let v = mm_loadu_si128(cast[ptr M128i](addr p[i]))
      let m = rangeMaskSse2(v, mm_cmplt_epi8(v, zero), zc, ten, zero)
      let mask = mm_movemask_epi8(m)
      if mask != 0xFFFF'i32:
        return i + trailingRun(mask) - pos
      i += 16
    while i < stop and p[i] in {'0'..'9'}: inc i
    i - pos

  func offsetUntilByteSse2(p: ptr UncheckedArray[char], pos, stop: int, b: char): int {.inline.} =
    var i = pos
    let bc = mm_set1_epi8(b)
    while i + 16 <= stop:
      let v = mm_loadu_si128(cast[ptr M128i](addr p[i]))
      let mask = mm_movemask_epi8(mm_cmpeq_epi8(v, bc))
      if mask != 0'i32:
        return i + countTrailingZeroBits(cast[uint32](mask)) - pos
      i += 16
    while i < stop and p[i] != b: inc i
    i - pos

  func offsetUntilEitherSse2(p: ptr UncheckedArray[char], pos, stop: int, b1, b2: char): int {.inline.} =
    var i = pos
    let c1 = mm_set1_epi8(b1)
    let c2 = mm_set1_epi8(b2)
    while i + 16 <= stop:
      let v = mm_loadu_si128(cast[ptr M128i](addr p[i]))
      let m = mm_or_si128(mm_cmpeq_epi8(v, c1), mm_cmpeq_epi8(v, c2))
      let mask = mm_movemask_epi8(m)
      if mask != 0'i32:
        return i + countTrailingZeroBits(cast[uint32](mask)) - pos
      i += 16
    while i < stop and p[i] != b1 and p[i] != b2: inc i
    i - pos

elif defined(arm64):
  # Neon has unsigned byte compares, so ranges need no sign-bit guard:
  # `t = (x - lo) mod 256` satisfies `t < n` exactly for x in [lo, lo+n).
  func bc(b: uint8): uint8x16 {.inline.} = vmovq_n_u8(b)

  func maskRun8(x: uint8x8): int {.inline.} =
    ## Leading 0xFF-byte run over 8 lanes. Compare intrinsics emit full
    ## bytes only, so `ctz div 8` counts whole matching lanes; all-match
    ## guards the undefined ctz(0xFFFF...).
    let w = vget_lane_u64(vreinterpret_u64_u8(x), 0'i32)
    if w == high(uint64): 8
    else: countTrailingZeroBits(w) div 8

  func findIn8(x: uint8x8): int {.inline.} =
    ## First 0xFF-lane index in 8 lanes, or -1.
    let w = vget_lane_u64(vreinterpret_u64_u8(x), 0'i32)
    if w == 0'u64: -1
    else: countTrailingZeroBits(w) div 8

  func classMaskNeon(v: uint8x16, allowDash: bool): uint8x16 {.inline.} =
    let d = vcltq_u8(vsubq_u8(v, bc(48'u8)), bc(10'u8)) # '0'
    let u = vcltq_u8(vsubq_u8(v, bc(65'u8)), bc(26'u8)) # 'A'
    let l = vcltq_u8(vsubq_u8(v, bc(97'u8)), bc(26'u8)) # 'a'
    var m = vorrq_u8(vorrq_u8(d, u), l)
    m = vorrq_u8(m, vceqq_u8(v, bc(95'u8))) # '_'
    if allowDash:
      m = vorrq_u8(m, vceqq_u8(v, bc(45'u8))) # '-'
    m

  func scanSpacesNeon(p: ptr UncheckedArray[char], pos, stop: int): int {.inline.} =
    var i = pos
    let sp = bc(32'u8)
    let tb = bc(9'u8)
    while i + 16 <= stop:
      let v = vld1q_u8(cast[pointer](addr p[i]))
      let m = vorrq_u8(vceqq_u8(v, sp), vceqq_u8(v, tb))
      let r0 = maskRun8(vget_low_u8(m))
      if r0 < 8: return i + r0 - pos
      let r1 = maskRun8(vget_high_u8(m))
      if r1 < 8: return i + 8 + r1 - pos
      i += 16
    while i < stop and (p[i] == ' ' or p[i] == '\t'): inc i
    i - pos

  func scanClassNeon(p: ptr UncheckedArray[char], pos, stop: int, allowDash: bool): int {.inline.} =
    var i = pos
    while i + 16 <= stop:
      let v = vld1q_u8(cast[pointer](addr p[i]))
      let m = classMaskNeon(v, allowDash)
      let r0 = maskRun8(vget_low_u8(m))
      if r0 < 8: return i + r0 - pos
      let r1 = maskRun8(vget_high_u8(m))
      if r1 < 8: return i + 8 + r1 - pos
      i += 16
    if allowDash:
      while i < stop:
        let c = p[i]
        if c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}: inc i
        else: break
    else:
      while i < stop:
        let c = p[i]
        if c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: inc i
        else: break
    i - pos

  func scanDigitsNeon(p: ptr UncheckedArray[char], pos, stop: int): int {.inline.} =
    var i = pos
    let lo = bc(48'u8)
    let n = bc(10'u8)
    while i + 16 <= stop:
      let v = vld1q_u8(cast[pointer](addr p[i]))
      let m = vcltq_u8(vsubq_u8(v, lo), n)
      let r0 = maskRun8(vget_low_u8(m))
      if r0 < 8: return i + r0 - pos
      let r1 = maskRun8(vget_high_u8(m))
      if r1 < 8: return i + 8 + r1 - pos
      i += 16
    while i < stop and p[i] in {'0'..'9'}: inc i
    i - pos

  func offsetUntilNeon(p: ptr UncheckedArray[char], pos, stop: int,
      c1, c2: uint8x16, two: bool): int {.inline.} =
    var i = pos
    while i + 16 <= stop:
      let v = vld1q_u8(cast[pointer](addr p[i]))
      var m = vceqq_u8(v, c1)
      if two: m = vorrq_u8(m, vceqq_u8(v, c2))
      let f0 = findIn8(vget_low_u8(m))
      if f0 >= 0: return i + f0 - pos
      let f1 = findIn8(vget_high_u8(m))
      if f1 >= 0: return i + 8 + f1 - pos
      i += 16
    i

  func offsetUntilByteNeon(p: ptr UncheckedArray[char], pos, stop: int, b: char): int {.inline.} =
    var i = offsetUntilNeon(p, pos, stop, bc(uint8(ord(b))), bc(0'u8), false)
    while i < stop and p[i] != b: inc i
    i - pos

  func offsetUntilEitherNeon(p: ptr UncheckedArray[char], pos, stop: int, b1, b2: char): int {.inline.} =
    var i = offsetUntilNeon(p, pos, stop,
      bc(uint8(ord(b1))), bc(uint8(ord(b2))), true)
    while i < stop and p[i] != b1 and p[i] != b2: inc i
    i - pos

# ---------------------------------------------------------------- dispatch ---

func scanSpaces*(p: ptr UncheckedArray[char], pos, stop: int): int {.inline.} =
  ## Run of `' '`/`'\t'` starting at pos (newlines excluded: callers handle
  ## line counting scalar). Never reads at or past stop.
  when defined(amd64): scanSpacesSse2(p, pos, stop)
  elif defined(arm64): scanSpacesNeon(p, pos, stop)
  else: scanSpacesScalar(p, pos, stop)

func scanDigits*(p: ptr UncheckedArray[char], pos, stop: int): int {.inline.} =
  ## Run of `[0-9]` starting at pos. Never reads at or past stop.
  when defined(amd64): scanDigitsSse2(p, pos, stop)
  elif defined(arm64): scanDigitsNeon(p, pos, stop)
  else: scanDigitsScalar(p, pos, stop)

func scanIdentTail*(p: ptr UncheckedArray[char], pos, stop: int): int {.inline.} =
  ## Run of `[A-Za-z0-9_-]` starting at pos. Never reads at or past stop.
  when defined(amd64): scanClassSse2(p, pos, stop, true)
  elif defined(arm64): scanClassNeon(p, pos, stop, true)
  else: scanIdentTailScalar(p, pos, stop)

func scanUnitTail*(p: ptr UncheckedArray[char], pos, stop: int): int {.inline.} =
  ## Run of `[A-Za-z0-9_]` starting at pos. Never reads at or past stop.
  when defined(amd64): scanClassSse2(p, pos, stop, false)
  elif defined(arm64): scanClassNeon(p, pos, stop, false)
  else: scanUnitTailScalar(p, pos, stop)

func offsetUntilByte*(p: ptr UncheckedArray[char], pos, stop: int, b: char): int {.inline.} =
  ## Offset of the first `b` at or after pos, or `stop - pos` when absent.
  ## Never reads at or past stop.
  when defined(amd64): offsetUntilByteSse2(p, pos, stop, b)
  elif defined(arm64): offsetUntilByteNeon(p, pos, stop, b)
  else: offsetUntilByteScalar(p, pos, stop, b)

func offsetUntilEither*(p: ptr UncheckedArray[char], pos, stop: int, b1, b2: char): int {.inline.} =
  ## Offset of the first `b1`/`b2` at or after pos, or `stop - pos`.
  ## Never reads at or past stop.
  when defined(amd64): offsetUntilEitherSse2(p, pos, stop, b1, b2)
  elif defined(arm64): offsetUntilEitherNeon(p, pos, stop, b1, b2)
  else: offsetUntilEitherScalar(p, pos, stop, b1, b2)
