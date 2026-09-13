# CSS strict typed values for Bro — length, angle, time, resolution, flex
#
# Every CSS unit is a typed foreign Object (Value with isForeign objectVal)
# wrapping a plain-object payload from cssvalues (never ref). No
# tyString/tyInt fallback anywhere: strict type errors on mismatch.
# (c) 2026 George Lemon | LGPL-v3 License

import std/[strutils, options, tables]
import pkg/vancode/interpreter/[ast, chunk, sym, value]
import ./inliner
import ./cssvalues
import ./libcolors  # tyColor: runtime Value kind for colors (vs ttyColor for Symbols)
import ../vancodegen  # brings ttyLength etc into scope
import ../parser as broParser

proc parseCssUnit(s: string): tuple[val: float, unit: string, ok: bool] =
  if s.len == 0: return (0, "", false)
  var i = 0
  if s[0] in {'-', '+'}: inc i
  while i < s.len and s[i] in {'0'..'9', '.'}:
    inc i
  # A unit starting with e (em, ex, ...) is not an exponent: only treat
  # e/E as an exponent marker when a digit or sign follows it.
  if i < s.len and s[i] in {'e', 'E'} and i + 1 < s.len and
      s[i + 1] in {'0'..'9', '-', '+'}:
    inc i
    if i < s.len and s[i] in {'-', '+'}: inc i
    while i < s.len and s[i] in {'0'..'9'}:
      inc i
  if i == 0 or (i == 1 and s[0] in {'-', '+'}):
    return (0, "", false)
  try:
    let num = parseFloat(s[0..<i])
    let unit = s[i..^1]
    if unit.len == 0:
      return (num, "", true)
    if unit in broParser.unitSizeSuffixes or unit == "%":
      return (num, unit, true)
    else:
      return (0, "", false)
  except:
    return (0, "", false)

proc newCssSize*(s: string): Value =
  let p = parseCssUnit(s)
  if not p.ok:
    raise newException(ValueError, "Invalid length value: '" & s & "'")
  initCssPayload(ord(ttyLength), CssSize(val: p.val, unit: p.unit), cssNumStr(p.val) & p.unit)

proc newCssSizeRaw*(val: float, unit: string): Value =
  initCssPayload(ord(ttyLength), CssSize(val: val, unit: unit), cssNumStr(val) & unit)

proc newCssAngle*(s: string): Value =
  let p = parseCssUnit(s)
  if not p.ok or p.unit notin ["deg", "rad", "grad", "turn"]:
    raise newException(ValueError, "Invalid angle value: '" & s & "'")
  initCssPayload(ord(ttyAngle), CssAngle(val: p.val, unit: p.unit), cssNumStr(p.val) & p.unit)

proc newCssAngleRaw*(val: float, unit: string): Value =
  initCssPayload(ord(ttyAngle), CssAngle(val: val, unit: unit), cssNumStr(val) & unit)

proc newCssTime*(s: string): Value =
  let p = parseCssUnit(s)
  if not p.ok or p.unit notin ["s", "ms"]:
    raise newException(ValueError, "Invalid time value: '" & s & "'")
  initCssPayload(ord(ttyTime), CssTime(val: p.val, unit: p.unit), cssNumStr(p.val) & p.unit)

proc newCssTimeRaw*(val: float, unit: string): Value =
  initCssPayload(ord(ttyTime), CssTime(val: val, unit: unit), cssNumStr(val) & unit)

proc newCssResolution*(s: string): Value =
  let p = parseCssUnit(s)
  if not p.ok or p.unit notin ["dpi", "dpcm", "dppx"]:
    raise newException(ValueError, "Invalid resolution value: '" & s & "'")
  initCssPayload(ord(ttyResolution), CssResolution(val: p.val, unit: p.unit), cssNumStr(p.val) & p.unit)

proc newCssFlex*(s: string): Value =
  let p = parseCssUnit(s)
  if not p.ok or p.unit != "fr":
    raise newException(ValueError, "Invalid flex value: '" & s & "'")
  initCssPayload(ord(ttyFlex), CssFlex(val: p.val, unit: p.unit), cssNumStr(p.val) & p.unit)

proc cssSizeToString*(v: Value): string =
  if v.typeId != ord(ttyLength):
    raise newException(ValueError, "type mismatch: expected length, got typeId " & $v.typeId)
  let c = v.foreign(CssSize)
  cssNumStr(c.val) & c.unit

proc cssAngleToString*(v: Value): string =
  if v.typeId != ord(ttyAngle):
    raise newException(ValueError, "type mismatch: expected angle, got typeId " & $v.typeId)
  let c = v.foreign(CssAngle)
  cssNumStr(c.val) & c.unit

proc cssTimeToString*(v: Value): string =
  if v.typeId != ord(ttyTime):
    raise newException(ValueError, "type mismatch: expected time, got typeId " & $v.typeId)
  let c = v.foreign(CssTime)
  cssNumStr(c.val) & c.unit

proc cssResolutionToString*(v: Value): string =
  if v.typeId != ord(ttyResolution):
    raise newException(ValueError, "type mismatch: expected resolution, got typeId " & $v.typeId)
  let c = v.foreign(CssResolution)
  cssNumStr(c.val) & c.unit

proc cssFlexToString*(v: Value): string =
  if v.typeId != ord(ttyFlex):
    raise newException(ValueError, "type mismatch: expected flex, got typeId " & $v.typeId)
  let c = v.foreign(CssFlex)
  cssNumStr(c.val) & c.unit

proc valueToCssText(v: Value): string =
  ## Render one runtime value to CSS text (mirrors `cssStr` in libsystem):
  ## primitives stringify, strictly typed values use the cached foreign-tag
  ## spelling. Used for `var()` fallbacks, which accept any value.
  case v.typeId
  of tyString: v.stringVal[]
  of tyInt: $v.intVal
  of tyFloat:
    var fs = $v.floatVal
    if fs.len > 2 and fs[fs.len - 2] == '.' and fs[fs.len - 1] == '0':
      fs.setLen(fs.len - 2)
    fs
  of tyBool: $v.boolVal
  else:
    if v.objectVal != nil and v.objectVal.isForeign and
        v.objectVal.foreign.tag.len > 0:
      v.objectVal.foreign.tag
    else: ""

proc toCssSize(v: Value): CssSize =
  if v.typeId != ord(ttyLength):
    raise newException(ValueError, "type mismatch: expected length, got typeId " & $v.typeId)
  v.foreign(CssSize)

proc toCssAngle(v: Value): CssAngle =
  if v.typeId != ord(ttyAngle):
    raise newException(ValueError, "type mismatch: expected angle, got typeId " & $v.typeId)
  v.foreign(CssAngle)

proc toCssTime(v: Value): CssTime =
  if v.typeId != ord(ttyTime):
    raise newException(ValueError, "type mismatch: expected time, got typeId " & $v.typeId)
  v.foreign(CssTime)

# ---- Generic CSS function values (translate3d, blur, gradients, ...) ----
# Every signaturable CSS function evaluates to a family-typed value whose
# foreign tag caches the canonical `name(a, b)` spelling, so VM emission,
# cssStr and cssJoin render it with zero special cases. Params stay ttyAny:
# vancode signatures cannot express CSS's "bare 0 is a length", so kind
# validation lives in the bodies with precise errors (firing in both
# lenient and strict modes, like other stdlib signatures).
proc cssFnArity(fname: string, argc, minA, maxA: int) =
  ## Raise on wrong argument count with a precise expectation message.
  if argc < minA or argc > maxA:
    let want =
      if minA == maxA:
        $minA & " argument" & (if minA == 1: "" else: "s")
      else:
        $minA & ".." & $maxA & " arguments"
    raise newException(ValueError,
      fname & "() expects " & want & ", got " & $argc)
proc cssFnLengthZero(fname, what: string, v: Value): string =
  ## A <length-percentage> argument: typed lengths render via their tag,
  ## unitless zero is valid CSS and renders as "0", anything else errors.
  if v.typeId == ord(ttyLength):
    return valueToCssText(v)
  if v.typeId == ord(tyInt) and v.intVal == 0: return "0"
  if v.typeId == ord(tyFloat) and v.floatVal == 0.0: return "0"
  raise newException(ValueError, fname & "() expects a length for " &
    what & ", got " & valueToCssText(v))
proc cssFnAnyText(fname, what: string, v: Value,
    allowed: set[TypeKind]): string =
  ## A validated argument rendered to its canonical spelling: strictly
  ## typed values use their tag, primitives stringify, anything else
  ## errors. `allowed` is checked against the value's TypeKind.
  var kindOk = false
  for k in allowed:
    if v.typeId == ord(k):
      kindOk = true
      break
  if not kindOk:
    raise newException(ValueError, fname & "() got invalid " & what &
      " '" & valueToCssText(v) & "'")
  valueToCssText(v)
type FnArgSpec = enum
  ## Per-argument shape for data-driven function bodies. NOTE the two
  ## kind worlds: runtime color Values carry tyColor (libcolors), while
  ## Symbols use ttyColor. Never match runtime values against
  ## ord(ttyNumber): id 20 is a runtime color, not a number.
  faLength  # <length-percentage>: ttyLength or unitless zero
  faNumber  # unitless number (tyInt/tyFloat)
  faNumLen  # number or length (filter amounts like brightness(50%))
  faAngle   # <angle>: ttyAngle or unitless zero
  faColor   # color value (tyColor)
  faString  # bare keyword, stringified at parse time
proc checkFnArg(fname, what: string, v: Value, spec: FnArgSpec): string =
  case spec
  of faLength: cssFnLengthZero(fname, what, v)
  of faNumber:
    if v.typeId == ord(tyInt) or v.typeId == ord(tyFloat):
      valueToCssText(v)
    else:
      raise newException(ValueError, fname & "() expects a number for " &
        what & ", got " & valueToCssText(v))
  of faNumLen:
    if v.typeId == ord(tyInt) or v.typeId == ord(tyFloat) or
        v.typeId == ord(ttyLength):
      valueToCssText(v)
    else:
      raise newException(ValueError, fname &
        "() expects a number or length for " & what & ", got " &
        valueToCssText(v))
  of faAngle:
    if v.typeId == ord(ttyAngle):
      valueToCssText(v)
    elif (v.typeId == ord(tyInt) and v.intVal == 0) or
        (v.typeId == ord(tyFloat) and v.floatVal == 0.0):
      "0"
    else:
      raise newException(ValueError, fname & "() expects an angle for " &
        what & ", got " & valueToCssText(v))
  of faColor:
    if v.typeId == tyColor:
      valueToCssText(v)
    else:
      raise newException(ValueError, fname & "() expects a color for " &
        what & ", got " & valueToCssText(v))
  of faString:
    if v.typeId == ord(tyString):
      v.stringVal[]
    else:
      raise newException(ValueError, fname & "() got invalid keyword '" &
        valueToCssText(v) & "'")
type CssFnDesc = object
  returnKind: TypeKind
  sep: string
  minA, maxA: int
  specs: seq[FnArgSpec]
var cssFnTable = initTable[string, CssFnDesc]()
proc runtimeIdFor(kind: TypeKind): TypeId =
  ## Runtime Value id for a family kind. Colors use tyColor (id 20):
  ## id 18 (ord(ttyColor)) cannot inhabit a Value's objectVal branch
  ## (extension-boundary quirk), while 20 is the established runtime
  ## color id (see newBroColor). All other families use ord().
  if kind == ttyColor: tyColor
  else: ord(kind)
proc specImpl(fname: string, args: StackView, argc: int): Value =
  ## Shared body for fixed-shape functions: arity check, per-arg
  ## validation, canonical rendering with family kind. Descriptors live
  ## in a module table (closures cannot capture openArrays soundly).
  let d = cssFnTable[fname]
  cssFnArity(fname, argc, d.minA, d.maxA)
  var parts: seq[string]
  for i in 0 ..< argc:
    let spec = if i < d.specs.len: d.specs[i] else: d.specs[^1]
    parts.add(checkFnArg(fname, "argument " & $(i + 1), args[i], spec))
    result = initCssPayload(runtimeIdFor(d.returnKind),
      CssFunction(fname: fname), fname & "(" & parts.join(d.sep) & ")")


# drop-shadow(<length>{2,4} + optional color, space-joined)
proc dropShadowImpl(args: StackView, argc: int): Value =
  cssFnArity("drop-shadow", argc, 2, 5)
  var parts: seq[string]
  var lengths, colors = 0
  for i in 0 ..< argc:
    let v = args[i]
    if v.typeId == tyColor:
      parts.add(valueToCssText(v))
      inc colors
    elif v.typeId == ord(ttyLength) or v.typeId == ord(tyInt) or
        v.typeId == ord(tyFloat):
      parts.add(valueToCssText(v))
      inc lengths
    elif v.typeId == ord(tyString) and '(' in valueToCssText(v):
      # Pre-rendered static color call (`rgba(0,0,0,.5)`): counts as the
      # optional color; other strings still fail below as before.
      parts.add(valueToCssText(v))
      inc colors
    else:
      raise newException(ValueError,
        "drop-shadow() got invalid part '" & valueToCssText(v) & "'")
  if lengths < 2 or colors > 1:
    raise newException(ValueError,
      "drop-shadow() expects 2-4 lengths and an optional color, got " &
      $argc & " arguments")
  result = initCssPayload(ord(ttyFilter),
    CssFunction(fname: "drop-shadow"), "drop-shadow(" & parts.join(" ") & ")")

proc mkParams(n: int): seq[TempParamDef] =
  ## ttyAny params a0..an for one overload arity.
  for ai in 0 ..< n:
    result.add(paramDef("a" & $ai, ttyAny))

proc translate3dBody(args: StackView, argc: int): Value =
  specImpl("translate3d", args, argc)
proc translateBody(args: StackView, argc: int): Value =
  specImpl("translate", args, argc)
proc translateXBody(args: StackView, argc: int): Value =
  specImpl("translateX", args, argc)
proc translateYBody(args: StackView, argc: int): Value =
  specImpl("translateY", args, argc)
proc translateZBody(args: StackView, argc: int): Value =
  specImpl("translateZ", args, argc)
proc scaleBody(args: StackView, argc: int): Value =
  specImpl("scale", args, argc)
proc scaleXBody(args: StackView, argc: int): Value =
  specImpl("scaleX", args, argc)
proc scaleYBody(args: StackView, argc: int): Value =
  specImpl("scaleY", args, argc)
proc scaleZBody(args: StackView, argc: int): Value =
  specImpl("scaleZ", args, argc)
proc scale3dBody(args: StackView, argc: int): Value =
  specImpl("scale3d", args, argc)
proc rotateBody(args: StackView, argc: int): Value =
  specImpl("rotate", args, argc)
proc rotateXBody(args: StackView, argc: int): Value =
  specImpl("rotateX", args, argc)
proc rotateYBody(args: StackView, argc: int): Value =
  specImpl("rotateY", args, argc)
proc rotateZBody(args: StackView, argc: int): Value =
  specImpl("rotateZ", args, argc)
proc rotate3dBody(args: StackView, argc: int): Value =
  specImpl("rotate3d", args, argc)
proc skewBody(args: StackView, argc: int): Value =
  specImpl("skew", args, argc)
proc skewXBody(args: StackView, argc: int): Value =
  specImpl("skewX", args, argc)
proc skewYBody(args: StackView, argc: int): Value =
  specImpl("skewY", args, argc)
proc matrixBody(args: StackView, argc: int): Value =
  specImpl("matrix", args, argc)
proc matrix3dBody(args: StackView, argc: int): Value =
  specImpl("matrix3d", args, argc)
proc perspectiveBody(args: StackView, argc: int): Value =
  specImpl("perspective", args, argc)
proc blurBody(args: StackView, argc: int): Value =
  specImpl("blur", args, argc)
proc brightnessBody(args: StackView, argc: int): Value =
  specImpl("brightness", args, argc)
proc contrastBody(args: StackView, argc: int): Value =
  specImpl("contrast", args, argc)
proc grayscaleBody(args: StackView, argc: int): Value =
  specImpl("grayscale", args, argc)
proc invertBody(args: StackView, argc: int): Value =
  specImpl("invert", args, argc)
proc opacityBody(args: StackView, argc: int): Value =
  specImpl("opacity", args, argc)
proc saturateBody(args: StackView, argc: int): Value =
  specImpl("saturate", args, argc)
proc sepiaBody(args: StackView, argc: int): Value =
  specImpl("sepia", args, argc)
proc hue_rotateBody(args: StackView, argc: int): Value =
  specImpl("hue-rotate", args, argc)

const linearDirectionKeywords = ["to", "left", "right", "top", "bottom"]
const radialPreludeKeywords = ["circle", "ellipse", "at", "left", "right",
  "top", "bottom", "center", "closest-side", "closest-corner",
  "farthest-side", "farthest-corner", "contain", "cover"]
const conicPreludeKeywords = ["from", "at", "left", "right", "top",
  "bottom", "center"]
proc gradientImpl(fname: string, keywords: openArray[string],
    preludeLengths, preludeAngles: bool,
    args: StackView, argc: int): Value =
  ## [shape | direction | from/at prelude] + 1+ color stops. The prelude
  ## is a leading run of keyword strings (+lengths for radial sizes,
  ## +angles for linear/conic directions). Position hints (`red 50%`)
  ## arrive as separate args (space-splitting) and re-join with a space
  ## onto the preceding color stop.
  # NOTE the two kind worlds: runtime Values use tyColor (libcolors) for
  # colors while Symbols use ttyColor; lengths etc use ord(tty*) in both.
  # In particular id 20 is a runtime *color*, never compare it against
  # ord(ttyNumber).
  # Stops are unbounded by nature (striped gradients take a dozen+);
  # 24 keeps dispatch enumerable while covering real-world input.
  cssFnArity(fname, argc, 1, 24)
  var dirParts: seq[string]
  var i = 0
  while i < argc:
    if args[i].typeId == ord(tyString):
      let w = args[i].stringVal[]
      if '(' in w:
        # Pre-rendered static color call: not a direction keyword, hand
        # over to the stops loop below.
        break
      var ok = false
      for k in keywords:
        if w == k:
          ok = true
          break
      if not ok:
        raise newException(ValueError, fname &
          "() got invalid keyword '" & w & "'")
      dirParts.add(w)
    elif preludeLengths and (args[i].typeId == ord(ttyLength) or
        args[i].typeId == ord(tyInt) or args[i].typeId == ord(tyFloat)):
      dirParts.add(valueToCssText(args[i]))
    elif preludeAngles and args[i].typeId == ord(ttyAngle):
      dirParts.add(valueToCssText(args[i]))
    else:
      break
    inc i
  var stops: seq[string]
  var prevWasColor = false
  while i < argc:
    let v = args[i]
    if v.typeId == tyColor:
      stops.add(valueToCssText(v))
      prevWasColor = true
    elif v.typeId == ord(tyString) and '(' in valueToCssText(v):
      # Pre-rendered static color call (`rgba(0,0,0,.3)` keeps its source
      # spelling): a function spelling is a color for stop-joining, while
      # bare-word strings still fail validation below via the keyword path.
      stops.add(valueToCssText(v))
      prevWasColor = true
    elif v.typeId == ord(ttyLength) or v.typeId == ord(tyInt) or
        v.typeId == ord(tyFloat):
      # Length/percentage/number after a color (or another position) is
      # a stop position hint: space-join, not comma-separate.
      let t = valueToCssText(v)
      if prevWasColor or (stops.len > 0 and
          stops[^1].contains(' ')):
        stops[^1] = stops[^1] & " " & t
      else:
        stops.add(t)
      prevWasColor = false
    elif v.typeId == ord(ttyAngle):
      stops.add(valueToCssText(v))
      prevWasColor = false
    else:
      raise newException(ValueError, fname &
        "() got invalid color stop '" & valueToCssText(v) & "'")
    inc i
  if stops.len == 0:
    raise newException(ValueError,
      fname & "() needs at least one color stop")
  # Direction parts space-join among themselves, then comma-separate
  # from the stops: `linear-gradient(to right, red, blue)`.
  var rendered = dirParts.join(" ")
  if stops.len > 0:
    if rendered.len > 0: rendered &= ", "
    rendered &= stops.join(", ")
  result = initCssPayload(ord(ttyImage), CssFunction(fname: fname),
    fname & "(" & rendered & ")")

proc linearGradientImpl(fname: string, args: StackView,
    argc: int): Value =
  ## direction ([to <side>...] | <angle>, optional) + 1+ color stops.
  gradientImpl(fname, linearDirectionKeywords, false, true, args, argc)

const circlePreludeKeywords = ["at", "left", "right", "top", "bottom",
  "center"]
const insetPreludeKeywords = ["round"]
const polygonFillKeywords = ["nonzero", "evenodd"]
const rayPreludeKeywords = ["at", "left", "right", "top", "bottom",
  "center", "sides", "closest-side", "closest-corner", "farthest-side",
  "farthest-corner", "contain"]
proc shapeImpl(fname: string, keywords: openArray[string], minA, maxA: int,
    args: StackView, argc: int): Value =
  ## Prelude-only shapes (circle, ellipse, inset, xywh): lengths/numbers
  ## + keyword strings, space-joined, nothing else. Positional semantics
  ## (which length is x vs a radius) is unchecked by design.
  cssFnArity(fname, argc, minA, maxA)
  var parts: seq[string]
  for i in 0 ..< argc:
    let v = args[i]
    if v.typeId == ord(tyString):
      let w = v.stringVal[]
      var ok = false
      for k in keywords:
        if w == k:
          ok = true
          break
      if not ok:
        raise newException(ValueError, fname &
          "() got invalid keyword '" & w & "'")
      parts.add(w)
    elif v.typeId == ord(ttyLength) or v.typeId == ord(tyInt) or
        v.typeId == ord(tyFloat):
      parts.add(valueToCssText(v))
    else:
      raise newException(ValueError, fname & "() got invalid part '" &
        valueToCssText(v) & "'")
  result = initCssPayload(ord(ttyShape), CssFunction(fname: fname),
    fname & "(" & parts.join(" ") & ")")
proc polygonImpl(args: StackView, argc: int): Value =
  ## polygon([nonzero|evenodd,] x y, ...) — space-split pairs re-join
  ## with spaces, pairs comma-separate.
  cssFnArity("polygon", argc, 2, 10)
  var i = 0
  var head = ""
  if args[0].typeId == ord(tyString):
    let w = args[0].stringVal[]
    var ok = false
    for k in polygonFillKeywords:
      if w == k:
        ok = true
        break
    if not ok:
      raise newException(ValueError,
        "polygon() got invalid fill rule '" & w & "'")
    head = w
    inc i
  var pairs: seq[string]
  var cur: seq[string]
  while i < argc:
    let v = args[i]
    if v.typeId == ord(ttyLength) or v.typeId == ord(tyInt) or
        v.typeId == ord(tyFloat):
      cur.add(valueToCssText(v))
      if cur.len == 2:
        pairs.add(cur.join(" "))
        cur = @[]
    else:
      raise newException(ValueError, "polygon() got invalid coordinate '" &
        valueToCssText(v) & "'")
    inc i
  if cur.len > 0 or pairs.len == 0:
    raise newException(ValueError,
      "polygon() needs coordinate pairs (x y, ...)")
  var rendered = pairs.join(", ")
  if head.len > 0: rendered = head & ", " & rendered
  result = initCssPayload(ord(ttyShape), CssFunction(fname: "polygon"),
    "polygon(" & rendered & ")")
proc pathImpl(args: StackView, argc: int): Value =
  ## path("<string>") — the path data stays a quoted string.
  cssFnArity("path", argc, 1, 1)
  if args[0].typeId != ord(tyString):
    raise newException(ValueError, "path() expects a string, got " &
      valueToCssText(args[0]))
  result = initCssPayload(ord(ttyShape), CssFunction(fname: "path"),
    "path(\"" & args[0].stringVal[] & "\")")
proc rayImpl(args: StackView, argc: int): Value =
  ## ray(<angle> [at <position>]? [size|contain]?) — one angle, then
  ## validated keywords, space-joined.
  cssFnArity("ray", argc, 1, 4)
  if args[0].typeId != ord(ttyAngle):
    raise newException(ValueError, "ray() expects an angle first, got " &
      valueToCssText(args[0]))
  var parts = @[valueToCssText(args[0])]
  for i in 1 ..< argc:
    if args[i].typeId != ord(tyString):
      raise newException(ValueError, "ray() got invalid part '" &
        valueToCssText(args[i]) & "'")
    let w = args[i].stringVal[]
    var ok = false
    for k in rayPreludeKeywords:
      if w == k:
        ok = true
        break
    if not ok:
      raise newException(ValueError,
        "ray() got invalid keyword '" & w & "'")
    parts.add(w)
  result = initCssPayload(ord(ttyShape), CssFunction(fname: "ray"),
    "ray(" & parts.join(" ") & ")")
proc isNoneString(v: Value): bool =
  ## The `none` keyword arrives stringified (bare idents stringify).
  v.typeId == ord(tyString) and v.stringVal[] == "none"
proc colorComponent(fname, what: string, v: Value,
    allowAngle, allowPct: bool): string =
  ## One color-function component: numbers always, angles/percentages
  ## per family, `none` always, and dynamic var() references verbatim (a
  ## var may hold any single channel). Ranges are intentionally unchecked
  ## (CSS clamps out-of-range values; over-validation risks false positives).
  if v.typeId == ord(ttyCssVar):
    return valueToCssText(v)
  if v.typeId == ord(tyInt) or v.typeId == ord(tyFloat):
    return valueToCssText(v)
  if allowPct and v.typeId == ord(ttyLength):
    return valueToCssText(v)
  if allowAngle and v.typeId == ord(ttyAngle):
    return valueToCssText(v)
  if isNoneString(v):
    return "none"
  raise newException(ValueError, fname & "() got invalid " & what &
    " '" & valueToCssText(v) & "'")
proc colorAlpha(fname: string, v: Value): string =
  ## Alpha component: number, percentage, none, or a dynamic var().
  if v.typeId == ord(ttyCssVar):
    return valueToCssText(v)
  if v.typeId == ord(tyInt) or v.typeId == ord(tyFloat) or
      v.typeId == ord(ttyLength) or isNoneString(v):
    return valueToCssText(v)
  raise newException(ValueError, fname & "() got invalid alpha '" &
    valueToCssText(v) & "'")
proc colorFnImpl(fname: string, args: StackView, argc: int): Value =
  ## rgb/rgba/hsl/hsla/hwb/lab/lch/oklab/oklch/color: 3-4 components with
  ## an optional slash-alpha (the parser splices a trailing `a / b` infix
  ## into separate args). Comma-legacy and space-modern forms arrive
  ## identically (arg separators don't survive parsing) and render
  ## canonically: comma for 3-arg rgb-like, space+slash for 4-arg and
  ## modern-only families.
  # color() carries space/from prefix args, so its arity (4..7) is
  # validated inside its own branch; the rest take 3-4 components, plus
  # the dynamic triplet forms `rgb(var(--t))` / `rgba(var(--t), a)`.
  if fname != "color" and (argc == 1 or argc == 2):
    # A var triplet holds a textual channel list unknowable statically
    # (Bootstrap's `--*-rgb` pattern); render verbatim in both modes.
    # Fully static 1-2-arg calls are provable nonsense and keep the
    # standard arity error.
    if args[0].typeId != ord(ttyCssVar):
      cssFnArity(fname, argc, 3, 4)
    var rendered = valueToCssText(args[0])
    if argc == 2:
      rendered &= ", " & colorAlpha(fname, args[1])
    return initCssPayload(tyColor, CssFunction(fname: fname),
      fname & "(" & rendered & ")")
  if fname != "color":
    cssFnArity(fname, argc, 3, 4)
  var comps: seq[string]
  case fname
  of "rgb", "rgba":
    for i in 0 ..< min(argc, 3):
      comps.add(colorComponent(fname, "channel", args[i], false, true))
  of "hsl", "hsla":
    if argc > 0:
      comps.add(colorComponent(fname, "hue", args[0], true, false))
    for i in 1 ..< min(argc, 3):
      comps.add(colorComponent(fname, "saturation/lightness", args[i],
        false, true))
  of "hwb":
    if argc > 0:
      comps.add(colorComponent(fname, "hue", args[0], true, false))
    for i in 1 ..< min(argc, 3):
      comps.add(colorComponent(fname, "whiteness/blackness", args[i],
        false, true))
  of "lab", "oklab":
    # lightness (number|percentage), then two plain numbers
    if argc > 0:
      comps.add(colorComponent(fname, "lightness", args[0], false, true))
    for i in 1 ..< min(argc, 3):
      comps.add(colorComponent(fname, "component", args[i], false, false))
  of "lch", "oklch":
    # lightness (number|percentage), chroma (number), hue (number|angle)
    if argc > 0:
      comps.add(colorComponent(fname, "lightness", args[0], false, true))
    if argc > 1:
      comps.add(colorComponent(fname, "chroma", args[1], false, false))
    if argc > 2:
      comps.add(colorComponent(fname, "hue", args[2], true, false))
  of "color":
    # color([from <color>] space c1 c2 c3 [/ a]): the space/from prefix
    # breaks argc-based alpha detection, so render here and return.
    var i = 0
    var prefix = ""
    if argc >= 2 and args[0].typeId == ord(tyString) and
        args[0].stringVal[] == "from" and args[1].typeId == tyColor:
      prefix = "from " & valueToCssText(args[1]) & " "
      i = 2
    if i >= argc or args[i].typeId != ord(tyString):
      raise newException(ValueError,
        fname & "() expects a color space name")
    let space = args[i].stringVal[]
    i += 1
    if argc - i < 3 or argc - i > 4:
      raise newException(ValueError, fname &
        "() needs 3 channels and an optional alpha")
    var ch: seq[string]
    for j in 0 .. 2:
      ch.add(colorComponent(fname, "channel", args[i + j], false, true))
    var rendered = prefix & space & " " & ch.join(" ")
    if argc - i == 4:
      rendered &= " / " & colorAlpha(fname, args[i + 3])
    return initCssPayload(tyColor, CssFunction(fname: fname),
      fname & "(" & rendered & ")")
  else:
    raise newException(ValueError, "unsupported color function " & fname)
  var rendered: string
  if argc == 4:
    let a = colorAlpha(fname, args[3])
    if fname in ["rgba", "hsla"]:
      rendered = comps.join(", ") & ", " & a
    else:
      rendered = comps.join(" ") & " / " & a
  else:
    if fname in ["hwb", "lab", "lch", "oklab", "oklch"]:
      rendered = comps.join(" ")
    else:
      rendered = comps.join(", ")
  result = initCssPayload(tyColor, CssFunction(fname: fname),
    fname & "(" & rendered & ")")
proc colorMixImpl(fname: string, args: StackView, argc: int): Value =
  ## color-mix(in <space>, color [pct]?, color [pct]?): the `in <space>`
  ## prefix arrives stringified (see parseColorMixCall), percentages
  ## space-join onto their color like gradient stops.
  cssFnArity(fname, argc, 4, 6)
  if args[0].typeId != ord(tyString) or args[0].stringVal[] != "in" or
      args[1].typeId != ord(tyString):
    raise newException(ValueError, fname &
      "() expects `in <colorspace>, <color>, <color>`")
  let space = args[1].stringVal[]
  var parts: seq[string]
  var colors = 0
  var i = 2
  while i < argc:
    let v = args[i]
    if v.typeId == tyColor:
      parts.add(valueToCssText(v))
      inc colors
    elif (v.typeId == ord(ttyLength) or v.typeId == ord(tyInt) or
        v.typeId == ord(tyFloat)) and parts.len > 0:
      parts[^1] = parts[^1] & " " & valueToCssText(v)
    else:
      raise newException(ValueError, fname & "() got invalid part '" &
        valueToCssText(v) & "'")
    inc i
  if colors != 2:
    raise newException(ValueError,
      fname & "() needs exactly two colors")
  result = initCssPayload(tyColor, CssFunction(fname: fname),
    fname & "(in " & space & ", " & parts.join(", ") & ")")
proc imageImpl(args: StackView, argc: int): Value =
  ## image([<string> | <color>][, ...]) — sources with optional fallback
  ## color stay verbatim; no shape validation beyond kinds.
  cssFnArity("image", argc, 1, 2)
  var parts: seq[string]
  for i in 0 ..< argc:
    let v = args[i]
    if v.typeId == ord(tyString):
      # Quoted sources re-quote (valueToCssText renders strings raw).
      # image() takes no bare keywords, so every string here was quoted.
      parts.add("\"" & v.stringVal[] & "\"")
    elif v.typeId == tyColor:
      parts.add(valueToCssText(v))
    else:
      raise newException(ValueError, "image() got invalid part '" &
        valueToCssText(v) & "'")
  result = initCssPayload(ord(ttyImage), CssFunction(fname: "image"),
    "image(" & parts.join(", ") & ")")
proc imageSetImpl(args: StackView, argc: int): Value =
  ## image-set("a" 1x, ...) — string/resolution pairs re-join with
  ## spaces, pairs comma-separate (same pair pattern as polygon).
  cssFnArity("image-set", argc, 2, 8)
  var pairs: seq[string]
  var cur: seq[string]
  var i = 0
  proc isResolutionText(s: string): bool =
    ## `1x` is not a known unit suffix (plain string at runtime); dppx
    ## and friends are typed resolutions. Accept both spellings here.
    const units = ["x", "dppx", "dpi", "dpcm"]
    for u in units:
      if s.len > u.len and s.endsWith(u):
        var ok = true
        for ch in s[0 ..< s.len - u.len]:
          if ch notin {'0'..'9', '.'}:
            ok = false
            break
        if ok: return true
    false
  while i < argc:
    let v = args[i]
    if v.typeId == ord(tyString) and not isResolutionText(v.stringVal[]):
      if cur.len > 0:
        raise newException(ValueError,
          "image-set() needs string/resolution pairs")
      cur.add("\"" & v.stringVal[] & "\"")
    elif v.typeId == ord(ttyResolution) or
        (v.typeId == ord(tyString) and isResolutionText(v.stringVal[])):
      if cur.len != 1:
        raise newException(ValueError,
          "image-set() needs string/resolution pairs")
      cur.add(valueToCssText(v))
      pairs.add(cur.join(" "))
      cur = @[]
    elif (v.typeId == ord(tyInt) or v.typeId == ord(tyFloat)) and
        i + 1 < argc and args[i + 1].typeId == ord(tyString) and
        args[i + 1].stringVal[] == "x":
      # Spaced `1 "x"`: the only split form left now that the lexer
      # glues adjacent `1x` into one token; reassemble the resolution here.
      if cur.len != 1:
        raise newException(ValueError,
          "image-set() needs string/resolution pairs")
      cur.add(valueToCssText(v) & "x")
      pairs.add(cur.join(" "))
      cur = @[]
      inc i
    else:
      raise newException(ValueError, "image-set() got invalid part '" &
        valueToCssText(v) & "'")
    inc i
  if cur.len > 0 or pairs.len == 0:
    raise newException(ValueError,
      "image-set() needs string/resolution pairs")
  result = initCssPayload(ord(ttyImage), CssFunction(fname: "image-set"),
    "image-set(" & pairs.join(", ") & ")")
proc easingLinearImpl(args: StackView, argc: int): Value =
  ## linear() easing: number/length stops; a length after a number is a
  ## stop position (`linear(0, 0.5 50%, 1)`), otherwise comma-separate.
  cssFnArity("linear", argc, 1, 6)
  var stops: seq[string]
  var prevWasNumber = false
  for i in 0 ..< argc:
    let v = args[i]
    if v.typeId == ord(tyInt) or v.typeId == ord(tyFloat):
      stops.add(valueToCssText(v))
      prevWasNumber = true
    elif v.typeId == ord(ttyLength):
      let t = valueToCssText(v)
      if prevWasNumber:
        stops[^1] = stops[^1] & " " & t
      else:
        stops.add(t)
      prevWasNumber = false
    else:
      raise newException(ValueError, "linear() got invalid stop '" &
        valueToCssText(v) & "'")
  result = initCssPayload(ord(ttyEasing), CssFunction(fname: "linear"),
    "linear(" & stops.join(", ") & ")")

proc initCssTypes*(script: Script, systemModule: Module): Module =
  result = newModule("cssTypes", some"std::cssTypes")
  result.load(systemModule)

  let symLength = genType(ttyLength, "length", true)
  result.add(symLength)
  discard result.addType(symLength, newIdent("ttyLength"))
  let symAngle = genType(ttyAngle, "angle", true)
  result.add(symAngle)
  discard result.addType(symAngle, newIdent("ttyAngle"))
  let symTime = genType(ttyTime, "time", true)
  result.add(symTime)
  discard result.addType(symTime, newIdent("ttyTime"))
  let symRes = genType(ttyResolution, "resolution", true)
  result.add(symRes)
  discard result.addType(symRes, newIdent("ttyResolution"))
  let symFlex = genType(ttyFlex, "flex", true)
  result.add(symFlex)
  discard result.addType(symFlex, newIdent("ttyFlex"))
  if not result.typeDefs.hasKey("number"):
    let symNum = genType(ttyNumber, "number", true)
    result.add(symNum)
    discard result.addType(symNum, newIdent("ttyNumber"))
  if not result.typeDefs.hasKey("color"):
    # Display name is "cssColor", NOT "color": the module sym table holds
    # one entry per name, and the color() *function* must win lookup for
    # isBroCall (a type named "color" would shadow it into the static
    # verbatim path). addType still keys the "ttyColor" ident used for
    # param/return resolution.
    let symCol = genType(ttyColor, "cssColor", true)
    result.add(symCol)
    discard result.addType(symCol, newIdent("ttyColor"))

  let tLen = result.typeDefs["length"]
  script.addProc(result, "+", @[paramDef("a", ttyLength, sym = tLen), paramDef("b", ttyLength, sym = tLen)], ttyLength,
    proc (args: StackView, argc: int): Value =
      let a = toCssSize(args[0])
      let b = toCssSize(args[1])
      if a.unit != b.unit:
        raise newException(ValueError, "Mismatched units for '+': '" & a.unit & "' vs '" & b.unit & "'")
      result = initCssPayload(ord(ttyLength), CssSize(val: a.val + b.val, unit: a.unit), cssNumStr(a.val + b.val) & a.unit)
  )
  script.addProc(result, "-", @[paramDef("a", ttyLength, sym = tLen), paramDef("b", ttyLength, sym = tLen)], ttyLength,
    proc (args: StackView, argc: int): Value =
      let a = toCssSize(args[0])
      let b = toCssSize(args[1])
      if a.unit != b.unit:
        raise newException(ValueError, "Mismatched units for '-': '" & a.unit & "' vs '" & b.unit & "'")
      result = initCssPayload(ord(ttyLength), CssSize(val: a.val - b.val, unit: a.unit), cssNumStr(a.val - b.val) & a.unit)
  )
  script.addProc(result, "echo", @[paramDef("x", ttyLength, sym = tLen)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      echo cssSizeToString(args[0])
  )
  script.addProc(result, "toString", @[paramDef("x", ttyLength, sym = tLen)], ttyString,
    proc (args: StackView, argc: int): Value =
      result = initValue(cssSizeToString(args[0]))
  )

  let tAngle = result.typeDefs["angle"]
  script.addProc(result, "+", @[paramDef("a", ttyAngle, sym = tAngle), paramDef("b", ttyAngle, sym = tAngle)], ttyAngle,
    proc (args: StackView, argc: int): Value =
      let a = toCssAngle(args[0])
      let b = toCssAngle(args[1])
      if a.unit != b.unit:
        raise newException(ValueError, "Mismatched units for '+': '" & a.unit & "' vs '" & b.unit & "'")
      result = initCssPayload(ord(ttyAngle), CssAngle(val: a.val + b.val, unit: a.unit), cssNumStr(a.val + b.val) & a.unit)
  )
  script.addProc(result, "-", @[paramDef("a", ttyAngle, sym = tAngle), paramDef("b", ttyAngle, sym = tAngle)], ttyAngle,
    proc (args: StackView, argc: int): Value =
      let a = toCssAngle(args[0])
      let b = toCssAngle(args[1])
      if a.unit != b.unit:
        raise newException(ValueError, "Mismatched units for '-': '" & a.unit & "' vs '" & b.unit & "'")
      result = initCssPayload(ord(ttyAngle), CssAngle(val: a.val - b.val, unit: a.unit), cssNumStr(a.val - b.val) & a.unit)
  )
  script.addProc(result, "echo", @[paramDef("x", ttyAngle, sym = tAngle)], ttyVoid,
    proc (args: StackView, argc: int): Value = echo cssAngleToString(args[0]))
  script.addProc(result, "toString", @[paramDef("x", ttyAngle, sym = tAngle)], ttyString,
    proc (args: StackView, argc: int): Value = result = initValue(cssAngleToString(args[0])))

  let tTime = result.typeDefs["time"]
  script.addProc(result, "+", @[paramDef("a", ttyTime, sym = tTime), paramDef("b", ttyTime, sym = tTime)], ttyTime,
    proc (args: StackView, argc: int): Value =
      let a = toCssTime(args[0])
      let b = toCssTime(args[1])
      if a.unit != b.unit:
        raise newException(ValueError, "Mismatched units for '+': '" & a.unit & "' vs '" & b.unit & "'")
      result = initCssPayload(ord(ttyTime), CssTime(val: a.val + b.val, unit: a.unit), cssNumStr(a.val + b.val) & a.unit)
  )
  script.addProc(result, "-", @[paramDef("a", ttyTime, sym = tTime), paramDef("b", ttyTime, sym = tTime)], ttyTime,
    proc (args: StackView, argc: int): Value =
      let a = toCssTime(args[0])
      let b = toCssTime(args[1])
      if a.unit != b.unit:
        raise newException(ValueError, "Mismatched units for '-': '" & a.unit & "' vs '" & b.unit & "'")
      result = initCssPayload(ord(ttyTime), CssTime(val: a.val - b.val, unit: a.unit), cssNumStr(a.val - b.val) & a.unit)
  )
  script.addProc(result, "echo", @[paramDef("x", ttyTime, sym = tTime)], ttyVoid,
    proc (args: StackView, argc: int): Value = echo cssTimeToString(args[0]))
  script.addProc(result, "toString", @[paramDef("x", ttyTime, sym = tTime)], ttyString,
    proc (args: StackView, argc: int): Value = result = initValue(cssTimeToString(args[0])))

  # Explicit string -> typed constructors (also used by codegen for unit
  # literals, so `4px` is a length value at runtime instead of a string).
  script.addProc(result, "parseLength", @[paramDef("s", ttyString)], ttyLength,
    proc (args: StackView, argc: int): Value =
      result = newCssSize(args[0].stringVal[]))
  script.addProc(result, "parseAngle", @[paramDef("s", ttyString)], ttyAngle,
    proc (args: StackView, argc: int): Value =
      result = newCssAngle(args[0].stringVal[]))
  script.addProc(result, "parseTime", @[paramDef("s", ttyString)], ttyTime,
    proc (args: StackView, argc: int): Value =
      result = newCssTime(args[0].stringVal[]))
  script.addProc(result, "parseResolution", @[paramDef("s", ttyString)], ttyResolution,
    proc (args: StackView, argc: int): Value =
      result = newCssResolution(args[0].stringVal[]))
  script.addProc(result, "parseFlex", @[paramDef("s", ttyString)], ttyFlex,
    proc (args: StackView, argc: int): Value =
      result = newCssFlex(args[0].stringVal[]))

  let tRes = result.typeDefs["resolution"]
  script.addProc(result, "echo", @[paramDef("x", ttyResolution, sym = tRes)], ttyVoid,
    proc (args: StackView, argc: int): Value = echo cssResolutionToString(args[0]))
  script.addProc(result, "toString", @[paramDef("x", ttyResolution, sym = tRes)], ttyString,
    proc (args: StackView, argc: int): Value = result = initValue(cssResolutionToString(args[0])))

  let tFlex = result.typeDefs["flex"]
  script.addProc(result, "echo", @[paramDef("x", ttyFlex, sym = tFlex)], ttyFlex,
    proc (args: StackView, argc: int): Value = echo cssFlexToString(args[0]))
  script.addProc(result, "toString", @[paramDef("x", ttyFlex, sym = tFlex)], ttyString,
    proc (args: StackView, argc: int): Value = result = initValue(cssFlexToString(args[0])))

  let symCssVar = genType(ttyCssVar, "cssvar", true)
  result.add(symCssVar)
  discard result.addType(symCssVar, newIdent("ttyCssVar"))

  # Type symbols for the CSS function families (append-only kinds declared
  # in vancodegen's extendSym block). One trio per kind, mirroring cssvar.
  let symTransform = genType(ttyTransform, "transform", true)
  result.add(symTransform)
  discard result.addType(symTransform, newIdent("ttyTransform"))
  let symFilter = genType(ttyFilter, "filter", true)
  result.add(symFilter)
  discard result.addType(symFilter, newIdent("ttyFilter"))
  let symImage = genType(ttyImage, "image", true)
  result.add(symImage)
  discard result.addType(symImage, newIdent("ttyImage"))
  let symShape = genType(ttyShape, "shape", true)
  result.add(symShape)
  discard result.addType(symShape, newIdent("ttyShape"))
  let symEasing = genType(ttyEasing, "easing", true)
  result.add(symEasing)
  discard result.addType(symEasing, newIdent("ttyEasing"))

  # CSS var() references as strictly typed values: `var(--x)` parses as a
  # real call so custom-property names stay atomic (never re-split by the
  # named-color normalizer) and use sites type-check structurally.
  script.addProc(result, "var", @[paramDef("name", ttyString)], ttyCssVar,
    proc (args: StackView, argc: int): Value =
      let name = args[0].stringVal[]
      if not name.startsWith("--"):
        raise newException(ValueError, "var() expects a custom property name starting with '--', got '" & name & "'")
      result = initCssPayload(ord(ttyCssVar), CssVar(name: name, fallback: ""),
        "var(" & name & ")")
  )
  script.addProc(result, "var", @[paramDef("name", ttyString), paramDef("fallback", ttyAny)], ttyCssVar,
    proc (args: StackView, argc: int): Value =
      let name = args[0].stringVal[]
      if not name.startsWith("--"):
        raise newException(ValueError, "var() expects a custom property name starting with '--', got '" & name & "'")
      let fb = valueToCssText(args[1])
      result = initCssPayload(ord(ttyCssVar), CssVar(name: name, fallback: fb),
        "var(" & name & ", " & fb & ")")
  )


  # ---- Transforms (all -> ttyTransform) ----
  cssFnTable["translate3d"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 3, maxA: 3, specs: @[faLength, faLength, faLength])
  for arity in 3 .. 3:
    script.addProc(result, "translate3d", mkParams(arity), ttyTransform, translate3dBody)
  cssFnTable["translate"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 1, maxA: 2, specs: @[faLength])
  for arity in 1 .. 2:
    script.addProc(result, "translate", mkParams(arity), ttyTransform, translateBody)
  cssFnTable["translateX"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 1, maxA: 1, specs: @[faLength])
  for arity in 1 .. 1:
    script.addProc(result, "translateX", mkParams(arity), ttyTransform, translateXBody)
  cssFnTable["translateY"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 1, maxA: 1, specs: @[faLength])
  for arity in 1 .. 1:
    script.addProc(result, "translateY", mkParams(arity), ttyTransform, translateYBody)
  cssFnTable["translateZ"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 1, maxA: 1, specs: @[faLength])
  for arity in 1 .. 1:
    script.addProc(result, "translateZ", mkParams(arity), ttyTransform, translateZBody)
  cssFnTable["scale"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 1, maxA: 2, specs: @[faNumber])
  for arity in 1 .. 2:
    script.addProc(result, "scale", mkParams(arity), ttyTransform, scaleBody)
  cssFnTable["scaleX"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 1, maxA: 1, specs: @[faNumber])
  for arity in 1 .. 1:
    script.addProc(result, "scaleX", mkParams(arity), ttyTransform, scaleXBody)
  cssFnTable["scaleY"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 1, maxA: 1, specs: @[faNumber])
  for arity in 1 .. 1:
    script.addProc(result, "scaleY", mkParams(arity), ttyTransform, scaleYBody)
  cssFnTable["scaleZ"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 1, maxA: 1, specs: @[faNumber])
  for arity in 1 .. 1:
    script.addProc(result, "scaleZ", mkParams(arity), ttyTransform, scaleZBody)
  cssFnTable["scale3d"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 3, maxA: 3, specs: @[faNumber])
  for arity in 3 .. 3:
    script.addProc(result, "scale3d", mkParams(arity), ttyTransform, scale3dBody)
  cssFnTable["rotate"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 1, maxA: 1, specs: @[faAngle])
  for arity in 1 .. 1:
    script.addProc(result, "rotate", mkParams(arity), ttyTransform, rotateBody)
  cssFnTable["rotateX"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 1, maxA: 1, specs: @[faAngle])
  for arity in 1 .. 1:
    script.addProc(result, "rotateX", mkParams(arity), ttyTransform, rotateXBody)
  cssFnTable["rotateY"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 1, maxA: 1, specs: @[faAngle])
  for arity in 1 .. 1:
    script.addProc(result, "rotateY", mkParams(arity), ttyTransform, rotateYBody)
  cssFnTable["rotateZ"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 1, maxA: 1, specs: @[faAngle])
  for arity in 1 .. 1:
    script.addProc(result, "rotateZ", mkParams(arity), ttyTransform, rotateZBody)
  cssFnTable["rotate3d"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 4, maxA: 4, specs: @[faNumber, faNumber, faNumber, faAngle])
  for arity in 4 .. 4:
    script.addProc(result, "rotate3d", mkParams(arity), ttyTransform, rotate3dBody)
  cssFnTable["skew"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 1, maxA: 2, specs: @[faAngle])
  for arity in 1 .. 2:
    script.addProc(result, "skew", mkParams(arity), ttyTransform, skewBody)
  cssFnTable["skewX"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 1, maxA: 1, specs: @[faAngle])
  for arity in 1 .. 1:
    script.addProc(result, "skewX", mkParams(arity), ttyTransform, skewXBody)
  cssFnTable["skewY"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 1, maxA: 1, specs: @[faAngle])
  for arity in 1 .. 1:
    script.addProc(result, "skewY", mkParams(arity), ttyTransform, skewYBody)
  cssFnTable["matrix"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 6, maxA: 6, specs: @[faNumber])
  for arity in 6 .. 6:
    script.addProc(result, "matrix", mkParams(arity), ttyTransform, matrixBody)
  cssFnTable["matrix3d"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 16, maxA: 16, specs: @[faNumber])
  for arity in 16 .. 16:
    script.addProc(result, "matrix3d", mkParams(arity), ttyTransform, matrix3dBody)
  cssFnTable["perspective"] = CssFnDesc(returnKind: ttyTransform, sep: ", ", minA: 1, maxA: 1, specs: @[faLength])
  for arity in 1 .. 1:
    script.addProc(result, "perspective", mkParams(arity), ttyTransform, perspectiveBody)

  # ---- Filters (all -> ttyFilter) ----
  # blur(<length>?): 0 args renders bare blur()
  cssFnTable["blur"] = CssFnDesc(returnKind: ttyFilter, sep: ", ", minA: 0, maxA: 1, specs: @[faLength])
  for arity in 0 .. 1:
    script.addProc(result, "blur", mkParams(arity), ttyFilter, blurBody)
  cssFnTable["brightness"] = CssFnDesc(returnKind: ttyFilter, sep: ", ", minA: 1, maxA: 1, specs: @[faNumLen])
  for arity in 1 .. 1:
    script.addProc(result, "brightness", mkParams(arity), ttyFilter, brightnessBody)
  cssFnTable["contrast"] = CssFnDesc(returnKind: ttyFilter, sep: ", ", minA: 1, maxA: 1, specs: @[faNumLen])
  for arity in 1 .. 1:
    script.addProc(result, "contrast", mkParams(arity), ttyFilter, contrastBody)
  cssFnTable["grayscale"] = CssFnDesc(returnKind: ttyFilter, sep: ", ", minA: 1, maxA: 1, specs: @[faNumLen])
  for arity in 1 .. 1:
    script.addProc(result, "grayscale", mkParams(arity), ttyFilter, grayscaleBody)
  cssFnTable["invert"] = CssFnDesc(returnKind: ttyFilter, sep: ", ", minA: 1, maxA: 1, specs: @[faNumLen])
  for arity in 1 .. 1:
    script.addProc(result, "invert", mkParams(arity), ttyFilter, invertBody)
  cssFnTable["opacity"] = CssFnDesc(returnKind: ttyFilter, sep: ", ", minA: 1, maxA: 1, specs: @[faNumLen])
  for arity in 1 .. 1:
    script.addProc(result, "opacity", mkParams(arity), ttyFilter, opacityBody)
  cssFnTable["saturate"] = CssFnDesc(returnKind: ttyFilter, sep: ", ", minA: 1, maxA: 1, specs: @[faNumLen])
  for arity in 1 .. 1:
    script.addProc(result, "saturate", mkParams(arity), ttyFilter, saturateBody)
  cssFnTable["sepia"] = CssFnDesc(returnKind: ttyFilter, sep: ", ", minA: 1, maxA: 1, specs: @[faNumLen])
  for arity in 1 .. 1:
    script.addProc(result, "sepia", mkParams(arity), ttyFilter, sepiaBody)
  cssFnTable["hue-rotate"] = CssFnDesc(returnKind: ttyFilter, sep: ", ", minA: 1, maxA: 1, specs: @[faAngle])
  for arity in 1 .. 1:
    script.addProc(result, "hue-rotate", mkParams(arity), ttyFilter, hue_rotateBody)
  for arity in 2 .. 5:
    var params: seq[TempParamDef]
    for ai in 0 ..< arity:
      params.add(paramDef("a" & $ai, ttyAny))
    script.addProc(result, "drop-shadow", params, ttyFilter,
      proc (args: StackView, argc: int): Value = dropShadowImpl(args, argc))

  for arity in 1 .. 24:
    var params: seq[TempParamDef]
    for ai in 0 ..< arity:
      params.add(paramDef("a" & $ai, ttyAny))
    script.addProc(result, "linear-gradient", params, ttyImage,
      proc (args: StackView, argc: int): Value =
        linearGradientImpl("linear-gradient", args, argc))
    script.addProc(result, "repeating-linear-gradient", params, ttyImage,
      proc (args: StackView, argc: int): Value =
        linearGradientImpl("repeating-linear-gradient", args, argc))
  for arity in 1 .. 24:
    var params: seq[TempParamDef]
    for ai in 0 ..< arity:
      params.add(paramDef("a" & $ai, ttyAny))
    script.addProc(result, "radial-gradient", params, ttyImage,
      proc (args: StackView, argc: int): Value =
        gradientImpl("radial-gradient", radialPreludeKeywords, true, false,
          args, argc))
    script.addProc(result, "repeating-radial-gradient", params, ttyImage,
      proc (args: StackView, argc: int): Value =
        gradientImpl("repeating-radial-gradient", radialPreludeKeywords,
          true, false, args, argc))
  for arity in 1 .. 24:
    var params: seq[TempParamDef]
    for ai in 0 ..< arity:
      params.add(paramDef("a" & $ai, ttyAny))
    script.addProc(result, "conic-gradient", params, ttyImage,
      proc (args: StackView, argc: int): Value =
        gradientImpl("conic-gradient", conicPreludeKeywords, false, true,
          args, argc))
    script.addProc(result, "repeating-conic-gradient", params, ttyImage,
      proc (args: StackView, argc: int): Value =
        gradientImpl("repeating-conic-gradient", conicPreludeKeywords,
          false, true, args, argc))

  # ---- Shapes (all -> ttyShape) ----
  for arity in 0 .. 4:
    var params: seq[TempParamDef]
    for ai in 0 ..< arity:
      params.add(paramDef("a" & $ai, ttyAny))
    script.addProc(result, "circle", params, ttyShape,
      proc (args: StackView, argc: int): Value =
        shapeImpl("circle", circlePreludeKeywords, 0, 4, args, argc))
  for arity in 0 .. 5:
    var params: seq[TempParamDef]
    for ai in 0 ..< arity:
      params.add(paramDef("a" & $ai, ttyAny))
    script.addProc(result, "ellipse", params, ttyShape,
      proc (args: StackView, argc: int): Value =
        shapeImpl("ellipse", circlePreludeKeywords, 0, 5, args, argc))
  for arity in 1 .. 9:
    var params: seq[TempParamDef]
    for ai in 0 ..< arity:
      params.add(paramDef("a" & $ai, ttyAny))
    script.addProc(result, "inset", params, ttyShape,
      proc (args: StackView, argc: int): Value =
        shapeImpl("inset", insetPreludeKeywords, 1, 9, args, argc))
    script.addProc(result, "xywh", params, ttyShape,
      proc (args: StackView, argc: int): Value =
        shapeImpl("xywh", insetPreludeKeywords, 1, 9, args, argc))
  for arity in 2 .. 10:
    var params: seq[TempParamDef]
    for ai in 0 ..< arity:
      params.add(paramDef("a" & $ai, ttyAny))
    script.addProc(result, "polygon", params, ttyShape,
      proc (args: StackView, argc: int): Value = polygonImpl(args, argc))
  script.addProc(result, "path", @[paramDef("d", ttyAny)], ttyShape,
    proc (args: StackView, argc: int): Value = pathImpl(args, argc))
  for arity in 1 .. 4:
    var params: seq[TempParamDef]
    for ai in 0 ..< arity:
      params.add(paramDef("a" & $ai, ttyAny))
    script.addProc(result, "ray", params, ttyShape,
      proc (args: StackView, argc: int): Value = rayImpl(args, argc))

  # ---- Easing (all -> ttyEasing) ----
  cssFnTable["cubic-bezier"] = CssFnDesc(returnKind: ttyEasing, sep: ", ",
    minA: 4, maxA: 4, specs: @[faNumber, faNumber, faNumber, faNumber])
  for arity in 4 .. 4:
    script.addProc(result, "cubic-bezier", mkParams(arity), ttyEasing,
      proc (args: StackView, argc: int): Value =
        specImpl("cubic-bezier", args, argc))
  cssFnTable["steps"] = CssFnDesc(returnKind: ttyEasing, sep: ", ",
    minA: 1, maxA: 2, specs: @[faNumber, faString])
  for arity in 1 .. 2:
    script.addProc(result, "steps", mkParams(arity), ttyEasing,
      proc (args: StackView, argc: int): Value =
        specImpl("steps", args, argc))
  for arity in 1 .. 6:
    var params: seq[TempParamDef]
    for ai in 0 ..< arity:
      params.add(paramDef("a" & $ai, ttyAny))
    script.addProc(result, "linear", params, ttyEasing,
      proc (args: StackView, argc: int): Value = easingLinearImpl(args, argc))

  # ---- Images (remainder -> ttyImage) ----
  for arity in 1 .. 2:
    var params: seq[TempParamDef]
    for ai in 0 ..< arity:
      params.add(paramDef("a" & $ai, ttyAny))
    script.addProc(result, "image", params, ttyImage,
      proc (args: StackView, argc: int): Value = imageImpl(args, argc))
  for arity in 2 .. 8:
    var params: seq[TempParamDef]
    for ai in 0 ..< arity:
      params.add(paramDef("a" & $ai, ttyAny))
    script.addProc(result, "image-set", params, ttyImage,
      proc (args: StackView, argc: int): Value = imageSetImpl(args, argc))

  # ---- Colors (all -> ttyColor) ----
  # 1..2 cover the dynamic triplet forms (rgb(var(--t)), rgba(var(--t), a));
  # static 1-2-arg calls still fail inside colorFnImpl's arity check.
  for arity in 1 .. 4:
    var params: seq[TempParamDef]
    for ai in 0 ..< arity:
      params.add(paramDef("a" & $ai, ttyAny))
    script.addProc(result, "rgb", params, ttyColor,
      proc (args: StackView, argc: int): Value =
        colorFnImpl("rgb", args, argc))
    script.addProc(result, "rgba", params, ttyColor,
      proc (args: StackView, argc: int): Value =
        colorFnImpl("rgba", args, argc))
    script.addProc(result, "hsl", params, ttyColor,
      proc (args: StackView, argc: int): Value =
        colorFnImpl("hsl", args, argc))
    script.addProc(result, "hsla", params, ttyColor,
      proc (args: StackView, argc: int): Value =
        colorFnImpl("hsla", args, argc))
    script.addProc(result, "hwb", params, ttyColor,
      proc (args: StackView, argc: int): Value =
        colorFnImpl("hwb", args, argc))
    script.addProc(result, "lab", params, ttyColor,
      proc (args: StackView, argc: int): Value =
        colorFnImpl("lab", args, argc))
    script.addProc(result, "lch", params, ttyColor,
      proc (args: StackView, argc: int): Value =
        colorFnImpl("lch", args, argc))
    script.addProc(result, "oklab", params, ttyColor,
      proc (args: StackView, argc: int): Value =
        colorFnImpl("oklab", args, argc))
    script.addProc(result, "oklch", params, ttyColor,
      proc (args: StackView, argc: int): Value =
        colorFnImpl("oklch", args, argc))
  for arity in 4 .. 7:
    var params: seq[TempParamDef]
    for ai in 0 ..< arity:
      params.add(paramDef("a" & $ai, ttyAny))
    script.addProc(result, "color", params, ttyColor,
      proc (args: StackView, argc: int): Value =
        colorFnImpl("color", args, argc))
  cssFnTable["light-dark"] = CssFnDesc(returnKind: ttyColor, sep: ", ",
    minA: 2, maxA: 2, specs: @[faColor, faColor])
  for arity in 2 .. 2:
    script.addProc(result, "light-dark", mkParams(arity), ttyColor,
      proc (args: StackView, argc: int): Value =
        specImpl("light-dark", args, argc))
  for arity in 4 .. 6:
    var params: seq[TempParamDef]
    for ai in 0 ..< arity:
      params.add(paramDef("a" & $ai, ttyAny))
    script.addProc(result, "color-mix", params, ttyColor,
      proc (args: StackView, argc: int): Value =
        colorMixImpl("color-mix", args, argc))
