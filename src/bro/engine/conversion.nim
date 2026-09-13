# A super fast stylesheet language for cool kids!
#
# (c) 2026 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/bowdy

import std/[math, strformat]

type
  UnitKind = enum
    uUnknown, uPx, uEm, uRem, uPercent, uVw, uVh,
    uVmin, uVmax, uCm, uMm, uIn, uPt, uPc, uCh, uEx

  CSSUnitVal = object
    value*: float
    unit*: UnitKind

  UnitContext = object
    baseFontPx*: float    # parent font-size in px (for em, ch, ex approximations)
    rootFontPx*: float    # root font-size in px (for rem)
    viewportWidth*: float # viewport width in px (for vw)
    viewportHeight*: float# viewport height in px (for vh)
    percentBase*: float   # base value in px to resolve percentages (must be provided when using %)

# Convert CSSUnitVal to pixels using the context. Raises if required context missing.
proc toPx(val: CSSUnitVal, ctx: UnitContext): float =
  case val.unit
  of uPx:
    result = val.value
  of uEm:
    result = val.value * ctx.baseFontPx
  of uRem:
    result = val.value * ctx.rootFontPx
  of uPercent:
    if ctx.percentBase <= 0.0:
      raise newException(Exception, "percentBase required in UnitContext to resolve % values")
    result = val.value / 100.0 * ctx.percentBase
  of uVw:
    result = val.value / 100.0 * ctx.viewportWidth
  of uVh:
    result = val.value / 100.0 * ctx.viewportHeight
  of uVmin:
    let v = min(ctx.viewportWidth, ctx.viewportHeight)
    result = val.value / 100.0 * v
  of uVmax:
    let v = max(ctx.viewportWidth, ctx.viewportHeight)
    result = val.value / 100.0 * v
  of uCm:
    # CSS uses 96dpi: 1in = 96px, 1in = 2.54cm -> 1cm = 96/2.54 px
    result = val.value * (96.0 / 2.54)
  of uMm:
    result = val.value * (96.0 / 25.4) # 1mm = 1/25.4 in
  of uIn:
    result = val.value * 96.0
  of uPt:
    # 1pt = 1/72in -> px = 96 * pt / 72 = pt * 1.333333...
    result = val.value * (96.0 / 72.0)
  of uPc:
    # 1pc = 12pt
    result = val.value * 12.0 * (96.0 / 72.0)
  of uCh:
    # approximate: width of "0" — often close to 0.5em, requires baseFontPx
    result = val.value * ctx.baseFontPx * 0.5
  of uEx:
    # approximate: x-height ~ 0.5em (depends on font)
    result = val.value * ctx.baseFontPx * 0.5
  else:
    raise newException(Exception, "unsupported or unknown unit")

proc isGreater*(a, b: CSSUnitVal, ctx: UnitContext, tol = 1e-6): bool =
  ## Returns true if `a` is greater than `b` by more than `tol` pixels
  let ax = toPx(a, ctx)
  let bx = toPx(b, ctx)
  result = ax > bx + tol

proc isLess*(a, b: CSSUnitVal, ctx: UnitContext, tol = 1e-6): bool =
  ## Returns true if `a` is less than `b` by more than `tol` pixels
  let ax = toPx(a, ctx)
  let bx = toPx(b, ctx)
  result = ax + tol < bx

proc isEqual*(a, b: CSSUnitVal, ctx: UnitContext, tol = 1e-6): bool =
  ## Returns true if `a` and `b` are equal within `tol` pixels
  let ax = toPx(a, ctx)
  let bx = toPx(b, ctx)
  result = abs(ax - bx) <= tol

# Small helpers
proc unitToStr*(u: UnitKind): string =
  case u
  of uPx: "px"
  of uEm: "em"
  of uRem: "rem"
  of uPercent: "%"
  of uVw: "vw"
  of uVh: "vh"
  of uVmin: "vmin"
  of uVmax: "vmax"
  of uCm: "cm"
  of uMm: "mm"
  of uIn: "in"
  of uPt: "pt"
  of uPc: "pc"
  of uCh: "ch"
  of uEx: "ex"
  else: "unknown"

proc `$`*(v: CSSUnitVal): string =
  &"{v.value}{unitToStr(v.unit)}"