# bowdy JIT bridges: native implementations of bowdy's opcodes and the
# string/object plumbing its chunks use.
#
# (c) 2026 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/bowdy
#
# These are the runtime half of the `extendJit` block in
# `bowdy/engine/vancodegen.nim` (admission + emission); the compile-time half
# lives there as one-liner `host_emit` calls so all machine-code knowledge
# stays vancode-owned. Every bridge mirrors its interpreter branch exactly:
# same pops, same pushes, same field accesses (including the same raises on
# misuse) — native execution cannot drift from interpretation.
#
# Stack convention (see vancode `jit/jit_values.nim`): ints/bools travel as
# raw int64s, every other `Value` as an epoch-tagged ring index. Bridges
# unpack with `jitUnpackArg` and return with `jitPackResult`. Never a raw
# pointer cast across the boundary.
#
# Import order matters: this module imports vancode at top level, so it
# must only ever be imported downstream of vancodegen's top-level voodoo
# blocks (which populate the injection caches vancode compiles against).
# `vancodegen.nim` imports it after those blocks; CLI/embed call sites
# import it via paths that compile after vancodegen.
import std/[tables, strutils]
import pkg/vancode/interpreter/[vm, value, chunk, sym]
import pkg/vancode/interpreter/jit/[compiler_bridge, host_emit]
import ./stdlib/cssvalues

# --- pushg bridges: (namePtr: pointer) -> int64, result pushed ---

proc broJitPushConst*(namePtr: pointer): int64 {.cdecl, exportc.} =
  ## Push a chunk string constant: the immortal C string becomes a fresh
  ## string Value (fresh per push, like `pushConst` materializes per
  ## execution; callers only ever read it).
  jitPackResult(initValue($cast[cstring](namePtr)))

proc broJitPushFloat*(namePtr: pointer): int64 {.cdecl, exportc.} =
  ## Push a chunk float constant as a fresh float Value (floats never
  ## travel raw: no float arithmetic exists on the native stack).
  jitPackResult(initValue(cast[ptr float64](namePtr)[]))

proc broJitPushG*(namePtr: pointer): int64 {.cdecl, exportc.} =
  ## Push a global by name. Direct table index mirrors `opcPushG`
  ## (missing globals raise KeyError in both worlds).
  jitPackResult(jitGlobalVm.globals[$cast[cstring](namePtr)])

proc broJitPopG*(namePtr: pointer, slot: int64) {.cdecl, exportc.} =
  ## Pop one slot into a global. Tagged slots store the same object the
  ## interpreter would (aliasing preserved); raw ints box fresh (immutable,
  ## unobservable).
  jitGlobalVm.globals[$cast[cstring](namePtr)] = jitUnpackArg(slot)

# --- bridge_2: (a: int64, b: int64) -> int64; a deeper, b top ---

proc broJitConcatStr*(a, b: int64): int64 {.cdecl, exportc.} =
  ## String concatenation mirroring `opcConcatStr` exactly (direct field
  ## access: non-strings raise FieldDefect in both worlds).
  let av = jitUnpackArg(a)
  let bv = jitUnpackArg(b)
  var concatResult = Value(typeId: tyString)
  new(concatResult.stringVal)
  concatResult.stringVal[] = av.stringVal[] & bv.stringVal[]
  jitPackResult(concatResult)

# --- call_invoke bridges: (metaId, flatArgs, argc, nil) -> int64 ---
# flatArgs is in interpreter order (deepest first, like `stack{^n}`):
# flatArgs[0] is the first-pushed operand.

proc broJitConstrArray*(metaId: int32, flatArgs: ptr UncheckedArray[int64],
    argc: int32, argTypes: pointer): int64 {.cdecl, exportc.} =
  ## Build an array from the top `argc` slots, mirroring `opcConstrArray`
  ## (fields in push order; empty count pushes an empty array).
  let n = argc.int
  var arr = initArray(n)
  for i in 0 ..< n:
    arr.objectVal.fields[i] = jitUnpackArg(flatArgs[i]).toStorage
  jitPackResult(arr)

proc broJitConstrObj*(metaId: int32, flatArgs: ptr UncheckedArray[int64],
    argc: int32, argTypes: pointer): int64 {.cdecl, exportc.} =
  ## Build an object from the top `argc` slots with site keys from the
  ## host meta table (owned copies of the chunk key strings), mirroring
  ## `opcConstrObj` (id 15, keys guarded by `i < keys.len`, empty count
  ## pushes an empty object).
  let meta = getJitHostMeta(metaId)
  let n = argc.int
  var obj = initObject(15, n)
  for i in 0 ..< n:
    if i < meta.strs.len:
      obj.objectVal.keys.add(meta.strs[i])
    obj.objectVal.fields[i] = jitUnpackArg(flatArgs[i]).toStorage
  jitPackResult(obj)

proc broJitEmitRaw*(metaId: int32, flatArgs: ptr UncheckedArray[int64],
    argc: int32, argTypes: pointer): int64 {.cdecl, exportc.} =
  ## Emit one raw chunk: the shared `broEmitRawImpl` (also used by the
  ## interpreter branch) appends to the `__bro_output` globals ref. The
  ## dummy result is discarded by the emitter. Meta: ints = [line, col],
  ## strs = [chunk file].
  let meta = getJitHostMeta(metaId)
  let vm = jitGlobalVm
  broEmitRawImpl(vm, vm.globals["__bro_output"], jitUnpackArg(flatArgs[0]),
    meta.ints[0].int, meta.ints[1].int, meta.strs[0])
  0

proc broJitEmitCSS*(metaId: int32, flatArgs: ptr UncheckedArray[int64],
    argc: int32, argTypes: pointer): int64 {.cdecl, exportc.} =
  ## Emit one structured rule via the shared `broEmitCSSImpl`. Operand
  ## order (bottom..top): kind int, selector string, props object, so
  ## flatArgs = [kind, selector, props]. Meta: ints = position pairs,
  ## strs = [chunk file].
  let meta = getJitHostMeta(metaId)
  let vm = jitGlobalVm
  var poses = newSeq[uint16](meta.ints.len)
  for i, p in meta.ints:
    poses[i] = p.uint16
  broEmitCSSImpl(vm, vm.globals["__bro_output"],
    jitUnpackArg(flatArgs[0]), jitUnpackArg(flatArgs[1]),
    jitUnpackArg(flatArgs[2]), poses, meta.strs[0])
  0

proc cssDisplayText*(v: Value): string =
  ## Render one runtime value to its CSS display string. Single source of
  ## truth for the fast bridges below; mirrors `cssStr` in
  ## `stdlib/libsystem.nim` (and `valueToCssText` in `stdlib/libcss.nim`)
  ## exactly: primitives stringify, strictly typed values use the cached
  ## foreign-tag spelling, anything else is empty. The byte-identical
  ## gates pin this down; keep the three in sync.
  case v.typeId
  of tyString: result = v.stringVal[]
  of tyInt: result = $v.intVal
  of tyFloat:
    var fs = $v.floatVal
    if fs.len > 2 and fs[fs.len - 2] == '.' and fs[fs.len - 1] == '0':
      fs.setLen(fs.len - 2)
    result = fs
  of tyBool: result = $v.boolVal
  else:
    if v.objectVal != nil and v.objectVal.isForeign and
        v.objectVal.foreign.tag.len > 0:
      result = v.objectVal.foreign.tag
    else:
      result = ""

# --- JitForeignFast bridges: (procId, flatArgs, argc, nil) -> int64 ---
# flatArgs is deepest-first (fixed by `emitCallArgs`), so flatArgs[i] is
# the i-th declared parameter, exactly like the interpreter's stack slice.

proc broFastCssStr*(procId: int32, flatArgs: ptr UncheckedArray[int64],
    argc: int32, argTypes: pointer): int64 {.cdecl, exportc.} =
  ## Fast path for `cssStr(x)`: skip the generic bridge's proc-table
  ## lookup, arg boxing buffer, and result dispatch.
  jitPackResult(initValue(cssDisplayText(jitUnpackArg(flatArgs[0]))))

proc broFastCssJoin*(procId: int32, flatArgs: ptr UncheckedArray[int64],
    argc: int32, argTypes: pointer): int64 {.cdecl, exportc.} =
  ## Fast path for `cssJoin(parts)`: concatenate pre-stringified parts
  ## (plus literal separators) with per-element `cssStr` rendering.
  let arr = jitUnpackArg(flatArgs[0])
  var buf = ""
  for f in arr.objectVal.fields:
    buf.add(cssDisplayText(f.toValue()))
  jitPackResult(initValue(buf))

proc broFastVar1*(procId: int32, flatArgs: ptr UncheckedArray[int64],
    argc: int32, argTypes: pointer): int64 {.cdecl, exportc.} =
  ## Fast path for `var(--name)`: build the strictly typed CssVar payload
  ## with its `var(--name)` display spelling. Same ValueError as the
  ## stdlib body for names not starting with `--`.
  let name = jitUnpackArg(flatArgs[0]).stringVal[]
  if not name.startsWith("--"):
    raise newException(ValueError, "var() expects a custom property name starting with '--', got '" & name & "'")
  jitPackResult(initCssPayload(ord(ttyCssVar), CssVar(name: name, fallback: ""),
    "var(" & name & ")"))

proc broFastVar2*(procId: int32, flatArgs: ptr UncheckedArray[int64],
    argc: int32, argTypes: pointer): int64 {.cdecl, exportc.} =
  ## Fast path for `var(--name, fallback)`: fallback accepts any value
  ## and renders via the same display spelling.
  let name = jitUnpackArg(flatArgs[0]).stringVal[]
  if not name.startsWith("--"):
    raise newException(ValueError, "var() expects a custom property name starting with '--', got '" & name & "'")
  let fb = cssDisplayText(jitUnpackArg(flatArgs[1]))
  jitPackResult(initCssPayload(ord(ttyCssVar), CssVar(name: name, fallback: fb),
    "var(" & name & ", " & fb & ")"))

proc broJitGetOutput*(vmPtr: pointer): Value {.nimcall.} =
  ## Main-chunk output: the `__bro_output` globals ref aliased to
  ## interpret()'s `result` by the injected snippet. The native Halt
  ## returns 0, so the compiled main reports through this buffer.
  cast[Vm](vmPtr).globals["__bro_output"]

var broJitRegistered = false

proc initBroJit*(vm: Vm) =
  ## Register bowdy's bridges before the first JIT compile and install the
  ## main-chunk output hook (without it the main JIT stays disabled).
  ## Idempotent per process for the bridges; the output hook is per-VM.
  ##
  ## The host meta table is owned by vancode's `resetJitState` (called at
  ## every generation boundary before a fresh compile): meta ids never
  ## outlive the compile that made them, and the previous generation's
  ## machine code is freed by the same reset.
  vm.jit.getOutput = broJitGetOutput
  if broJitRegistered: return
  broJitRegistered = true
  registerJitHostBridge("broPushConst", cast[pointer](broJitPushConst))
  registerJitHostBridge("broPushFloat", cast[pointer](broJitPushFloat))
  registerJitHostBridge("broPushG", cast[pointer](broJitPushG))
  registerJitHostBridge("broPopG", cast[pointer](broJitPopG))
  registerJitHostBridge("broConcatStr", cast[pointer](broJitConcatStr))
  registerJitHostBridge("broConstrArray", cast[pointer](broJitConstrArray))
  registerJitHostBridge("broConstrObj", cast[pointer](broJitConstrObj))
  registerJitHostBridge("broEmitRaw", cast[pointer](broJitEmitRaw))
  registerJitHostBridge("broEmitCSS", cast[pointer](broJitEmitCSS))
  # Builtin fast paths: the hottest CallD targets in real stylesheets
  # (`var` 1046x, `cssStr` 309x, `cssJoin` 118x per bootstrap compile).
  # Same invoke sequence as the generic bridge, direct implementation.
  registerJitForeignFast("cssStr", JitForeignFast(arity: 1,
    bridgeFn: cast[pointer](broFastCssStr)))
  registerJitForeignFast("cssJoin", JitForeignFast(arity: 1,
    bridgeFn: cast[pointer](broFastCssJoin)))
  registerJitForeignFast("var", JitForeignFast(arity: 1,
    bridgeFn: cast[pointer](broFastVar1)))
  registerJitForeignFast("var", JitForeignFast(arity: 2,
    bridgeFn: cast[pointer](broFastVar2)))
