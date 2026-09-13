# Shared payload types + safe foreign-value constructor for strict CSS values.
#
# Every CSS value is a vancode Value whose typeId is the bro TypeKind ord and
# whose objectVal is a foreign Object wrapping one of the payloads below.
#
# Payloads MUST be plain objects (never ref): vancode initValue copies objects
# onto the heap with alloc, while its ref branch segfaults (dangling GC_ref).
#
# Construction goes through initCssPayload (not vancode initValue directly):
# raw alloc memory is zeroed first so ARC never decrefs recycled garbage when
# assigning payloads that own strings. The canonical CSS spelling is cached
# on the foreign tag so the VM can emit typed values without bro imports.
#
# (c) 2026 George Lemon | LGPL-v3 License

import std/[strutils]
import pkg/vancode/interpreter/value
import pkg/openparser/colors

type
  CssSize* = object
    val*: float
    unit*: string
  CssAngle* = object
    val*: float
    unit*: string
  CssTime* = object
    val*: float
    unit*: string
  CssResolution* = object
    val*: float
    unit*: string
  CssFlex* = object
    val*: float
    unit*: string
  BroColor* = object
    c*: Color
    raw*: string
  CssVar* = object
    name*: string
    fallback*: string
  CssFunction* = object
    ## Payload for CSS function values (translate3d, blur, gradients, ...).
    ## The full canonical spelling lives on the foreign tag (used by
    ## valueToCssText); the payload keeps the function name for
    ## introspection. One payload type serves all function families; the
    ## family is carried by the value's TypeKind (ttyTransform, ttyFilter,
    ## ttyImage, ttyShape, ttyEasing, ttyColor).
    fname*: string

proc cssNumStr*(f: float): string =
  result = $f
  if result.endsWith(".0"):
    result.setLen(result.len - 2)

var cssPayloadFreed* = 0
  ## TEMP DEBUG (remove before commit): destructor invocation count.
var cssPayloadMade* = 0
  ## TEMP DEBUG (remove before commit): construction count.

proc destroyCssPayload[T](data: pointer) {.nimcall.} =
  ## Per-payload destructor: `reset` runs the string field destructors
  ## before the struct memory goes back. A bare `dealloc` would orphan
  ## every string owned by the payload (raw memory has no destructors),
  ## leaking them once per constructed value.
  inc cssPayloadFreed
  reset(cast[ptr T](data)[])
  dealloc(data)

proc initCssPayload*[T: object](id: TypeId, payload: T, display: string): Value =
  inc cssPayloadMade
  let mem = alloc(sizeof(T))
  zeroMem(mem, sizeof(T))
  cast[ptr T](mem)[] = payload
  result = Value(typeId: id)
  result.objectVal = Object(isForeign: true,
    foreign: ForeignData(data: mem, tag: display,
      destructor: destroyCssPayload[T]))
